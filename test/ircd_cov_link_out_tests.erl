-module(ircd_cov_link_out_tests).
-include_lib("eunit/include/eunit.hrl").

%% The outbound RFC 2813 connector (ircd_link) against a fake peer listener
%% opened by the test: PASS/SERVER handshake, burst, PING/PONG liveness,
%% routed traffic through ircd_links, redacted status, and each failure that
%% drops the link followed by an operator-style immediate reconnect.

-define(UP, <<"up.test">>).

outbound_test_() ->
    {timeout, 90, fun outbound/0}.

outbound() ->
    {ok, Listen} = gen_tcp:listen(0, [
        binary, {active, false}, {packet, raw}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}
    ]),
    {ok, UpPort} = inet:port(Listen),
    Port = start(UpPort),
    try
        Link = link_pid(?UP),
        Alice = client(Port, <<"alice">>),
        send(Alice, <<"JOIN #room">>),
        sync(Alice),
        Up = accept(Listen),
        Hello = recv_until(Up, <<"SERVER irc.test">>),
        ?assert(has(Hello, <<"PASS linksecret 0210 |\r\n">>)),
        ?assert(has(Hello, <<"SERVER irc.test 1 1 :Erlang/OTP IRC server\r\n">>)),
        %% Nothing but PASS/SERVER is accepted before authentication.
        ?assertEqual({error, unsupported}, gen_server:call(Link, anything)),
        send(Up, <<"PASS linksecret 0210 |">>),
        wait_until(fun() -> maps:get(phase, sys:get_state(Link)) =:= await_server end),
        %% The configured password and the one the peer sent are redacted.
        {status, _, _, [_, _, _, _, Misc]} = sys:get_status(Link),
        [Redacted] = [S || {data, [{"State", S}]} <- Misc],
        ?assertEqual(redacted, maps:get(peer_password, Redacted)),
        ?assertNot(maps:is_key(password, maps:get(peer, Redacted))),
        send(Up, <<"SERVER up.test 1 1 :Up">>),
        ?assert(has(recv_until(Up, <<"NJOIN #room">>), <<"NICK alice 0 alice ">>)),
        wait_until(fun() -> maps:get(phase, sys:get_state(Link)) =:= authenticated end),
        %% An authenticated link resets the reconnect backoff.
        ?assertMatch(#{attempts := 0, backoff := undefined}, sys:get_state(Link)),
        %% Server PING is answered with the local and the origin name.
        send(Up, <<"PING up.test">>),
        recv_until(Up, <<"PONG irc.test up.test">>),
        %% Liveness: the worker pings, and a matching PONG clears the pending token.
        #{timer_gen := Gen} = sys:get_state(Link),
        Link ! {liveness_ping, Gen + 1},
        Link ! {ping_timeout, Gen, make_ref()},
        Link ! {reconnect, Gen + 1},
        Link ! unrelated,
        gen_server:cast(Link, connect_now),
        gen_server:cast(Link, unrelated),
        Link ! {liveness_ping, Gen},
        recv_until(Up, <<"PING irc.test">>),
        ?assertNotEqual(undefined, maps:get(ping_pending, sys:get_state(Link))),
        send(Up, <<"PONG up.test irc.test">>),
        pong_sync(Up),
        ?assertEqual(undefined, maps:get(ping_pending, sys:get_state(Link))),
        %% Routed traffic over the outbound link, in both directions.
        send(Up, <<":up.test SERVER leaf.test 2 2 :Leaf">>),
        send(Up, <<":up.test NICK rem 1 ruser rhost.test 7 + :Remote">>),
        send(Up, <<":rem!ruser@rhost.test JOIN #room">>),
        recv_until(Alice, <<":rem!ruser@rhost.test JOIN #room">>),
        send(Up, <<"WALLOPS :ignored">>),
        send(Up, <<>>),
        send(Up, <<":rem!ruser@rhost.test PRIVMSG alice :up-hello">>),
        recv_until(Alice, <<"up-hello">>),
        send(Alice, <<"PRIVMSG rem :to-up">>),
        recv_until(Up, <<"PRIVMSG rem :to-up">>),
        send(Alice, <<"PRIVMSG #room :room-up">>),
        recv_until(Up, <<"PRIVMSG #room :room-up">>),
        %% An inbound session with the same name does not get a second copy.
        Twin = handshake(Port, ?UP),
        In = handshake(Port, <<"in.test">>),
        sync(Twin),
        sync(In),
        send(Alice, <<"TOPIC #room :fanout">>),
        recv_until(Up, <<"TOPIC #room :fanout">>),
        recv_until(In, <<"TOPIC #room :fanout">>),
        ?assertNot(has(sync(Twin), <<"fanout">>)),
        %% A line from the inbound peer is relayed to the outbound peer.
        send(In, <<":in.test NICK inny 1 iuser ihost.test 3 + :In">>),
        recv_until(Up, <<"NICK inny">>),
        %% ERROR from an authenticated peer drops the link and its users.
        send(Up, <<"ERROR :going away">>),
        ?assertEqual(closed, wait_closed(Up)),
        wait_until(fun() -> maps:get(phase, sys:get_state(Link)) =:= disconnected end),
        ?assertEqual([], mnesia:dirty_read(remote_client, <<"rem">>)),
        %% Handshake failures, each followed by an immediate reconnect.
        lists:foreach(
            fun(Lines) ->
                Sock = accept(Listen, Link),
                recv_until(Sock, <<"SERVER irc.test">>),
                lists:foreach(fun(Line) -> gen_tcp:send(Sock, Line) end, Lines),
                ?assertEqual(closed, wait_closed(Sock))
            end,
            [
                [<<"PASS wrong 0210 |\r\n">>],
                [<<"PASS linksecret 02 |\r\n">>],
                [<<"PASS linksecret abcd |\r\n">>],
                [<<"PASS linksecret 0210 |\r\nSERVER nope.test 1 1 :x\r\n">>],
                [<<"PASS linksecret 0210 |\r\nSERVER up.test x 1 :x\r\n">>],
                [<<"NICK early\r\n">>],
                [<<"PRIVMSG a :b", 0, "c\r\n">>],
                [<<"half\rline">>]
            ]
        ),
        %% Failures after authentication.
        lists:foreach(
            fun(Lines) ->
                Sock = accept(Listen, Link),
                authenticate(Sock),
                lists:foreach(fun(Line) -> gen_tcp:send(Sock, Line) end, Lines),
                ?assertEqual(closed, wait_closed(Sock))
            end,
            [
                [<<":ghost!g@g PRIVMSG alice :spoofed\r\n">>],
                [<<":up.test NICK bad 1 u h.test x + :R\r\n">>]
            ]
        ),
        %% The peer closing its socket, and a missed PONG.
        Closing = accept(Listen, Link),
        authenticate(Closing),
        send(Closing, <<":up.test NICK gone 1 g ghost.test 1 + :Gone">>),
        pong_sync(Closing),
        gen_tcp:close(Closing),
        wait_until(fun() -> mnesia:dirty_read(remote_client, <<"gone">>) =:= [] end),
        Silent = accept(Listen, Link),
        authenticate(Silent),
        #{timer_gen := Gen2} = sys:get_state(Link),
        Link ! {liveness_ping, Gen2},
        recv_until(Silent, <<"PING irc.test">>),
        #{ping_pending := Token} = sys:get_state(Link),
        Link ! {ping_timeout, Gen2, Token},
        ?assertEqual(closed, wait_closed(Silent)),
        %% A refused connection keeps the worker alive and disconnected.
        ok = gen_tcp:close(Listen),
        #{timer_gen := Gen3} = sys:get_state(Link),
        ok = ircd_links:connect_peer(?UP),
        wait_until(fun() -> maps:get(timer_gen, sys:get_state(Link)) > Gen3 end),
        ?assertEqual(disconnected, maps:get(phase, sys:get_state(Link))),
        %% A TLS peer that refuses the connection is retried the same way.
        TLS = link_pid(<<"tlsup.test">>),
        #{timer_gen := Gen4} = sys:get_state(TLS),
        ok = ircd_links:connect_peer(<<"tlsup.test">>),
        wait_until(fun() -> maps:get(timer_gen, sys:get_state(TLS)) > Gen4 end)
    after
        catch_close(Listen),
        stop()
    end.

authenticate(Sock) ->
    recv_until(Sock, <<"SERVER irc.test">>),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER up.test 1 1 :Up">>),
    pong_sync(Sock).

%% The connector answers PING only after the lines before it are handled.
pong_sync(Sock) ->
    N = integer_to_binary(erlang:unique_integer([positive])),
    send(Sock, <<"PING o", N/binary>>),
    recv_until(Sock, <<"PONG irc.test o", N/binary>>).

catch_close(Listen) ->
    _ = gen_tcp:close(Listen),
    ok.

link_pid(Name) ->
    [Pid] = [
        Pid
     || {{server_link, Peer}, Pid, worker, _} <- supervisor:which_children(ircd_links),
        Peer =:= Name
    ],
    Pid.

accept(Listen) ->
    {ok, Sock} = gen_tcp:accept(Listen, 5000),
    Sock.

%% Ask the disconnected worker to reconnect now instead of after its backoff.
accept(Listen, Link) ->
    accept(Listen, Link, 40).

accept(_Listen, _Link, 0) ->
    error(no_reconnect);
accept(Listen, Link, N) ->
    gen_server:cast(Link, connect_now),
    case gen_tcp:accept(Listen, 250) of
        {ok, Sock} -> Sock;
        {error, timeout} -> accept(Listen, Link, N - 1)
    end.

start(UpPort) ->
    Dir = filename:join(
        "/tmp", "ircd-covlink-out-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(filename:join(Dir, "db"), UpPort)),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    [erase(Key) || {{buf, _} = Key, _} <- get()],
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.

stop() ->
    _ = application:stop(ircd),
    os:unsetenv("IRCD_CONFIG").

config(Db, UpPort) ->
    Link = fun(Name, P, TLS) ->
        [
            <<"{\"name\":\"">>,
            Name,
            <<"\",\"host\":\"127.0.0.1\",\"port\":">>,
            integer_to_binary(P),
            <<",\"password\":\"linksecret\",\"tls\":">>,
            TLS,
            <<"}">>
        ]
    end,
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"emergency\",\"log_format\":\"text\",\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\",\"server_links\":[">>,
        lists:join(<<",">>, [
            Link(?UP, UpPort, <<"false">>),
            Link(<<"in.test">>, 1, <<"false">>),
            Link(<<"tlsup.test">>, 1, <<"true">>)
        ]),
        <<"]}">>
    ]).

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

client(Port, Nick) ->
    Sock = connect(Port),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :", Nick/binary>>),
    recv_until(Sock, <<" 001 ">>),
    Sock.

handshake(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    recv_until(Sock, <<"SERVER irc.test">>),
    Sock.

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

sync(Sock) ->
    N = integer_to_binary(erlang:unique_integer([positive])),
    Token = <<"sync", N/binary>>,
    send(Sock, <<"PING ", Token/binary>>),
    recv_until(Sock, Token).

%% Read until Needle appears and its line is complete; keep the rest buffered.
recv_until(Sock, Needle) ->
    Deadline = erlang:monotonic_time(millisecond) + 3000,
    Buffered =
        case get({buf, Sock}) of
            undefined -> <<>>;
            B -> B
        end,
    put({buf, Sock}, <<>>),
    recv_loop(Sock, Needle, Deadline, Buffered).

recv_loop(Sock, Needle, Deadline, Acc) ->
    case line_end(Acc, Needle) of
        {ok, End} ->
            put({buf, Sock}, binary:part(Acc, End, byte_size(Acc) - End)),
            binary:part(Acc, 0, End);
        nomatch ->
            Left = Deadline - erlang:monotonic_time(millisecond),
            case Left > 0 andalso gen_tcp:recv(Sock, 0, Left) of
                {ok, <<_/binary>> = Bin} ->
                    recv_loop(Sock, Needle, Deadline, <<Acc/binary, Bin/binary>>);
                _ ->
                    error({no_match, Needle, Acc})
            end
    end.

line_end(Acc, Needle) ->
    case binary:match(Acc, Needle) of
        {Pos, Len} ->
            From = Pos + Len,
            case binary:match(Acc, <<"\r\n">>, [{scope, {From, byte_size(Acc) - From}}]) of
                {E, 2} -> {ok, E + 2};
                nomatch -> nomatch
            end;
        nomatch ->
            nomatch
    end.

wait_closed(Sock) ->
    case gen_tcp:recv(Sock, 0, 3000) of
        {ok, _} -> wait_closed(Sock);
        {error, closed} -> closed;
        {error, Reason} -> Reason
    end.

wait_until(Fun) ->
    wait_until(Fun, 60).

wait_until(Fun, 0) ->
    ?assert(Fun());
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, N - 1)
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.
