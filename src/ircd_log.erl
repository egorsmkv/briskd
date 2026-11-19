-module(ircd_log).
-moduledoc """
Logging setup, safe command summaries, and the JSON log formatter.

`m:ircd_app` calls `formatter/1` and `apply_level/1` at startup to install the
configured `log_format` and `log_level` on the OTP `logger` default handler,
and `REHASH` applies them again. Both the primary level and the default
handler level are set, because the primary level otherwise drops `info` and
`debug` events.

`client_command/3` and `server_command/3` write one `debug` event per accepted
client or peer command. They never log message text, passwords, or channel
keys (`command_detail/2`), and skip `PING` and `PONG`.

`format/2` is a `logger` formatter that writes one JSON object per line.
""".
-export([
    apply_level/1, client_command/3, command_detail/2, format/2, formatter/1, server_command/3
]).

-doc """
Apply a configured log level to the primary `logger` level and the default handler.

`Level` is the atom from `ircd_config:load/1`. `trace` is installed as the OTP
level `all`, which passes every event, including `debug`; the other values are
OTP levels and are installed as they are.
""".
-spec apply_level(trace | debug | info | notice | warning | error | critical | alert | emergency) ->
    ok.
apply_level(Level) ->
    LoggerLevel = logger_level(Level),
    ok = logger:set_primary_config(level, LoggerLevel),
    ok = logger:update_handler_config(default, level, LoggerLevel).

logger_level(trace) -> all;
logger_level(Level) -> Level.

-doc """
Log one accepted client command as a `debug` event.

The event has `event => client_command`, the sender's `nick`, the `command`,
and a `detail` from `command_detail/2`, so message text, passwords, and
channel keys are not logged. `PING` and `PONG` are not logged at all. The
event is visible when `log_level` is `debug` or `trace`.
""".
-spec client_command(binary(), binary(), [binary()]) -> ok.
client_command(_Nick, <<"PING">>, _Params) ->
    ok;
client_command(_Nick, <<"PONG">>, _Params) ->
    ok;
client_command(Nick, Command, Params) ->
    logger:debug(#{
        event => client_command,
        nick => Nick,
        command => Command,
        detail => command_detail(Command, Params)
    }).

-doc """
Log one command received from a server link as a `debug` event.

Same as `client_command/3`, with `event => server_command` and the link's
`peer` name instead of a nickname.
""".
-spec server_command(binary(), binary(), [binary()]) -> ok.
server_command(_Peer, <<"PING">>, _Params) ->
    ok;
server_command(_Peer, <<"PONG">>, _Params) ->
    ok;
server_command(Peer, Command, Params) ->
    logger:debug(#{
        event => server_command,
        peer => Peer,
        command => Command,
        detail => command_detail(Command, Params)
    }).

-doc """
Summarize a command's parameters for logging without secrets or message text.

Returns:

- `<<"redacted">>` for `PASS`, and only the account name for `OPER`.
- For `MODE`, the parameters joined with spaces, or only the target and mode
  string when the mode string contains `k` or `K`, so a channel key is
  dropped.
- For `KICK` and `INVITE`, the channel and nickname; the reason is dropped.
- For `PRIVMSG`, `NOTICE`, `TAGMSG`, `SQUERY`, `TOPIC`, `NICK`, `USER`, `JOIN`,
  `PART`, `LIST`, `NAMES`, and `KILL`, only the first parameter (the target).
- For `WHO`, `WHOIS`, `WHOWAS`, `ISON`, `USERHOST`, and `CAP`, all parameters
  joined with spaces.
- `<<>>` for any other command, including `QUIT` and `AWAY`.
""".
-spec command_detail(binary(), [binary()]) -> binary().
command_detail(<<"PASS">>, _) ->
    <<"redacted">>;
command_detail(<<"OPER">>, [Name | _]) ->
    Name;
command_detail(<<"OPER">>, _) ->
    <<>>;
command_detail(<<"MODE">>, [Target, Modes | Args]) when is_binary(Modes) ->
    case binary:match(Modes, [<<"k">>, <<"K">>]) of
        nomatch -> join_params([Target, Modes | Args]);
        _ -> join_params([Target, Modes])
    end;
command_detail(<<"KICK">>, [Channel, Nick | _]) ->
    join_params([Channel, Nick]);
command_detail(<<"INVITE">>, [Nick, Channel | _]) ->
    join_params([Nick, Channel]);
command_detail(Command, [Target | _]) when
    Command =:= <<"PRIVMSG">>;
    Command =:= <<"NOTICE">>;
    Command =:= <<"TAGMSG">>;
    Command =:= <<"SQUERY">>;
    Command =:= <<"TOPIC">>;
    Command =:= <<"NICK">>;
    Command =:= <<"USER">>;
    Command =:= <<"JOIN">>;
    Command =:= <<"PART">>;
    Command =:= <<"LIST">>;
    Command =:= <<"NAMES">>;
    Command =:= <<"KILL">>;
    Command =:= <<"KICK">>;
    Command =:= <<"INVITE">>
->
    Target;
command_detail(<<"KICK">>, _) ->
    <<>>;
command_detail(<<"QUIT">>, _) ->
    <<>>;
command_detail(<<"AWAY">>, _) ->
    <<>>;
command_detail(Command, Params) when
    Command =:= <<"WHO">>;
    Command =:= <<"WHOIS">>;
    Command =:= <<"WHOWAS">>;
    Command =:= <<"ISON">>;
    Command =:= <<"USERHOST">>;
    Command =:= <<"CAP">>
->
    join_params(Params);
command_detail(_, _) ->
    <<>>.

join_params(Params) ->
    iolist_to_binary(lists:join(<<" ">>, [Param || Param <- Params, is_binary(Param)])).

-doc """
Return the `logger` handler formatter for a configured `log_format`.

`<<"json">>` selects `format/2` of this module. `<<"text">>` selects OTP's
`logger_formatter` with a single-line `time level msg` template. The value is
used as the default handler's `formatter` setting.
""".
-spec formatter(binary()) -> {module(), map()}.
formatter(<<"json">>) ->
    {?MODULE, #{}};
formatter(<<"text">>) ->
    {logger_formatter, #{template => [time, " ", level, " ", msg, "\n"], single_line => true}}.

-doc """
Format a `logger` event as one newline-terminated JSON object.

This is a `logger` formatter callback, selected with `log_format` `json`
(see `formatter/1`); the formatter configuration is ignored. A map report
without its own report callback, such as the `logger:info(#{event => ...})`
events this server logs, becomes top-level fields next to `level` and `time`
(`logger` time, microseconds since the epoch); `level` and `time` win over
report keys of the same name. Any other event, such as a string, a format
call, or an OTP report with its own callback, is rendered by `logger_formatter`
into a `message` field. Terms JSON cannot hold (pids, tuples, references,
invalid UTF-8) are written as Erlang term text.

For example, `logger:notice(#{event => started, name => <<"irc.local">>})`
is written as a line like
`{"name":"irc.local","time":1763550000000000,"level":"notice","event":"started"}`
(key order is not significant).
""".
-spec format(logger:log_event(), logger:formatter_config()) -> iolist().
format(#{level := Level, meta := Meta, msg := Msg} = Event, _) ->
    Base = #{level => Level, time => maps:get(time, Meta, 0)},
    Fields =
        case Msg of
            {report, Report} when is_map(Report) ->
                structured(Report, maps:get(report_cb, Meta, none), Event);
            _ ->
                #{message => message(Event)}
        end,
    [json:encode(maps:merge(Fields, Base)), $\n].

%% logger_h_common adds `fun logger:format_otp_report/1` to every report that
%% has no callback of its own, so that default also means "plain report".
structured(Report, Callback, Event) ->
    case Callback =:= none orelse Callback =:= fun logger:format_otp_report/1 of
        true ->
            maps:fold(fun(Key, Value, Acc) -> Acc#{key(Key) => value(Value)} end, #{}, Report);
        false ->
            #{message => message(Event)}
    end.

%% logger_formatter raises on some invalid character data (a lone UTF-16
%% surrogate, for example); the raw message is then logged as term text.
message(#{msg := Msg} = Event) ->
    try logger_formatter:format(Event, #{template => [msg], single_line => true}) of
        Text ->
            case unicode:characters_to_binary(Text) of
                Binary when is_binary(Binary) -> Binary;
                _ -> term_text(Text)
            end
    catch
        error:_ -> term_text(Msg)
    end.

key(Key) when is_atom(Key) -> Key;
key(Key) when is_binary(Key) -> value(Key);
key(Key) -> term_text(Key).

value(Value) when is_binary(Value) ->
    case unicode:characters_to_binary(Value) of
        Value -> Value;
        _ -> term_text(Value)
    end;
value(Value) when is_atom(Value); is_integer(Value); is_float(Value) ->
    Value;
value(Value) when is_map(Value) ->
    maps:fold(fun(Key, Item, Acc) -> Acc#{key(Key) => value(Item)} end, #{}, Value);
value(Value) when is_list(Value) ->
    case io_lib:printable_unicode_list(Value) of
        true -> unicode:characters_to_binary(Value);
        false -> list_value(Value)
    end;
value(Value) ->
    term_text(Value).

%% A proper list of JSON values stays an array; anything else is term text.
list_value(Value) ->
    try
        [value(Item) || Item <- Value]
    catch
        error:_ -> term_text(Value)
    end.

term_text(Term) ->
    unicode:characters_to_binary(io_lib:format("~0tp", [Term])).
