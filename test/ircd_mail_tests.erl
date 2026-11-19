-module(ircd_mail_tests).
-behaviour(gen_smtp_server_session).
-include_lib("eunit/include/eunit.hrl").

%% gen_smtp_server_session callbacks for the local test SMTP server.
-export([
    init/4,
    code_change/3,
    handle_HELO/2,
    handle_EHLO/3,
    handle_STARTTLS/1,
    handle_MAIL/2,
    handle_MAIL_extension/2,
    handle_RCPT/2,
    handle_RCPT_extension/2,
    handle_DATA/4,
    handle_RSET/1,
    handle_VRFY/2,
    handle_other/3,
    terminate/2
]).

%%% Unit tests

mail_helpers_test() ->
    ?assertEqual(
        <<"https://irc.example.org/verify?account=alice&code=ABCD1234">>,
        ircd_mail:verify_link(<<"https://irc.example.org/verify">>, <<"alice">>, <<"ABCD1234">>)
    ),
    ?assertEqual(
        <<"https://irc.example.org/verify?foo=1&account=a%2Bb&code=XYZ">>,
        ircd_mail:verify_link(<<"https://irc.example.org/verify?foo=1">>, <<"a+b">>, <<"XYZ">>)
    ),
    Msg = ircd_mail:build_message(
        <<"noreply@irc.test\r\nBcc: evil@attacker.test">>,
        <<"alice@example.com">>,
        <<"Verify\r\nInjected: yes">>,
        <<"alice">>,
        #{code => <<"CODE9999">>, verify_url => <<"https://irc.test/verify">>}
    ),
    ?assertEqual(nomatch, binary:match(Msg, <<"\r\nBcc:">>)),
    ?assertEqual(nomatch, binary:match(Msg, <<"\r\nInjected:">>)),
    ?assert(
        binary:match(Msg, <<"https://irc.test/verify?account=alice&code=CODE9999">>) =/= nomatch
    ),
    ?assert(binary:match(Msg, <<"VERIFY alice CODE9999">>) =/= nomatch).

config_smtp_verification_test() ->
    Load = fun(Extra) ->
        Path = filename:join(
            "/tmp",
            "ircd-mail-cfg-" ++ integer_to_list(erlang:system_time(nanosecond)) ++ ".json"
        ),
        ok = file:write_file(Path, [<<"{\"tcp_port\":6667">>, Extra, <<"}">>]),
        try
            ircd_config:load(Path)
        after
            file:delete(Path)
        end
    end,
    ?assertMatch(
        {ok, #{
            account_verification := #{
                ttl := 600,
                verify_url := <<"https://irc.test/verify">>,
                smtp := #{
                    relay := <<"127.0.0.1">>,
                    port := 2525,
                    from := <<"noreply@irc.test">>,
                    tls := never,
                    ssl := false
                }
            }
        }},
        Load(
            <<",\"account_verification\":{\"ttl\":600,\"verify_url\":\"https://irc.test/verify\",\"smtp\":{\"relay\":\"127.0.0.1\",\"port\":2525,\"from\":\"noreply@irc.test\",\"tls\":\"never\"}}">>
        )
    ),
    ?assertMatch({error, _}, Load(<<",\"account_verification\":{\"ttl\":600}">>)),
    ?assertMatch(
        {error, _},
        Load(
            <<",\"account_verification\":{\"verify_url\":\"ftp://bad\",\"smtp\":{\"relay\":\"127.0.0.1\",\"from\":\"a@b.c\"}}">>
        )
    ),
    ?assertMatch(
        {error, _},
        Load(
            <<",\"account_verification\":{\"smtp\":{\"relay\":\"127.0.0.1\",\"from\":\"not-an-email\"}}">>
        )
    ),
    ?assertMatch(
        {error, _},
        Load(
            <<",\"account_verification\":{\"smtp\":{\"relay\":\"127.0.0.1\",\"from\":\"a@b.c\",\"username\":\"u\"}}">>
        )
    ).

%%% Integration test with local gen_smtp_server + WebUI /verify + SASL login

smtp_web_verify_integration_test_() ->
    {timeout, 60, fun smtp_web_verify_integration/0}.

smtp_web_verify_integration() ->
    {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(gen_smtp),
    SmtpPort = free_port(),
    WebPort = free_port(),
    SmtpRef = {ircd_test_smtp, erlang:system_time(nanosecond)},
    Self = self(),
    {ok, _} = gen_smtp_server:start(SmtpRef, ?MODULE, [
        {address, {127, 0, 0, 1}},
        {port, SmtpPort},
        {domain, "localhost"},
        {sessionoptions, [{callbackoptions, [Self]}]}
    ]),
    Dir = filename:join(
        "/tmp",
        "ircd-mail-int-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config_json(Db, SmtpPort, WebPort)),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    try
        IrcPort = listener_port(),
        Sock1 = connect_tcp(IrcPort),
        ok = gen_tcp:send(
            Sock1,
            <<"CAP LS 302\r\nCAP REQ :draft/account-registration sasl\r\nNICK alice\r\nUSER alice 0 * :Alice\r\nCAP END\r\n">>
        ),
        _ = recv_until(Sock1, <<" 001 ">>, <<>>),

        %% Trigger account registration; server should send SMTP email with web link.
        ok = gen_tcp:send(Sock1, <<"REGISTER alice alice@example.com strongpass123\r\n">>),
        RegReply = recv_until(Sock1, <<"VERIFICATION_REQUIRED">>, <<>>),
        ?assert(has(RegReply, <<"REGISTER VERIFICATION_REQUIRED alice">>)),
        ok = gen_tcp:close(Sock1),

        %% Wait for the local SMTP server to receive the verification email.
        {From, To, Data} =
            receive
                {smtp_mail, F, T, D} -> {F, T, D}
            after 10000 ->
                error(smtp_mail_timeout)
            end,
        ?assertEqual(<<"noreply@irc.test">>, From),
        ?assertEqual([<<"alice@example.com">>], To),

        %% Extract the web verification path + query from the email body.
        Prefix = iolist_to_binary([
            <<"http://127.0.0.1:">>, integer_to_binary(WebPort), <<"/verify?">>
        ]),
        {Pos, _} = binary:match(Data, Prefix),
        AfterPrefix = binary:part(Data, Pos, byte_size(Data) - Pos),
        [FullUrl | _] = binary:split(AfterPrefix, [<<"\r\n">>, <<"\n">>, <<" ">>]),
        PathAndQuery = binary:part(
            FullUrl,
            byte_size(<<"http://127.0.0.1:">>) + byte_size(integer_to_binary(WebPort)),
            byte_size(FullUrl) - byte_size(<<"http://127.0.0.1:">>) -
                byte_size(integer_to_binary(WebPort))
        ),

        %% Visiting /verify without query parameters renders the email + code + ALTCHA form.
        {200, FormBody} = http_get(WebPort, <<"/verify">>),
        ?assert(has(FormBody, <<"<title>Verify Account - ircd</title>">>)),
        ?assert(has(FormBody, <<"name=\"email\"">>)),
        ?assert(has(FormBody, <<"name=\"code\"">>)),
        ?assert(has(FormBody, <<"altcha-check">>)),

        %% Visiting /verify with email link prefills the form (and still requires ALTCHA on submit).
        {200, PrefillBody} = http_get(WebPort, PathAndQuery),
        ?assert(has(PrefillBody, <<"value=\"alice\"">>)),

        %% Extract the code from the email link query string.
        [_, QueryPart] = binary:split(PathAndQuery, <<"?">>),
        Pairs = uri_string:dissect_query(QueryPart),
        {_, AliceCode} = lists:keyfind(<<"code">>, 1, Pairs),

        %% POST /api/verify without ALTCHA is rejected.
        {400, NoAltchaV} = http_post_json(
            WebPort, <<"/api/verify">>, #{account => <<"alice">>, code => AliceCode}
        ),
        ?assertMatch(#{<<"error">> := <<"altcha_required">>}, json:decode(NoAltchaV)),

        %% Verify alice via POST /api/verify with valid server-generated test ALTCHA payload.
        {200, Body1} = http_post_json(WebPort, <<"/api/verify">>, #{
            account => <<"alice">>,
            code => AliceCode,
            altcha => test_altcha_payload(11)
        }),
        ?assertMatch(
            #{<<"status">> := <<"verified">>, <<"account">> := <<"alice">>}, json:decode(Body1)
        ),

        %% Reusing the same verification code fails with 400.
        {400, Body2} = http_post_json(WebPort, <<"/api/verify">>, #{
            account => <<"alice">>,
            code => AliceCode,
            altcha => test_altcha_payload(12)
        }),
        ?assertMatch(#{<<"error">> := <<"invalid_code">>}, json:decode(Body2)),

        %% Verify a second pending account by pasting email + code into /api/verify.
        {ok, _} = ircd_account:create(
            <<"bobmail">>, <<"Bob@Example.COM">>, <<"strongpass123">>, [], {<<"BOBCODE9">>, 60000}
        ),
        {200, EmailVerifyBody} = http_post_json(WebPort, <<"/api/verify">>, #{
            email => <<"bob@example.com">>,
            code => <<"BOBCODE9">>,
            altcha => test_altcha_payload(13)
        }),
        ?assertMatch(
            #{<<"status">> := <<"verified">>, <<"account">> := <<"bobmail">>},
            json:decode(EmailVerifyBody)
        ),

        %% Now log in via SASL PLAIN on IRC with the newly verified account.
        Sock2 = connect_tcp(IrcPort),
        SaslPayload = base64:encode(<<0, "alice", 0, "strongpass123">>),
        ok = gen_tcp:send(Sock2, [
            <<"CAP REQ :sasl\r\nAUTHENTICATE PLAIN\r\n">>
        ]),
        _ = recv_until(Sock2, <<"AUTHENTICATE +">>, <<>>),
        ok = gen_tcp:send(Sock2, [
            <<"AUTHENTICATE ">>,
            SaslPayload,
            <<"\r\nNICK alice2\r\nUSER alice 0 * :Alice\r\nCAP END\r\n">>
        ]),
        SaslReply = recv_until(Sock2, <<" 001 ">>, <<>>),
        ?assert(has(SaslReply, <<" 903 ">>)),
        ok = gen_tcp:close(Sock2)
    after
        _ = application:stop(ircd),
        _ = gen_smtp_server:stop(SmtpRef),
        os:unsetenv("IRCD_CONFIG")
    end.

%%% gen_smtp_server_session callbacks

init(_Hostname, _SessionCount, _Address, [Owner]) ->
    {ok, [<<"ircd-test-smtp ESMTP">>], Owner}.

code_change(_OldVsn, Owner, _Extra) ->
    {ok, Owner}.

handle_HELO(_Hostname, Owner) ->
    {ok, 65536, Owner}.

handle_EHLO(_Hostname, Extensions, Owner) ->
    {ok, Extensions, Owner}.

handle_STARTTLS(Owner) ->
    Owner.

handle_MAIL(_From, Owner) ->
    {ok, Owner}.

handle_MAIL_extension(_Ext, Owner) ->
    {ok, Owner}.

handle_RCPT(_To, Owner) ->
    {ok, Owner}.

handle_RCPT_extension(_Ext, Owner) ->
    {ok, Owner}.

handle_DATA(From, To, Data, Owner) ->
    Owner ! {smtp_mail, From, To, Data},
    {ok, <<"queued-ok">>, Owner}.

handle_RSET(Owner) ->
    Owner.

handle_VRFY(_Address, Owner) ->
    {error, <<"252 VRFY disabled">>, Owner}.

handle_other(Verb, _Args, Owner) ->
    {[<<"500 Unknown command: ">>, Verb], Owner}.

terminate(Reason, Owner) ->
    {ok, Reason, Owner}.

%%% Helpers

free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Sock),
    ok = gen_tcp:close(Sock),
    Port.

config_json(Db, SmtpPort, WebPort) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",\"shutdown_grace\":2,">>,
        <<"\"webui\":{\"bind\":\"127.0.0.1\",\"port\":">>,
        integer_to_binary(WebPort),
        <<",\"username\":\"admin\",\"password\":\"topsecret\"},">>,
        <<"\"account_verification\":{\"ttl\":600,\"verify_url\":\"http://127.0.0.1:">>,
        integer_to_binary(WebPort),
        <<"/verify\",\"smtp\":{\"relay\":\"127.0.0.1\",\"port\":">>,
        integer_to_binary(SmtpPort),
        <<",\"from\":\"noreply@irc.test\",\"tls\":\"never\"}},">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).

connect_tcp(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

recv_until(Sock, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            {ok, Bin} = gen_tcp:recv(Sock, 0, 5000),
            recv_until(Sock, Needle, <<Acc/binary, Bin/binary>>);
        _ ->
            Acc
    end.

http_get(Port, Path) ->
    Sock = connect_tcp(Port),
    try
        ok = gen_tcp:send(Sock, [<<"GET ">>, Path, <<" HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n">>]),
        Raw = read_all(Sock, <<>>),
        [Head, Body] = binary:split(Raw, <<"\r\n\r\n">>),
        [StatusLine | _] = binary:split(Head, <<"\r\n">>, [global]),
        [<<"HTTP/1.1">>, CodeBin | _] = binary:split(StatusLine, <<" ">>, [global]),
        {binary_to_integer(CodeBin), Body}
    after
        gen_tcp:close(Sock)
    end.

http_post_json(Port, Path, Map) ->
    Body = iolist_to_binary(json:encode(Map)),
    Sock = connect_tcp(Port),
    try
        ok = gen_tcp:send(Sock, [
            <<"POST ">>,
            Path,
            <<" HTTP/1.1\r\nHost: 127.0.0.1\r\n">>,
            <<"Content-Type: application/json\r\n">>,
            <<"X-Requested-With: ircd-webui\r\n">>,
            <<"Content-Length: ">>,
            integer_to_binary(byte_size(Body)),
            <<"\r\n\r\n">>,
            Body
        ]),
        Raw = read_all(Sock, <<>>),
        [Head, RespBody] = binary:split(Raw, <<"\r\n\r\n">>),
        [StatusLine | _] = binary:split(Head, <<"\r\n">>, [global]),
        [<<"HTTP/1.1">>, CodeBin | _] = binary:split(StatusLine, <<" ">>, [global]),
        {binary_to_integer(CodeBin), RespBody}
    after
        gen_tcp:close(Sock)
    end.

test_altcha_payload(Number) ->
    Key = persistent_term:get({ircd_altcha, hmac_key}),
    Ch = ircd_altcha:build_challenge(Key, Number, erlang:system_time(second) + 300),
    base64:encode(iolist_to_binary(json:encode(Ch#{number => Number}))).

read_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Chunk} -> read_all(Sock, <<Acc/binary, Chunk/binary>>);
        {error, closed} -> Acc
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.
