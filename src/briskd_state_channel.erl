-module(briskd_state_channel).
-moduledoc """
Channel membership, channel and user modes, channel commands, message
delivery, and safe-channel reop.

Every function runs inside the single `m:briskd_state` gen_server process, which
owns the Mnesia `channel` rows written here. A row is keyed by the channel
name folded with `briskd_wire:fold/1` (RFC 1459 case mapping) and holds only
**local** members, as a map of session pid to roles (`operator`, `voice`,
`creator`, or `member`). Members on other servers live in `remote_channel`
rows maintained by `m:briskd_state_link`; changes made here are propagated to
server peers through that module. A local channel operator's
`MODE +o/-o/+v/-v` and `KICK` on such a member update that `remote_channel`
row here. In every handler `Client` is the requesting `client` record and
`Server` is this server's name, used as the numeric prefix.

Implements the RFC 2811 channel model and the RFC 2812 section 3.2 and 3.3
commands. `JOIN` checks run in this order: channel name (403), netsplit hold
(437), per-user channel limit (405), key `+k` (475), limit `+l` (471),
invite-only `+i` unless invited or matched by `+I` (473), and ban `+b` unless
matched by `+e` (474). Sending to a channel fails with 404 for an outsider on a
`+n` channel, and for a member without voice or operator status on a `+m`
channel or matching a ban. The `b`, `e`, and `I` lists hold at most
`?MAX_LIST_ENTRIES` (100) masks each, advertised as `MAXLIST=beI:100`; adding
past that gives 478 ERR_BANLISTFULL.

Listing (`MODE <channel> b`, `e`, or `I`, with or without `+`): the ban list
is shown to anyone (RFC 2812 section 3.2.3), except that a non-member of a
`+s` or `+p` channel gets only 368 RPL_ENDOFBANLIST; the exception (348/349)
and invite-exception (346/347) lists need channel operator status, otherwise
482 ERR_CHANOPRIVSNEEDED. This split is implementation policy.

Visibility: `+p` and `+s` hide a channel's members from non-members; `+a`
(anonymous, only on `&` and `!` channels, RFC 2811 section 4.2.1) shows every
member as `anonymous!anonymous@anonymous.` and hides the member list; `+q`
(quiet, server-only) limits join, part, and quit notices to the user
concerned; members with user mode `+i` are listed only to requesters sharing
a channel with them.

Safe channels (RFC 2811 section 3.2) are named `!` plus a five-character id
plus a short name. `JOIN !short` looks up the folded short name in the
`briskd_safe_channels` ETS index to reuse an existing safe channel or creates
one with a new id, whose creator gets operator and creator status and alone
controls `+r` and `+a`. With `+r`, a channel left without an operator is
reopped after `reop_delay` seconds plus jitter, measured in monotonic time
(`reop_channels/1`). An emptied safe channel is kept; an emptied ordinary
channel is kept only under `channels` retention or when it is a configured
channel. Empty non-predefined channels without remote members are bounded by
`max_empty_channels` and expire after `empty_channel_ttl` seconds.
""".
%% Session pid -> folded channel keys it was invited to (ETS bag, owned by
%% briskd_state), so a disconnect cleans only those channels' invite lists.
-define(INVITES, briskd_invites).
-export([
    note_invited/2,
    admin_create/3,
    admin_destroy/3,
    admin_mode/4,
    deliver/5,
    deliver_body/6,
    index_safe_channels/0,
    invite/4,
    join_channels/4,
    kick/5,
    knock/4,
    leave/5,
    leave/6,
    mask_matches/3,
    mode_command/4,
    names/3,
    names_lines/6,
    names_listing/3,
    names_unattached/2,
    nick_recipients/1,
    prune_empty_channels/0,
    prune_invited/1,
    reop_channels/1,
    rename/3,
    role_prefix/2,
    split/1,
    topic/4,
    note_channel_history/4,
    note_channel_history/5,
    grant_predefined_operator/2,
    release_if_empty/2,
    track_opless/2,
    user_mode_string/1,
    visible_member/3,
    wildcard_match/2
]).
-include("briskd_state.hrl").

-doc """
A message body: `none` for `TAGMSG`, the text of a `PRIVMSG` or `NOTICE`, or a
draft/multiline batch as `{Concat, Line}` pairs in order.
""".
-type body() :: none | binary() | {multiline, [{boolean(), binary()}]}.
-export_type([body/0]).

-doc """
Store or delete a channel whose last local member has left.

`Remaining` is the (empty) member map to store. Safe `!` channels are always
kept, with their operatorless deadline updated (`track_opless/2`). Ordinary
channels are kept when retention is `channels` or the channel is configured
in `channels`, so a predefined channel stays available. Otherwise the
channel row, its message history, and its metadata are deleted.
""".
-spec release_if_empty(#channel{}, #{pid() => [channel_role()]}) -> ok.
release_if_empty(#channel{key = Key, name = <<$!, _/binary>>} = Channel, Remaining) ->
    note_channel_empty(Key),
    mnesia:dirty_write(track_opless(Channel, Remaining)),
    prune_empty_channels();
release_if_empty(#channel{key = Key} = Channel, Remaining) ->
    case briskd_state:retention() =:= channels orelse briskd_state:predefined_channel(Key) of
        true ->
            note_channel_empty(Key),
            mnesia:dirty_write(Channel#channel{members = Remaining}),
            prune_empty_channels();
        false ->
            drop_channel_row(Channel)
    end.

drop_channel_row(#channel{key = Key, name = Name}) ->
    unindex_safe_channel(Name),
    clear_channel_empty(Key),
    briskd_state_meta:drop_channel(Key),
    mnesia:dirty_delete(channel, Key),
    briskd_population:on_channel_delete(Key),
    briskd_state_history:delete_channel_history(Key).

note_channel_empty(Key) ->
    case ets:whereis(briskd_empty_channels) of
        undefined -> ok;
        _ -> ets:insert(briskd_empty_channels, {Key, erlang:system_time(second)})
    end,
    ok.

clear_channel_empty(Key) ->
    case ets:whereis(briskd_empty_channels) of
        undefined -> ok;
        _ -> ets:delete(briskd_empty_channels, Key)
    end,
    ok.

empty_since(Key, Created) ->
    case ets:whereis(briskd_empty_channels) of
        undefined ->
            channel_age_key(Created);
        _ ->
            case ets:lookup(briskd_empty_channels, Key) of
                [{Key, Since}] -> Since;
                [] -> channel_age_key(Created)
            end
    end.

-doc """
Populate the `briskd_safe_channels` ETS short-name index from the stored
`channel` table. Called by `m:briskd_state` at startup.
""".
-spec index_safe_channels() -> ok.
index_safe_channels() ->
    Now = erlang:system_time(second),
    case ets:whereis(briskd_safe_channels) of
        undefined ->
            ok;
        _ ->
            true = ets:delete_all_objects(briskd_safe_channels),
            lists:foreach(
                fun(Key) ->
                    case mnesia:dirty_read(channel, Key) of
                        [#channel{name = Name, members = Members}] ->
                            index_safe_channel(Name),
                            case map_size(Members) of
                                0 ->
                                    case ets:whereis(briskd_empty_channels) of
                                        undefined -> ok;
                                        _ -> ets:insert(briskd_empty_channels, {Key, Now})
                                    end;
                                _ ->
                                    ok
                            end;
                        [] ->
                            ok
                    end
                end,
                briskd_state:table_keys(channel)
            )
    end.

index_safe_channel(<<$!, _Id:5/binary, Short/binary>> = Name) when Short =/= <<>> ->
    case ets:whereis(briskd_safe_channels) of
        undefined ->
            ok;
        _ ->
            ets:insert(briskd_safe_channels, {briskd_wire:fold(Short), briskd_wire:retain(Name)}),
            ok
    end;
index_safe_channel(_) ->
    ok.

unindex_safe_channel(<<$!, _Id:5/binary, Short/binary>> = Name) when Short =/= <<>> ->
    case ets:whereis(briskd_safe_channels) of
        undefined ->
            ok;
        _ ->
            Folded = briskd_wire:fold(Short),
            case ets:lookup(briskd_safe_channels, Folded) of
                [{Folded, Stored}] ->
                    case briskd_wire:fold(Stored) =:= briskd_wire:fold(Name) of
                        true -> ets:delete(briskd_safe_channels, Folded);
                        false -> ok
                    end;
                [] ->
                    ok
            end,
            ok
    end;
unindex_safe_channel(_) ->
    ok.

-doc """
Evict the oldest empty non-predefined channels (without remote members) when
their count exceeds `max_empty_channels` (default 1000).
""".
-spec prune_empty_channels() -> ok.
prune_empty_channels() ->
    Max = maps:get(
        max_empty_channels, briskd_config:current_or_empty(), 1000
    ),
    Empty = [
        {has_retained_state(Channel), empty_since(Key, Created), Key, Channel}
     || Key <- briskd_state:table_keys(channel),
        [#channel{members = Members, created = Created} = Channel] <- [
            mnesia:dirty_read(channel, Key)
        ],
        map_size(Members) =:= 0,
        not briskd_state:predefined_channel(Key),
        mnesia:dirty_read(remote_channel, Key) =:= []
    ],
    Excess = length(Empty) - Max,
    case Excess > 0 of
        true ->
            Oldest = lists:sublist(lists:sort(Empty), Excess),
            lists:foreach(fun({_, _, _, C}) -> drop_channel_row(C) end, Oldest);
        false ->
            ok
    end.

has_retained_state(#channel{
    key = Key, topic = Topic, flags = Flags, lists = Lists, password = Password, limit = Limit
}) ->
    Topic =/= <<>> orelse map_size(Flags) > 0 orelse map_size(Lists) > 0 orelse
        Password =/= undefined orelse Limit =/= undefined orelse
        briskd_state_history:has_channel_history(Key) orelse
        mnesia:dirty_read(channel_meta, Key) =/= [].

channel_age_key(Created) when is_integer(Created) -> Created;
channel_age_key(_) -> 0.

-doc """
Record that session `Pid` was invited to channel `Key` (folded), so its
disconnect visits only those channels (`prune_invited/1`).
""".
-spec note_invited(pid(), binary()) -> ok.
note_invited(Pid, Key) ->
    case ets:whereis(?INVITES) of
        undefined -> ok;
        _ -> true = ets:insert(?INVITES, {Pid, Key})
    end,
    ok.

-doc """
Remove a disconnecting session `Pid` (and any dead pids) from the `invited`
list of every channel it was invited to. Only those channels are read (an
index kept by `note_invited/2`), where every channel used to be read on
every disconnect.
""".
-spec prune_invited(pid()) -> ok.
prune_invited(Pid) when is_pid(Pid) ->
    Keys =
        case ets:whereis(?INVITES) of
            undefined -> [];
            _ -> lists:usort([K || {_, K} <- ets:take(?INVITES, Pid)])
        end,
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{invited = [_ | _] = Invited} = Channel] ->
                    Cleaned = [P || P <- Invited, P =/= Pid, is_process_alive(P)],
                    case Cleaned =:= Invited of
                        true -> ok;
                        false -> mnesia:dirty_write(Channel#channel{invited = Cleaned})
                    end;
                _ ->
                    ok
            end
        end,
        Keys
    ).

-doc """
Give channel operator to an administrator on the predefined channels it is in.

Called after a successful `OPER`. Does nothing unless the client is a
configured administrator. For each predefined channel the client is already
a member of without operator status, it gains `operator`, the members see
`MODE <channel> +o <nick>`, and the change is propagated to server peers.
Modeless `+` channels are skipped.
""".
-spec grant_predefined_operator(#client{}, binary()) -> ok.
grant_predefined_operator(#client{pid = Pid}, Server) ->
    case briskd_state:administrator(Pid) of
        false ->
            ok;
        true ->
            Client = briskd_state_client:client(Pid),
            lists:foreach(
                fun(Key) -> grant_predefined_one(Key, Client, Server) end,
                Client#client.channels
            )
    end.

grant_predefined_one(Key, Client, Server) ->
    case briskd_state:predefined_channel(Key) of
        false -> ok;
        true -> grant_predefined_row(mnesia:dirty_read(channel, Key), Client, Server)
    end.

grant_predefined_row([], _Client, _Server) ->
    ok;
grant_predefined_row([#channel{name = <<$+, _/binary>>}], _Client, _Server) ->
    ok;
grant_predefined_row(
    [#channel{members = Members} = Channel], #client{pid = Pid, nick = Nick} = Client, _Server
) ->
    Roles = maps:get(Pid, Members, []),
    case is_map_key(Pid, Members) andalso not lists:member(operator, Roles) of
        false ->
            ok;
        true ->
            Updated = Channel#channel{members = Members#{Pid => lists:usort([operator | Roles])}},
            mnesia:dirty_write(Updated),
            briskd_state_send:broadcast(
                maps:keys(Members),
                briskd_state_send:prefix(Client),
                <<"MODE">>,
                [Channel#channel.name, <<"+o">>, Nick],
                none
            ),
            briskd_state_link:propagate_channel_mode(Client, Channel#channel.name, <<"+o">>, [Nick])
    end.

-doc """
Set a channel's member map and maintain its operatorless deadline.

Returns the updated record without writing it. When no remaining member
holds `operator`, `opless_since` is set to the reop deadline (monotonic
seconds plus `reop_delay` and jitter) unless one is already pending; when an
operator remains, the deadline is cleared.
""".
-spec track_opless(#channel{}, #{pid() => [creator | member | operator | voice]}) -> #channel{}.
track_opless(#channel{} = Channel, Remaining) ->
    HasOperator = lists:any(
        fun(Roles) -> lists:member(operator, Roles) end,
        maps:values(Remaining)
    ),
    ReopAt =
        case {HasOperator, Channel#channel.opless_since} of
            {true, _} -> undefined;
            {false, undefined} -> next_reop_time();
            {false, Existing} -> Existing
        end,
    Channel#channel{members = Remaining, opless_since = ReopAt}.

%% Deadline is monotonic seconds plus the configured delay and jitter.
%% Startup clears opless_since, so a persisted row never keeps a previous VM's clock.
next_reop_time() ->
    Delay = persistent_term:get({briskd_state, reop_delay}, 30),
    erlang:monotonic_time(second) + Delay + rand:uniform(Delay).

-doc """
Reop safe channels whose operatorless deadline has passed (RFC 2811 section 3.2.3).

Called once per second from the state process's `reop_tick` timer. For each
non-empty channel with mode `+r`: a pending deadline is cleared when an
operator is present, a deadline is started when none is pending, and once the
monotonic deadline passes a uniformly chosen local member is given
`operator`; the local members see `MODE <channel> +o <nick>` from
`Server`, and the same line, with `Server` as prefix, goes to every peer.
""".
-spec reop_channels(binary()) -> ok.
reop_channels(Server) ->
    Now = erlang:system_time(second),
    Ttl = maps:get(
        empty_channel_ttl, briskd_config:current_or_empty(), 86400
    ),
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{flags = Flags, members = Members} = Channel] when
                    map_size(Members) > 0
                ->
                    case maps:is_key($r, Flags) of
                        true -> maybe_reop(Channel, Server);
                        false -> ok
                    end;
                [#channel{members = Members} = Channel] when map_size(Members) =:= 0 ->
                    maybe_expire_empty(Channel, Now, Ttl);
                [] ->
                    ok
            end
        end,
        briskd_state:table_keys(channel)
    ).

maybe_expire_empty(_Channel, _Now, 0) ->
    ok;
maybe_expire_empty(#channel{key = Key, created = Created} = Channel, Now, Ttl) ->
    %% Under `channels` retention, channels with stored state or history are
    %% preserved across restarts and idle periods; TTL expiry only removes
    %% empty channels under `transient` retention (or completely blank rows).
    Eligible =
        briskd_state:retention() =:= transient orelse not has_retained_state(Channel),
    Since = empty_since(Key, Created),
    case
        Eligible andalso Since > 0 andalso Now - Since >= Ttl andalso
            not briskd_state:predefined_channel(Key) andalso
            mnesia:dirty_read(remote_channel, Key) =:= []
    of
        true -> drop_channel_row(Channel);
        false -> ok
    end.

maybe_reop(#channel{members = Members} = Channel, Server) ->
    HasOperator = lists:any(
        fun(Roles) -> lists:member(operator, Roles) end,
        maps:values(Members)
    ),
    case HasOperator of
        true ->
            case Channel#channel.opless_since of
                undefined -> ok;
                _ -> mnesia:dirty_write(Channel#channel{opless_since = undefined})
            end;
        false ->
            maybe_reop_opless(Channel, Server)
    end.

maybe_reop_opless(#channel{opless_since = undefined} = Channel, _Server) ->
    mnesia:dirty_write(Channel#channel{opless_since = next_reop_time()});
maybe_reop_opless(#channel{opless_since = ReopAt, members = Members} = Channel, Server) ->
    case erlang:monotonic_time(second) >= ReopAt of
        false ->
            ok;
        true ->
            case pick_member(Members) of
                none ->
                    ok;
                {Pid, Pids} ->
                    Nick =
                        case mnesia:dirty_read(client, Pid) of
                            [#client{nick = CurrentNick}] -> CurrentNick;
                            [] -> <<"*">>
                        end,
                    NewMembers = Members#{
                        Pid := lists:usort([operator | maps:get(Pid, Members)])
                    },
                    mnesia:dirty_write(Channel#channel{
                        members = NewMembers, opless_since = undefined
                    }),
                    briskd_state_send:broadcast(
                        Pids, Server, <<"MODE">>, [Channel#channel.name, <<"+o">>, Nick], none
                    ),
                    %% Peers learn the new operator from this server (RFC 2813
                    %% section 4.2.3), so their remote membership stays in step.
                    briskd_state_link:server_broadcast(
                        briskd_wire:line(
                            Server, <<"MODE">>, [Channel#channel.name, <<"+o">>, Nick], none
                        )
                    )
            end
    end.

%% A uniformly chosen member pid and every member pid, in map order. An empty
%% map is not reop'd (and `rand:uniform(0)` would raise).
pick_member(Members) ->
    case maps:keys(Members) of
        [] -> none;
        Pids -> {lists:nth(rand:uniform(length(Pids)), Pids), Pids}
    end.

-doc """
Join the client with session pid `Pid` to each channel in `Names` (RFC 2812 section 3.2.1).

`Keys` are matched to the names by position; missing keys are `undefined`.
Channels the client is already on are skipped. Each join runs the checks in
the order given in the module documentation. On success the channel row and
the client's channel list are updated (a new channel makes the joiner
operator, plus creator on a safe channel; a modeless `+` channel never grants
operator; a configured administrator joining a predefined channel becomes
operator), the join is propagated to peers, members receive `JOIN` (and
`AWAY` for away-notify), the event goes to channel history, and the joiner gets
332 RPL_TOPIC and 333 RPL_TOPICWHOTIME when a topic is set, the NAMES reply
(unless `no-implicit-names`), metadata, and history replay.
""".
-spec join_channels([binary()], [binary()], pid(), binary()) -> ok.
join_channels([], _, _, _) ->
    ok;
join_channels([Name | Names], Keys, Pid, Server) ->
    {Password, Remaining} =
        case Keys of
            [Key | Tail] -> {Key, Tail};
            [] -> {undefined, []}
        end,
    join(Name, Password, briskd_state_client:client(Pid), Server),
    join_channels(Names, Remaining, Pid, Server).

%% Resolve safe channel names, then apply membership, key, limit, and ban checks.
join(Name, Password, Client, Server) ->
    case resolve_channel(Name) of
        error ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        {ok, Canonical} ->
            Key = briskd_wire:fold(Canonical),
            case lists:member(Key, Client#client.channels) of
                true -> ok;
                false -> add_member(Key, Canonical, Client, Server, Password)
            end
    end.

resolve_channel(<<$!, Short/binary>> = Requested) ->
    Key = briskd_wire:fold(Requested),
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Existing}] ->
            {ok, Existing};
        [] ->
            case {byte_size(Short) =< 44, briskd_wire:channel(<<$#, Short/binary>>)} of
                {false, _} ->
                    error;
                {_, false} ->
                    error;
                {true, true} ->
                    case find_safe_short(Short) of
                        {ok, Existing} -> {ok, Existing};
                        none -> {ok, <<$!, (safe_channel_id())/binary, Short/binary>>}
                    end
            end
    end;
resolve_channel(Name) ->
    case briskd_wire:channel(Name) of
        true -> {ok, Name};
        false -> error
    end.

find_safe_short(Short) ->
    Wanted = briskd_wire:fold(Short),
    case ets:whereis(briskd_safe_channels) of
        undefined ->
            scan_safe_short(Wanted);
        _ ->
            case ets:lookup(briskd_safe_channels, Wanted) of
                [{Wanted, Indexed}] ->
                    case mnesia:dirty_read(channel, briskd_wire:fold(Indexed)) of
                        [#channel{name = Existing}] ->
                            {ok, Existing};
                        [] ->
                            ets:delete(briskd_safe_channels, Wanted),
                            scan_safe_short(Wanted)
                    end;
                [] ->
                    scan_safe_short(Wanted)
            end
    end.

scan_safe_short(Wanted) ->
    case
        [
            Name
         || Key <- briskd_state:table_keys(channel),
            [#channel{name = <<$!, _Id:5/binary, ExistingShort/binary>> = Name}] <-
                [mnesia:dirty_read(channel, Key)],
            briskd_wire:fold(ExistingShort) =:= Wanted
        ]
    of
        [Name | _] ->
            index_safe_channel(Name),
            {ok, Name};
        [] ->
            none
    end.

%% Local row for a channel learned from a peer, before the first local member.
channel_from_remote(#remote_channel{key = Key, name = Name, flags = RemoteFlags}) ->
    ModeKeys = [$a, $i, $m, $n, $p, $q, $r, $s, $t, $K],
    #channel{
        key = Key,
        name = Name,
        created = erlang:system_time(second),
        topic = maps:get(topic, RemoteFlags, <<>>),
        flags = #{M => true || M <- ModeKeys, is_map_key(M, RemoteFlags)},
        lists = maps:with([ban, exception, invite], RemoteFlags),
        password = maps:get(key, RemoteFlags, undefined),
        limit = maps:get(limit, RemoteFlags, undefined)
    }.

safe_channel_id() ->
    Alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890">>,
    safe_channel_id(erlang:system_time(second) rem 60466176, Alphabet, <<>>).

safe_channel_id(_, _, <<_:(5 * 8)/bitstring>> = Id) ->
    Id;
safe_channel_id(Value, Alphabet, Acc) ->
    Digit = Value rem 36,
    Char = binary:at(Alphabet, Digit),
    safe_channel_id(Value div 36, Alphabet, <<Char, Acc/binary>>).

%% Add a client to a channel and grant operator status to the first member.
%% A channel that already exists on a linked server is adopted from its
%% `remote_channel` row (modes, key, limit, lists, topic). The joiner is a
%% plain member of that channel, not its founder.
add_member(Key, Name, #client{pid = Pid} = Client, Server, Password) ->
    {Channel, IsNew} =
        case mnesia:dirty_read(channel, Key) of
            [#channel{} = Existing] ->
                {Existing, false};
            [] ->
                case mnesia:dirty_read(remote_channel, Key) of
                    [#remote_channel{} = Remote] ->
                        {channel_from_remote(Remote), false};
                    [] ->
                        {
                            #channel{
                                key = Key,
                                name = Name,
                                created = erlang:system_time(second),
                                creator =
                                    case binary:first(Name) of
                                        $! -> Pid;
                                        _ -> undefined
                                    end,
                                flags =
                                    case binary:first(Name) of
                                        $+ -> #{$t => true};
                                        _ -> #{}
                                    end
                            },
                            true
                        }
                end
        end,
    #channel{name = Canonical, members = Members} = Channel,
    Admin = briskd_state:administrator(Pid) andalso briskd_state:predefined_channel(Key),
    Role =
        case {IsNew, binary:first(Canonical), Admin} of
            {true, $!, _} -> [operator, creator];
            {_, $+, _} -> [member];
            {true, _, _} -> [operator];
            {false, _, true} -> [operator];
            _ -> [member]
        end,
    NewMembers = Members#{Pid => Role},
    Joined = length(Client#client.channels),
    case briskd_state_net:channel_blocked(Canonical) of
        true ->
            briskd_state_send:numeric(
                Client,
                Server,
                <<"437">>,
                [Canonical],
                <<"Nick/channel is temporarily unavailable">>
            );
        false ->
            case briskd_route:channel_allowed(Joined, briskd_route:max_channels()) of
                false ->
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"405">>,
                        [Canonical],
                        <<"You have joined too many channels">>
                    );
                true ->
                    join_checked(Channel, Client, Server, NewMembers, Members, Password)
            end
    end.

join_checked(
    Channel, #client{pid = Pid, channels = Channels} = Client, Server, NewMembers, Members, Password
) ->
    Canonical = Channel#channel.name,
    %% Constant-time key comparison so the key does not leak through timing.
    KeyAccepted =
        case Channel#channel.password of
            undefined -> true;
            Required -> is_binary(Password) andalso briskd_config:secret_match(Password, Required)
        end,
    case Channel of
        _ when not KeyAccepted ->
            briskd_state_send:numeric(
                Client, Server, <<"475">>, [Canonical], <<"Cannot join channel (+k)">>
            );
        #channel{limit = Limit} when is_integer(Limit), map_size(Members) >= Limit ->
            briskd_state_send:numeric(
                Client, Server, <<"471">>, [Canonical], <<"Cannot join channel (+l)">>
            );
        _ ->
            Invited =
                lists:member(Pid, Channel#channel.invited) orelse
                    mask_matches(Channel, invite, Client),
            Banned =
                mask_matches(Channel, ban, Client) andalso
                    not mask_matches(Channel, exception, Client),
            case {maps:is_key($i, Channel#channel.flags) andalso not Invited, Banned} of
                {true, _} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"473">>, [Canonical], <<"Cannot join channel (+i)">>
                    );
                {_, true} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"474">>, [Canonical], <<"Cannot join channel (+b)">>
                    );
                _ ->
                    finish_join(Channel, Client, Server, NewMembers, Channels)
            end
    end.

finish_join(
    #channel{key = Key, name = Canonical, invited = Invited, flags = Flags} = Channel,
    #client{pid = Pid} = Client,
    Server,
    NewMembers,
    Channels
) ->
    mnesia:dirty_write(Channel#channel{
        members = NewMembers,
        invited = lists:delete(Pid, Invited)
    }),
    briskd_population:on_channel_put(Key),
    clear_channel_empty(Key),
    index_safe_channel(Canonical),
    mnesia:dirty_write(Client#client{channels = [Key | Channels]}),
    briskd_state_link:propagate_join(Client, Canonical, maps:get(Pid, NewMembers)),
    JoinRecipients =
        case maps:is_key($q, Flags) of
            true -> [Pid];
            false -> maps:keys(NewMembers)
        end,
    Origin = channel_origin_prefix(Channel, Client),
    Anonymous = maps:is_key($a, Flags),
    {JoinAccount, JoinReal} =
        case Anonymous of
            true -> {undefined, <<"anonymous">>};
            false -> {briskd_state_v3:account(Pid), Client#client.real}
        end,
    {JoinTags, JoinMeta} = briskd_state_history:event_tags(),
    briskd_state_v3:join_broadcast(
        JoinRecipients, Origin, Canonical, JoinAccount, JoinReal, JoinTags
    ),
    briskd_state_history:note_event(Key, <<"JOIN">>, Origin, [], none, JoinMeta),
    case Anonymous of
        true ->
            ok;
        false ->
            briskd_state_v3:away_on_join(
                [P || P <- JoinRecipients, P =/= Pid], Origin, Client#client.away
            )
    end,
    %% RFC 2812 3.2.1: after JOIN only an existing topic is sent (RPL_TOPIC).
    join_topic(Channel, Client, Server),
    briskd_state_history:markread_on_join(Pid, Canonical, Server),
    case briskd_cap:enabled(Pid, <<"no-implicit-names">>) of
        true -> ok;
        false -> names(Canonical, Client, Server)
    end,
    briskd_state_meta:on_join(Key, Client, Server),
    replay_channel_history(Key, Canonical, Pid).

-doc """
Remove a local client from a channel; see `leave/6`.

`Notify` controls both the local notice and peer propagation.
""".
-spec leave(binary(), #client{}, binary(), none | binary(), boolean()) -> ok.
leave(Key, Client, Command, Reason, Notify) ->
    leave(Key, Client, Command, Reason, Notify, Notify).

-doc """
Remove a local client from a channel.

`Key` is the folded channel name and must name an existing channel.
`Command` is the verb shown to members (normally `PART`) and `Reason` its
trailing text or `none`. With `Notify`, members (only the leaver on a `+q`
channel) receive the line and it is recorded in channel history; with
`Propagate` and a `PART` command, the `PART` is sent to server peers. The
member is removed, the operatorless deadline is updated, an emptied channel
is handled by `release_if_empty/2`, and the channel is removed from the
client's list.
""".
-spec leave(binary(), #client{}, binary(), none | binary(), boolean(), boolean()) -> ok.
leave(Key, #client{pid = Pid} = Client, Command, Reason, Notify, Propagate) ->
    [#channel{name = Name, members = Members, flags = Flags} = Channel] =
        mnesia:dirty_read(channel, Key),
    case Notify of
        true ->
            Recipients =
                case maps:is_key($q, Flags) of
                    true -> [Pid];
                    false -> maps:keys(Members)
                end,
            {LeaveTags, LeaveMeta} = briskd_state_history:event_tags(),
            briskd_state_send:broadcast(
                Recipients,
                channel_origin_prefix(Channel, Client),
                Command,
                [Name],
                Reason,
                LeaveTags
            ),
            briskd_state_history:note_event(
                Key, Command, channel_origin_prefix(Channel, Client), [], Reason, LeaveMeta
            );
        false ->
            ok
    end,
    case Propagate andalso Command =:= <<"PART">> of
        true ->
            ReasonParams =
                case Reason of
                    none -> none;
                    _ -> Reason
                end,
            briskd_state_link:server_broadcast(
                briskd_wire:line(briskd_state_send:prefix(Client), <<"PART">>, [Name], ReasonParams)
            );
        false ->
            ok
    end,
    case maps:remove(Pid, Members) of
        Remaining when map_size(Remaining) =:= 0 ->
            release_if_empty(Channel, Remaining);
        Remaining ->
            mnesia:dirty_write(track_opless(Channel, Remaining))
    end,
    Current = briskd_state_client:client(Pid),
    mnesia:dirty_write(Current#client{channels = lists:delete(Key, Current#client.channels)}).

-doc """
Handle `KICK <channel> <nick>[,<nick>...] [<comment>]` (RFC 2812 section 3.2.8).

`Name` is the channel, `Nicks` the targets in order, and `Reason` the comment.
An unknown channel gets 403 ERR_NOSUCHCHANNEL, a requester who is not a
member 442 ERR_NOTONCHANNEL, and one without operator status 482
ERR_CHANOPRIVSNEEDED. For each target, a nickname unknown locally and on the
network gets 401 ERR_NOSUCHNICK and a non-member 441 ERR_USERNOTINCHANNEL. A
kicked member is announced to the channel (only to the kicker and target on a
`+q` channel), recorded in history, propagated to peers, and removed. A
member on another server is removed from the `remote_channel` row; its home
server removes it there when the propagated `KICK` arrives.
""".
-spec kick(binary(), [binary()], binary(), #client{}, binary()) -> ok.
kick(_, [], _, _, _) ->
    ok;
kick(Name, [Nick | Nicks], Reason, #client{pid = Pid} = Client, Server) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        [#channel{name = Canonical, members = Members} = Channel] ->
            case maps:is_key(Pid, Members) of
                false ->
                    briskd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                true ->
                    case lists:member(operator, maps:get(Pid, Members, [])) of
                        false ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"482">>,
                                [Canonical],
                                <<"You're not channel operator">>
                            );
                        true ->
                            kick_member(
                                Nick, Nicks, Reason, Client, Server, Key, Canonical, Channel
                            )
                    end
            end
    end.

kick_member(
    Nick,
    Nicks,
    Reason,
    Client,
    Server,
    Key,
    Canonical,
    #channel{members = Members} = Channel
) ->
    case briskd_state_client:find_nick(Nick) of
        undefined ->
            NickKey = briskd_wire:fold(Nick),
            case remote_target(NickKey, Canonical) of
                no_such_nick ->
                    briskd_state_send:numeric(
                        Client, Server, <<"401">>, [Nick], <<"No such nick">>
                    );
                not_on_channel ->
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"441">>,
                        [Nick, Canonical],
                        <<"They aren't on that channel">>
                    );
                {ok, Actual, RemoteChannel} ->
                    kick_remote_member(
                        NickKey, Actual, RemoteChannel, Reason, Client, Key, Canonical, Channel
                    )
            end,
            kick(Canonical, Nicks, Reason, Client, Server);
        #client{pid = TargetPid, nick = Actual} = Target ->
            case maps:is_key(TargetPid, Members) of
                false ->
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"441">>,
                        [Actual, Canonical],
                        <<"They aren't on that channel">>
                    ),
                    kick(Canonical, Nicks, Reason, Client, Server);
                true ->
                    {KickTags, KickMeta} = briskd_state_history:event_tags(),
                    briskd_state_send:broadcast(
                        case maps:is_key($q, Channel#channel.flags) of
                            true -> [Client#client.pid, TargetPid];
                            false -> maps:keys(Members)
                        end,
                        channel_origin_prefix(Channel, Client),
                        <<"KICK">>,
                        [Canonical, Actual],
                        Reason,
                        KickTags
                    ),
                    briskd_state_history:note_event(
                        Key,
                        <<"KICK">>,
                        channel_origin_prefix(Channel, Client),
                        [Actual],
                        Reason,
                        KickMeta
                    ),
                    briskd_state_link:propagate_channel_kick(Client, Canonical, Actual, Reason),
                    Remaining = maps:remove(TargetPid, Members),
                    case map_size(Remaining) of
                        0 ->
                            release_if_empty(Channel, Remaining);
                        _ ->
                            mnesia:dirty_write(track_opless(Channel, Remaining))
                    end,
                    mnesia:dirty_write(Target#client{
                        channels = lists:delete(Key, Target#client.channels)
                    }),
                    kick(Canonical, Nicks, Reason, Client, Server)
            end
    end.

%% KICK of a member of another server (RFC 2812 section 3.2.8): local members
%% see it, the member is dropped from the `remote_channel` row, and the peers
%% get the KICK so the target's home server removes it there.
kick_remote_member(
    NickKey,
    Actual,
    #remote_channel{key = RemoteKey, members = Remote} = RemoteChannel,
    Reason,
    Client,
    Key,
    Canonical,
    #channel{members = Members} = Channel
) ->
    {KickTags, KickMeta} = briskd_state_history:event_tags(),
    briskd_state_send:broadcast(
        case maps:is_key($q, Channel#channel.flags) of
            true -> [Client#client.pid];
            false -> maps:keys(Members)
        end,
        channel_origin_prefix(Channel, Client),
        <<"KICK">>,
        [Canonical, Actual],
        Reason,
        KickTags
    ),
    briskd_state_history:note_event(
        Key, <<"KICK">>, channel_origin_prefix(Channel, Client), [Actual], Reason, KickMeta
    ),
    briskd_state_link:propagate_channel_kick(Client, Canonical, Actual, Reason),
    Left = maps:remove(NickKey, Remote),
    case map_size(Left) of
        0 ->
            mnesia:dirty_delete(remote_channel, RemoteKey),
            briskd_population:on_channel_delete(RemoteKey);
        _ ->
            mnesia:dirty_write(RemoteChannel#remote_channel{members = Left})
    end.

-doc """
Local session pids that should see a `NICK` change by `Client`.

The client itself plus every local member of its channels, excluding
anonymous `+a` and quiet `+q` channels. The list is sorted and unique.
""".
-spec nick_recipients(#client{}) -> [pid(), ...].
nick_recipients(#client{pid = Pid, channels = Channels}) ->
    lists:usort([
        Pid
        | [
            Other
         || Key <- Channels,
            [#channel{members = Members, flags = Flags}] <- [mnesia:dirty_read(channel, Key)],
            not maps:is_key($a, Flags),
            not maps:is_key($q, Flags),
            Other <- maps:keys(Members),
            Other =/= Pid
        ]
    ]).

channel_origin_prefix(#channel{flags = Flags}, _Client) when is_map_key($a, Flags) ->
    <<"anonymous!anonymous@anonymous.">>;
channel_origin_prefix(_, Client) ->
    briskd_state_send:prefix(Client).

-doc """
Route `PRIVMSG`, `NOTICE`, or `TAGMSG` to nicknames and channels (RFC 2812 section 3.3).

`Command` is the verb, `Params` the parameters (`<targets> [<text>]`), and
`Tags` the parsed message tags; client-only tags are relayed only when the
sender has `message-tags`. A missing target gives 411 ERR_NORECIPIENT and
missing or empty text (except for `TAGMSG`) 412 ERR_NOTEXTTOSEND. Duplicate
targets are dropped, and targets past the first four (`TARGMAX`) each get 407
ERR_TOOMANYTARGETS. Each remaining target goes through `deliver_body/6`.
`NOTICE` never produces an error reply.
""".
-spec deliver(binary(), [binary()], #client{}, binary(), [{binary(), undefined | binary()}]) -> ok.
deliver(Command, Params, #client{pid = Pid} = Client, Server, Tags) ->
    %% Without message-tags a client's tags are ignored, except the E2EE
    %% envelope tags: dropping them would store and relay ciphertext as if it
    %% were text (and message search would index it).
    ClientTags =
        case briskd_cap:enabled(Pid, <<"message-tags">>) of
            true -> briskd_cap:client_tags(Tags);
            false -> briskd_e2ee:envelope_tags(Tags)
        end,
    case {Command, Params} of
        {<<"TAGMSG">>, []} ->
            message_error(Command, Client, Server, <<"411">>, [], <<"No recipient given">>);
        {<<"TAGMSG">>, [Targets | _]} ->
            deliver_targets(Targets, none, Command, Client, Server, ClientTags);
        {_, []} ->
            message_error(Command, Client, Server, <<"411">>, [], <<"No recipient given">>);
        {_, [_]} ->
            message_error(Command, Client, Server, <<"412">>, [], <<"No text to send">>);
        {_, [_, <<>> | _]} ->
            message_error(Command, Client, Server, <<"412">>, [], <<"No text to send">>);
        {_, [Targets, Text | _]} ->
            deliver_targets(Targets, Text, Command, Client, Server, ClientTags)
    end.

%% At most ?MAX_TARGETS recipients per PRIVMSG, NOTICE, or TAGMSG
%% (advertised as TARGMAX). Each extra target gets 407 ERR_TOOMANYTARGETS,
%% except for NOTICE, whose errors are silent.
-define(MAX_TARGETS, 4).

deliver_targets(Targets, Text, Command, Client, Server, Tags) ->
    All = lists:uniq(split(Targets)),
    {Allowed, Extra} = lists:split(min(length(All), ?MAX_TARGETS), All),
    lists:foreach(
        fun(Target) -> deliver_body(Command, Target, Text, Client, Server, Tags) end,
        Allowed
    ),
    lists:foreach(
        fun(Target) ->
            message_error(
                Command, Client, Server, <<"407">>, [Target], <<"Too many recipients">>
            )
        end,
        Extra
    ).

-doc """
Deliver one message body to one target.

`Body` is a binary, `none` for `TAGMSG`, or `{multiline, Lines}` from a
draft/multiline batch, and `ClientTags` are the client-only tags to relay.
Each delivery gets fresh `msgid` and `time` tags, filtered per recipient by
capability.

- A local channel applies the `+n`, `+m`, and ban checks (404
  ERR_CANNOTSENDTOCHAN), then sends to the other local members, echoes to the
  sender with `echo-message`, records the message in channel history, and
  forwards it to server peers.
- A registered local user receives the message, the sender gets the echo, the
  message is recorded as direct history, and a `PRIVMSG` to an away user gets
  301 RPL_AWAY.
- A remote user is reached through its adjacent link.
- Anything else, including a local client still registering, gets 401
  ERR_NOSUCHNICK.

`NOTICE` failures are silent.
""".
-spec deliver_body(binary(), binary(), body(), #client{}, binary(), [
    {binary(), undefined | binary()}
]) -> ok.
deliver_body(Command, Target, Body, #client{pid = Pid} = Client, Server, ClientTags) ->
    MsgId = briskd_state_send:msgid(),
    Now = erlang:system_time(millisecond),
    %% message-tags: server tags come before client-only tags.
    Tags = [{<<"msgid">>, MsgId}, {<<"time">>, briskd_state_send:time_value(Now)} | ClientTags],
    Account = briskd_state_v3:account(Pid),
    case mnesia:dirty_read(channel, briskd_wire:fold(Target)) of
        [#channel{name = Name, members = Members, flags = Flags} = Channel] ->
            Roles = maps:get(Pid, Members, []),
            %% +a hides every sender behind one mask, so an outsider must not
            %% be able to speak as a member. Treat it like +n.
            Outside =
                (maps:is_key($n, Flags) orelse maps:is_key($a, Flags)) andalso
                    not maps:is_key(Pid, Members),
            Moderated =
                maps:is_key($m, Flags) andalso
                    not (lists:member(operator, Roles) orelse lists:member(voice, Roles)),
            Banned =
                mask_matches(Channel, ban, Client) andalso
                    not mask_matches(Channel, exception, Client),
            BannedWithoutPrivilege =
                Banned andalso
                    not (lists:member(operator, Roles) orelse lists:member(voice, Roles)),
            case Outside orelse Moderated orelse BannedWithoutPrivilege of
                true ->
                    message_error(
                        Command, Client, Server, <<"404">>, [Name], <<"Cannot send to channel">>
                    );
                false ->
                    Origin = channel_origin_prefix(Channel, Client),
                    Recipients = maps:keys(maps:remove(Pid, Members)),
                    fan_out(Recipients, Origin, Command, Name, Body, Tags),
                    echo(Pid, Origin, Command, Name, Body, Tags),
                    Stored =
                        case maps:is_key($a, Flags) of
                            true -> undefined;
                            false -> Account
                        end,
                    briskd_state_history:note_channel(
                        briskd_wire:fold(Name),
                        briskd_state_history:entry(
                            Command, Origin, Body, MsgId, Now, ClientTags, Stored
                        )
                    ),
                    briskd_state_link:propagate_channel_lines(
                        Name,
                        briskd_state_batch:link_lines(
                            briskd_state_send:prefix(Client), Command, Name, Body, Tags
                        )
                    )
            end;
        [] ->
            %% End-to-end encryption: queue an envelope for an offline device;
            %% a target that is wholly offline needs no other delivery.
            case briskd_e2ee:route(Target, Body, Client, {ClientTags, Tags, Command}) of
                handled ->
                    ok;
                pass ->
                    deliver_direct(
                        Command,
                        Target,
                        Body,
                        Client,
                        Server,
                        {ClientTags, Tags, MsgId, Now, Account}
                    )
            end
    end.

deliver_direct(
    Command,
    Target,
    Body,
    #client{pid = Pid} = Client,
    Server,
    {ClientTags, Tags, MsgId, Now, Account}
) ->
    Recipient =
        case briskd_state_client:find_nick(Target) of
            #client{} = Found ->
                case briskd_state_client:ready(Found) of
                    true -> Found;
                    false -> held
                end;
            undefined ->
                undefined
        end,
    case Recipient of
        held ->
            message_error(
                Command, Client, Server, <<"401">>, [Target], <<"No such nick/channel">>
            );
        #client{pid = Other, nick = Nick, away = Away} ->
            Prefix = briskd_state_send:prefix(Client),
            %% A message to oneself is delivered and, with
            %% echo-message, also echoed: two copies, one labeled.
            fan_out([Other], Prefix, Command, Nick, Body, Tags),
            echo(Pid, Prefix, Command, Nick, Body, Tags),
            briskd_state_history:note_direct(
                {Account, Client#client.nick},
                {briskd_state_v3:account(Other), Nick},
                Nick,
                briskd_state_history:entry(
                    Command, Prefix, Body, MsgId, Now, ClientTags, Account
                )
            ),
            case {Command, Away} of
                {<<"PRIVMSG">>, Message} when Message =/= undefined ->
                    briskd_state_send:numeric(Client, Server, <<"301">>, [Nick], Message);
                _ ->
                    ok
            end;
        undefined ->
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Target)) of
                [#remote_client{peer = Peer, nick = Nick, account = Theirs}] ->
                    Prefix = briskd_state_send:prefix(Client),
                    Results = [
                        briskd_links:send(Peer, iolist_to_binary(Line))
                     || Line <- briskd_state_batch:link_lines(
                            Prefix, Command, Nick, Body, Tags
                        )
                    ],
                    case lists:all(fun(R) -> R =:= ok end, Results) of
                        true ->
                            echo(Pid, Prefix, Command, Nick, Body, Tags),
                            briskd_state_history:note_direct(
                                {Account, Client#client.nick},
                                {Theirs, Nick},
                                Nick,
                                briskd_state_history:entry(
                                    Command, Prefix, Body, MsgId, Now, ClientTags, Account
                                )
                            );
                        false ->
                            message_error(
                                Command,
                                Client,
                                Server,
                                <<"401">>,
                                [Target],
                                <<"No such nick/channel">>
                            )
                    end;
                [] ->
                    message_error(
                        Command,
                        Client,
                        Server,
                        <<"401">>,
                        [Target],
                        <<"No such nick/channel">>
                    )
            end
    end.

fan_out(Pids, Prefix, Command, Target, {multiline, Lines}, Tags) ->
    lists:foreach(
        fun(P) ->
            briskd_state_batch:deliver_multiline(P, Prefix, Command, Target, Lines, Tags, normal)
        end,
        Pids
    );
fan_out(Pids, Prefix, Command, Target, Text, Tags) ->
    briskd_state_send:broadcast(Pids, Prefix, Command, [Target], Text, Tags).

%% echo-message: the sender gets the message as recipients saw it.
echo(Pid, Prefix, Command, Target, Body, Tags) ->
    case briskd_cap:enabled(Pid, <<"echo-message">>) of
        false ->
            ok;
        true ->
            case Body of
                {multiline, Lines} ->
                    briskd_state_batch:deliver_multiline(
                        Pid, Prefix, Command, Target, Lines, Tags, echo
                    );
                _ ->
                    briskd_state_send:echo(Pid, Prefix, Command, [Target], Body, Tags)
            end
    end.

message_error(<<"NOTICE">>, _, _, _, _, _) ->
    ok;
message_error(_, Client, Server, Number, Middle, Text) ->
    briskd_state_send:numeric(Client, Server, Number, Middle, Text).

-doc """
Record a channel `PRIVMSG` or `NOTICE` accepted from a server peer; see `note_channel_history/5`.
""".
-spec note_channel_history(binary(), binary(), binary(), none | iodata()) -> ok.
note_channel_history(Key, Command, Prefix, Text) ->
    note_channel_history(Key, Command, Prefix, Text, []).

-doc """
Record a channel `PRIVMSG` or `NOTICE` accepted from a server peer.

`Key` is the folded channel name, `Prefix` the source prefix, `Text` the
body, and `Tags` the line's tags. The peer's `msgid` and `time` are kept when
present (a line without `msgid` is stored without one; a missing or invalid
`time` uses the current time), and the account is taken from the source.
A non-binary body, such as `TAGMSG`'s `none`, is not recorded. The body is
never logged.
""".
-spec note_channel_history(binary(), binary(), binary(), none | iodata(), [
    {binary(), undefined | binary()}
]) -> ok.
note_channel_history(Key, Command, Prefix, Text, Tags) when is_binary(Text) ->
    MsgId =
        case lists:keyfind(<<"msgid">>, 1, Tags) of
            {_, Id} when is_binary(Id) -> Id;
            %% A line that arrived without a msgid keeps none in history.
            _ -> undefined
        end,
    Time =
        case lists:keyfind(<<"time">>, 1, Tags) of
            {_, Stamp} when is_binary(Stamp) ->
                case briskd_state_history:parse_timestamp(Stamp) of
                    {ok, T} -> T;
                    error -> erlang:system_time(millisecond)
                end;
            _ ->
                erlang:system_time(millisecond)
        end,
    Account = maps:get(
        account, briskd_state_v3:remote_source_info(iolist_to_binary(Prefix)), undefined
    ),
    briskd_state_history:note_channel(
        Key,
        briskd_state_history:entry(
            Command, Prefix, Text, MsgId, Time, briskd_cap:client_tags(Tags), Account
        )
    );
note_channel_history(_Key, _Command, _Prefix, _Text, _Tags) ->
    ok.

replay_channel_history(Key, Name, Pid) ->
    briskd_state_history:replay_on_join(Key, Name, Pid).

-doc """
Handle `TOPIC <channel> [<topic>]` (RFC 2812 section 3.2.4).

`Rest` is the optional new topic as a parameter list. A query replies with
332 RPL_TOPIC and 333 RPL_TOPICWHOTIME, or 331 RPL_NOTOPIC. A `+p` or `+s`
channel the requester is not on (local or remote-only alike), or an unknown
channel, gives 403 ERR_NOSUCHCHANNEL, for both a query and a change.
Setting requires membership (442 ERR_NOTONCHANNEL) and, with `+t`, operator
status (482 ERR_CHANOPRIVSNEEDED). A new topic is stored with its setter and time,
broadcast to members, recorded in history, and propagated to peers. When the
local row has no topic, the topic reported by a peer is shown.
""".
-spec topic(binary(), [binary()], #client{}, binary()) -> ok.
topic(Name, Rest, #client{pid = Pid} = Client, Server) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, flags = Flags} = Channel] ->
            Operator = lists:member(operator, maps:get(Pid, Members, [])),
            Hidden =
                (maps:is_key($s, Flags) orelse maps:is_key($p, Flags)) andalso
                    not maps:is_key(Pid, Members),
            case {Hidden, maps:is_key(Pid, Members), Rest} of
                {true, _, _} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"403">>, [Canonical], <<"No such channel">>
                    );
                {false, false, [_ | _]} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                {false, _, []} ->
                    topic_reply(effective_topic(Channel), Client, Server);
                {false, true, [_ | _]} when is_map_key($t, Flags), not Operator ->
                    briskd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    );
                {false, true, [Text | _]} ->
                    UpdatedTopic = Channel#channel{
                        topic = briskd_wire:retain(Text),
                        topic_by = iolist_to_binary(channel_origin_prefix(Channel, Client)),
                        topic_at = erlang:system_time(second)
                    },
                    mnesia:dirty_write(UpdatedTopic),
                    briskd_state_link:note_local_channel(UpdatedTopic),
                    {TopicTags, TopicMeta} = briskd_state_history:event_tags(),
                    briskd_state_history:note_event(
                        Channel#channel.key,
                        <<"TOPIC">>,
                        channel_origin_prefix(Channel, Client),
                        [],
                        Text,
                        TopicMeta
                    ),
                    briskd_state_send:broadcast(
                        maps:keys(Members),
                        channel_origin_prefix(Channel, Client),
                        <<"TOPIC">>,
                        [Canonical],
                        Text,
                        TopicTags
                    ),
                    briskd_state_link:propagate_topic(Client, Canonical, Text)
            end;
        [] ->
            case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
                [#remote_channel{name = Canonical, flags = RemoteFlags}] ->
                    case {maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags), Rest} of
                        {true, _} ->
                            briskd_state_send:numeric(
                                Client, Server, <<"403">>, [Canonical], <<"No such channel">>
                            );
                        {false, []} ->
                            topic_reply(
                                #channel{
                                    key = briskd_wire:fold(Canonical),
                                    name = Canonical,
                                    topic = maps:get(topic, RemoteFlags, <<>>)
                                },
                                Client,
                                Server
                            );
                        {false, [_ | _]} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"442">>,
                                [Canonical],
                                <<"You're not on that channel">>
                            )
                    end;
                [] ->
                    briskd_state_send:numeric(
                        Client, Server, <<"403">>, [Name], <<"No such channel">>
                    )
            end
    end.

effective_topic(#channel{name = Name, topic = <<>>} = Channel) ->
    case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
        [#remote_channel{flags = RemoteFlags}] ->
            Channel#channel{topic = maps:get(topic, RemoteFlags, <<>>)};
        [] ->
            Channel
    end;
effective_topic(Channel) ->
    Channel.

join_topic(Channel, Client, Server) ->
    case effective_topic(Channel) of
        #channel{topic = <<>>} -> ok;
        WithTopic -> topic_reply(WithTopic, Client, Server)
    end.

topic_reply(#channel{name = Name, topic = <<>>}, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"331">>, [Name], <<"No topic is set">>);
topic_reply(#channel{name = Name, topic = Topic} = Channel, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"332">>, [Name], Topic),
    By =
        case Channel#channel.topic_by of
            undefined -> Server;
            Setter -> Setter
        end,
    At =
        case {Channel#channel.topic_at, Channel#channel.created} of
            {undefined, undefined} -> persistent_term:get({briskd_state, started_at_system}, 0);
            {undefined, Created} -> Created;
            {Time, _} -> Time
        end,
    briskd_state_send:numeric(Client, Server, <<"333">>, [Name, By, integer_to_binary(At)], none).

-doc """
Handle `NAMES` for one channel (RFC 2812 section 3.2.5).

Sends 353 RPL_NAMREPLY lines with local and remote members, sorted under the
RFC 1459 case mapping, then 366 RPL_ENDOFNAMES. A `+p` or `+s` channel the
requester is not on lists nobody; an anonymous `+a` channel lists only the
requester; members with `+i` are listed only to requesters sharing a channel.
Prefixes follow `multi-prefix`, and `userhost-in-names` adds `!user@host`.
An unknown channel still gets 366.
""".
-spec names(binary(), #client{}, binary()) -> ok.
names(Name, Client, Server) ->
    Canonical =
        case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
            [#channel{name = Existing, members = Members, flags = Flags}] ->
                LocalMember = maps:is_key(Client#client.pid, Members),
                RemoteFlags = briskd_state_link:remote_channel_flags(Name),
                Hidden =
                    (not LocalMember andalso
                        (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))) orelse
                        (not LocalMember andalso
                            (maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags))),
                case Hidden of
                    true ->
                        ok;
                    false ->
                        VisiblePids =
                            case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                                true ->
                                    case maps:is_key(Client#client.pid, Members) of
                                        true -> [Client#client.pid];
                                        false -> []
                                    end;
                                false ->
                                    maps:keys(Members)
                            end,
                        LocalEntries = [
                            display_nick(
                                briskd_state_client:client(Pid), maps:get(Pid, Members), Client
                            )
                         || Pid <- VisiblePids,
                            visible_member(Pid, Client, Members)
                        ],
                        RemoteEntries =
                            case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                                true ->
                                    [];
                                false ->
                                    briskd_state_link:remote_names_entries(
                                        Name, Client, LocalMember
                                    )
                            end,
                        Entries = lists:usort(fun nick_less/2, LocalEntries ++ RemoteEntries),
                        names_lines(Entries, [], 0, Existing, Client, Server)
                end,
                Existing;
            [] ->
                case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
                    [#remote_channel{name = Existing, flags = Flags}] ->
                        case
                            maps:is_key($p, Flags) orelse maps:is_key($s, Flags) orelse
                                maps:is_key($a, Flags)
                        of
                            true ->
                                ok;
                            false ->
                                names_lines(
                                    briskd_state_link:remote_names_entries(Name, Client, false),
                                    [],
                                    0,
                                    Existing,
                                    Client,
                                    Server
                                )
                        end,
                        Existing;
                    [] ->
                        Name
                end
        end,
    briskd_state_send:numeric(Client, Server, <<"366">>, [Canonical], <<"End of NAMES list">>).

-doc """
Send the 353 RPL_NAMREPLY lines for one local channel in an argument-less `NAMES`.

`Key` is the folded channel name. Applies the same visibility rules as
`names/3` but sends nothing for hidden channels and no 366; the caller ends
the listing.
""".
-spec names_listing(binary(), #client{}, binary()) -> ok.
names_listing(Key, Client, Server) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Name, members = Members, flags = Flags}] ->
            RemoteFlags = briskd_state_link:remote_channel_flags(Name),
            LocalMember = maps:is_key(Client#client.pid, Members),
            Visible =
                LocalMember orelse
                    not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags) orelse
                        maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags)),

            case Visible of
                true ->
                    VisiblePids =
                        case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                            true ->
                                case maps:is_key(Client#client.pid, Members) of
                                    true -> [Client#client.pid];
                                    false -> []
                                end;
                            false ->
                                maps:keys(Members)
                        end,
                    LocalEntries = [
                        display_nick(
                            briskd_state_client:client(Pid), maps:get(Pid, Members), Client
                        )
                     || Pid <- VisiblePids,
                        visible_member(Pid, Client, Members)
                    ],
                    RemoteEntries =
                        case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                            true ->
                                [];
                            false ->
                                briskd_state_link:remote_names_entries(Name, Client, LocalMember)
                        end,
                    Entries = lists:usort(fun nick_less/2, LocalEntries ++ RemoteEntries),
                    names_lines(Entries, [], 0, Name, Client, Server);
                false ->
                    ok
            end;
        [] ->
            ok
    end.

nick_less(Left, Right) -> briskd_wire:fold(Left) =< briskd_wire:fold(Right).

-doc """
List visible registered local users who are on no channel, under the `*` channel.

Part of an argument-less `NAMES`. A user who is only on secret or private
channels is not listed. Sends 353 RPL_NAMREPLY lines only.
""".
-spec names_unattached(#client{}, binary()) -> ok.
names_unattached(#client{pid = RequesterPid}, Server) ->
    Requester = briskd_state_client:client(RequesterPid),
    Entries = lists:sort([
        Member#client.nick
     || Pid <- briskd_state_client:pids(),
        [#client{} = Member] <- [mnesia:dirty_read(client, Pid)],
        briskd_state_client:ready(Member),
        briskd_state_client:user_visible(Member, Requester),
        %% Only users on no channel are listed under `*`; a user who is only
        %% in secret or private channels is not revealed.
        Member#client.channels =:= []
    ]),
    names_lines(Entries, [], 0, <<"*">>, Requester, Server).

-doc """
True when channel member `Pid` may be listed to `Requester`.

`Members` is the channel's local member map. A requester on the channel sees
every member; otherwise the rule of `briskd_state_client:user_visible/2`
applies.
""".
-spec visible_member(pid(), #client{}, #{pid() => [channel_role()]}) -> boolean().
visible_member(Pid, Requester, Members) ->
    maps:is_key(Requester#client.pid, Members) orelse
        case mnesia:dirty_read(client, Pid) of
            [#client{} = Member] -> briskd_state_client:user_visible(Member, Requester);
            [] -> false
        end.

-doc """
Send `Entries` as 353 RPL_NAMREPLY lines for channel `Name`.

Call with an empty accumulator and size 0. Entries are packed until a line
would carry about 370 octets of names, so each reply stays under the
512-octet line limit. The channel symbol is `@` for `+s`, `*` for `+p`
(including flags reported by peers), and `=` otherwise. Sends nothing for an
empty list.
""".
-spec names_lines([binary()], [binary()], non_neg_integer(), binary(), #client{}, binary()) -> ok.
names_lines([], [], _, _, _, _) ->
    ok;
names_lines([], Acc, _, Name, Client, Server) ->
    briskd_state_send:numeric(
        Client,
        Server,
        <<"353">>,
        [names_symbol(Name), Name],
        lists:join(<<" ">>, lists:reverse(Acc))
    );
names_lines([Entry | Rest], Acc, Size, Name, Client, Server) when Size + byte_size(Entry) < 370 ->
    names_lines(Rest, [Entry | Acc], Size + byte_size(Entry) + 1, Name, Client, Server);
names_lines(Entries, Acc, _, Name, Client, Server) ->
    names_lines([], Acc, 0, Name, Client, Server),
    names_lines(Entries, [], 0, Name, Client, Server).

names_symbol(<<"*">>) ->
    <<"*">>;
names_symbol(Name) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{flags = Flags}] when is_map_key($s, Flags) -> <<"@">>;
        [#channel{flags = Flags}] when is_map_key($p, Flags) -> <<"*">>;
        _ ->
            case briskd_state_link:remote_channel_flags(Name) of
                Flags when is_map_key($s, Flags) -> <<"@">>;
                Flags when is_map_key($p, Flags) -> <<"*">>;
                _ -> <<"=">>
            end
    end.

%% NAMES entry for a local member as seen by Requester: multi-prefix shows
%% every status prefix and userhost-in-names adds `!user@host`.
display_nick(#client{nick = Nick, user = User, host = Host}, Roles, #client{pid = Requester}) ->
    Name =
        case briskd_cap:enabled(Requester, <<"userhost-in-names">>) of
            true -> <<Nick/binary, "!", User/binary, "@", Host/binary>>;
            false -> Nick
        end,
    <<(role_prefix(Roles, Requester))/binary, Name/binary>>.

-doc """
Status prefix for a member's channel roles as shown to `Requester`.

With `multi-prefix` the requester sees every prefix in rank order (`@+`),
otherwise only the highest. `creator` is shown as `@`.
""".
-spec role_prefix([atom()], pid()) -> binary().
role_prefix(Roles, Requester) ->
    Operator = lists:member(operator, Roles) orelse lists:member(creator, Roles),
    Voice = lists:member(voice, Roles),
    case {Operator, Voice, briskd_cap:enabled(Requester, <<"multi-prefix">>)} of
        {true, true, true} -> <<"@+">>;
        {true, _, _} -> <<"@">>;
        {false, true, _} -> <<"+">>;
        _ -> <<>>
    end.

-doc """
True when a local or remote user matches the channel's ban, exception, or invite list.

A plain mask is matched with `wildcard_match/2` against `nick!user@host`.
The IRCv3 account extban (advertised as `EXTBAN=$,a` and `ACCOUNTEXTBAN=a`)
is also supported: `$a:<account mask>` matches a logged-in user by account
name, and `$a` alone matches any logged-in user.
""".
-spec mask_matches(#channel{}, ban | exception | invite, #client{} | #remote_client{}) ->
    boolean().
mask_matches(Channel, Type, #client{pid = Pid, nick = Nick, user = User, host = Host}) ->
    identity_matches(Channel, Type, Nick, User, Host, fun() -> briskd_state_v3:account(Pid) end);
mask_matches(Channel, Type, #remote_client{key = Key, nick = Nick, user = User, host = Host}) ->
    identity_matches(Channel, Type, Nick, User, Host, fun() ->
        briskd_state_v3:remote_account(Key)
    end).

identity_matches(#channel{lists = Lists}, Type, Nick, User, Host, Account) ->
    Identity = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
    lists:any(
        fun
            (<<"$a:", AccountMask/binary>>) ->
                case Account() of
                    undefined -> false;
                    Name -> wildcard_match(AccountMask, Name)
                end;
            (<<"$a">>) ->
                Account() =/= undefined;
            (Mask) ->
                wildcard_match(Mask, Identity)
        end,
        maps:get(Type, Lists, [])
    ).

-doc """
Match an IRC mask (`*` any run, `?` one octet) against a value under
the RFC 1459 case mapping.

On a mismatch the scan resumes from the most recent `*`, so the cost is
O(byte_size(Mask) * byte_size(Value)) even for hostile masks such as
`*a*a*a*a*b` (no exponential backtracking).
""".
-spec wildcard_match(binary(), binary()) -> boolean().
wildcard_match(Mask, Value) ->
    glob(briskd_wire:fold(Mask), briskd_wire:fold(Value), none).

glob(<<>>, <<>>, _Star) ->
    true;
glob(<<$*, Mask/binary>>, Value, _Star) ->
    glob(Mask, Value, {Mask, Value});
glob(<<$?, Mask/binary>>, <<_, Value/binary>>, Star) ->
    glob(Mask, Value, Star);
glob(<<Char, Mask/binary>>, <<Char, Value/binary>>, Star) ->
    glob(Mask, Value, Star);
glob(_Mask, _Value, {StarMask, <<_, StarValue/binary>>}) ->
    glob(StarMask, StarValue, {StarMask, StarValue});
glob(_Mask, _Value, _Star) ->
    false.

-doc """
Handle `KNOCK <channel> [<message>]`: ask the operators of an invite-only channel for an invite.

`ReasonParams` holds the optional message. An unknown channel gets 403
ERR_NOSUCHCHANNEL and a member 714 ERR_KNOCKONCHAN. A channel with no `+i`,
`+k`, `+l`, or `+K` gets 713 ERR_CHANOPEN. A channel with `+K` (no knock), one
that is `+k` or `+l` but not `+i`, or one without a local operator gets 480
with a matching text. 713 and 714 are the numerics common briskds use for
`KNOCK`; they are not assigned by RFC 2812.
Otherwise the local channel operators receive `KNOCK <channel> :<message>`
from the requester.
""".
-spec knock(binary(), [binary()], #client{}, binary()) -> ok.
knock(Name, ReasonParams, #client{pid = Pid} = Client, Server) ->
    Reason =
        case ReasonParams of
            [Text | _] -> Text;
            [] -> <<>>
        end,
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        [#channel{name = Canonical, members = Members, flags = Flags} = Channel] ->
            Open =
                Channel#channel.password =:= undefined andalso
                    Channel#channel.limit =:= undefined,
            case maps:is_key(Pid, Members) of
                true ->
                    briskd_state_send:numeric(
                        Client, Server, <<"714">>, [Canonical], <<"You're already on that channel">>
                    );
                false ->
                    case {maps:is_key($K, Flags), maps:is_key($i, Flags)} of
                        {false, false} when Open ->
                            briskd_state_send:numeric(
                                Client, Server, <<"713">>, [Canonical], <<"Channel is open">>
                            );
                        {true, _} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"480">>,
                                [Canonical],
                                <<"Cannot knock on channel">>
                            );
                        {false, false} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"480">>,
                                [Canonical],
                                <<"Channel is not invite-only">>
                            );
                        {false, true} ->
                            Operators = [
                                MemberPid
                             || MemberPid := Roles <- Members, lists:member(operator, Roles)
                            ],
                            case Operators of
                                [] ->
                                    briskd_state_send:numeric(
                                        Client,
                                        Server,
                                        <<"480">>,
                                        [Canonical],
                                        <<"No channel operators available">>
                                    );
                                _ ->
                                    briskd_state_send:broadcast(
                                        Operators,
                                        channel_origin_prefix(Channel, Client),
                                        <<"KNOCK">>,
                                        [Canonical],
                                        Reason
                                    ),
                                    ok
                            end
                    end
            end
    end.

-doc """
Handle `INVITE <nick> <channel>` (RFC 2812 section 3.2.7).

A local user still registering, or an unknown nickname, gets 401
ERR_NOSUCHNICK. For a local target: an existing channel requires that the
target is not already on it (443 ERR_USERONCHANNEL), that the inviter is on it
(442 ERR_NOTONCHANNEL), and, with `+i`, that the inviter is an operator (482
ERR_CHANOPRIVSNEEDED); the invite is then remembered on the channel and
`invite-notify` members are told. The inviter gets 341 RPL_INVITING (and 301
RPL_AWAY for an away target) and the target receives `INVITE`. An invite to a
channel that does not exist is delivered without checks. A remote target
requires an existing local channel (403 otherwise) and the same membership and
operator checks; the invite is remembered and forwarded to the target's link.
""".
-spec invite(binary(), binary(), #client{}, binary()) -> ok.
invite(Nick, Name, #client{pid = Pid} = Client, Server) ->
    Found =
        case briskd_state_client:find_nick(Nick) of
            #client{} = Local ->
                case briskd_state_client:ready(Local) of
                    true -> Local;
                    false -> held
                end;
            undefined ->
                undefined
        end,
    case Found of
        held ->
            briskd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>);
        undefined ->
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
                [#remote_client{} = Remote] ->
                    invite_remote(Remote, Name, Client, Server);
                [] ->
                    briskd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>)
            end;
        #client{} = Target ->
            case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
                [] ->
                    notify_invite(Target, Name, Client, Server);
                [
                    #channel{
                        name = Canonical,
                        members = Members,
                        flags = Flags,
                        invited = Invited
                    } = Channel
                ] ->
                    IsMember = maps:is_key(Pid, Members),
                    IsOperator = lists:member(operator, maps:get(Pid, Members, [])),
                    case
                        {
                            maps:is_key(Target#client.pid, Members),
                            IsMember,
                            maps:is_key($i, Flags) andalso not IsOperator
                        }
                    of
                        {true, _, _} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"443">>,
                                [Target#client.nick, Canonical],
                                <<"is already on channel">>
                            );
                        {false, false, _} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"442">>,
                                [Canonical],
                                <<"You're not on that channel">>
                            );
                        {false, true, true} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"482">>,
                                [Canonical],
                                <<"You're not channel operator">>
                            );
                        {false, true, false} ->
                            AliveInvited = [P || P <- Invited, is_process_alive(P)],
                            mnesia:dirty_write(Channel#channel{
                                invited =
                                    lists:usort([Target#client.pid | AliveInvited])
                            }),
                            note_invited(Target#client.pid, Channel#channel.key),
                            notify_invite(Target, Canonical, Client, Server),
                            briskd_state_v3:invite_notify(
                                Channel,
                                Target,
                                Target#client.nick,
                                {Pid, invite_origin_prefix(Canonical, Client)}
                            )
                    end
            end
    end.

invite_remote(
    #remote_client{nick = RemoteNick, peer = Dest},
    Name,
    #client{pid = Pid} = Client,
    Server
) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        [#channel{name = Canonical, members = Members, flags = Flags}] ->
            IsMember = maps:is_key(Pid, Members),
            IsOperator = lists:member(operator, maps:get(Pid, Members, [])),
            case {IsMember, maps:is_key($i, Flags) andalso not IsOperator} of
                {false, _} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                {true, true} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    );
                {true, false} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"341">>, [RemoteNick, Canonical], none
                    ),
                    briskd_state_link:propagate_invite(Client, RemoteNick, Canonical, Dest)
            end
    end.

notify_invite(
    #client{pid = TargetPid, nick = TargetNick, away = Away},
    Channel,
    Client,
    Server
) ->
    briskd_state_send:numeric(Client, Server, <<"341">>, [TargetNick, Channel], none),
    briskd_state_send:send(
        TargetPid, invite_origin_prefix(Channel, Client), <<"INVITE">>, [TargetNick, Channel], none
    ),
    case Away of
        undefined -> ok;
        _ -> briskd_state_send:numeric(Client, Server, <<"301">>, [TargetNick], Away)
    end.

invite_origin_prefix(Channel, Client) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Channel)) of
        [#channel{} = Record] -> channel_origin_prefix(Record, Client);
        [] -> briskd_state_send:prefix(Client)
    end.

-doc """
Handle `MODE` for a channel or for the requester's own user modes.

A target that is a valid channel name is handled as a channel mode (RFC 2812
section 3.2.3); otherwise as a user mode (section 3.1.5).

User modes: an unknown nickname gets 401, another user 502
ERR_USERSDONTMATCH, and no mode string 221 RPL_UMODEIS. `i`, `w`, and `B` can
be set and cleared; `-o` drops operator (and administrator) status; `+o` gets
481 ERR_NOPRIVILEGES (operator status comes only from `OPER`); other letters
get 501 ERR_UMODEUNKNOWNFLAG. Each change is echoed to the user and
propagated to peers.

Channel modes: an unknown channel gets 403. A bare `b`, `e`, or `I` (with or
without `+`) lists the ban (367/368), exception (348/349), or invite
(346/347) list; the exception and invite lists require channel operator
status (482), and a non-member of a `+s` or `+p` channel sees an empty ban
list. No mode string
replies with 324 RPL_CHANNELMODEIS (the key only to members) and 329
RPL_CREATIONTIME. Changes require operator or creator status (482
ERR_CHANOPRIVSNEEDED) and are applied letter by letter: `+r` and `+a` on a
safe channel need the creator, `+a` exists only on `&` and `!` channels and
`+r` only on `!` channels (472 otherwise), `q` is server-only (481), an
invalid key or limit gets 696 ERR_INVALIDMODEPARAM, a full list 478
ERR_BANLISTFULL, a missing argument 461, `+o`/`+v` on a non-member 441 or
401, and an unknown letter 472 ERR_UNKNOWNMODE. `+o`/`+v` on a member of the
channel that is on another server updates its roles in the `remote_channel`
row. Applied changes are announced
as one `MODE` line to members, recorded in history (except key changes), and
propagated to peers.
""".
-spec mode_command(binary(), [binary()], #client{}, binary()) -> ok.
mode_command(Target, Rest, Client, Server) ->
    case briskd_wire:channel(Target) of
        true -> channel_mode(Target, Rest, Client, Server);
        false -> user_mode(Target, Rest, Client, Server)
    end.

user_mode(Target, Rest, #client{pid = Pid} = Client, Server) ->
    case briskd_state_client:find_nick(Target) of
        undefined ->
            briskd_state_send:numeric(
                Client, Server, <<"401">>, [Target], <<"No such nick/channel">>
            );
        #client{pid = Other} when Other =/= Pid ->
            briskd_state_send:numeric(
                Client, Server, <<"502">>, [], <<"Cannot change mode for other users">>
            );
        #client{nick = Nick} ->
            Modes = briskd_state_client:user_modes(Pid),
            case Rest of
                [] ->
                    briskd_state_send:numeric(
                        Client, Server, <<"221">>, [user_mode_string(Modes)], none
                    );
                [ModeSpec | _] ->
                    change_user_modes(
                        binary_to_list(ModeSpec),
                        undefined,
                        Modes,
                        Nick,
                        Client,
                        Server
                    )
            end
    end.

-doc """
Format a user-mode map as `+` followed by the sorted mode letters.
""".
-spec user_mode_string(map()) -> binary().
user_mode_string(Modes) ->
    list_to_binary([$+ | lists:sort(maps:keys(Modes))]).

change_user_modes([], _, Modes, _, Client, _Server) ->
    mnesia:dirty_write(#user_modes{pid = Client#client.pid, modes = Modes});
change_user_modes([$+ | Rest], _, Modes, Nick, Client, Server) ->
    change_user_modes(Rest, add, Modes, Nick, Client, Server);
change_user_modes([$- | Rest], _, Modes, Nick, Client, Server) ->
    change_user_modes(Rest, remove, Modes, Nick, Client, Server);
change_user_modes([_Mode | Rest], undefined, Modes, Nick, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"501">>, [], <<"Unknown MODE flag">>),
    change_user_modes(Rest, undefined, Modes, Nick, Client, Server);
change_user_modes([Mode | Rest], Action, Modes, Nick, Client, Server) when
    Mode =:= $i; Mode =:= $w; Mode =:= $B
->
    New =
        case Action of
            add -> Modes#{Mode => true};
            remove -> maps:remove(Mode, Modes)
        end,
    case New =/= Modes of
        true ->
            mnesia:dirty_write(#user_modes{pid = Client#client.pid, modes = New}),
            briskd_population:on_local_mode_change(
                Client#client.pid, briskd_state_client:ready(Client), New
            ),
            Sign =
                case Action of
                    add -> $+;
                    remove -> $-
                end,
            briskd_state_send:send(
                Client#client.pid,
                briskd_state_send:prefix(Client),
                <<"MODE">>,
                [Nick, <<Sign, Mode>>],
                none
            ),
            briskd_state_link:server_broadcast(
                briskd_wire:line(
                    briskd_state_send:prefix(Client), <<"MODE">>, [Nick, <<Sign, Mode>>], none
                )
            );
        false ->
            ok
    end,
    change_user_modes(Rest, Action, New, Nick, Client, Server);
%% RFC 2812 3.1.5: a user may de-op themselves; +o only comes from OPER.
%% Losing +o also ends administrator status.
change_user_modes([$o | Rest], remove, Modes, Nick, #client{pid = Pid} = Client, Server) ->
    New = maps:remove($o, Modes),
    case New =/= Modes of
        true ->
            mnesia:dirty_write(#user_modes{pid = Pid, modes = New}),
            _ = ets:whereis(briskd_admins) =/= undefined andalso ets:delete(briskd_admins, Pid),
            briskd_population:on_local_mode_change(Pid, briskd_state_client:ready(Client), New),
            logger:info(#{event => oper_dropped, nick => Nick}),
            Prefix = briskd_state_send:prefix(Client),
            briskd_state_send:send(Pid, Prefix, <<"MODE">>, [Nick, <<"-o">>], none),
            briskd_state_link:server_broadcast(
                briskd_wire:line(Prefix, <<"MODE">>, [Nick, <<"-o">>], none)
            );
        false ->
            ok
    end,
    change_user_modes(Rest, remove, New, Nick, Client, Server);
change_user_modes([$o | Rest], Action, Modes, Nick, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>
    ),
    change_user_modes(Rest, Action, Modes, Nick, Client, Server);
change_user_modes([_Mode | Rest], Action, Modes, Nick, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"501">>, [], <<"Unknown MODE flag">>),
    change_user_modes(Rest, Action, Modes, Nick, Client, Server).

%% Query or update channel flags, lists, keys, limits, and member roles.
%% `MODE <channel> b` and `+b` (and `e`, `I`) without a mask list the entries.
channel_mode(Name, [Mode], #client{pid = Pid} = Client, Server) when
    Mode =:= <<"+b">>;
    Mode =:= <<"+e">>;
    Mode =:= <<"+I">>;
    Mode =:= <<"b">>;
    Mode =:= <<"e">>;
    Mode =:= <<"I">>
->
    Type =
        case Mode of
            <<"+b">> -> ban;
            <<"b">> -> ban;
            <<"+e">> -> exception;
            <<"e">> -> exception;
            <<"+I">> -> invite;
            <<"I">> -> invite
        end,
    list_mode(Type, Name, Pid, Client, Server);
channel_mode(Name, Rest, #client{pid = Pid} = Client, Server) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members} = Channel] ->
            %% Creator authority is per membership (AGENTS.md 8.3). A founder
            %% who has left keeps the creator field so a later rejoin still
            %% has it, but cannot change modes while absent.
            IsCreator =
                Channel#channel.creator =:= Pid andalso maps:is_key(Pid, Members),
            IsOperator = lists:member(operator, maps:get(Pid, Members, [])),
            case {Rest, IsOperator orelse IsCreator} of
                {[], _} ->
                    report_modes(Channel, Client, Server);
                {[Modes | Args], true} ->
                    %% Applied changes are collected and announced as one
                    %% MODE line, e.g. `MODE #chan -int` or `+ov a b`.
                    put(briskd_mode_changes, []),
                    try
                        change_modes(binary_to_list(Modes), add, Args, Channel, Client, Server)
                    after
                        announce_mode_changes(Channel, Client)
                    end;
                {_, false} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    )
            end;
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>)
    end.

%% List policy (implementation policy, see the module documentation): the ban
%% list is readable by anyone (RFC 2812 section 3.2.3), but a non-member of a
%% `+s` or `+p` channel gets only the end-of-list reply; the exception and
%% invite-exception lists need channel operator (482 ERR_CHANOPRIVSNEEDED).
list_mode(Type, Name, Pid, Client, Server) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, lists = Lists, flags = Flags}] ->
            Member = maps:is_key(Pid, Members),
            Operator = lists:member(operator, maps:get(Pid, Members, [])),
            Hidden = not Member andalso (maps:is_key($s, Flags) orelse maps:is_key($p, Flags)),
            case Type =:= ban orelse Operator of
                false ->
                    briskd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    );
                true ->
                    %% RFC 2812: bans 367/368, exceptions 348/349, invites 346/347.
                    {Item, End, Text} =
                        case Type of
                            ban ->
                                {<<"367">>, <<"368">>, <<"End of channel ban list">>};
                            exception ->
                                {<<"348">>, <<"349">>, <<"End of channel exception list">>};
                            invite ->
                                {<<"346">>, <<"347">>, <<"End of channel invite list">>}
                        end,
                    Entries =
                        case Hidden of
                            true -> [];
                            false -> maps:get(Type, Lists, [])
                        end,
                    lists:foreach(
                        fun(Entry) ->
                            briskd_state_send:numeric(
                                Client, Server, Item, [Canonical, Entry], none
                            )
                        end,
                        Entries
                    ),
                    briskd_state_send:numeric(Client, Server, End, [Canonical], Text)
            end;
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>)
    end.

report_modes(
    #channel{} = Channel,
    Client,
    Server
) ->
    report_modes_of(Channel, Client, Server).

report_modes_of(
    #channel{
        name = Name,
        flags = Flags,
        limit = Limit,
        password = Password,
        members = Members
    } = Channel,
    #client{pid = Pid} = Client,
    Server
) ->
    KeyFields =
        case Password of
            undefined ->
                {[], []};
            _ ->
                Display =
                    case maps:is_key(Pid, Members) of
                        true -> Password;
                        false -> <<"*">>
                    end,
                {"k", [Display]}
        end,
    LimitFields =
        case Limit of
            undefined -> {[], []};
            _ -> {"l", [integer_to_binary(Limit)]}
        end,
    {KeyMode, KeyArgs} = KeyFields,
    {LimitMode, LimitArgs} = LimitFields,
    Modes = list_to_binary([$+ | lists:sort(maps:keys(Flags)) ++ KeyMode ++ LimitMode]),
    briskd_state_send:numeric(
        Client, Server, <<"324">>, [Name, Modes | KeyArgs ++ LimitArgs], none
    ),
    %% RPL_CREATIONTIME (329). A row from before `created` existed reports
    %% the server start time.
    Created =
        case Channel#channel.created of
            undefined -> persistent_term:get({briskd_state, started_at_system}, 0);
            Seconds -> Seconds
        end,
    briskd_state_send:numeric(Client, Server, <<"329">>, [Name, integer_to_binary(Created)], none).

change_modes([], _, _, _, _, _) ->
    ok;
change_modes([$+ | Rest], _, Args, Channel, Client, Server) ->
    change_modes(Rest, add, Args, Channel, Client, Server);
change_modes([$- | Rest], _, Args, Channel, Client, Server) ->
    change_modes(Rest, remove, Args, Channel, Client, Server);
change_modes([Mode | Rest], Action, Args, Channel, Client, Server) ->
    #channel{name = Name, members = Members} = Channel,
    Authorized = mode_authorized(Mode, Action, Channel, Client),
    case {Mode, Authorized, apply_mode(Mode, Action, Args, Channel)} of
        {$q, _, _} ->
            briskd_state_send:numeric(
                Client,
                Server,
                <<"481">>,
                [],
                <<"Permission Denied- Quiet mode is server only">>
            ),
            change_modes(Rest, Action, Args, Channel, Client, Server);
        {_, false, _} ->
            briskd_state_send:numeric(
                Client, Server, <<"482">>, [Name], <<"You're not channel creator">>
            ),
            change_modes(Rest, Action, Args, Channel, Client, Server);
        {_, true, {ok, New, Tail, Parameters}} ->
            case New =/= Channel of
                true ->
                    mnesia:dirty_write(New),
                    Sign =
                        case Action of
                            add -> $+;
                            remove -> $-
                        end,
                    _ = {Name, Members},
                    put(briskd_mode_changes, [{Sign, Mode, Parameters} | get(briskd_mode_changes)]);
                false ->
                    ok
            end,
            change_modes(Rest, Action, Tail, New, Client, Server);
        {_, true, {remote, Updated, Tail, Parameters}} ->
            %% `+o`/`+v` on a member of another server: the role lives in the
            %% `remote_channel` row; the change is announced like a local one.
            case mnesia:dirty_read(remote_channel, Updated#remote_channel.key) of
                [#remote_channel{} = Updated] ->
                    ok;
                _ ->
                    mnesia:dirty_write(Updated),
                    Sign =
                        case Action of
                            add -> $+;
                            remove -> $-
                        end,
                    put(briskd_mode_changes, [{Sign, Mode, Parameters} | get(briskd_mode_changes)])
            end,
            change_modes(Rest, Action, Tail, Channel, Client, Server);
        {_, true, {error, Code, Params, Message, Tail}} ->
            briskd_state_send:numeric(Client, Server, Code, Params, Message),
            change_modes(Rest, Action, Tail, Channel, Client, Server)
    end.

%% A nickname that is not a local client, looked up as a member of the
%% channel `Name` on another server: `{ok, WireNick, RemoteChannel}`,
%% `not_on_channel` when the user exists elsewhere but is not in the channel,
%% or `no_such_nick`.
remote_target(NickKey, Name) ->
    case mnesia:dirty_read(remote_client, NickKey) of
        [] ->
            no_such_nick;
        [#remote_client{nick = Actual}] ->
            case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
                [#remote_channel{members = Remote} = RemoteChannel] when
                    is_map_key(NickKey, Remote)
                ->
                    {ok, Actual, RemoteChannel};
                _ ->
                    not_on_channel
            end
    end.

%% Announce the collected changes of one MODE command as a single line to
%% members, history, and peers. A change of the channel key keeps the line
%% out of history.
announce_mode_changes(#channel{key = Key, name = Name, members = Members} = Channel, Client) ->
    case lists:reverse(erase(briskd_mode_changes)) of
        [] ->
            ok;
        Changes ->
            {Letters, _} = lists:foldl(
                fun
                    ({Sign, Mode, _}, {Acc, Sign}) -> {[Mode | Acc], Sign};
                    ({Sign, Mode, _}, {Acc, _}) -> {[Mode, Sign | Acc], Sign}
                end,
                {[], none},
                Changes
            ),
            ModeString = list_to_binary(lists:reverse(Letters)),
            Params = lists:append([P || {_, _, P} <- Changes]),
            Origin = channel_origin_prefix(Channel, Client),
            {Tags, Meta} = briskd_state_history:event_tags(),
            briskd_state_send:broadcast(
                maps:keys(Members), Origin, <<"MODE">>, [Name, ModeString | Params], none, Tags
            ),
            case lists:keymember($k, 2, Changes) of
                true ->
                    ok;
                false ->
                    briskd_state_history:note_event(
                        Key, <<"MODE">>, Origin, [ModeString | Params], none, Meta
                    )
            end,
            briskd_state_link:propagate_channel_mode(Client, Name, ModeString, Params),
            %% Keep the peer's copy of this channel aligned with the row just
            %% written, so a later remote MODE cannot replace it with a
            %% partial flag map.
            case mnesia:dirty_read(channel, Key) of
                [#channel{} = Current] -> briskd_state_link:note_local_channel(Current);
                [] -> ok
            end
    end.

mode_authorized($r, _Action, #channel{name = <<$!, _/binary>>} = Channel, Client) ->
    Channel#channel.creator =:= Client#client.pid;
%% On other channel types +r and +a are not creator modes; apply_mode/4
%% answers them with 472 (RFC 2811 4.2.1 and 4.3).
mode_authorized($r, _Action, _, _) ->
    true;
mode_authorized($a, _Action, #channel{name = <<$!, _/binary>>} = Channel, Client) ->
    Channel#channel.creator =:= Client#client.pid;
mode_authorized($a, _Action, #channel{name = <<$&, _/binary>>}, _) ->
    true;
mode_authorized($a, _Action, _, _) ->
    true;
mode_authorized(_, _, _, _) ->
    true.

apply_mode(Mode, Action, Args, #channel{name = Name, lists = Lists} = Channel) when
    Mode =:= $b; Mode =:= $e; Mode =:= $I
->
    Type =
        case Mode of
            $b -> ban;
            $e -> exception;
            $I -> invite
        end,
    Existing = maps:get(Type, Lists, []),
    case Args of
        [Mask | Tail] when Action =:= add, length(Existing) >= ?MAX_LIST_ENTRIES ->
            case lists:member(Mask, Existing) of
                true ->
                    {ok, Channel, Tail, []};
                false ->
                    {error, <<"478">>, [Name, <<Mode>>], <<"Channel list is full">>, Tail}
            end;
        [Mask | Tail] ->
            StoredMask = briskd_wire:retain(Mask),
            NewList =
                case Action of
                    add -> lists:usort([StoredMask | Existing]);
                    remove -> lists:delete(Mask, Existing)
                end,
            {ok, Channel#channel{lists = Lists#{Type => NewList}}, Tail, [Mask]};
        [] ->
            {ok, Channel, [], []}
    end;
apply_mode($a, Action, Args, #channel{name = <<$&, _/binary>>, flags = Flags} = Channel) ->
    New =
        case Action of
            add -> Flags#{$a => true};
            remove -> maps:remove($a, Flags)
        end,
    {ok, Channel#channel{flags = New}, Args, []};
apply_mode($a, add, Args, #channel{name = <<$!, _/binary>>, flags = Flags} = Channel) ->
    {ok, Channel#channel{flags = Flags#{$a => true}}, Args, []};
apply_mode($a, remove, Args, #channel{name = <<$!, _/binary>>} = Channel) ->
    {error, <<"482">>, [Channel#channel.name], <<"Cannot unset anonymous mode on a safe channel">>,
        Args};
apply_mode($a, _, Args, _) ->
    {error, <<"472">>, [<<"a">>], <<"Anonymous mode is only available on local and safe channels">>,
        Args};
apply_mode($r, Action, Args, #channel{name = <<$!, _/binary>>, flags = Flags} = Channel) ->
    New =
        case Action of
            add -> Flags#{$r => true};
            remove -> maps:remove($r, Flags)
        end,
    {ok, Channel#channel{flags = New, opless_since = undefined}, Args, []};
apply_mode($r, _, Args, _) ->
    {error, <<"472">>, [<<"r">>], <<"Reop mode is only available on safe channels">>, Args};
apply_mode(Mode, Action, Args, #channel{flags = Flags} = Channel) when
    Mode =:= $i; Mode =:= $m; Mode =:= $n; Mode =:= $q; Mode =:= $t; Mode =:= $K
->
    New =
        case Action of
            add -> Flags#{Mode => true};
            remove -> maps:remove(Mode, Flags)
        end,
    {ok, Channel#channel{flags = New}, Args, []};
apply_mode(Mode, add, Args, #channel{flags = Flags} = Channel) when
    Mode =:= $p; Mode =:= $s
->
    Other =
        case Mode of
            $p -> $s;
            $s -> $p
        end,
    New = (maps:remove(Other, Flags))#{Mode => true},
    {ok, Channel#channel{flags = New}, Args, []};
apply_mode(Mode, remove, Args, #channel{flags = Flags} = Channel) when
    Mode =:= $p; Mode =:= $s
->
    {ok, Channel#channel{flags = maps:remove(Mode, Flags)}, Args, []};
apply_mode($l, remove, Args, Channel) ->
    {ok, Channel#channel{limit = undefined}, Args, []};
apply_mode($l, add, [Value | Args], Channel) ->
    case string:to_integer(Value) of
        {Limit, <<>>} when Limit > 0, Limit =< 2147483647 ->
            {ok, Channel#channel{limit = Limit}, Args, [integer_to_binary(Limit)]};
        %% ERR_INVALIDMODEPARAM (696): <channel> <mode> <param> :<reason>
        _ ->
            {error, <<"696">>, [Channel#channel.name, <<"l">>, param_token(Value)],
                <<"Invalid channel limit">>, Args}
    end;
apply_mode($k, add, [Key | Args], Channel) when byte_size(Key) > 0, byte_size(Key) =< 64 ->
    case binary:match(Key, [<<" ">>, <<",">>, <<":">>]) of
        nomatch -> {ok, Channel#channel{password = briskd_wire:retain(Key)}, Args, [Key]};
        _ -> invalid_key(Key, Args, Channel)
    end;
apply_mode($k, add, [Key | Args], Channel) ->
    invalid_key(Key, Args, Channel);
apply_mode($k, remove, [_ | Args], Channel) ->
    {ok, Channel#channel{password = undefined}, Args, [<<"*">>]};
apply_mode(Mode, Action, [Nick | Args], #channel{name = Name, members = Members} = Channel) when
    Mode =:= $o; Mode =:= $v
->
    Role =
        case Mode of
            $o -> operator;
            $v -> voice
        end,
    case briskd_state_client:find_nick(Nick) of
        #client{pid = Pid, nick = Actual} when is_map_key(Pid, Members) ->
            Roles = maps:get(Pid, Members),
            New =
                case Action of
                    add -> lists:usort([Role | Roles]);
                    remove -> lists:delete(Role, Roles)
                end,
            {ok, Channel#channel{members = Members#{Pid := New}}, Args, [Actual]};
        undefined ->
            NickKey = briskd_wire:fold(Nick),
            case remote_target(NickKey, Name) of
                no_such_nick ->
                    {error, <<"401">>, [Nick], <<"No such nick/channel">>, Args};
                not_on_channel ->
                    {error, <<"441">>, [Nick, Name], <<"They aren't on that channel">>, Args};
                {ok, Actual, #remote_channel{members = Remote} = RemoteChannel} ->
                    {Peer, Roles} = maps:get(NickKey, Remote),
                    New =
                        case Action of
                            add -> lists:usort([Role | Roles]);
                            remove -> lists:delete(Role, Roles)
                        end,
                    Updated = RemoteChannel#remote_channel{
                        members = Remote#{NickKey := {Peer, New}}
                    },
                    {remote, Updated, Args, [Actual]}
            end;
        _ ->
            {error, <<"441">>, [Nick, Name], <<"They aren't on that channel">>, Args}
    end;
apply_mode(Mode, _, [], _) when Mode =:= $k; Mode =:= $l; Mode =:= $o; Mode =:= $v ->
    {error, <<"461">>, [<<"MODE">>], <<"Not enough parameters">>, []};
apply_mode(Mode, _, Args, _) ->
    {error, <<"472">>, [<<Mode>>], <<"Unknown mode character">>, Args}.

-doc """
Create the empty channel `Name` with `Topic` for the admin panel
(`briskdctl create-channel`). `#`, `&`, and `+` channels only: a safe `!`
channel needs a creator. Like a channel created by `JOIN` it has no modes
(`+` channels get `+t`); empty, it is kept under `channels` retention until
`empty_channel_ttl` passes, as any channel its last member left.
""".
-spec admin_create(binary(), binary(), binary()) ->
    {ok, binary()} | {error, invalid_channel | channel_exists}.
admin_create(Name, Topic, Server) ->
    Key = briskd_wire:fold(Name),
    case briskd_wire:channel(Name) andalso binary:first(Name) =/= $! of
        false ->
            {error, invalid_channel};
        true ->
            case mnesia:dirty_read(channel, Key) of
                [_] ->
                    {error, channel_exists};
                [] ->
                    Now = erlang:system_time(second),
                    {TopicBy, TopicAt} =
                        case Topic of
                            <<>> -> {undefined, undefined};
                            _ -> {Server, Now}
                        end,
                    mnesia:dirty_write(#channel{
                        key = Key,
                        name = briskd_wire:retain(Name),
                        topic = briskd_wire:retain(Topic),
                        flags =
                            case binary:first(Name) of
                                $+ -> #{$t => true};
                                _ -> #{}
                            end,
                        created = Now,
                        topic_by = TopicBy,
                        topic_at = TopicAt
                    }),
                    briskd_population:on_channel_put(Key),
                    note_channel_empty(Key),
                    {ok, Name}
            end
    end.

-doc """
Remove the channel `Name` for the admin panel (`briskdctl delete-channel`):
every local member is kicked by the server with `Reason`, peers are told of
each kick, and the channel's row, history, and metadata are deleted. A
channel from the configuration file's `channels` is refused, since startup
and `REHASH` would create it again. Members on other servers stay in their
servers' copy of the channel. Returns the number of members kicked.
""".
-spec admin_destroy(binary(), binary(), binary()) ->
    {ok, binary(), non_neg_integer()} | {error, no_such_channel | predefined_channel}.
admin_destroy(Name, Reason, Server) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            {error, no_such_channel};
        [#channel{name = Canonical, members = Members} = Channel] ->
            case briskd_state:predefined_channel(Key) of
                true ->
                    {error, predefined_channel};
                false ->
                    Pids = maps:keys(Members),
                    Kicked = [
                        Client
                     || Pid <- Pids, [#client{} = Client] <- [mnesia:dirty_read(client, Pid)]
                    ],
                    lists:foreach(
                        fun(#client{nick = Nick} = Client) ->
                            briskd_state_send:broadcast(
                                Pids, Server, <<"KICK">>, [Canonical, Nick], Reason
                            ),
                            admin_propagate(
                                Canonical,
                                briskd_wire:line(Server, <<"KICK">>, [Canonical, Nick], Reason)
                            ),
                            mnesia:dirty_write(Client#client{
                                channels = lists:delete(Key, Client#client.channels)
                            })
                        end,
                        Kicked
                    ),
                    drop_channel_row(Channel),
                    {ok, Canonical, length(Kicked)}
            end
    end.

-doc """
Apply the channel modes `ModeString` with `Args` to `Name` as the server,
for the admin panel (`briskdctl set-channel-modes`): the same modes and checks
as `MODE` from a channel operator (`apply_mode/4`), plus the server-only
quiet mode `q`. The changes that applied are announced to members with the
server as the source, recorded in history (not a key change), and sent to
peers. Returns the channel's name, the applied mode string, its parameters
with a channel key shown as `*`, and the reasons of modes that did not
apply.
""".
-spec admin_mode(binary(), binary(), [binary()], binary()) ->
    {ok, binary(), binary(), [binary()], [binary()]} | {error, no_such_channel}.
admin_mode(Name, ModeString, Args, Server) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            {error, no_such_channel};
        [#channel{name = Canonical} = Channel] ->
            {Final, Changes, Errors} = admin_modes(
                binary_to_list(ModeString), add, Args, Channel, [], []
            ),
            case Final =/= Channel of
                true -> mnesia:dirty_write(Final);
                false -> ok
            end,
            {Applied, Params} = mode_line(Changes),
            case Changes of
                [] ->
                    ok;
                _ ->
                    #channel{members = Members} = Final,
                    {Tags, Meta} = briskd_state_history:event_tags(),
                    briskd_state_send:broadcast(
                        maps:keys(Members),
                        Server,
                        <<"MODE">>,
                        [Canonical, Applied | Params],
                        none,
                        Tags
                    ),
                    case lists:keymember($k, 2, Changes) of
                        true ->
                            ok;
                        false ->
                            briskd_state_history:note_event(
                                Key, <<"MODE">>, Server, [Applied | Params], none, Meta
                            )
                    end,
                    admin_propagate(
                        Canonical,
                        briskd_wire:line(Server, <<"MODE">>, [Canonical, Applied | Params], none)
                    )
            end,
            Shown = lists:append([
                case M of
                    $k -> [<<"*">> || _ <- P];
                    _ -> P
                end
             || {_, M, P} <- Changes
            ]),
            {ok, Canonical, Applied, Shown, lists:reverse(Errors)}
    end.

admin_modes([], _Action, _Args, Channel, Changes, Errors) ->
    {Channel, lists:reverse(Changes), Errors};
admin_modes([$+ | Rest], _, Args, Channel, Changes, Errors) ->
    admin_modes(Rest, add, Args, Channel, Changes, Errors);
admin_modes([$- | Rest], _, Args, Channel, Changes, Errors) ->
    admin_modes(Rest, remove, Args, Channel, Changes, Errors);
admin_modes([Mode | Rest], Action, Args, Channel, Changes, Errors) ->
    Sign =
        case Action of
            add -> $+;
            remove -> $-
        end,
    case apply_mode(Mode, Action, Args, Channel) of
        {ok, New, Tail, Params} when New =:= Channel, Params =:= [] ->
            admin_modes(Rest, Action, Tail, Channel, Changes, Errors);
        {ok, New, Tail, Params} ->
            admin_modes(Rest, Action, Tail, New, [{Sign, Mode, Params} | Changes], Errors);
        {remote, Updated, Tail, Params} ->
            mnesia:dirty_write(Updated),
            admin_modes(Rest, Action, Tail, Channel, [{Sign, Mode, Params} | Changes], Errors);
        {error, _Code, _Params, Message, Tail} ->
            Error = <<Sign, Mode, ": ", Message/binary>>,
            admin_modes(Rest, Action, Tail, Channel, Changes, [Error | Errors])
    end.

%% An admin change reaches peers unless the channel is a local `&` channel
%% (RFC 2811 2.2: local to the server).
admin_propagate(<<$&, _/binary>>, _Line) -> ok;
admin_propagate(_Name, Line) -> briskd_state_link:server_broadcast(Line).

%% One mode string and its parameters for a list of {Sign, Mode, Params}.
mode_line(Changes) ->
    {Letters, _} = lists:foldl(
        fun
            ({Sign, Mode, _}, {Acc, Sign}) -> {[Mode | Acc], Sign};
            ({Sign, Mode, _}, {Acc, _}) -> {[Mode, Sign | Acc], Sign}
        end,
        {[], none},
        Changes
    ),
    {list_to_binary(lists:reverse(Letters)), lists:append([P || {_, _, P} <- Changes])}.

-doc """
Split a comma-separated parameter, dropping empty items.
""".
-spec split(binary()) -> [binary()].
split(Value) -> binary:split(Value, <<",">>, [global, trim_all]).

%% ERR_INVALIDMODEPARAM (696) for a channel key that is empty, too long, or
%% contains a space, comma, or colon. The key itself is not echoed.
invalid_key(_Key, Args, #channel{name = Name}) ->
    {error, <<"696">>, [Name, <<"k">>, <<"*">>], <<"Invalid channel key">>, Args}.

%% A mode parameter shown in a numeric must be one non-empty middle token.
param_token(Value) ->
    case
        Value =:= <<>> orelse binary:match(Value, [<<" ">>]) =/= nomatch orelse
            binary:first(Value) =:= $:
    of
        true -> <<"*">>;
        false -> Value
    end.

-doc """
Handle `RENAME <old> <new> [:reason]` (draft/channel-rename).

A channel operator may rename a local channel. The type prefix cannot
change, and safe `!` channels and channels shared with a server link cannot
be renamed (`FAIL RENAME CANNOT_RENAME`); a name already in use gives
`FAIL RENAME CHANNEL_NAME_IN_USE`. Errors: 461 without two parameters, 403
for an unknown channel, 442 for a non-member, and 482 for a non-operator.
The channel row, member channel lists, history, metadata, and read markers
move to the new key. `draft/channel-rename` clients see `RENAME`; other
members see `PART`, then `JOIN` with the topic and NAMES reply. A case-only
rename sends no fallback.
""".
-spec rename([binary()], #client{}, binary()) -> ok.
rename([Old, New | Rest], #client{pid = Pid} = Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> <<>>
        end,
    OldKey = briskd_wire:fold(Old),
    NewKey = briskd_wire:fold(New),
    case mnesia:dirty_read(channel, OldKey) of
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Old], <<"No such channel">>);
        [#channel{name = Canonical, members = Members} = Channel] ->
            Roles = maps:get(Pid, Members, undefined),
            CaseOnly = OldKey =:= NewKey,
            Shared =
                mnesia:dirty_read(remote_channel, OldKey) =/= [] orelse
                    mnesia:dirty_read(remote_channel, NewKey) =/= [],
            Taken =
                not CaseOnly andalso
                    (mnesia:dirty_read(channel, NewKey) =/= [] orelse
                        mnesia:dirty_read(remote_channel, NewKey) =/= []),
            case Roles of
                undefined ->
                    briskd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                _ ->
                    case lists:member(operator, Roles) of
                        false ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"482">>,
                                [Canonical],
                                <<"You're not channel operator">>
                            );
                        true ->
                            Valid =
                                briskd_wire:channel(New) andalso
                                    binary:first(New) =:= binary:first(Canonical) andalso
                                    binary:first(New) =/= $! andalso not Shared,
                            case {Valid, Taken} of
                                {false, _} ->
                                    briskd_state_send:fail(
                                        Pid,
                                        <<"RENAME">>,
                                        <<"CANNOT_RENAME">>,
                                        [Canonical, New],
                                        <<"The channel cannot be renamed">>
                                    );
                                {true, true} ->
                                    briskd_state_send:fail(
                                        Pid,
                                        <<"RENAME">>,
                                        <<"CHANNEL_NAME_IN_USE">>,
                                        [Canonical, New],
                                        <<"The channel name is already taken">>
                                    );
                                {true, false} ->
                                    apply_rename(Channel, New, Reason, Client, Server, CaseOnly)
                            end
                    end
            end
    end;
rename(_, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"RENAME">>], <<"Not enough parameters">>
    ).

apply_rename(
    #channel{key = OldKey, name = OldName, members = Members} = Channel,
    New,
    Reason,
    Client,
    Server,
    CaseOnly
) ->
    NewKey = briskd_wire:fold(New),
    Name = briskd_wire:retain(New),
    Renamed = Channel#channel{key = NewKey, name = Name},
    case CaseOnly of
        true ->
            mnesia:dirty_write(Renamed);
        false ->
            mnesia:dirty_delete(channel, OldKey),
            mnesia:dirty_write(Renamed),
            briskd_population:on_channel_delete(OldKey),
            briskd_population:on_channel_put(NewKey),
            lists:foreach(
                fun(Pid) ->
                    case mnesia:dirty_read(client, Pid) of
                        [#client{channels = Keys} = Member] ->
                            mnesia:dirty_write(Member#client{
                                channels = [
                                    case K of
                                        OldKey -> NewKey;
                                        _ -> K
                                    end
                                 || K <- Keys
                                ]
                            });
                        [] ->
                            ok
                    end
                end,
                maps:keys(Members)
            ),
            case mnesia:dirty_read(channel_history, OldKey) of
                [#channel_history{} = History] ->
                    mnesia:dirty_delete(channel_history, OldKey),
                    mnesia:dirty_write(History#channel_history{channel = NewKey});
                [] ->
                    ok
            end,
            briskd_state_meta:rename_channel(OldKey, NewKey),
            briskd_state_history:rename_markers(OldKey, NewKey),
            briskd_state_v3:rename_channel(OldKey, Name)
    end,
    logger:info(#{event => channel_renamed, actor => Client#client.nick}),
    Origin = channel_origin_prefix(Channel, Client),
    {Capable, Legacy} = lists:partition(
        fun(P) -> briskd_cap:enabled(P, <<"draft/channel-rename">>) end, maps:keys(Members)
    ),
    briskd_state_send:broadcast(Capable, Origin, <<"RENAME">>, [OldName, Name], Reason),
    case CaseOnly of
        true ->
            ok;
        false ->
            PartReason =
                case Reason of
                    <<>> -> none;
                    _ -> Reason
                end,
            lists:foreach(
                fun(Pid) ->
                    case mnesia:dirty_read(client, Pid) of
                        [#client{real = Real} = Member] when is_binary(Real) ->
                            Self = briskd_state_send:prefix(Member),
                            briskd_state_send:send(Pid, Self, <<"PART">>, [OldName], PartReason),
                            briskd_state_v3:join_broadcast(
                                [Pid],
                                Self,
                                Name,
                                briskd_state_v3:account(Pid),
                                Real
                            ),
                            join_topic(Renamed, Member, Server),
                            briskd_state_history:markread_on_join(Pid, Name, Server),
                            case briskd_cap:enabled(Pid, <<"no-implicit-names">>) of
                                true -> ok;
                                false -> names(Name, Member, Server)
                            end;
                        [] ->
                            ok
                    end
                end,
                Legacy
            )
    end,
    ok.
