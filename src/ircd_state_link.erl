-module(ircd_state_link).
-moduledoc """
Server-link burst, import, and propagation of users, channels, and messages
(RFC 2813).

The functions run inside the `m:ircd_state` process, the single writer of the
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
`ircd_wire:fold/1`.
""".
-export([
    expire_peer_batches/0,
    import_remote_join/3,
    import_remote_nick/3,
    receive_remote_invite/4,
    import_remote_njoin/3,
    flush_netjoin/1,
    forget_peer_batches/1,
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
    update_remote_modes/5,
    update_remote_topic/4
]).
-include("ircd_state.hrl").

%% Open draft/multiline batches kept per peer link.
-define(MAX_PEER_BATCHES, 10).

-doc """
Every line of the state burst sent to a newly authenticated peer (RFC 2813
section 5.3.2).

`Server` is the local server name, used as the prefix of server-generated
lines. The order is: known servers nearest first, registered local users as
`NICK`, remote users (prefixed by their home server), IRCv3 account state
from `ircd_state_v3:burst_lines/1`, local channels (`NJOIN`, modes, list
entries, `+O` creator, topic), accounts, metadata, and read markers from
`ircd_state_sync:burst_lines/1`, and finally remote channels. Members are
packed into as few `NJOIN` lines as fit in 512 octets.
""".
-spec server_burst_lines(binary()) -> [iodata()].
server_burst_lines(Server) ->
    ServerLines = ircd_state_net:burst_server_lines(Server),
    ClientLines =
        lists:flatmap(
            fun(Pid) ->
                case mnesia:dirty_read(client, Pid) of
                    [#client{} = Client] ->
                        case ircd_state_client:ready(Client) of
                            true -> client_burst_lines(Client, Server);
                            false -> []
                        end;
                    _ ->
                        []
                end
            end,
            ircd_state_client:pids()
        ),
    ChannelLines =
        lists:flatmap(
            fun(Key) ->
                case mnesia:dirty_read(channel, Key) of
                    [#channel{} = Channel] -> channel_burst_lines(Channel, Server);
                    [] -> []
                end
            end,
            ircd_state:table_keys(channel)
        ),
    ServerLines ++ ClientLines ++ remote_client_burst_lines() ++
        ircd_state_v3:burst_lines(Server) ++ ChannelLines ++ ircd_state_sync:burst_lines(Server) ++
        remote_channel_burst_lines(Server) ++ ircd_e2ee:burst_lines().

client_burst_lines(
    #client{nick = Nick, user = User, host = Host, real = Real, pid = Pid}, Server
) ->
    Modes = ircd_state_channel:user_mode_string(ircd_state_client:user_modes(Pid)),
    [
        iolist_to_binary(
            ircd_wire:line(
                Server,
                <<"NICK">>,
                [Nick, <<"0">>, User, Host, <<"1">>, Modes],
                Real
            )
        )
    ].

remote_client_burst_lines() ->
    lists:flatmap(
        fun(Key) ->
            case mnesia:dirty_read(remote_client, Key) of
                [#remote_client{server = Home, peer = Peer} = Remote] ->
                    Prefix =
                        case Home of
                            undefined -> Peer;
                            _ -> Home
                        end,
                    [iolist_to_binary(stored_nick_line(Prefix, Remote))];
                [] ->
                    []
            end
        end,
        ircd_state:table_keys(remote_client)
    ).

stored_nick_line(
    Prefix,
    #remote_client{
        nick = Nick, hop = Hop, user = User, host = Host, token = Token, modes = Modes, real = Real
    }
) ->
    remote_nick_line(Prefix, Nick, Hop, User, Host, Token, Modes, Real).

remote_channel_burst_lines(Server) ->
    lists:flatmap(
        fun(Key) ->
            case mnesia:dirty_read(remote_channel, Key) of
                [#remote_channel{} = Channel] -> remote_channel_lines(Channel, Server);
                [] -> []
            end
        end,
        ircd_state:table_keys(remote_channel)
    ).

remote_channel_lines(#remote_channel{name = Name, members = Members, flags = Flags}, Server) ->
    Tokens = [
        remote_njoin_token(Remote#remote_client.nick, Roles)
     || {NickKey, {_Peer, Roles}} <- maps:to_list(Members),
        [#remote_client{} = Remote] <- [mnesia:dirty_read(remote_client, NickKey)]
    ],
    ModeFlags = maps:from_keys([Key || Key <- maps:keys(Flags), is_integer(Key)], true),
    TopicLines =
        case maps:get(topic, Flags, <<>>) of
            <<>> -> [];
            Topic -> [ircd_wire:line(Server, <<"TOPIC">>, [Name], Topic)]
        end,
    njoin_lines(Name, Tokens, Server) ++
        channel_mode_burst(
            Name,
            ModeFlags,
            maps:get(key, Flags, undefined),
            maps:get(limit, Flags, undefined),
            maps:with([ban, exception, invite], Flags),
            Server
        ) ++ TopicLines.

remote_njoin_token(Nick, Roles) ->
    case
        {lists:member(creator, Roles), lists:member(operator, Roles), lists:member(voice, Roles)}
    of
        {true, _, true} -> <<"@@+", Nick/binary>>;
        {true, _, false} -> <<"@@", Nick/binary>>;
        {false, true, true} -> <<"@+", Nick/binary>>;
        {false, true, false} -> <<$@, Nick/binary>>;
        {false, false, true} -> <<$+, Nick/binary>>;
        _ -> Nick
    end.

channel_burst_lines(
    #channel{
        name = Name,
        members = Members,
        flags = Flags,
        lists = Lists,
        creator = Creator,
        password = Password,
        limit = Limit,
        topic = Topic
    },
    Server
) ->
    LiveMembers =
        [
            {Pid, Client, Roles}
         || {Pid, Roles} <- maps:to_list(Members),
            [#client{} = Client] <- [mnesia:dirty_read(client, Pid)],
            ircd_state_client:ready(Client)
        ],
    NjoinLines =
        njoin_lines(
            Name,
            [njoin_member(Client, Roles) || {_Pid, Client, Roles} <- LiveMembers],
            Server
        ),
    CreatorLines =
        case lists:keyfind(Creator, 1, LiveMembers) of
            {Creator, CreatorClient, _} ->
                [
                    ircd_wire:line(
                        Server,
                        <<"MODE">>,
                        [Name, <<"+O">>, CreatorClient#client.nick],
                        none
                    )
                ];
            false ->
                []
        end,
    TopicLines =
        case Topic of
            <<>> -> [];
            _ -> [ircd_wire:line(Server, <<"TOPIC">>, [Name], Topic)]
        end,
    NjoinLines ++ channel_mode_burst(Name, Flags, Password, Limit, Lists, Server) ++
        CreatorLines ++ TopicLines.

njoin_member(#client{nick = Nick}, Roles) ->
    remote_njoin_token(Nick, Roles).

njoin_lines(_Name, [], _Server) ->
    [];
njoin_lines(Name, Members, Server) ->
    PrefixSize = byte_size(Server) + byte_size(Name) + 11,
    MaxMembers = max(1, 510 - PrefixSize),
    Batches = member_batches(Members, MaxMembers, [], 0, []),
    [ircd_wire:line(Server, <<"NJOIN">>, [Name], lists:join(<<$,>>, Batch)) || Batch <- Batches].

member_batches([], _Max, [], _Size, Batches) ->
    lists:reverse(Batches);
member_batches([], _Max, Current, _Size, Batches) ->
    lists:reverse([lists:reverse(Current) | Batches]);
member_batches([Member | Rest], Max, Current, Size, Batches) ->
    AddedSize =
        byte_size(Member) +
            case Current of
                [] -> 0;
                _ -> 1
            end,
    case Size + AddedSize =< Max of
        true ->
            member_batches(Rest, Max, [Member | Current], Size + AddedSize, Batches);
        false when Current =:= [] ->
            member_batches(Rest, Max, [Member], byte_size(Member), Batches);
        false ->
            member_batches(
                [Member | Rest], Max, [], 0, [lists:reverse(Current) | Batches]
            )
    end.

channel_mode_burst(Name, Flags, Password, Limit, Lists, Server) ->
    KeyMode =
        case Password of
            undefined -> [];
            _ -> [$k]
        end,
    LimitMode =
        case Limit of
            undefined -> [];
            _ -> [$l]
        end,
    Modes = lists:sort(maps:keys(Flags)) ++ KeyMode ++ LimitMode,
    Args =
        (case Password of
            undefined -> [];
            _ -> [Password]
        end) ++
            (case Limit of
                undefined -> [];
                _ -> [integer_to_binary(Limit)]
            end),
    FlagLines =
        case Modes of
            [] ->
                [];
            _ ->
                [
                    ircd_wire:line(
                        Server, <<"MODE">>, [Name, list_to_binary([$+ | Modes]) | Args], none
                    )
                ]
        end,
    AccessLines =
        lists:flatmap(
            fun({Type, Mode}) ->
                [
                    ircd_wire:line(Server, <<"MODE">>, [Name, <<$+, Mode>>, Mask], none)
                 || Mask <- maps:get(Type, Lists, [])
                ]
            end,
            [{ban, $b}, {exception, $e}, {invite, $I}]
        ),
    FlagLines ++ AccessLines.
-doc """
True when `Nick` belongs to a user behind a server link.
""".
-spec remote_nick_exists(binary()) -> boolean().
remote_nick_exists(Nick) ->
    mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) =/= [].

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
    Key = ircd_wire:fold(Nick),
    case
        {
            ircd_wire:nickname(Nick, ircd_state:nicklen()),
            Key =/= <<"anonymous">>,
            ircd_route:valid_decimal(Token),
            re:run(User, <<"^[A-Za-z0-9_.-]{1,32}$">>, [{capture, none}, dollar_endonly]),
            valid_server_host(Host),
            server_user_modes(ModeString),
            ircd_state_client:find_nick(Nick),
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
                    ircd_state_monitor:online(
                        Nick, <<Nick/binary, "!", User/binary, "@", Host/binary>>
                    ),
                    ircd_state_meta:forget_remote(Key),
                    relay_except(
                        Peer,
                        remote_nick_line(Home, Nick, Distance, User, Host, Token, Modes, Real)
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
    case ircd_route:valid_decimal(Hop) of
        false ->
            {error, invalid_hopcount};
        true ->
            Distance = binary_to_integer(Hop) + 1,
            case ircd_wire:fold(Prefix) =:= ircd_wire:fold(Peer) of
                true ->
                    {ok, Peer, Distance};
                false ->
                    case mnesia:dirty_read(known_server, ircd_wire:fold(Prefix)) of
                        [#known_server{name = Name, hop = HopCount, adjacent = Adjacent}] ->
                            case
                                ircd_wire:fold(Adjacent) =:= ircd_wire:fold(Peer) andalso
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
    case ircd_route:nick_collision(true, true) of
        kill_both ->
            Server = local_server(),
            Reason = <<"Nick collision">>,
            Local = ircd_state_client:find_nick(Nick),
            Remote =
                case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                    [#remote_client{} = Row] -> Row;
                    [] -> undefined
                end,
            Actual = collision_nick(Nick, Local, Remote),
            server_broadcast(ircd_wire:line(Server, <<"KILL">>, [Actual], Reason)),
            case Local of
                #client{pid = Pid} = Client ->
                    ircd_state_send:send(Pid, Server, <<"KILL">>, [Actual], Reason),
                    ircd_state_client:disconnect(Client, Reason, Server);
                undefined ->
                    ok
            end,
            case Remote of
                #remote_client{user = User, host = Host} ->
                    Prefix = <<Actual/binary, "!", User/binary, "@", Host/binary>>,
                    server_broadcast(ircd_wire:line(Prefix, <<"QUIT">>, [], Reason)),
                    ircd_state_net:remove_remote_user(Remote);
                undefined ->
                    ok
            end,
            ircd_state_net:hold_nick(Actual)
    end.

collision_nick(_Nick, #client{nick = Actual}, _) ->
    Actual;
collision_nick(_Nick, _, #remote_client{nick = Actual}) ->
    Actual;
collision_nick(Nick, _, _) ->
    Nick.

write_remote_nick(Peer, Home, Distance, Key, Nick, User, Host, Token, Modes, Real) ->
    mnesia:dirty_write(
        ircd_wire:retain_fields(#remote_client{
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
    ).

remote_nick_line(Prefix, Nick, Hop, User, Host, Token, Modes, Real) ->
    ircd_wire:line(
        Prefix,
        <<"NICK">>,
        [
            Nick,
            integer_to_binary(Hop),
            User,
            Host,
            Token,
            ircd_state_channel:user_mode_string(Modes)
        ],
        Real
    ).

local_server() ->
    maps:get(name, ircd_config:current()).

peer_user_room(Peer) ->
    Max = maps:get(max_peer_users, ircd_config:current_or_empty(), 10000),
    FoldedPeer = ircd_wire:fold(Peer),
    Count = length([
        K
     || K <- ircd_state:table_keys(remote_client),
        [#remote_client{peer = P}] <- [mnesia:dirty_read(remote_client, K)],
        ircd_wire:fold(P) =:= FoldedPeer
    ]),
    Count < Max.

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
    NewKey = ircd_wire:fold(Nick),
    case remote_source(Peer, Prefix) of
        {ok, #remote_client{key = OldKey} = Remote} ->
            case
                {
                    ircd_wire:nickname(Nick, ircd_state:nicklen()),
                    NewKey =/= <<"anonymous">>,
                    ircd_state_client:find_nick(Nick),
                    mnesia:dirty_read(remote_client, NewKey)
                }
            of
                {true, true, undefined, []} ->
                    show_remote_event(OldKey, Prefix, <<"NICK">>, Nick),
                    mnesia:dirty_delete(remote_client, OldKey),
                    mnesia:dirty_write(
                        ircd_wire:retain_fields(Remote#remote_client{key = NewKey, nick = Nick})
                    ),
                    rename_remote_memberships(Peer, OldKey, NewKey),
                    ircd_state_meta:rename_remote(OldKey, NewKey),
                    ok = ircd_e2ee:remote_renamed(OldKey, NewKey),
                    ok = ircd_calls:remote_renamed(OldKey, NewKey),
                    ircd_state_monitor:offline(Remote#remote_client.nick),
                    ircd_state_monitor:online(
                        Nick,
                        <<Nick/binary, "!", (Remote#remote_client.user)/binary, "@",
                            (Remote#remote_client.host)/binary>>
                    ),
                    relay_except(Peer, ircd_wire:line(Prefix, <<"NICK">>, [Nick], none)),
                    ok;
                {true, true, undefined, [#remote_client{key = OldKey, peer = Peer}]} when
                    Nick =:= Remote#remote_client.nick
                ->
                    ok;
                {true, true, undefined, [#remote_client{key = OldKey, peer = Peer}]} ->
                    show_remote_event(OldKey, Prefix, <<"NICK">>, Nick),
                    mnesia:dirty_write(ircd_wire:retain_fields(Remote#remote_client{nick = Nick})),
                    relay_except(Peer, ircd_wire:line(Prefix, <<"NICK">>, [Nick], none)),
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
            relay_except(Peer, ircd_wire:line(Prefix, <<"QUIT">>, [], Reason)),
            mnesia:dirty_delete(remote_client, Key),
            ircd_state_monitor:offline(Nick),
            ircd_state_meta:forget_remote(Key),
            ok = ircd_e2ee:forget_remote(Key),
            ok = ircd_calls:remote_gone(Key),
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
            mnesia:dirty_write(ircd_wire:retain_fields(Remote#remote_client{modes = Modes})),
            AwayTail =
                case Params of
                    [] -> none;
                    [Text | _] -> Text
                end,
            ircd_state_v3:notify_remote(
                Remote, Prefix, <<"away-notify">>, <<"AWAY">>, [], AwayTail
            ),
            AwayLine =
                case Params of
                    [] -> ircd_wire:line(Prefix, <<"AWAY">>, [], none);
                    [Message | _] -> ircd_wire:line(Prefix, <<"AWAY">>, [], Message)
                end,
            relay_except(Peer, AwayLine),
            ok;
        error ->
            {error, unknown_remote_nick}
    end.

%% Show a remote user's NICK or QUIT to the local clients that share a
%% channel with it. Anonymous and quiet channels are skipped, as in
%% remote_user_local_recipients/1, so the real prefix is never exposed there.
%% ircd_state has already set the message source to Prefix for this line.
show_remote_event(Key, Prefix, Command, Tail) ->
    ircd_state_send:broadcast(remote_user_local_recipients(Key), Prefix, Command, [], Tail).

-doc """
The remote user that `Prefix` names, when it may speak on the link `Peer`.

`Prefix` must be the exact `nick!user@host` of a `remote_client` row whose
adjacent link is `Peer`; anything else, including a server name, is `error`.
""".
-spec remote_source(binary(), binary()) -> {ok, #remote_client{}} | error.
remote_source(Peer, Prefix) ->
    case binary:split(Prefix, <<"!">>) of
        [Nick, _UserHost] ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
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

-doc """
Apply a `TOPIC` change for channel `Name` received from `Peer`.

A server prefix trusted for `Peer` may always set the topic. A user prefix
must belong to a member reached through `Peer`, and that member needs
channel operator status when `+t` is set on the remote or local channel. The
topic is stored on the remote channel and on the local channel of the same
name, whose members see the `TOPIC` (with the anonymous prefix on a `+a`
channel), and the line is relayed to the other peers.

Errors: `invalid_channel`, `unknown_remote_source`, `unknown_remote_channel`,
`remote_user_not_on_channel`, and `remote_topic_requires_operator`.
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
    Key = ircd_wire:fold(Name),
    case {ircd_wire:channel(Name), trusted_server(Peer, Prefix)} of
        {false, _} ->
            {error, invalid_channel};
        {true, true} ->
            store_remote_topic(Peer, Prefix, Key, Name, Topic);
        {true, false} ->
            case {remote_source(Peer, Prefix), mnesia:dirty_read(remote_channel, Key)} of
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
    Remote =
        case mnesia:dirty_read(remote_channel, Key) of
            [#remote_channel{} = RemoteRecord] -> RemoteRecord;
            [] -> #remote_channel{key = Key, name = Name}
        end,
    Flags = (Remote#remote_channel.flags)#{topic => ircd_wire:retain(Topic)},
    mnesia:dirty_write(ircd_wire:retain_fields(Remote#remote_channel{flags = Flags})),
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Canonical, members = Members, flags = ChannelFlags} = Channel] ->
            mnesia:dirty_write(Channel#channel{topic = ircd_wire:retain(Topic)}),
            EventPrefix =
                case
                    maps:is_key($a, ChannelFlags) orelse
                        maps:is_key($a, Remote#remote_channel.flags)
                of
                    true -> <<"anonymous!anonymous@anonymous.">>;
                    false -> Prefix
                end,
            ircd_state_send:broadcast(
                maps:keys(Members), EventPrefix, <<"TOPIC">>, [Canonical], Topic
            );
        [] ->
            ok
    end,
    relay_except(Peer, ircd_wire:line(Prefix, <<"TOPIC">>, [Name], Topic)),
    ok.

local_channel_mode(Key, Mode) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{flags = Flags}] -> maps:is_key(Mode, Flags);
        [] -> false
    end.

-doc """
True when `Prefix` is the adjacent peer `Peer` or a known server reached
through `Peer`.
""".
-spec trusted_server(binary(), binary()) -> boolean().
trusted_server(Peer, Prefix) ->
    case ircd_wire:fold(Prefix) =:= ircd_wire:fold(Peer) of
        true ->
            true;
        false ->
            case mnesia:dirty_read(known_server, ircd_wire:fold(Prefix)) of
                [#known_server{adjacent = Adjacent}] ->
                    ircd_wire:fold(Adjacent) =:= ircd_wire:fold(Peer);
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
                            );
                        _ ->
                            ok
                    end;
                _ ->
                    ok
            end
        end,
        ircd_state:table_keys(remote_channel)
    ).

remove_remote_memberships(Peer, NickKey) ->
    lists:foreach(
        fun(ChannelKey) ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{members = Members} = Channel] ->
                    case Members of
                        #{NickKey := {Peer, _Roles}} ->
                            Remaining = maps:remove(NickKey, Members),
                            case map_size(Remaining) of
                                0 ->
                                    mnesia:dirty_delete(remote_channel, ChannelKey);
                                _ ->
                                    mnesia:dirty_write(
                                        ircd_wire:retain_fields(Channel#remote_channel{
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
        ircd_state:table_keys(remote_channel)
    ).

-doc """
Import an `NJOIN` (RFC 2813 section 4.2.2) for channel `Name` from `Peer`.

`Members` is the comma-separated member list; `@@` marks the channel creator,
`@` an operator, and `+` a voiced member, stacked as `@@+` or `@+`. Every nickname must be a remote
user reached through `Peer`. Members are added to the remote channel. Members
that are new are shown to local channel members as `JOIN`s collected into one
IRCv3 `netjoin` batch per peer, sent by `flush_netjoin/1` when the peer sends
a non-burst command, when its link closes, or one second after the first
collected join. The `NJOIN` is relayed to the other peers with this server as
prefix.

Errors: `invalid_channel`, `empty_njoin`, `unknown_remote_member`, and
`remote_member_from_other_peer`.
""".
-spec import_remote_njoin(binary(), binary(), binary()) ->
    ok
    | {error,
        empty_njoin | invalid_channel | remote_member_from_other_peer | unknown_remote_member}.
import_remote_njoin(Peer, Name, Members) ->
    case ircd_wire:channel(Name) of
        false ->
            {error, invalid_channel};
        true ->
            case parse_remote_members(Peer, binary:split(Members, <<$,>>, [global]), []) of
                {ok, Parsed} when Parsed =/= [] ->
                    Key = ircd_wire:fold(Name),
                    Existing =
                        case mnesia:dirty_read(remote_channel, Key) of
                            [#remote_channel{} = Channel] -> Channel;
                            [] -> #remote_channel{key = Key, name = Name}
                        end,
                    Previous = Existing#remote_channel.members,
                    NewMembers = lists:foldl(
                        fun({NickKey, Roles}, Acc) -> Acc#{NickKey => {Peer, Roles}} end,
                        Previous,
                        Parsed
                    ),
                    mnesia:dirty_write(Existing#remote_channel{members = NewMembers}),
                    Joined = [K || {K, _} <- Parsed, not maps:is_key(K, Previous)],
                    show_netjoin(Name, Joined, Peer),
                    relay_except(
                        Peer, ircd_wire:line(local_server(), <<"NJOIN">>, [Name], Members)
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
%% types). RFC 2813 bursts have no end marker, so joins are collected per peer
%% and flushed when the peer sends a non-burst command, when its link closes,
%% or one second after the first collected join.
show_netjoin(_Name, [], _Peer) ->
    ok;
show_netjoin(Name, Joined, Peer) ->
    Pending =
        case get({ircd_netjoin, Peer}) of
            undefined ->
                erlang:send_after(1000, self(), {flush_netjoin, Peer}),
                [];
            List ->
                List
        end,
    put({ircd_netjoin, Peer}, lists:reverse([{Name, Key} || Key <- Joined], Pending)),
    ok.

-doc """
Send the `JOIN`s collected from `Peer`'s `NJOIN` burst lines to local
channel members in one IRCv3 `netjoin` batch.

Members that left again before the flush are skipped. Does nothing when no
joins are pending for `Peer`.
""".
-spec flush_netjoin(binary()) -> ok.
flush_netjoin(Peer) ->
    case erase({ircd_netjoin, Peer}) of
        undefined ->
            ok;
        Reversed ->
            ircd_state_send:begin_batch(<<"netjoin">>, [local_server(), Peer], [<<"JOIN">>]),
            try
                lists:foreach(
                    fun({Name, Key}) ->
                        case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
                            [#remote_channel{members = Members}] when is_map_key(Key, Members) ->
                                broadcast_remote_join(Name, Key);
                            _ ->
                                ok
                        end
                    end,
                    lists:reverse(Reversed)
                )
            after
                ircd_state_send:end_batch()
            end
    end.

-doc """
Apply a `JOIN` of channel `Name` by a remote user.

`Peer` is the adjacent link the line arrived on and `Prefix` its source
prefix, which must be the exact `nick!user@host` of a remote user reached
through `Peer`. The user is added as a
plain member, creating the remote channel row if needed; local members of the
channel see the `JOIN` and the line is relayed to the other peers. A user who
is already a member is ignored.

Errors: `unknown_remote_source` and `invalid_channel`.
""".
-spec import_remote_join(binary(), binary(), binary()) ->
    ok | {error, invalid_channel | unknown_remote_source}.
import_remote_join(Peer, Prefix, Name) ->
    case {remote_source(Peer, Prefix), ircd_wire:channel(Name)} of
        {{ok, #remote_client{key = NickKey}}, true} ->
            Key = ircd_wire:fold(Name),
            Channel =
                case mnesia:dirty_read(remote_channel, Key) of
                    [#remote_channel{} = Existing] -> Existing;
                    [] -> #remote_channel{key = Key, name = Name}
                end,
            Members = Channel#remote_channel.members,
            case maps:is_key(NickKey, Members) of
                true ->
                    ok;
                false ->
                    mnesia:dirty_write(
                        Channel#remote_channel{members = Members#{NickKey => {Peer, [member]}}}
                    ),
                    broadcast_remote_join(Name, NickKey),
                    relay_except(Peer, ircd_wire:line(Prefix, <<"JOIN">>, [Name], none)),
                    ok
            end;
        {error, _} ->
            {error, unknown_remote_source};
        {_, false} ->
            {error, invalid_channel}
    end.

-doc """
Apply a `PART` of channel `Name` by a remote user, with optional `Reason`.

`Peer` is the adjacent link the line arrived on and `Prefix` its source
prefix, which must be the exact `nick!user@host` of a remote user reached
through `Peer`. Local members of the
channel see the `PART`, the membership is removed (deleting a remote channel
left empty), and the line is relayed to the other peers.

Errors: `unknown_remote_source`, `unknown_remote_channel`, and
`remote_user_not_on_channel`.
""".
-spec remove_remote_channel_member(binary(), binary(), binary(), none | iodata()) ->
    ok | {error, remote_user_not_on_channel | unknown_remote_channel | unknown_remote_source}.
remove_remote_channel_member(Peer, Prefix, Name, Reason) ->
    case {remote_source(Peer, Prefix), mnesia:dirty_read(remote_channel, ircd_wire:fold(Name))} of
        {{ok, #remote_client{key = NickKey}}, [#remote_channel{members = Members} = Channel]} ->
            case Members of
                #{NickKey := {Peer, _Roles}} ->
                    broadcast_remote_channel_event(Name, Prefix, <<"PART">>, Reason),
                    Remaining = maps:remove(NickKey, Members),
                    case map_size(Remaining) of
                        0 ->
                            mnesia:dirty_delete(remote_channel, Channel#remote_channel.key);
                        _ ->
                            mnesia:dirty_write(
                                ircd_wire:retain_fields(Channel#remote_channel{members = Remaining})
                            )
                    end,
                    relay_except(Peer, ircd_wire:line(Prefix, <<"PART">>, [Name], Reason)),
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

`Peer` is the adjacent link the line arrived on and `Prefix` its source
prefix, which must be the exact `nick!user@host` of a remote user reached
through `Peer`. The kicker must be an
operator or the creator of the channel through `Peer`. A local target is
removed from the local channel (which is released when it becomes empty);
a remote target is removed from the remote channel. Local members see the
`KICK` (with the anonymous prefix on a `+a` channel), and the line is relayed
to the other peers.

Errors: `unknown_remote_source`, `unknown_remote_channel`,
`remote_kick_requires_operator`, `remote_kick_target_not_on_channel`, and
`unknown_remote_kick_target`.
""".
-spec receive_remote_kick(binary(), binary(), binary(), binary(), none | iodata()) ->
    ok
    | {error,
        remote_kick_requires_operator
        | remote_kick_target_not_on_channel
        | unknown_remote_channel
        | unknown_remote_kick_target
        | unknown_remote_source}.
receive_remote_kick(Peer, Prefix, Name, Nick, Reason) ->
    Key = ircd_wire:fold(Name),
    case {remote_source(Peer, Prefix), mnesia:dirty_read(remote_channel, Key)} of
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
    case ircd_state_client:find_nick(Nick) of
        #client{pid = TargetPid, nick = Actual} = Target ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{members = Members} = Channel] when is_map_key(TargetPid, Members) ->
                    broadcast_kick(Channel, Prefix, Actual, Reason),
                    Remaining = maps:remove(TargetPid, Members),
                    case map_size(Remaining) of
                        0 ->
                            ircd_state_channel:release_if_empty(Channel, Remaining);
                        _ ->
                            mnesia:dirty_write(ircd_state_channel:track_opless(Channel, Remaining))
                    end,
                    mnesia:dirty_write(Target#client{
                        channels = lists:delete(Key, Target#client.channels)
                    }),
                    remove_remote_channel_member_record(
                        Peer, ircd_wire:fold(Actual), RemoteChannel
                    ),
                    relay_except(Peer, ircd_wire:line(Prefix, <<"KICK">>, [Name, Actual], Reason)),
                    ok;
                _ ->
                    {error, remote_kick_target_not_on_channel}
            end;
        undefined ->
            TargetKey = ircd_wire:fold(Nick),
            case maps:find(TargetKey, RemoteChannel#remote_channel.members) of
                {ok, {_TargetPeer, _TargetRoles}} ->
                    case mnesia:dirty_read(remote_client, TargetKey) of
                        [#remote_client{nick = Actual}] ->
                            broadcast_kick_by_name(Name, Prefix, Actual, Reason),
                            remove_remote_channel_member_record(Peer, TargetKey, RemoteChannel),
                            relay_except(
                                Peer, ircd_wire:line(Prefix, <<"KICK">>, [Name, Actual], Reason)
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
    Members = maps:remove(NickKey, Channel#remote_channel.members),
    case map_size(Members) of
        0 -> mnesia:dirty_delete(remote_channel, Key);
        _ -> mnesia:dirty_write(ircd_wire:retain_fields(Channel#remote_channel{members = Members}))
    end,
    ok.

broadcast_kick(#channel{name = Name, members = Members, flags = Flags}, Prefix, Nick, Reason) ->
    EventPrefix =
        case maps:is_key($a, Flags) of
            true -> <<"anonymous!anonymous@anonymous.">>;
            false -> Prefix
        end,
    ircd_state_send:broadcast(maps:keys(Members), EventPrefix, <<"KICK">>, [Name, Nick], Reason).

broadcast_kick_by_name(Name, Prefix, Nick, Reason) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{} = Channel] -> broadcast_kick(Channel, Prefix, Nick, Reason);
        [] -> ok
    end.

%% Show a remote member joining a local channel. extended-join clients get the
%% account and realname; away-notify clients learn that the member is away.
broadcast_remote_join(Name, NickKey) ->
    case
        {
            mnesia:dirty_read(channel, ircd_wire:fold(Name)),
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
                    ircd_state_send:broadcast(
                        maps:keys(Members),
                        <<"anonymous!anonymous@anonymous.">>,
                        <<"JOIN">>,
                        [Canonical],
                        none
                    );
                false ->
                    Prefix = <<N/binary, "!", U/binary, "@", H/binary>>,
                    ircd_state_send:with_source(ircd_state_v3:remote_source_info(Prefix), fun() ->
                        ircd_state_v3:join_broadcast(
                            maps:keys(Members), Prefix, Canonical, Account, Real
                        )
                    end),
                    case maps:is_key($a, Modes) of
                        true ->
                            ircd_state_v3:away_on_join(maps:keys(Members), Prefix, <<"Away">>);
                        false ->
                            ok
                    end
            end;
        _ ->
            ok
    end.

broadcast_remote_channel_event(Name, Prefix, Command, Reason) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, flags = Flags}] ->
            EventPrefix =
                case maps:is_key($a, Flags) of
                    true -> <<"anonymous!anonymous@anonymous.">>;
                    false -> Prefix
                end,
            ircd_state_send:broadcast(
                maps:keys(Members), EventPrefix, Command, [Canonical], Reason
            );
        [] ->
            ok
    end.

parse_remote_members(_Peer, [], Acc) ->
    {ok, lists:reverse(Acc)};
parse_remote_members(Peer, [RawMember | Rest], Acc) ->
    {Roles, Nick} = remote_member(RawMember),
    Key = ircd_wire:fold(Nick),
    case {ircd_wire:nickname(Nick, ircd_state:nicklen()), mnesia:dirty_read(remote_client, Key)} of
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
Apply a `MODE` from `Peer` to a channel or to a remote user.

For a channel, a server prefix trusted for `Peer` is accepted and creates the
remote channel if it is unknown; such changes are stored silently, as in a
burst. A user prefix must be an operator or creator member reached through
`Peer`, and its change is also shown to local members. Supported letters are
`a i m n p q r s t K`, `k <key>`, `l <limit>` (positive), `b`/`e`/`I <mask>`
(each list capped at the server's list limit), and `o`/`v`/`O <nick>`. The
result is stored on the remote channel, copied to the local channel of the
same name, and relayed to the other peers. An `o`/`v`/`O` target that is not
a remote member may be a local member of the local channel of the same name:
its roles (or, for `O`, the channel creator) are updated there, and the
change is shown to local members even when the source is a server.

For a user target, `Prefix` must be that remote user; letters `a i o w B` are
applied and others ignored, local users sharing a channel see the change, and
it is relayed.

Errors: `unknown_remote_channel`, `remote_mode_requires_operator`,
`missing_mode_argument`, `missing_channel_limit`, `invalid_channel_limit`,
`unknown_remote_mode_target`, `{unsupported_channel_mode, Char}`,
`{extra_mode_arguments, Args}`, `unknown_remote_source`, and
`remote_user_mode_source_mismatch`.
""".
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
        | {extra_mode_arguments, term()}
        | {unsupported_channel_mode, byte()}}.
update_remote_modes(Peer, Prefix, Name, ModeString, Args) ->
    case ircd_wire:channel(Name) of
        false -> update_remote_user_modes(Peer, Prefix, Name, ModeString);
        true -> update_remote_channel_modes(Peer, Prefix, Name, ModeString, Args)
    end.

update_remote_channel_modes(Peer, Prefix, Name, ModeString, Args) ->
    Key = ircd_wire:fold(Name),
    %% A relayed MODE keeps the upstream server prefix. Trust that prefix when
    %% the named server is this link or was introduced through it.
    TrustedServer = trusted_server(Peer, Prefix),
    Channel =
        case mnesia:dirty_read(remote_channel, Key) of
            [#remote_channel{} = ExistingRecord] -> ExistingRecord;
            [] when TrustedServer -> #remote_channel{key = Key, name = Name};
            [] -> undefined
        end,
    case Channel of
        undefined ->
            {error, unknown_remote_channel};
        #remote_channel{members = Members} = ChannelRecord ->
            Authorized =
                case TrustedServer of
                    true ->
                        true;
                    false ->
                        case remote_source(Peer, Prefix) of
                            {ok, #remote_client{key = NickKey}} ->
                                case Members of
                                    #{NickKey := {Peer, Roles}} ->
                                        lists:member(operator, Roles) orelse
                                            lists:member(creator, Roles);
                                    #{} ->
                                        false
                                end;
                            error ->
                                false
                        end
                end,
            case Authorized of
                false ->
                    {error, remote_mode_requires_operator};
                true ->
                    case
                        %% Letters before any sign are additions, as in the
                        %% local MODE handler.
                        apply_remote_modes(
                            binary_to_list(ModeString), add, Args, ChannelRecord, []
                        )
                    of
                        {ok, Updated, [], LocalRoles} ->
                            mnesia:dirty_write(Updated),
                            synchronize_local_channel(Updated),
                            apply_local_roles(Key, LocalRoles),
                            relay_except(
                                Peer,
                                ircd_wire:line(Prefix, <<"MODE">>, [Name, ModeString | Args], none)
                            ),
                            %% A server MODE is stored silently, as in a burst,
                            %% unless it changes the status of a local member.
                            case TrustedServer andalso LocalRoles =:= [] of
                                true -> ok;
                                false -> broadcast_remote_mode(Name, Prefix, ModeString, Args)
                            end;
                        {ok, _Updated, Remaining, _LocalRoles} ->
                            {error, {extra_mode_arguments, Remaining}};
                        Error ->
                            Error
                    end
            end
    end.

synchronize_local_channel(#remote_channel{key = Key, flags = RemoteFlags}) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{} = Channel] ->
            ModeKeys = [$a, $i, $m, $n, $p, $q, $r, $s, $t, $K],
            Flags = #{M => true || M <- ModeKeys, is_map_key(M, RemoteFlags)},
            Lists = maps:with([ban, exception, invite], RemoteFlags),
            mnesia:dirty_write(Channel#channel{
                flags = Flags,
                password = maps:get(key, RemoteFlags, undefined),
                limit = maps:get(limit, RemoteFlags, undefined),
                lists = Lists
            });
        [] ->
            ok
    end.

%% Local accumulates {Pid, Role, Action} for `o`, `v`, and `O` changes that
%% target a member of the local channel of the same name; they are applied by
%% apply_local_roles/2 after the remote channel row is written.
apply_remote_modes([], _Action, Args, Channel, Local) ->
    {ok, Channel, Args, lists:reverse(Local)};
apply_remote_modes([$+ | Rest], _Action, Args, Channel, Local) ->
    apply_remote_modes(Rest, add, Args, Channel, Local);
apply_remote_modes([$- | Rest], _Action, Args, Channel, Local) ->
    apply_remote_modes(Rest, remove, Args, Channel, Local);
apply_remote_modes(
    [Mode | Rest], Action, Args, #remote_channel{flags = Flags} = Channel, Local
) when
    Mode =:= $a;
    Mode =:= $i;
    Mode =:= $m;
    Mode =:= $n;
    Mode =:= $p;
    Mode =:= $s;
    Mode =:= $t;
    Mode =:= $r;
    Mode =:= $K;
    Mode =:= $q
->
    NewFlags =
        case {Mode, Action} of
            {$p, add} -> (maps:remove($s, Flags))#{$p => true};
            {$s, add} -> (maps:remove($p, Flags))#{$s => true};
            {_, add} -> Flags#{Mode => true};
            {_, remove} -> maps:remove(Mode, Flags)
        end,
    apply_remote_modes(Rest, Action, Args, Channel#remote_channel{flags = NewFlags}, Local);
apply_remote_modes(
    [$k | Rest], Action, [Key | Args], #remote_channel{flags = Flags} = Channel, Local
) ->
    NewFlags =
        case Action of
            add -> Flags#{key => ircd_wire:retain(Key)};
            remove -> maps:remove(key, Flags)
        end,
    apply_remote_modes(Rest, Action, Args, Channel#remote_channel{flags = NewFlags}, Local);
apply_remote_modes([$l | Rest], Action, Args, #remote_channel{flags = Flags} = Channel, Local) ->
    case {Action, Args} of
        {add, [Value | Tail]} ->
            try binary_to_integer(Value) of
                Limit when Limit > 0 ->
                    apply_remote_modes(
                        Rest,
                        Action,
                        Tail,
                        Channel#remote_channel{flags = Flags#{limit => Limit}},
                        Local
                    );
                _ ->
                    {error, invalid_channel_limit}
            catch
                error:badarg -> {error, invalid_channel_limit}
            end;
        {remove, _} ->
            apply_remote_modes(
                Rest,
                Action,
                Args,
                Channel#remote_channel{flags = maps:remove(limit, Flags)},
                Local
            );
        _ ->
            {error, missing_channel_limit}
    end;
apply_remote_modes(
    [Mode | Rest], Action, [Mask | Args], #remote_channel{flags = Flags} = Channel, Local
) when
    Mode =:= $b; Mode =:= $e; Mode =:= $I
->
    Type =
        case Mode of
            $b -> ban;
            $e -> exception;
            $I -> invite
        end,
    Existing = maps:get(Type, Flags, []),
    Updated =
        case Action of
            add when length(Existing) >= ?MAX_LIST_ENTRIES -> Existing;
            add -> lists:usort([ircd_wire:retain(Mask) | Existing]);
            remove -> lists:delete(Mask, Existing)
        end,
    apply_remote_modes(
        Rest, Action, Args, Channel#remote_channel{flags = Flags#{Type => Updated}}, Local
    );
apply_remote_modes(
    [Mode | Rest],
    Action,
    [Nick | Args],
    #remote_channel{key = ChannelKey, members = Members} = Channel,
    Local
) when
    Mode =:= $o; Mode =:= $v; Mode =:= $O
->
    Key = ircd_wire:fold(Nick),
    Role =
        case Mode of
            $o -> operator;
            $v -> voice;
            $O -> creator
        end,
    case maps:find(Key, Members) of
        {ok, {Owner, Roles}} ->
            NewRoles =
                case Action of
                    add -> lists:usort([Role | Roles]);
                    remove -> lists:delete(Role, Roles)
                end,
            apply_remote_modes(
                Rest,
                Action,
                Args,
                Channel#remote_channel{members = Members#{Key := {Owner, NewRoles}}},
                Local
            );
        error ->
            %% The target may be a member homed on this server.
            case local_member(ChannelKey, Nick) of
                {ok, Pid} ->
                    apply_remote_modes(Rest, Action, Args, Channel, [{Pid, Role, Action} | Local]);
                error ->
                    {error, unknown_remote_mode_target}
            end
    end;
apply_remote_modes([Mode | _], _Action, [], _Channel, _Local) when
    Mode =:= $k; Mode =:= $o; Mode =:= $v; Mode =:= $O; Mode =:= $b; Mode =:= $e; Mode =:= $I
->
    {error, missing_mode_argument};
apply_remote_modes([Mode | _], _Action, _Args, _Channel, _Local) ->
    {error, {unsupported_channel_mode, Mode}}.

%% The pid of local user Nick when it is a member of the local channel Key.
local_member(Key, Nick) ->
    case {ircd_state_client:find_nick(Nick), mnesia:dirty_read(channel, Key)} of
        {#client{pid = Pid}, [#channel{members = Members}]} when is_map_key(Pid, Members) ->
            {ok, Pid};
        _ ->
            error
    end.

%% Apply `o`, `v`, and `O` changes from a peer to local members of channel
%% Key, as a local MODE would: `o` and `v` edit the member's roles and `O`
%% sets or clears the channel creator. The reop deadline is kept current.
apply_local_roles(_Key, []) ->
    ok;
apply_local_roles(Key, Changes) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{} = Channel] ->
            Updated = lists:foldl(fun apply_local_role/2, Channel, Changes),
            mnesia:dirty_write(
                ircd_state_channel:track_opless(Updated, Updated#channel.members)
            );
        [] ->
            ok
    end.

apply_local_role({Pid, creator, add}, Channel) ->
    Channel#channel{creator = Pid};
apply_local_role({Pid, creator, remove}, #channel{creator = Pid} = Channel) ->
    Channel#channel{creator = undefined};
apply_local_role({_Pid, creator, remove}, Channel) ->
    Channel;
apply_local_role({Pid, Role, Action}, #channel{members = Members} = Channel) ->
    case Members of
        #{Pid := Roles} ->
            NewRoles =
                case Action of
                    add -> lists:usort([Role | Roles]);
                    remove -> lists:delete(Role, Roles)
                end,
            Channel#channel{members = Members#{Pid := NewRoles}};
        #{} ->
            Channel
    end.

broadcast_remote_mode(Name, Prefix, Modes, Args) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, flags = Flags}] ->
            EventPrefix =
                case maps:is_key($a, Flags) of
                    true -> <<"anonymous!anonymous@anonymous.">>;
                    false -> Prefix
                end,
            ircd_state_send:broadcast(
                maps:keys(Members), EventPrefix, <<"MODE">>, [Canonical, Modes | Args], none
            );
        [] ->
            ok
    end.

update_remote_user_modes(Peer, Prefix, Nick, ModeString) ->
    Key = ircd_wire:fold(Nick),
    case remote_source(Peer, Prefix) of
        {ok, #remote_client{key = Key, modes = Modes} = Remote} ->
            Updated = apply_remote_user_modes(binary_to_list(ModeString), undefined, Modes),
            mnesia:dirty_write(ircd_wire:retain_fields(Remote#remote_client{modes = Updated})),
            ircd_state_send:broadcast(
                remote_user_local_recipients(Key), Prefix, <<"MODE">>, [Nick, ModeString], none
            ),
            relay_except(Peer, ircd_wire:line(Prefix, <<"MODE">>, [Nick, ModeString], none)),
            ok;
        {ok, _OtherRemote} ->
            {error, remote_user_mode_source_mismatch};
        error ->
            {error, unknown_remote_source}
    end.

apply_remote_user_modes([], _Action, Modes) ->
    Modes;
apply_remote_user_modes([$+ | Rest], _Action, Modes) ->
    apply_remote_user_modes(Rest, add, Modes);
apply_remote_user_modes([$- | Rest], _Action, Modes) ->
    apply_remote_user_modes(Rest, remove, Modes);
apply_remote_user_modes([Mode | Rest], Action, Modes) when
    Mode =:= $a; Mode =:= $i; Mode =:= $o; Mode =:= $w; Mode =:= $B
->
    NewModes =
        case Action of
            add -> Modes#{Mode => true};
            remove -> maps:remove(Mode, Modes);
            undefined -> Modes
        end,
    apply_remote_user_modes(Rest, Action, NewModes);
apply_remote_user_modes([_ | Rest], Action, Modes) ->
    apply_remote_user_modes(Rest, Action, Modes).

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
-doc """
Deliver a `PRIVMSG`, `NOTICE`, `TAGMSG`, or `SQUERY` from a remote user,
without message tags.

Same as `receive_remote_message/5` with an empty tag list.
""".
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
    receive_remote_message(Peer, Prefix, Command, Params, []).

-doc """
Deliver a `PRIVMSG`, `NOTICE`, or `TAGMSG` from a remote user to its target.

`Peer` is the adjacent link the line arrived on and `Prefix` its source
prefix, which must be the exact `nick!user@host` of a remote user reached
through `Peer`. `Params` is the target
and text (`TAGMSG` needs only the target). Only a `msgid` of at most 64 bytes
without space or colon, a valid `time`, and client-only tags are kept from
`Tags`.

- A local nickname receives the message, and it is stored in that user's
  direct-message history.
- A channel is delivered to local members when the sender is a member
  through `Peer`, is not banned (unless an exception matches), and may speak
  under `+m`; a `+a` channel shows the anonymous prefix. The message is saved
  in channel history and forwarded to the other peers that have members.
- A remote nickname has the message forwarded to its link, unless that link
  is `Peer`.

An unknown target is dropped with `ok`. Errors: `invalid_remote_message`,
`malformed_remote_prefix`, `remote_prefix_mismatch`, `unknown_remote_source`,
`unknown_remote_channel`, and `remote_user_not_on_channel`.
""".
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
receive_remote_message(Peer, Prefix, <<"TAGMSG">>, [Target | _], Tags) ->
    relay_remote_message(Peer, Prefix, <<"TAGMSG">>, Target, none, Tags);
receive_remote_message(Peer, Prefix, Command, [Target, Text | _], Tags) ->
    relay_remote_message(Peer, Prefix, Command, Target, Text, Tags);
receive_remote_message(_Peer, _Prefix, _Command, _Params, _Tags) ->
    {error, invalid_remote_message}.

relay_remote_message(Peer, Prefix, Command, Target, Text, Tags) ->
    ClientTags = trusted_server_tags(Tags) ++ ircd_cap:client_tags(Tags),
    case binary:split(Prefix, <<"!">>) of
        [Nick, _UserHost] ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [
                    #remote_client{
                        peer = Peer,
                        nick = Nick,
                        user = User,
                        host = Host
                    } = Remote
                ] ->
                    ExpectedPrefix = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
                    case Prefix =:= ExpectedPrefix of
                        true ->
                            receive_remote_target(
                                Peer, Remote, Prefix, Target, Text, Command, ClientTags
                            );
                        false ->
                            {error, remote_prefix_mismatch}
                    end;
                _ ->
                    {error, unknown_remote_source}
            end;
        _ ->
            {error, malformed_remote_prefix}
    end.

%% A configured peer may carry the original `msgid` and `time` of a message so
%% every server shows the same values. Malformed values are dropped.
trusted_server_tags(Tags) ->
    MsgId =
        case lists:keyfind(<<"msgid">>, 1, Tags) of
            {_, Id} when is_binary(Id), byte_size(Id) =< 64 ->
                case binary:match(Id, [<<" ">>, <<":">>]) of
                    nomatch -> [{<<"msgid">>, Id}];
                    _ -> []
                end;
            _ ->
                []
        end,
    Time =
        case lists:keyfind(<<"time">>, 1, Tags) of
            {_, Stamp} when is_binary(Stamp) ->
                case ircd_state_history:parse_timestamp(Stamp) of
                    {ok, _} -> [{<<"time">>, Stamp}];
                    error -> []
                end;
            _ ->
                []
        end,
    MsgId ++ Time.

receive_remote_target(Peer, Remote, Prefix, Target, Text, Command, Tags) ->
    case ircd_state_client:find_nick(Target) of
        #client{pid = Pid, nick = LocalNick} ->
            ircd_state_send:send(Pid, Prefix, Command, [LocalNick], Text, Tags),
            note_remote_direct(Remote, Prefix, Command, LocalNick, Text, Tags, Pid),
            ok;
        undefined ->
            case ircd_wire:channel(Target) of
                true ->
                    %% A message rejected here (unknown channel, sender not
                    %% a member through Peer) is not passed on to other peers.
                    case
                        receive_remote_channel_message(
                            Peer, Remote, Prefix, Target, Text, Command, Tags
                        )
                    of
                        ok -> forward_channel(Peer, Target, Prefix, Command, Text, Tags);
                        {error, _} = Error -> Error
                    end;
                false ->
                    forward_user(Peer, Prefix, Command, Target, Text, Tags)
            end
    end.

%% Keep the recipient's copy of a direct message from a remote account.
note_remote_direct(
    #remote_client{account = From, nick = FromNick}, Prefix, Command, Target, Text, Tags, Pid
) ->
    Time =
        case lists:keyfind(<<"time">>, 1, Tags) of
            {_, Stamp} ->
                case ircd_state_history:parse_timestamp(Stamp) of
                    {ok, T} -> T;
                    error -> erlang:system_time(millisecond)
                end;
            false ->
                erlang:system_time(millisecond)
        end,
    MsgId =
        case lists:keyfind(<<"msgid">>, 1, Tags) of
            {_, Id} -> Id;
            false -> undefined
        end,
    ircd_state_history:note_direct(
        {From, FromNick},
        {ircd_state_v3:account(Pid), Target},
        Target,
        ircd_state_history:entry(
            Command, Prefix, Text, MsgId, Time, ircd_cap:client_tags(Tags), From
        )
    ).

forward_user(Ingress, Prefix, Command, Target, Text, Tags) ->
    case mnesia:dirty_read(remote_client, ircd_wire:fold(Target)) of
        [#remote_client{peer = Dest, nick = Nick}] ->
            case ircd_route:should_forward(Ingress, Dest) of
                true ->
                    Line = ircd_wire:message(Tags, Prefix, Command, [Nick], Text),
                    _ = ircd_links:send(Dest, Line),
                    ok;
                false ->
                    ok
            end;
        [] ->
            ok
    end.

forward_channel(Ingress, Name, Prefix, Command, Text, Tags) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Line = iolist_to_binary(ircd_wire:message(Tags, Prefix, Command, [Name], Text)),
            Peers = lists:usort([MemberPeer || _Nick := {MemberPeer, _} <- Members]),
            lists:foreach(
                fun(Dest) ->
                    case ircd_route:should_forward(Ingress, Dest) of
                        true -> _ = ircd_links:send(Dest, Line);
                        false -> ok
                    end
                end,
                Peers
            );
        [] ->
            ok
    end.

receive_remote_channel_message(Peer, Remote, Prefix, Name, Text, Command, Tags) ->
    Key = ircd_wire:fold(Name),
    case {mnesia:dirty_read(remote_channel, Key), mnesia:dirty_read(channel, Key)} of
        {[#remote_channel{members = RemoteMembers, flags = RemoteFlags}], [#channel{} = Channel]} ->
            NickKey = Remote#remote_client.key,
            case RemoteMembers of
                #{NickKey := {Peer, Roles}} ->
                    Flags = maps:merge(RemoteFlags, Channel#channel.flags),
                    Banned =
                        ircd_state_channel:mask_matches(Channel, ban, Remote) andalso
                            not ircd_state_channel:mask_matches(Channel, exception, Remote),
                    Allowed =
                        not maps:is_key($m, Flags) orelse
                            lists:member(operator, Roles) orelse lists:member(voice, Roles),
                    case Allowed andalso not Banned of
                        true ->
                            Origin =
                                case maps:is_key($a, Flags) of
                                    true -> <<"anonymous!anonymous@anonymous.">>;
                                    false -> Prefix
                                end,
                            ircd_state_send:broadcast(
                                maps:keys(Channel#channel.members),
                                Origin,
                                Command,
                                [Name],
                                Text,
                                Tags
                            ),
                            ircd_state_channel:note_channel_history(
                                Channel#channel.key, Command, Origin, Text, Tags
                            );
                        false ->
                            ok
                    end;
                #{} ->
                    {error, remote_user_not_on_channel}
            end;
        {[#remote_channel{members = RemoteMembers}], []} ->
            case maps:find(Remote#remote_client.key, RemoteMembers) of
                {ok, {Peer, _Roles}} -> ok;
                _ -> {error, remote_user_not_on_channel}
            end;
        {[], _} ->
            {error, unknown_remote_channel};
        {_, []} ->
            {error, unknown_remote_channel}
    end.

-doc """
Send `NAMES` replies (numeric 353) listing the remote members of the channel
with folded name `Key` to `Client`.

Nothing is sent for an unknown channel, for an anonymous `+a` channel, or for
a `+p`/`+s` channel the client is not a local member of. The end-of-names
numeric is left to the caller.
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
                    ircd_state_channel:names_lines(
                        remote_names_entries(Name, Client, LocalMember), [], 0, Name, Client, Server
                    )
            end;
        [] ->
            ok
    end.

-doc """
Mode state stored for the remote channel `Name`, or an empty map when it is
unknown.

Keys are mode characters, `key`, `limit`, `topic`, and the `ban`,
`exception`, and `invite` mask lists.
""".
-spec remote_channel_flags(binary()) -> remote_flags().
remote_channel_flags(Name) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{flags = Flags}] -> Flags;
        [] -> #{}
    end.

-doc """
`NAMES` entries for the remote members of channel `Name`, sorted.

Each entry is the member's role prefix and nickname, or `nick!user@host` for
a client with `userhost-in-names`. Invisible (`+i`) members are left out
unless `LocalMember` is true, meaning the requester is a member of the local
channel.
""".
-spec remote_names_entries(binary(), #client{}, boolean()) -> [binary()].
remote_names_entries(Name, Client, LocalMember) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
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

A user without `+i` is always visible; an invisible user is visible only when
`Client` is a local member of a channel the user is also in.
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
            ircd_state:table_keys(remote_channel)
        ).

-doc """
Pids of local clients that share a channel with the remote user `NickKey`.

Channels with mode `a` or `q` on either side are skipped. Used, for example,
to show a remote user's `QUIT` and user mode changes.
""".
-spec remote_user_local_recipients(binary()) -> [pid()].
remote_user_local_recipients(NickKey) ->
    lists:usort([
        Pid
     || ChannelKey <- ircd_state:table_keys(remote_channel),
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

remote_display_nick(#remote_client{nick = Nick, user = User, host = Host}, Roles, #client{pid = Pid}) ->
    Name =
        case ircd_cap:enabled(Pid, <<"userhost-in-names">>) of
            true -> <<Nick/binary, "!", User/binary, "@", Host/binary>>;
            false -> Nick
        end,
    <<(ircd_state_channel:role_prefix(Roles, Pid))/binary, Name/binary>>.

-doc """
Introduce a newly registered local user to every peer with a 7-parameter
`NICK` line prefixed by `Server`, the local server name.
""".
-spec propagate_introduction(#client{}, iodata()) -> ok.
propagate_introduction(
    #client{nick = Nick, user = User, host = Host, real = Real, pid = Pid}, Server
) when is_binary(User), is_binary(Real) ->
    Modes = ircd_state_channel:user_mode_string(ircd_state_client:user_modes(Pid)),
    server_broadcast(
        ircd_wire:line(
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
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"NICK">>, [Nick], none)).

-doc """
Announce a local user's `AWAY` to every peer; `none` clears the away
message.
""".
-spec propagate_away(#client{}, none | iodata()) -> ok.
propagate_away(Client, none) ->
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"AWAY">>, [], none));
propagate_away(Client, Message) ->
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"AWAY">>, [], Message)).

-doc """
Announce a local user's `QUIT` with `Reason` to every peer.
""".
-spec propagate_quit(#client{}, none | iodata()) -> ok.
propagate_quit(Client, Reason) ->
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"QUIT">>, [], Reason)).

-doc """
Send a server line to every authenticated peer.
""".
-spec server_broadcast(iodata()) -> ok.
server_broadcast(Line) ->
    relay_except(undefined, Line).

-doc """
Send a server line to every authenticated peer except the ingress link.

`Ingress` is the peer the line arrived from, or `undefined` for every peer.
An exit from `m:ircd_links` (for example, while it is restarting) is caught
and the line is dropped.
""".
-spec relay_except(undefined | binary(), iodata()) -> ok.
relay_except(Ingress, Line) ->
    try ircd_links:send_except(Ingress, iolist_to_binary(Line)) of
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
    relay_except(Peer, ircd_wire:line(Server, <<"KILL">>, [Nick], Reason)),
    case ircd_state_client:find_nick(Nick) of
        #client{pid = Pid, nick = Actual} = Client ->
            ircd_state_send:send(Pid, Server, <<"KILL">>, [Actual], Reason),
            ircd_state_client:disconnect(Client, Reason, Server);
        undefined ->
            ok
    end,
    case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
        [#remote_client{nick = RemoteNick, user = User, host = Host} = Remote] ->
            Prefix = <<RemoteNick/binary, "!", User/binary, "@", Host/binary>>,
            relay_except(Peer, ircd_wire:line(Prefix, <<"QUIT">>, [], Reason)),
            ircd_state_net:remove_remote_user(Remote);
        [] ->
            ok
    end,
    ircd_state_net:hold_nick(Nick).

-doc """
Send a local user's `INVITE` of `Nick` to channel `Name`.

The line goes to `Peer`, the link that reaches the invited user, and to every
other peer that has members of the channel.
""".
-spec propagate_invite(#client{}, iodata(), binary(), binary()) -> ok.
propagate_invite(Client, Nick, Name, Peer) ->
    Line = iolist_to_binary(
        ircd_wire:line(ircd_state_send:prefix(Client), <<"INVITE">>, [Nick, Name], none)
    ),
    _ = ircd_links:send(Peer, Line),
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Peers = lists:usort([MemberPeer || _Nick := {MemberPeer, _} <- Members]),
            lists:foreach(
                fun(Other) ->
                    case ircd_route:should_forward(Peer, Other) of
                        true -> _ = ircd_links:send(Other, Line);
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

`Peer` is the adjacent link the line arrived on and `Prefix` its source
prefix, which must be the exact `nick!user@host` of a remote user reached
through `Peer`. A local target is added
to the invite list of the local channel, if it exists, and receives the
`INVITE`. A remote target is recorded on the remote channel and the `INVITE`
is forwarded to its link unless that link is `Peer`. An unknown target is
ignored. Returns `{error, unknown_remote_nick}` for an untrusted prefix.
""".
-spec receive_remote_invite(binary(), binary(), binary(), binary()) ->
    ok | {error, unknown_remote_nick}.
receive_remote_invite(Peer, Prefix, Nick, Name) ->
    case remote_source(Peer, Prefix) of
        {ok, #remote_client{}} ->
            case ircd_state_client:find_nick(Nick) of
                #client{pid = Pid} = Target ->
                    remember_local_invite(Pid, Name),
                    Key = ircd_wire:fold(Name),
                    Origin =
                        case
                            local_channel_mode(Key, $a) orelse
                                maps:is_key($a, remote_channel_flags(Name))
                        of
                            true -> <<"anonymous!anonymous@anonymous.">>;
                            false -> Prefix
                        end,
                    ircd_state_send:send(
                        Pid, Origin, <<"INVITE">>, [Target#client.nick, Name], none
                    ),
                    ok;
                undefined ->
                    case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                        [#remote_client{peer = Dest, nick = RemoteNick}] ->
                            case ircd_route:should_forward(Peer, Dest) of
                                true ->
                                    Line = ircd_wire:line(
                                        Prefix, <<"INVITE">>, [RemoteNick, Name], none
                                    ),
                                    _ = ircd_links:send(Dest, Line),
                                    ok;
                                false ->
                                    ok
                            end;
                        [] ->
                            ok
                    end
            end;
        error ->
            {error, unknown_remote_nick}
    end.

remember_local_invite(Pid, Name) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{invited = Invited} = Channel] ->
            Alive = [P || P <- Invited, is_process_alive(P)],
            mnesia:dirty_write(Channel#channel{invited = lists:usort([Pid | Alive])}),
            ircd_state_channel:note_invited(Pid, Channel#channel.key);
        [] ->
            ok
    end.

-doc """
Delete `remote_channel` rows that have no members, and empty the unused
`invited` maps that earlier releases recorded. A row describes a channel as
peers report it and is removed when its last remote member leaves; rows
created by a peer's TOPIC or MODE, or by an INVITE, for a channel with no
remote members were never removed, and each kept its local channel from
being pruned as empty. Called every minute by `m:ircd_state`.
""".
-spec sweep_remote_channels() -> non_neg_integer().
sweep_remote_channels() ->
    lists:foldl(
        fun(Key, Removed) ->
            case mnesia:dirty_read(remote_channel, Key) of
                [#remote_channel{members = Members}] when map_size(Members) =:= 0 ->
                    mnesia:dirty_delete(remote_channel, Key),
                    Removed + 1;
                [#remote_channel{invited = Invited} = Row] when map_size(Invited) > 0 ->
                    mnesia:dirty_write(Row#remote_channel{invited = #{}}),
                    Removed;
                _ ->
                    Removed
            end
        end,
        0,
        mnesia:dirty_all_keys(remote_channel)
    ).

-doc """
Announce a local user's `TOPIC` change on channel `Name` to every peer.
""".
-spec propagate_topic(#client{}, iodata(), none | iodata()) -> ok.
propagate_topic(Client, Name, Topic) ->
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"TOPIC">>, [Name], Topic)).

-doc """
Announce a local user's channel `MODE` change to every peer.
""".
-spec propagate_channel_mode(#client{}, iodata(), iodata(), [iodata()]) -> ok.
propagate_channel_mode(Client, Name, Mode, Args) ->
    server_broadcast(
        ircd_wire:line(ircd_state_send:prefix(Client), <<"MODE">>, [Name, Mode | Args], none)
    ).

-doc """
Announce a local user's `KICK` of `Nick` from channel `Name` to every peer.
""".
-spec propagate_channel_kick(#client{}, iodata(), iodata(), none | iodata()) -> ok.
propagate_channel_kick(Client, Name, Nick, Reason) ->
    server_broadcast(
        ircd_wire:line(ircd_state_send:prefix(Client), <<"KICK">>, [Name, Nick], Reason)
    ).

-doc """
Announce a local user joining channel `Name` to every peer.

Sends the user's `JOIN`, an `NJOIN` from this server carrying the member's
`Roles` (creator, operator, or voice prefix), and the channel's current
modes, key, limit, and mask lists.
""".
-spec propagate_join(#client{}, binary(), [channel_role()]) -> ok.
propagate_join(Client, Name, Roles) ->
    Server = maps:get(name, ircd_config:current()),
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"JOIN">>, [Name], none)),
    Member = iolist_to_binary(njoin_member(Client, Roles)),
    server_broadcast(ircd_wire:line(Server, <<"NJOIN">>, [Name], Member)),
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{flags = Flags, password = Password, limit = Limit, lists = Lists}] ->
            lists:foreach(
                fun server_broadcast/1,
                channel_mode_burst(Name, Flags, Password, Limit, Lists, Server)
            );
        [] ->
            ok
    end.

-doc """
Send prepared lines to every peer that has members of channel `Name`.
""".
-spec propagate_channel_lines(binary(), [iodata()]) -> ok.
propagate_channel_lines(Name, Lines) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Peers = lists:usort([Peer || _Nick := {Peer, _Roles} <- Members]),
            Bins = [iolist_to_binary(Line) || Line <- Lines],
            lists:foreach(
                fun(Peer) ->
                    lists:foreach(fun(Bin) -> _ = ircd_links:send(Peer, Bin) end, Bins)
                end,
                Peers
            );
        [] ->
            ok
    end.

-doc """
Open or close a `draft/multiline` batch sent by a remote user.

`BATCH +<ref> draft/multiline <target>` opens a batch; the prefix must be a
remote user reached through `Peer`, otherwise the result is
`{error, unknown_remote_source}`. `BATCH -<ref>` closes it and delivers the
collected message to a local nickname or channel members, or forwards it
toward a remote target, never back to `Peer`. Closing an unknown or empty
batch does nothing. Other batch types are `{error, invalid_batch}`. Open
batches are kept per peer and reference in the state process, each bounded by
the multiline line limit. At most 10 batches may be open per peer; opening
another is `{error, too_many_batches}`. `forget_peer_batches/1` discards a
peer's open batches when its link is lost.
""".
-spec receive_remote_batch(binary(), binary(), [binary()], list()) -> ok | {error, term()}.
receive_remote_batch(Peer, Prefix, [<<"+", Ref/binary>>, <<"draft/multiline">>, Target | _], Tags) ->
    Open = peer_batch_keys(Peer),
    Full =
        length(Open) >= ?MAX_PEER_BATCHES andalso
            not lists:member({ircd_peer_batch, Peer, Ref}, Open),
    case remote_source(Peer, Prefix) of
        {ok, _} when Full ->
            {error, too_many_batches};
        {ok, _} ->
            put({ircd_peer_batch, Peer, ircd_wire:retain(Ref)}, #{
                prefix => Prefix,
                target => ircd_wire:retain(Target),
                tags => trusted_server_tags(Tags) ++ ircd_cap:client_tags(Tags),
                command => undefined,
                lines => [],
                bytes => 0,
                count => 0,
                opened_at => erlang:monotonic_time(second)
            }),
            ok;
        error ->
            {error, unknown_remote_source}
    end;
receive_remote_batch(Peer, Prefix, [<<"-", Ref/binary>> | _], _Tags) ->
    case erase({ircd_peer_batch, Peer, Ref}) of
        #{prefix := Prefix, command := Command, lines := [_ | _] = Lines} = Batch when
            Command =/= undefined
        ->
            deliver_remote_multiline(Peer, Batch#{lines := lists:reverse(Lines)});
        #{prefix := Prefix} ->
            ok;
        #{} ->
            {error, invalid_batch};
        undefined ->
            ok
    end;
receive_remote_batch(_Peer, _Prefix, _Params, _Tags) ->
    {error, invalid_batch}.

-doc """
Discard every `draft/multiline` batch that `Peer` opened and did not close.

Called when the link to `Peer` is lost, so the state process does not keep
partial batches for a link that is gone.
""".
-spec forget_peer_batches(binary()) -> ok.
forget_peer_batches(Peer) ->
    lists:foreach(fun erase/1, peer_batch_keys(Peer)).

-doc """
Discard any peer `draft/multiline` batch left open for more than 60 seconds.
Called from `m:ircd_state`'s one-second tick.
""".
-spec expire_peer_batches() -> ok.
expire_peer_batches() ->
    Cutoff = erlang:monotonic_time(second) - 60,
    lists:foreach(
        fun
            ({ircd_peer_batch, _, _} = Key) ->
                case get(Key) of
                    #{opened_at := Opened} when Opened =< Cutoff -> erase(Key);
                    _ -> ok
                end;
            (_) ->
                ok
        end,
        get_keys()
    ).

peer_batch_keys(Peer) ->
    [Key || {ircd_peer_batch, P, _} = Key <- get_keys(), P =:= Peer].

-doc """
Add one `PRIVMSG` or `NOTICE` line to an open peer `draft/multiline` batch.

The line's `batch` tag names the batch, and `Prefix` must match the prefix
that opened it. Returns `{error, unknown_batch}` when no such batch is open,
and `{error, invalid_multiline}` (discarding the batch) when the prefix,
command, or target differs, or the line or byte limit is exceeded.
""".
-spec remote_batch_line(binary(), binary(), binary(), [binary()], list()) -> ok | {error, term()}.
remote_batch_line(Peer, Prefix, Command, [Target, Text | _], Tags) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>
->
    {_, Ref} = lists:keyfind(<<"batch">>, 1, Tags),
    {MaxBytes, MaxLines} = ircd_cap:multiline_limits(),
    case get({ircd_peer_batch, Peer, Ref}) of
        #{
            prefix := Prefix,
            target := BatchTarget,
            command := Previous,
            bytes := Bytes,
            count := Count,
            lines := Lines
        } = Batch when Count < MaxLines ->
            Concat = lists:keymember(<<"draft/multiline-concat">>, 1, Tags),
            Separator =
                case {Lines, Concat} of
                    {[], _} -> 0;
                    {_, true} -> 0;
                    {_, false} -> 1
                end,
            NewBytes = Bytes + Separator + byte_size(Text),
            SameTarget = ircd_wire:fold(Target) =:= ircd_wire:fold(BatchTarget),
            SameCommand = Previous =:= undefined orelse Previous =:= Command,
            case
                SameTarget andalso SameCommand andalso (not Concat orelse Text =/= <<>>) andalso
                    NewBytes =< MaxBytes
            of
                true ->
                    put({ircd_peer_batch, Peer, Ref}, Batch#{
                        command => Command,
                        lines => [{Concat, ircd_wire:retain(Text)} | Lines],
                        bytes => NewBytes,
                        count => Count + 1
                    }),
                    ok;
                false ->
                    erase({ircd_peer_batch, Peer, Ref}),
                    {error, invalid_multiline}
            end;
        #{} ->
            erase({ircd_peer_batch, Peer, Ref}),
            {error, invalid_multiline};
        undefined ->
            {error, unknown_batch}
    end;
remote_batch_line(_Peer, _Prefix, _Command, _Params, _Tags) ->
    {error, invalid_multiline}.

deliver_remote_multiline(
    Peer, #{prefix := Prefix, target := Target, tags := Tags, command := Command, lines := Lines}
) ->
    Body = {multiline, Lines},
    case ircd_state_client:find_nick(Target) of
        #client{pid = Pid, nick = Nick} ->
            ircd_state_batch:deliver_multiline(Pid, Prefix, Command, Nick, Lines, Tags, normal),
            [RemoteNick | _] = binary:split(Prefix, <<"!">>),
            case mnesia:dirty_read(remote_client, ircd_wire:fold(RemoteNick)) of
                [#remote_client{} = Remote] ->
                    note_remote_direct(Remote, Prefix, Command, Nick, Body, Tags, Pid);
                [] ->
                    ok
            end;
        undefined ->
            case ircd_wire:channel(Target) of
                true ->
                    Key = ircd_wire:fold(Target),
                    [Nick | _] = binary:split(Prefix, <<"!">>),
                    NickKey = ircd_wire:fold(Nick),
                    case
                        {
                            mnesia:dirty_read(remote_channel, Key),
                            mnesia:dirty_read(channel, Key),
                            mnesia:dirty_read(remote_client, NickKey)
                        }
                    of
                        {
                            [#remote_channel{members = RM, flags = RF}],
                            [#channel{name = Name, members = LM, flags = LF} = Channel],
                            [#remote_client{} = Remote]
                        } ->
                            case RM of
                                #{NickKey := {Peer, Roles}} ->
                                    Flags = maps:merge(RF, LF),
                                    Banned =
                                        ircd_state_channel:mask_matches(Channel, ban, Remote) andalso
                                            not ircd_state_channel:mask_matches(
                                                Channel, exception, Remote
                                            ),
                                    Allowed =
                                        not maps:is_key($m, Flags) orelse
                                            lists:member(operator, Roles) orelse
                                            lists:member(voice, Roles),
                                    case Allowed andalso not Banned of
                                        true ->
                                            Origin =
                                                case maps:is_key($a, Flags) of
                                                    true -> <<"anonymous!anonymous@anonymous.">>;
                                                    false -> Prefix
                                                end,
                                            lists:foreach(
                                                fun(P) ->
                                                    ircd_state_batch:deliver_multiline(
                                                        P,
                                                        Origin,
                                                        Command,
                                                        Name,
                                                        Lines,
                                                        Tags,
                                                        normal
                                                    )
                                                end,
                                                maps:keys(LM)
                                            ),
                                            MsgId =
                                                case lists:keyfind(<<"msgid">>, 1, Tags) of
                                                    {_, Id} -> Id;
                                                    false -> undefined
                                                end,
                                            Account =
                                                case maps:is_key($a, Flags) of
                                                    true -> undefined;
                                                    false -> Remote#remote_client.account
                                                end,
                                            ircd_state_history:note_channel(
                                                Key,
                                                ircd_state_history:entry(
                                                    Command,
                                                    Origin,
                                                    Body,
                                                    MsgId,
                                                    erlang:system_time(millisecond),
                                                    ircd_cap:client_tags(Tags),
                                                    Account
                                                )
                                            );
                                        false ->
                                            ok
                                    end;
                                #{} ->
                                    ok
                            end;
                        _ ->
                            ok
                    end,
                    forward_lines_channel(
                        Peer,
                        Target,
                        ircd_state_batch:link_lines(Prefix, Command, Target, Body, Tags)
                    );
                false ->
                    case mnesia:dirty_read(remote_client, ircd_wire:fold(Target)) of
                        [#remote_client{peer = Dest}] ->
                            case ircd_route:should_forward(Peer, Dest) of
                                true ->
                                    lists:foreach(
                                        fun(Line) ->
                                            _ = ircd_links:send(Dest, iolist_to_binary(Line))
                                        end,
                                        ircd_state_batch:link_lines(
                                            Prefix, Command, Target, Body, Tags
                                        )
                                    );
                                false ->
                                    ok
                            end;
                        [] ->
                            ok
                    end
            end
    end,
    ok.

forward_lines_channel(Ingress, Name, Lines) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Bins = [iolist_to_binary(Line) || Line <- Lines],
            Peers = lists:usort([MemberPeer || _Nick := {MemberPeer, _} <- Members]),
            lists:foreach(
                fun(Dest) ->
                    case ircd_route:should_forward(Ingress, Dest) of
                        true -> lists:foreach(fun(Bin) -> _ = ircd_links:send(Dest, Bin) end, Bins);
                        false -> ok
                    end
                end,
                Peers
            );
        [] ->
            ok
    end.

-doc """
Send a local user's channel `PRIVMSG`, `NOTICE`, or `TAGMSG` to every peer
that has members of channel `Name`.

`Tags` are the message tags to put on the server line.
""".
-spec propagate_channel_message(binary(), none | iodata(), binary(), #client{}, [
    {binary(), undefined | binary()}
]) -> ok.
propagate_channel_message(Name, Text, Command, Client, Tags) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Line = iolist_to_binary(
                ircd_wire:message(Tags, ircd_state_send:prefix(Client), Command, [Name], Text)
            ),
            Peers = lists:usort([Peer || _Nick := {Peer, _Roles} <- Members]),
            lists:foreach(fun(Peer) -> _ = ircd_links:send(Peer, Line) end, Peers),
            ok;
        [] ->
            ok
    end.
