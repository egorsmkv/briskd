-module(ircd_log).
-export([apply_level/1, format/2]).

%% @doc Apply a configured log level to the primary filter and the default handler.
%% `trace` is stored in the config map and installed as OTP level `all`, which
%% passes every event, including `debug`.
-spec apply_level(trace | debug | info | notice | warning | error | critical | alert | emergency) ->
    ok.
apply_level(Level) ->
    LoggerLevel = logger_level(Level),
    ok = logger:set_primary_config(level, LoggerLevel),
    ok = logger:update_handler_config(default, level, LoggerLevel).

logger_level(trace) -> all;
logger_level(Level) -> Level.

%% @doc Format an OTP Logger event as one newline-terminated JSON object.
%% Flatlog renders the message field; invalid Unicode falls back to Erlang term text.
-spec format(map(), term()) -> iodata().
format(#{level := Level, meta := Meta} = Event, _) ->
    Line = flatlog:format(Event, #{template => [msg]}),
    Message =
        case unicode:characters_to_binary(Line) of
            Binary when is_binary(Binary) -> Binary;
            _ -> iolist_to_binary(io_lib:format("~tp", [Line]))
        end,
    [
        json:encode(#{
            level => Level,
            time => maps:get(time, Meta, 0),
            message => Message
        }),
        $\n
    ].
