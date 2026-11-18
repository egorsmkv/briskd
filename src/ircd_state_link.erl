-module(ircd_state_link).
-export([
    import_remote_join/3,
    import_remote_nick/3,
    receive_remote_invite/4,
    import_remote_njoin/3,
    flush_netjoin/1,
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
    remote_user_local_recipients/1,
    remote_user_visible_to_requester/3,
    receive_remote_kill/3,
    relay_except/2,
    remove_remote_channel_member/4,
    remove_remote_nick/3,
    rename_remote_nick/3,
    server_broadcast/1,
    server_burst_lines/1,
    set_remote_away/3,
    update_remote_modes/5,
    update_remote_topic/4
]).
-include("ircd_state.hrl").

%% @doc Direct server-link burst, import, and propagation.

server_burst_lines(Server) ->
    ServerLines = ircd_state_net:burst_server_lines(Server),
    ClientLines =
        lists:flatmap(
            fun(Pid) ->
                case mnesia:dirty_read(client, Pid) of
                    [Client] ->
                        case ircd_state_client:ready(Client) of
                            true -> client_burst_lines(Client, Server);
                            false -> []
                        end;
                    _ ->
                        []
                end
            end,
            mnesia:dirty_all_keys(client)
        ),
    ChannelLines =
        lists:flatmap(
            fun(Key) ->
                case mnesia:dirty_read(channel, Key) of
                    [Channel] -> channel_burst_lines(Channel, Server);
                    [] -> []
                end
            end,
            mnesia:dirty_all_keys(channel)
        ),
    ServerLines ++ ClientLines ++ remote_client_burst_lines() ++
        ircd_state_v3:burst_lines(Server) ++ ChannelLines ++ ircd_state_sync:burst_lines(Server) ++
        remote_channel_burst_lines(Server).

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
        mnesia:dirty_all_keys(remote_client)
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
                [Channel] -> remote_channel_lines(Channel, Server);
                [] -> []
            end
        end,
        mnesia:dirty_all_keys(remote_channel)
    ).

remote_channel_lines(#remote_channel{name = Name, members = Members, flags = Flags}, Server) ->
    Tokens = [
        remote_njoin_token(Remote#remote_client.nick, Roles)
     || {NickKey, {_Peer, Roles}} <- maps:to_list(Members),
        [Remote] <- [mnesia:dirty_read(remote_client, NickKey)]
    ],
    ModeFlags = maps:from_list([
        {Key, true}
     || Key <- maps:keys(Flags), is_integer(Key)
    ]),
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
        {true, _, _} -> <<"@@", Nick/binary>>;
        {false, true, _} -> <<$@, Nick/binary>>;
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
            [Client] <- [mnesia:dirty_read(client, Pid)],
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
    case
        {lists:member(creator, Roles), lists:member(operator, Roles), lists:member(voice, Roles)}
    of
        {true, _, _} -> <<"@@", Nick/binary>>;
        {false, true, _} -> <<$@, Nick/binary>>;
        {false, false, true} -> <<$+, Nick/binary>>;
        _ -> Nick
    end.

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
remote_nick_exists(Nick) ->
    mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) =/= [].

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
            valid_decimal(Token),
            re:run(User, <<"^[A-Za-z0-9_.-]{1,32}$">>, [{capture, none}, dollar_endonly]),
            valid_server_host(Host),
            server_user_modes(ModeString),
            ircd_state_client:find_nick(Nick),
            mnesia:dirty_read(remote_client, Key)
        }
    of
        {true, true, true, match, true, {ok, Modes}, undefined, []} ->
            write_remote_nick(
                Peer, Home, Distance, Key, Nick, User, Host, Token, Modes, Real
            ),
            ircd_state_monitor:online(Nick, <<Nick/binary, "!", User/binary, "@", Host/binary>>),
            ircd_state_meta:forget_remote(Key),
            relay_except(
                Peer, remote_nick_line(Home, Nick, Distance, User, Host, Token, Modes, Real)
            ),
            ok;
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
    case valid_decimal(Hop) of
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
                    [Row] -> Row;
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
    mnesia:dirty_write(#remote_client{
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
    }).

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
    maps:get(name, persistent_term:get({ircd_state, config})).

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
                    mnesia:dirty_delete(remote_client, OldKey),
                    mnesia:dirty_write(Remote#remote_client{key = NewKey, nick = Nick}),
                    rename_remote_memberships(Peer, OldKey, NewKey),
                    ircd_state_meta:rename_remote(OldKey, NewKey),
                    ircd_state_monitor:offline(Remote#remote_client.nick),
                    ircd_state_monitor:online(
                        Nick,
                        <<Nick/binary, "!", (Remote#remote_client.user)/binary, "@",
                            (Remote#remote_client.host)/binary>>
                    ),
                    relay_except(Peer, ircd_wire:line(Prefix, <<"NICK">>, [Nick], none)),
                    ok;
                {true, true, undefined, [#remote_client{key = OldKey, peer = Peer}]} ->
                    mnesia:dirty_write(Remote#remote_client{nick = Nick}),
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

remove_remote_nick(Peer, Prefix, Reason) ->
    case remote_source(Peer, Prefix) of
        {ok, #remote_client{key = Key, nick = Nick}} ->
            relay_except(Peer, ircd_wire:line(Prefix, <<"QUIT">>, [], Reason)),
            mnesia:dirty_delete(remote_client, Key),
            ircd_state_monitor:offline(Nick),
            ircd_state_meta:forget_remote(Key),
            remove_remote_memberships(Peer, Key),
            ok;
        error ->
            {error, unknown_remote_nick}
    end.

set_remote_away(Peer, Prefix, Params) ->
    case remote_source(Peer, Prefix) of
        {ok, Remote} ->
            Modes =
                case Params of
                    [] -> maps:remove($a, Remote#remote_client.modes);
                    [_Message | _] -> (Remote#remote_client.modes)#{$a => true}
                end,
            mnesia:dirty_write(Remote#remote_client{modes = Modes}),
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
                    case maps:find(NickKey, Members) of
                        {ok, {Peer, Roles}} ->
                            Restricted = maps:is_key($t, Flags) orelse local_channel_mode(Key, $t),
                            case Restricted andalso not lists:member(operator, Roles) of
                                true -> {error, remote_topic_requires_operator};
                                false -> store_remote_topic(Peer, Prefix, Key, Name, Topic)
                            end;
                        _ ->
                            {error, remote_user_not_on_channel}
                    end;
                {{error, _}, _} ->
                    {error, unknown_remote_source};
                {_, []} ->
                    {error, unknown_remote_channel}
            end
    end.

store_remote_topic(Peer, Prefix, Key, Name, Topic) ->
    Remote =
        case mnesia:dirty_read(remote_channel, Key) of
            [RemoteRecord] -> RemoteRecord;
            [] -> #remote_channel{key = Key, name = Name}
        end,
    Flags = (Remote#remote_channel.flags)#{topic => Topic},
    mnesia:dirty_write(Remote#remote_channel{flags = Flags}),
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Canonical, members = Members, flags = ChannelFlags} = Channel] ->
            mnesia:dirty_write(Channel#channel{topic = Topic}),
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

%% True when Prefix is the adjacent peer or a known server reached through it.
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
        mnesia:dirty_all_keys(remote_channel)
    ).

remove_remote_memberships(Peer, NickKey) ->
    lists:foreach(
        fun(ChannelKey) ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{members = Members} = Channel] ->
                    case maps:find(NickKey, Members) of
                        {ok, {Peer, _Roles}} ->
                            Remaining = maps:remove(NickKey, Members),
                            case map_size(Remaining) of
                                0 -> mnesia:dirty_delete(remote_channel, ChannelKey);
                                _ -> mnesia:dirty_write(Channel#remote_channel{members = Remaining})
                            end;
                        _ ->
                            ok
                    end;
                _ ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(remote_channel)
    ).

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
                            [Channel] -> Channel;
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
                Error ->
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

%% @doc Send the collected burst JOINs from Peer in one netjoin batch.
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

import_remote_join(Peer, Prefix, Name) ->
    case {remote_source(Peer, Prefix), ircd_wire:channel(Name)} of
        {{ok, #remote_client{key = NickKey}}, true} ->
            Key = ircd_wire:fold(Name),
            Channel =
                case mnesia:dirty_read(remote_channel, Key) of
                    [Existing] -> Existing;
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

remove_remote_channel_member(Peer, Prefix, Name, Reason) ->
    case {remote_source(Peer, Prefix), mnesia:dirty_read(remote_channel, ircd_wire:fold(Name))} of
        {{ok, #remote_client{key = NickKey}}, [#remote_channel{members = Members} = Channel]} ->
            case maps:find(NickKey, Members) of
                {ok, {Peer, _Roles}} ->
                    broadcast_remote_channel_event(Name, Prefix, <<"PART">>, Reason),
                    Remaining = maps:remove(NickKey, Members),
                    case map_size(Remaining) of
                        0 -> mnesia:dirty_delete(remote_channel, Channel#remote_channel.key);
                        _ -> mnesia:dirty_write(Channel#remote_channel{members = Remaining})
                    end,
                    relay_except(Peer, ircd_wire:line(Prefix, <<"PART">>, [Name], Reason)),
                    ok;
                _ ->
                    {error, remote_user_not_on_channel}
            end;
        {{error, _}, _} ->
            {error, unknown_remote_source};
        {_, []} ->
            {error, unknown_remote_channel}
    end.

receive_remote_kick(Peer, Prefix, Name, Nick, Reason) ->
    Key = ircd_wire:fold(Name),
    case {remote_source(Peer, Prefix), mnesia:dirty_read(remote_channel, Key)} of
        {{ok, #remote_client{key = SourceKey}}, [#remote_channel{members = Members} = Channel]} ->
            case maps:find(SourceKey, Members) of
                {ok, {Peer, Roles}} ->
                    case lists:member(operator, Roles) orelse lists:member(creator, Roles) of
                        true -> apply_remote_kick(Peer, Prefix, Name, Nick, Reason, Channel);
                        false -> {error, remote_kick_requires_operator}
                    end;
                _ ->
                    {error, remote_kick_requires_operator}
            end;
        {{error, _}, _} ->
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
        _ -> mnesia:dirty_write(Channel#remote_channel{members = Members})
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
        [Channel] -> broadcast_kick(Channel, Prefix, Nick, Reason);
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

remote_member(<<"@@", Nick/binary>>) -> {[creator, operator], Nick};
remote_member(<<$@, Nick/binary>>) -> {[operator], Nick};
remote_member(<<$+, Nick/binary>>) -> {[voice], Nick};
remote_member(Nick) -> {[member], Nick}.

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
            [ExistingRecord] -> ExistingRecord;
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
                                case maps:find(NickKey, Members) of
                                    {ok, {Peer, Roles}} ->
                                        lists:member(operator, Roles) orelse
                                            lists:member(creator, Roles);
                                    _ ->
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
                        apply_remote_modes(
                            binary_to_list(ModeString), undefined, Args, ChannelRecord
                        )
                    of
                        {ok, Updated, []} ->
                            mnesia:dirty_write(Updated),
                            synchronize_local_channel(Updated),
                            relay_except(
                                Peer,
                                ircd_wire:line(Prefix, <<"MODE">>, [Name, ModeString | Args], none)
                            ),
                            case TrustedServer of
                                true -> ok;
                                false -> broadcast_remote_mode(Name, Prefix, ModeString, Args)
                            end;
                        {ok, _Updated, Remaining} ->
                            {error, {extra_mode_arguments, Remaining}};
                        Error ->
                            Error
                    end
            end
    end.

synchronize_local_channel(#remote_channel{key = Key, flags = RemoteFlags}) ->
    case mnesia:dirty_read(channel, Key) of
        [Channel] ->
            ModeKeys = [$a, $i, $m, $n, $p, $q, $r, $s, $t, $K],
            Flags = maps:with(ModeKeys, RemoteFlags),
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

apply_remote_modes([], _Action, Args, Channel) ->
    {ok, Channel, Args};
apply_remote_modes([$+ | Rest], _Action, Args, Channel) ->
    apply_remote_modes(Rest, add, Args, Channel);
apply_remote_modes([$- | Rest], _Action, Args, Channel) ->
    apply_remote_modes(Rest, remove, Args, Channel);
apply_remote_modes([Mode | Rest], Action, Args, #remote_channel{flags = Flags} = Channel) when
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
    apply_remote_modes(Rest, Action, Args, Channel#remote_channel{flags = NewFlags});
apply_remote_modes([$k | Rest], Action, [Key | Args], #remote_channel{flags = Flags} = Channel) ->
    NewFlags =
        case Action of
            add -> Flags#{key => Key};
            remove -> maps:remove(key, Flags)
        end,
    apply_remote_modes(Rest, Action, Args, Channel#remote_channel{flags = NewFlags});
apply_remote_modes([$l | Rest], Action, Args, #remote_channel{flags = Flags} = Channel) ->
    case {Action, Args} of
        {add, [Value | Tail]} ->
            try binary_to_integer(Value) of
                Limit when Limit > 0 ->
                    apply_remote_modes(Rest, Action, Tail, Channel#remote_channel{
                        flags = Flags#{limit => Limit}
                    });
                _ ->
                    {error, invalid_channel_limit}
            catch
                error:badarg -> {error, invalid_channel_limit}
            end;
        {remove, _} ->
            apply_remote_modes(Rest, Action, Args, Channel#remote_channel{
                flags = maps:remove(limit, Flags)
            });
        _ ->
            {error, missing_channel_limit}
    end;
apply_remote_modes(
    [Mode | Rest], Action, [Mask | Args], #remote_channel{flags = Flags} = Channel
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
            add -> lists:usort([Mask | Existing]);
            remove -> lists:delete(Mask, Existing)
        end,
    apply_remote_modes(Rest, Action, Args, Channel#remote_channel{flags = Flags#{Type => Updated}});
apply_remote_modes(
    [Mode | Rest], Action, [Nick | Args], #remote_channel{members = Members} = Channel
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
            apply_remote_modes(Rest, Action, Args, Channel#remote_channel{
                members = Members#{Key := {Owner, NewRoles}}
            });
        error ->
            {error, unknown_remote_mode_target}
    end;
apply_remote_modes([Mode | _], _Action, [], _Channel) when
    Mode =:= $k; Mode =:= $o; Mode =:= $v; Mode =:= $O; Mode =:= $b; Mode =:= $e; Mode =:= $I
->
    {error, missing_mode_argument};
apply_remote_modes([Mode | _], _Action, _Args, _Channel) ->
    {error, {unsupported_channel_mode, Mode}}.

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
            mnesia:dirty_write(Remote#remote_client{modes = Updated}),
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

valid_decimal(Value) ->
    try binary_to_integer(Value) of
        Number -> Number >= 0
    catch
        error:badarg -> false
    end.

valid_server_host(Host) ->
    byte_size(Host) > 0 andalso byte_size(Host) =< 253 andalso
        binary:match(Host, [<<0>>, <<" ">>, <<"\r">>, <<"\n">>]) =:= nomatch.

server_user_modes(<<$+, Modes/binary>>) ->
    case lists:all(fun(Mode) -> lists:member(Mode, "aiowB") end, binary_to_list(Modes)) of
        true -> {ok, maps:from_list([{Mode, true} || Mode <- binary_to_list(Modes)])};
        false -> error
    end;
server_user_modes(_) ->
    error.
receive_remote_message(Peer, Prefix, Command, Params) ->
    receive_remote_message(Peer, Prefix, Command, Params, []).

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
                    Result = receive_remote_channel_message(
                        Peer, Remote, Prefix, Target, Text, Command, Tags
                    ),
                    forward_channel(Peer, Target, Prefix, Command, Text, Tags),
                    Result;
                false ->
                    forward_user(Peer, Prefix, Command, Target, Text, Tags)
            end
    end.

%% Keep the recipient's copy of a direct message from a remote account.
note_remote_direct(#remote_client{account = From}, Prefix, Command, Target, Text, Tags, Pid) ->
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
        From,
        ircd_state_v3:account(Pid),
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
            Peers = lists:usort([MemberPeer || {_Nick, {MemberPeer, _}} <- maps:to_list(Members)]),
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
        {[#remote_channel{members = RemoteMembers, flags = RemoteFlags}], [Channel]} ->
            NickKey = Remote#remote_client.key,
            case maps:find(NickKey, RemoteMembers) of
                {ok, {Peer, Roles}} ->
                    Flags = maps:merge(RemoteFlags, Channel#channel.flags),
                    RemoteIdentity = #client{
                        nick = Remote#remote_client.nick,
                        user = Remote#remote_client.user,
                        host = Remote#remote_client.host
                    },
                    Banned =
                        ircd_state_channel:mask_matches(Channel, ban, RemoteIdentity) andalso
                            not ircd_state_channel:mask_matches(Channel, exception, RemoteIdentity),
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
                _ ->
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

remote_channel_flags(Name) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{flags = Flags}] -> Flags;
        [] -> #{}
    end.

remote_names_entries(Name, Client, LocalMember) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            lists:sort([
                remote_display_nick(Remote, Roles, Client)
             || {NickKey, {_Peer, Roles}} <- maps:to_list(Members),
                [Remote] <- [mnesia:dirty_read(remote_client, NickKey)],
                remote_visible_in_names(Remote, Client, LocalMember)
            ]);
        [] ->
            []
    end.

remote_visible_in_names(#remote_client{modes = Modes}, _Client, LocalMember) ->
    LocalMember orelse not maps:is_key($i, Modes).

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
            mnesia:dirty_all_keys(remote_channel)
        ).

remote_user_local_recipients(NickKey) ->
    lists:usort([
        Pid
     || ChannelKey <- mnesia:dirty_all_keys(remote_channel),
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

propagate_introduction(
    #client{nick = Nick, user = User, host = Host, real = Real, pid = Pid}, Server
) ->
    Modes = ircd_state_channel:user_mode_string(ircd_state_client:user_modes(Pid)),
    server_broadcast(
        ircd_wire:line(
            Server,
            <<"NICK">>,
            [Nick, <<"0">>, User, Host, <<"1">>, Modes],
            Real
        )
    ).

propagate_nick_change(Client, Nick) ->
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"NICK">>, [Nick], none)).

propagate_away(Client, none) ->
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"AWAY">>, [], none));
propagate_away(Client, Message) ->
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"AWAY">>, [], Message)).

propagate_quit(Client, Reason) ->
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"QUIT">>, [], Reason)).

server_broadcast(Line) ->
    relay_except(undefined, Line).

%% Forward one server message to every authenticated peer except the ingress link.
relay_except(Ingress, Line) ->
    try ircd_links:send_except(Ingress, iolist_to_binary(Line)) of
        _ -> ok
    catch
        exit:_ -> ok
    end.

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

propagate_invite(Client, Nick, Name, Peer) ->
    Line = iolist_to_binary(
        ircd_wire:line(ircd_state_send:prefix(Client), <<"INVITE">>, [Nick, Name], none)
    ),
    _ = ircd_links:send(Peer, Line),
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Peers = lists:usort([MemberPeer || {_Nick, {MemberPeer, _}} <- maps:to_list(Members)]),
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

receive_remote_invite(Peer, Prefix, Nick, Name) ->
    case remote_source(Peer, Prefix) of
        {ok, #remote_client{}} ->
            case ircd_state_client:find_nick(Nick) of
                #client{pid = Pid} = Target ->
                    remember_local_invite(Pid, Name),
                    ircd_state_send:send(
                        Pid, Prefix, <<"INVITE">>, [Target#client.nick, Name], none
                    ),
                    ok;
                undefined ->
                    case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                        [#remote_client{peer = Dest, nick = RemoteNick, key = NickKey}] ->
                            remember_remote_invite_link(NickKey, Name),
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
            mnesia:dirty_write(Channel#channel{invited = lists:usort([Pid | Invited])});
        [] ->
            ok
    end.

remember_remote_invite_link(NickKey, Name) ->
    Key = ircd_wire:fold(Name),
    Channel =
        case mnesia:dirty_read(remote_channel, Key) of
            [Existing] -> Existing;
            [] -> #remote_channel{key = Key, name = Name}
        end,
    mnesia:dirty_write(Channel#remote_channel{
        invited = (Channel#remote_channel.invited)#{NickKey => true}
    }).

propagate_topic(Client, Name, Topic) ->
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"TOPIC">>, [Name], Topic)).

propagate_channel_mode(Client, Name, Mode, Args) ->
    server_broadcast(
        ircd_wire:line(ircd_state_send:prefix(Client), <<"MODE">>, [Name, Mode | Args], none)
    ).

propagate_channel_kick(Client, Name, Nick, Reason) ->
    server_broadcast(
        ircd_wire:line(ircd_state_send:prefix(Client), <<"KICK">>, [Name, Nick], Reason)
    ).

propagate_join(Client, Name, Roles) ->
    Server = maps:get(name, persistent_term:get({ircd_state, config})),
    server_broadcast(ircd_wire:line(ircd_state_send:prefix(Client), <<"JOIN">>, [Name], none)),
    Member = iolist_to_binary(njoin_member(Client, Roles)),
    server_broadcast(ircd_wire:line(Server, <<"NJOIN">>, [Name], Member)),
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{flags = Flags, password = Password, limit = Limit, lists = Lists}] ->
            lists:foreach(
                fun(Line) -> server_broadcast(Line) end,
                channel_mode_burst(Name, Flags, Password, Limit, Lists, Server)
            );
        [] ->
            ok
    end.

%% @doc Send prepared lines to every peer that has members of the channel.
-spec propagate_channel_lines(binary(), [iodata()]) -> ok.
propagate_channel_lines(Name, Lines) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Peers = lists:usort([Peer || {_Nick, {Peer, _Roles}} <- maps:to_list(Members)]),
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

%% @doc `BATCH +<ref> draft/multiline <target>` or `BATCH -<ref>` from a peer.
%% Open batches are kept per peer and reference in the state process and are
%% bounded by the multiline line limit.
-spec receive_remote_batch(binary(), binary(), [binary()], list()) -> ok | {error, term()}.
receive_remote_batch(Peer, Prefix, [<<"+", Ref/binary>>, <<"draft/multiline">>, Target | _], Tags) ->
    case remote_source(Peer, Prefix) of
        {ok, _} ->
            put({ircd_peer_batch, Peer, Ref}, #{
                prefix => Prefix,
                target => ircd_wire:retain(Target),
                tags => trusted_server_tags(Tags) ++ ircd_cap:client_tags(Tags),
                command => undefined,
                lines => [],
                count => 0
            }),
            ok;
        error ->
            {error, unknown_remote_source}
    end;
receive_remote_batch(Peer, _Prefix, [<<"-", Ref/binary>> | _], _Tags) ->
    case erase({ircd_peer_batch, Peer, Ref}) of
        #{command := Command, lines := [_ | _] = Lines} = Batch when Command =/= undefined ->
            deliver_remote_multiline(Peer, Batch#{lines := lists:reverse(Lines)});
        _ ->
            ok
    end;
receive_remote_batch(_Peer, _Prefix, _Params, _Tags) ->
    {error, invalid_batch}.

%% @doc One PRIVMSG or NOTICE line of an open peer multiline batch.
-spec remote_batch_line(binary(), binary(), binary(), [binary()], list()) -> ok | {error, term()}.
remote_batch_line(Peer, Prefix, Command, [_Target, Text | _], Tags) ->
    {_, Ref} = lists:keyfind(<<"batch">>, 1, Tags),
    {_, MaxLines} = ircd_cap:multiline_limits(),
    case get({ircd_peer_batch, Peer, Ref}) of
        #{prefix := Prefix, count := Count, lines := Lines} = Batch when Count < MaxLines ->
            Concat = lists:keymember(<<"draft/multiline-concat">>, 1, Tags),
            put({ircd_peer_batch, Peer, Ref}, Batch#{
                command => Command,
                lines => [{Concat, ircd_wire:retain(Text)} | Lines],
                count => Count + 1
            }),
            ok;
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
            ircd_state_batch:deliver_multiline(Pid, Prefix, Command, Nick, Lines, Tags, normal);
        undefined ->
            case ircd_wire:channel(Target) of
                true ->
                    Key = ircd_wire:fold(Target),
                    [Nick | _] = binary:split(Prefix, <<"!">>),
                    case
                        {
                            mnesia:dirty_read(remote_channel, Key),
                            mnesia:dirty_read(channel, Key)
                        }
                    of
                        {[#remote_channel{members = RM}], [#channel{name = Name, members = LM}]} ->
                            case maps:is_key(ircd_wire:fold(Nick), RM) of
                                true ->
                                    lists:foreach(
                                        fun(P) ->
                                            ircd_state_batch:deliver_multiline(
                                                P, Prefix, Command, Name, Lines, Tags, normal
                                            )
                                        end,
                                        maps:keys(LM)
                                    ),
                                    MsgId =
                                        case lists:keyfind(<<"msgid">>, 1, Tags) of
                                            {_, Id} -> Id;
                                            false -> undefined
                                        end,
                                    ircd_state_history:note_channel(
                                        Key,
                                        ircd_state_history:entry(
                                            Command,
                                            Prefix,
                                            Body,
                                            MsgId,
                                            erlang:system_time(millisecond),
                                            ircd_cap:client_tags(Tags),
                                            ircd_state_v3:remote_account(ircd_wire:fold(Nick))
                                        )
                                    );
                                false ->
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
            Peers = lists:usort([MemberPeer || {_Nick, {MemberPeer, _}} <- maps:to_list(Members)]),
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

propagate_channel_message(Name, Text, Command, Client, Tags) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Line = iolist_to_binary(
                ircd_wire:message(Tags, ircd_state_send:prefix(Client), Command, [Name], Text)
            ),
            Peers = lists:usort([Peer || {_Nick, {Peer, _Roles}} <- maps:to_list(Members)]),
            lists:foreach(fun(Peer) -> _ = ircd_links:send(Peer, Line) end, Peers),
            ok;
        [] ->
            ok
    end.
