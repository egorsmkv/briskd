-module(briskd_link_channel).
-moduledoc """
Server-link channel membership, `NJOIN`/netjoin batching, `TOPIC`, `KICK`,
`INVITE`, remote `NAMES` queries, empty-channel sweeping, and outbound channel
propagation (RFC 2813).
""".
-export([
    ensure_remote_channel/2,
    flush_netjoin/1,
    import_remote_join/3,
    import_remote_njoin/3,
    note_local_channel/1,
    propagate_channel_kick/4,
    propagate_channel_lines/2,
    propagate_channel_mode/4,
    propagate_invite/4,
    propagate_join/3,
    propagate_topic/3,
    receive_remote_invite/4,
    receive_remote_kick/5,
    remote_channel_flags/1,
    remote_names_entries/3,
    remote_names_listing/3,
    remote_user_local_recipients/1,
    remote_user_visible_to_requester/3,
    remove_remote_channel_member/4,
    sweep_remote_channels/0,
    update_remote_topic/4
]).
-include("briskd_client.hrl").
-include("briskd_channel.hrl").
-include("briskd_remote.hrl").

-doc """
Apply a `TOPIC` update from `Peer` for channel `Name`.

Either a trusted server or a remote channel member (requiring `+o` when the
channel is `+t`) may change the topic. Stored on the remote channel and synced
to any local channel row.
""".
-spec update_remote_topic(binary(), binary(), binary(), binary()) ->
    ok
    | {error,
        invalid_channel
        | remote_topic_requires_operator
        | remote_user_not_on_channel
        | unknown_remote_channel
        | unknown_remote_source}.
update_remote_topic(Peer, Prefix, Name, Topic) ->
    Key = briskd_wire:fold(Name),
    case {shared_channel(Name), briskd_state_link:trusted_server(Peer, Prefix)} of
        {false, _} ->
            {error, invalid_channel};
        {true, true} ->
            store_remote_topic(Peer, Prefix, Key, Name, Topic);
        {true, false} ->
            case
                {
                    briskd_state_link:remote_source(Peer, Prefix),
                    mnesia:dirty_read(remote_channel, Key)
                }
            of
                {{ok, #remote_client{key = NickKey}}, [
                    #remote_channel{members = Members, flags = Flags}
                ]} ->
                    case Members of
                        #{NickKey := {Peer, Roles}} ->
                            Restricted = maps:is_key($t, Flags) orelse local_channel_mode(Key, $t),
                            case Restricted andalso not lists:member(operator, Roles) of
                                true -> {error, remote_topic_requires_operator};
                                false -> store_remote_topic(Peer, Prefix, Key, Name, Topic)
                            end;
                        #{} ->
                            {error, remote_user_not_on_channel}
                    end;
                {error, _} ->
                    {error, unknown_remote_source};
                {_, []} ->
                    {error, unknown_remote_channel}
            end
    end.

store_remote_topic(Peer, Prefix, Key, Name, Topic) ->
    Remote = ensure_remote_channel(Key, Name),
    Flags = (Remote#remote_channel.flags)#{topic => briskd_wire:retain(Topic)},
    mnesia:dirty_write(briskd_wire:retain_fields(Remote#remote_channel{flags = Flags})),
    briskd_population:on_channel_put(Key),
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Canonical, members = Members, flags = ChannelFlags} = Channel] ->
            mnesia:dirty_write(Channel#channel{topic = briskd_wire:retain(Topic)}),
            EventPrefix =
                case
                    maps:is_key($a, ChannelFlags) orelse
                        maps:is_key($a, Remote#remote_channel.flags)
                of
                    true -> <<"anonymous!anonymous@anonymous.">>;
                    false -> Prefix
                end,
            briskd_state_send:broadcast(
                maps:keys(Members), EventPrefix, <<"TOPIC">>, [Canonical], Topic
            );
        [] ->
            ok
    end,
    briskd_state_link:relay_except(Peer, briskd_wire:line(Prefix, <<"TOPIC">>, [Name], Topic)),
    ok.

local_channel_mode(Key, Mode) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{flags = Flags}] -> maps:is_key(Mode, Flags);
        [] -> false
    end.

%% `&` channels stay on this server (RFC 2811). Every other accepted channel
%% name is shared with peers.
shared_channel(Name) ->
    briskd_wire:channel(Name) andalso binary:first(Name) =/= $&.

-doc """
Open the `remote_channel` row for a shared channel, seeding modes from any
existing local `#channel{}` row.
""".
-spec ensure_remote_channel(binary(), binary()) -> #remote_channel{}.
ensure_remote_channel(Key, Name) ->
    case mnesia:dirty_read(remote_channel, Key) of
        [#remote_channel{} = Existing] -> Existing;
        [] -> #remote_channel{key = Key, name = Name, flags = local_remote_flags(Key)}
    end.

local_remote_flags(Key) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{} = Channel] -> remote_flags_from_local(Channel);
        [] -> #{}
    end.

remote_flags_from_local(#channel{
    flags = Flags, password = Password, limit = Limit, lists = Lists, topic = Topic
}) ->
    WithKey =
        case Password of
            undefined -> Flags;
            _ -> Flags#{key => Password}
        end,
    WithLimit =
        case Limit of
            undefined -> WithKey;
            _ -> WithKey#{limit => Limit}
        end,
    WithLists = maps:merge(WithLimit, maps:with([ban, exception, invite], Lists)),
    case Topic of
        <<>> -> WithLists;
        _ -> WithLists#{topic => Topic}
    end.

-doc """
Copy a local channel's modes, key, limit, lists, and topic onto its remote
row, when one exists.
""".
-spec note_local_channel(#channel{}) -> ok.
note_local_channel(#channel{key = Key} = Channel) ->
    case mnesia:dirty_read(remote_channel, Key) of
        [#remote_channel{} = Remote] ->
            mnesia:dirty_write(Remote#remote_channel{flags = remote_flags_from_local(Channel)}),
            ok;
        [] ->
            ok
    end.

-doc """
Import a peer's `NJOIN` burst line for channel `Name` (RFC 2813 section 4.2.2).
""".
-spec import_remote_njoin(binary(), binary(), binary()) ->
    ok
    | {error,
        empty_njoin | invalid_channel | remote_member_from_other_peer | unknown_remote_member}.
import_remote_njoin(Peer, Name, Members) ->
    case shared_channel(Name) of
        false ->
            {error, invalid_channel};
        true ->
            case parse_remote_members(Peer, binary:split(Members, <<$,>>, [global]), []) of
                {ok, Parsed} when Parsed =/= [] ->
                    Key = briskd_wire:fold(Name),
                    Existing = ensure_remote_channel(Key, Name),
                    Previous = Existing#remote_channel.members,
                    NewMembers = lists:foldl(
                        fun({NickKey, Roles}, Acc) -> Acc#{NickKey => {Peer, Roles}} end,
                        Previous,
                        Parsed
                    ),
                    mnesia:dirty_write(Existing#remote_channel{members = NewMembers}),
                    briskd_population:on_channel_put(Key),
                    Joined = [K || {K, _} <- Parsed, not maps:is_key(K, Previous)],
                    lists:foreach(
                        fun(K) -> briskd_state_link:index_remote_member(K, Key) end, Joined
                    ),
                    show_netjoin(Name, Joined, Peer),
                    briskd_state_link:relay_except(
                        Peer, briskd_wire:line(local_server(), <<"NJOIN">>, [Name], Members)
                    ),
                    ok;
                {ok, []} ->
                    {error, empty_njoin};
                {error, _} = Error ->
                    Error
            end
    end.

%% Members that arrive in a peer's burst are shown to local channel members as
%% JOINs inside one `netjoin` batch per burst (IRCv3 netsplit/netjoin batch
%% types).
show_netjoin(_Name, [], _Peer) ->
    ok;
show_netjoin(Name, Joined, Peer) ->
    Entry = [{Name, Key} || Key <- Joined],
    case ets:whereis(briskd_peer_batches) of
        undefined ->
            Pending =
                case get({briskd_netjoin, Peer}) of
                    undefined ->
                        erlang:send_after(1000, self(), {flush_netjoin, Peer}),
                        [];
                    List ->
                        List
                end,
            put({briskd_netjoin, Peer}, lists:reverse(Entry, Pending));
        _ ->
            Pending =
                case ets:lookup(briskd_peer_batches, {netjoin, Peer}) of
                    [] ->
                        erlang:send_after(1000, self(), {flush_netjoin, Peer}),
                        [];
                    [{_, List}] ->
                        List
                end,
            ets:insert(briskd_peer_batches, {{netjoin, Peer}, lists:reverse(Entry, Pending)})
    end,
    ok.

-doc """
Send the `JOIN`s collected from `Peer`'s `NJOIN` burst lines to local
channel members in one IRCv3 `netjoin` batch.
""".
-spec flush_netjoin(binary()) -> ok.
flush_netjoin(Peer) ->
    Pending =
        case ets:whereis(briskd_peer_batches) of
            undefined ->
                erase({briskd_netjoin, Peer});
            _ ->
                case ets:take(briskd_peer_batches, {netjoin, Peer}) of
                    [{_, List}] -> List;
                    [] -> undefined
                end
        end,
    case Pending of
        undefined ->
            ok;
        Reversed ->
            briskd_state_send:begin_batch(<<"netjoin">>, [local_server(), Peer], [<<"JOIN">>]),
            try
                lists:foreach(
                    fun({Name, Key}) ->
                        case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
                            [#remote_channel{members = Members}] when is_map_key(Key, Members) ->
                                broadcast_remote_join(Name, Key);
                            _ ->
                                ok
                        end
                    end,
                    lists:reverse(Reversed)
                )
            after
                briskd_state_send:end_batch()
            end
    end.

-doc """
Apply a `JOIN` of channel `Name` by a remote user.
""".
-spec import_remote_join(binary(), binary(), binary()) ->
    ok | {error, invalid_channel | unknown_remote_source}.
import_remote_join(Peer, Prefix, Name) ->
    case {briskd_state_link:remote_source(Peer, Prefix), shared_channel(Name)} of
        {{ok, #remote_client{key = NickKey}}, true} ->
            Key = briskd_wire:fold(Name),
            Channel = ensure_remote_channel(Key, Name),
            Members = Channel#remote_channel.members,
            case maps:is_key(NickKey, Members) of
                true ->
                    ok;
                false ->
                    mnesia:dirty_write(
                        Channel#remote_channel{members = Members#{NickKey => {Peer, [member]}}}
                    ),
                    briskd_state_link:index_remote_member(NickKey, Key),
                    briskd_population:on_channel_put(Key),
                    broadcast_remote_join(Name, NickKey),
                    briskd_state_link:relay_except(
                        Peer, briskd_wire:line(Prefix, <<"JOIN">>, [Name], none)
                    ),
                    ok
            end;
        {error, _} ->
            {error, unknown_remote_source};
        {_, false} ->
            {error, invalid_channel}
    end.

-doc """
Apply a `PART` of channel `Name` by a remote user, with optional `Reason`.
""".
-spec remove_remote_channel_member(binary(), binary(), binary(), none | iodata()) ->
    ok | {error, remote_user_not_on_channel | unknown_remote_channel | unknown_remote_source}.
remove_remote_channel_member(Peer, Prefix, Name, Reason) ->
    case
        {
            briskd_state_link:remote_source(Peer, Prefix),
            mnesia:dirty_read(remote_channel, briskd_wire:fold(Name))
        }
    of
        {{ok, #remote_client{key = NickKey}}, [#remote_channel{members = Members} = Channel]} ->
            case Members of
                #{NickKey := {Peer, _Roles}} ->
                    broadcast_remote_channel_event(Name, Prefix, <<"PART">>, Reason),
                    briskd_state_link:unindex_remote_member(NickKey, Channel#remote_channel.key),
                    Remaining = maps:remove(NickKey, Members),
                    case map_size(Remaining) of
                        0 ->
                            mnesia:dirty_delete(remote_channel, Channel#remote_channel.key),
                            briskd_population:on_channel_delete(Channel#remote_channel.key);
                        _ ->
                            mnesia:dirty_write(
                                briskd_wire:retain_fields(Channel#remote_channel{
                                    members = Remaining
                                })
                            )
                    end,
                    briskd_state_link:relay_except(
                        Peer, briskd_wire:line(Prefix, <<"PART">>, [Name], Reason)
                    ),
                    ok;
                #{} ->
                    {error, remote_user_not_on_channel}
            end;
        {error, _} ->
            {error, unknown_remote_source};
        {_, []} ->
            {error, unknown_remote_channel}
    end.

-doc """
Apply a `KICK` of `Nick` from channel `Name` by a remote user.
""".
-spec receive_remote_kick(binary(), binary(), binary(), binary(), none | iodata()) ->
    ok
    | {error,
        remote_kick_requires_operator
        | remote_kick_target_not_on_channel
        | unknown_remote_channel
        | unknown_remote_kick_target
        | unknown_remote_source}.
receive_remote_kick(_Peer, _Prefix, <<$&, _/binary>>, _Nick, _Reason) ->
    {error, unknown_remote_channel};
receive_remote_kick(Peer, Prefix, Name, Nick, Reason) ->
    Key = briskd_wire:fold(Name),
    case
        {
            briskd_state_link:remote_source(Peer, Prefix),
            mnesia:dirty_read(remote_channel, Key)
        }
    of
        {{ok, #remote_client{key = SourceKey}}, [#remote_channel{members = Members} = Channel]} ->
            case Members of
                #{SourceKey := {Peer, Roles}} ->
                    case lists:member(operator, Roles) orelse lists:member(creator, Roles) of
                        true -> apply_remote_kick(Peer, Prefix, Name, Nick, Reason, Channel);
                        false -> {error, remote_kick_requires_operator}
                    end;
                #{} ->
                    {error, remote_kick_requires_operator}
            end;
        {error, _} ->
            {error, unknown_remote_source};
        {_, []} ->
            {error, unknown_remote_channel}
    end.

apply_remote_kick(Peer, Prefix, Name, Nick, Reason, RemoteChannel) ->
    Key = RemoteChannel#remote_channel.key,
    case briskd_state_client:find_nick(Nick) of
        #client{pid = TargetPid, nick = Actual} = Target ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{members = Members} = Channel] when is_map_key(TargetPid, Members) ->
                    broadcast_kick(Channel, Prefix, Actual, Reason),
                    Remaining = maps:remove(TargetPid, Members),
                    case map_size(Remaining) of
                        0 ->
                            briskd_state_channel:release_if_empty(Channel, Remaining);
                        _ ->
                            mnesia:dirty_write(
                                briskd_state_channel:track_opless(Channel, Remaining)
                            )
                    end,
                    mnesia:dirty_write(Target#client{
                        channels = lists:delete(Key, Target#client.channels)
                    }),
                    remove_remote_channel_member_record(
                        Peer, briskd_wire:fold(Actual), RemoteChannel
                    ),
                    briskd_state_link:relay_except(
                        Peer, briskd_wire:line(Prefix, <<"KICK">>, [Name, Actual], Reason)
                    ),
                    ok;
                _ ->
                    {error, remote_kick_target_not_on_channel}
            end;
        undefined ->
            TargetKey = briskd_wire:fold(Nick),
            case maps:find(TargetKey, RemoteChannel#remote_channel.members) of
                {ok, {_TargetPeer, _TargetRoles}} ->
                    case mnesia:dirty_read(remote_client, TargetKey) of
                        [#remote_client{nick = Actual}] ->
                            broadcast_kick_by_name(Name, Prefix, Actual, Reason),
                            remove_remote_channel_member_record(Peer, TargetKey, RemoteChannel),
                            briskd_state_link:relay_except(
                                Peer, briskd_wire:line(Prefix, <<"KICK">>, [Name, Actual], Reason)
                            ),
                            ok;
                        [] ->
                            {error, unknown_remote_kick_target}
                    end;
                error ->
                    {error, remote_kick_target_not_on_channel}
            end
    end.

remove_remote_channel_member_record(_Peer, NickKey, #remote_channel{key = Key} = Channel) ->
    briskd_state_link:unindex_remote_member(NickKey, Key),
    Members = maps:remove(NickKey, Channel#remote_channel.members),
    case map_size(Members) of
        0 ->
            mnesia:dirty_delete(remote_channel, Key),
            briskd_population:on_channel_delete(Key);
        _ ->
            mnesia:dirty_write(briskd_wire:retain_fields(Channel#remote_channel{members = Members}))
    end,
    ok.

broadcast_kick(#channel{name = Name, members = Members, flags = Flags}, Prefix, Nick, Reason) ->
    EventPrefix =
        case maps:is_key($a, Flags) of
            true -> <<"anonymous!anonymous@anonymous.">>;
            false -> Prefix
        end,
    briskd_state_send:broadcast(maps:keys(Members), EventPrefix, <<"KICK">>, [Name, Nick], Reason).

broadcast_kick_by_name(Name, Prefix, Nick, Reason) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{} = Channel] -> broadcast_kick(Channel, Prefix, Nick, Reason);
        [] -> ok
    end.

%% Show a remote member joining a local channel.
broadcast_remote_join(Name, NickKey) ->
    case
        {
            mnesia:dirty_read(channel, briskd_wire:fold(Name)),
            mnesia:dirty_read(remote_client, NickKey)
        }
    of
        {
            [#channel{name = Canonical, members = Members, flags = Flags}],
            [
                #remote_client{
                    nick = N, user = U, host = H, real = Real, account = Account, modes = Modes
                }
            ]
        } ->
            case maps:is_key($a, Flags) of
                true ->
                    briskd_state_send:broadcast(
                        maps:keys(Members),
                        <<"anonymous!anonymous@anonymous.">>,
                        <<"JOIN">>,
                        [Canonical],
                        none
                    );
                false ->
                    Prefix = <<N/binary, "!", U/binary, "@", H/binary>>,
                    briskd_state_send:with_source(
                        briskd_state_v3:remote_source_info(Prefix), fun() ->
                            briskd_state_v3:join_broadcast(
                                maps:keys(Members), Prefix, Canonical, Account, Real
                            )
                        end
                    ),
                    case maps:is_key($a, Modes) of
                        true ->
                            briskd_state_v3:away_on_join(maps:keys(Members), Prefix, <<"Away">>);
                        false ->
                            ok
                    end
            end;
        _ ->
            ok
    end.

broadcast_remote_channel_event(Name, Prefix, Command, Reason) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, flags = Flags}] ->
            EventPrefix =
                case maps:is_key($a, Flags) of
                    true -> <<"anonymous!anonymous@anonymous.">>;
                    false -> Prefix
                end,
            briskd_state_send:broadcast(
                maps:keys(Members), EventPrefix, Command, [Canonical], Reason
            );
        [] ->
            ok
    end.

parse_remote_members(_Peer, [], Acc) ->
    {ok, lists:reverse(Acc)};
parse_remote_members(Peer, [RawMember | Rest], Acc) ->
    {Roles, Nick} = remote_member(RawMember),
    Key = briskd_wire:fold(Nick),
    case
        {briskd_wire:nickname(Nick, briskd_state:nicklen()), mnesia:dirty_read(remote_client, Key)}
    of
        {true, [#remote_client{peer = Peer}]} ->
            parse_remote_members(Peer, Rest, [{Key, Roles} | Acc]);
        {true, [_]} ->
            {error, remote_member_from_other_peer};
        _ ->
            {error, unknown_remote_member}
    end.

%% RFC 2813 4.2.2: "@@" (creator), "@" (operator), and "+" (voice); the
%% status prefixes may be stacked as "@@+" and "@+".
remote_member(<<"@@+", Nick/binary>>) -> {[creator, operator, voice], Nick};
remote_member(<<"@@", Nick/binary>>) -> {[creator, operator], Nick};
remote_member(<<"@+", Nick/binary>>) -> {[operator, voice], Nick};
remote_member(<<$@, Nick/binary>>) -> {[operator], Nick};
remote_member(<<$+, Nick/binary>>) -> {[voice], Nick};
remote_member(Nick) -> {[member], Nick}.

-doc """
Send `NAMES` replies (numeric 353) listing the remote members of the channel
with folded name `Key` to `Client`.
""".
-spec remote_names_listing(binary(), #client{}, binary()) -> ok.
remote_names_listing(Key, Client, Server) ->
    case mnesia:dirty_read(remote_channel, Key) of
        [#remote_channel{name = Name, flags = Flags}] ->
            LocalMember =
                case mnesia:dirty_read(channel, Key) of
                    [#channel{members = Members}] -> maps:is_key(Client#client.pid, Members);
                    [] -> false
                end,
            Hidden =
                (maps:is_key($p, Flags) orelse maps:is_key($s, Flags)) andalso
                    not LocalMember,
            case Hidden orelse maps:is_key($a, Flags) of
                true ->
                    ok;
                false ->
                    briskd_state_channel:names_lines(
                        remote_names_entries(Name, Client, LocalMember), [], 0, Name, Client, Server
                    )
            end;
        [] ->
            ok
    end.

-doc """
Mode state stored for the remote channel `Name`, or an empty map when it is
unknown.
""".
-spec remote_channel_flags(binary()) -> remote_flags().
remote_channel_flags(Name) ->
    case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
        [#remote_channel{flags = Flags}] -> Flags;
        [] -> #{}
    end.

-doc """
`NAMES` entries for the remote members of channel `Name`, sorted.
""".
-spec remote_names_entries(binary(), #client{}, boolean()) -> [binary()].
remote_names_entries(Name, Client, LocalMember) ->
    case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            lists:sort([
                remote_display_nick(Remote, Roles, Client)
             || {NickKey, {_Peer, Roles}} <- maps:to_list(Members),
                [#remote_client{} = Remote] <- [mnesia:dirty_read(remote_client, NickKey)],
                remote_visible_in_names(Remote, Client, LocalMember)
            ]);
        [] ->
            []
    end.

remote_visible_in_names(#remote_client{modes = Modes}, _Client, LocalMember) ->
    LocalMember orelse not maps:is_key($i, Modes).

-doc """
True when the remote user with folded nickname `NickKey` and user modes
`Modes` is visible to `Client` in queries.
""".
-spec remote_user_visible_to_requester(binary(), #{char() => true}, #client{}) -> boolean().
remote_user_visible_to_requester(NickKey, Modes, Client) ->
    not maps:is_key($i, Modes) orelse
        lists:any(
            fun(ChannelKey) ->
                case
                    {
                        mnesia:dirty_read(remote_channel, ChannelKey),
                        mnesia:dirty_read(channel, ChannelKey)
                    }
                of
                    {
                        [#remote_channel{members = RemoteMembers}],
                        [#channel{members = LocalMembers}]
                    } ->
                        maps:is_key(NickKey, RemoteMembers) andalso
                            maps:is_key(Client#client.pid, LocalMembers);
                    _ ->
                        false
                end
            end,
            Client#client.channels
        ).

-doc """
Pids of local clients that share a channel with the remote user `NickKey`.
""".
-spec remote_user_local_recipients(binary()) -> [pid()].
remote_user_local_recipients(NickKey) ->
    lists:usort([
        Pid
     || ChannelKey <- briskd_state_link:remote_user_channels(NickKey),
        [#remote_channel{members = RemoteMembers, flags = RemoteFlags}] <-
            [mnesia:dirty_read(remote_channel, ChannelKey)],
        maps:is_key(NickKey, RemoteMembers),
        not maps:is_key($a, RemoteFlags),
        not maps:is_key($q, RemoteFlags),
        [#channel{members = LocalMembers, flags = LocalFlags}] <-
            [mnesia:dirty_read(channel, ChannelKey)],
        not maps:is_key($a, LocalFlags),
        not maps:is_key($q, LocalFlags),
        Pid <- maps:keys(LocalMembers)
    ]).

remote_display_nick(
    #remote_client{nick = Nick, user = User, host = Host}, Roles, #client{pid = Pid}
) ->
    Name =
        case briskd_cap:enabled(Pid, <<"userhost-in-names">>) of
            true -> <<Nick/binary, "!", User/binary, "@", Host/binary>>;
            false -> Nick
        end,
    <<(briskd_state_channel:role_prefix(Roles, Pid))/binary, Name/binary>>.

-doc """
Forward a local `INVITE` of remote `Nick` to `Peer` and every other peer that
has members of channel `Name`.
""".
-spec propagate_invite(#client{}, iodata(), binary(), binary()) -> ok.
propagate_invite(_Client, _Nick, <<$&, _/binary>>, _Peer) ->
    ok;
propagate_invite(Client, Nick, Name, Peer) ->
    Line = iolist_to_binary(
        briskd_wire:line(briskd_state_send:prefix(Client), <<"INVITE">>, [Nick, Name], none)
    ),
    _ = briskd_links:send(Peer, Line),
    case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Peers = lists:usort([MemberPeer || _Nick := {MemberPeer, _} <- Members]),
            lists:foreach(
                fun(Other) ->
                    case briskd_route:should_forward(Peer, Other) of
                        true -> _ = briskd_links:send(Other, Line);
                        false -> ok
                    end
                end,
                Peers
            );
        [] ->
            ok
    end,
    ok.

-doc """
Apply an `INVITE` of `Nick` to channel `Name` sent by a remote user.
""".
-spec receive_remote_invite(binary(), binary(), binary(), binary()) ->
    ok | {error, unknown_remote_nick}.
receive_remote_invite(Peer, Prefix, Nick, Name) ->
    case briskd_state_link:remote_source(Peer, Prefix) of
        {ok, #remote_client{} = Source} ->
            case remote_invite_allowed(Peer, Source, Name) of
                false -> ok;
                true -> deliver_remote_invite(Peer, Prefix, Nick, Name)
            end;
        error ->
            {error, unknown_remote_nick}
    end.

remote_invite_allowed(_Peer, _Source, <<$&, _/binary>>) ->
    false;
remote_invite_allowed(Peer, #remote_client{key = NickKey}, Name) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(remote_channel, Key) of
        [#remote_channel{members = Members, flags = Flags}] ->
            case Members of
                #{NickKey := {Peer, Roles}} ->
                    Restricted = maps:is_key($i, Flags) orelse local_channel_mode(Key, $i),
                    not Restricted orelse lists:member(operator, Roles) orelse
                        lists:member(creator, Roles);
                #{} ->
                    false
            end;
        [] ->
            false
    end.

deliver_remote_invite(Peer, Prefix, Nick, Name) ->
    case briskd_state_client:find_nick(Nick) of
        #client{pid = Pid} = Target ->
            remember_local_invite(Pid, Name),
            Key = briskd_wire:fold(Name),
            Origin =
                case
                    local_channel_mode(Key, $a) orelse
                        maps:is_key($a, remote_channel_flags(Name))
                of
                    true -> <<"anonymous!anonymous@anonymous.">>;
                    false -> Prefix
                end,
            briskd_state_send:send(
                Pid, Origin, <<"INVITE">>, [Target#client.nick, Name], none
            ),
            ok;
        undefined ->
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
                [#remote_client{peer = Dest, nick = RemoteNick}] ->
                    case briskd_route:should_forward(Peer, Dest) of
                        true ->
                            Line = briskd_wire:line(
                                Prefix, <<"INVITE">>, [RemoteNick, Name], none
                            ),
                            _ = briskd_links:send(Dest, Line),
                            ok;
                        false ->
                            ok
                    end;
                [] ->
                    ok
            end
    end.

remember_local_invite(Pid, Name) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{invited = Invited} = Channel] ->
            Alive = [P || P <- Invited, is_process_alive(P)],
            mnesia:dirty_write(Channel#channel{invited = lists:usort([Pid | Alive])}),
            briskd_state_channel:note_invited(Pid, Channel#channel.key);
        [] ->
            ok
    end.

-doc """
Delete `remote_channel` rows that have no members, and empty the unused
`invited` maps that earlier releases recorded.
""".
-spec sweep_remote_channels() -> non_neg_integer().
sweep_remote_channels() ->
    lists:foldl(
        fun(Key, Removed) ->
            case mnesia:dirty_read(remote_channel, Key) of
                [#remote_channel{members = Members}] when map_size(Members) =:= 0 ->
                    mnesia:dirty_delete(remote_channel, Key),
                    briskd_population:on_channel_delete(Key),
                    Removed + 1;
                [#remote_channel{invited = Invited} = Row] when map_size(Invited) > 0 ->
                    mnesia:dirty_write(Row#remote_channel{invited = #{}}),
                    Removed;
                _ ->
                    Removed
            end
        end,
        0,
        briskd_state:table_keys(remote_channel)
    ).

-doc """
Announce a local user's `TOPIC` change on channel `Name` to every peer.
""".
-spec propagate_topic(#client{}, iodata(), none | iodata()) -> ok.
propagate_topic(_Client, <<$&, _/binary>>, _Topic) ->
    ok;
propagate_topic(Client, Name, Topic) ->
    briskd_state_link:server_broadcast(
        briskd_wire:line(briskd_state_send:prefix(Client), <<"TOPIC">>, [Name], Topic)
    ).

-doc """
Announce a local user's channel `MODE` change to every peer.
""".
-spec propagate_channel_mode(#client{}, iodata(), iodata(), [iodata()]) -> ok.
propagate_channel_mode(_Client, <<$&, _/binary>>, _Mode, _Args) ->
    ok;
propagate_channel_mode(Client, Name, Mode, Args) ->
    briskd_state_link:server_broadcast(
        briskd_wire:line(briskd_state_send:prefix(Client), <<"MODE">>, [Name, Mode | Args], none)
    ).

-doc """
Announce a local user's `KICK` of `Nick` from channel `Name` to every peer.
""".
-spec propagate_channel_kick(#client{}, iodata(), iodata(), none | iodata()) -> ok.
propagate_channel_kick(_Client, <<$&, _/binary>>, _Nick, _Reason) ->
    ok;
propagate_channel_kick(Client, Name, Nick, Reason) ->
    briskd_state_link:server_broadcast(
        briskd_wire:line(briskd_state_send:prefix(Client), <<"KICK">>, [Name, Nick], Reason)
    ).

-doc """
Announce a local user joining channel `Name` to every peer.
""".
-spec propagate_join(#client{}, binary(), [channel_role()]) -> ok.
propagate_join(_Client, <<$&, _/binary>>, _Roles) ->
    ok;
propagate_join(Client, Name, Roles) ->
    Server = local_server(),
    briskd_state_link:server_broadcast(
        briskd_wire:line(briskd_state_send:prefix(Client), <<"JOIN">>, [Name], none)
    ),
    Member = iolist_to_binary(briskd_link_burst:njoin_member(Client, Roles)),
    briskd_state_link:server_broadcast(briskd_wire:line(Server, <<"NJOIN">>, [Name], Member)),
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{flags = Flags, password = Password, limit = Limit, lists = Lists}] ->
            lists:foreach(
                fun briskd_state_link:server_broadcast/1,
                briskd_link_burst:channel_mode_burst(Name, Flags, Password, Limit, Lists, Server)
            );
        [] ->
            ok
    end.

-doc """
Send prepared lines to every peer that has members of channel `Name`.
""".
-spec propagate_channel_lines(binary(), [iodata()]) -> ok.
propagate_channel_lines(Name, Lines) ->
    case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Peers = lists:usort([Peer || _Nick := {Peer, _Roles} <- Members]),
            Bins = [iolist_to_binary(Line) || Line <- Lines],
            lists:foreach(
                fun(Peer) ->
                    lists:foreach(fun(Bin) -> _ = briskd_links:send(Peer, Bin) end, Bins)
                end,
                Peers
            );
        [] ->
            ok
    end.

local_server() ->
    maps:get(name, briskd_config:current()).
