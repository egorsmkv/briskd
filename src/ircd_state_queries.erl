-module(ircd_state_queries).
-export([ison/3, userhost/3, who/3, whois/3, whowas_options/1, whowas_reply/4]).
-include("ircd_state.hrl").

who(Params, Client, Server) ->
    who_command(Params, Client, Server).

ison(Nicks, Client, Server) ->
    Existing = [
        Actual
     || Nick <- Nicks,
        Actual <- [ison_nick(Nick)],
        Actual =/= undefined
    ],
    ircd_state:numeric(Client, Server, <<"303">>, [], lists:join(<<" ">>, Existing)).

userhost(Nicks, Client, Server) ->
    Entries = lists:filtermap(
        fun(Nick) ->
            case ircd_state:find_nick(Nick) of
                #client{pid = Pid, nick = Actual, host = Host, away = Away} ->
                    AwayMarker =
                        case Away of
                            undefined -> <<"+">>;
                            _ -> <<"-">>
                        end,
                    OperatorMarker =
                        case maps:is_key($o, ircd_state:user_modes(Pid)) of
                            true -> <<"*">>;
                            false -> <<>>
                        end,
                    {
                        true,
                        <<Actual/binary, OperatorMarker/binary, $=, AwayMarker/binary, Host/binary>>
                    };
                undefined ->
                    remote_userhost(Nick)
            end
        end,
        lists:sublist(Nicks, 5)
    ),
    ircd_state:numeric(Client, Server, <<"302">>, [], lists:join(<<" ">>, Entries)).

ison_nick(Nick) ->
    case ircd_state:find_nick(Nick) of
        #client{nick = Actual} ->
            Actual;
        undefined ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [#remote_client{nick = Actual}] -> Actual;
                [] -> undefined
            end
    end.

remote_userhost(Nick) ->
    case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
        [#remote_client{nick = Actual, host = Host, modes = Modes}] ->
            OperatorMarker =
                case maps:is_key($o, Modes) of
                    true -> <<"*">>;
                    false -> <<>>
                end,
            AwayMarker =
                case maps:is_key($a, Modes) of
                    true -> $-;
                    false -> $+
                end,
            {true, <<Actual/binary, OperatorMarker/binary, $=, AwayMarker, Host/binary>>};
        [] ->
            false
    end.

%% Select WHO matches and format RFC 2812 WHO replies.
who_command([], Client, Server) ->
    who_mask(<<"*">>, false, Client, Server);
who_command([Mask, Filter | _], Client, Server) ->
    who_mask(Mask, ircd_wire:fold(Filter) =:= <<"o">>, Client, Server);
who_command([Mask], Client, Server) ->
    who_mask(Mask, false, Client, Server).

who_mask(Mask, OperatorsOnly, Client, Server) ->
    ChannelKey = ircd_wire:fold(Mask),
    case mnesia:dirty_read(channel, ChannelKey) of
        [#channel{name = Name, members = Members, flags = Flags}] ->
            RemoteFlags = ircd_state:remote_channel_flags(Name),
            LocalMember = maps:is_key(Client#client.pid, Members),
            Visible =
                not (maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags)) andalso
                    (LocalMember orelse
                        not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags) orelse
                            maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags))),
            lists:foreach(
                fun(Pid) ->
                    case {Visible, mnesia:dirty_read(client, Pid)} of
                        {true, [Member]} ->
                            case
                                ircd_state:visible_member(Pid, Client, Members) andalso
                                    who_operator_matches(Pid, OperatorsOnly)
                            of
                                true -> who_reply(Member, Name, Client, Server);
                                false -> ok
                            end;
                        _ ->
                            ok
                    end
                end,
                maps:keys(Members)
            ),
            case Visible of
                true -> remote_who_channel(Name, Client, OperatorsOnly, Server);
                false -> ok
            end;
        [] ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{name = Name}] ->
                    remote_who_channel(Name, Client, OperatorsOnly, Server);
                [] ->
                    who_mask_nonchannel(Mask, OperatorsOnly, Client, Server)
            end
    end,
    ircd_state:numeric(Client, Server, <<"315">>, [Mask], <<"End of WHO list">>).

who_mask_nonchannel(Mask, OperatorsOnly, Client, Server) ->
    case ircd_state:find_nick(Mask) of
        #client{} = Member ->
            case
                ircd_state:user_visible(Member, Client) andalso
                    who_operator_matches(Member#client.pid, OperatorsOnly)
            of
                true -> who_reply(Member, <<"*">>, Client, Server);
                false -> ok
            end;
        undefined ->
            lists:foreach(
                fun(Pid) ->
                    case mnesia:dirty_read(client, Pid) of
                        [Member] ->
                            case
                                ircd_state:ready(Member) andalso who_matches(Mask, Member) andalso
                                    ircd_state:user_visible(Member, Client) andalso
                                    who_operator_matches(Member#client.pid, OperatorsOnly)
                            of
                                true ->
                                    who_reply(
                                        Member, who_channel(Member, Client), Client, Server
                                    );
                                false ->
                                    ok
                            end;
                        [] ->
                            ok
                    end
                end,
                mnesia:dirty_all_keys(client)
            ),
            remote_who_mask(Mask, OperatorsOnly, Client, Server)
    end.

remote_who_channel(Name, Client, OperatorsOnly, Server) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{name = Canonical, members = Members, flags = Flags}] ->
            LocalMember =
                case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
                    [#channel{members = LocalMembers}] ->
                        maps:is_key(Client#client.pid, LocalMembers);
                    [] ->
                        false
                end,
            Visible =
                not maps:is_key($a, Flags) andalso
                    (LocalMember orelse not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))),
            case Visible of
                false ->
                    ok;
                true ->
                    lists:foreach(
                        fun({NickKey, {_Peer, Roles}}) ->
                            case mnesia:dirty_read(remote_client, NickKey) of
                                [
                                    #remote_client{
                                        nick = Nick,
                                        user = User,
                                        host = Host,
                                        real = Real,
                                        server = Home,
                                        peer = Peer,
                                        modes = Modes
                                    }
                                ] ->
                                    IsOperator = maps:is_key($o, Modes),
                                    case
                                        ircd_state:remote_user_visible_to_requester(
                                            NickKey, Modes, Client
                                        ) andalso
                                            (not OperatorsOnly orelse IsOperator)
                                    of
                                        true ->
                                            Away =
                                                case maps:is_key($a, Modes) of
                                                    true -> $G;
                                                    false -> $H
                                                end,
                                            UserOperator =
                                                case IsOperator of
                                                    true -> $*;
                                                    false -> <<>>
                                                end,
                                            ChannelStatus =
                                                case
                                                    {
                                                        lists:member(operator, Roles),
                                                        lists:member(voice, Roles)
                                                    }
                                                of
                                                    {true, _} -> <<$@>>;
                                                    {false, true} -> <<$+>>;
                                                    _ -> <<>>
                                                end,
                                            Status = list_to_binary([
                                                Away, UserOperator, ChannelStatus
                                            ]),
                                            ircd_state:numeric(
                                                Client,
                                                Server,
                                                <<"352">>,
                                                [
                                                    Canonical,
                                                    User,
                                                    Host,
                                                    home_server_name(Home, Peer),
                                                    Nick,
                                                    Status
                                                ],
                                                [<<"0 ">>, Real]
                                            );
                                        false ->
                                            ok
                                    end;
                                [] ->
                                    ok
                            end
                        end,
                        maps:to_list(Members)
                    )
            end;
        [] ->
            ok
    end.

who_operator_matches(_Pid, false) ->
    true;
who_operator_matches(Pid, true) ->
    maps:is_key($o, ircd_state:user_modes(Pid)).

remote_who_mask(Mask, OperatorsOnly, Client, Server) ->
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(remote_client, Key) of
                [
                    #remote_client{
                        nick = Nick,
                        user = User,
                        host = Host,
                        real = Real,
                        server = Home,
                        peer = Peer,
                        modes = Modes
                    }
                ] ->
                    Matches =
                        (Mask =:= <<"*">> orelse ircd_state:wildcard_match(Mask, Nick) orelse
                            ircd_state:wildcard_match(Mask, User) orelse
                            ircd_state:wildcard_match(Mask, Host) orelse
                            ircd_state:wildcard_match(Mask, Real)),
                    Visible = ircd_state:remote_user_visible_to_requester(
                        ircd_wire:fold(Nick), Modes, Client
                    ),
                    Operator = maps:is_key($o, Modes),
                    Away = maps:is_key($a, Modes),
                    case Matches andalso Visible andalso (not OperatorsOnly orelse Operator) of
                        true ->
                            Status =
                                list_to_binary([
                                    case Away of
                                        true -> $G;
                                        false -> $H
                                    end,
                                    case Operator of
                                        true -> $*;
                                        false -> <<>>
                                    end
                                ]),
                            ircd_state:numeric(
                                Client,
                                Server,
                                <<"352">>,
                                [<<"*">>, User, Host, home_server_name(Home, Peer), Nick, Status],
                                [<<"0 ">>, Real]
                            );
                        false ->
                            ok
                    end;
                [] ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(remote_client)
    ).

who_matches(<<"*">>, _) ->
    true;
who_matches(Mask, #client{nick = Nick, user = User, host = Host, real = Real}) ->
    Identity = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
    ircd_state:wildcard_match(Mask, Nick) orelse ircd_state:wildcard_match(Mask, User) orelse
        ircd_state:wildcard_match(Mask, Host) orelse ircd_state:wildcard_match(Mask, Real) orelse
        ircd_state:wildcard_match(Mask, Identity).

who_channel(#client{channels = Keys}, #client{pid = RequesterPid}) ->
    case
        [
            Name
         || Key <- Keys,
            [#channel{name = Name, members = Members, flags = Flags}] <-
                [mnesia:dirty_read(channel, Key)],
            not maps:is_key($a, Flags),
            maps:is_key(RequesterPid, Members) orelse
                not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))
        ]
    of
        [Name | _] -> Name;
        [] -> <<"*">>
    end.

who_reply(
    #client{nick = Nick, user = User, host = Host, real = Real} = Member,
    Channel,
    Requester,
    Server
) ->
    Away =
        case Member#client.away of
            undefined -> <<"H">>;
            _ -> <<"G">>
        end,
    Roles =
        case mnesia:dirty_read(channel, ircd_wire:fold(Channel)) of
            [#channel{members = Members}] -> maps:get(Member#client.pid, Members, []);
            [] -> []
        end,
    ChannelStatus =
        case {lists:member(operator, Roles), lists:member(voice, Roles)} of
            {true, _} -> <<"@">>;
            {false, true} -> <<"+">>;
            _ -> <<>>
        end,
    UserOperator =
        case maps:is_key($o, ircd_state:user_modes(Member#client.pid)) of
            true -> <<"*">>;
            false -> <<>>
        end,
    Status = <<Away/binary, UserOperator/binary, ChannelStatus/binary>>,
    ircd_state:numeric(
        Requester,
        Server,
        <<"352">>,
        [Channel, User, Host, Server, Nick, Status],
        [<<"0 ">>, Real]
    ).

whois_operator(Nick, Pid, Client, Server) ->
    case maps:is_key($o, ircd_state:user_modes(Pid)) of
        false ->
            ok;
        true ->
            Text =
                case ircd_state:administrator(Pid) of
                    true -> <<"is an IRC administrator">>;
                    false -> <<"is an IRC operator">>
                end,
            ircd_state:numeric(Client, Server, <<"313">>, [Nick], Text)
    end.

%% Produce the local server's WHOIS numerics for one nickname mask.
whois(Nick, Client, Server) ->
    case ircd_state:find_nick(Nick) of
        #client{
            pid = TargetPid,
            nick = Actual,
            user = User,
            host = Host,
            real = Real,
            away = Away,
            channels = Channels
        } = Target when User =/= undefined ->
            case ircd_state:user_visible(Target, Client) of
                true ->
                    ircd_state:numeric(
                        Client, Server, <<"311">>, [Actual, User, Host, <<"*">>], Real
                    ),
                    case Away of
                        undefined -> ok;
                        _ -> ircd_state:numeric(Client, Server, <<"301">>, [Actual], Away)
                    end,
                    whois_channels(Channels, TargetPid, Actual, Client, Server),
                    ircd_state:numeric(
                        Client, Server, <<"312">>, [Actual, Server], <<"IRC server">>
                    ),
                    whois_operator(Actual, TargetPid, Client, Server),
                    Idle =
                        case mnesia:dirty_read(activity, TargetPid) of
                            [#activity{last = Last}] ->
                                max(0, erlang:system_time(second) - Last);
                            [] ->
                                0
                        end,
                    ircd_state:numeric(
                        Client,
                        Server,
                        <<"317">>,
                        [Actual, integer_to_binary(Idle)],
                        <<"seconds idle">>
                    );
                false ->
                    ircd_state:numeric(
                        Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>
                    )
            end;
        _ ->
            remote_whois(Nick, Client, Server)
    end,
    ircd_state:numeric(Client, Server, <<"318">>, [Nick], <<"End of WHOIS list">>).

%% WHO and WHOIS name the user's home server. `peer` is only the adjacent link.
home_server_name(Server, _Peer) when is_binary(Server) ->
    Server;
home_server_name(_Server, Peer) ->
    Peer.

remote_whois(Nick, Client, Server) ->
    case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
        [Remote] ->
            Actual = Remote#remote_client.nick,
            User = Remote#remote_client.user,
            Host = Remote#remote_client.host,
            Peer = home_server_name(Remote#remote_client.server, Remote#remote_client.peer),
            Real = Remote#remote_client.real,
            Modes = Remote#remote_client.modes,
            case
                ircd_state:remote_user_visible_to_requester(ircd_wire:fold(Actual), Modes, Client)
            of
                false ->
                    ircd_state:numeric(
                        Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>
                    );
                true ->
                    ircd_state:numeric(
                        Client, Server, <<"311">>, [Actual, User, Host, <<"*">>], Real
                    ),
                    ircd_state:numeric(Client, Server, <<"312">>, [Actual, Peer], <<"IRC server">>),
                    case maps:is_key($a, Modes) of
                        true ->
                            ircd_state:numeric(Client, Server, <<"301">>, [Actual], <<"is away">>);
                        false ->
                            ok
                    end,
                    case maps:is_key($o, Modes) of
                        true ->
                            ircd_state:numeric(
                                Client,
                                Server,
                                <<"313">>,
                                [Actual],
                                <<"is an IRC operator">>
                            );
                        false ->
                            ok
                    end
            end;
        [] ->
            ircd_state:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>)
    end.

whois_channels(Keys, Pid, Nick, Client, Server) ->
    Entries = lists:filtermap(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{name = Name, members = Members, flags = Flags}] ->
                    Roles = maps:get(Pid, Members, []),
                    Visible =
                        not maps:is_key($a, Flags) andalso
                            (maps:is_key(Client#client.pid, Members) orelse
                                not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))),
                    case Visible of
                        false ->
                            false;
                        true ->
                            Prefix =
                                case {lists:member(operator, Roles), lists:member(voice, Roles)} of
                                    {true, _} -> <<"@">>;
                                    {false, true} -> <<"+">>;
                                    _ -> <<>>
                                end,
                            {true, <<Prefix/binary, Name/binary>>}
                    end;
                [] ->
                    false
            end
        end,
        Keys
    ),
    case Entries of
        [] -> ok;
        _ -> whois_channel_lines(Entries, [], 0, Nick, Client, Server)
    end.

whois_channel_lines([], [], _, _, _, _) ->
    ok;
whois_channel_lines([], Acc, _, Nick, Client, Server) ->
    emit_whois_channels(lists:reverse(Acc), Nick, Client, Server);
whois_channel_lines([Entry | Rest], [], _, Nick, Client, Server) ->
    whois_channel_lines(Rest, [Entry], byte_size(Entry), Nick, Client, Server);
whois_channel_lines([Entry | Rest], Acc, Size, Nick, Client, Server) when
    Size + byte_size(Entry) + 1 =< 350
->
    whois_channel_lines(
        Rest,
        [Entry | Acc],
        Size + byte_size(Entry) + 1,
        Nick,
        Client,
        Server
    );
whois_channel_lines([Entry | Rest], Acc, _, Nick, Client, Server) ->
    emit_whois_channels(lists:reverse(Acc), Nick, Client, Server),
    whois_channel_lines([Entry | Rest], [], 0, Nick, Client, Server).

emit_whois_channels(Entries, Nick, Client, Server) ->
    ircd_state:numeric(Client, Server, <<"319">>, [Nick], lists:join(<<" ">>, Entries)).

whowas_options([]) ->
    {all, undefined};
whowas_options([Count | Rest]) ->
    Target =
        case Rest of
            [Value | _] -> Value;
            [] -> undefined
        end,
    try binary_to_integer(Count) of
        Limit -> {Limit, Target}
    catch
        error:badarg -> {all, Target}
    end.

whowas_reply(Nick, Count, Client, Server) ->
    Folded = ircd_wire:fold(Nick),
    History = lists:sort(
        fun(#whowas{time = Left}, #whowas{time = Right}) -> Left > Right end,
        [
            Entry
         || Key <- mnesia:dirty_all_keys(whowas),
            [Entry = #whowas{nick = StoredNick}] <- [mnesia:dirty_read(whowas, Key)],
            ircd_wire:fold(StoredNick) =:= Folded
        ]
    ),
    Results =
        case Count of
            Limit when is_integer(Limit), Limit > 0 -> lists:sublist(History, Limit);
            _ -> History
        end,
    case Results of
        [] ->
            ircd_state:numeric(Client, Server, <<"406">>, [Nick], <<"There was no such nickname">>);
        _ ->
            lists:foreach(
                fun(Entry) ->
                    #whowas{
                        nick = OldNick,
                        user = User,
                        host = Host,
                        real = Real,
                        server = OldServer
                    } = Entry,
                    ircd_state:numeric(
                        Client,
                        Server,
                        <<"314">>,
                        [OldNick, User, Host, <<"*">>],
                        Real
                    ),
                    ircd_state:numeric(
                        Client,
                        Server,
                        <<"312">>,
                        [OldNick, OldServer],
                        <<"IRC server">>
                    )
                end,
                Results
            )
    end.
