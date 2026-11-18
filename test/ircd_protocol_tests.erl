-module(ircd_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

%% Live registration, channel limits, restart persistence, and a two-hop link.
%% The second server is a socket that speaks RFC 2813; one node cannot register
%% two ircd_state processes.

protocol_test_() ->
    {timeout, 120, fun protocol/0}.

protocol() ->
    Dir = filename:join(
        "/tmp", "ircd-protocol-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(filename:join(Dir, "db"))),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    Port = listener_port(),
    try
        Alice = register_client(Port, <<"alice">>, <<"Alice">>),
        ?assert(has(recv(Alice), <<" 001 ">>)),
        send(Alice, <<"CAP REQ sasl">>),
        ?assert(has(recv(Alice), <<" NAK :sasl">>)),
        send(Alice, <<"CAP NOPE">>),
        ?assert(has(recv(Alice), <<" 410 ">>)),
        send(Alice, <<"SUMMON">>),
        ?assert(has(recv(Alice), <<" 445 ">>)),
        send(Alice, <<"USERS">>),
        ?assert(has(recv(Alice), <<" 446 ">>)),
        send(Alice, <<"JOIN !room">>),
        Joined = recv(Alice),
        ?assert(has(Joined, <<"JOIN !">>)),
        Safe = safe_name(Joined),
        send(Alice, <<"TOPIC ", Safe/binary, " :kept">>),
        _ = recv(Alice),
        send(Alice, <<"JOIN #ordinary">>),
        _ = recv(Alice),
        send(Alice, <<"TOPIC #ordinary :temp">>),
        _ = recv(Alice),
        send(Alice, <<"MODE #ordinary +t">>),
        _ = recv(Alice),
        send(Alice, <<"MODE #ordinary">>),
        ?assert(has(recv(Alice), <<" 324 ">>)),
        send(Alice, <<"QUIT :bye">>),
        gen_tcp:close(Alice),
        timer:sleep(200),
        Bob = connect(Port),
        send(Bob, <<"NICK alice">>),
        ?assert(has(recv(Bob), <<" 437 ">>)),
        send(Bob, <<"NICK bob">>),
        send(Bob, <<"USER bob 0 * :Bob">>),
        ?assert(has(recv(Bob), <<" 001 ">>)),
        lists:foreach(
            fun(N) ->
                Name = iolist_to_binary([<<"JOIN #c">>, integer_to_binary(N)]),
                send(Bob, Name),
                _ = recv(Bob)
            end,
            lists:seq(1, 10)
        ),
        send(Bob, <<"JOIN #overflow">>),
        ?assert(has(recv(Bob), <<" 405 ">>)),
        send(Bob, <<"DIE">>),
        ?assert(has(recv(Bob), <<" 481 ">>)),
        link_and_restart(Port, Bob, Dir, Config)
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

link_and_restart(Port, Bob, Dir, Config) ->
    Peer = connect(Port),
    send(Peer, <<"PASS linksecret 0210 |">>),
    send(Peer, <<"SERVER peer.test 1 1 :peer">>),
    Handshake = recv(Peer),
    ?assert(has(Handshake, <<"SERVER irc.test">>)),
    send(Peer, <<"PING peer.test">>),
    Pong = recv(Peer),
    ?assert(has(Pong, <<"PONG">>)),
    send(Peer, <<":peer.test SERVER leaf.test 2 2 :leaf">>),
    send(Peer, <<":leaf.test NICK remote 1 user leaf.test 2 + :Remote">>),
    send(Peer, <<":peer.test NICK direct 0 user peer.test 1 + :Direct">>),
    send(Peer, <<":peer.test SERVICE helper * *.test 0 * :Help">>),
    timer:sleep(300),
    ?assertEqual(
        {[<<"direct">>, <<"remote">>], [<<"leaf.test">>, <<"peer.test">>]},
        {
            lists:sort(mnesia:dirty_all_keys(remote_client)),
            lists:sort(mnesia:dirty_all_keys(known_server))
        }
    ),
    send(Bob, <<"PART #c1">>),
    _ = recv(Bob),
    send(Bob, <<"JOIN #room">>),
    _ = recv(Bob),
    send(Bob, <<"INVITE remote #room">>),
    Invite = recv(Peer),
    ?assert(has(Invite, <<"INVITE remote #room">>)),
    send(Bob, <<"PRIVMSG remote :hello-hop">>),
    Routed = recv(Peer),
    ?assertEqual(1, count(Routed, <<"hello-hop">>)),
    send(Peer, <<":remote!user@leaf.test PRIVMSG bob :from-leaf">>),
    ?assert(has(recv(Bob), <<"from-leaf">>)),
    Echo = recv_quiet(Peer),
    ?assertNot(has(Echo, <<"from-leaf">>)),
    send(Bob, <<"SERVLIST">>),
    ?assert(has(recv(Bob), <<" 234 ">>)),
    send(Bob, <<"SQUERY helper :ping">>),
    ?assert(has(recv(Peer), <<"SQUERY helper :ping">>)),
    send(Peer, <<":peer.test SQUIT leaf.test :split">>),
    timer:sleep(200),
    send(Bob, <<"WHOIS remote">>),
    ?assert(has(recv(Bob), <<" 401 ">>)),
    send(Bob, <<"WHOIS direct">>),
    ?assert(has(recv(Bob), <<" 311 ">>)),
    gen_tcp:close(Peer),
    timer:sleep(300),
    send(Bob, <<"WHOIS direct">>),
    ?assert(has(recv(Bob), <<" 401 ">>)),
    gen_tcp:close(Bob),
    ok = application:stop(ircd),
    {ok, _} = application:ensure_all_started(ircd),
    Again = listener_port(),
    Carol = register_client(Again, <<"carol">>, <<"Carol">>),
    send(Carol, <<"WHOWAS alice">>),
    History = recv(Carol),
    ?assert(has(History, <<" 314 ">>)),
    ?assert(has(History, <<"alice">>)),
    send(Carol, <<"JOIN !room">>),
    Rejoined = recv(Carol),
    ?assert(has(Rejoined, <<" 332 ">>)),
    ?assert(has(Rejoined, <<"kept">>)),
    send(Carol, <<"JOIN #ordinary">>),
    Ordinary = recv(Carol),
    ?assert(has(Ordinary, <<" 331 ">>)),
    ?assertNot(has(Ordinary, <<"temp">>)),
    gen_tcp:close(Carol),
    _ = Dir,
    _ = Config.

config(Db) ->
    iolist_to_binary([
        <<"{">>,
        <<"\"name\":\"irc.test\",">>,
        <<"\"bind\":\"127.0.0.1\",">>,
        <<"\"tcp_port\":0,">>,
        <<"\"tls_port\":null,">>,
        <<"\"log_level\":\"warning\",">>,
        <<"\"log_format\":\"text\",">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\",">>,
        <<"\"operators\":[{\"name\":\"oper\",\"password\":\"opersecret\"}],">>,
        <<"\"server_links\":[{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",">>,
        <<"\"port\":1,\"password\":\"linksecret\",\"tls\":false}]">>,
        <<"}">>
    ]).

register_client(Port, Nick, Real) ->
    Sock = connect(Port),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :", Real/binary>>),
    Sock.

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

recv(Sock) ->
    recv(Sock, <<>>, 0).

recv(Sock, Acc, Tries) when Tries < 20 ->
    case gen_tcp:recv(Sock, 0, 200) of
        {ok, Bin} -> recv(Sock, <<Acc/binary, Bin/binary>>, Tries + 1);
        {error, timeout} when Acc =/= <<>> -> Acc;
        {error, timeout} -> recv(Sock, Acc, Tries + 1);
        {error, closed} -> Acc
    end;
recv(_Sock, Acc, _) ->
    Acc.

recv_quiet(Sock) ->
    case gen_tcp:recv(Sock, 0, 150) of
        {ok, Bin} -> Bin;
        {error, _} -> <<>>
    end.

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

count(Bin, Needle) ->
    count(Bin, Needle, 0).

count(Bin, Needle, N) ->
    case binary:match(Bin, Needle) of
        nomatch ->
            N;
        {Start, Length} ->
            Rest = binary:part(Bin, Start + Length, byte_size(Bin) - Start - Length),
            count(Rest, Needle, N + 1)
    end.

safe_name(Bin) ->
    case binary:match(Bin, <<"JOIN !">>) of
        {Start, _} ->
            <<_:Start/binary, "JOIN ", Rest/binary>> = Bin,
            case binary:match(Rest, <<"\r\n">>) of
                {End, _} -> binary:part(Rest, 0, End);
                nomatch -> error(missing_safe_channel)
            end;
        nomatch ->
            error(missing_safe_channel)
    end.
