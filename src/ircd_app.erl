-module(ircd_app).
-moduledoc """
Application callback module for `ircd`.

Startup, in order:

1. Load the configuration file named by `IRCD_CONFIG` (default
   `config/ircd.json`) with `ircd_config:load/1`. An invalid file stops the
   start with `{error, {invalid_config, Path, Reason}}`.
2. Install the configured `log_format` and `log_level` on the `logger` default
   handler (`m:ircd_log`).
3. Start Mnesia with its directory set to `mnesia_dir`, creating the disk
   schema on first start. If Mnesia is already running, it must already use
   that directory.
4. Start the supervision tree, `m:ircd_sup`.

On stop, `prep_stop/1` drains clients and links (`m:ircd_shutdown`), and
`stop/1` restores the previous logger settings and stops Mnesia if this
application started it. A failed start undoes the same steps.
""".
-behaviour(application).
-export([start/2, prep_stop/1, stop/1]).

-doc false.
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
                            ok = stop({Previous, Primary, StartedMnesia}),
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

-doc """
Drain clients and server links before the supervision tree stops.

Runs `ircd_shutdown:drain/1` with the reason `Server shutting down`. This is
the graceful-shutdown path for SIGTERM (`init:stop/0`), operator `DIE` and
`RESTART`, and `application:stop(ircd)`. A failure while draining is logged as
`shutdown_drain_failed` and does not block the stop. Returns `State`
unchanged.
""".
prep_stop(State) ->
    try
        ircd_shutdown:drain(<<"Server shutting down">>)
    catch
        Class:Reason ->
            logger:warning(#{event => shutdown_drain_failed, class => Class, reason => Reason})
    end,
    State.

-doc false.
stop({Previous, Primary, StartedMnesia}) ->
    ok = logger:set_primary_config(level, Primary),
    ok = logger:update_handler_config(default, Previous),
    _ =
        case StartedMnesia of
            true -> application:stop(mnesia);
            false -> ok
        end,
    ok.

start_mnesia(Dir) ->
    case application:which_applications() of
        Applications when is_list(Applications) ->
            case lists:keymember(mnesia, 1, Applications) of
                true ->
                    case filename:absname(mnesia_directory()) =:= filename:absname(Dir) of
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

%% mnesia:system_info(directory) returns term(); it is the directory name.
mnesia_directory() ->
    case mnesia:system_info(directory) of
        Dir when is_list(Dir) -> Dir
    end.
