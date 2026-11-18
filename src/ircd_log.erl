-module(ircd_log).
-export([apply_level/1, client_command/3, command_detail/2, format/2, server_command/3]).

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

%% @doc Log one accepted client command without message text, passwords, or keys.
%% `PING` and `PONG` are omitted. Visible when `log_level` is `debug` or `trace`.
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

%% @doc Log one peer command the same way as a client command.
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

%% @doc Safe command summary. The trailing message, a password, and a channel key are dropped.
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
