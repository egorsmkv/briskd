-module(ircd_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

%% Live registration, channel limits, restart persistence, and a two-hop link.
%% Two peer sockets speak RFC 2813. One node cannot register two ircd_state
%% processes, so the leaf server is introduced by the first peer.

protocol_test_() ->
    {timeout, 120, fun protocol/0}.

retention_test_() ->
    {timeout, 60, fun retention/0}.

rejected_retention_test_() ->
    {timeout, 30, fun rejected_retention/0}.

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

link_and_restart(Port, Bob, Dir, _Config) ->
    Peer = handshake(Port, <<"peer.test">>),
    Other = handshake(Port, <<"other.test">>),
    _ = recv(Peer),
    _ = recv(Other),
    send(Peer, <<"PING peer.test">>),
    ?assert(has(recv(Peer), <<"PONG">>)),
    send(Peer, <<":peer.test SERVER leaf.test 2 2 :leaf">>),
    send(Peer, <<":leaf.test NICK remote 1 user leaf.test 2 + :Remote">>),
    Introduced = recv(Other),
    ?assertEqual(1, count(Introduced, <<"NICK remote">>)),
    ?assert(has(Introduced, <<"SERVER leaf.test">>)),
    IngressEcho = recv_quiet(Peer),
    ?assertNot(has(IngressEcho, <<"NICK remote">>)),
    ?assertNot(has(IngressEcho, <<"SERVER leaf.test">>)),
    send(Peer, <<":peer.test NICK direct 0 user peer.test 1 + :Direct">>),
    send(Peer, <<":peer.test SERVICE helper * *.test 0 * :Help">>),
    _ = recv(Other),
    timer:sleep(300),
    ?assertEqual(
        {[<<"direct">>, <<"remote">>], [<<"leaf.test">>, <<"other.test">>, <<"peer.test">>]},
        {
            lists:sort(mnesia:dirty_all_keys(remote_client)),
            lists:sort(mnesia:dirty_all_keys(known_server))
        }
    ),
    send(Bob, <<"PART #c1">>),
    _ = recv(Bob),
    send(Bob, <<"JOIN #room">>),
    _ = recv(Bob),
    _ = recv(Peer),
    _ = recv(Other),
    send(Peer, <<":remote!user@leaf.test JOIN #room">>),
    Joined = recv(Other),
    ?assertEqual(1, count(Joined, <<"JOIN #room">>)),
    ?assertNot(has(recv_quiet(Peer), <<"JOIN #room">>)),
    send(Other, <<":other.test NICK side 0 user other.test 3 + :Side">>),
    SideNick = recv(Peer),
    ?assertEqual(1, count(SideNick, <<"NICK side">>)),
    ?assertNot(has(recv_quiet(Other), <<"NICK side">>)),
    send(Other, <<":side!user@other.test JOIN #room">>),
    _ = recv(Peer),
    %% Prefix is the leaf, not the adjacent link. The next hop must still accept it.
    send(Peer, <<":leaf.test MODE #room +o remote">>),
    Mode = recv(Other),
    ?assertEqual(1, count(Mode, <<"MODE #room +o remote">>)),
    ?assert(has(Mode, <<":leaf.test MODE">>)),
    ?assertNot(has(recv_quiet(Peer), <<"MODE #room +o remote">>)),
    send(Peer, <<":leaf.test TOPIC #room :from-leaf">>),
    Topic = recv(Other),
    ?assert(has(Topic, <<"TOPIC #room">>)),
    ?assert(has(Topic, <<"from-leaf">>)),
    ?assertNot(has(recv_quiet(Peer), <<"from-leaf">>)),
    send(Peer, <<":remote!user@leaf.test KICK #room side :out">>),
    Kick = recv(Other),
    ?assertEqual(1, count(Kick, <<"KICK #room side">>)),
    ?assertNot(has(recv_quiet(Peer), <<"KICK #room side">>)),
    send(Bob, <<"WHOIS remote">>),
    Whois = recv(Bob),
    ?assert(has(Whois, <<" 312 ">>)),
    ?assert(has(Whois, <<"remote leaf.test">>)),
    ?assertNot(has(Whois, <<"remote peer.test">>)),
    send(Bob, <<"WHO remote">>),
    Who = recv(Bob),
    ?assert(has(Who, <<"leaf.test remote">>)),
    ?assertNot(has(Who, <<"peer.test remote">>)),
    send(Peer, <<":leaf.test NICK side 1 user leaf.test 2 + :Clash">>),
    PeerKill = recv(Peer),
    OtherKill = recv(Other),
    ?assert(has(PeerKill, <<"KILL side">>)),
    ?assert(has(OtherKill, <<"KILL side">>)),
    ?assert(has(OtherKill, <<"QUIT">>)),
    send(Bob, <<"INVITE remote #room">>),
    Invite = recv(Peer),
    ?assert(has(Invite, <<"INVITE remote #room">>)),
    ?assertNot(has(recv_quiet(Other), <<"INVITE remote #room">>)),
    send(Bob, <<"PRIVMSG remote :hello-hop">>),
    Routed = recv(Peer),
    ?assertEqual(1, count(Routed, <<"hello-hop">>)),
    ?assertNot(has(recv_quiet(Other), <<"hello-hop">>)),
    send(Peer, <<":remote!user@leaf.test PRIVMSG bob :from-leaf">>),
    ?assert(has(recv(Bob), <<"from-leaf">>)),
    Echo = recv_quiet(Peer),
    ?assertNot(has(Echo, <<"from-leaf">>)),
    send(Bob, <<"SERVLIST">>),
    ?assert(has(recv(Bob), <<" 234 ">>)),
    send(Bob, <<"SQUERY helper :ping">>),
    ?assert(has(recv(Peer), <<"SQUERY helper :ping">>)),
    send(Peer, <<":remote!user@leaf.test JOIN #leafonly">>),
    LeafJoin = recv(Other),
    ?assertEqual(1, count(LeafJoin, <<"JOIN #leafonly">>)),
    ?assertNot(has(recv_quiet(Peer), <<"JOIN #leafonly">>)),
    _ = recv_quiet(Other),
    send(Peer, <<":peer.test SQUIT leaf.test :split">>),
    Split = recv(Other),
    ?assertEqual(1, count(Split, <<"SQUIT leaf.test">>)),
    ?assertNot(has(recv_quiet(Peer), <<"SQUIT leaf.test">>)),
    timer:sleep(200),
    ?assertNot(lists:member(<<"remote">>, mnesia:dirty_all_keys(remote_client))),
    ?assertNot(lists:member(<<"leaf.test">>, mnesia:dirty_all_keys(known_server))),
    ?assertNot(lists:member(<<"#leafonly">>, mnesia:dirty_all_keys(remote_channel))),
    send(Bob, <<"WHOIS remote">>),
    ?assert(has(recv(Bob), <<" 401 ">>)),
    send(Bob, <<"WHOIS direct">>),
    ?assert(has(recv(Bob), <<" 311 ">>)),
    gen_tcp:close(Peer),
    timer:sleep(300),
    send(Bob, <<"WHOIS direct">>),
    ?assert(has(recv(Bob), <<" 401 ">>)),
    gen_tcp:close(Other),
    gen_tcp:close(Bob),
    %% Default retention: the config omits the key, so WHOWAS and the safe
    %% channel return and the ordinary channel does not.
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
    restore_from_backup(Dir).

%% Exercise the operator backup and restore procedure, then the normal startup
%% rules: WHOWAS and the safe channel come back, and the ordinary channel does not.
restore_from_backup(Dir) ->
    Backup = filename:join(Dir, "state.bak"),
    ok = mnesia:backup(Backup),
    ok = application:stop(ircd),
    _ = application:stop(mnesia),
    Restored = filename:join(Dir, "restored"),
    ok = filelib:ensure_dir(filename:join(Restored, "schema.DAT")),
    ok = application:set_env(mnesia, dir, Restored),
    ok = mnesia:create_schema([node()]),
    {ok, _} = application:ensure_all_started(mnesia),
    {atomic, _} = mnesia:restore(Backup, [{default_op, recreate_tables}]),
    ok = application:stop(mnesia),
    RestoredConfig = filename:join(Dir, "restored.json"),
    ok = file:write_file(RestoredConfig, config(Restored)),
    os:putenv("IRCD_CONFIG", RestoredConfig),
    {ok, _} = application:ensure_all_started(ircd),
    Port = listener_port(),
    Dave = register_client(Port, <<"dave">>, <<"Dave">>),
    ?assert(has(recv(Dave), <<" 001 ">>)),
    send(Dave, <<"WHOWAS alice">>),
    ?assert(has(recv(Dave), <<" 314 ">>)),
    send(Dave, <<"JOIN !room">>),
    Rejoined = recv(Dave),
    ?assert(has(Rejoined, <<" 332 ">>)),
    ?assert(has(Rejoined, <<"kept">>)),
    send(Dave, <<"JOIN #ordinary">>),
    Ordinary = recv(Dave),
    ?assert(has(Ordinary, <<" 331 ">>)),
    ?assertNot(has(Ordinary, <<"temp">>)),
    gen_tcp:close(Dave).

%% `channels` retention keeps an ordinary channel, its modes, and a bounded
%% PRIVMSG/NOTICE history. Sessions, operator mode, and peer rows do not.
retention() ->
    Dir = filename:join(
        "/tmp", "ircd-retention-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Db = filename:join(Dir, "db"),
    Config = filename:join(Dir, "ircd.json"),
    Extra = <<"\"retention\":\"channels\",\"history_limit\":2,">>,
    ok = file:write_file(Config, config(Db, Extra)),
    os:putenv("IRCD_CONFIG", Config),
    logger:remove_primary_filter(retention_bodies),
    ok = logger:add_primary_filter(retention_bodies, {fun retention_log/2, self()}),
    {ok, _} = application:ensure_all_started(ircd),
    try
        Port = listener_port(),
        Alice = register_client(Port, <<"alice">>, <<"Alice">>),
        ?assert(has(recv(Alice), <<" 001 ">>)),
        send(Alice, <<"OPER oper opersecret">>),
        ?assert(has(recv(Alice), <<" 381 ">>)),
        send(Alice, <<"JOIN #kept">>),
        _ = recv(Alice),
        send(Alice, <<"TOPIC #kept :kept-topic">>),
        _ = recv(Alice),
        send(Alice, <<"MODE #kept +t">>),
        _ = recv(Alice),
        send(Alice, <<"MODE #kept +k secret">>),
        _ = recv(Alice),
        send(Alice, <<"MODE #kept +l 1">>),
        _ = recv(Alice),
        send(Alice, <<"MODE #kept +b banned!*@*">>),
        _ = recv(Alice),
        send(Alice, <<"PRIVMSG #kept :hist-old">>),
        send(Alice, <<"NOTICE #kept :hist-mid">>),
        send(Alice, <<"PRIVMSG #kept :hist-new">>),
        _ = recv_quiet(Alice),
        Peer = handshake(Port, <<"peer.test">>),
        send(Peer, <<":peer.test NICK remote 0 user peer.test 1 + :Remote">>),
        timer:sleep(200),
        ?assert(lists:member(<<"remote">>, mnesia:dirty_all_keys(remote_client))),
        gen_tcp:close(Alice),
        gen_tcp:close(Peer),
        timer:sleep(200),
        ok = application:stop(ircd),
        {ok, _} = application:ensure_all_started(ircd),
        ?assertEqual([], mnesia:dirty_all_keys(remote_client)),
        ?assertEqual([], mnesia:dirty_all_keys(remote_channel)),
        ?assertEqual([], mnesia:dirty_all_keys(known_server)),
        ?assertEqual([], mnesia:dirty_all_keys(service)),
        ?assertEqual([], mnesia:dirty_all_keys(client)),
        ?assertEqual([], mnesia:dirty_all_keys(user_modes)),
        Again = listener_port(),
        Carol = register_client(Again, <<"carol">>, <<"Carol">>),
        ?assert(has(recv(Carol), <<" 001 ">>)),
        send(Carol, <<"WHOWAS alice">>),
        History = recv(Carol),
        ?assert(has(History, <<" 314 ">>)),
        ?assert(has(History, <<"alice">>)),
        send(Carol, <<"WHOIS alice">>),
        ?assert(has(recv(Carol), <<" 401 ">>)),
        send(Carol, <<"WHOIS carol">>),
        ?assertNot(has(recv(Carol), <<" 313 ">>)),
        send(Carol, <<"KILL carol :no">>),
        ?assert(has(recv(Carol), <<" 481 ">>)),
        send(Carol, <<"JOIN #kept">>),
        ?assert(has(recv(Carol), <<" 475 ">>)),
        Banned = register_client(Again, <<"banned">>, <<"Banned">>),
        ?assert(has(recv(Banned), <<" 001 ">>)),
        send(Banned, <<"JOIN #kept secret">>),
        ?assert(has(recv(Banned), <<" 474 ">>)),
        send(Carol, <<"JOIN #kept secret">>),
        Joined = recv(Carol),
        ?assert(has(Joined, <<" 332 ">>)),
        ?assert(has(Joined, <<"kept-topic">>)),
        ?assertNot(has(Joined, <<"hist-old">>)),
        ?assert(has(Joined, <<"NOTICE #kept :hist-mid">>)),
        ?assert(has(Joined, <<"PRIVMSG #kept :hist-new">>)),
        assert_before(Joined, <<"hist-mid">>, <<"hist-new">>),
        ?assert(has(Joined, <<"= #kept :carol">>)),
        ?assertNot(has(Joined, <<"@carol">>)),
        send(Carol, <<"MODE #kept">>),
        Modes = recv(Carol),
        ?assert(has(Modes, <<" 324 ">>)),
        ?assert(has(Modes, <<"+tkl">>)),
        ?assert(has(Modes, <<"secret 1">>)),
        send(Carol, <<"TOPIC #kept :changed">>),
        ?assert(has(recv(Carol), <<" 482 ">>)),
        Dave = register_client(Again, <<"dave">>, <<"Dave">>),
        ?assert(has(recv(Dave), <<" 001 ">>)),
        send(Dave, <<"JOIN #kept secret">>),
        ?assert(has(recv(Dave), <<" 471 ">>)),
        assert_bodies_unlogged([<<"hist-old">>, <<"hist-mid">>, <<"hist-new">>]),
        gen_tcp:close(Carol),
        gen_tcp:close(Banned),
        gen_tcp:close(Dave)
    after
        logger:remove_primary_filter(retention_bodies),
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

rejected_retention() ->
    Dir = filename:join(
        "/tmp", "ircd-retention-bad-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(
        Config,
        config(filename:join(Dir, "db"), <<"\"retention\":\"forever\",">>)
    ),
    os:putenv("IRCD_CONFIG", Config),
    try
        ?assertMatch(
            {error, {ircd, {{invalid_config, _, {invalid_retention, <<"forever">>}}, _}}},
            application:ensure_all_started(ircd)
        )
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

retention_log(Event, Pid) ->
    Pid ! {retention_log, Event},
    Event.

assert_bodies_unlogged(Tokens) ->
    Rendered = iolist_to_binary(io_lib:format("~0tp", [drain_logs([])])),
    lists:foreach(fun(Token) -> ?assertNot(has(Rendered, Token)) end, Tokens).

drain_logs(Acc) ->
    receive
        {retention_log, Event} -> drain_logs([Event | Acc])
    after 0 -> Acc
    end.

assert_before(Bin, Left, Right) ->
    {LeftAt, _} = binary:match(Bin, Left),
    {RightAt, _} = binary:match(Bin, Right),
    ?assert(LeftAt < RightAt).

config(Db) ->
    config(Db, <<>>).

config(Db, Extra) ->
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
        Extra,
        <<"\"operators\":[{\"name\":\"oper\",\"password\":\"opersecret\"}],">>,
        <<"\"server_links\":[">>,
        <<"{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false},">>,
        <<"{\"name\":\"other.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false}]">>,
        <<"}">>
    ]).

handshake(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    Hello = recv(Sock),
    ?assert(has(Hello, <<"SERVER irc.test">>)),
    Sock.

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
