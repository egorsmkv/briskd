-module(ircd_call_tests).
-include_lib("eunit/include/eunit.hrl").

-define(CAP, "egorsmkv.github.io/calls").

%%% Bencode

bencode_roundtrip_test() ->
    Term = #{<<"a">> => 1, <<"b">> => [<<"x">>, -2, #{<<"c">> => <<>>}]},
    Encoded = iolist_to_binary(ircd_bencode:encode(Term)),
    ?assertEqual(<<"d1:ai1e1:bl1:xi-2ed1:c0:eee">>, Encoded),
    ?assertEqual({ok, Term}, ircd_bencode:decode(Encoded)),
    %% Atoms encode as strings and keys are sorted.
    ?assertEqual(
        <<"d1:a3:one1:bli1eee">>, iolist_to_binary(ircd_bencode:encode(#{b => [1], a => one}))
    ).

bencode_malformed_test() ->
    ?assertEqual(error, ircd_bencode:decode(<<"5:abc">>)),
    ?assertEqual(error, ircd_bencode:decode(<<"i12">>)),
    ?assertEqual(error, ircd_bencode:decode(<<"ixe">>)),
    ?assertEqual(error, ircd_bencode:decode(<<"d1:ae">>)),
    ?assertEqual(error, ircd_bencode:decode(<<"di1ei2ee">>)),
    ?assertEqual(error, ircd_bencode:decode(<<"le trailing">>)),
    Deep = iolist_to_binary([lists:duplicate(40, $l), lists:duplicate(40, $e)]),
    ?assertEqual(error, ircd_bencode:decode(Deep)).

%%% Protocol helpers

validation_test() ->
    ?assert(ircd_call_proto:valid_token(<<"abcd1234">>)),
    ?assertNot(ircd_call_proto:valid_token(<<"short">>)),
    ?assertNot(ircd_call_proto:valid_token(<<"has-dash1">>)),
    ?assertNot(ircd_call_proto:valid_token(binary:copy(<<"a">>, 33))),
    ?assertEqual({ok, 1, 1}, ircd_call_proto:parse_part(<<"1">>, <<"1">>)),
    ?assertEqual({ok, 40, 40}, ircd_call_proto:parse_part(<<"40">>, <<"40">>)),
    ?assertEqual(error, ircd_call_proto:parse_part(<<"0">>, <<"3">>)),
    ?assertEqual(error, ircd_call_proto:parse_part(<<"4">>, <<"3">>)),
    ?assertEqual(error, ircd_call_proto:parse_part(<<"1">>, <<"41">>)),
    ?assertEqual(error, ircd_call_proto:parse_part(<<"x">>, <<"1">>)),
    ?assert(ircd_call_proto:valid_chunk(<<"dj0wDQo=">>)),
    ?assertNot(ircd_call_proto:valid_chunk(<<"not base64!">>)),
    ?assertNot(ircd_call_proto:valid_chunk(binary:copy(<<"A">>, 401))),
    ?assertEqual(<<"busy">>, ircd_call_proto:reason(<<"busy">>)),
    ?assertEqual(<<"normal">>, ircd_call_proto:reason(<<"Bad Reason">>)),
    ?assertEqual(<<"normal">>, ircd_call_proto:reason(none)).

sdp_test() ->
    Audio = sdp(<<"audio">>),
    ?assertEqual({ok, Audio}, ircd_call_proto:decode_sdp(base64:encode(Audio))),
    ?assertEqual(
        {error, not_audio}, ircd_call_proto:decode_sdp(base64:encode(sdp(<<"video">>)))
    ),
    Mixed = <<Audio/binary, "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n">>,
    ?assertEqual({error, not_audio}, ircd_call_proto:decode_sdp(base64:encode(Mixed))),
    ?assertEqual({error, invalid_sdp}, ircd_call_proto:decode_sdp(base64:encode(<<"hello">>))),
    ?assertEqual({error, invalid_base64}, ircd_call_proto:decode_sdp(<<"!!">>)),
    Big = <<Audio/binary, (binary:copy(<<"a=x\r\n">>, 3000))/binary>>,
    ?assertEqual({error, too_large}, ircd_call_proto:decode_sdp(base64:encode(Big))),
    %% Chunks are at most 400 characters and join back to the description.
    Long = <<Audio/binary, (binary:copy(<<"a=ice-candidate-padding\r\n">>, 100))/binary>>,
    Chunks = ircd_call_proto:chunks(Long),
    ?assert(length(Chunks) > 1),
    ?assert(lists:all(fun(C) -> byte_size(C) =< 400 end, Chunks)),
    ?assertEqual(Long, base64:decode(iolist_to_binary(Chunks))).

%% A NUL or a CR that does not end a line could hide `m=video` from the
%% audio-only check, so both are refused.
sdp_line_ending_test() ->
    Audio = sdp(<<"audio">>),
    BareCr = <<Audio/binary, "a=x\rm=video 9 UDP/TLS/RTP/SAVPF 96\r\n">>,
    ?assertEqual({error, invalid_sdp}, ircd_call_proto:decode_sdp(base64:encode(BareCr))),
    Nul = <<Audio/binary, "a=x", 0, "\r\n">>,
    ?assertEqual({error, invalid_sdp}, ircd_call_proto:decode_sdp(base64:encode(Nul))),
    Lf = binary:replace(Audio, <<"\r\n">>, <<"\n">>, [global]),
    ?assertEqual({ok, Lf}, ircd_call_proto:decode_sdp(base64:encode(Lf))).

%% `string:uppercase/1` raises on invalid UTF-8; the wire helper must not.
upper_test() ->
    ?assertEqual(<<"HANGUP">>, ircd_wire:upper(<<"hangup">>)),
    ?assertEqual(<<"OFFER", 255, "X">>, ircd_wire:upper(<<"offer", 255, "x">>)),
    ?assertEqual(<<"SCRAM-SHA-256">>, ircd_wire:upper(<<"scram-sha-256">>)),
    ?assertEqual(<<>>, ircd_wire:upper(<<>>)).

%%% NG socket

%% Replies are accepted only from rtpengine's address and port; a datagram
%% from anywhere else is dropped even when it carries a pending cookie.
ng_source_test() ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    try
        Reply = <<"c00kie d6:result2:oke">>,
        Pending = #{<<"c00kie">> => #{id => <<"x">>, op => offer, timer => undefined}},
        State = #{
            sock => Sock,
            ng => {"127.0.0.1", 2223},
            ng_ip => {127, 0, 0, 1},
            pending => Pending,
            calls => #{}
        },
        {noreply, #{pending := P1}} =
            ircd_calls:handle_info({udp, Sock, {10, 0, 0, 9}, 2223, Reply}, State),
        ?assertEqual(Pending, P1),
        {noreply, #{pending := P2}} =
            ircd_calls:handle_info({udp, Sock, {127, 0, 0, 1}, 4000, Reply}, State),
        ?assertEqual(Pending, P2),
        {noreply, #{pending := P3}} =
            ircd_calls:handle_info({udp, Sock, {127, 0, 0, 1}, 2223, Reply}, State),
        ?assertEqual(#{}, P3)
    after
        gen_udp:close(Sock)
    end.

%% Ending a call drops its NG requests still in flight, so a retry cannot
%% send the offer again after the delete and recreate the call in rtpengine.
ng_pending_dropped_on_end_test() ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    try
        Caller = self(),
        Token = <<"tok12345">>,
        Timer = erlang:send_after(60000, self(), never),
        Call = #{
            id => <<"call-1">>,
            token => Token,
            caller => Caller,
            callee => list_to_pid("<0.1.0>"),
            state => offering,
            started => erlang:monotonic_time(millisecond),
            timer => undefined,
            timer_ref => undefined,
            monitors => []
        },
        State = #{
            server => <<"irc.test">>,
            sock => Sock,
            ng => {"127.0.0.1", 9},
            ng_ip => {127, 0, 0, 1},
            calls => #{<<"call-1">> => Call},
            parties => #{{Caller, Token} => <<"call-1">>},
            busy => #{Caller => <<"call-1">>},
            pending => #{
                <<"a">> => #{id => <<"call-1">>, op => offer, timer => Timer},
                <<"b">> => #{id => <<"other">>, op => offer, timer => undefined}
            }
        },
        {noreply, #{pending := Pending, calls := Calls}} =
            ircd_calls:handle_cast({hangup, Caller, Token, <<"cancelled">>}, State),
        ?assertEqual([<<"b">>], maps:keys(Pending)),
        ?assertEqual(#{}, Calls),
        ?assertEqual(false, erlang:read_timer(Timer))
    after
        gen_udp:close(Sock)
    end.

ng_test() ->
    Offer = ircd_call_proto:offer(<<"c1">>, <<"f1">>, <<"v=0">>),
    Framed = iolist_to_binary(ircd_call_proto:frame(<<"ck">>, Offer)),
    [<<"ck">>, Body] = binary:split(Framed, <<" ">>),
    {ok, Decoded} = ircd_bencode:decode(Body),
    ?assertMatch(
        #{
            <<"command">> := <<"offer">>,
            <<"call-id">> := <<"c1">>,
            <<"ICE">> := <<"force">>,
            <<"transport-protocol">> := <<"UDP/TLS/RTP/SAVPF">>,
            <<"rtcp-mux">> := [<<"require">>]
        },
        Decoded
    ),
    ?assertEqual(
        {ok, <<"ck">>, {ok, <<"v=0">>}},
        ircd_call_proto:parse_reply(<<"ck d6:result2:ok3:sdp3:v=0e">>)
    ),
    ?assertEqual(
        {ok, <<"ck">>, {error, <<"no ports">>}},
        ircd_call_proto:parse_reply(<<"ck d6:result5:error12:error-reason8:no portse">>)
    ),
    ?assertEqual(
        {ok, <<"ck">>, {ok, undefined}}, ircd_call_proto:parse_reply(<<"ck d6:result4:ponge">>)
    ),
    ?assertEqual(error, ircd_call_proto:parse_reply(<<"garbage">>)).

%%% Configuration

config_test() ->
    ?assertMatch({ok, #{calls := null}}, load(<<>>)),
    ?assertMatch(
        {ok, #{
            calls := #{
                rtpengine := {<<"rtpengine">>, 2223},
                ring_timeout := 45,
                max_duration := 7200,
                max_calls := 100,
                calls_per_minute := 6,
                require_account := false
            }
        }},
        load(<<",\"calls\":{\"rtpengine\":\"rtpengine:2223\"}">>)
    ),
    ?assertMatch(
        {ok, #{calls := #{max_duration := 0, ring_timeout := 5}}},
        load(<<",\"calls\":{\"rtpengine\":\"127.0.0.1:1\",\"max_duration\":0,\"ring_timeout\":5}">>)
    ),
    ?assertMatch({error, _}, load(<<",\"calls\":{}">>)),
    ?assertMatch({error, _}, load(<<",\"calls\":{\"rtpengine\":\"host\"}">>)),
    ?assertMatch({error, _}, load(<<",\"calls\":{\"rtpengine\":\"h:70000\"}">>)),
    ?assertMatch({error, _}, load(<<",\"calls\":{\"rtpengine\":\"h:1\",\"ring_timeout\":4}">>)),
    ?assertMatch({error, _}, load(<<",\"calls\":{\"rtpengine\":\"h:1\",\"max_calls\":0}">>)).

load(Extra) ->
    Path = filename:join(
        "/tmp", "ircd-calls-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".json"
    ),
    ok = file:write_file(Path, [<<"{\"tcp_port\":6667">>, Extra, <<"}">>]),
    try
        ircd_config:load(Path)
    after
        file:delete(Path)
    end.

%%% Live: two clients calling through a fake rtpengine.

live_test_() ->
    {timeout, 60, fun live/0}.

live() ->
    Ng = start_fake_ng(self()),
    NgPort = ng_port(Ng),
    Dir = filename:join(
        "/tmp", "ircd-calls-live-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join([Dir, "db", "x"])),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, live_config(filename:join(Dir, "db"), NgPort)),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    try
        Port = listener_port(),
        Alice = client(Port, <<"alice">>, true),
        Bob = client(Port, <<"bob">>, true),
        Carol = client(Port, <<"carol">>, true),
        Dave = client(Port, <<"dave">>, false),

        %% Calling a client without the capability fails up front.
        send(
            Carol,
            <<"CALL OFFER dave tokendave1 1 1 :", (base64:encode(sdp(<<"audio">>)))/binary, "\r\n">>
        ),
        ?assert(
            has(
                recv_until(Carol, <<"TARGET_UNSUPPORTED">>),
                <<"FAIL CALL TARGET_UNSUPPORTED tokendave1">>
            )
        ),
        %% A client without the capability cannot use CALL.
        send(Dave, <<"CALL HANGUP alice tokendave1\r\n">>),
        ?assert(has(recv_until(Dave, <<"NEED_CAPABILITY">>), <<"FAIL CALL NEED_CAPABILITY">>)),

        %% Invalid UTF-8 in a subcommand is an unknown subcommand, not a crash
        %% of ircd_state (string:uppercase/1 raised badarg here). The same
        %% applies to METADATA and CHATHISTORY.
        StatePid = whereis(ircd_state),
        send(Carol, <<"CALL ", 255, "OFFER bob tokencarol 1 1 :AAAA\r\n">>),
        ?assert(
            has(recv_until(Carol, <<"UNKNOWN_SUBCOMMAND">>), <<"FAIL CALL UNKNOWN_SUBCOMMAND :">>)
        ),
        send(Carol, <<"METADATA * ", 255, "GET x\r\nCHATHISTORY ", 255, "LATEST #a * 1\r\n">>),
        %% A token that is a trailing parameter with a space is not echoed.
        send(Carol, <<"CALL HANGUP bob :tok 12345\r\n">>),
        ?assert(
            has(recv_until(Carol, <<"FAIL CALL INVALID_PARAMS">>), <<"FAIL CALL INVALID_PARAMS :">>)
        ),
        send(Carol, <<"PING :still-here\r\n">>),
        ?assert(has(recv_until(Carol, <<"still-here">>), <<"PONG">>)),
        ?assertEqual(StatePid, whereis(ircd_state)),

        %% Offer in two chunks; rtpengine sees the joined description.
        Offer = <<(sdp(<<"audio">>))/binary, (binary:copy(<<"a=x-pad:1\r\n">>, 40))/binary>>,
        send_sdp(Alice, <<"OFFER">>, <<"bob">>, <<"call0001">>, Offer),
        {offer, OfferMsg} = ng_recv(),
        ?assertEqual(Offer, maps:get(<<"sdp">>, OfferMsg)),
        CallId = maps:get(<<"call-id">>, OfferMsg),
        %% Bob receives rtpengine's description, from Alice's prefix.
        BobOffer = recv_until(Bob, <<"CALL OFFER bob call0001">>, fun sdp_complete/1),
        ?assert(has(BobOffer, <<":alice!alice@127.0.0.1 CALL OFFER bob call0001 1 ">>)),
        ?assertEqual(fake_sdp(<<"FROM-RTPENGINE-OFFER">>), sdp_of(BobOffer, <<"OFFER">>)),

        %% Ringing reaches the caller.
        send(Bob, <<"CALL RINGING alice call0001\r\n">>),
        ?assert(
            has(
                recv_until(Alice, <<"RINGING">>),
                <<":bob!bob@127.0.0.1 CALL RINGING alice call0001">>
            )
        ),

        %% A ringing call cannot be put on hold.
        send(Alice, <<"CALL HOLD bob call0001\r\n">>),
        ?assert(
            has(
                recv_until(Alice, <<"INVALID_STATE">>),
                <<"FAIL CALL INVALID_STATE call0001">>
            )
        ),

        %% Carol cannot call Bob while he is in a call.
        send_sdp(Carol, <<"OFFER">>, <<"bob">>, <<"carolcall1">>, sdp(<<"audio">>)),
        ?assert(has(recv_until(Carol, <<"TARGET_BUSY">>), <<"FAIL CALL TARGET_BUSY carolcall1">>)),

        %% Answer: rtpengine gets the same call with both tags.
        send_sdp(Bob, <<"ANSWER">>, <<"alice">>, <<"call0001">>, sdp(<<"audio">>)),
        {answer, AnswerMsg} = ng_recv(),
        ?assertEqual(CallId, maps:get(<<"call-id">>, AnswerMsg)),
        ?assertEqual(maps:get(<<"from-tag">>, OfferMsg), maps:get(<<"from-tag">>, AnswerMsg)),
        ?assert(is_map_key(<<"to-tag">>, AnswerMsg)),
        AliceAnswer = recv_until(Alice, <<"CALL ANSWER alice call0001">>, fun sdp_complete/1),
        ?assertEqual(fake_sdp(<<"FROM-RTPENGINE-ANSWER">>), sdp_of(AliceAnswer, <<"ANSWER">>)),

        %% Hold and resume go to the other party only, from either side; a
        %% third user's HOLD with the same token is not a call of theirs.
        send(Bob, <<"CALL HOLD alice call0001\r\n">>),
        ?assert(
            has(
                recv_until(Alice, <<"CALL HOLD">>),
                <<":bob!bob@127.0.0.1 CALL HOLD alice call0001">>
            )
        ),
        send(Bob, <<"CALL RESUME alice call0001\r\n">>),
        ?assert(
            has(
                recv_until(Alice, <<"CALL RESUME">>),
                <<":bob!bob@127.0.0.1 CALL RESUME alice call0001">>
            )
        ),
        send(Alice, <<"CALL HOLD bob call0001\r\n">>),
        ?assert(
            has(
                recv_until(Bob, <<"CALL HOLD">>),
                <<":alice!alice@127.0.0.1 CALL HOLD bob call0001">>
            )
        ),
        send(Carol, <<"CALL HOLD bob call0001\r\n">>),
        ?assert(has(recv_until(Carol, <<"UNKNOWN_CALL">>), <<"FAIL CALL UNKNOWN_CALL call0001">>)),

        %% Hang up: Bob is told, rtpengine deletes the call.
        send(Alice, <<"CALL HANGUP bob call0001 :normal\r\n">>),
        ?assert(
            has(
                recv_until(Bob, <<"HANGUP">>),
                <<":alice!alice@127.0.0.1 CALL HANGUP bob call0001 :normal">>
            )
        ),
        {delete, DeleteMsg} = ng_recv(),
        ?assertEqual(CallId, maps:get(<<"call-id">>, DeleteMsg)),

        %% Reject.
        send_sdp(Carol, <<"OFFER">>, <<"bob">>, <<"call0002">>, sdp(<<"audio">>)),
        {offer, _} = ng_recv(),
        _ = recv_until(Bob, <<"call0002">>, fun sdp_complete/1),
        send(Bob, <<"CALL REJECT carol call0002 :declined\r\n">>),
        ?assert(has(recv_until(Carol, <<"REJECT">>), <<"CALL REJECT carol call0002 :declined">>)),
        {delete, _} = ng_recv(),

        %% The callee disconnecting ends the call for the caller.
        send_sdp(Alice, <<"OFFER">>, <<"carol">>, <<"call0003">>, sdp(<<"audio">>)),
        {offer, _} = ng_recv(),
        _ = recv_until(Carol, <<"call0003">>, fun sdp_complete/1),
        send(Carol, <<"QUIT :bye\r\n">>),
        ?assert(
            has(
                recv_until(Alice, <<"disconnected">>),
                <<":irc.test CALL HANGUP alice call0003 :disconnected">>
            )
        ),
        {delete, _} = ng_recv(),

        %% A media relay error fails the call for the caller only.
        Ng ! fail_next,
        send_sdp(Alice, <<"OFFER">>, <<"bob">>, <<"call0004">>, sdp(<<"audio">>)),
        {offer, _} = ng_recv(),
        ?assert(has(recv_until(Alice, <<"MEDIA_ERROR">>), <<"FAIL CALL MEDIA_ERROR call0004">>)),
        {delete, _} = ng_recv(),

        %% Video is refused before reaching rtpengine.
        send_sdp(Alice, <<"OFFER">>, <<"bob">>, <<"call0005">>, sdp(<<"video">>)),
        ?assert(has(recv_until(Alice, <<"INVALID_SDP">>), <<"FAIL CALL INVALID_SDP call0005">>)),

        %% An unanswered call times out for both sides (ring_timeout 5 s).
        send_sdp(Alice, <<"OFFER">>, <<"bob">>, <<"call0006">>, sdp(<<"audio">>)),
        {offer, _} = ng_recv(),
        _ = recv_until(Bob, <<"call0006">>, fun sdp_complete/1),
        ?assert(
            has(
                recv_until(Alice, <<"no-answer">>, fun(_) -> true end, 8000),
                <<"CALL HANGUP alice call0006 :no-answer">>
            )
        ),
        ?assert(
            has(
                recv_until(Bob, <<"no-answer">>, fun(_) -> true end, 8000),
                <<"CALL HANGUP bob call0006 :no-answer">>
            )
        ),
        {delete, _} = ng_recv(),
        receive
            {ng, Unexpected, _} -> ?assertEqual(none, Unexpected)
        after 200 -> ok
        end,

        %% Every call above has ended (hangup, reject, busy, disconnect,
        %% media error, ring timeout): nothing is left in the call table, no
        %% party is still monitored, and no NG request or timer is pending.
        Calls =
            case whereis(ircd_calls) of
                CallsPid when is_pid(CallsPid) -> CallsPid
            end,
        #{calls := C, parties := P, busy := B, chunks := Ch, pending := Pe} =
            sys:get_state(Calls),
        ?assertEqual({#{}, #{}, #{}, #{}, #{}}, {C, P, B, Ch, Pe}),
        ?assertEqual({monitors, []}, erlang:process_info(Calls, monitors))
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG"),
        Ng ! stop
    end.

live_config(Db, NgPort) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",\"retention\":\"transient\",">>,
        <<"\"calls\":{\"rtpengine\":\"127.0.0.1:">>,
        integer_to_binary(NgPort),
        <<"\",\"ring_timeout\":5},\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).

sdp(Media) ->
    <<"v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=", Media/binary,
        " 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\n">>.

fake_sdp(Marker) ->
    <<
        (sdp(<<"audio">>))/binary,
        "a=",
        Marker/binary,
        "\r\n",
        (binary:copy(<<"a=relay-padding\r\n">>, 30))/binary
    >>.

send_sdp(Sock, Kind, Nick, Token, Sdp) ->
    Chunks = ircd_call_proto:chunks(Sdp),
    Total = integer_to_binary(length(Chunks)),
    lists:foldl(
        fun(Chunk, N) ->
            send(Sock, [
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
                Chunk,
                "\r\n"
            ]),
            N + 1
        end,
        1,
        Chunks
    ).

%% The description carried by the `CALL <Kind>` lines in `Lines`.
sdp_of(Lines, Kind) ->
    Parts = [
        L
     || L <- binary:split(Lines, <<"\r\n">>, [global]),
        has(L, <<" CALL ", Kind/binary, " ">>)
    ],
    base64:decode(
        iolist_to_binary([lists:last(binary:split(P, <<" :">>, [global])) || P <- Parts])
    ).

%% True once the last chunk (part = total) of a description has arrived.
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

%% A fake rtpengine: decodes NG requests, reports them to the test, and
%% answers offers and answers with a recognizable description.
start_fake_ng(Test) ->
    Parent = self(),
    spawn(fun() ->
        {ok, S} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
        {ok, P} = inet:port(S),
        Parent ! {ng_port, self(), P},
        ng_loop(S, Test, false)
    end).

ng_port(Pid) ->
    receive
        {ng_port, Pid, P} -> P
    after 5000 -> error(ng_not_started)
    end.

ng_loop(S, Test, FailNext) ->
    receive
        stop ->
            gen_udp:close(S);
        fail_next ->
            ng_loop(S, Test, true);
        {udp, S, Ip, Port, Packet} ->
            [Cookie, Body] = binary:split(Packet, <<" ">>),
            {ok, #{<<"command">> := <<_/binary>> = Cmd} = Msg} = ircd_bencode:decode(Body),
            Test ! {ng, binary_to_atom(Cmd), Msg},
            {Reply, Fail1} =
                case {Cmd, FailNext} of
                    {<<"delete">>, _} ->
                        {#{result => ok}, FailNext};
                    {_, true} ->
                        {#{result => error, 'error-reason' => <<"no ports">>}, false};
                    {<<"offer">>, false} ->
                        {#{result => ok, sdp => fake_sdp(<<"FROM-RTPENGINE-OFFER">>)}, false};
                    {<<"answer">>, false} ->
                        {#{result => ok, sdp => fake_sdp(<<"FROM-RTPENGINE-ANSWER">>)}, false}
                end,
            ok = gen_udp:send(S, Ip, Port, [Cookie, " ", ircd_bencode:encode(Reply)]),
            ng_loop(S, Test, Fail1)
    end.

ng_recv() ->
    receive
        {ng, Cmd, Msg} -> {Cmd, Msg}
    after 5000 -> error(no_ng_request)
    end.

client(Port, Nick, WithCap) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    case WithCap of
        true -> send(Sock, <<"CAP REQ :" ?CAP "\r\n">>);
        false -> ok
    end,
    send(Sock, [<<"NICK ">>, Nick, <<"\r\nUSER ">>, Nick, <<" 0 * :T\r\nCAP END\r\n">>]),
    _ = recv_until(Sock, <<" 001 ">>),
    Sock.

send(Sock, Data) -> ok = gen_tcp:send(Sock, Data).

recv_until(Sock, Needle) -> recv_until(Sock, Needle, fun(_) -> true end).

recv_until(Sock, Needle, Done) -> recv_until(Sock, Needle, Done, 5000).

recv_until(Sock, Needle, Done, Timeout) -> recv_until(Sock, Needle, Done, Timeout, <<>>).

recv_until(Sock, Needle, Done, Timeout, Acc) ->
    case has(Acc, Needle) andalso Done(Acc) andalso binary:last(Acc) =:= $\n of
        true ->
            Acc;
        false ->
            {ok, <<_/binary>> = Bin} = gen_tcp:recv(Sock, 0, Timeout),
            recv_until(Sock, Needle, Done, Timeout, <<Acc/binary, Bin/binary>>)
    end.

has(Bin, Needle) -> binary:match(Bin, Needle) =/= nomatch.

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.
