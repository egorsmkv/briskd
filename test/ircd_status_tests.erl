-module(ircd_status_tests).
-include_lib("eunit/include/eunit.hrl").

session_status_redacts_link_password_test() ->
    State = {tcp, socket, <<"peer">>, <<"PASS secret\r">>, {server_pass, <<"secret">>}},
    #{state := Redacted} = ircd_session:format_status(#{state => State}),
    ?assertEqual({tcp, socket, <<"peer">>, <<>>, {server_pass, redacted}}, Redacted),
    Plain = {tcp, socket, <<"peer">>, <<"PRIVMSG #c :hello">>, client},
    #{state := PlainRedacted} = ircd_session:format_status(#{state => Plain}),
    ?assertEqual({tcp, socket, <<"peer">>, <<>>, client}, PlainRedacted).

link_status_redacts_peer_password_test() ->
    State = #{
        peer => #{name => <<"irc.example">>, password => <<"secret">>},
        peer_password => <<"secret">>,
        buffer => <<"PASS secret">>,
        config => #{
            name => <<"irc.local">>,
            server_links => [#{name => <<"irc.example">>, password => <<"secret">>}],
            operators => [{<<"admin">>, <<"opersecret">>}]
        }
    },
    #{state := Redacted} = ircd_link:format_status(#{state => State}),
    ?assertEqual(#{name => <<"irc.local">>}, maps:get(config, Redacted)),
    ?assertEqual(nomatch, binary:match(term_to_binary(Redacted), <<"secret">>)),
    ?assertEqual(#{name => <<"irc.example">>}, maps:get(peer, Redacted)),
    ?assertEqual(redacted, maps:get(peer_password, Redacted)).

state_status_redacts_pass_and_oper_test() ->
    Status = ircd_state:format_status(#{
        state => <<"irc.local">>,
        message =>
            {'$gen_call', from, {command, <<"OPER">>, [<<"admin">>, <<"secret">>], 20, []}},
        log => [{in, {command, <<"PASS">>, [<<"secret">>], 12, []}}]
    }),
    ?assertEqual(
        {'$gen_call', from, {command, <<"OPER">>, [<<"admin">>, redacted], 20, []}},
        maps:get(message, Status)
    ),
    ?assertEqual([{in, {command, <<"PASS">>, [redacted], 12, []}}], maps:get(log, Status)),
    ?assertEqual(<<"irc.local">>, maps:get(state, Status)).
