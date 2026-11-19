-module(ircd_log_tests).
-include_lib("eunit/include/eunit.hrl").

command_detail_hides_secrets_and_message_text_test() ->
    ?assertEqual(<<"redacted">>, ircd_log:command_detail(<<"PASS">>, [<<"secret">>])),
    ?assertEqual(<<"admin">>, ircd_log:command_detail(<<"OPER">>, [<<"admin">>, <<"secret">>])),
    ?assertEqual(
        <<"#room">>,
        ircd_log:command_detail(<<"PRIVMSG">>, [<<"#room">>, <<"hello secret body">>])
    ),
    ?assertEqual(
        <<"#room">>,
        ircd_log:command_detail(<<"NOTICE">>, [<<"#room">>, <<"hello secret body">>])
    ),
    ?assertEqual(
        <<"#room +k">>,
        ircd_log:command_detail(<<"MODE">>, [<<"#room">>, <<"+k">>, <<"roomkey">>])
    ),
    ?assertEqual(
        <<"#room +o alice">>,
        ircd_log:command_detail(<<"MODE">>, [<<"#room">>, <<"+o">>, <<"alice">>])
    ),
    ?assertEqual(
        <<"#room bob">>, ircd_log:command_detail(<<"KICK">>, [<<"#room">>, <<"bob">>, <<"bye">>])
    ),
    ?assertEqual(<<>>, ircd_log:command_detail(<<"QUIT">>, [<<"leaving now">>])),
    ?assertEqual(<<>>, ircd_log:command_detail(<<"PING">>, [<<"token">>])).

client_command_skips_ping_test() ->
    ok = ircd_log:client_command(<<"alice">>, <<"PING">>, [<<"token">>]),
    ok = ircd_log:server_command(<<"peer.test">>, <<"PONG">>, [<<"peer.test">>]).

json_report_fields_test() ->
    Event = #{
        level => notice,
        meta => #{time => 42},
        msg => {report, #{event => started, name => <<"irc.test">>, sessions => 3}}
    },
    ?assertEqual(
        #{
            <<"level">> => <<"notice">>,
            <<"time">> => 42,
            <<"event">> => <<"started">>,
            <<"name">> => <<"irc.test">>,
            <<"sessions">> => 3
        },
        decode(Event)
    ).

json_default_report_cb_is_structured_test() ->
    Event = #{
        level => notice,
        meta => #{time => 1, report_cb => fun logger:format_otp_report/1},
        msg => {report, #{event => started}}
    },
    ?assertMatch(#{<<"event">> := <<"started">>}, decode(Event)).

json_reserved_fields_win_test() ->
    Event = #{level => info, meta => #{time => 7}, msg => {report, #{level => fake, time => 0}}},
    ?assertMatch(#{<<"level">> := <<"info">>, <<"time">> := 7}, decode(Event)).

json_odd_terms_test() ->
    Event = #{
        level => warning,
        meta => #{time => 1},
        msg =>
            {report, #{
                reason => {badarg, [1]},
                pid => self(),
                bytes => <<255, 0>>,
                text => "plain",
                list => [<<"a">>, 1],
                improper => [a | b]
            }}
    },
    Decoded = decode(Event),
    ?assertEqual(<<"{badarg,[1]}">>, maps:get(<<"reason">>, Decoded)),
    ?assertEqual(list_to_binary(pid_to_list(self())), maps:get(<<"pid">>, Decoded)),
    ?assertEqual(<<"<<255,0>>">>, maps:get(<<"bytes">>, Decoded)),
    ?assertEqual(<<"plain">>, maps:get(<<"text">>, Decoded)),
    ?assertEqual([<<"a">>, 1], maps:get(<<"list">>, Decoded)),
    ?assertEqual(<<"[a|b]">>, maps:get(<<"improper">>, Decoded)).

json_string_and_format_messages_test() ->
    ?assertMatch(
        #{<<"message">> := <<"hello">>, <<"level">> := <<"info">>},
        decode(#{level => info, meta => #{time => 1}, msg => {string, "hello"}})
    ),
    ?assertMatch(
        #{<<"message">> := <<"n=5">>},
        decode(#{level => info, meta => #{time => 1}, msg => {"n=~p", [5]}})
    ).

json_report_callback_uses_message_test() ->
    Event = #{
        level => info,
        meta => #{time => 1, report_cb => fun(_) -> {"custom ~p", [x]} end},
        msg => {report, #{a => 1}}
    },
    ?assertMatch(#{<<"message">> := <<"custom x">>}, decode(Event)).

text_formatter_single_line_test() ->
    {Module, Config} = ircd_log:formatter(<<"text">>),
    Line = iolist_to_binary(
        Module:format(
            #{level => info, meta => #{time => 0}, msg => {report, #{event => started}}},
            Config
        )
    ),
    ?assertMatch({_, _}, binary:match(Line, <<" info ">>)),
    ?assertMatch({_, _}, binary:match(Line, <<"event: started">>)),
    ?assertEqual(<<"\n">>, binary:part(Line, byte_size(Line), -1)).

decode(Event) ->
    {Module, Config} = ircd_log:formatter(<<"json">>),
    [Json, $\n] = Module:format(Event, Config),
    json:decode(iolist_to_binary(Json)).
