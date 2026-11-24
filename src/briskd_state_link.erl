-module(briskd_state_link).
-moduledoc """
Server-link burst, import, and propagation of users, channels, and messages
(RFC 2813).

The functions run inside the `m:briskd_state` process, the single writer of the
transient `remote_client` and `remote_channel` Mnesia rows that describe users
and channel memberships behind server links. Each `remote_client` row records
the adjacent link (`peer`) the user is reached through and its home server.

Import functions (`import_*`, `receive_*`, `update_remote_*`,
`rename_remote_nick/3`, `remove_*`, `set_remote_away/3`) take `Peer`, the
adjacent link the line arrived on, and `Prefix`, the source prefix from the
wire. Source prefixes are trusted only within that link: a user prefix must
be the exact `nick!user@host` of a remote user whose `peer` is `Peer`, and a
server prefix must be `Peer` itself or a server introduced through it. Other
sources are rejected with `{error, Reason}`, which makes the link drop.
Accepted changes are shown to local clients and relayed to every other peer
with `relay_except/2`, never back to `Peer`.

Propagate functions announce local events. Nick, quit, away, topic, mode,
kick, and join go to every peer; channel messages go only to the peers that
have members in the channel. The burst for a new peer is built by
`server_burst_lines/1`. Nicknames and channel names are compared with
`briskd_wire:fold/1`.
""".
-export([
    expire_peer_batches/0,
    import_remote_join/3,
    import_remote_nick/3,
    index_remote_member/2,
    peer_item_count/2,
    receive_remote_invite/4,
    import_remote_njoin/3,
    flush_netjoin/1,
    forget_peer_batches/1,
    note_local_channel/1,
    propagate_away/2,
    propagate_channel_kick/4,
    propagate_channel_message/5,
    propagate_channel_lines/2,
    receive_remote_batch/4,
    remote_batch_line/5,
    propagate_channel_mode/4,
    propagate_introduction/2,
    propagate_invite/4,
    propagate_join/3,
    propagate_nick_change/2,
    propagate_quit/2,
    propagate_topic/3,
    receive_remote_kick/5,
    receive_remote_message/4,
    receive_remote_message/5,
    remote_channel_flags/1,
    remote_names_entries/3,
    remote_names_listing/3,
    remote_nick_exists/1,
    remote_source/2,
    trusted_server/2,
    remote_user_channels/1,
    remote_user_local_recipients/1,
    remote_user_visible_to_requester/3,
    receive_remote_kill/3,
    relay_except/2,
    remove_remote_channel_member/4,
    remove_remote_nick/3,
    rename_remote_nick/3,
    server_broadcast/1,
    sweep_remote_channels/0,
    server_burst_lines/1,
    set_remote_away/3,
    track_peer_item/3,
    unindex_remote_channel/2,
    unindex_remote_member/2,
    untrack_peer_item/2,
    update_remote_modes/5,
    update_remote_topic/4
]).
-include("briskd_state.hrl").

-doc """
Every line of the state burst sent to a newly authenticated peer (RFC 2813
section 5.3.2).
""".
-spec server_burst_lines(binary()) -> [iodata()].
server_burst_lines(Server) ->
    briskd_link_burst:server_burst_lines(Server).
-doc """
True when `Nick` belongs to a user behind a server link.
""".
-spec remote_nick_exists(binary()) -> boolean().
remote_nick_exists(Nick) ->
    mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) =/= [].

-doc """
Import a user introduction, the 7-parameter `NICK` of RFC 2813 section 4.1.3.

The parameters are nickname, hop count, username, host, server token, user
modes, and real name. `Prefix` is the home server: `Peer` itself, or a known
server reached through `Peer` whose stored hop count is the `NICK` hop count
plus one. A new user is stored with its home server and distance, reported
to MONITOR, and relayed to the other peers.

The nickname must be valid, at most the configured length, and not
`anonymous`; the username 1 to 32 characters of letters, digits, `_`, `.`,
and `-`; the host 1 to 253 bytes without NUL, space, CR, or LF; the modes `+`
followed only by `a`, `i`, `o`, `w`, or `B`. The same peer may introduce a
nickname again, which overwrites the row without relaying it. A nickname held
by a local client or by a user behind another link is a collision: both
copies are killed and the name is held, and the result is still `ok`.

Errors: `invalid_hopcount`, `invalid_introduction_prefix`, `invalid_nickname`,
`reserved_nickname`, `invalid_server_token`, `invalid_username`,
`invalid_hostname`, `invalid_user_modes`, and `invalid_nick_message`.
""".
-spec import_remote_nick(binary(), binary(), [binary()]) ->
    ok
    | {error,
        invalid_hopcount
        | invalid_hostname
        | invalid_introduction_prefix
        | invalid_nick_message
        | invalid_nickname
        | invalid_server_token
        | invalid_user_modes
        | invalid_username
        | reserved_nickname
        | too_many_remote_users}.
import_remote_nick(Peer, Prefix, [Nick, Hop, User, Host, Token, ModeString, Real]) ->
    case home_server(Peer, Prefix, Hop) of
        {error, Reason} ->
            {error, Reason};
        {ok, Home, Distance} ->
            import_remote_nick(
                Peer, Home, Distance, Nick, Hop, User, Host, Token, ModeString, Real
            )
    end;
import_remote_nick(_, _, _) ->
    {error, invalid_nick_message}.

import_remote_nick(Peer, Home, Distance, Nick, _Hop, User, Host, Token, ModeString, Real) ->
    Key = briskd_wire:fold(Nick),
    case
        {
            briskd_wire:nickname(Nick, briskd_state:nicklen()),
            Key =/= <<"anonymous">>,
            briskd_route:valid_decimal(Token),
            re:run(User, <<"^[A-Za-z0-9_.-]{1,32}$">>, [{capture, none}, dollar_endonly]),
            valid_server_host(Host),
            server_user_modes(ModeString),
            briskd_state_client:find_nick(Nick),
            mnesia:dirty_read(remote_client, Key)
        }
    of
        {true, true, true, match, true, {ok, Modes}, undefined, []} ->
            case peer_user_room(Peer) of
                false ->
                    {error, too_many_remote_users};
                true ->
                    write_remote_nick(
                        Peer, Home, Distance, Key, Nick, User, Host, Token, Modes, Real
                    ),
                    briskd_state_monitor:online(
                        Nick, <<Nick/binary, "!", User/binary, "@", Host/binary>>
                    ),
                    briskd_state_meta:forget_remote(Key),
                    relay_except(
                        Peer,
                        briskd_link_burst:remote_nick_line(
                            Home, Nick, Distance, User, Host, Token, Modes, Real
                        )
                    ),
                    ok
            end;
        {true, true, true, match, true, {ok, Modes}, undefined, [#remote_client{peer = Peer}]} ->
            write_remote_nick(
                Peer, Home, Distance, Key, Nick, User, Host, Token, Modes, Real
            ),
            ok;
        {false, _, _, _, _, _, _, _} ->
            {error, invalid_nickname};
        {_, false, _, _, _, _, _, _} ->
            {error, reserved_nickname};
        {_, _, false, _, _, _, _, _} ->
            {error, invalid_server_token};
        {_, _, _, nomatch, _, _, _, _} ->
            {error, invalid_username};
        {_, _, _, _, false, _, _, _} ->
            {error, invalid_hostname};
        {_, _, _, _, _, error, _, _} ->
            {error, invalid_user_modes};
        {_, _, _, _, _, _, #client{}, _} ->
            collide_nickname(Nick),
            ok;
        {_, _, _, _, _, _, _, [#remote_client{peer = Other}]} when Other =/= Peer ->
            collide_nickname(Nick),
            ok;
        _ ->
            {error, invalid_nick_message}
    end.

home_server(Peer, Prefix, Hop) ->
    case briskd_route:valid_decimal(Hop) of
        false ->
            {error, invalid_hopcount};
        true ->
            Distance = binary_to_integer(Hop) + 1,
            case briskd_wire:fold(Prefix) =:= briskd_wire:fold(Peer) of
                true ->
                    {ok, Peer, Distance};
                false ->
                    case mnesia:dirty_read(known_server, briskd_wire:fold(Prefix)) of
                        [#known_server{name = Name, hop = HopCount, adjacent = Adjacent}] ->
                            case
                                briskd_wire:fold(Adjacent) =:= briskd_wire:fold(Peer) andalso
                                    Distance =:= HopCount
                            of
                                true -> {ok, Name, HopCount};
                                false -> {error, invalid_introduction_prefix}
                            end;
                        [] ->
                            {error, invalid_introduction_prefix}
                    end
            end
    end.

collide_nickname(Nick) ->
    %% RFC 2812 nick collision kills every copy. Both peers must see KILL and QUIT,
    %% including the server that introduced the second copy.
    case briskd_route:nick_collision(true, true) of
        kill_both ->
            Server = local_server(),
            Reason = <<"Nick collision">>,
            Local = briskd_state_client:find_nick(Nick),
            Remote =
                case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
                    [#remote_client{} = Row] -> Row;
                    [] -> undefined
                end,
            Actual = collision_nick(Nick, Local, Remote),
            server_broadcast(briskd_wire:line(Server, <<"KILL">>, [Actual], Reason)),
            case Local of
                #client{pid = Pid} = Client ->
                    briskd_state_send:send(Pid, Server, <<"KILL">>, [Actual], Reason),
                    briskd_state_client:disconnect(Client, Reason, Server);
                undefined ->
                    ok
            end,
            case Remote of
                #remote_client{user = User, host = Host} ->
                    Prefix = <<Actual/binary, "!", User/binary, "@", Host/binary>>,
                    server_broadcast(briskd_wire:line(Prefix, <<"QUIT">>, [], Reason)),
                    briskd_state_net:remove_remote_user(Remote);
                undefined ->
                    ok
            end,
            briskd_state_net:hold_nick(Actual)
    end.

collision_nick(_Nick, #client{nick = Actual}, _) ->
    Actual;
collision_nick(_Nick, _, #remote_client{nick = Actual}) ->
    Actual;
collision_nick(Nick, _, _) ->
    Nick.

write_remote_nick(Peer, Home, Distance, Key, Nick, User, Host, Token, Modes, Real) ->
    mnesia:dirty_write(
        briskd_wire:retain_fields(#remote_client{
            key = Key,
            peer = Peer,
            nick = Nick,
            user = User,
            host = Host,
            token = Token,
            modes = Modes,
            real = Real,
            server = Home,
            hop = Distance
        })
    ),
    track_peer_item(user, Key, Peer),
    briskd_population:on_remote_user_put(Key, Modes).

local_server() ->
    maps:get(name, briskd_config:current()).

peer_user_room(Peer) ->
    Max = maps:get(max_peer_users, briskd_config:current_or_empty(), 10000),
    peer_item_count(user, Peer) < Max.

-doc """
Record that remote user `NickKey` belongs to remote channel `ChannelKey` in
`briskd_remote_membership`.
""".
-spec index_remote_member(binary(), binary()) -> ok.
index_remote_member(NickKey, ChannelKey) ->
    case ets:whereis(briskd_remote_membership) of
        undefined -> ok;
        _ -> true = ets:insert(briskd_remote_membership, {NickKey, ChannelKey})
    end,
    ok.

-doc """
Remove `{NickKey, ChannelKey}` from `briskd_remote_membership`.
""".
-spec unindex_remote_member(binary(), binary()) -> ok.
unindex_remote_member(NickKey, ChannelKey) ->
    case ets:whereis(briskd_remote_membership) of
        undefined -> ok;
        _ -> true = ets:delete_object(briskd_remote_membership, {NickKey, ChannelKey})
    end,
    ok.

-doc """
Remove all member entries for remote channel `ChannelKey` from
`briskd_remote_membership`.
""".
-spec unindex_remote_channel(binary(), map()) -> ok.
unindex_remote_channel(ChannelKey, Members) ->
    lists:foreach(
        fun(NickKey) -> unindex_remote_member(NickKey, ChannelKey) end,
        maps:keys(Members)
    ).

-doc """
Folded channel keys that remote user `NickKey` is currently a member of.
""".
-spec remote_user_channels(binary()) -> [binary()].
remote_user_channels(NickKey) ->
    case ets:whereis(briskd_remote_membership) of
        undefined ->
            briskd_state:table_keys(remote_channel);
        _ ->
            lists:usort([ChanKey || {_, ChanKey} <- ets:lookup(briskd_remote_membership, NickKey)])
    end.

-doc """
Idempotently record ownership of a remote `user`, `server`, or `service` by
`Peer` in `briskd_peer_counts`.
""".
-spec track_peer_item(user | server | service, binary(), binary()) -> ok.
track_peer_item(Type, Key, Peer) ->
    case ets:whereis(briskd_peer_counts) of
        undefined ->
            ok;
        _ ->
            FoldPeer = briskd_wire:fold(Peer),
            case ets:lookup(briskd_peer_counts, {item, Type, Key}) of
                [{_, FoldPeer}] ->
                    ok;
                [{_, OldPeer}] ->
                    dec_peer_count(Type, OldPeer),
                    inc_peer_count(Type, FoldPeer),
                    ets:insert(briskd_peer_counts, {{item, Type, Key}, FoldPeer}),
                    ok;
                [] ->
                    inc_peer_count(Type, FoldPeer),
                    ets:insert(briskd_peer_counts, {{item, Type, Key}, FoldPeer}),
                    ok
            end
    end.

-doc """
Remove ownership tracking for a deleted remote `user`, `server`, or `service`.
""".
-spec untrack_peer_item(user | server | service, binary()) -> ok.
untrack_peer_item(Type, Key) ->
    case ets:whereis(briskd_peer_counts) of
        undefined ->
            ok;
        _ ->
            case ets:take(briskd_peer_counts, {item, Type, Key}) of
                [{_, FoldPeer}] -> dec_peer_count(Type, FoldPeer);
                [] -> ok
            end
    end.

-doc """
Number of tracked `user`, `server`, or `service` entries owned by `Peer`.
""".
-spec peer_item_count(user | server | service, binary()) -> non_neg_integer().
peer_item_count(Type, Peer) ->
    case ets:whereis(briskd_peer_counts) of
        undefined ->
            0;
        _ ->
            case ets:lookup(briskd_peer_counts, {count, Type, briskd_wire:fold(Peer)}) of
                [{_, N}] when is_integer(N), N > 0 -> N;
                _ -> 0
            end
    end.

inc_peer_count(Type, FoldPeer) ->
    _ = ets:update_counter(
        briskd_peer_counts, {count, Type, FoldPeer}, {2, 1}, {{count, Type, FoldPeer}, 0}
    ),
    ok.

dec_peer_count(Type, FoldPeer) ->
    case ets:lookup(briskd_peer_counts, {count, Type, FoldPeer}) of
        [{_, N}] when N > 1 ->
            _ = ets:update_counter(briskd_peer_counts, {count, Type, FoldPeer}, {2, -1}),
            ok;
        [{_, _}] ->
            true = ets:delete(briskd_peer_counts, {count, Type, FoldPeer}),
            ok;
        [] ->
            ok
    end.

-doc """
Apply a nickname change by a remote user.

`Peer` is the adjacent link the line arrived on and `Prefix` its source
prefix, which must be the exact `nick!user@host` of a remote user reached
through `Peer`. The new nickname must be
valid, not `anonymous`, and unused by any local or other remote user. The
`remote_client` row, channel memberships, metadata, and MONITOR presence move
to the new name, local clients sharing a channel with the user (outside `+a`
and `+q` channels) see the `NICK`, and the change is relayed to the other
peers. A change that only alters case updates the stored spelling and is
shown and relayed the same way, without MONITOR notifications; a `NICK` to
the current spelling changes nothing.

Errors: `unknown_remote_nick` for an untrusted prefix, `invalid_nickname`,
`reserved_nickname`, and `nickname_collision` (no kill is issued).
""".
-spec rename_remote_nick(binary(), binary(), binary()) ->
    ok | {error, invalid_nickname | nickname_collision | reserved_nickname | unknown_remote_nick}.
rename_remote_nick(Peer, Prefix, Nick) ->
    NewKey = briskd_wire:fold(Nick),
    case remote_source(Peer, Prefix) of
        {ok, #remote_client{key = OldKey} = Remote} ->
            case
                {
                    briskd_wire:nickname(Nick, briskd_state:nicklen()),
                    NewKey =/= <<"anonymous">>,
                    briskd_state_client:find_nick(Nick),
                    mnesia:dirty_read(remote_client, NewKey)
                }
            of
                {true, true, undefined, []} ->
                    show_remote_event(OldKey, Prefix, <<"NICK">>, Nick),
                    mnesia:dirty_delete(remote_client, OldKey),
                    mnesia:dirty_write(
                        briskd_wire:retain_fields(Remote#remote_client{key = NewKey, nick = Nick})
                    ),
                    untrack_peer_item(user, OldKey),
                    track_peer_item(user, NewKey, Remote#remote_client.peer),
                    briskd_population:on_remote_user_rename(
                        OldKey, NewKey, Remote#remote_client.modes
                    ),
                    rename_remote_memberships(Peer, OldKey, NewKey),
                    briskd_state_meta:rename_remote(OldKey, NewKey),
                    ok = briskd_e2ee:remote_renamed(OldKey, NewKey),
                    ok = briskd_calls:remote_renamed(OldKey, NewKey),
                    briskd_state_monitor:offline(Remote#remote_client.nick),
                    briskd_state_monitor:online(
                        Nick,
                        <<Nick/binary, "!", (Remote#remote_client.user)/binary, "@",
                            (Remote#remote_client.host)/binary>>
                    ),
                    relay_except(Peer, briskd_wire:line(Prefix, <<"NICK">>, [Nick], none)),
                    ok;
                {true, true, undefined, [#remote_client{key = OldKey, peer = Peer}]} when
                    Nick =:= Remote#remote_client.nick
                ->
                    ok;
                {true, true, undefined, [#remote_client{key = OldKey, peer = Peer}]} ->
                    show_remote_event(OldKey, Prefix, <<"NICK">>, Nick),
                    mnesia:dirty_write(
                        briskd_wire:retain_fields(Remote#remote_client{nick = Nick})
                    ),
                    relay_except(Peer, briskd_wire:line(Prefix, <<"NICK">>, [Nick], none)),
                    ok;
                {true, true, undefined, [#remote_client{peer = Peer}]} ->
                    {error, nickname_collision};
                {false, _, _, _} ->
                    {error, invalid_nickname};
                {_, false, _, _} ->
                    {error, reserved_nickname};
                _ ->
                    {error, nickname_collision}
            end;
        _ ->
            {error, unknown_remote_nick}
    end.

-doc """
Apply a `QUIT` by a remote user.

`Peer` is the adjacent link the line arrived on and `Prefix` its source
prefix, which must be the exact `nick!user@host` of a remote user reached
through `Peer`. Local clients sharing a channel with the user (outside
`+a` and `+q` channels) see the `QUIT`, it is relayed to
the other peers, and the user's row, metadata, MONITOR presence, and channel
memberships through `Peer` are removed; a remote channel left empty is
deleted. Returns `{error, unknown_remote_nick}` for an untrusted prefix.
""".
-spec remove_remote_nick(binary(), binary(), none | iodata()) -> ok | {error, unknown_remote_nick}.
remove_remote_nick(Peer, Prefix, Reason) ->
    case remote_source(Peer, Prefix) of
        {ok, #remote_client{key = Key, nick = Nick}} ->
            show_remote_event(Key, Prefix, <<"QUIT">>, Reason),
            relay_except(Peer, briskd_wire:line(Prefix, <<"QUIT">>, [], Reason)),
            mnesia:dirty_delete(remote_client, Key),
            untrack_peer_item(user, Key),
            briskd_population:on_remote_user_delete(Key),
            briskd_state_monitor:offline(Nick),
            briskd_state_meta:forget_remote(Key),
            ok = briskd_e2ee:forget_remote(Key),
            ok = briskd_calls:remote_gone(Key),
            remove_remote_memberships(Peer, Key),
            ok;
        error ->
            {error, unknown_remote_nick}
    end.

-doc """
Apply an `AWAY` by a remote user.

`Peer` is the adjacent link the line arrived on and `Prefix` its source
prefix, which must be the exact `nick!user@host` of a remote user reached
through `Peer`. A message parameter sets
user mode `a`, and no parameter clears it. `away-notify` clients sharing a
channel with the user are told, and the line is relayed to the other peers.
Returns `{error, unknown_remote_nick}` for an untrusted prefix.
""".
-spec set_remote_away(binary(), binary(), [binary()]) -> ok | {error, unknown_remote_nick}.
set_remote_away(Peer, Prefix, Params) ->
    case remote_source(Peer, Prefix) of
        {ok, Remote} ->
            Modes =
                case Params of
                    [] -> maps:remove($a, Remote#remote_client.modes);
                    [_Message | _] -> (Remote#remote_client.modes)#{$a => true}
                end,
            mnesia:dirty_write(briskd_wire:retain_fields(Remote#remote_client{modes = Modes})),
            AwayTail =
                case Params of
                    [] -> none;
                    [Text | _] -> Text
                end,
            briskd_state_v3:notify_remote(
                Remote, Prefix, <<"away-notify">>, <<"AWAY">>, [], AwayTail
            ),
            AwayLine =
                case Params of
                    [] -> briskd_wire:line(Prefix, <<"AWAY">>, [], none);
                    [Message | _] -> briskd_wire:line(Prefix, <<"AWAY">>, [], Message)
                end,
            relay_except(Peer, AwayLine),
            ok;
        error ->
            {error, unknown_remote_nick}
    end.

%% Show a remote user's NICK or QUIT to the local clients that share a
%% channel with it. Anonymous and quiet channels are skipped, as in
%% remote_user_local_recipients/1, so the real prefix is never exposed there.
%% briskd_state has already set the message source to Prefix for this line.
show_remote_event(Key, Prefix, Command, Tail) ->
    briskd_state_send:broadcast(remote_user_local_recipients(Key), Prefix, Command, [], Tail).

-doc """
The remote user that `Prefix` names, when it may speak on the link `Peer`.

`Prefix` must be the exact `nick!user@host` of a `remote_client` row whose
adjacent link is `Peer`; anything else, including a server name, is `error`.
""".
-spec remote_source(binary(), binary()) -> {ok, #remote_client{}} | error.
remote_source(Peer, Prefix) ->
    case binary:split(Prefix, <<"!">>) of
        [Nick, _UserHost] ->
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
                [#remote_client{peer = Peer, nick = Nick, user = User, host = Host} = Remote] ->
                    case Prefix =:= <<Nick/binary, "!", User/binary, "@", Host/binary>> of
                        true -> {ok, Remote};
                        false -> error
                    end;
                _ ->
                    error
            end;
        _ ->
            error
    end.

-doc "Apply a `TOPIC` change for channel `Name` received from `Peer`.".
-spec update_remote_topic(binary(), binary(), binary(), binary()) ->
    ok
    | {error,
        invalid_channel
        | remote_topic_requires_operator
        | remote_user_not_on_channel
        | unknown_remote_channel
        | unknown_remote_source}.
update_remote_topic(Peer, Prefix, Name, Topic) ->
    briskd_link_channel:update_remote_topic(Peer, Prefix, Name, Topic).

-doc "Copy a local channel's modes, key, limit, lists, and topic onto its remote row.".
-spec note_local_channel(#channel{}) -> ok.
note_local_channel(Channel) ->
    briskd_link_channel:note_local_channel(Channel).

-doc """
True when `Prefix` is the adjacent peer `Peer` or a known server reached
through `Peer`.
""".
-spec trusted_server(binary(), binary()) -> boolean().
trusted_server(Peer, Prefix) ->
    case briskd_wire:fold(Prefix) =:= briskd_wire:fold(Peer) of
        true ->
            true;
        false ->
            case mnesia:dirty_read(known_server, briskd_wire:fold(Prefix)) of
                [#known_server{adjacent = Adjacent}] ->
                    briskd_wire:fold(Adjacent) =:= briskd_wire:fold(Peer);
                [] ->
                    false
            end
    end.

rename_remote_memberships(Peer, OldKey, NewKey) ->
    lists:foreach(
        fun(ChannelKey) ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{members = Members} = Channel] ->
                    case maps:take(OldKey, Members) of
                        {{Peer, Roles}, Remaining} ->
                            mnesia:dirty_write(
                                Channel#remote_channel{
                                    members = Remaining#{NewKey => {Peer, Roles}}
                                }
                            ),
                            unindex_remote_member(OldKey, ChannelKey),
                            index_remote_member(NewKey, ChannelKey);
                        _ ->
                            ok
                    end;
                _ ->
                    ok
            end
        end,
        remote_user_channels(OldKey)
    ).

remove_remote_memberships(Peer, NickKey) ->
    lists:foreach(
        fun(ChannelKey) ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{members = Members} = Channel] ->
                    case Members of
                        #{NickKey := {Peer, _Roles}} ->
                            unindex_remote_member(NickKey, ChannelKey),
                            Remaining = maps:remove(NickKey, Members),
                            case map_size(Remaining) of
                                0 ->
                                    mnesia:dirty_delete(remote_channel, ChannelKey),
                                    briskd_population:on_channel_delete(ChannelKey);
                                _ ->
                                    mnesia:dirty_write(
                                        briskd_wire:retain_fields(Channel#remote_channel{
                                            members = Remaining
                                        })
                                    )
                            end;
                        #{} ->
                            ok
                    end;
                _ ->
                    ok
            end
        end,
        remote_user_channels(NickKey)
    ).

-doc "Import an `NJOIN` (RFC 2813 section 4.2.2) for channel `Name` from `Peer`.".
-spec import_remote_njoin(binary(), binary(), binary()) ->
    ok
    | {error,
        empty_njoin | invalid_channel | remote_member_from_other_peer | unknown_remote_member}.
import_remote_njoin(Peer, Name, Members) ->
    briskd_link_channel:import_remote_njoin(Peer, Name, Members).

-doc "Send the `JOIN`s collected from `Peer`'s `NJOIN` burst lines to local channel members.".
-spec flush_netjoin(binary()) -> ok.
flush_netjoin(Peer) ->
    briskd_link_channel:flush_netjoin(Peer).

-doc "Apply a `JOIN` of channel `Name` by a remote user.".
-spec import_remote_join(binary(), binary(), binary()) ->
    ok | {error, invalid_channel | unknown_remote_source}.
import_remote_join(Peer, Prefix, Name) ->
    briskd_link_channel:import_remote_join(Peer, Prefix, Name).

-doc "Apply a `PART` of channel `Name` by a remote user, with optional `Reason`.".
-spec remove_remote_channel_member(binary(), binary(), binary(), none | iodata()) ->
    ok | {error, remote_user_not_on_channel | unknown_remote_channel | unknown_remote_source}.
remove_remote_channel_member(Peer, Prefix, Name, Reason) ->
    briskd_link_channel:remove_remote_channel_member(Peer, Prefix, Name, Reason).

-doc "Apply a `KICK` of `Nick` from channel `Name` by a remote user.".
-spec receive_remote_kick(binary(), binary(), binary(), binary(), none | iodata()) ->
    ok
    | {error,
        remote_kick_requires_operator
        | remote_kick_target_not_on_channel
        | unknown_remote_channel
        | unknown_remote_kick_target
        | unknown_remote_source}.
receive_remote_kick(Peer, Prefix, Name, Nick, Reason) ->
    briskd_link_channel:receive_remote_kick(Peer, Prefix, Name, Nick, Reason).

-doc "Apply a `MODE` from `Peer` to a channel or to a remote user.".
-spec update_remote_modes(binary(), binary(), binary(), binary(), [binary()]) ->
    ok
    | {error,
        invalid_channel_limit
        | missing_channel_limit
        | missing_mode_argument
        | remote_mode_requires_operator
        | remote_user_mode_source_mismatch
        | unknown_remote_channel
        | unknown_remote_mode_target
        | unknown_remote_source
        | invalid_channel
        | {extra_mode_arguments, term()}
        | {unsupported_channel_mode, byte()}}.
update_remote_modes(Peer, Prefix, Name, ModeString, Args) ->
    briskd_link_mode:update_remote_modes(Peer, Prefix, Name, ModeString, Args).

valid_server_host(Host) ->
    byte_size(Host) > 0 andalso byte_size(Host) =< 253 andalso
        binary:match(Host, [<<0>>, <<" ">>, <<"\r">>, <<"\n">>]) =:= nomatch.

server_user_modes(<<$+, Modes/binary>>) ->
    case lists:all(fun(Mode) -> lists:member(Mode, "aiowB") end, binary_to_list(Modes)) of
        true -> {ok, maps:from_keys(binary_to_list(Modes), true)};
        false -> error
    end;
server_user_modes(_) ->
    error.

-doc "Deliver a `PRIVMSG`, `NOTICE`, `TAGMSG`, or `SQUERY` from a remote user, without tags.".
-spec receive_remote_message(binary(), binary(), binary(), [binary()]) ->
    ok
    | {error,
        invalid_remote_message
        | malformed_remote_prefix
        | remote_prefix_mismatch
        | remote_user_not_on_channel
        | unknown_remote_channel
        | unknown_remote_source}.
receive_remote_message(Peer, Prefix, Command, Params) ->
    briskd_link_msg:receive_remote_message(Peer, Prefix, Command, Params).

-doc "Deliver a `PRIVMSG`, `NOTICE`, or `TAGMSG` from a remote user to its target.".
-spec receive_remote_message(binary(), binary(), binary(), [binary()], [
    {binary(), undefined | binary()}
]) ->
    ok
    | {error,
        invalid_remote_message
        | malformed_remote_prefix
        | remote_prefix_mismatch
        | remote_user_not_on_channel
        | unknown_remote_channel
        | unknown_remote_source}.
receive_remote_message(Peer, Prefix, Command, Params, Tags) ->
    briskd_link_msg:receive_remote_message(Peer, Prefix, Command, Params, Tags).

-doc "Send `NAMES` replies listing the remote members of channel `Key`.".
-spec remote_names_listing(binary(), #client{}, binary()) -> ok.
remote_names_listing(Key, Client, Server) ->
    briskd_link_channel:remote_names_listing(Key, Client, Server).

-doc "Mode state stored for the remote channel `Name`, or an empty map.".
-spec remote_channel_flags(binary()) -> remote_flags().
remote_channel_flags(Name) ->
    briskd_link_channel:remote_channel_flags(Name).

-doc "`NAMES` entries for the remote members of channel `Name`, sorted.".
-spec remote_names_entries(binary(), #client{}, boolean()) -> [binary()].
remote_names_entries(Name, Client, LocalMember) ->
    briskd_link_channel:remote_names_entries(Name, Client, LocalMember).

-doc "True when the remote user with folded nickname `NickKey` is visible to `Client`.".
-spec remote_user_visible_to_requester(binary(), #{char() => true}, #client{}) -> boolean().
remote_user_visible_to_requester(NickKey, Modes, Client) ->
    briskd_link_channel:remote_user_visible_to_requester(NickKey, Modes, Client).

-doc "Pids of local clients that share a channel with the remote user `NickKey`.".
-spec remote_user_local_recipients(binary()) -> [pid()].
remote_user_local_recipients(NickKey) ->
    briskd_link_channel:remote_user_local_recipients(NickKey).

-doc """
Introduce a newly registered local user to every peer with a 7-parameter
`NICK` line prefixed by `Server`, the local server name.
""".
-spec propagate_introduction(#client{}, iodata()) -> ok.
propagate_introduction(
    #client{nick = Nick, user = User, host = Host, real = Real, pid = Pid}, Server
) when is_binary(User), is_binary(Real) ->
    Modes = briskd_state_channel:user_mode_string(briskd_state_client:user_modes(Pid)),
    server_broadcast(
        briskd_wire:line(
            Server,
            <<"NICK">>,
            [Nick, <<"0">>, User, Host, <<"1">>, Modes],
            Real
        )
    ).

-doc """
Announce a local user's nickname change to every peer.

`Client` still holds the old nickname, used as the line's prefix, and `Nick`
is the new one.
""".
-spec propagate_nick_change(#client{}, iodata()) -> ok.
propagate_nick_change(Client, Nick) ->
    server_broadcast(briskd_wire:line(briskd_state_send:prefix(Client), <<"NICK">>, [Nick], none)).

-doc """
Announce a local user's `AWAY` to every peer; `none` clears the away
message.
""".
-spec propagate_away(#client{}, none | iodata()) -> ok.
propagate_away(Client, none) ->
    server_broadcast(briskd_wire:line(briskd_state_send:prefix(Client), <<"AWAY">>, [], none));
propagate_away(Client, Message) ->
    server_broadcast(briskd_wire:line(briskd_state_send:prefix(Client), <<"AWAY">>, [], Message)).

-doc """
Announce a local user's `QUIT` with `Reason` to every peer.
""".
-spec propagate_quit(#client{}, none | iodata()) -> ok.
propagate_quit(Client, Reason) ->
    server_broadcast(briskd_wire:line(briskd_state_send:prefix(Client), <<"QUIT">>, [], Reason)).

-doc """
Send a server line to every authenticated peer.
""".
-spec server_broadcast(iodata()) -> ok.
server_broadcast(Line) ->
    relay_except(undefined, Line).

-doc """
Send a server line to every authenticated peer except the ingress link.

`Ingress` is the peer the line arrived from, or `undefined` for every peer.
An exit from `m:briskd_links` (for example, while it is restarting) is caught
and the line is dropped.
""".
-spec relay_except(undefined | binary(), iodata()) -> ok.
relay_except(Ingress, Line) ->
    try briskd_links:send_except(Ingress, iolist_to_binary(Line)) of
        _ -> ok
    catch
        exit:_ -> ok
    end.

-doc """
Apply a `KILL` of `Nick` received from `Peer`.

The `KILL` is relayed to the other peers with this server as prefix. A local
user with that nickname receives the `KILL` and is disconnected. A remote user
with that nickname is removed and its `QUIT` relayed to the other peers. The
nickname is then held. Always returns `ok`.
""".
-spec receive_remote_kill(binary(), binary(), none | binary()) -> ok.
receive_remote_kill(Peer, Nick, Reason) ->
    Server = local_server(),
    relay_except(Peer, briskd_wire:line(Server, <<"KILL">>, [Nick], Reason)),
    case briskd_state_client:find_nick(Nick) of
        #client{pid = Pid, nick = Actual} = Client ->
            briskd_state_send:send(Pid, Server, <<"KILL">>, [Actual], Reason),
            briskd_state_client:disconnect(Client, Reason, Server);
        undefined ->
            ok
    end,
    case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
        [#remote_client{nick = RemoteNick, user = User, host = Host} = Remote] ->
            Prefix = <<RemoteNick/binary, "!", User/binary, "@", Host/binary>>,
            relay_except(Peer, briskd_wire:line(Prefix, <<"QUIT">>, [], Reason)),
            briskd_state_net:remove_remote_user(Remote);
        [] ->
            ok
    end,
    briskd_state_net:hold_nick(Nick).

-doc "Send a local user's `INVITE` of `Nick` to channel `Name`.".
-spec propagate_invite(#client{}, iodata(), binary(), binary()) -> ok.
propagate_invite(Client, Nick, Name, Peer) ->
    briskd_link_channel:propagate_invite(Client, Nick, Name, Peer).

-doc "Apply an `INVITE` of `Nick` to channel `Name` sent by a remote user.".
-spec receive_remote_invite(binary(), binary(), binary(), binary()) ->
    ok | {error, unknown_remote_nick}.
receive_remote_invite(Peer, Prefix, Nick, Name) ->
    briskd_link_channel:receive_remote_invite(Peer, Prefix, Nick, Name).

-doc "Delete `remote_channel` rows that have no members.".
-spec sweep_remote_channels() -> non_neg_integer().
sweep_remote_channels() ->
    briskd_link_channel:sweep_remote_channels().

-doc "Announce a local user's `TOPIC` change on channel `Name` to every peer.".
-spec propagate_topic(#client{}, iodata(), none | iodata()) -> ok.
propagate_topic(Client, Name, Topic) ->
    briskd_link_channel:propagate_topic(Client, Name, Topic).

-doc "Announce a local user's channel `MODE` change to every peer.".
-spec propagate_channel_mode(#client{}, iodata(), iodata(), [iodata()]) -> ok.
propagate_channel_mode(Client, Name, Mode, Args) ->
    briskd_link_channel:propagate_channel_mode(Client, Name, Mode, Args).

-doc "Announce a local user's `KICK` of `Nick` from channel `Name` to every peer.".
-spec propagate_channel_kick(#client{}, iodata(), iodata(), none | iodata()) -> ok.
propagate_channel_kick(Client, Name, Nick, Reason) ->
    briskd_link_channel:propagate_channel_kick(Client, Name, Nick, Reason).

-doc "Announce a local user joining channel `Name` to every peer.".
-spec propagate_join(#client{}, binary(), [channel_role()]) -> ok.
propagate_join(Client, Name, Roles) ->
    briskd_link_channel:propagate_join(Client, Name, Roles).

-doc "Send prepared lines to every peer that has members of channel `Name`.".
-spec propagate_channel_lines(binary(), [iodata()]) -> ok.
propagate_channel_lines(Name, Lines) ->
    briskd_link_channel:propagate_channel_lines(Name, Lines).

-doc "Open or close a `draft/multiline` batch sent by a remote user.".
-spec receive_remote_batch(binary(), binary(), [binary()], list()) -> ok | {error, term()}.
receive_remote_batch(Peer, Prefix, Params, Tags) ->
    briskd_link_batch:receive_remote_batch(Peer, Prefix, Params, Tags).

-doc "Discard every `draft/multiline` batch that `Peer` opened and did not close.".
-spec forget_peer_batches(binary()) -> ok.
forget_peer_batches(Peer) ->
    briskd_link_batch:forget_peer_batches(Peer).

-doc "Discard any peer `draft/multiline` batch left open for more than 60 seconds.".
-spec expire_peer_batches() -> ok.
expire_peer_batches() ->
    briskd_link_batch:expire_peer_batches().

-doc "Add one `PRIVMSG` or `NOTICE` line to an open peer `draft/multiline` batch.".
-spec remote_batch_line(binary(), binary(), binary(), [binary()], list()) -> ok | {error, term()}.
remote_batch_line(Peer, Prefix, Command, Params, Tags) ->
    briskd_link_batch:remote_batch_line(Peer, Prefix, Command, Params, Tags).

-doc "Send a local user's channel message to every peer with members of `Name`.".
-spec propagate_channel_message(binary(), none | iodata(), binary(), #client{}, [
    {binary(), undefined | binary()}
]) -> ok.
propagate_channel_message(Name, Text, Command, Client, Tags) ->
    briskd_link_msg:propagate_channel_message(Name, Text, Command, Client, Tags).
