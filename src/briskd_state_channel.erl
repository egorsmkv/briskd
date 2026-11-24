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
    join_topic/3,
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
-type body() :: briskd_channel_msg:body().
-export_type([body/0]).

-doc """
Store or delete a channel whose last local member has left.
""".
-spec release_if_empty(#channel{}, #{pid() => [channel_role()]}) -> ok.
release_if_empty(Channel, Remaining) ->
    briskd_channel_safe:release_if_empty(Channel, Remaining).

-doc """
Populate the `briskd_safe_channels` ETS short-name index from the stored
`channel` table. Called by `m:briskd_state` at startup.
""".
-spec index_safe_channels() -> ok.
index_safe_channels() ->
    briskd_channel_safe:index_safe_channels().

-doc """
Evict the oldest empty non-predefined channels (without remote members) when
their count exceeds `max_empty_channels` (default 1000).
""".
-spec prune_empty_channels() -> ok.
prune_empty_channels() ->
    briskd_channel_safe:prune_empty_channels().

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
""".
-spec grant_predefined_operator(#client{}, binary()) -> ok.
grant_predefined_operator(Client, Server) ->
    briskd_channel_mode:grant_predefined_operator(Client, Server).

-doc """
Set a channel's member map and maintain its operatorless deadline.
""".
-spec track_opless(#channel{}, #{pid() => [creator | member | operator | voice]}) -> #channel{}.
track_opless(Channel, Remaining) ->
    briskd_channel_safe:track_opless(Channel, Remaining).

-doc """
Reop safe channels whose operatorless deadline has passed (RFC 2811 section 3.2.3).
""".
-spec reop_channels(binary()) -> ok.
reop_channels(Server) ->
    briskd_channel_safe:reop_channels(Server).

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
    case briskd_channel_safe:resolve_channel(Name) of
        error ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        {ok, Canonical} ->
            Key = briskd_wire:fold(Canonical),
            case lists:member(Key, Client#client.channels) of
                true -> ok;
                false -> add_member(Key, Canonical, Client, Server, Password)
            end
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
    briskd_channel_safe:clear_channel_empty(Key),
    briskd_channel_safe:index_safe_channel(Canonical),
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
            case briskd_channel_mode:remote_target(NickKey, Canonical) of
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
    briskd_state_link:unindex_remote_member(NickKey, RemoteKey),
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

channel_origin_prefix(Channel, Client) ->
    briskd_channel_mode:channel_origin_prefix(Channel, Client).

-doc """
Route `PRIVMSG`, `NOTICE`, or `TAGMSG` to nicknames and channels (RFC 2812 section 3.3).
""".
-spec deliver(binary(), [binary()], #client{}, binary(), [{binary(), undefined | binary()}]) -> ok.
deliver(Command, Params, Client, Server, Tags) ->
    briskd_channel_msg:deliver(Command, Params, Client, Server, Tags).

-doc """
Deliver one message body to one target.
""".
-spec deliver_body(binary(), binary(), body(), #client{}, binary(), [
    {binary(), undefined | binary()}
]) -> ok.
deliver_body(Command, Target, Body, Client, Server, ClientTags) ->
    briskd_channel_msg:deliver_body(Command, Target, Body, Client, Server, ClientTags).

-doc """
Record a channel `PRIVMSG` or `NOTICE` accepted from a server peer; see `note_channel_history/5`.
""".
-spec note_channel_history(binary(), binary(), binary(), none | iodata()) -> ok.
note_channel_history(Key, Command, Prefix, Text) ->
    briskd_channel_msg:note_channel_history(Key, Command, Prefix, Text).

-doc """
Record a channel `PRIVMSG` or `NOTICE` accepted from a server peer.
""".
-spec note_channel_history(binary(), binary(), binary(), none | iodata(), [
    {binary(), undefined | binary()}
]) -> ok.
note_channel_history(Key, Command, Prefix, Text, Tags) ->
    briskd_channel_msg:note_channel_history(Key, Command, Prefix, Text, Tags).

replay_channel_history(Key, Name, Pid) ->
    briskd_state_history:replay_on_join(Key, Name, Pid).

-doc """
Handle `TOPIC <channel> [<topic>]` (RFC 2812 section 3.2.4).
""".
-spec topic(binary(), [binary()], #client{}, binary()) -> ok.
topic(Name, Rest, Client, Server) ->
    briskd_channel_names:topic(Name, Rest, Client, Server).

-doc "Send the channel topic on `JOIN` if set.".
-spec join_topic(#channel{}, #client{}, binary()) -> ok.
join_topic(Channel, Client, Server) ->
    briskd_channel_names:join_topic(Channel, Client, Server).

-doc """
Handle `NAMES` for one channel (RFC 2812 section 3.2.5).
""".
-spec names(binary(), #client{}, binary()) -> ok.
names(Name, Client, Server) ->
    briskd_channel_names:names(Name, Client, Server).

-doc """
Send the 353 RPL_NAMREPLY lines for one local channel in an argument-less `NAMES`.
""".
-spec names_listing(binary(), #client{}, binary()) -> ok.
names_listing(Key, Client, Server) ->
    briskd_channel_names:names_listing(Key, Client, Server).

-doc """
List visible registered local users who are on no channel, under the `*` channel.
""".
-spec names_unattached(#client{}, binary()) -> ok.
names_unattached(Client, Server) ->
    briskd_channel_names:names_unattached(Client, Server).

-doc """
True when channel member `Pid` may be listed to `Requester`.
""".
-spec visible_member(pid(), #client{}, #{pid() => [channel_role()]}) -> boolean().
visible_member(Pid, Requester, Members) ->
    briskd_channel_names:visible_member(Pid, Requester, Members).

-doc """
Send `Entries` as 353 RPL_NAMREPLY lines for channel `Name`.
""".
-spec names_lines([binary()], [binary()], non_neg_integer(), binary(), #client{}, binary()) -> ok.
names_lines(Entries, Acc, Size, Name, Client, Server) ->
    briskd_channel_names:names_lines(Entries, Acc, Size, Name, Client, Server).

-doc """
Status prefix for a member's channel roles as shown to `Requester`.
""".
-spec role_prefix([atom()], pid()) -> binary().
role_prefix(Roles, Requester) ->
    briskd_channel_mode:role_prefix(Roles, Requester).

-doc """
True when a local or remote user matches the channel's ban, exception, or invite list.
""".
-spec mask_matches(#channel{}, ban | exception | invite, #client{} | #remote_client{}) ->
    boolean().
mask_matches(Channel, Type, Subject) ->
    briskd_channel_mode:mask_matches(Channel, Type, Subject).

-doc """
Match an IRC mask (`*` any run, `?` one octet) against a value under
the RFC 1459 case mapping.
""".
-spec wildcard_match(binary(), binary()) -> boolean().
wildcard_match(Mask, Value) ->
    briskd_channel_mode:wildcard_match(Mask, Value).

-doc """
Handle `KNOCK <channel> [<message>]`: ask the operators of an invite-only channel for an invite.
""".
-spec knock(binary(), [binary()], #client{}, binary()) -> ok.
knock(Name, ReasonParams, Client, Server) ->
    briskd_channel_invite:knock(Name, ReasonParams, Client, Server).

-doc """
Handle `INVITE <nick> <channel>` (RFC 2812 section 3.2.7).
""".
-spec invite(binary(), binary(), #client{}, binary()) -> ok.
invite(Nick, Name, Client, Server) ->
    briskd_channel_invite:invite(Nick, Name, Client, Server).

-doc """
Handle `MODE` for a channel or for the requester's own user modes.
""".
-spec mode_command(binary(), [binary()], #client{}, binary()) -> ok.
mode_command(Target, Rest, Client, Server) ->
    briskd_channel_mode:mode_command(Target, Rest, Client, Server).

-doc """
Format a user-mode map as `+` followed by the sorted mode letters.
""".
-spec user_mode_string(map()) -> binary().
user_mode_string(Modes) ->
    briskd_channel_mode:user_mode_string(Modes).

-doc """
Create the empty channel `Name` with `Topic` for the admin panel
(`briskdctl create-channel`).
""".
-spec admin_create(binary(), binary(), binary()) ->
    {ok, binary()} | {error, invalid_channel | channel_exists}.
admin_create(Name, Topic, Server) ->
    briskd_channel_admin:admin_create(Name, Topic, Server).

-doc """
Remove the channel `Name` for the admin panel (`briskdctl delete-channel`).
""".
-spec admin_destroy(binary(), binary(), binary()) ->
    {ok, binary(), non_neg_integer()} | {error, no_such_channel | predefined_channel}.
admin_destroy(Name, Reason, Server) ->
    briskd_channel_admin:admin_destroy(Name, Reason, Server).

-doc """
Apply the channel modes `ModeString` with `Args` to `Name` as the server for
`briskdctl set-channel-modes`.
""".
-spec admin_mode(binary(), binary(), [binary()], binary()) ->
    {ok, binary(), binary(), [binary()], [binary()]} | {error, no_such_channel}.
admin_mode(Name, ModeString, Args, Server) ->
    briskd_channel_admin:admin_mode(Name, ModeString, Args, Server).

-doc """
Split a comma-separated parameter, dropping empty items.
""".
-spec split(binary()) -> [binary()].
split(Value) ->
    briskd_channel_msg:split(Value).

-doc """
Handle `RENAME <old> <new> [:reason]` (draft/channel-rename).
""".
-spec rename([binary()], #client{}, binary()) -> ok.
rename(Params, Client, Server) ->
    briskd_channel_admin:rename(Params, Client, Server).
