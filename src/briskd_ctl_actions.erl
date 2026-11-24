-module(briskd_ctl_actions).
-moduledoc """
Administrative control-plane subcommand implementations and `m:briskd_state`
action handlers backing `m:briskd_ctl`.
""".
-export([
    cmd_accounts/1,
    cmd_backup/2,
    cmd_channels/1,
    cmd_check_config/2,
    cmd_clients/1,
    cmd_connect/2,
    cmd_drain/2,
    cmd_get_log_level/1,
    cmd_links/1,
    cmd_ping/1,
    cmd_reload_certs/1,
    cmd_search/1,
    cmd_status/1,
    cmd_stop/2,
    handle_state_action/2
]).
-include("briskd_state.hrl").
-include("briskd_account.hrl").
-include("briskd_population.hrl").

-doc """
Execute a state-mutating control action inside the `m:briskd_state` process.
Called only from `briskd_state:handle_call({ctl, Action}, ...)`.
""".
-spec handle_state_action(briskd_ctl:state_action(), binary()) -> {ok, map()} | {error, term()}.
handle_state_action(rehash, Server) ->
    case briskd_rehash:rehash_server(Server) of
        {ok, Path} -> {ok, #{status => <<"rehashed">>, config_path => Path}};
        {error, Reason} -> {error, Reason}
    end;
handle_state_action({set_log_level, LevelBin}, _Server) ->
    case briskd_config:parse_log_level(LevelBin) of
        {ok, Level} ->
            Config = briskd_config:current(),
            briskd_config:store(Config#{level => Level}),
            %% Kept by a later override change, which rebuilds the
            %% effective configuration from the file's.
            briskd_config:store_base((briskd_config:base())#{level => Level}),
            ok = briskd_log:apply_level(Level),
            logger:notice(#{event => ctl_log_level, level => Level}),
            {ok, #{status => <<"updated">>, log_level => LevelBin}};
        error ->
            {error, {invalid_log_level, LevelBin}}
    end;
handle_state_action({kick_client, Nick, Reason}, Server) ->
    case briskd_state_client:find_nick(Nick) of
        undefined ->
            {error, {no_such_nick, Nick}};
        #client{pid = Pid, nick = Actual} = Target ->
            Line = briskd_wire:line(Server, <<"KILL">>, [Actual], Reason),
            Pid ! {irc_close, Line},
            logger:notice(#{event => ctl_kill, target => Actual}),
            briskd_state_client:disconnect(Target, Reason, Server),
            {ok, #{status => <<"kicked">>, nick => Actual, reason => Reason}}
    end;
handle_state_action({squit, Target, Reason}, _Server) ->
    case mnesia:dirty_read(known_server, briskd_wire:fold(Target)) of
        [] ->
            {error, {no_such_server, Target}};
        [#known_server{name = Name}] ->
            logger:notice(#{event => ctl_squit, target => Name}),
            briskd_state_net:drop_server(Name, Reason, undefined),
            {ok, #{status => <<"split">>, server => Name, reason => Reason}}
    end;
handle_state_action({create_account, Name, Password, Email}, _Server) ->
    case briskd_account:create(Name, Email, Password, [], undefined) of
        {ok, Account} ->
            logger:notice(#{event => ctl_account_created, account => Account#account.name}),
            briskd_state_sync:account_created(Account),
            {ok, #{status => <<"created">>, account => Account#account.name}};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({notice_all, Text}, Server) ->
    Pids = [
        Pid
     || Pid <- briskd_state_client:pids(),
        [#client{} = Client] <- [mnesia:dirty_read(client, Pid)],
        briskd_state_client:ready(Client)
    ],
    lists:foreach(
        fun(Pid) ->
            briskd_state_send:send(Pid, Server, <<"NOTICE">>, [<<"*">>], Text)
        end,
        Pids
    ),
    logger:notice(#{event => ctl_notice_all, recipients => length(Pids)}),
    {ok, #{status => <<"sent">>, recipients => length(Pids)}};
handle_state_action({set_topic, ChannelName, Topic}, Server) ->
    Key = briskd_wire:fold(ChannelName),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            {error, {no_such_channel, ChannelName}};
        [#channel{name = Actual, members = Members} = Channel] ->
            Now = erlang:system_time(second),
            Updated = Channel#channel{
                topic = briskd_wire:retain(Topic),
                topic_by = Server,
                topic_at = Now
            },
            mnesia:dirty_write(Updated),
            briskd_state_send:broadcast(maps:keys(Members), Server, <<"TOPIC">>, [Actual], Topic),
            logger:notice(#{event => ctl_set_topic, channel => Actual}),
            {ok, #{status => <<"updated">>, channel => Actual, topic => Topic}}
    end;
handle_state_action({notice_channel, ChannelName, Text}, Server) ->
    Key = briskd_wire:fold(ChannelName),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            {error, {no_such_channel, ChannelName}};
        [#channel{name = Actual, members = Members}] ->
            Pids = maps:keys(Members),
            briskd_state_send:broadcast(Pids, Server, <<"NOTICE">>, [Actual], Text),
            logger:notice(#{
                event => ctl_notice_channel, channel => Actual, recipients => length(Pids)
            }),
            {ok, #{status => <<"sent">>, channel => Actual, recipients => length(Pids)}}
    end;
handle_state_action({reset_password, Name, Password}, _Server) ->
    case briskd_account:set_password(Name, Password) of
        {ok, #account{name = Actual} = Updated} ->
            logger:notice(#{event => ctl_password_reset, account => Actual}),
            briskd_state_sync:account_created(Updated),
            {ok, #{status => <<"password_updated">>, account => Actual}};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({verify_account, Name}, _Server) ->
    case briskd_account:force_verify(Name) of
        {ok, #account{name = Actual} = Account} ->
            logger:notice(#{event => ctl_account_verified, account => Actual}),
            briskd_state_sync:account_created(Account),
            {ok, #{status => <<"verified">>, account => Actual}};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({delete_account, Name}, Server) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(account, Key) of
        [] ->
            {error, {no_such_account, Name}};
        [#account{name = Actual} = Account] ->
            lists:foreach(
                fun(Pid) ->
                    case mnesia:dirty_read(client, Pid) of
                        [#client{} = Client] ->
                            briskd_state_v3:logout(Client, Server);
                        [] ->
                            ok
                    end
                end,
                briskd_conn:account_pids(Key)
            ),
            MarkerKeys = mnesia:dirty_select(read_marker, [
                {{read_marker, {Key, '$1'}, '_'}, [], [{{Key, '$1'}}]}
            ]),
            lists:foreach(
                fun(MarkerKey) -> mnesia:dirty_delete(read_marker, MarkerKey) end,
                MarkerKeys
            ),
            DevKeys = mnesia:dirty_select(e2ee_device, [
                {{e2ee_device, {Key, '$1'}, '_', '_', '_', '_', '_', '_', '_', '_', '_'}, [], [
                    {{Key, '$1'}}
                ]}
            ]),
            lists:foreach(
                fun(DevKey) -> mnesia:dirty_delete(e2ee_device, DevKey) end,
                DevKeys
            ),
            QKeys = mnesia:dirty_select(e2ee_queue, [
                {{e2ee_queue, {Key, '$1', '$2'}, '_', '_', '_', '_', '_', '_'}, [], [
                    {{Key, '$1', '$2'}}
                ]}
            ]),
            lists:foreach(
                fun(QKey) -> mnesia:dirty_delete(e2ee_queue, QKey) end,
                QKeys
            ),
            briskd_account:unindex_account(Account),
            mnesia:dirty_delete(account, Key),
            case ets:whereis(briskd_account_channels) of
                undefined -> ok;
                _ -> ets:delete(briskd_account_channels, Key)
            end,
            logger:notice(#{event => ctl_account_deleted, account => Actual}),
            {ok, #{status => <<"deleted">>, account => Actual}}
    end;
handle_state_action({erase_account, Name}, Server) ->
    case handle_state_action({delete_account, Name}, Server) of
        {ok, #{account := Actual} = Reply} ->
            #{channel := C, direct := D} = briskd_state_history:erase_account(
                briskd_wire:fold(Actual)
            ),
            logger:notice(#{event => account_erased, channel_messages => C, direct_messages => D}),
            {ok, Reply#{channel_messages => C, direct_messages => D}};
        Other ->
            Other
    end;
handle_state_action({create_channel, Name, Topic}, Server) ->
    case briskd_state_channel:admin_create(Name, Topic, Server) of
        {ok, Actual} ->
            logger:notice(#{event => ctl_channel_created, channel => Actual}),
            {ok, #{status => <<"created">>, channel => Actual}};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({delete_channel, Name, Reason}, Server) ->
    case briskd_state_channel:admin_destroy(Name, Reason, Server) of
        {ok, Actual, Kicked} ->
            logger:notice(#{event => ctl_channel_deleted, channel => Actual, kicked => Kicked}),
            {ok, #{status => <<"deleted">>, channel => Actual, kicked => Kicked}};
        {error, Why} ->
            {error, Why}
    end;
handle_state_action({set_channel_modes, Name, Modes, Args}, Server) ->
    case briskd_state_channel:admin_mode(Name, Modes, Args, Server) of
        {ok, _Actual, <<>>, _Shown, [First | _]} ->
            {error, {mode_refused, First}};
        {ok, Actual, Applied, Shown, Errors} ->
            logger:notice(#{event => ctl_channel_modes, channel => Actual, modes => Applied}),
            {ok, #{
                status => <<"updated">>,
                channel => Actual,
                applied => Applied,
                params => Shown,
                errors => Errors
            }};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({set_email, Name, Email}, _Server) ->
    case Email =:= undefined orelse briskd_state_v3:valid_email(Email) of
        false ->
            {error, invalid_email};
        true ->
            case briskd_account:set_email(Name, Email) of
                {ok, #account{name = Actual}} ->
                    logger:notice(#{event => ctl_account_email_set, account => Actual}),
                    {ok, #{status => <<"updated">>, account => Actual}};
                {error, Reason} ->
                    {error, Reason}
            end
    end;
handle_state_action({add_certfp, Name, Fp}, _Server) ->
    case briskd_account:add_certfp(Name, Fp) of
        {ok, #account{name = Actual, certfps = Fps}} ->
            logger:notice(#{event => ctl_account_certfp_added, account => Actual}),
            {ok, #{status => <<"updated">>, account => Actual, certfps => Fps}};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({remove_certfp, Name, Fp}, _Server) ->
    case briskd_account:remove_certfp(Name, Fp) of
        {ok, #account{name = Actual, certfps = Fps}} ->
            logger:notice(#{event => ctl_account_certfp_removed, account => Actual}),
            {ok, #{status => <<"updated">>, account => Actual, certfps => Fps}};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action(Unknown, _Server) ->
    {error, {unknown_action, Unknown}}.

%%% Subcommand implementations

-doc "Run the `ping` / `health` control subcommand.".
-spec cmd_ping(json | text) -> {ok, binary()} | {error, binary()}.
cmd_ping(Format) ->
    Alive =
        is_pid(whereis(briskd_state)) andalso is_pid(whereis(briskd_sessions)) andalso
            is_pid(whereis(briskd_links)) andalso mnesia:system_info(is_running) =:= yes,
    case Alive of
        true ->
            briskd_ctl:reply_ok(Format, #{status => <<"ok">>, reply => <<"pong">>}, <<"pong">>);
        false ->
            briskd_ctl:reply_error(
                Format, #{status => <<"error">>, reason => <<"not_running">>}, <<"not running">>
            )
    end.

-doc "Run the `status` control subcommand.".
-spec cmd_status(json | text) -> {ok, binary()} | {error, binary()}.
cmd_status(Format) ->
    case whereis(briskd_state) of
        undefined ->
            briskd_ctl:reply_error(
                Format,
                #{status => <<"error">>, reason => <<"not_running">>},
                <<"briskd is not running">>
            );
        _ ->
            Config = briskd_config:current_or_empty(),
            StartedAt = persistent_term:get(
                {briskd_state, started_at}, erlang:monotonic_time(second)
            ),
            Uptime = max(0, erlang:monotonic_time(second) - StartedAt),
            StartedIso = list_to_binary(
                persistent_term:get({briskd_state, started}, "unknown")
            ),
            {SessionsCount, RegisteredCount, OperatorsCount} =
                case ets:whereis(briskd_population) of
                    undefined ->
                        Clients = [
                            C
                         || Pid <- briskd_state_client:pids(),
                            [#client{} = C] <- [mnesia:dirty_read(client, Pid)]
                        ],
                        Reg = [C || C <- Clients, briskd_state_client:ready(C)],
                        Ops = [
                            C
                         || #client{pid = P} = C <- Reg,
                            maps:is_key($o, briskd_state_client:user_modes(P))
                        ],
                        {length(Clients), length(Reg), length(Ops)};
                    _ ->
                        Pop = briskd_population:snapshot(),
                        {
                            Pop#population.local_users + Pop#population.unknown_users,
                            Pop#population.local_users,
                            Pop#population.operators
                        }
                end,
            Map = #{
                status => <<"running">>,
                name => maps:get(name, Config, <<"irc.local">>),
                network => maps:get(network, Config, <<"irc.local">>),
                version => briskd_app:vsn(),
                started_at => StartedIso,
                uptime_seconds => Uptime,
                retention => atom_to_binary(maps:get(retention, Config, channels)),
                log_level => atom_to_binary(maps:get(level, Config, info)),
                log_format => maps:get(log_format, Config, <<"json">>),
                listeners => active_listeners(),
                sessions => SessionsCount,
                max_clients => maps:get(max_clients, Config, 10000),
                registered_users => RegisteredCount,
                operators_online => OperatorsCount,
                remote_users => table_size(remote_client),
                channels => table_size(channel),
                remote_channels => table_size(remote_channel),
                known_servers => table_size(known_server),
                services => table_size(service),
                accounts => length(briskd_account:list()),
                db_disk_bytes => mnesia_disk_bytes(),
                db_memory_bytes => mnesia_memory_bytes(),
                db_tables => length(mnesia_tables()),
                memory_bytes => erlang:memory(total),
                erlang_processes => erlang:system_info(process_count)
            },
            Text = iolist_to_binary([
                <<"Server:           ">>,
                maps:get(name, Map),
                <<" (network: ">>,
                maps:get(network, Map),
                <<")\n">>,
                <<"Status:           running (up ">>,
                integer_to_binary(Uptime),
                <<"s since ">>,
                StartedIso,
                <<")\n">>,
                <<"Retention:        ">>,
                maps:get(retention, Map),
                <<" | Log: ">>,
                maps:get(log_level, Map),
                <<" (">>,
                maps:get(log_format, Map),
                <<")\n">>,
                <<"Listeners:        ">>,
                format_listeners_text(maps:get(listeners, Map)),
                <<"\n">>,
                <<"Local sessions:   ">>,
                integer_to_binary(maps:get(sessions, Map)),
                <<" / ">>,
                integer_to_binary(maps:get(max_clients, Map)),
                <<" (registered: ">>,
                integer_to_binary(maps:get(registered_users, Map)),
                <<", operators: ">>,
                integer_to_binary(maps:get(operators_online, Map)),
                <<")\n">>,
                <<"Channels:         ">>,
                integer_to_binary(maps:get(channels, Map)),
                <<" local, ">>,
                integer_to_binary(maps:get(remote_channels, Map)),
                <<" remote\n">>,
                <<"Network:          ">>,
                integer_to_binary(maps:get(known_servers, Map)),
                <<" remote servers, ">>,
                integer_to_binary(maps:get(remote_users, Map)),
                <<" remote users, ">>,
                integer_to_binary(maps:get(services, Map)),
                <<" services\n">>,
                <<"Accounts:         ">>,
                integer_to_binary(maps:get(accounts, Map)),
                <<"\n">>,
                <<"Database:         ">>,
                integer_to_binary(maps:get(db_disk_bytes, Map) div 1024),
                <<" KiB disk, ">>,
                integer_to_binary(maps:get(db_memory_bytes, Map) div 1024),
                <<" KiB RAM (">>,
                integer_to_binary(maps:get(db_tables, Map)),
                <<" tables)\n">>,
                <<"VM Memory / Pids: ">>,
                integer_to_binary(maps:get(memory_bytes, Map) div 1024),
                <<" KiB / ">>,
                integer_to_binary(maps:get(erlang_processes, Map)),
                <<" processes">>
            ]),
            briskd_ctl:reply_ok(Format, Map, Text)
    end.

-doc "Run the `check-config` control subcommand.".
-spec cmd_check_config([binary()], json | text) -> {ok, binary()} | {error, binary()}.
cmd_check_config(Rest, Format) ->
    Path =
        case Rest of
            [Given | _] ->
                binary_to_list(Given);
            [] ->
                case persistent_term:get({briskd_state, config_path}, undefined) of
                    undefined -> os:getenv("BRISKD_CONFIG", "config/briskd.json");
                    RunningPath -> RunningPath
                end
        end,
    PathBin =
        case unicode:characters_to_binary(Path) of
            Bin when is_binary(Bin) -> Bin;
            _ -> iolist_to_binary(Path)
        end,
    case briskd_config:load(Path) of
        {error, Reason} ->
            ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
            briskd_ctl:reply_error(
                Format,
                #{status => <<"invalid">>, path => PathBin, reason => ReasonBin},
                [<<"Configuration invalid (">>, PathBin, <<"): ">>, ReasonBin]
            );
        {ok, Config} ->
            case check_tls_pairs(maps:get(tls_options, Config, [])) of
                {ok, Certs} ->
                    briskd_ctl:reply_ok(
                        Format,
                        #{
                            status => <<"valid">>,
                            path => PathBin,
                            name => maps:get(name, Config),
                            certificates => Certs
                        },
                        [
                            <<"Configuration valid: ">>,
                            PathBin,
                            <<" (server: ">>,
                            maps:get(name, Config),
                            <<", certificates checked: ">>,
                            integer_to_binary(length(Certs)),
                            <<")">>
                        ]
                    );
                {error, CertReason} ->
                    ReasonBin = iolist_to_binary(io_lib:format("~p", [CertReason])),
                    briskd_ctl:reply_error(
                        Format,
                        #{status => <<"invalid_tls">>, path => PathBin, reason => ReasonBin},
                        [<<"TLS certificate check failed: ">>, ReasonBin]
                    )
            end
    end.

check_tls_pairs([]) ->
    {ok, []};
check_tls_pairs(Options) ->
    Main =
        case {proplists:get_value(certfile, Options), proplists:get_value(keyfile, Options)} of
            {Cert, Key} when is_list(Cert), is_list(Key) -> [{Cert, Key}];
            _ -> []
        end,
    Sni = [
        {proplists:get_value(certfile, SOpts), proplists:get_value(keyfile, SOpts)}
     || {_Host, SOpts} <- proplists:get_value(sni_hosts, Options, [])
    ],
    validate_pairs(Main ++ Sni, []).

validate_pairs([], Acc) ->
    {ok, lists:reverse(Acc)};
validate_pairs([{Cert, Key} | Rest], Acc) ->
    case briskd_certs:validate_pair(Cert, Key) of
        {ok, Info} ->
            validate_pairs(Rest, [Info#{certfile => unicode:characters_to_binary(Cert)} | Acc]);
        {error, Reason} ->
            {error, Reason}
    end.

-doc "Run the `reload-certs` control subcommand.".
-spec cmd_reload_certs(json | text) -> {ok, binary()} | {error, binary()}.
cmd_reload_certs(Format) ->
    case whereis(briskd_certs) of
        undefined ->
            briskd_ctl:reply_ok(
                Format,
                #{status => <<"disabled">>},
                <<"TLS certificate watcher is not active (no TLS listener configured)">>
            );
        _ ->
            case briskd_certs:check_now() of
                reloaded ->
                    briskd_ctl:reply_ok(
                        Format, #{status => <<"reloaded">>}, <<"TLS certificates reloaded">>
                    );
                unchanged ->
                    briskd_ctl:reply_ok(
                        Format,
                        #{status => <<"unchanged">>},
                        <<"TLS certificates unchanged">>
                    );
                {error, Reason} ->
                    ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
                    briskd_ctl:reply_error(
                        Format,
                        #{status => <<"error">>, reason => ReasonBin},
                        [<<"TLS certificate reload rejected: ">>, ReasonBin]
                    )
            end
    end.

-doc "Run the `search` control subcommand.".
-spec cmd_search(json | text) -> {ok, binary()} | {error, binary()}.
cmd_search(Format) ->
    Info = briskd_search:info(),
    Service = maps:get(service, Info, #{}),
    Text =
        case Info of
            #{status := not_configured} ->
                <<"Message search: not configured">>;
            _ ->
                iolist_to_binary(
                    io_lib:format(
                        "Message search: ~ts (~ts), ~b queued, ~b rebuilds~n"
                        "Service: ~ts",
                        [
                            maps:get(status, Info),
                            case maps:get(enabled, Info) of
                                true -> "on";
                                false -> "switched off"
                            end,
                            maps:get(queued, Info, 0),
                            maps:get(rebuilds, Info, 0),
                            case Service of
                                #{reachable := true, docs := Docs, bytes := Bytes} ->
                                    io_lib:format("~b messages, ~p bytes", [Docs, Bytes]);
                                #{error := Error} ->
                                    io_lib:format("unreachable (~ts)", [Error]);
                                _ ->
                                    "unknown"
                            end
                        ]
                    )
                )
        end,
    briskd_ctl:reply_ok(Format, Info, Text).

-doc "Run the `log-level` query subcommand.".
-spec cmd_get_log_level(json | text) -> {ok, binary()} | {error, binary()}.
cmd_get_log_level(Format) ->
    Config = briskd_config:current_or_empty(),
    Level = atom_to_binary(maps:get(level, Config, info)),
    briskd_ctl:reply_ok(Format, #{log_level => Level}, Level).

-doc "Run the `clients` control subcommand.".
-spec cmd_clients(json | text) -> {ok, binary()} | {error, binary()}.
cmd_clients(Format) ->
    Now = erlang:system_time(second),
    Entries = lists:sort([
        begin
            Modes = briskd_state_client:user_modes(Pid),
            Account =
                case briskd_state_v3:account(Pid) of
                    undefined -> null;
                    A -> A
                end,
            Idle =
                case mnesia:dirty_read(activity, Pid) of
                    [#activity{last = Last}] -> max(0, Now - Last);
                    [] -> 0
                end,
            Info = briskd_cap:info(Pid),
            #{
                nick => Nick,
                user =>
                    case User of
                        undefined -> <<"*">>;
                        _ -> User
                    end,
                host => Host,
                account => Account,
                registered => briskd_state_client:ready(Client),
                operator => maps:is_key($o, Modes),
                secure => maps:get(secure, Info, false),
                channels => length(Channels),
                idle_seconds => Idle
            }
        end
     || Pid <- briskd_state_client:pids(),
        [#client{nick = Nick, user = User, host = Host, channels = Channels} = Client] <- [
            mnesia:dirty_read(client, Pid)
        ]
    ]),
    Lines = [
        iolist_to_binary([
            maps:get(nick, E),
            <<"!">>,
            maps:get(user, E),
            <<"@">>,
            maps:get(host, E),
            <<" | account=">>,
            null_star(maps:get(account, E)),
            <<" | oper=">>,
            atom_to_binary(maps:get(operator, E)),
            <<" | tls=">>,
            atom_to_binary(maps:get(secure, E)),
            <<" | channels=">>,
            integer_to_binary(maps:get(channels, E)),
            <<" | idle=">>,
            integer_to_binary(maps:get(idle_seconds, E)),
            <<"s">>
        ])
     || E <- Entries
    ],
    Text =
        case Lines of
            [] -> <<"No local clients connected">>;
            _ -> binary:join(Lines, <<"\n">>)
        end,
    briskd_ctl:reply_ok(Format, #{count => length(Entries), clients => Entries}, Text).

-doc "Run the `channels` control subcommand.".
-spec cmd_channels(json | text) -> {ok, binary()} | {error, binary()}.
cmd_channels(Format) ->
    Entries = lists:sort([
        begin
            RemoteCount =
                case mnesia:dirty_read(remote_channel, Key) of
                    [#remote_channel{members = RM}] -> map_size(RM);
                    [] -> 0
                end,
            Modes = list_to_binary([
                $+
                | lists:sort([M || M <- maps:keys(Flags), is_integer(M)])
            ]),
            #{
                name => Name,
                local_members => map_size(Members),
                remote_members => RemoteCount,
                modes => Modes,
                topic => Topic,
                predefined => briskd_state:predefined_channel(Key),
                has_key => Password =/= undefined,
                limit =>
                    case Limit of
                        undefined -> null;
                        _ -> Limit
                    end,
                bans => maps:get(ban, Lists, []),
                exceptions => maps:get(exception, Lists, []),
                invites => maps:get(invite, Lists, [])
            }
        end
     || Key <- briskd_state:table_keys(channel),
        [
            #channel{
                name = Name,
                members = Members,
                flags = Flags,
                topic = Topic,
                password = Password,
                limit = Limit,
                lists = Lists
            }
        ] <- [
            mnesia:dirty_read(channel, Key)
        ]
    ]),
    Lines = [
        iolist_to_binary([
            maps:get(name, E),
            <<" (local=">>,
            integer_to_binary(maps:get(local_members, E)),
            <<", remote=">>,
            integer_to_binary(maps:get(remote_members, E)),
            <<", modes=">>,
            maps:get(modes, E),
            <<") :">>,
            maps:get(topic, E)
        ])
     || E <- Entries
    ],
    Text =
        case Lines of
            [] -> <<"No channels">>;
            _ -> binary:join(Lines, <<"\n">>)
        end,
    briskd_ctl:reply_ok(Format, #{count => length(Entries), channels => Entries}, Text).

-doc "Run the `links` control subcommand.".
-spec cmd_links(json | text) -> {ok, binary()} | {error, binary()}.
cmd_links(Format) ->
    Configured = [
        maps:without([password], Link)
     || Link <- persistent_term:get({briskd_state, server_links}, [])
    ],
    Known = [
        #{
            name => Name,
            hop => Hop,
            adjacent => Adjacent,
            parent => Parent,
            info => Info
        }
     || Key <- briskd_state:table_keys(known_server),
        [
            #known_server{
                name = Name, hop = Hop, adjacent = Adjacent, parent = Parent, info = Info
            }
        ] <- [mnesia:dirty_read(known_server, Key)]
    ],
    Lines = [
        iolist_to_binary([
            maps:get(name, S),
            <<" (hop=">>,
            integer_to_binary(maps:get(hop, S)),
            <<", via=">>,
            maps:get(adjacent, S),
            <<") :">>,
            maps:get(info, S)
        ])
     || S <- Known
    ],
    Text =
        case Lines of
            [] ->
                iolist_to_binary([
                    <<"No connected server links (configured peers: ">>,
                    integer_to_binary(length(Configured)),
                    <<")">>
                ]);
            _ ->
                binary:join(Lines, <<"\n">>)
        end,
    briskd_ctl:reply_ok(
        Format,
        #{configured => Configured, connected => Known, count => length(Known)},
        Text
    ).

-doc "Run the `connect` control subcommand.".
-spec cmd_connect(binary(), json | text) -> {ok, binary()} | {error, binary()}.
cmd_connect(Peer, Format) ->
    case briskd_state_net:configured_peer(Peer) of
        {ok, Name} ->
            _ = briskd_links:connect_peer(Name),
            briskd_ctl:reply_ok(
                Format,
                #{status => <<"connecting">>, peer => Name},
                <<"Triggered connection attempt for ", Name/binary>>
            );
        error ->
            briskd_ctl:reply_error(
                Format,
                #{error => <<"no_such_peer">>, peer => Peer},
                <<"No configured server link named ", Peer/binary>>
            )
    end.

-doc "Run the `accounts` control subcommand.".
-spec cmd_accounts(json | text) -> {ok, binary()} | {error, binary()}.
cmd_accounts(Format) ->
    Entries = lists:sort([
        #{
            name => Name,
            verified => Pending =:= undefined,
            email =>
                case Email of
                    undefined -> null;
                    _ -> Email
                end,
            certfps => length(Fps),
            certfp_list => Fps,
            created_us => Created
        }
     || #account{
            name = Name, email = Email, certfps = Fps, created = Created, pending = Pending
        } <-
            briskd_account:list_all()
    ]),
    Lines = [
        iolist_to_binary([
            maps:get(name, E),
            <<" | verified=">>,
            atom_to_binary(maps:get(verified, E)),
            <<" | email=">>,
            null_star(maps:get(email, E)),
            <<" | certfps=">>,
            integer_to_binary(maps:get(certfps, E))
        ])
     || E <- Entries
    ],
    Text =
        case Lines of
            [] -> <<"No registered accounts">>;
            _ -> binary:join(Lines, <<"\n">>)
        end,
    briskd_ctl:reply_ok(Format, #{count => length(Entries), accounts => Entries}, Text).

-doc "Run the `backup` control subcommand.".
-spec cmd_backup(binary(), json | text) -> {ok, binary()} | {error, binary()}.
cmd_backup(FileBin, Format) ->
    Path = binary_to_list(FileBin),
    ok = filelib:ensure_dir(Path),
    case mnesia:backup(Path) of
        ok ->
            logger:notice(#{event => ctl_backup, path => FileBin}),
            briskd_ctl:reply_ok(
                Format,
                #{status => <<"backed_up">>, path => FileBin},
                <<"Mnesia backup written to ", FileBin/binary>>
            );
        {error, Reason} ->
            ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
            briskd_ctl:reply_error(
                Format,
                #{error => <<"backup_failed">>, path => FileBin, reason => ReasonBin},
                [<<"Backup failed: ">>, ReasonBin]
            )
    end.

-doc "Run the `drain` control subcommand.".
-spec cmd_drain(binary(), json | text) -> {ok, binary()}.
cmd_drain(Reason, Format) ->
    ok = briskd_shutdown:drain(Reason),
    briskd_ctl:reply_ok(
        Format,
        #{status => <<"drained">>, reason => Reason},
        <<"Drained listeners, links, and client sessions">>
    ).

-doc "Run the `stop` control subcommand.".
-spec cmd_stop(binary(), json | text) -> {ok, binary()}.
cmd_stop(Reason, Format) ->
    ok = briskd_shutdown:drain(Reason),
    erlang:spawn(fun init:stop/0),
    briskd_ctl:reply_ok(
        Format,
        #{status => <<"stopping">>, reason => Reason},
        <<"Server drained and stopping">>
    ).

%%% Helpers

-spec mnesia_tables() -> [atom()].
mnesia_tables() ->
    case mnesia:system_info(tables) of
        Tables when is_list(Tables) -> [T || T <- Tables, is_atom(T)];
        _ -> []
    end.

-spec table_size(atom()) -> non_neg_integer().
table_size(Table) ->
    case mnesia:table_info(Table, size) of
        Size when is_integer(Size), Size >= 0 -> Size;
        _ -> 0
    end.

mnesia_disk_bytes() ->
    case mnesia:system_info(directory) of
        Dir when is_list(Dir) -> dir_bytes(Dir);
        _ -> 0
    end.

dir_bytes(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:foldl(
                fun(Name, Acc) ->
                    Path = filename:join(Dir, Name),
                    case filelib:is_regular(Path) of
                        true -> Acc + filelib:file_size(Path);
                        false -> Acc
                    end
                end,
                0,
                Files
            );
        {error, _} ->
            0
    end.

mnesia_memory_bytes() ->
    WordSize = erlang:system_info(wordsize),
    lists:foldl(
        fun(Table, Acc) ->
            try mnesia:table_info(Table, memory) of
                Words when is_integer(Words) -> Acc + Words * WordSize;
                _ -> Acc
            catch
                _:_ -> Acc
            end
        end,
        0,
        mnesia_tables()
    ).

active_listeners() ->
    case whereis(briskd_sup) of
        undefined ->
            [];
        _ ->
            lists:foldl(
                fun(Kind, Acc) ->
                    case lists:keyfind(Kind, 1, supervisor:which_children(briskd_sup)) of
                        {Kind, Pid, _, _} when is_pid(Pid) ->
                            Port =
                                case briskd_listener:port(Pid) of
                                    {ok, P} -> P;
                                    error -> 0
                                end,
                            [#{transport => atom_to_binary(Kind), port => Port} | Acc];
                        _ ->
                            Acc
                    end
                end,
                [],
                [wss, ws, tls, tcp]
            )
    end.

format_listeners_text([]) ->
    <<"none">>;
format_listeners_text(List) ->
    iolist_to_binary(
        lists:join(
            <<", ">>,
            [
                [maps:get(transport, L), <<":">>, integer_to_binary(maps:get(port, L))]
             || L <- List
            ]
        )
    ).

null_star(null) -> <<"*">>;
null_star(Bin) -> Bin.
