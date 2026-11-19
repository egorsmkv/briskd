-module(ircd_app).
-behaviour(application).
-export([start/2, prep_stop/1, stop/1]).

%% @doc Load JSON configuration, configure logging, and start the supervision tree.
start(_, _) ->
    Path = os:getenv("IRCD_CONFIG", "config/ircd.json"),
    case ircd_config:load(Path) of
        {ok, Config} ->
            #{level := Primary} = logger:get_primary_config(),
            {ok, Previous} = logger:get_handler_config(default),
            Formatter = ircd_log:formatter(maps:get(log_format, Config)),
            ok = logger:update_handler_config(default, formatter, Formatter),
            ok = ircd_log:apply_level(maps:get(level, Config)),
            case start_mnesia(maps:get(mnesia_dir, Config)) of
                {ok, StartedMnesia} ->
                    case ircd_sup:start_link(Config) of
                        {ok, Pid} ->
                            logger:notice(#{
                                event => started,
                                name => maps:get(name, Config),
                                log_level => maps:get(level, Config)
                            }),
                            {ok, Pid, {Previous, Primary, StartedMnesia}};
                        Error ->
                            stop({Previous, Primary, StartedMnesia}),
                            Error
                    end;
                {error, Reason} ->
                    ok = logger:set_primary_config(level, Primary),
                    ok = logger:update_handler_config(default, Previous),
                    {error, Reason}
            end;
        Error ->
            Error
    end.

%% @doc Drain clients and peers before the supervision tree stops (graceful
%% shutdown on SIGTERM, DIE, RESTART, or application:stop/1).
prep_stop(State) ->
    try
        ircd_shutdown:drain(<<"Server shutting down">>)
    catch
        Class:Reason ->
            logger:warning(#{event => shutdown_drain_failed, class => Class, reason => Reason})
    end,
    State.

%% @doc Restore the logger level and formatter from before startup.
stop({Previous, Primary, StartedMnesia}) ->
    ok = logger:set_primary_config(level, Primary),
    ok = logger:update_handler_config(default, Previous),
    case StartedMnesia of
        true -> application:stop(mnesia);
        false -> ok
    end.

start_mnesia(Dir) ->
    case application:which_applications() of
        Applications when is_list(Applications) ->
            case lists:keymember(mnesia, 1, Applications) of
                true ->
                    case
                        filename:absname(mnesia:system_info(directory)) =:= filename:absname(Dir)
                    of
                        true -> {ok, false};
                        false -> {error, {mnesia_already_running, mnesia:system_info(directory)}}
                    end;
                false ->
                    ok = application:set_env(mnesia, dir, Dir),
                    ok = filelib:ensure_dir(filename:join(Dir, "schema.DAT")),
                    case ensure_mnesia_schema(Dir) of
                        ok ->
                            case application:ensure_all_started(mnesia) of
                                {ok, Started} -> {ok, lists:member(mnesia, Started)};
                                {error, StartReason} -> {error, {mnesia_start, StartReason}}
                            end;
                        {error, SchemaReason} ->
                            {error, {mnesia_schema, SchemaReason}}
                    end
            end
    end.

ensure_mnesia_schema(Dir) ->
    case filelib:is_file(filename:join(Dir, "schema.DAT")) of
        true -> ok;
        false -> mnesia:create_schema([node()])
    end.
