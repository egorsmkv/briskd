-module(briskd_rehash).
-moduledoc """
Versioned runtime configuration snapshots and `REHASH` reload lifecycle.

Publishes a coherent, generation-stamped `runtime_config()` snapshot in
`persistent_term` (`current/0`) instead of scattering independent configuration
updates across many `persistent_term` keys. Credentials remain behind
`m:briskd_oper` rather than inside the query snapshot.

Coordinates `REHASH` (RFC 2812 section 4.2), `briskdctl rehash`, and admin
override updates (`apply_effective/4`): validates static settings, updates
the effective configuration, refreshes `m:briskd_motd`, seeds newly configured
channels, reconciles population channel counts, triggers asynchronous TLS
certificate checks, notifies `cap-notify` and `draft/extended-isupport`
clients, updates `logger`, and broadcasts `WALLOPS`.
""".

-export([
    init/1,
    current/0,
    generation/0,
    rehash/2,
    rehash_server/1,
    apply_effective/4,
    path_text/1
]).

-include("briskd_state.hrl").

-define(RUNTIME_KEY, {?MODULE, runtime}).

-doc "Coherent versioned runtime configuration snapshot for read-only queries.".
-type runtime_config() :: #{
    generation := non_neg_integer(),
    server_name := binary(),
    server_info := binary(),
    admin := map(),
    motd := briskd_motd:snapshot(),
    limits := #{
        max_clients := pos_integer(),
        max_sendq := pos_integer(),
        reop_delay := pos_integer(),
        nicklen := pos_integer(),
        history_limit := pos_integer(),
        monitor_limit := pos_integer(),
        resource_delay := non_neg_integer(),
        max_empty_channels := pos_integer(),
        empty_channel_ttl := non_neg_integer()
    },
    flood := briskd_config:flood(),
    capabilities := #{
        utf8_only := boolean(),
        chathistory := boolean(),
        multiclient := boolean(),
        account_rejoin := boolean(),
        account_registration := boolean()
    }
}.
-export_type([runtime_config/0]).

-doc """
Initialize generation `0` of the runtime configuration snapshot and load the
initial MOTD snapshot at server startup.
""".
-spec init(briskd_config:config()) -> ok.
init(Config) ->
    Motd = briskd_motd:reload(maps:get(motd_file, Config, null)),
    ok = briskd_oper:store_accounts(Config),
    Snapshot = build_runtime(0, Config, Motd),
    persistent_term:put(?RUNTIME_KEY, Snapshot).

-doc "Return the current coherent runtime configuration snapshot.".
-spec current() -> runtime_config().
current() ->
    case persistent_term:get(?RUNTIME_KEY, undefined) of
        #{generation := _} = Snapshot ->
            Snapshot;
        _ ->
            build_runtime(0, briskd_config:current_or_empty(), briskd_motd:current())
    end.

-doc "Return the current configuration generation number.".
-spec generation() -> non_neg_integer().
generation() ->
    maps:get(generation, current()).

-doc """
Handle `REHASH` (RFC 2812 section 4.2): reload the JSON configuration file.
""".
-spec rehash(#client{}, binary()) -> ok.
rehash(#client{pid = Pid} = Client, Server) ->
    case briskd_oper:is_operator(Pid) of
        false ->
            briskd_state_send:numeric(
                Client,
                Server,
                <<"481">>,
                [],
                <<"Permission Denied- You're not an IRC operator">>
            );
        true ->
            Path = persistent_term:get({briskd_state, config_path}),
            case briskd_config:load(Path) of
                {ok, NewConfig} ->
                    rehash_config(NewConfig, Path, Client, Server);
                {error, Reason} ->
                    logger:warning(#{
                        event => rehash_failed, nick => Client#client.nick, reason => Reason
                    }),
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"400">>,
                        [<<"REHASH">>],
                        <<"Configuration reload failed">>
                    )
            end
    end.

rehash_config(NewConfig, Path, Client, Server) ->
    case static_unchanged(NewConfig) of
        false ->
            briskd_state_send:numeric(
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
            reload(
                NewConfig,
                #{event => oper_rehash, nick => Client#client.nick, result => accepted},
                [<<"Oper ">>, Client#client.nick, <<" rehashed the configuration">>],
                Server
            ),
            briskd_state_send:numeric(
                Client, Server, <<"382">>, [path_text(Path)], <<"Rehashing">>
            )
    end.

-doc """
Reload the configuration file from `m:briskd_ctl` without a client session.
""".
-spec rehash_server(binary()) -> {ok, binary()} | {error, term()}.
rehash_server(Server) ->
    Path = persistent_term:get({briskd_state, config_path}),
    case briskd_config:load(Path) of
        {error, Reason} ->
            logger:warning(#{event => rehash_failed, actor => <<"briskdctl">>, reason => Reason}),
            {error, Reason};
        {ok, NewConfig} ->
            case static_unchanged(NewConfig) of
                false ->
                    logger:warning(#{
                        event => ctl_rehash, result => restart_required
                    }),
                    {error, restart_required};
                true ->
                    reload(
                        NewConfig,
                        #{event => ctl_rehash, result => accepted},
                        [<<"briskdctl rehashed the configuration">>],
                        Server
                    ),
                    {ok, path_text(Path)}
            end
    end.

-doc """
Apply the effective configuration `NewConfig`, update subsystem snapshots,
notify clients about capability and ISUPPORT changes, log `Audit`, and send
`Wallops`.
""".
-spec apply_effective(briskd_config:config(), map(), iodata(), binary()) -> ok.
apply_effective(NewConfig, Audit, Wallops, Server) ->
    Clients =
        case ets:whereis(briskd_caps) of
            undefined -> [];
            _ -> [Pid || {Pid, _} <- ets:tab2list(briskd_caps), is_pid(Pid)]
        end,
    Advertised = #{Pid => briskd_cap:advertised(Pid) || Pid <- Clients},
    Tokens = briskd_isupport:tokens(),
    %% Logged before the new log level takes effect, so the audit event is not
    %% lost when the reload lowers the level.
    logger:notice(Audit),
    apply_rehash(NewConfig),
    %% Certificate paths are static, their contents are not: reload renewed
    %% certificates now instead of at the next interval.
    ok = briskd_certs:check_async(),
    briskd_state_net:notify_cap_changes(Advertised, Server),
    notify_isupport_changes(Tokens, briskd_isupport:tokens(), Clients, Server),
    briskd_oper:server_wallops(Wallops, Server).

-doc """
Format a configuration path as text for replies (`382 RPL_REHASHING`).
""".
-spec path_text(file:filename_all()) -> binary().
path_text(Path) ->
    case unicode:characters_to_binary(Path) of
        Bin when is_binary(Bin) -> Bin;
        _ -> iolist_to_binary(io_lib:format("~tp", [Path]))
    end.

%% Settings that need a restart: listeners, the database, and links.
static_unchanged(NewConfig) ->
    StaticKeys = [
        name, ip, tcp, tls, ws, wss, tls_options, mnesia_dir, client_password, server_links
    ],
    maps:with(StaticKeys, briskd_config:current()) =:=
        maps:with(StaticKeys, NewConfig).

reload(NewConfig, Audit, Wallops, Server) ->
    briskd_config:store_base(NewConfig),
    apply_effective(
        briskd_overrides:apply(NewConfig, briskd_overrides:all()), Audit, Wallops, Server
    ).

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
                briskd_cap:enabled(Pid, <<"draft/extended-isupport">>) andalso
                    mnesia:dirty_read(client, Pid)
            of
                [#client{} = Client] ->
                    case briskd_state_client:ready(Client) of
                        true -> briskd_isupport:send_tokens(Client, Server, Changed, true);
                        false -> ok
                    end;
                _ ->
                    ok
            end
        end,
        Clients
    ).

apply_rehash(Config) ->
    briskd_config:store(Config),
    briskd_state:store_accounts(Config),
    Motd = briskd_motd:reload(maps:get(motd_file, Config, null)),
    briskd_state:seed_channels(),
    briskd_population:reconcile_channels(),
    NextGen = generation() + 1,
    persistent_term:put(?RUNTIME_KEY, build_runtime(NextGen, Config, Motd)),
    persistent_term:put({briskd_state, motd_file}, maps:get(motd_file, Config)),
    persistent_term:put({briskd_state, admin}, maps:get(admin, Config)),
    persistent_term:put({briskd_state, reop_delay}, maps:get(reop_delay, Config)),
    persistent_term:put({briskd_state, server_links}, maps:get(server_links, Config)),
    persistent_term:put({briskd_sessions, max_clients}, maps:get(max_clients, Config)),
    Formatter = briskd_log:formatter(maps:get(log_format, Config)),
    ok = logger:update_handler_config(default, formatter, Formatter),
    ok = briskd_log:apply_level(maps:get(level, Config)).

build_runtime(Generation, Config, Motd) ->
    #{
        generation => Generation,
        server_name => maps:get(name, Config, <<"irc.local">>),
        server_info => maps:get(server_info, Config, <<"Erlang/OTP IRC server">>),
        admin => maps:get(admin, Config, #{}),
        motd => Motd,
        limits => #{
            max_clients => maps:get(max_clients, Config, 10000),
            max_sendq => maps:get(max_sendq, Config, 10000),
            reop_delay => maps:get(reop_delay, Config, 30),
            nicklen => maps:get(nicklen, Config, 9),
            history_limit => maps:get(history_limit, Config, 100),
            monitor_limit => maps:get(monitor_limit, Config, 100),
            resource_delay => maps:get(resource_delay, Config, 60),
            max_empty_channels => maps:get(max_empty_channels, Config, 1000),
            empty_channel_ttl => maps:get(empty_channel_ttl, Config, 86400)
        },
        flood => maps:get(flood, Config, null),
        capabilities => #{
            utf8_only => maps:get(utf8_only, Config, false),
            chathistory => maps:get(chathistory, Config, true),
            multiclient => maps:get(multiclient, Config, false),
            account_rejoin => maps:get(account_rejoin, Config, false),
            account_registration => maps:get(account_registration, Config, true)
        }
    }.
