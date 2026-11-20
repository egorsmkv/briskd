-module(ircd_bot_tests).
-include_lib("eunit/include/eunit.hrl").

%%% Pure helpers (ircd_bot_ai)

addressed_test() ->
    ?assertEqual(
        {true, <<"what is IRC?">>}, ircd_bot_ai:addressed(<<"helper">>, <<"helper: what is IRC?">>)
    ),
    ?assertEqual({true, <<"hi">>}, ircd_bot_ai:addressed(<<"helper">>, <<"Helper, hi">>)),
    %% RFC 1459 case mapping: [ and { are the same character.
    ?assertEqual({true, <<"x">>}, ircd_bot_ai:addressed(<<"bot[1]">>, <<"BOT{1}: x">>)),
    ?assertEqual(
        {true, <<"ask @helper about it">>},
        ircd_bot_ai:addressed(<<"helper">>, <<"ask @helper about it">>)
    ),
    ?assertEqual(false, ircd_bot_ai:addressed(<<"helper">>, <<"helpers: no">>)),
    ?assertEqual(false, ircd_bot_ai:addressed(<<"helper">>, <<"mail me@helperx.org">>)),
    ?assertEqual(false, ircd_bot_ai:addressed(<<"helper">>, <<"the helper is here">>)).

clean_input_test() ->
    ?assertEqual(<<"bold text">>, ircd_bot_ai:clean_input(<<"\x02bold\x02 text\r\n">>)),
    ?assertEqual(2000, byte_size(ircd_bot_ai:clean_input(binary:copy(<<"a">>, 5000)))),
    %% Invalid UTF-8 is replaced instead of being forwarded.
    Clean = ircd_bot_ai:clean_input(<<"ok ", 16#FF, " end">>),
    ?assert(is_binary(unicode:characters_to_binary(Clean))).

build_request_test() ->
    Body = ircd_bot_ai:build_request(
        #{model => <<"m1">>, max_tokens => 100, temperature => 0.5},
        <<"Be brief.">>,
        <<"ctx">>,
        [{user, <<"alice: hi">>}, {assistant, <<"hello">>}],
        <<"alice: and now?">>
    ),
    #{<<"model">> := <<"m1">>, <<"messages">> := Messages, <<"max_tokens">> := 100} =
        json:decode(Body),
    ?assertEqual(
        [<<"system">>, <<"system">>, <<"user">>, <<"assistant">>, <<"user">>],
        [maps:get(<<"role">>, M) || M <- Messages]
    ),
    ?assertEqual(<<"alice: and now?">>, maps:get(<<"content">>, lists:last(Messages))),
    %% An empty system prompt is omitted.
    Bare = json:decode(
        ircd_bot_ai:build_request(
            #{model => <<"m">>, max_tokens => 1, temperature => 0.0}, <<>>, <<"c">>, [], <<"q">>
        )
    ),
    ?assertEqual(2, length(maps:get(<<"messages">>, Bare))).

parse_reply_test() ->
    Ok = <<"{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\" Hi! \"}}]}">>,
    ?assertEqual({ok, <<"Hi!">>}, ircd_bot_ai:parse_reply(Ok)),
    ?assertEqual(
        {error, {provider_error, <<"bad key">>}},
        ircd_bot_ai:parse_reply(<<"{\"error\":{\"message\":\"bad key\"}}">>)
    ),
    ?assertEqual(
        {error, empty_reply},
        ircd_bot_ai:parse_reply(<<"{\"choices\":[{\"message\":{\"content\":\"  \"}}]}">>)
    ),
    ?assertEqual({error, invalid_json}, ircd_bot_ai:parse_reply(<<"not json">>)),
    ?assertEqual({error, unexpected_response}, ircd_bot_ai:parse_reply(<<"{}">>)).

reply_lines_test() ->
    ?assertEqual([<<"one">>, <<"two">>], ircd_bot_ai:reply_lines(<<"one\n\n two \r\n">>, 100, 5)),
    %% Long lines wrap at a space, and each chunk fits the budget.
    Long = iolist_to_binary(lists:join(<<" ">>, lists:duplicate(60, <<"word">>))),
    Lines = ircd_bot_ai:reply_lines(Long, 80, 10),
    ?assert(length(Lines) > 1),
    ?assert(lists:all(fun(L) -> byte_size(L) =< 80 end, Lines)),
    ?assertEqual(Long, iolist_to_binary(lists:join(<<" ">>, Lines))),
    %% Truncated replies end with a marker.
    Many = ircd_bot_ai:reply_lines(<<"a\nb\nc\nd">>, 80, 2),
    ?assertEqual(2, length(Many)),
    ?assertMatch(<<"b", _/binary>>, lists:last(Many)),
    ?assertNotEqual(nomatch, binary:match(lists:last(Many), <<"[…]"/utf8>>)),
    %% Multi-byte characters are never split.
    Cyrillic = binary:copy(<<"ж"/utf8>>, 100),
    Parts = ircd_bot_ai:reply_lines(Cyrillic, 51, 10),
    ?assert(lists:all(fun(P) -> is_binary(unicode:characters_to_binary(P)) end, Parts)),
    ?assertEqual(Cyrillic, iolist_to_binary(Parts)),
    %% Control characters are removed from model output.
    ?assertEqual([<<"ab">>], ircd_bot_ai:reply_lines(<<"a\x01\x00b">>, 80, 2)).

text_budget_test() ->
    Budget = ircd_bot_ai:text_budget(<<"helper">>, <<"bot">>, <<"irc.test">>, <<"#lobby">>),
    Line = iolist_to_binary([
        <<":helper!bot@irc.test PRIVMSG #lobby :">>, binary:copy(<<"x">>, Budget), <<"\r\n">>
    ]),
    ?assert(byte_size(Line) =< 512).

%%% Configuration

config_test() ->
    Prompt = tmp_path("prompt.txt"),
    ok = file:write_file(Prompt, <<"You are terse.\n">>),
    os:putenv("IRCD_BOT_TEST_KEY", "sk-test"),
    {ok, Config} = load([
        <<"\"ai_providers\":{\"p\":{\"base_url\":\"https://api.example.com/v1/\",">>,
        <<"\"api_key_env\":\"IRCD_BOT_TEST_KEY\",\"model\":\"gpt-x\",\"timeout\":30}},">>,
        <<"\"bots\":[{\"nick\":\"helper\",\"provider\":\"p\",\"channels\":[\"#a\",\"&b\"],">>,
        <<"\"system_prompt_file\":\"">>,
        list_to_binary(Prompt),
        <<"\",\"temperature\":1}]">>
    ]),
    [Bot] = maps:get(bots, Config),
    ?assertMatch(
        #{
            nick := <<"helper">>,
            user := <<"bot">>,
            model := <<"gpt-x">>,
            channels := [<<"#a">>, <<"&b">>],
            respond_to := mention,
            context := conversation,
            direct_messages := true,
            history_lines := 20,
            temperature := 1.0,
            system_prompt := <<"You are terse.">>
        },
        Bot
    ),
    #{provider := Provider} = Bot,
    ?assertEqual(<<"https://api.example.com/v1">>, maps:get(base_url, Provider)),
    ?assertEqual(<<"sk-test">>, maps:get(api_key, Provider)),
    ?assertEqual(30000, maps:get(timeout, Provider)),
    {ok, Defaults} = load([]),
    ?assertEqual([], maps:get(bots, Defaults)).

config_errors_test() ->
    Provider =
        <<"\"ai_providers\":{\"p\":{\"base_url\":\"http://127.0.0.1:1/v1\",\"model\":\"m\"}},">>,
    Bot = fun(Fields) ->
        [Provider, <<"\"bots\":[{\"nick\":\"helper\",\"provider\":\"p\"">>, Fields, <<"}]">>]
    end,
    ?assertMatch({ok, _}, load(Bot(<<>>))),
    ?assertMatch(
        {error, {invalid_config, _, {unknown_ai_provider, _, <<"nope">>}}},
        load([Provider, <<"\"bots\":[{\"nick\":\"helper\",\"provider\":\"nope\"}]">>])
    ),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_bot_nick, _}}},
        load([Provider, <<"\"bots\":[{\"nick\":\"1bad\",\"provider\":\"p\"}]">>])
    ),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_bot_channel, _, _}}},
        load(Bot(<<",\"channels\":[\"lobby\"]">>))
    ),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_bot, _, respond_to, _}}},
        load(Bot(<<",\"respond_to\":\"always\"">>))
    ),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_bot, _, temperature, _}}},
        load(Bot(<<",\"temperature\":3">>))
    ),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_bot, _, history_lines, 101}}},
        load(Bot(<<",\"history_lines\":101">>))
    ),
    ?assertMatch({ok, _}, load(Bot(<<",\"history_lines\":0,\"max_reply_lines\":30">>))),
    ?assertMatch(
        {error, {invalid_config, _, duplicate_bot_nick}},
        load([
            Provider,
            <<"\"bots\":[{\"nick\":\"helper\",\"provider\":\"p\"},{\"nick\":\"HELPER\",\"provider\":\"p\"}]">>
        ])
    ),
    os:unsetenv("IRCD_BOT_MISSING_KEY"),
    Missing = load([
        <<"\"ai_providers\":{\"p\":{\"base_url\":\"https://x/v1\",\"model\":\"m\",">>,
        <<"\"api_key_env\":\"IRCD_BOT_MISSING_KEY\"}}">>
    ]),
    ?assertMatch({error, {invalid_config, _, {missing_api_key_env, _, _}}}, Missing),
    %% A rejected key is never echoed back in the error.
    BadKey = load([
        <<"\"ai_providers\":{\"p\":{\"base_url\":\"https://x/v1\",\"model\":\"m\",">>,
        <<"\"api_key\":\"secret with space\"}}">>
    ]),
    ?assertMatch({error, {invalid_config, _, {invalid_ai_provider, <<"p">>, api_key}}}, BadKey),
    ?assertEqual(nomatch, binary:match(term_to_binary(BadKey), <<"secret with space">>)),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_webui_url, _}}},
        load([<<"\"ai_providers\":{\"p\":{\"base_url\":\"ftp://x\",\"model\":\"m\"}}">>])
    ).

load(Fields) ->
    Path = tmp_path("ircd.json"),
    Extra =
        case iolist_size(Fields) of
            0 -> <<>>;
            _ -> [<<",">>, Fields]
        end,
    ok = file:write_file(Path, [<<"{\"tcp_port\":6667">>, Extra, <<"}">>]),
    try
        ircd_config:load(Path)
    after
        file:delete(Path)
    end.

tmp_path(Name) ->
    filename:join(
        "/tmp", "ircd-bot-" ++ integer_to_list(erlang:unique_integer([positive])) ++ "-" ++ Name
    ).

%%% Live: a bot answering through a mock OpenAI-compatible provider.

live_test_() ->
    {timeout, 60, fun live/0}.

live() ->
    Mock = start_mock(self()),
    MockPort = mock_port(Mock),
    Dir = tmp_path("live"),
    ok = filelib:ensure_dir(filename:join([Dir, "db", "x"])),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, live_config(filename:join(Dir, "db"), MockPort)),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    try
        Port = listener_port(),
        Alice = register_client(Port, <<"alice">>),
        send(Alice, <<"CAP REQ :message-tags\r\nJOIN #lobby\r\n">>),
        Names = recv_until(Alice, <<" 366 ">>),
        %% The bot joined at startup.
        ?assert(has(Names, <<"helper">>)),

        %% An unaddressed message is not sent to the provider.
        send(Alice, <<"PRIVMSG #lobby :just chatting\r\n">>),
        %% An addressed question: typing indicator, then a prefixed answer.
        send(Alice, <<"PRIVMSG #lobby :helper: what is IRC?\r\n">>),
        Request = receive_request(),
        #{<<"model">> := <<"mock-model">>, <<"messages">> := Messages} = json:decode(Request),
        [System | _] = Messages,
        ?assertEqual(<<"You are a test bot.">>, maps:get(<<"content">>, System)),
        ?assertEqual(<<"alice: what is IRC?">>, maps:get(<<"content">>, lists:last(Messages))),
        ?assertEqual(nomatch, binary:match(Request, <<"just chatting">>)),
        Answer = recv_until(Alice, <<"line two">>),
        ?assert(has(Answer, <<"+typing=active">>)),
        ?assert(has(Answer, <<":helper!bot@irc.test PRIVMSG #lobby :alice: Mock answer">>)),
        ?assert(has(Answer, <<"PRIVMSG #lobby :line two">>)),
        %% Its messages carry the bot tag (user mode +B).
        ?assert(
            has(Answer, <<";bot;">>) orelse has(Answer, <<"@bot;">>) orelse has(Answer, <<";bot ">>)
        ),

        %% The follow-up carries the earlier exchange as conversation context.
        send(Alice, <<"PRIVMSG #lobby :helper, and then?\r\n">>),
        Second = json:decode(receive_request()),
        Contents = [maps:get(<<"content">>, M) || M <- maps:get(<<"messages">>, Second)],
        ?assert(lists:member(<<"alice: what is IRC?">>, Contents)),
        ?assert(lists:member(<<"Mock answer\nline two">>, Contents)),
        _ = recv_until(Alice, <<"line two">>),

        %% A reply (+draft/reply) to the bot's answer is answered without a
        %% mention, quotes the answered line, and is threaded under the question.
        BotMsgId = msgid_of(Answer, <<"PRIVMSG #lobby :alice: Mock answer">>),
        send(Alice, [<<"@+draft/reply=">>, BotMsgId, <<" PRIVMSG #lobby :why so?\r\n">>]),
        Reply = json:decode(receive_request()),
        ?assertEqual(
            <<"alice: (replying to your message \"alice: Mock answer\") why so?">>,
            maps:get(<<"content">>, lists:last(maps:get(<<"messages">>, Reply)))
        ),
        Threaded = recv_until(Alice, <<"line two">>),
        ?assert(has(Threaded, <<"+draft/reply=">>)),
        %% A reply to a message the bot did not send is ignored.
        send(Alice, <<"@+draft/reply=someoneelse PRIVMSG #lobby :not for the bot\r\n">>),

        %% NOTICE and CTCP never trigger a request.
        send(Alice, <<"NOTICE #lobby :helper: notice\r\nPRIVMSG #lobby :\x01VERSION\x01\r\n">>),

        %% Private message; the provider fails and the user gets a NOTICE.
        Mock ! {next_status, 500},
        send(Alice, <<"PRIVMSG helper :hello in private\r\n">>),
        Private = json:decode(receive_request()),
        ?assertEqual(
            <<"hello in private">>,
            maps:get(<<"content">>, lists:last(maps:get(<<"messages">>, Private)))
        ),
        Failed = recv_until(Alice, <<"couldn't get an answer">>),
        ?assert(has(Failed, <<"NOTICE alice :Sorry">>)),

        %% WHOIS shows the bot's real name.
        send(Alice, <<"WHOIS helper\r\n">>),
        ?assert(has(recv_until(Alice, <<" 318 ">>), <<"Test assistant">>)),
        %% No stray provider requests were made.
        receive
            {mock_request, _} -> ?assert(false)
        after 300 -> ok
        end
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG"),
        Mock ! stop
    end.

live_config(Db, MockPort) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",\"retention\":\"transient\",">>,
        <<"\"channels\":[{\"name\":\"#lobby\"}],">>,
        <<"\"ai_providers\":{\"mock\":{\"base_url\":\"http://127.0.0.1:">>,
        integer_to_binary(MockPort),
        <<"/v1\",\"api_key\":\"sk-mock\",\"model\":\"mock-model\",\"timeout\":5}},">>,
        <<"\"bots\":[{\"nick\":\"helper\",\"provider\":\"mock\",\"channels\":[\"#lobby\"],">>,
        <<"\"realname\":\"Test assistant\",\"system_prompt\":\"You are a test bot.\"}],">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).

%% The msgid tag of the first line containing Needle.
msgid_of(Lines, Needle) ->
    [Line | _] = [L || L <- binary:split(Lines, <<"\r\n">>, [global]), has(L, Needle)],
    {match, [Id]} = re:run(Line, <<"[@;]msgid=([^; ]+)">>, [{capture, [1], binary}]),
    Id.

receive_request() ->
    receive
        {mock_request, Body} -> Body
    after 5000 -> error(no_provider_request)
    end.

%% A one-connection-at-a-time HTTP server answering chat/completions. It
%% forwards each request body to the test and checks the bearer token.
start_mock(Test) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, L} = gen_tcp:listen(0, [
            binary, {active, false}, {packet, raw}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}
        ]),
        {ok, Port} = inet:port(L),
        Parent ! {mock_port, self(), Port},
        mock_loop(L, Test, 200)
    end),
    Pid.

mock_port(Pid) ->
    receive
        {mock_port, Pid, Port} -> Port
    after 5000 -> error(mock_not_started)
    end.

mock_loop(L, Test, Status) ->
    receive
        stop -> gen_tcp:close(L);
        {next_status, S} -> mock_loop(L, Test, S)
    after 0 ->
        case gen_tcp:accept(L, 100) of
            {ok, S} ->
                %% A status change queued while blocked in accept applies to
                %% this connection.
                Use =
                    receive
                        {next_status, Next} -> Next
                    after 0 -> Status
                    end,
                {Headers, Body} = read_http(S, <<>>),
                ?assertNotEqual(
                    nomatch,
                    binary:match(string:lowercase(Headers), <<"authorization: bearer sk-mock">>)
                ),
                Test ! {mock_request, Body},
                Reply =
                    case Use of
                        200 ->
                            <<"{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Mock answer\\nline two\"}}]}">>;
                        _ ->
                            <<"{\"error\":{\"message\":\"boom\"}}">>
                    end,
                ok = gen_tcp:send(S, [
                    <<"HTTP/1.1 ">>,
                    integer_to_binary(Use),
                    <<" X\r\ncontent-type: application/json\r\n">>,
                    <<"content-length: ">>,
                    integer_to_binary(byte_size(Reply)),
                    <<"\r\nconnection: close\r\n\r\n">>,
                    Reply
                ]),
                gen_tcp:close(S),
                mock_loop(L, Test, 200);
            {error, timeout} ->
                mock_loop(L, Test, Status)
        end
    end.

read_http(S, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            {match, [Len]} = re:run(Head, <<"(?i)content-length:\\s*(\\d+)">>, [
                {capture, [1], binary}
            ]),
            {Head, read_body(S, Rest, binary_to_integer(Len))};
        [_] ->
            {ok, Data} = gen_tcp:recv(S, 0, 5000),
            read_http(S, <<Acc/binary, Data/binary>>)
    end.

read_body(_S, Body, Len) when byte_size(Body) >= Len -> binary:part(Body, 0, Len);
read_body(S, Body, Len) ->
    {ok, Data} = gen_tcp:recv(S, 0, 5000),
    read_body(S, <<Body/binary, Data/binary>>, Len).

register_client(Port, Nick) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    send(Sock, [<<"NICK ">>, Nick, <<"\r\nUSER ">>, Nick, <<" 0 * :T\r\n">>]),
    _ = recv_until(Sock, <<" 001 ">>),
    Sock.

send(Sock, Data) -> ok = gen_tcp:send(Sock, Data).

recv_until(Sock, Needle) -> recv_until(Sock, Needle, <<>>).

recv_until(Sock, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            {ok, Bin} = gen_tcp:recv(Sock, 0, 5000),
            recv_until(Sock, Needle, <<Acc/binary, Bin/binary>>);
        _ ->
            Acc
    end.

has(Bin, Needle) -> binary:match(Bin, Needle) =/= nomatch.

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.
