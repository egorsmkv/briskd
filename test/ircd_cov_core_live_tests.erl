-module(ircd_cov_core_live_tests).
-include_lib("eunit/include/eunit.hrl").

%% Live coverage for ircd_session, ircd_listener, ircd_sessions, ircd_app,
%% and ircd_shutdown: line framing on TCP (RFC 1459 2.3), registration and
%% link timers (driven by injecting the timer messages into the session),
%% inbound RFC 2813 PASS/SERVER handling, STARTTLS and TLS handshake
%% failures, WebSocket (ws and wss) sessions, max_clients admission, and the
%% application start and stop paths.

live_test_() ->
    {timeout, 180, fun live/0}.

admission_test_() ->
    {timeout, 60, fun admission/0}.

app_paths_test_() ->
    {timeout, 90, fun app_paths/0}.

prep_stop_without_app_test() ->
    %% With no supervision tree the drain fails; prep_stop logs and returns.
    ?assertEqual(undefined, whereis(ircd_sup)),
    ?assertEqual(state, ircd_app:prep_stop(state)).

session_format_status_test() ->
    ?assertEqual(#{}, ircd_session:format_status(#{})),
    ?assertEqual(
        #{state => {tcp, s, <<"p">>, <<>>, {server_pass, redacted}}},
        ircd_session:format_status(#{state => {tcp, s, <<"p">>, <<>>, {server_pass, <<"pw">>}}})
    ),
    ?assertEqual(
        #{state => {tcp, s, <<"p">>}}, ircd_session:format_status(#{state => {tcp, s, <<"p">>}})
    ).

%%% Main live server: tcp, tls, ws, and wss listeners.

live() ->
    Dir = tmp_dir("live"),
    {CertFile, KeyFile} = certificate(Dir),
    Extra = [
        <<"\"tls_port\":0,\"ws_port\":0,\"wss_port\":0,">>,
        <<"\"certfile\":\"">>,
        CertFile,
        <<"\",\"keyfile\":\"">>,
        KeyFile,
        <<"\",\"multiclient\":true,\"shutdown_grace\":1,">>,
        <<"\"server_links\":[{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false}],">>
    ],
    start_app(Dir, Extra),
    try
        Tcp = listener_port(tcp),
        listener_callbacks(),
        session_callbacks(Tcp),
        registration_timeouts(Tcp),
        framing(Tcp),
        malformed_first_lines(Tcp),
        starttls(Tcp),
        tls_handshake_failure(listener_port(tls)),
        inbound_link(Tcp),
        inbound_link_failures(Tcp),
        multiclient(Tcp),
        websocket(listener_port(ws)),
        secure_websocket(listener_port(wss)),
        closed_socket_paths(Tcp, listener_port(ws)),
        %% A TLS connection that never sends a ClientHello keeps its session
        %% busy, so the graceful drain polls until shutdown_grace expires.
        Before = session_pids(),
        _Idle = connect(listener_port(tls)),
        ?assert(wait_until(fun() -> session_pids() -- Before =/= [] end))
    after
        stop_app()
    end.

listener_callbacks() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    true = is_pid(Pid),
    ?assertEqual({error, unsupported}, gen_server:call(Pid, anything)),
    ok = gen_server:cast(Pid, anything),
    Pid ! anything,
    ?assert(is_process_alive(Pid)).

session_callbacks(Port) ->
    Sock = client(Port, <<"cbuser">>),
    Pid = session_for(Sock),
    ?assertEqual({error, unsupported}, gen_server:call(Pid, anything)),
    ok = gen_server:cast(Pid, anything),
    Pid ! unexpected_message,
    %% A registered client ignores the registration timer.
    Pid ! registration_timeout,
    %% A timer for another link generation is ignored.
    Pid ! {link_ping_timeout, make_ref()},
    send(Sock, <<"PING :alive">>),
    ?assert(has(collect(Sock), <<"PONG irc.test :alive">>)),
    Status = sys:get_status(Pid),
    ?assertMatch({status, Pid, _, _}, Status),
    %% A socket error closes the session.
    {_, Socket, _, _, _} = sys:get_state(Pid),
    Pid ! {tcp_error, Socket, econnreset},
    ?assert(wait_dead(Pid)),
    gen_tcp:close(Sock).

registration_timeouts(Port) ->
    %% No line yet: the connection has not reached ircd_state.
    Silent = connect(Port),
    SilentPid = session_for(Silent),
    ?assertMatch({tcp, _, _, _, awaiting}, sys:get_state(SilentPid)),
    SilentPid ! registration_timeout,
    ?assert(wait_dead(SilentPid)),
    ?assert(closed(Silent)),
    %% NICK without USER: a client that has not completed registration.
    Half = connect(Port),
    send(Half, <<"NICK halfway">>),
    HalfPid = session_for(Half),
    ok = wait_role(HalfPid, client),
    HalfPid ! registration_timeout,
    ?assert(wait_dead(HalfPid)),
    ?assert(closed(Half)).

framing(Port) ->
    Sock = client(Port, <<"framer">>),
    %% A partial line, then several lines and an empty line in one read.
    ok = gen_tcp:send(Sock, <<"PI">>),
    timer:sleep(50),
    ok = gen_tcp:send(Sock, <<"NG :one\r\nPING :two\r\n\r\nPING :three\r\n">>),
    Out = collect(Sock),
    ?assert(has(Out, <<":one">>)),
    ?assert(has(Out, <<":two">>)),
    ?assert(has(Out, <<":three">>)),
    %% A tagged line that outgrows the wire cap before CR LF gets 417 and
    %% the rest of it is discarded up to the next LF (IRCv3 message-tags).
    ok = gen_tcp:send(Sock, [<<"@">>, binary:copy(<<"t">>, 9000)]),
    ?assert(has(collect(Sock), <<" 417 ">>)),
    ok = gen_tcp:send(Sock, <<"still-discarding">>),
    timer:sleep(50),
    ok = gen_tcp:send(Sock, <<"end\nPING :after\r\n">>),
    ?assert(has(collect(Sock), <<":after">>)),
    %% A complete line over 512 octets from a registered client is 417.
    send(Sock, [<<"PRIVMSG framer :">>, binary:copy(<<"a">>, 600)]),
    ?assert(has(collect(Sock), <<" 417 ">>)),
    send(Sock, <<"QUIT :done">>),
    ?assert(closed(Sock)).

malformed_first_lines(Port) ->
    %% The first line is over 512 octets: the connection becomes a client and gets 417.
    Long = connect(Port),
    send(Long, [<<"PRIVMSG x :">>, binary:copy(<<"a">>, 600)]),
    ?assert(has(collect(Long), <<" 417 ">>)),
    %% A tagged partial line with a bare LF is malformed and closes.
    ok = gen_tcp:send(Long, <<"@a=b\nxx">>),
    ?assert(closed(Long)),
    %% So does an untagged one.
    Bare = connect(Port),
    ok = gen_tcp:send(Bare, <<"PING\nxx">>),
    ?assert(closed(Bare)),
    %% Tags on a server PASS are not allowed.
    Tagged = connect(Port),
    send(Tagged, <<"@t=1 PASS linksecret 0210 |">>),
    ?assert(closed(Tagged)),
    %% A NUL in a line closes the connection.
    Nul = connect(Port),
    ok = gen_tcp:send(Nul, <<"PI", 0, "NG\r\n">>),
    ?assert(closed(Nul)).

starttls(Port) ->
    %% Nothing may follow STARTTLS in the same read.
    Eager = connect(Port),
    ok = gen_tcp:send(Eager, <<"STARTTLS\r\nPING :x\r\n">>),
    ?assert(closed(Eager)),
    %% A client that answers 670 with plaintext fails the handshake.
    Plain = connect(Port),
    send(Plain, <<"STARTTLS">>),
    ?assert(has(collect(Plain), <<" 670 ">>)),
    ok = gen_tcp:send(Plain, <<"this is not a TLS ClientHello\r\n\r\n">>),
    ?assert(closed(Plain)).

tls_handshake_failure(TlsPort) ->
    Sock = connect(TlsPort),
    ok = gen_tcp:send(Sock, <<"NICK plaintext\r\nUSER a 0 * :b\r\n">>),
    ?assert(closed(Sock)).

inbound_link(Port) ->
    Link = link_peer(Port),
    Pid = session_for(Link),
    ?assertMatch({tcp, _, <<"peer.test">>, _, {server, undefined}}, sys:get_state(Pid)),
    %% An authenticated link ignores the registration timer.
    Pid ! registration_timeout,
    send(Link, <<"PING peer.test">>),
    ?assert(has(collect(Link), <<"PONG irc.test peer.test">>)),
    %% Liveness: the server pings; a matching PONG clears the token.
    Pid ! liveness_ping,
    ?assert(has(collect(Link), <<"PING irc.test">>)),
    ?assertMatch({_, _, _, _, {server, Token}} when is_reference(Token), sys:get_state(Pid)),
    send(Link, <<"PONG peer.test irc.test">>),
    ok = wait_role(Pid, {server, undefined}),
    %% A PONG from the wrong responder does not.
    Pid ! liveness_ping,
    ?assert(has(collect(Link), <<"PING irc.test">>)),
    send(Link, <<"PONG someone.else irc.test">>),
    %% Unknown server commands are ignored.
    send(Link, <<":peer.test WALLOPS :hello">>),
    send(Link, <<"PING peer.test">>),
    ?assert(has(collect(Link), <<"PONG irc.test peer.test">>)),
    {_, _, _, _, {server, Pending}} = sys:get_state(Pid),
    ?assert(is_reference(Pending)),
    Pid ! {link_ping_timeout, make_ref()},
    ?assert(is_process_alive(Pid)),
    Pid ! {link_ping_timeout, Pending},
    ?assert(wait_dead(Pid)),
    ?assert(closed(Link)),
    %% ERROR from the peer closes the link.
    Again = link_peer(Port),
    AgainPid = session_for(Again),
    send(Again, <<"ERROR :going away">>),
    ?assert(wait_dead(AgainPid)),
    ?assert(closed(Again)),
    %% Invalid remote state (an invalid nickname) closes the link.
    Bad = link_peer(Port),
    BadPid = session_for(Bad),
    send(Bad, <<":peer.test NICK 1bad 1 user host.test 1 + :Real">>),
    ?assert(wait_dead(BadPid)),
    ?assert(closed(Bad)).

inbound_link_failures(Port) ->
    %% The link password is held during the handshake and redacted in status.
    Held = connect(Port),
    send(Held, <<"PASS linksecret 0210 |">>),
    HeldPid = session_for(Held),
    ok = wait_role(HeldPid, {server_pass, <<"linksecret">>}),
    Status = lists:flatten(io_lib:format("~p", [sys:get_status(HeldPid)])),
    ?assertEqual(nomatch, string:find(Status, "linksecret")),
    ?assertNotEqual(nomatch, string:find(Status, "redacted")),
    %% A client command after PASS is a protocol error.
    send(Held, <<"NICK notaclient">>),
    ?assert(closed(Held)),
    %% A complete over-long line after PASS closes.
    Long = connect(Port),
    send(Long, <<"PASS linksecret 0210 |">>),
    send(Long, [<<"SERVER peer.test 1 1 :">>, binary:copy(<<"i">>, 600)]),
    ?assert(closed(Long)),
    %% PASS without SERVER before the registration timer.
    Slow = connect(Port),
    send(Slow, <<"PASS linksecret 0210 |">>),
    SlowPid = session_for(Slow),
    ok = wait_role(SlowPid, {server_pass, <<"linksecret">>}),
    SlowPid ! registration_timeout,
    ?assert(wait_dead(SlowPid)),
    ?assert(closed(Slow)),
    lists:foreach(
        fun(Lines) ->
            Sock = connect(Port),
            [send(Sock, Line) || Line <- Lines],
            ?assert(closed(Sock))
        end,
        [
            %% Version must start with four digits (RFC 2813 4.1.1).
            [<<"PASS linksecret 02 |">>],
            [<<"PASS linksecret abcd |">>],
            %% SERVER without PASS.
            [<<"SERVER peer.test 1 1 :Peer">>],
            %% Wrong password.
            [<<"PASS wrongsecret 0210 |">>, <<"SERVER peer.test 1 1 :Peer">>],
            %% Hop count and token must be integers.
            [<<"PASS linksecret 0210 |">>, <<"SERVER peer.test x 1 :Peer">>],
            [<<"PASS linksecret 0210 |">>, <<"SERVER peer.test 1 -1 :Peer">>],
            %% Tags on SERVER.
            [<<"PASS linksecret 0210 |">>, <<"@t SERVER peer.test 1 1 :Peer">>],
            %% SERVER from a connection that already sent NICK.
            [<<"NICK nolink">>, <<"SERVER peer.test 1 1 :Peer">>]
        ]
    ).

multiclient(Port) ->
    Owner = client(Port, <<"owner">>),
    send(Owner, <<"REGISTER * * ownerpass">>),
    ?assert(has(collect(Owner), <<"REGISTER SUCCESS owner">>)),
    Friend = client(Port, <<"friend">>),
    Second = connect(Port),
    send(Second, <<"CAP LS 302">>),
    _ = collect(Second),
    send(Second, <<"CAP REQ sasl">>),
    _ = collect(Second),
    send(Second, <<"AUTHENTICATE PLAIN">>),
    _ = collect(Second),
    send(Second, <<"AUTHENTICATE ", (base64:encode(<<0, "owner", 0, "ownerpass">>))/binary>>),
    _ = collect(Second),
    send(Second, <<"NICK owner">>),
    send(Second, <<"USER o * * :Owner">>),
    send(Second, <<"CAP END">>),
    ?assert(has(collect(Second), <<" 001 owner ">>)),
    SecondPid = session_for(Second),
    ok = wait_role_match(SecondPid, fun
        ({attached, _}) -> true;
        (_) -> false
    end),
    %% An attached connection ignores the registration timer.
    SecondPid ! registration_timeout,
    %% Commands on the attached connection run as the primary client.
    send(Second, <<"PRIVMSG friend :from the second connection">>),
    ?assert(has(collect(Friend), <<"PRIVMSG friend :from the second connection">>)),
    %% When the primary session goes away, the attached one is closed.
    gen_tcp:close(Owner),
    Closing = collect(Second),
    ?assert(has(Closing, <<"ERROR :Primary session closed">>)),
    ?assert(wait_dead(SecondPid)),
    gen_tcp:close(Friend).

websocket(Port) ->
    %% The upgrade request arrives in two reads (RFC 6455 4.1).
    Sock = connect(Port),
    Request = ws_request(<<>>),
    {First, Rest} = split_binary(Request, 20),
    ok = gen_tcp:send(Sock, First),
    timer:sleep(50),
    ok = gen_tcp:send(Sock, Rest),
    {ok, Pending} = ws_upgraded(gen_tcp, Sock),
    ws_send(gen_tcp, Sock, 1, <<"NICK wsuser">>),
    ws_send(gen_tcp, Sock, 1, <<"USER wsuser 0 * :Web">>),
    {Welcome, Buffer} = ws_until(gen_tcp, Sock, Pending, <<" 001 wsuser ">>),
    ?assertNotEqual([], Welcome),
    %% Text mode: each server line is one frame without CR LF.
    ?assert(lists:all(fun({1, Payload}) -> not has(Payload, <<"\r\n">>) end, Welcome)),
    Pid = session_for(Sock),
    %% Pong frames are ignored; a CR LF inside a frame is tolerated.
    ws_send(gen_tcp, Sock, 10, <<"pong">>),
    ws_send(gen_tcp, Sock, 1, <<"PING :crlf\r\n">>),
    {_, Buffer2} = ws_until(gen_tcp, Sock, Buffer, <<"PONG irc.test :crlf">>),
    %% A server line without CR LF is framed as is.
    Pid ! {irc, <<":irc.test NOTICE wsuser :raw">>},
    {_, Buffer3} = ws_until(gen_tcp, Sock, Buffer2, <<"NOTICE wsuser :raw">>),
    %% Ping frames are answered with pong.
    ws_send(gen_tcp, Sock, 9, <<"hb">>),
    {Pong, _} = ws_until_frame(gen_tcp, Sock, Buffer3, 10),
    ?assertEqual(<<"hb">>, Pong),
    %% Invalid UTF-8 in a text frame closes the connection.
    ws_send(gen_tcp, Sock, 1, <<"PRIVMSG wsuser :", 255, 254>>),
    ?assert(wait_dead(Pid)),
    gen_tcp:close(Sock),
    %% QUIT closes.
    Quit = ws_open(Port),
    ws_send(gen_tcp, Quit, 1, <<"QUIT :bye">>),
    ?assert(closed(Quit)),
    %% A malformed IRC line inside a frame closes.
    Nul = ws_open(Port),
    ws_send(gen_tcp, Nul, 2, <<"PI", 0, "NG">>),
    ?assert(closed(Nul)),
    %% An unmasked client frame is a protocol error: close code 1002.
    Unmasked = ws_open(Port),
    ok = gen_tcp:send(Unmasked, <<1:1, 0:3, 1:4, 0:1, 4:7, "PING">>),
    Close = collect(Unmasked),
    ?assert(has(Close, <<136, 2, 1002:16>>)),
    ?assert(closed(Unmasked)).

secure_websocket(Port) ->
    {ok, Sock} = ssl:connect(
        "127.0.0.1", Port, [binary, {active, false}, {verify, verify_none}], 5000
    ),
    ok = ssl:send(Sock, ws_request(<<"Sec-WebSocket-Protocol: binary.ircv3.net\r\n">>)),
    {ok, Pending} = ws_upgraded(ssl, Sock),
    ws_send(ssl, Sock, 2, <<"NICK wssuser\r\n">>),
    ws_send(ssl, Sock, 2, <<"USER wssuser 0 * :Web">>),
    {Frames, _} = ws_until(ssl, Sock, Pending, <<" 001 wssuser ">>),
    ?assert(lists:any(fun({Op, _}) -> Op =:= 2 end, Frames)),
    ws_send(ssl, Sock, 8, <<1000:16>>),
    ssl:close(Sock).

%% The session owns its socket. Closing it underneath the session and then
%% delivering a socket message or timer exercises the send and setopts error
%% branches, which otherwise need a peer that vanishes mid-write.
closed_socket_paths(Port, WsPort) ->
    Inject = fun(Sock, Message) ->
        Pid = session_for(Sock),
        {_, Socket, _, _, _} = sys:get_state(Pid),
        ok = gen_tcp:close(Socket),
        Pid ! Message(Socket),
        ?assert(wait_dead(Pid)),
        gen_tcp:close(Sock)
    end,
    %% Liveness PING on a link whose socket is gone.
    Inject(link_peer(Port), fun(_) -> liveness_ping end),
    %% A mirrored line for a socket that is gone.
    Inject(client(Port, <<"mirror">>), fun(_) -> {irc_mirror, <<"PING :x\r\n">>} end),
    %% Re-arming {active, once} fails after a processed line.
    Inject(client(Port, <<"rearm">>), fun(S) -> {tcp, S, <<"PING :x\r\n">>} end),
    %% STARTTLS cannot switch the socket to passive mode.
    Inject(connect_awaiting(Port), fun(S) -> {tcp, S, <<"STARTTLS\r\n">>} end),
    %% A delivery larger than the 1 MiB pending cap (?MAX_PENDING_BYTES).
    Huge = binary:copy(<<"a">>, 1048577),
    Inject(client(Port, <<"huge">>), fun(S) -> {tcp, S, Huge} end),
    Inject(ws_open(WsPort), fun(S) -> {tcp, S, Huge} end),
    %% The WebSocket upgrade response cannot be written.
    Inject(connect_awaiting(WsPort), fun(S) -> {tcp, S, ws_request(<<>>)} end).

connect_awaiting(Port) ->
    Sock = connect(Port),
    _ = session_for(Sock),
    Sock.

%%% Admission: max_clients and an IPv6 listener.

admission() ->
    Dir = tmp_dir("admission"),
    {Bind, Host} =
        case gen_tcp:listen(0, [inet6, {ip, {0, 0, 0, 0, 0, 0, 0, 1}}]) of
            {ok, Probe} ->
                gen_tcp:close(Probe),
                {<<"::1">>, {0, 0, 0, 0, 0, 0, 0, 1}};
            {error, _} ->
                {<<"127.0.0.1">>, {127, 0, 0, 1}}
        end,
    start_app(Dir, [<<"\"max_clients\":1,">>], Bind),
    try
        Port = listener_port(tcp),
        {ok, First} = gen_tcp:connect(Host, Port, [binary, {active, false}]),
        ok = gen_tcp:send(First, <<"NICK first\r\nUSER first 0 * :F\r\n">>),
        ?assert(has(collect(First), <<" 001 first ">>)),
        %% The second connection is over max_clients and is closed at once.
        {ok, Second} = gen_tcp:connect(Host, Port, [binary, {active, false}]),
        ?assert(closed(Second)),
        gen_tcp:close(First),
        %% Closing the listen socket under the accept loop fails the
        %% listener; the supervisor starts a new one.
        {_, Listener, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
        Ref = monitor(process, Listener),
        ok = gen_tcp:close(sys:get_state(Listener)),
        receive
            {'DOWN', Ref, process, Listener, _} -> ok
        after 5000 -> error(listener_still_running)
        end,
        ?assert(
            wait_until(fun() ->
                case lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)) of
                    {_, New, _, _} when is_pid(New), New =/= Listener -> true;
                    _ -> false
                end
            end)
        )
    after
        stop_app()
    end.

%%% ircd_app start failures and an already running Mnesia.

app_paths() ->
    {ok, _} = application:ensure_all_started(ssl),
    Dir = tmp_dir("app"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    %% Invalid configuration.
    Bad = filename:join(Dir, "bad.json"),
    ok = file:write_file(Bad, <<"{\"log_level\":\"loud\"}">>),
    os:putenv("IRCD_CONFIG", Bad),
    try
        ?assertMatch({error, _}, application:start(ircd))
    after
        os:unsetenv("IRCD_CONFIG")
    end,
    %% The TCP port is already taken: the supervision tree fails and the
    %% logger and Mnesia are restored.
    {ok, Taken} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, TakenPort} = inet:port(Taken),
    #{level := Level} = logger:get_primary_config(),
    try
        write_config(Dir, "busy.json", filename:join(Dir, "busy-db"), [
            <<"\"tcp_port\":">>, integer_to_binary(TakenPort), <<",">>
        ]),
        os:putenv("IRCD_CONFIG", filename:join(Dir, "busy.json")),
        ?assertMatch({error, _}, application:start(ircd)),
        ?assertNot(lists:keymember(mnesia, 1, application:which_applications())),
        ?assertEqual(Level, maps:get(level, logger:get_primary_config()))
    after
        os:unsetenv("IRCD_CONFIG"),
        gen_tcp:close(Taken)
    end,
    %% Mnesia already running with another directory is refused; with the
    %% configured directory it is reused and left running on stop.
    Running = filename:join(Dir, "running-db"),
    ok = filelib:ensure_dir(filename:join(Running, "x")),
    _ = application:load(mnesia),
    ok = application:set_env(mnesia, dir, Running),
    ok = mnesia:create_schema([node()]),
    ok = application:start(mnesia),
    try
        write_config(Dir, "other.json", filename:join(Dir, "other-db"), [<<"\"tcp_port\":0,">>]),
        os:putenv("IRCD_CONFIG", filename:join(Dir, "other.json")),
        ?assertMatch({error, _}, application:start(ircd)),
        write_config(Dir, "same.json", Running, [<<"\"tcp_port\":0,">>]),
        os:putenv("IRCD_CONFIG", filename:join(Dir, "same.json")),
        ok = application:start(ircd),
        ok = application:stop(ircd),
        ?assert(lists:keymember(mnesia, 1, application:which_applications()))
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG"),
        _ = application:stop(mnesia),
        _ = application:unset_env(mnesia, dir)
    end.

%%% Helpers

tmp_dir(Label) ->
    filename:join(
        "/tmp",
        "ircd-cov-core-" ++ Label ++ "-" ++ integer_to_list(erlang:system_time(nanosecond))
    ).

start_app(Dir, Extra) ->
    start_app(Dir, Extra, <<"127.0.0.1">>).

start_app(Dir, Extra, Bind) ->
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    write_config(Dir, "ircd.json", filename:join(Dir, "db"), [
        <<"\"bind\":\"">>, Bind, <<"\",\"tcp_port\":0,">> | Extra
    ]),
    application:stop(ircd),
    os:putenv("IRCD_CONFIG", filename:join(Dir, "ircd.json")),
    {ok, _} = application:ensure_all_started(ircd).

stop_app() ->
    _ = application:stop(ircd),
    os:unsetenv("IRCD_CONFIG").

write_config(Dir, Name, Db, Extra) ->
    ok = file:write_file(
        filename:join(Dir, Name),
        iolist_to_binary([
            <<"{\"name\":\"irc.test\",">>,
            Extra,
            <<"\"log_level\":\"warning\",\"log_format\":\"text\",">>,
            <<"\"mnesia_dir\":\"">>,
            Db,
            <<"\"}">>
        ])
    ).

certificate(Dir) ->
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    #{server_config := ServerConf} =
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
    {_, <<_/binary>> = Cert} = lists:keyfind(cert, 1, ServerConf),
    {_, {'RSAPrivateKey' = KeyType, <<_/binary>> = KeyDer}} = lists:keyfind(key, 1, ServerConf),
    ok = file:write_file(CertFile, public_key:pem_encode([{'Certificate', Cert, not_encrypted}])),
    ok = file:write_file(KeyFile, public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])),
    {list_to_binary(CertFile), list_to_binary(KeyFile)}.

listener_port(Kind) ->
    {_, Pid, _, _} = lists:keyfind(Kind, 1, supervisor:which_children(ircd_sup)),
    Socket = sys:get_state(Pid),
    {ok, {_, Port}} =
        case Kind of
            tcp -> inet:sockname(Socket);
            ws -> inet:sockname(Socket);
            _ -> ssl:sockname(Socket)
        end,
    Port.

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

client(Port, Nick) ->
    Sock = connect(Port),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :Real">>),
    ?assert(has(collect(Sock), <<" 001 ">>)),
    Sock.

link_peer(Port) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER peer.test 1 1 :Peer">>),
    ?assert(has(collect(Sock), <<"SERVER irc.test">>)),
    Sock.

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

collect(Sock) ->
    collect(Sock, <<>>, 0).

collect(Sock, Acc, N) when N < 60 ->
    Timeout =
        case Acc of
            <<>> -> 200;
            _ -> 100
        end,
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, <<_/binary>> = Bin} -> collect(Sock, <<Acc/binary, Bin/binary>>, N + 1);
        {error, timeout} when Acc =:= <<>>, N < 15 -> collect(Sock, Acc, N + 1);
        {error, _} -> Acc
    end;
collect(_Sock, Acc, _) ->
    Acc.

%% True when the server closes the connection within five seconds.
closed(Sock) ->
    closed(Sock, erlang:monotonic_time(millisecond) + 5000).

closed(Sock, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case gen_tcp:recv(Sock, 0, Left) of
        {ok, _} -> closed(Sock, Deadline);
        {error, closed} -> true;
        {error, econnreset} -> true;
        {error, enotconn} -> true;
        {error, timeout} -> false
    end.

has(Bin, Needle) ->
    binary:match(iolist_to_binary(Bin), Needle) =/= nomatch.

session_pids() ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(ircd_sessions), is_pid(Pid)].

%% The session process whose socket is the server side of this client socket.
session_for(Sock) ->
    {ok, {_, Local}} = inet:sockname(Sock),
    Find = fun() ->
        [
            Pid
         || {_, Pid, _, _} <- supervisor:which_children(ircd_sessions),
            is_pid(Pid),
            peer_port(Pid) =:= Local
        ]
    end,
    true = wait_until(fun() -> Find() =/= [] end),
    [Pid] = Find(),
    Pid.

peer_port(Pid) ->
    try sys:get_state(Pid, 1000) of
        {Kind, Socket, _, _, _} ->
            Result =
                case Kind of
                    tcp when is_port(Socket) -> inet:peername(Socket);
                    ws when is_port(Socket) -> inet:peername(Socket);
                    _ -> ssl:peername(Socket)
                end,
            case Result of
                {ok, {_, Port}} -> Port;
                _ -> undefined
            end;
        _ ->
            undefined
    catch
        exit:_ -> undefined
    end.

wait_role(Pid, Role) ->
    wait_role_match(Pid, fun(Current) -> Current =:= Role end).

wait_role_match(Pid, Match) ->
    true = wait_until(fun() ->
        try sys:get_state(Pid, 1000) of
            {_, _, _, _, Role} -> Match(Role);
            _ -> false
        catch
            exit:_ -> false
        end
    end),
    ok.

wait_dead(Pid) ->
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> true
    after 5000 ->
        demonitor(Ref, [flush]),
        false
    end.

wait_until(Fun) ->
    wait_until(Fun, 100).

wait_until(_Fun, 0) ->
    false;
wait_until(Fun, N) ->
    case Fun() of
        true ->
            true;
        false ->
            timer:sleep(30),
            wait_until(Fun, N - 1)
    end.

%%% WebSocket client side (RFC 6455): masked frames out, unmasked frames in.

ws_request(Extra) ->
    iolist_to_binary([
        <<"GET /irc HTTP/1.1\r\nHost: example\r\nUpgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n">>,
        <<"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n">>,
        Extra,
        <<"\r\n">>
    ]).

ws_open(Port) ->
    Sock = connect(Port),
    ok = gen_tcp:send(Sock, ws_request(<<>>)),
    {ok, _} = ws_upgraded(gen_tcp, Sock),
    Sock.

ws_upgraded(Mod, Sock) ->
    ws_upgraded(Mod, Sock, <<>>).

ws_upgraded(Mod, Sock, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            ?assert(has(Head, <<" 101 ">>)),
            {ok, Rest};
        [_] ->
            {ok, Bin} = Mod:recv(Sock, 0, 5000),
            ws_upgraded(Mod, Sock, <<Acc/binary, Bin/binary>>)
    end.

ws_send(Mod, Sock, Opcode, Payload) ->
    Mask = <<7, 1, 9, 3>>,
    Masked = list_to_binary([
        B bxor binary:at(Mask, I rem 4)
     || {B, I} <- lists:zip(binary_to_list(Payload), lists:seq(0, byte_size(Payload) - 1))
    ]),
    ok = Mod:send(
        Sock, <<1:1, 0:3, Opcode:4, 1:1, (byte_size(Payload)):7, Mask/binary, Masked/binary>>
    ).

%% Read frames until a data frame contains Needle. Returns the frames read and
%% the unparsed remainder.
ws_until(Mod, Sock, Buffer, Needle) ->
    ws_until(Mod, Sock, Buffer, Needle, [], 50).

ws_until(_Mod, _Sock, _Buffer, Needle, _Acc, 0) ->
    error({websocket_timeout, Needle});
ws_until(Mod, Sock, Buffer, Needle, Acc, N) ->
    {Frames, Rest} = ws_frames(Buffer, []),
    All = Acc ++ Frames,
    case lists:any(fun({_, Payload}) -> has(Payload, Needle) end, All) of
        true ->
            {All, Rest};
        false ->
            {ok, Bin} = Mod:recv(Sock, 0, 5000),
            ws_until(Mod, Sock, <<Rest/binary, Bin/binary>>, Needle, All, N - 1)
    end.

ws_until_frame(Mod, Sock, Buffer, Opcode) ->
    {Frames, Rest} = ws_frames(Buffer, []),
    case lists:keyfind(Opcode, 1, Frames) of
        {_, Payload} ->
            {Payload, Rest};
        false ->
            {ok, Bin} = Mod:recv(Sock, 0, 5000),
            ws_until_frame(Mod, Sock, <<Rest/binary, Bin/binary>>, Opcode)
    end.

ws_frames(<<_:4, Op:4, 0:1, 126:7, Len:16, Payload:Len/binary, Rest/binary>>, Acc) ->
    ws_frames(Rest, [{Op, Payload} | Acc]);
ws_frames(<<_:4, Op:4, 0:1, Len:7, Payload:Len/binary, Rest/binary>>, Acc) when Len < 126 ->
    ws_frames(Rest, [{Op, Payload} | Acc]);
ws_frames(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.
