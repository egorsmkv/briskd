-module(ircd_state_info).
-export([
    admin/3,
    info/3,
    kill/3,
    links/3,
    lusers/3,
    motd/3,
    oper/4,
    query_local_server/2,
    rehash/2,
    squery/3,
    stats/3,
    trace/3,
    users_disabled/3
]).
-include("ircd_state.hrl").

%% @doc Server query, operator, and statistics commands.

%% Match an optional server argument against this server's configured name.
query_local_server([], _) ->
    true;
query_local_server([Target | _], Server) ->
    case ircd_state_channel:wildcard_match(Target, Server) of
        true -> true;
        false -> {false, Target}
    end.

trace([], Client, Server) ->
    trace_server(Client, Server);
trace([Target | _], Client, Server) ->
    case ircd_state_channel:wildcard_match(Target, Server) of
        true ->
            trace_server(Client, Server);
        false ->
            case ircd_state_client:find_nick(Target) of
                undefined ->
                    ircd_state_send:numeric(
                        Client, Server, <<"402">>, [Target], <<"No such server">>
                    );
                User ->
                    trace_user(User, Client, Server),
                    trace_end(Client, Server)
            end
    end.

trace_server(Client, Server) ->
    RequesterIsOperator = maps:is_key($o, ircd_state_client:user_modes(Client#client.pid)),
    lists:foreach(
        fun(Pid) ->
            case mnesia:dirty_read(client, Pid) of
                [User] when User#client.nick =/= <<"*">> ->
                    IsOperator = maps:is_key($o, ircd_state_client:user_modes(Pid)),
                    case IsOperator orelse RequesterIsOperator of
                        true -> trace_user(User, Client, Server);
                        false -> ok
                    end;
                _ ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(client)
    ),
    trace_end(Client, Server).

trace_end(Client, Server) ->
    ircd_state_send:numeric(
        Client,
        Server,
        <<"262">>,
        [Server, <<"ircd-0.1.0">>],
        <<"End of TRACE">>
    ).

trace_user(#client{pid = Pid, nick = Nick}, Client, Server) ->
    {Reply, Label} =
        case maps:is_key($o, ircd_state_client:user_modes(Pid)) of
            true -> {<<"204">>, <<"Oper">>};
            false -> {<<"205">>, <<"User">>}
        end,
    ircd_state_send:numeric(Client, Server, Reply, [Label, <<"0">>, Nick], none).

users_disabled(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        true ->
            ircd_state_send:numeric(Client, Server, <<"446">>, [], <<"USERS has been disabled">>);
        {false, Target} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end.

squery([], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"411">>, [], <<"No recipient given (SQUERY)">>);
squery([_Service], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"412">>, [], <<"No text to send">>);
squery([_Service, <<>> | _], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"412">>, [], <<"No text to send">>);
squery([Service | _], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"401">>, [Service], <<"No such nick/channel">>).

server_wallops(Text, Server) ->
    Recipients =
        [
            Pid
         || Pid <- mnesia:dirty_all_keys(client),
            maps:is_key($w, ircd_state_client:user_modes(Pid))
        ],
    ircd_state_send:broadcast(Recipients, Server, <<"WALLOPS">>, [], Text).

stats(Params, Client, Server) ->
    {Query, Target} =
        case Params of
            [Letter, Name | _] -> {Letter, Name};
            [Letter] -> {Letter, undefined};
            [] -> {<<"*">>, undefined}
        end,
    case Target =/= undefined andalso not ircd_state_channel:wildcard_match(Target, Server) of
        true ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        false ->
            report_stats(Query, Client, Server)
    end.

report_stats(<<"u">>, Client, Server) ->
    Uptime = erlang:monotonic_time(second) - persistent_term:get({ircd_state, started_at}),
    Days = Uptime div 86400,
    Hours = (Uptime rem 86400) div 3600,
    Minutes = (Uptime rem 3600) div 60,
    Seconds = Uptime rem 60,
    ircd_state_send:numeric(
        Client,
        Server,
        <<"242">>,
        [],
        [
            <<"Server Up ">>,
            integer_to_binary(Days),
            <<" days ">>,
            two_digits(Hours),
            <<":">>,
            two_digits(Minutes),
            <<":">>,
            two_digits(Seconds)
        ]
    ),
    ircd_state_send:numeric(Client, Server, <<"219">>, [<<"u">>], <<"End of STATS report">>);
report_stats(<<"m">>, Client, Server) ->
    lists:foreach(
        fun({Command, Count, Bytes}) ->
            ircd_state_send:numeric(
                Client,
                Server,
                <<"212">>,
                [Command, integer_to_binary(Count), integer_to_binary(Bytes), <<"0">>],
                none
            )
        end,
        lists:sort(ets:tab2list(ircd_command_stats))
    ),
    ircd_state_send:numeric(Client, Server, <<"219">>, [<<"m">>], <<"End of STATS report">>);
report_stats(<<"l">>, Client, Server) ->
    lists:foreach(
        fun(Pid) ->
            case {mnesia:dirty_read(client, Pid), ircd_state_client:connection_stats(Pid)} of
                {
                    [#client{nick = Nick}],
                    #{
                        sent_messages := SentMessages,
                        sent_bytes := SentBytes,
                        recv_messages := RecvMessages,
                        recv_bytes := RecvBytes,
                        connected_at := ConnectedAt
                    }
                } ->
                    Open = erlang:monotonic_time(second) - ConnectedAt,
                    ircd_state_send:numeric(
                        Client,
                        Server,
                        <<"211">>,
                        [
                            Nick,
                            <<"0">>,
                            integer_to_binary(SentMessages),
                            integer_to_binary(SentBytes div 1024),
                            integer_to_binary(RecvMessages),
                            integer_to_binary(RecvBytes div 1024),
                            integer_to_binary(Open)
                        ],
                        none
                    );
                _ ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(client)
    ),
    ircd_state_send:numeric(Client, Server, <<"219">>, [<<"l">>], <<"End of STATS report">>);
report_stats(<<"o">>, Client, Server) ->
    lists:foreach(
        fun({Name, _Password}) ->
            ircd_state_send:numeric(
                Client, Server, <<"243">>, [<<"O">>, <<"*">>, <<"*">>, Name], none
            )
        end,
        persistent_term:get({ircd_state, operators}, [])
    ),
    ircd_state_send:numeric(Client, Server, <<"219">>, [<<"o">>], <<"End of STATS report">>);
report_stats(Query, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"219">>, [Query], <<"End of STATS report">>).

two_digits(Value) when Value < 10 -> <<$0, ($0 + Value)>>;
two_digits(Value) -> integer_to_binary(Value).

oper(Name, Password, #client{pid = Pid} = Client, Server) ->
    Credentials = persistent_term:get({ircd_state, operators}, []),
    Fold = ircd_wire:fold(Name),
    case lists:keyfind(Fold, 1, Credentials) of
        false ->
            logger:warning(#{
                event => oper_rejected,
                nick => Client#client.nick,
                account => Name,
                reason => unknown
            }),
            ircd_state_send:numeric(Client, Server, <<"491">>, [], <<"No O-lines for your host">>);
        {_, Expected} ->
            case ircd_config:secret_match(Password, Expected) of
                true ->
                    case
                        lists:member(Fold, persistent_term:get({ircd_state, administrators}, []))
                    of
                        true -> ets:insert(ircd_admins, {Pid});
                        false -> ok
                    end,
                    Modes = (ircd_state_client:user_modes(Pid))#{$o => true},
                    mnesia:dirty_write(#user_modes{pid = Pid, modes = Modes}),
                    ircd_state_channel:grant_predefined_operator(Client, Server),
                    ircd_state_link:server_broadcast(
                        ircd_wire:line(
                            ircd_state_send:prefix(Client),
                            <<"MODE">>,
                            [Client#client.nick, <<"+o">>],
                            none
                        )
                    ),
                    logger:info(#{
                        event => oper_accepted, nick => Client#client.nick, account => Name
                    }),
                    ircd_state_send:numeric(
                        Client, Server, <<"381">>, [], <<"You are now an IRC operator">>
                    );
                false ->
                    logger:warning(#{
                        event => oper_rejected,
                        nick => Client#client.nick,
                        account => Name,
                        reason => password
                    }),
                    ircd_state_send:numeric(Client, Server, <<"464">>, [], <<"Password incorrect">>)
            end
    end.

kill(Params, #client{pid = Pid} = Client, Server) ->
    case maps:is_key($o, ircd_state_client:user_modes(Pid)) of
        false ->
            ircd_state_send:numeric(
                Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>
            );
        true ->
            kill_target(Params, Client, Server)
    end.

kill_target([Nick, Reason | _], Client, Server) ->
    case ircd_state_client:find_nick(Nick) of
        undefined ->
            ircd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>);
        #client{pid = TargetPid, nick = Actual} = Target ->
            Line = ircd_wire:line(ircd_state_send:prefix(Client), <<"KILL">>, [Actual], Reason),
            TargetPid ! {irc_close, Line},
            server_wallops(
                [<<"Oper ">>, Client#client.nick, <<" used KILL on ">>, Actual, <<": ">>, Reason],
                Server
            ),
            ircd_state_client:disconnect(Target, Reason, Server),
            case TargetPid =:= Client#client.pid of
                true -> quit;
                false -> ok
            end
    end;
kill_target(_, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"KILL">>], <<"Not enough parameters">>).

rehash(#client{pid = Pid} = Client, Server) ->
    case maps:is_key($o, ircd_state_client:user_modes(Pid)) of
        false ->
            ircd_state_send:numeric(
                Client,
                Server,
                <<"481">>,
                [],
                <<"Permission Denied- You're not an IRC operator">>
            );
        true ->
            Path = persistent_term:get({ircd_state, config_path}),
            case ircd_config:load(Path) of
                {ok, NewConfig} ->
                    rehash_config(NewConfig, Path, Client, Server);
                {error, Reason} ->
                    logger:warning(#{event => rehash_failed, reason => Reason}),
                    ircd_state_send:numeric(
                        Client,
                        Server,
                        <<"400">>,
                        [<<"REHASH">>],
                        <<"Configuration reload failed">>
                    )
            end
    end.

rehash_config(NewConfig, Path, Client, Server) ->
    OldConfig = persistent_term:get({ircd_state, config}),
    StaticKeys = [
        name, ip, tcp, tls, ws, wss, tls_options, mnesia_dir, client_password, server_links
    ],
    case
        lists:all(fun(Key) -> maps:get(Key, OldConfig) =:= maps:get(Key, NewConfig) end, StaticKeys)
    of
        false ->
            ircd_state_send:numeric(
                Client,
                Server,
                <<"400">>,
                [<<"REHASH">>],
                <<"Listener and database changes require a restart">>
            );
        true ->
            Clients = [Pid || {Pid, _} <- ets:tab2list(ircd_caps)],
            Advertised = maps:from_list([{Pid, ircd_cap:advertised(Pid)} || Pid <- Clients]),
            Tokens = ircd_isupport:tokens(),
            apply_rehash(NewConfig),
            ircd_state_net:notify_cap_changes(Advertised, Server),
            notify_isupport_changes(Tokens, ircd_isupport:tokens(), Clients, Server),
            server_wallops(
                [<<"Oper ">>, Client#client.nick, <<" rehashed the configuration">>], Server
            ),
            ircd_state_send:numeric(
                Client, Server, <<"382">>, [unicode:characters_to_binary(Path)], <<"Rehashing">>
            )
    end.

%% draft/extended-isupport: registered clients with the capability get the
%% changed and removed (`-TOKEN`) ISUPPORT entries in a new batch.
notify_isupport_changes(Old, Old, _Clients, _Server) ->
    ok;
notify_isupport_changes(Old, New, Clients, Server) ->
    Name = fun(Token) -> hd(binary:split(Token, <<"=">>)) end,
    NewNames = [Name(T) || T <- New],
    Changed =
        [T || T <- New, not lists:member(T, Old)] ++
            [<<"-", (Name(T))/binary>> || T <- Old, not lists:member(Name(T), NewNames)],
    lists:foreach(
        fun(Pid) ->
            case
                ircd_cap:enabled(Pid, <<"draft/extended-isupport">>) andalso
                    mnesia:dirty_read(client, Pid)
            of
                [#client{} = Client] ->
                    case ircd_state_client:ready(Client) of
                        true -> ircd_isupport:send_tokens(Client, Server, Changed, true);
                        false -> ok
                    end;
                _ ->
                    ok
            end
        end,
        Clients
    ).

apply_rehash(Config) ->
    persistent_term:put({ircd_state, config}, Config),
    ircd_state:store_accounts(Config),
    ircd_state:seed_channels(),
    persistent_term:put({ircd_state, motd_file}, maps:get(motd_file, Config)),
    persistent_term:put({ircd_state, admin}, maps:get(admin, Config)),
    persistent_term:put({ircd_state, reop_delay}, maps:get(reop_delay, Config)),
    persistent_term:put({ircd_state, server_links}, maps:get(server_links, Config)),
    persistent_term:put({ircd_sessions, max_clients}, maps:get(max_clients, Config)),
    Formatter =
        case maps:get(log_format, Config) of
            <<"json">> -> {ircd_log, #{}};
            <<"text">> -> {flatlog, #{template => [time, " ", level, " ", msg]}}
        end,
    ok = logger:update_handler_config(default, formatter, Formatter),
    ok = ircd_log:apply_level(maps:get(level, Config)).

admin(Params, Client, Server) ->
    case admin_target(Params, Server) of
        {false, Target} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            Info = persistent_term:get({ircd_state, admin}, #{}),
            ircd_state_send:numeric(
                Client,
                Server,
                <<"256">>,
                [Server],
                maps:get(name, Info, <<"IRC server administrator">>)
            ),
            ircd_state_send:numeric(
                Client, Server, <<"257">>, [], maps:get(location1, Info, <<"Not configured">>)
            ),
            ircd_state_send:numeric(
                Client, Server, <<"258">>, [], maps:get(location2, Info, <<"Not configured">>)
            ),
            ircd_state_send:numeric(
                Client, Server, <<"259">>, [], maps:get(email, Info, <<"Not configured">>)
            )
    end.

admin_target([], _) ->
    true;
admin_target([Target | _], Server) ->
    case
        ircd_state_channel:wildcard_match(Target, Server) orelse
            ircd_state_client:find_nick(Target) =/= undefined
    of
        true -> true;
        false -> {false, Target}
    end.

%% Send the configured MOTD sequence, or the RFC missing-file response.
motd(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        {false, Target} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            case persistent_term:get({ircd_state, motd_file}, null) of
                null ->
                    ircd_state_send:numeric(
                        Client, Server, <<"422">>, [], <<"MOTD File is missing">>
                    );
                Path ->
                    case file:read_file(Path) of
                        {ok, Contents} ->
                            ircd_state_send:numeric(
                                Client, Server, <<"375">>, [], <<"- Message of the day -">>
                            ),
                            lists:foreach(
                                fun(Line) ->
                                    ircd_state_send:numeric(Client, Server, <<"372">>, [], [
                                        <<"- ">>, Line
                                    ])
                                end,
                                motd_lines(Contents)
                            ),
                            ircd_state_send:numeric(
                                Client, Server, <<"376">>, [], <<"End of MOTD command">>
                            );
                        {error, _} ->
                            ircd_state_send:numeric(
                                Client, Server, <<"422">>, [], <<"MOTD File is missing">>
                            )
                    end
            end
    end.

motd_lines(<<>>) ->
    [];
motd_lines(Contents) ->
    Lines = binary:split(Contents, <<"\n">>, [global]),
    ContentLines = lists:sublist(
        Lines,
        length(Lines) -
            case lists:last(Lines) of
                <<>> -> 1;
                _ -> 0
            end
    ),
    lists:append([wrap_motd_line(strip_cr(Line)) || Line <- ContentLines]).

wrap_motd_line(<<>>) ->
    [<<>>];
wrap_motd_line(Line) when byte_size(Line) =< 80 ->
    [Line];
wrap_motd_line(<<Chunk:80/binary, Rest/binary>>) ->
    [Chunk | wrap_motd_line(Rest)].

strip_cr(<<>>) ->
    <<>>;
strip_cr(Line) ->
    case binary:last(Line) of
        $\r -> binary:part(Line, 0, byte_size(Line) - 1);
        _ -> Line
    end.

info(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        {false, Target} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            CompileTime = proplists:get_value(time, ircd_state:module_info(compile)),
            CompileText = iolist_to_binary(io_lib:format("~p", [CompileTime])),
            Started = persistent_term:get({ircd_state, started}),
            ircd_state_send:numeric(
                Client, Server, <<"371">>, [], <<"ircd-0.1.0, Erlang/OTP IRC server">>
            ),
            ircd_state_send:numeric(Client, Server, <<"371">>, [], [<<"Compiled: ">>, CompileText]),
            ircd_state_send:numeric(Client, Server, <<"371">>, [], <<"Patch level: 0">>),
            ircd_state_send:numeric(Client, Server, <<"371">>, [], [<<"Started: ">>, Started]),
            ircd_state_send:numeric(
                Client,
                Server,
                <<"371">>,
                [],
                <<"Protocol references: RFC 1459, 2810, 2811, 2812, 2813, 7194">>
            ),
            ircd_state_send:numeric(Client, Server, <<"374">>, [], <<"End of INFO list">>)
    end.

links(Params, Client, Server) ->
    {Remote, Mask} =
        case Params of
            [] -> {undefined, <<"*">>};
            [GivenMask] -> {undefined, GivenMask};
            [GivenRemote, GivenMask | _] -> {GivenRemote, GivenMask}
        end,
    case Remote =:= undefined orelse ircd_state_channel:wildcard_match(Remote, Server) of
        false ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Remote], <<"No such server">>);
        true ->
            case ircd_state_channel:wildcard_match(Mask, Server) of
                true ->
                    ircd_state_send:numeric(
                        Client,
                        Server,
                        <<"364">>,
                        [Server, Server],
                        [<<"0 ">>, Server, <<" (Erlang/OTP IRC server)">>]
                    );
                false ->
                    ok
            end,
            lists:foreach(
                fun({Name, Hop, Info}) ->
                    case ircd_state_channel:wildcard_match(Mask, Name) of
                        true ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"364">>,
                                [Name, Server],
                                [integer_to_binary(Hop), <<" ">>, Info]
                            );
                        false ->
                            ok
                    end
                end,
                ircd_state_net:links_entries()
            ),
            ircd_state_send:numeric(Client, Server, <<"365">>, [Mask], <<"End of LINKS list">>)
    end.

lusers(Params, Client, Server) ->
    {Mask, Target} =
        case Params of
            [] -> {<<"*">>, Server};
            [GivenMask] -> {GivenMask, Server};
            [GivenMask, GivenTarget | _] -> {GivenMask, GivenTarget}
        end,
    case ircd_state_channel:wildcard_match(Target, Server) of
        false ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            Included = ircd_state_channel:wildcard_match(Mask, Server),
            {Users, Operators, Unknown, Channels, Clients, Servers} =
                case Included of
                    true ->
                        {ReadyCount, UnknownCount, LocalOperatorCount, LocalCount} =
                            ets:foldl(
                                fun(#client{pid = Pid} = Record, {Ready, Unknown, Ops, Total}) ->
                                    case ircd_state_client:ready(Record) of
                                        true ->
                                            Op =
                                                case
                                                    maps:is_key(
                                                        $o, ircd_state_client:user_modes(Pid)
                                                    )
                                                of
                                                    true -> 1;
                                                    false -> 0
                                                end,
                                            {Ready + 1, Unknown, Ops + Op, Total + 1};
                                        false ->
                                            {Ready, Unknown + 1, Ops, Total + 1}
                                    end
                                end,
                                {0, 0, 0, 0},
                                client
                            ),
                        {RemoteCount, RemoteOperatorCount, RemoteServers} = ets:foldl(
                            fun(#remote_client{peer = Peer, modes = Modes}, {Count, Ops, Homes}) ->
                                Op =
                                    case maps:is_key($o, Modes) of
                                        true -> 1;
                                        false -> 0
                                    end,
                                {Count + 1, Ops + Op, Homes#{Peer => true}}
                            end,
                            {0, 0, #{}},
                            remote_client
                        ),
                        {
                            ReadyCount + RemoteCount,
                            LocalOperatorCount + RemoteOperatorCount,
                            UnknownCount,
                            map_size(
                                lists:foldl(
                                    fun(Key, Acc) -> Acc#{Key => true} end,
                                    maps:from_keys(mnesia:dirty_all_keys(channel), true),
                                    mnesia:dirty_all_keys(remote_channel)
                                )
                            ),
                            LocalCount + RemoteCount,
                            1 + map_size(RemoteServers)
                        };
                    false ->
                        {0, 0, 0, 0, 0, 0}
                end,
            ircd_state_send:numeric(
                Client,
                Server,
                <<"251">>,
                [],
                [
                    <<"There are ">>,
                    integer_to_binary(Users),
                    <<" users and ">>,
                    integer_to_binary(ircd_state_net:service_count()),
                    <<" services on ">>,
                    integer_to_binary(Servers),
                    <<" servers">>
                ]
            ),
            case Operators of
                0 ->
                    ok;
                _ ->
                    ircd_state_send:numeric(
                        Client,
                        Server,
                        <<"252">>,
                        [integer_to_binary(Operators)],
                        <<"operator(s) online">>
                    )
            end,
            case Unknown of
                0 ->
                    ok;
                _ ->
                    ircd_state_send:numeric(
                        Client,
                        Server,
                        <<"253">>,
                        [integer_to_binary(Unknown)],
                        <<"unknown connection(s)">>
                    )
            end,
            case Channels of
                0 ->
                    ok;
                _ ->
                    ircd_state_send:numeric(
                        Client,
                        Server,
                        <<"254">>,
                        [integer_to_binary(Channels)],
                        <<"channels formed">>
                    )
            end,
            ircd_state_send:numeric(
                Client,
                Server,
                <<"255">>,
                [],
                [
                    <<"I have ">>,
                    integer_to_binary(Clients),
                    <<" clients and ">>,
                    integer_to_binary(Servers),
                    <<" servers">>
                ]
            )
    end.
