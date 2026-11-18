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
