-module(ircd_ircv3_tls_tests).
-include_lib("eunit/include/eunit.hrl").

%% Live tests that need TLS or a scripted peer: STARTTLS, SASL EXTERNAL with
%% a client certificate, STS on a secure connection, account verification
%% codes, draft/event-playback, and replication of accounts, metadata, and
%% read markers over a server link.

tls_test_() ->
    {timeout, 180, fun run/0}.

run() ->
    Dir = filename:join(
        "/tmp", "ircd-ircv3-tls-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    #{server_config := ServerConf, client_config := ClientConf} =
        public_key:pkix_test_data(#{
            server_chain => #{
                root => [{digest, sha256}, {key, {rsa, 2048, 65537}}],
                peer => [{digest, sha256}, {key, {rsa, 2048, 65537}}]
            },
            client_chain => #{
                root => [{digest, sha256}, {key, {rsa, 2048, 65537}}],
                peer => [{digest, sha256}, {key, {rsa, 2048, 65537}}]
            }
        }),
    CertFile = filename:join(Dir, "server.pem"),
    KeyFile = filename:join(Dir, "server.key"),
    {_, ServerCert} = lists:keyfind(cert, 1, ServerConf),
    {_, {KeyType, KeyDer}} = lists:keyfind(key, 1, ServerConf),
    ok = file:write_file(
        CertFile, public_key:pem_encode([{'Certificate', ServerCert, not_encrypted}])
    ),
    ok = file:write_file(KeyFile, public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])),
    CodeFile = filename:join(Dir, "code"),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(Dir, CertFile, KeyFile, CodeFile)),
    application:stop(ircd),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    {_, ClientCert} = lists:keyfind(cert, 1, ClientConf),
    {_, ClientKey} = lists:keyfind(key, 1, ClientConf),
    Identity = [{cert, ClientCert}, {key, ClientKey}],
    try
        starttls(listener_port(tcp)),
        external(listener_port(tls), Identity),
        verification(listener_port(tcp), CodeFile),
        event_playback(listener_port(tcp)),
        replication(listener_port(tcp))
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

starttls(Port) ->
    Sock = connect(Port),
    send(Sock, <<"CAP LS 302">>),
    Ls = collect(Sock),
    ?assert(has(Ls, <<" tls">>)),
    ?assert(has(Ls, <<"sts=port=6697">>)),
    send(Sock, <<"STARTTLS">>),
    ?assert(has(collect(Sock), <<" 670 ">>)),
    {ok, Tls} = ssl:connect(Sock, [{verify, verify_none}, {active, false}], 5000),
    %% The offer changed with the upgrade: cap-notify (implicit at 302).
    Notify = tls_collect(Tls),
    ?assert(has(Notify, <<"CAP * DEL :tls">>)),
    ?assert(has(Notify, <<"CAP * NEW :sts=duration=600">>)),
    tls_send(Tls, <<"CAP LS 302">>),
    Secure = tls_collect(Tls),
    ?assert(has(Secure, <<"sts=duration=600">>)),
    ?assertNot(has(Secure, <<" tls ">>)),
    tls_send(Tls, <<"NICK upgraded">>),
    tls_send(Tls, <<"USER upgraded 0 * :U">>),
    tls_send(Tls, <<"CAP END">>),
    ?assert(has(tls_collect(Tls), <<" 001 ">>)),
    tls_send(Tls, <<"STARTTLS">>),
    ?assert(has(tls_collect(Tls), <<" 691 ">>)),
    ssl:close(Tls).

external(TlsPort, Identity) ->
    Opts = [binary, {active, false}, {verify, verify_none} | Identity],
    {ok, First} = ssl:connect("127.0.0.1", TlsPort, Opts, 5000),
    tls_send(First, <<"NICK certuser">>),
    tls_send(First, <<"REGISTER * c@example.org certpassword">>),
    ?assert(has(tls_collect(First), <<"VERIFICATION_REQUIRED certuser">>)),
    ssl:close(First),
    %% Pending accounts cannot log in; complete verification over TCP.
    Code = wait_code(),
    {ok, Second} = ssl:connect("127.0.0.1", TlsPort, Opts, 5000),
    tls_send(Second, <<"NICK certuser">>),
    tls_send(Second, <<"AUTHENTICATE EXTERNAL">>),
    _ = tls_collect(Second),
    tls_send(Second, <<"AUTHENTICATE +">>),
    ?assert(has(tls_collect(Second), <<" 904 ">>)),
    tls_send(Second, <<"VERIFY certuser ", Code/binary>>),
    Verified = tls_collect(Second),
    ?assert(has(Verified, <<"VERIFY SUCCESS certuser">>)),
    ?assert(has(Verified, <<" 900 ">>)),
    ssl:close(Second),
    {ok, Third} = ssl:connect("127.0.0.1", TlsPort, Opts, 5000),
    tls_send(Third, <<"CAP LS 302">>),
    _ = tls_collect(Third),
    tls_send(Third, <<"CAP REQ sasl">>),
    _ = tls_collect(Third),
    tls_send(Third, <<"NICK certnick">>),
    tls_send(Third, <<"USER c 0 * :C">>),
    tls_send(Third, <<"AUTHENTICATE EXTERNAL">>),
    ?assert(has(tls_collect(Third), <<"AUTHENTICATE +">>)),
    tls_send(Third, <<"AUTHENTICATE +">>),
    Done = tls_collect(Third),
    ?assert(has(Done, <<" 900 certnick ">>)),
    ?assert(has(Done, <<" certuser :You are now logged in">>)),
    ?assert(has(Done, <<" 903 ">>)),
    ssl:close(Third),
    {ok, NoCert} = ssl:connect(
        "127.0.0.1", TlsPort, [binary, {active, false}, {verify, verify_none}], 5000
    ),
    tls_send(NoCert, <<"AUTHENTICATE EXTERNAL">>),
    _ = tls_collect(NoCert),
    tls_send(NoCert, <<"AUTHENTICATE +">>),
    ?assert(has(tls_collect(NoCert), <<" 904 ">>)),
    ssl:close(NoCert).

verification(Port, CodeFile) ->
    _ = file:delete(CodeFile),
    Sock = connect(Port),
    send(Sock, <<"CAP LS 302">>),
    ?assert(has(collect(Sock), <<"email-required">>)),
    send(Sock, <<"NICK verifier">>),
    send(Sock, <<"REGISTER * * longpassword">>),
    ?assert(has(collect(Sock), <<"FAIL REGISTER INVALID_EMAIL">>)),
    send(Sock, <<"REGISTER * v@example.org longpassword">>),
    ?assert(has(collect(Sock), <<"REGISTER VERIFICATION_REQUIRED verifier">>)),
    Code = wait_code(),
    send(Sock, <<"VERIFY verifier WRONG123">>),
    ?assert(has(collect(Sock), <<"FAIL VERIFY INVALID_CODE verifier">>)),
    Other = connect(Port),
    send(Other, <<"NICK other">>),
    send(Other, <<"REGISTER verifier v@example.org longpassword">>),
    ?assert(has(collect(Other), <<"FAIL REGISTER ACCOUNT_EXISTS verifier">>)),
    gen_tcp:close(Other),
    send(Sock, <<"VERIFY verifier ", Code/binary>>),
    Done = collect(Sock),
    ?assert(has(Done, <<"VERIFY SUCCESS verifier">>)),
    ?assert(has(Done, <<" 900 verifier * verifier ">>)),
    send(Sock, <<"VERIFY verifier ", Code/binary>>),
    ?assert(has(collect(Sock), <<"FAIL VERIFY ALREADY_AUTHENTICATED">>)),
    gen_tcp:close(Sock).

wait_code() ->
    wait_code(50).

wait_code(0) ->
    erlang:error(no_verification_code);
wait_code(N) ->
    Dir = os:getenv("IRCD_CONFIG"),
    File = filename:join(filename:dirname(Dir), "code"),
    case file:read_file(File) of
        {ok, Code} when byte_size(Code) =:= 8 ->
            ok = file:delete(File),
            Code;
        _ ->
            timer:sleep(100),
            wait_code(N - 1)
    end.

event_playback(Port) ->
    Player = client(
        Port,
        <<"player">>,
        <<"batch server-time message-tags draft/chathistory draft/event-playback">>
    ),
    Plain = client(Port, <<"plainhist">>, <<"batch draft/chathistory">>),
    send(Player, <<"JOIN #events">>),
    _ = collect(Player),
    send(Plain, <<"JOIN #events">>),
    _ = collect(Plain),
    send(Player, <<"TOPIC #events :a topic">>),
    send(Player, <<"PRIVMSG #events :spoken">>),
    %% Typing indicators are ephemeral and are not stored; other TAGMSGs are.
    send(Player, <<"@+typing=active TAGMSG #events">>),
    send(Player, <<"@+draft/react=ok TAGMSG #events">>),
    _ = collect(Player),
    _ = collect(Plain),
    send(Player, <<"CHATHISTORY LATEST #events * 20">>),
    Events = collect(Player),
    ?assert(has(Events, <<"JOIN #events">>)),
    ?assert(has(Events, <<"TOPIC #events :a topic">>)),
    ?assert(has(Events, <<"PRIVMSG #events :spoken">>)),
    ?assert(has(Events, <<"TAGMSG #events">>)),
    ?assert(has(Events, <<"+draft/react=ok">>)),
    ?assertNot(has(Events, <<"+typing">>)),
    send(Plain, <<"CHATHISTORY LATEST #events * 20">>),
    Messages = collect(Plain),
    ?assert(has(Messages, <<"PRIVMSG #events :spoken">>)),
    ?assertNot(has(Messages, <<"TOPIC #events">>)),
    ?assertNot(has(Messages, <<"JOIN #events">>)),
    gen_tcp:close(Player),
    gen_tcp:close(Plain).

replication(Port) ->
    Peer = handshake(Port, <<"peer.test">>),
    Burst = collect(Peer),
    %% Verified accounts travel in the burst; the email address does not.
    ?assert(has(Burst, <<"ACCOUNTSYNC verifier ">>)),
    ?assertNot(has(Burst, <<"v@example.org">>)),
    %% An account registered on the peer can log in here.
    Salt = crypto:strong_rand_bytes(16),
    Salted = crypto:pbkdf2_hmac(sha256, <<"farpassword">>, Salt, 4096, 32),
    ClientKey = crypto:mac(hmac, sha256, Salted, <<"Client Key">>),
    ServerKey = crypto:mac(hmac, sha256, Salted, <<"Server Key">>),
    send(
        Peer,
        iolist_to_binary([
            <<":peer.test ACCOUNTSYNC faracct ">>,
            base64:encode(Salt),
            <<" 4096 ">>,
            base64:encode(crypto:hash(sha256, ClientKey)),
            <<" ">>,
            base64:encode(ServerKey),
            <<" 1 :">>
        ])
    ),
    timer:sleep(200),
    Local = client(Port, <<"localfar">>, <<"sasl batch draft/metadata-2 draft/read-marker">>),
    send(Local, <<"AUTHENTICATE PLAIN">>),
    _ = collect(Local),
    send(Local, <<"AUTHENTICATE ", (base64:encode(<<0, "faracct", 0, "farpassword">>))/binary>>),
    ?assert(has(collect(Local), <<" 903 ">>)),
    ?assert(has(collect(Peer), <<"ACCOUNT faracct">>)),
    %% Read markers set on the peer reach this server's clients of the account.
    send(Peer, <<":peer.test MARKREAD faracct #shared 1893456000000">>),
    ?assert(has(collect(Local), <<"MARKREAD #shared timestamp=2030-01-01T00:00:00.000Z">>)),
    send(Local, <<"MARKREAD #other timestamp=2031-01-01T00:00:00.000Z">>),
    _ = collect(Local),
    ?assert(has(collect(Peer), <<"MARKREAD faracct #other 1924992000000">>)),
    %% Metadata: a remote user's keys are readable and announced to subscribers.
    send(Local, <<"METADATA * SUB avatar">>),
    _ = collect(Local),
    send(Local, <<"JOIN #shared">>),
    _ = collect(Local),
    _ = collect(Peer),
    send(Peer, <<":peer.test NICK remmeta 0 user peer.test 1 + :R">>),
    send(Peer, <<":remmeta!user@peer.test JOIN #shared">>),
    send(Peer, <<":remmeta!user@peer.test METADATA remmeta avatar * :https://x/a.png">>),
    ?assert(has(collect(Local), <<"METADATA remmeta avatar * :https://x/a.png">>)),
    send(Local, <<"METADATA remmeta GET avatar">>),
    ?assert(has(collect(Local), <<" 761 localfar remmeta avatar * :https://x/a.png">>)),
    send(Local, <<"METADATA * SET color :red">>),
    _ = collect(Local),
    ?assert(has(collect(Peer), <<"METADATA localfar color * :red">>)),
    %% draft/multiline crosses the link as one batch, both ways.
    Multi = client(Port, <<"mlink">>, <<"batch draft/multiline message-tags">>),
    send(Multi, <<"JOIN #shared">>),
    _ = collect(Multi),
    _ = collect(Peer),
    _ = collect(Local),
    send(Multi, <<"BATCH +x draft/multiline #shared">>),
    send(Multi, <<"@batch=x PRIVMSG #shared :up one">>),
    send(Multi, <<"@batch=x PRIVMSG #shared :up two">>),
    send(Multi, <<"BATCH -x">>),
    Out = collect(Peer),
    ?assert(has(Out, <<"BATCH +">>)),
    ?assert(has(Out, <<"draft/multiline #shared">>)),
    ?assert(has(Out, <<"PRIVMSG #shared :up two">>)),
    _ = collect(Local),
    send(Peer, <<"@msgid=far1 :remmeta!user@peer.test BATCH +r1 draft/multiline #shared">>),
    send(Peer, <<"@batch=r1 :remmeta!user@peer.test PRIVMSG #shared :down one">>),
    send(
        Peer, <<"@batch=r1;draft/multiline-concat :remmeta!user@peer.test PRIVMSG #shared :+more">>
    ),
    send(Peer, <<":remmeta!user@peer.test BATCH -r1">>),
    In = collect(Multi),
    ?assert(has(In, <<"msgid=far1">>)),
    ?assert(has(In, <<"draft/multiline #shared">>)),
    ?assert(has(In, <<"draft/multiline-concat">>)),
    ?assert(has(In, <<"PRIVMSG #shared :down one">>)),
    gen_tcp:close(Multi),
    gen_tcp:close(Peer),
    gen_tcp:close(Local).

%%% Helpers

config(Dir, CertFile, KeyFile, CodeFile) ->
    Script = iolist_to_binary([
        <<"printf '%s' \\\"$IRCD_CODE\\\" > ">>, CodeFile
    ]),
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":0,">>,
        <<"\"certfile\":\"">>,
        CertFile,
        <<"\",\"keyfile\":\"">>,
        KeyFile,
        <<"\",">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",">>,
        <<"\"sts\":{\"port\":6697,\"duration\":600},">>,
        <<"\"account_verification\":{\"command\":[\"/bin/sh\",\"-c\",\"">>,
        Script,
        <<"\"]},">>,
        <<"\"mnesia_dir\":\"">>,
        filename:join(Dir, "db"),
        <<"\",">>,
        <<"\"server_links\":[{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false}]}">>
    ]).

client(Port, Nick, Caps) ->
    Sock = connect(Port),
    send(Sock, <<"CAP LS 302">>),
    _ = collect(Sock),
    send(Sock, <<"CAP REQ :", Caps/binary>>),
    ?assert(has(collect(Sock), <<" ACK ">>)),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :Real">>),
    send(Sock, <<"CAP END">>),
    ?assert(has(collect(Sock), <<" 001 ">>)),
    Sock.

handshake(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    Sock.

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

tls_send(Sock, Line) ->
    ok = ssl:send(Sock, [Line, <<"\r\n">>]).

collect(Sock) ->
    collect(fun(T) -> gen_tcp:recv(Sock, 0, T) end, <<>>, 0).

tls_collect(Sock) ->
    collect(fun(T) -> ssl:recv(Sock, 0, T) end, <<>>, 0).

collect(Recv, Acc, N) when N < 60 ->
    Timeout =
        case Acc of
            <<>> -> 200;
            _ -> 100
        end,
    case Recv(Timeout) of
        {ok, Bin} -> collect(Recv, <<Acc/binary, Bin/binary>>, N + 1);
        {error, timeout} when Acc =:= <<>>, N < 15 -> collect(Recv, Acc, N + 1);
        {error, _} -> Acc
    end;
collect(_Recv, Acc, _) ->
    Acc.

listener_port(Kind) ->
    {_, Pid, _, _} = lists:keyfind(Kind, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} =
        case Kind of
            tcp -> inet:sockname(sys:get_state(Pid));
            tls -> ssl:sockname(sys:get_state(Pid))
        end,
    Port.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.
