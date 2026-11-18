-module(ircd_ircv3_tests).
-include_lib("eunit/include/eunit.hrl").

%% Live capability negotiation, message tags, TAGMSG, labeled responses, and one link.

ircv3_test_() ->
    {timeout, 120, fun ircv3/0}.

ircv3() ->
    Dir = filename:join(
        "/tmp", "ircd-protocol-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(filename:join(Dir, "db"))),
    application:stop(ircd),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    Port = listener_port(),
    try
        registration_and_labels(Port),
        tags_and_link(Port),
        labeled_server_notice(Port)
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

registration_and_labels(Port) ->
    Alice = connect(Port),
    send(Alice, <<"CAP LS 302">>),
    Ls = collect(Alice),
    ?assert(has(Ls, <<"CAP * LS">>)),
    ?assert(has(Ls, <<"batch">>)),
    ?assert(has(Ls, <<"cap-notify">>)),
    ?assert(has(Ls, <<"labeled-response">>)),
    ?assert(has(Ls, <<"message-tags">>)),
    ?assertNot(has(Ls, <<"sasl">>)),
    ?assertNot(has(Ls, <<"LS *">>)),
    ?assertNot(has(Ls, <<" 001 ">>)),
    send(Alice, <<"CAP LIST">>),
    ?assert(has(collect(Alice), <<"cap-notify">>)),
    send(Alice, <<"CAP REQ :message-tags batch labeled-response">>),
    Ack = collect(Alice),
    ?assert(has(Ack, <<" ACK :message-tags batch labeled-response">>)),
    ?assertNot(has(Ack, <<" 001 ">>)),
    send(Alice, <<"CAP LS">>),
    Again = collect(Alice),
    ?assert(has(Again, <<"message-tags">>)),
    ?assert(has(Again, <<"cap-notify">>)),
    ?assertNot(has(Again, <<"LS *">>)),
    ?assertNot(has(Again, <<" 001 ">>)),
    send(Alice, <<"CAP REQ :-cap-notify">>),
    ?assert(has(collect(Alice), <<" NAK :-cap-notify">>)),
    send(Alice, <<"CAP LIST">>),
    Listed = collect(Alice),
    ?assert(has(Listed, <<"cap-notify">>)),
    ?assert(has(Listed, <<"message-tags">>)),
    send(Alice, <<"CAP REQ :message-tags sasl">>),
    ?assert(has(collect(Alice), <<" NAK :message-tags sasl">>)),
    send(Alice, <<"CAP LIST">>),
    ?assert(has(collect(Alice), <<"message-tags">>)),
    send(Alice, <<"NICK ann">>),
    send(Alice, <<"USER ann 0 * :Ann">>),
    ?assertNot(has(collect_quiet(Alice), <<" 001 ">>)),
    send(Alice, <<"CAP END">>),
    Welcome = collect(Alice),
    ?assert(has(Welcome, <<" 001 ">>)),
    send(Alice, <<"@label=end CAP END">>),
    ?assertEqual(<<>>, collect_quiet(Alice)),
    send(Alice, <<"CAP NOPE">>),
    ?assert(has(collect(Alice), <<" 410 ann NOPE ">>)),
    send(Alice, <<"@label=one PING xyz">>),
    Pong = collect(Alice),
    ?assertEqual(1, count_lines(Pong, <<"@label=one">>)),
    ?assert(has(Pong, <<"PONG">>)),
    ?assertNot(has(Pong, <<"BATCH">>)),
    send(Alice, <<"@label=two WHOIS ann">>),
    Who = collect(Alice),
    ?assertEqual(1, count_lines(Who, <<"@label=two">>)),
    ?assert(has(Who, <<"BATCH +">>)),
    ?assert(has(Who, <<"labeled-response">>)),
    ?assert(has(Who, <<"@batch=">>)),
    ?assert(has(Who, <<"BATCH -">>)),
    send(Alice, <<"@label=three PONG xyz">>),
    AckLine = collect(Alice),
    ?assert(has(AckLine, <<"@label=three">>)),
    ?assert(has(AckLine, <<" ACK">>)),
    ?assertNot(has(AckLine, <<"BATCH">>)),
    send(Alice, <<"@label=", (binary:copy(<<"a">>, 65))/binary, " PING long">>),
    Long = collect(Alice),
    ?assert(has(Long, <<"PONG">>)),
    ?assertNot(has(Long, <<"@label=">>)),
    ?assertNot(has(Long, <<"BATCH">>)),
    send(Alice, <<"@label= PING empty">>),
    Empty = collect(Alice),
    ?assert(has(Empty, <<"PONG">>)),
    ?assertNot(has(Empty, <<"@label=">>)),
    Tag417 = binary:copy(<<"b">>, 4095 - byte_size(<<"label=e417;">>)),
    send(Alice, <<"@label=e417;", Tag417/binary, " PING x">>),
    TooLong = collect(Alice),
    ?assert(has(TooLong, <<" 417 ">>)),
    ?assert(has(TooLong, <<"@label=e417">>)),
    send(Alice, <<"PING stay">>),
    ?assert(has(collect(Alice), <<"PONG">>)),
    Plain = connect(Port),
    send(Plain, <<"NICK plain">>),
    send(Plain, <<"USER plain 0 * :Plain">>),
    ?assert(has(collect(Plain), <<" 001 ">>)),
    send(Plain, <<"@label=zz PING abc">>),
    PlainPong = collect(Plain),
    ?assert(has(PlainPong, <<"PONG">>)),
    ?assertNot(has(PlainPong, <<"@label">>)),
    ?assertNot(has(PlainPong, <<"BATCH">>)),
    send(Plain, <<"@label=zz PONG abc">>),
    ?assertEqual(<<>>, collect_quiet(Plain)),
    send(Plain, <<"CAP LS">>),
    PlainLs = collect(Plain),
    ?assert(has(PlainLs, <<"batch">>)),
    ?assertNot(has(PlainLs, <<"LS *">>)),
    send(Plain, <<"CAP REQ :cap-notify">>),
    ?assert(has(collect(Plain), <<" ACK :cap-notify">>)),
    send(Plain, <<"CAP REQ :-cap-notify">>),
    ?assert(has(collect(Plain), <<" ACK :-cap-notify">>)),
    send(Plain, <<"CAP LIST">>),
    ?assertNot(has(collect(Plain), <<"cap-notify">>)),
    Legacy = connect(Port),
    send(Legacy, <<":evil PRIVMSG #room :x">>),
    ?assertMatch({error, closed}, gen_tcp:recv(Legacy, 0, 500)),
    Spoof = connect(Port),
    send(Spoof, <<"@+a=b :evil PRIVMSG #room :x">>),
    ?assertMatch({error, closed}, gen_tcp:recv(Spoof, 0, 500)),
    gen_tcp:close(Alice),
    gen_tcp:close(Plain).

tags_and_link(Port) ->
    Alice = negotiate(Port, <<"alice">>, <<"Alice">>),
    Bob = register_client(Port, <<"bob">>, <<"Bob">>),
    _ = collect(Bob),
    Carol = negotiate(Port, <<"carol">>, <<"Carol">>),
    lists:foreach(
        fun(Sock) ->
            send(Sock, <<"JOIN #room">>),
            _ = collect(Sock)
        end,
        [Alice, Bob, Carol]
    ),
    send(Alice, <<"@+demo=a\\:b;label=secret PRIVMSG #room :hi">>),
    CarolPriv = collect(Carol),
    ?assert(has(CarolPriv, <<"@+demo=a\\:b">>)),
    ?assert(has(CarolPriv, <<"PRIVMSG #room :hi">>)),
    ?assertNot(has(CarolPriv, <<"label=">>)),
    BobPriv = collect(Bob),
    ?assert(has(BobPriv, <<"PRIVMSG #room :hi">>)),
    ?assertNot(starts_with_tag(BobPriv)),
    send(Alice, <<"@+n=1;account=secret NOTICE #room :note">>),
    CarolNote = collect(Carol),
    ?assert(has(CarolNote, <<"@+n=1">>)),
    ?assert(has(CarolNote, <<"NOTICE #room :note">>)),
    ?assertNot(has(CarolNote, <<"account=">>)),
    ?assertNot(starts_with_tag(collect(Bob))),
    send(Alice, <<"@+flag=1;account=no TAGMSG #room">>),
    CarolTag = collect(Carol),
    ?assert(has(CarolTag, <<"@+flag=1">>)),
    ?assert(has(CarolTag, <<"TAGMSG #room">>)),
    ?assertNot(has(CarolTag, <<"account=">>)),
    ?assertNot(has(collect_quiet(Bob), <<"TAGMSG">>)),
    send(Bob, <<"@+demo=hidden PRIVMSG #room :frombob">>),
    FromBob = collect(Carol),
    ?assert(has(FromBob, <<"PRIVMSG #room :frombob">>)),
    ?assertNot(has(FromBob, <<"+demo">>)),
    ?assertNot(starts_with_tag(FromBob)),
    send(Alice, <<"@", (binary:copy(<<"k">>, 4095))/binary, " PRIVMSG #room :uniq417">>),
    ?assert(has(collect(Alice), <<" 417 ">>)),
    ?assertNot(has(collect_quiet(Carol), <<"uniq417">>)),
    ?assertNot(has(collect_quiet(Bob), <<"uniq417">>)),
    send(Alice, <<"PING after417">>),
    ?assert(has(collect(Alice), <<"PONG">>)),
    Drop = register_client(Port, <<"drop">>, <<"Drop">>),
    _ = collect(Drop),
    send(Drop, <<"PRIVMSG #room :", (binary:copy(<<"A">>, 600))/binary>>),
    ?assertMatch({error, closed}, gen_tcp:recv(Drop, 0, 500)),
    Peer = handshake(Port, <<"peer.test">>),
    _ = collect(Peer),
    send(Peer, <<":peer.test NICK remote 0 user peer.test 1 + :Remote">>),
    send(Peer, <<":remote!user@peer.test JOIN #room">>),
    _ = collect(Alice),
    _ = collect(Carol),
    _ = collect(Bob),
    _ = collect_quiet(Peer),
    send(Alice, <<"@+demo=keep;label=no PRIVMSG #room :fromlocal">>),
    ToPeer = collect(Peer),
    ?assert(has(ToPeer, <<"@+demo=keep">>)),
    ?assert(has(ToPeer, <<"PRIVMSG #room :fromlocal">>)),
    ?assertNot(has(ToPeer, <<"label=">>)),
    send(Bob, <<"@+demo=hidden2 PRIVMSG #room :boblocal">>),
    BobToPeer = collect(Peer),
    ?assert(has(BobToPeer, <<"PRIVMSG #room :boblocal">>)),
    ?assertNot(has(BobToPeer, <<"+demo">>)),
    send(Peer, <<"@+demo=back;label=no :remote!user@peer.test PRIVMSG #room :frompeer">>),
    FromPeer = collect(Carol),
    ?assert(has(FromPeer, <<"@+demo=back">>)),
    ?assert(has(FromPeer, <<"PRIVMSG #room :frompeer">>)),
    ?assertNot(has(FromPeer, <<"label=">>)),
    BobFromPeer = collect(Bob),
    ?assert(has(BobFromPeer, <<"PRIVMSG #room :frompeer">>)),
    ?assertNot(starts_with_tag(BobFromPeer)),
    send(Alice, <<"@+flag=9;account=no TAGMSG #room">>),
    PeerTag = collect(Peer),
    ?assert(has(PeerTag, <<"@+flag=9">>)),
    ?assert(has(PeerTag, <<"TAGMSG #room">>)),
    ?assertNot(has(PeerTag, <<"account=">>)),
    send(Peer, <<"@+flag=8;label=no :remote!user@peer.test TAGMSG #room">>),
    CarolRemoteTag = collect(Carol),
    ?assert(has(CarolRemoteTag, <<"@+flag=8">>)),
    ?assert(has(CarolRemoteTag, <<"TAGMSG">>)),
    ?assertNot(has(CarolRemoteTag, <<"label=">>)),
    ?assertNot(has(collect_quiet(Bob), <<"TAGMSG">>)),
    gen_tcp:close(Alice),
    gen_tcp:close(Bob),
    gen_tcp:close(Carol),
    gen_tcp:close(Peer).

labeled_server_notice(Port) ->
    Oper = negotiate(Port, <<"oper">>, <<"Oper">>),
    send(Oper, <<"OPER oper opersecret">>),
    ?assert(has(collect(Oper), <<" 381 ">>)),
    send(Oper, <<"@label=conn CONNECT peer.test">>),
    Connected = collect(Oper),
    ?assertEqual(1, count_lines(Connected, <<"@label=conn">>)),
    ?assert(has(Connected, <<"NOTICE oper :Connect attempt for peer.test">>)),
    ?assertNot(has(Connected, <<" ACK">>)),
    ?assertNot(has(Connected, <<"BATCH">>)),
    Peer = handshake(Port, <<"peer.test">>),
    _ = collect_quiet(Oper),
    send(Oper, <<"@label=sq SQUIT peer.test">>),
    Squitted = collect(Oper),
    ?assertEqual(1, count_lines(Squitted, <<"@label=sq">>)),
    ?assert(has(Squitted, <<"NOTICE oper :SQUIT peer.test">>)),
    ?assertNot(has(Squitted, <<" ACK">>)),
    ?assertNot(has(Squitted, <<"BATCH">>)),
    send(Oper, <<"@label=me PRIVMSG oper :echo">>),
    Echo = collect(Oper),
    EchoLines = [Line || Line <- binary:split(Echo, <<"\r\n">>, [global]), Line =/= <<>>],
    Priv = [Line || Line <- EchoLines, has(Line, <<"PRIVMSG oper :echo">>)],
    Acks = [Line || Line <- EchoLines, has(Line, <<" ACK">>)],
    ?assertEqual(1, length(Priv)),
    ?assertNot(has(hd(Priv), <<"label=">>)),
    ?assertEqual(1, length(Acks)),
    ?assert(has(hd(Acks), <<"@label=me">>)),
    gen_tcp:close(Peer),
    gen_tcp:close(Oper).

negotiate(Port, Nick, Real) ->
    Sock = connect(Port),
    send(Sock, <<"CAP LS 302">>),
    _ = collect(Sock),
    send(Sock, <<"CAP REQ :message-tags batch labeled-response">>),
    _ = collect(Sock),
    send(Sock, <<"CAP END">>),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :", Real/binary>>),
    Welcome = collect(Sock),
    ?assert(has(Welcome, <<" 001 ">>)),
    Sock.

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
        <<"\"server_links\":[">>,
        <<"{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false}]">>,
        <<"}">>
    ]).

handshake(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    Hello = collect(Sock),
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

collect(Sock) ->
    collect(Sock, <<>>, 0, true).

collect_quiet(Sock) ->
    collect(Sock, <<>>, 0, false).

collect(Sock, Acc, N, Wait) when N < 40 ->
    Timeout =
        case {Wait, Acc} of
            {true, <<>>} -> 200;
            _ -> 80
        end,
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Bin} ->
            collect(Sock, <<Acc/binary, Bin/binary>>, N + 1, Wait);
        {error, timeout} when Wait, Acc =:= <<>>, N < 15 ->
            collect(Sock, Acc, N + 1, Wait);
        {error, timeout} ->
            Acc;
        {error, closed} ->
            Acc
    end;
collect(_Sock, Acc, _, _) ->
    Acc.

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

starts_with_tag(Bin) ->
    lists:any(
        fun
            (<<$@, _/binary>>) -> true;
            (_) -> false
        end,
        binary:split(Bin, <<"\r\n">>, [global])
    ).

count_lines(Bin, Needle) ->
    length([Line || Line <- binary:split(Bin, <<"\r\n">>, [global]), has(Line, Needle)]).
