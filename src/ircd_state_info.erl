-module(ircd_state_info).
-moduledoc """
Server query, operator, and statistics commands.

Implements the RFC 2812 server queries `MOTD`, `LUSERS`, `STATS`, `LINKS`,
`TRACE`, `ADMIN`, and `INFO` (section 3.4), the operator commands `OPER`
(section 3.1.4), `KILL` (section 3.7.1), and `REHASH` (section 4.2), and the
disabled `USERS` command (446 ERR_USERSDISABLED). Every function runs inside
the single `m:ircd_state` gen_server process and reads the Mnesia and ETS
tables that process owns, plus the immutable configuration it keeps in
`persistent_term`.

In every handler `Client` is the requesting `client` record, `Server` is this
server's name (the numeric prefix), and `Params` are the command parameters.
An optional server argument is matched as a wildcard mask against `Server`
only; a query for another server is answered with 402 ERR_NOSUCHSERVER rather
than forwarded over server links.

Operator privilege is the `o` user mode of the **local** session, set only by
a successful `OPER`. Operator and administrator passwords are compared with
`ircd_config:secret_match/2` and are never logged or placed in replies.
""".
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
    note_user_counts/0,
    stats/3,
    trace/3,
    users_disabled/3
]).
-include("ircd_state.hrl").

-doc """
Check an optional server argument against this server's name.

`Params` is the remaining parameter list; its first element, when present, is
a wildcard mask (see `ircd_state_channel:wildcard_match/2`) matched against
`Server`. Returns `true` for no argument or a match, otherwise
`{false, Target}` so the caller can send 402 ERR_NOSUCHSERVER.
""".
-spec query_local_server([binary()], term()) -> true | {false, binary()}.
query_local_server([], _) ->
    true;
query_local_server([Target | _], Server) ->
    case ircd_state_channel:wildcard_match(Target, Server) of
        true -> true;
        false -> {false, Target}
    end.

-doc """
Handle `TRACE [<target>]` (RFC 2812 section 3.4.8) for this server only.

With no target, or a target mask matching this server, lists local registered
users: operators as 204 RPL_TRACEOPERATOR to everyone, and other users as 205
RPL_TRACEUSER only when the requester is an IRC operator. A target naming a
local nickname reports just that user. Every listing ends with 262
RPL_TRACEEND. Any other target, including a remote nickname, gets 402
ERR_NOSUCHSERVER.
""".
-spec trace([binary()], #client{}, binary()) -> ok.
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

-doc """
Handle `USERS [<target>]`, which this server keeps disabled (RFC 2812 section 4.5).

Replies 446 ERR_USERSDISABLED, or 402 ERR_NOSUCHSERVER when the target does
not match this server.
""".
-spec users_disabled([binary()], #client{}, binary()) -> ok.
users_disabled(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        true ->
            ircd_state_send:numeric(Client, Server, <<"446">>, [], <<"USERS has been disabled">>);
        {false, Target} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end.

server_wallops(Text, Server) ->
    Recipients =
        [
            Pid
         || Pid <- mnesia:dirty_all_keys(client),
            maps:is_key($w, ircd_state_client:user_modes(Pid))
        ],
    ircd_state_send:broadcast(Recipients, Server, <<"WALLOPS">>, [], Text).

-doc """
Handle `STATS [<query> [<target>]]` (RFC 2812 section 3.4.4).

Supported queries:

- `u`: 242 RPL_STATSUPTIME (uptime from monotonic time);
- `m`: 212 RPL_STATSCOMMANDS per command, from `ircd_command_stats`;
- `l`: 211 RPL_STATSLINKINFO per local connection (send queue reported as 0,
  byte counts in KiB, open time in seconds). An operator (`+o`) sees every
  local connection; anyone else sees only the line for their own connection;
- `o`: 243 RPL_STATSOLINE per configured operator name (never the password).
  Operator only: anyone else gets 481 ERR_NOPRIVILEGES and no 243 lines.

Each query, including an unsupported letter, no query at all, and a refused
`o`, ends with 219 RPL_ENDOFSTATS. A target that does not match this server
gets 402 ERR_NOSUCHSERVER. `u` and `m` need no operator privilege
(implementation policy: `l` and `o` expose other users' connections and the
operator account names, so they are restricted).
""".
-spec stats([binary()], #client{}, binary()) -> ok.
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
report_stats(<<"l">>, #client{pid = Self} = Client, Server) ->
    Pids =
        case is_operator(Self) of
            true -> mnesia:dirty_all_keys(client);
            false -> [Self]
        end,
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
        Pids
    ),
    ircd_state_send:numeric(Client, Server, <<"219">>, [<<"l">>], <<"End of STATS report">>);
report_stats(<<"o">>, #client{pid = Self} = Client, Server) ->
    case is_operator(Self) of
        true ->
            lists:foreach(
                fun({Name, _Password}) ->
                    ircd_state_send:numeric(
                        Client, Server, <<"243">>, [<<"O">>, <<"*">>, <<"*">>, Name], none
                    )
                end,
                persistent_term:get({ircd_state, operators}, [])
            );
        false ->
            ircd_state_send:numeric(
                Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>
            )
    end,
    ircd_state_send:numeric(Client, Server, <<"219">>, [<<"o">>], <<"End of STATS report">>);
report_stats(Query, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"219">>, [Query], <<"End of STATS report">>).

is_operator(Pid) ->
    maps:is_key($o, ircd_state_client:user_modes(Pid)).

two_digits(Value) when Value < 10 -> <<$0, ($0 + Value)>>;
two_digits(Value) -> integer_to_binary(Value).

-doc """
Handle `OPER <name> <password>` (RFC 2812 section 3.1.4).

`Name` is folded with `ircd_wire:fold/1` and looked up in the configured
`operators` and `administrators`. An unknown name gets 491 ERR_NOOPERHOST and a wrong password
464 ERR_PASSWDMISMATCH; both are logged as `oper_rejected` without the
password. On success the session gains user mode `+o`, a name listed in
`administrators` is also recorded as administrator and receives channel
operator on predefined channels it is already in
(`ircd_state_channel:grant_predefined_operator/2`), `MODE <nick> +o` is
broadcast to server peers, the client gets 381 RPL_YOUREOPER and its own
`MODE +o`, and `oper_accepted` is logged.
""".
-spec oper(binary(), binary(), #client{}, binary()) -> ok.
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
                    ),
                    ircd_state_send:send(
                        Pid,
                        ircd_state_send:prefix(Client),
                        <<"MODE">>,
                        [Client#client.nick, <<"+o">>],
                        none
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

-doc """
Handle `KILL <nickname> <comment>` (RFC 2812 section 3.7.1).

Requires user mode `+o` on the local session, otherwise 481
ERR_NOPRIVILEGES. Missing parameters give 461 ERR_NEEDMOREPARAMS and a
nickname that is not a local client gives 401 ERR_NOSUCHNICK. The target is
sent the `KILL` line and closed, users with `+w` receive a `WALLOPS` naming
the operator and target, an `oper_kill` audit event is logged at `notice`
with the operator and target nicknames (not the comment), and the target is
removed through `ircd_state_client:disconnect/3` with the comment as the quit
reason (which also propagates `QUIT` to peers). Returns `quit` when an operator killed its
own session, otherwise `ok`.
""".
-spec kill([binary()], #client{}, binary()) -> ok | quit.
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
            logger:notice(#{
                event => oper_kill, nick => Client#client.nick, target => Actual
            }),
            ircd_state_client:disconnect(Target, Reason, Server),
            case TargetPid =:= Client#client.pid of
                true -> quit;
                false -> ok
            end
    end;
kill_target(_, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"KILL">>], <<"Not enough parameters">>).

-doc """
Handle `REHASH` (RFC 2812 section 4.2): reload the JSON configuration file.

Requires user mode `+o`, otherwise 481 ERR_NOPRIVILEGES. The file at the
startup configuration path is loaded and validated with `ircd_config:load/1`;
a load error is logged and answered with 400 "Configuration reload failed".
Settings that need a restart (server name, bind address, listeners, TLS
options, `mnesia_dir`, `client_password`, `server_links`) must be unchanged,
otherwise the reply is 400 and nothing is applied.

When accepted, the new configuration replaces the running config map
(including `flood`, `e2ee`, `max_sendq`, and resource caps), the operator,
administrator, and predefined-channel lists (creating missing predefined
channels), the MOTD path, admin info, `reop_delay`, `max_clients`, and log
format and level, and triggers an asynchronous TLS certificate reload check
(`ircd_certs:check_async/0`).
Clients with `cap-notify` or `draft/extended-isupport` are told about changed
capabilities and ISUPPORT tokens, `+w` users get a `WALLOPS`, an
`oper_rehash` audit event (`result => accepted`, logged just before the new
configuration, including its log level, is applied) at `notice` with the
operator nickname, and the operator gets 382 RPL_REHASHING with the file path.
A refused reload is logged as `oper_rehash` with `result => restart_required`,
or `rehash_failed` with the load error, both at `warning`.
""".
-spec rehash(#client{}, binary()) -> ok.
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
                    logger:warning(#{
                        event => rehash_failed, nick => Client#client.nick, reason => Reason
                    }),
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
            ),
            logger:warning(#{
                event => oper_rehash, nick => Client#client.nick, result => restart_required
            });
        true ->
            Clients = [Pid || {Pid, _} <- ets:tab2list(ircd_caps)],
            Advertised = maps:from_list([{Pid, ircd_cap:advertised(Pid)} || Pid <- Clients]),
            Tokens = ircd_isupport:tokens(),
            %% Logged before the new log level takes effect, so the audit
            %% event is not lost when the reload lowers the level.
            logger:notice(#{event => oper_rehash, nick => Client#client.nick, result => accepted}),
            apply_rehash(NewConfig),
            %% Certificate paths are static, their contents are not: reload
            %% renewed certificates now instead of at the next interval.
            ok = ircd_certs:check_async(),
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
    Formatter = ircd_log:formatter(maps:get(log_format, Config)),
    ok = logger:update_handler_config(default, formatter, Formatter),
    ok = ircd_log:apply_level(maps:get(level, Config)).

-doc """
Handle `ADMIN [<target>]` (RFC 2812 section 3.4.9).

The target may be a mask matching this server or the nickname of a local
client; both answer for this server with 256 RPL_ADMINME, 257 RPL_ADMINLOC1,
258 RPL_ADMINLOC2, and 259 RPL_ADMINEMAIL from the configured `admin` fields
("Not configured" when absent). Any other target gets 402 ERR_NOSUCHSERVER.
""".
-spec admin([binary()], #client{}, binary()) -> ok.
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

-doc """
Handle `MOTD [<target>]` (RFC 2812 section 3.4.1); also sent after registration.

Reads the configured `motd_file` on each request and sends 375
RPL_MOTDSTART, one 372 RPL_MOTD per line, and 376 RPL_ENDOFMOTD. Lines are
split on LF, a trailing CR is removed, and lines longer than 80 octets are
wrapped. No configured or unreadable file gives 422 ERR_NOMOTD, and a target
that does not match this server gives 402 ERR_NOSUCHSERVER.
""".
-spec motd([binary()], #client{}, binary()) -> ok.
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

-doc """
Handle `INFO [<target>]` (RFC 2812 section 3.4.10).

Sends several 371 RPL_INFO lines (version, compile time, patch level, start
time, and the implemented RFCs) and 374 RPL_ENDOFINFO, or 402
ERR_NOSUCHSERVER when the target does not match this server.
""".
-spec info([binary()], #client{}, binary()) -> ok.
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

-doc """
Handle `LINKS [[<remote server>] <server mask>]` (RFC 2812 section 3.4.5).

A remote server argument must match this server, otherwise 402
ERR_NOSUCHSERVER. Sends 364 RPL_LINKS for this server (hop count 0 and the
configured `server_info`) and for each known server from
`ircd_state_net:links_entries/0`, in both cases only when its name matches the
mask, then 365 RPL_ENDOFLINKS.
""".
-spec links([binary()], #client{}, binary()) -> ok.
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
                        [<<"0 ">>, server_info()]
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

%% Server description for LINKS (`server_info` in configuration).
server_info() ->
    maps:get(server_info, persistent_term:get({ircd_state, config}), <<"Erlang/OTP IRC server">>).

-doc """
Record the current local and global registered-user counts so the maxima
reported by 265 RPL_LOCALUSERS and 266 RPL_GLOBALUSERS never go down.

Local counts ready local clients; global adds every remote user. The maxima
are kept in the state process dictionary, so they reset when that process
restarts. Returns `{Local, Global}`.
""".
-spec note_user_counts() -> {non_neg_integer(), non_neg_integer()}.
note_user_counts() ->
    Local = ets:foldl(
        fun(#client{} = C, N) ->
            case ircd_state_client:ready(C) of
                true -> N + 1;
                false -> N
            end
        end,
        0,
        client
    ),
    Global = Local + ets:info(remote_client, size),
    put(ircd_max_local, max(Local, get_count(ircd_max_local))),
    put(ircd_max_global, max(Global, get_count(ircd_max_global))),
    {Local, Global}.

get_count(Key) ->
    case get(Key) of
        undefined -> 0;
        N -> N
    end.

-doc """
Handle `LUSERS [<mask> [<target>]]` (RFC 2812 section 3.4.2).

The target must match this server, otherwise 402 ERR_NOSUCHSERVER. Sends 251
RPL_LUSERCLIENT (visible and invisible users, servers), then 252
RPL_LUSEROP, 253 RPL_LUSERUNKNOWN, and 254 RPL_LUSERCHANNELS when their
counts are non-zero, 255 RPL_LUSERME, and 265 RPL_LOCALUSERS and 266
RPL_GLOBALUSERS with their maxima. Network counts include users, operators,
and channels known through server links. A mask that does not match this
server zeroes those counts, including the invisible count in 251; the local
and global figures in 265 and 266 are still reported.
""".
-spec lusers([binary()], #client{}, binary()) -> ok.
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
            {LocalUsers, GlobalUsers} = note_user_counts(),
            Invisible =
                case Included of
                    true -> invisible_count();
                    false -> 0
                end,
            %% RFC 2812 RPL_LUSERCLIENT: visible users, invisible users, servers.
            ircd_state_send:numeric(
                Client,
                Server,
                <<"251">>,
                [],
                [
                    <<"There are ">>,
                    integer_to_binary(max(0, Users - Invisible)),
                    <<" users and ">>,
                    integer_to_binary(Invisible),
                    <<" invisible on ">>,
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
            _ = Clients,
            ircd_state_send:numeric(
                Client,
                Server,
                <<"255">>,
                [],
                [
                    <<"I have ">>,
                    integer_to_binary(LocalUsers),
                    <<" clients and ">>,
                    integer_to_binary(Servers - 1),
                    <<" servers">>
                ]
            ),
            ircd_state_send:numeric(
                Client,
                Server,
                <<"265">>,
                [integer_to_binary(LocalUsers), integer_to_binary(get_count(ircd_max_local))],
                [
                    <<"Current local users ">>,
                    integer_to_binary(LocalUsers),
                    <<", max ">>,
                    integer_to_binary(get_count(ircd_max_local))
                ]
            ),
            ircd_state_send:numeric(
                Client,
                Server,
                <<"266">>,
                [integer_to_binary(GlobalUsers), integer_to_binary(get_count(ircd_max_global))],
                [
                    <<"Current global users ">>,
                    integer_to_binary(GlobalUsers),
                    <<", max ">>,
                    integer_to_binary(get_count(ircd_max_global))
                ]
            )
    end.

%% Registered local users with mode +i plus remote users with +i.
invisible_count() ->
    Local = ets:foldl(
        fun(#client{pid = Pid} = C, N) ->
            case
                ircd_state_client:ready(C) andalso
                    maps:is_key($i, ircd_state_client:user_modes(Pid))
            of
                true -> N + 1;
                false -> N
            end
        end,
        0,
        client
    ),
    Remote = ets:foldl(
        fun(#remote_client{modes = Modes}, N) ->
            case maps:is_key($i, Modes) of
                true -> N + 1;
                false -> N
            end
        end,
        0,
        remote_client
    ),
    Local + Remote.
