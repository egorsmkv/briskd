-module(ircd_call_link_tests).
-include_lib("eunit/include/eunit.hrl").

%% Voice calls between users on two linked servers: two ircd OS processes
%% (alpha and beta) linked over RFC 2813 TCP, each with its own fake
%% rtpengine. The caller's server (alpha) anchors the media: only its
%% rtpengine sees offer, answer, and delete; beta relays.

-define(CAP, <<"egorsmkv.github.io/calls">>).

call_link_test_() ->
    {timeout, 240, fun run/0}.

run() ->
    Base = filename:join(
        "/tmp", "ircd-call-link-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    NgA = start_fake_ng(self(), alpha),
    NgB = start_fake_ng(self(), beta),
    [PortA, PortB] = free_ports(2),
    A = start_node(Base, "alpha", PortA, ng_port(NgA), [{<<"beta.test">>, PortB}]),
    B = start_node(Base, "beta", PortB, ng_port(NgB), [{<<"alpha.test">>, 1}]),
    try
        ok = wait_listening(PortA),
        ok = wait_listening(PortB),
        scenario(PortA, PortB)
    after
        stop_node(A),
        stop_node(B),
        NgA ! stop,
        NgB ! stop,
        %% Node output and fake rtpengine reports must not reach the next
        %% test, which runs in this process.
        flush()
    end.

flush() ->
    receive
        {Port, _} when is_port(Port) -> flush();
        {ng, _, _, _} -> flush()
    after 200 -> ok
    end.

scenario(PortA, PortB) ->
    Alice = client(PortA, <<"alice">>, ?CAP),
    Bob = client(PortB, <<"bob">>, ?CAP),
    Carol = client(PortB, <<"carol">>, <<"message-tags">>),
    ok = wait_until(fun() ->
        send(Alice, <<"WHOIS carol">>),
        has(collect(Alice), <<" 311 alice carol ">>)
    end),

    %% The far server refuses a user whose client cannot take calls.
    send_sdp(Alice, <<"OFFER">>, <<"carol">>, <<"tokcarol1">>, sdp(<<"audio">>)),
    ?assertMatch({alpha, offer, _}, ng_recv()),
    ?assert(
        has(
            wait_for(Alice, <<"FAIL CALL TARGET_UNSUPPORTED tokcarol1">>),
            <<"FAIL CALL TARGET_UNSUPPORTED tokcarol1">>
        )
    ),
    ?assertMatch({alpha, delete, _}, ng_recv()),
    _ = collect(Carol),

    %% Offer: alpha's rtpengine rewrites it; bob sees alice's prefix.
    Offer = <<(sdp(<<"audio">>))/binary, (binary:copy(<<"a=x-pad:1\r\n">>, 40))/binary>>,
    send_sdp(Alice, <<"OFFER">>, <<"bob">>, <<"tokbob001">>, Offer),
    {alpha, offer, OfferMsg} = ng_recv(),
    ?assertEqual(Offer, maps:get(<<"sdp">>, OfferMsg)),
    BobOffer = wait_for(Bob, <<"CALL OFFER bob tokbob001">>, fun sdp_complete/1),
    ?assert(has(BobOffer, <<":alice!">>)),
    ?assertEqual(fake_sdp(<<"alpha-offer">>), sdp_of(BobOffer, <<"OFFER">>)),

    %% Ringing, then the answer through alpha's rtpengine.
    send(Bob, <<"CALL RINGING alice tokbob001">>),
    ?assert(has(wait_for(Alice, <<"CALL RINGING alice tokbob001">>), <<":bob!">>)),
    Answer = sdp(<<"audio">>),
    send_sdp(Bob, <<"ANSWER">>, <<"alice">>, <<"tokbob001">>, Answer),
    {alpha, answer, AnswerMsg} = ng_recv(),
    ?assertEqual(Answer, maps:get(<<"sdp">>, AnswerMsg)),
    ?assertEqual(maps:get(<<"call-id">>, OfferMsg), maps:get(<<"call-id">>, AnswerMsg)),
    AliceAnswer = wait_for(Alice, <<"CALL ANSWER alice tokbob001">>, fun sdp_complete/1),
    ?assertEqual(fake_sdp(<<"alpha-answer">>), sdp_of(AliceAnswer, <<"ANSWER">>)),

    %% Hold crosses the link; a nick change does not end the call.
    send(Alice, <<"CALL HOLD bob tokbob001">>),
    ?assert(has(wait_for(Bob, <<"CALL HOLD bob tokbob001">>), <<":alice!">>)),
    send(Bob, <<"NICK bobby">>),
    ok = wait_until(fun() ->
        send(Alice, <<"WHOIS bobby">>),
        has(collect(Alice), <<" 311 alice bobby ">>)
    end),
    send(Alice, <<"CALL RESUME bobby tokbob001">>),
    ?assert(has(wait_for(Bob, <<"CALL RESUME bobby tokbob001">>), <<":alice!">>)),
    send(Bob, <<"CALL HANGUP alice tokbob001 :normal">>),
    ?assert(has(wait_for(Alice, <<"CALL HANGUP alice tokbob001">>), <<":bobby!">>)),
    ?assertMatch({alpha, delete, _}, ng_recv()),

    %% The callee quits while ringing: alice's server ends the call.
    send_sdp(Alice, <<"OFFER">>, <<"bobby">>, <<"tokbob002">>, Offer),
    ?assertMatch({alpha, offer, _}, ng_recv()),
    _ = wait_for(Bob, <<"CALL OFFER bobby tokbob002">>, fun sdp_complete/1),
    send(Bob, <<"QUIT :bye">>),
    ?assert(
        has(
            wait_for(Alice, <<"CALL HANGUP alice tokbob002">>),
            <<":alpha.test CALL HANGUP alice tokbob002 :disconnected">>
        )
    ),
    ?assertMatch({alpha, delete, _}, ng_recv()),

    %% beta never used its rtpengine: it only relayed.
    receive
        {ng, beta, Cmd, _} -> erlang:error({beta_used_rtpengine, Cmd})
    after 500 -> ok
    end,
    lists:foreach(fun gen_tcp:close/1, [Alice, Bob, Carol]).

%%% Session descriptions

sdp(Media) ->
    <<"v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=", Media/binary,
        " 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\n">>.

fake_sdp(Marker) ->
    <<(sdp(<<"audio">>))/binary, "a=", Marker/binary, "\r\n">>.

send_sdp(Sock, Kind, Nick, Token, Sdp) ->
    Chunks = ircd_call_proto:chunks(Sdp),
    Total = integer_to_binary(length(Chunks)),
    lists:foreach(
        fun({N, Chunk}) ->
            send(
                Sock,
                iolist_to_binary([
                    <<"CALL ">>,
                    Kind,
                    " ",
                    Nick,
                    " ",
                    Token,
                    " ",
                    integer_to_binary(N),
                    " ",
                    Total,
                    " :",
                    Chunk
                ])
            )
        end,
        lists:enumerate(Chunks)
    ).

sdp_of(Lines, Kind) ->
    Parts = [
        L
     || L <- binary:split(Lines, <<"\r\n">>, [global]),
        has(L, <<" CALL ", Kind/binary, " ">>)
    ],
    base64:decode(
        iolist_to_binary([lists:last(binary:split(P, <<" :">>, [global])) || P <- Parts])
    ).

sdp_complete(Lines) ->
    lists:any(
        fun(L) ->
            case
                re:run(L, <<" CALL (OFFER|ANSWER) \\S+ \\S+ (\\d+) (\\d+) :">>, [
                    {capture, [2, 3], binary}
                ])
            of
                {match, [N, N]} -> true;
                _ -> false
            end
        end,
        binary:split(Lines, <<"\r\n">>, [global])
    ).

%%% Fake rtpengine (one per server, tagged)

start_fake_ng(Test, Tag) ->
    Parent = self(),
    spawn(fun() ->
        {ok, S} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
        {ok, P} = inet:port(S),
        Parent ! {ng_port, self(), P},
        ng_loop(S, Test, Tag)
    end).

ng_port(Pid) ->
    receive
        {ng_port, Pid, P} -> P
    after 5000 -> error(ng_not_started)
    end.

ng_loop(S, Test, Tag) ->
    receive
        stop ->
            gen_udp:close(S);
        {udp, S, Ip, Port, Packet} ->
            [Cookie, Body] = binary:split(Packet, <<" ">>),
            {ok, #{<<"command">> := <<_/binary>> = Cmd} = Msg} = ircd_bencode:decode(Body),
            Test ! {ng, Tag, binary_to_atom(Cmd), Msg},
            Marker = <<(atom_to_binary(Tag))/binary, "-", Cmd/binary>>,
            Reply =
                case Cmd of
                    <<"delete">> -> #{result => ok};
                    _ -> #{result => ok, sdp => fake_sdp(Marker)}
                end,
            ok = gen_udp:send(S, Ip, Port, [Cookie, " ", ircd_bencode:encode(Reply)]),
            ng_loop(S, Test, Tag)
    end.

ng_recv() ->
    receive
        {ng, Tag, Cmd, Msg} -> {Tag, Cmd, Msg}
    after 10000 -> error(no_ng_request)
    end.

%%% External nodes

start_node(Base, Name, Port, NgPort, Links) ->
    Dir = filename:join(Base, Name),
    ok = filelib:ensure_dir(filename:join([Dir, "db", "x"])),
    Config = filename:join(Dir, "ircd.json"),
    LinkJson = lists:join(<<",">>, [
        [
            <<"{\"name\":\"">>,
            Peer,
            <<"\",\"host\":\"127.0.0.1\",\"port\":">>,
            integer_to_binary(PeerPort),
            <<",\"password\":\"linkpass\",\"tls\":false}">>
        ]
     || {Peer, PeerPort} <- Links
    ]),
    ok = file:write_file(
        Config,
        iolist_to_binary([
            <<"{\"name\":\"">>,
            Name,
            <<".test\",\"bind\":\"127.0.0.1\",\"tcp_port\":">>,
            integer_to_binary(Port),
            <<",\"log_level\":\"error\",\"log_format\":\"text\",">>,
            <<"\"calls\":{\"rtpengine\":\"127.0.0.1:">>,
            integer_to_binary(NgPort),
            <<"\",\"ring_timeout\":30},\"mnesia_dir\":\"">>,
            filename:join(Dir, "db"),
            <<"\",\"server_links\":[">>,
            LinkJson,
            <<"]}">>
        ])
    ),
    Erl = os:find_executable("erl"),
    Paths = lists:append([["-pa", P] || P <- code:get_path(), lists:prefix("/workspace", P)]),
    erlang:open_port({spawn_executable, Erl}, [
        {args,
            ["-noshell", "-noinput" | Paths] ++
                ["-eval", "{ok, _} = application:ensure_all_started(ircd)."]},
        {env, [{"IRCD_CONFIG", Config}]},
        {cd, Dir},
        exit_status,
        use_stdio,
        stderr_to_stdout
    ]).

stop_node(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} when is_integer(OsPid) ->
            _ = os:cmd("kill " ++ integer_to_list(OsPid)),
            try
                port_close(Port)
            catch
                error:badarg -> ok
            end,
            ok;
        undefined ->
            ok
    end.

free_ports(N) ->
    Socks = [
        begin
            {ok, S} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
            S
        end
     || _ <- lists:seq(1, N)
    ],
    Ports = [element(2, inet:port(S)) || S <- Socks],
    lists:foreach(fun gen_tcp:close/1, Socks),
    Ports.

wait_listening(Port) ->
    wait_until(fun() ->
        case gen_tcp:connect("127.0.0.1", Port, [], 200) of
            {ok, S} ->
                gen_tcp:close(S),
                true;
            _ ->
                false
        end
    end).

wait_until(Fun) ->
    wait_until(Fun, 60).

wait_until(_Fun, 0) ->
    erlang:error(timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(500),
            wait_until(Fun, N - 1)
    end.

%%% Clients

client(Port, Nick, Caps) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    send(Sock, <<"CAP LS 302">>),
    send(Sock, <<"CAP REQ :", Caps/binary>>),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :Real">>),
    send(Sock, <<"CAP END">>),
    _ = wait_for(Sock, <<" 001 ">>),
    Sock.

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

collect(Sock) ->
    collect(Sock, <<>>, 0).

collect(Sock, Acc, N) when N < 80 ->
    Timeout =
        case Acc of
            <<>> -> 250;
            _ -> 150
        end,
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, <<_/binary>> = Bin} -> collect(Sock, <<Acc/binary, Bin/binary>>, N + 1);
        {error, timeout} when Acc =:= <<>>, N < 15 -> collect(Sock, Acc, N + 1);
        {error, _} -> Acc
    end;
collect(_Sock, Acc, _) ->
    Acc.

%% Read until `Needle` has arrived and `Done` holds on whole lines.
wait_for(Sock, Needle) ->
    wait_for(Sock, Needle, fun(_) -> true end).

wait_for(Sock, Needle, Done) ->
    wait_for(Sock, Needle, Done, 10).

wait_for(Sock, Needle, Done, Seconds) ->
    wait_for(Sock, Needle, Done, erlang:monotonic_time(millisecond) + Seconds * 1000, <<>>).

wait_for(Sock, Needle, Done, Deadline, Acc) ->
    case has(Acc, Needle) andalso Done(Acc) andalso binary:last(Acc) =:= $\n of
        true ->
            Acc;
        false ->
            Left = Deadline - erlang:monotonic_time(millisecond),
            case Left > 0 andalso gen_tcp:recv(Sock, 0, Left) of
                {ok, <<_/binary>> = Bin} ->
                    wait_for(Sock, Needle, Done, Deadline, <<Acc/binary, Bin/binary>>);
                _ ->
                    erlang:error({timeout_waiting_for, Needle, Acc})
            end
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.
