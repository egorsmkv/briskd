-module(ircd_e2ee_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ircd/include/ircd_e2ee.hrl").

%% End-to-end encryption broker (ircd_e2ee): capability, key directory,
%% device binding, the offline queue with acknowledgement, limits, and the
%% feature switched off.

-define(CAP, "egorsmkv.github.io/e2ee").
-define(DST, "+egorsmkv.github.io/e2ee-dst").
-define(SRC, "+egorsmkv.github.io/e2ee-src").
-define(QID, "egorsmkv.github.io/e2ee-qid").
%% Stand-ins for Curve25519 keys (32 bytes) and an XEdDSA signature (64).
-define(K32(C), base64:encode(binary:copy(<<C>>, 32))).
-define(SIG, base64:encode(binary:copy(<<"s">>, 64))).

disabled_test_() ->
    {timeout, 60, fun disabled/0}.

disabled() ->
    with_server(<<>>, fun(Port) ->
        S = connect(Port),
        send(S, <<"CAP LS 302">>),
        ?assertNot(has(sync(S), <<?CAP>>)),
        send(S, <<"CAP END\r\nNICK plain\r\nUSER p 0 * :P">>),
        _ = recv_until(S, <<" 001 ">>),
        send(S, <<"E2EE DEVICES plain">>),
        ?assert(has(sync(S), <<" 421 plain E2EE ">>)),
        close(S)
    end).

broker_test_() ->
    {timeout, 120, fun broker/0}.

broker() ->
    Config =
        <<",\"e2ee\":{\"max_devices\":2,\"max_prekeys\":5,\"queue_limit\":3,\"fetch_rate\":4}">>,
    with_server(Config, fun(Port) ->
        {ok, _} = ircd_account:create(<<"alice">>, undefined, <<"alicepassword">>, [], undefined),
        {ok, _} = ircd_account:create(<<"bob">>, undefined, <<"bobpassword1">>, [], undefined),
        capability(Port),
        directory(Port),
        queue(Port),
        expiry()
    end).

capability(Port) ->
    S = connect(Port),
    %% CAP LS 302 may span several lines; read them all.
    send(S, <<"CAP LS 302">>),
    Ls = sync(S),
    ?assert(has(Ls, <<?CAP "=v=1,max-devices=2,max-prekeys=5,queue=3">>)),
    send(S, <<"CAP END\r\nNICK nocap\r\nUSER n 0 * :N">>),
    _ = recv_until(S, <<" 001 ">>),
    send(S, <<"E2EE DEVICES alice">>),
    ?assert(has(sync(S), <<"FAIL E2EE CAP_REQUIRED">>)),
    send(S, <<"CAP REQ " ?CAP>>),
    _ = recv_until(S, <<"ACK">>),
    %% Key material needs a SASL account.
    send(
        S, <<"E2EE PUBLISH 1 ", (?K32("i"))/binary, " 1:", (?K32("s"))/binary, " ", (?SIG)/binary>>
    ),
    ?assert(has(sync(S), <<"FAIL E2EE ACCOUNT_REQUIRED">>)),
    send(S, <<"E2EE FROB">>),
    ?assert(has(sync(S), <<"FAIL E2EE UNKNOWN_COMMAND FROB">>)),
    send(S, <<"E2EE PUBLISH 1">>),
    ?assert(has(sync(S), <<"FAIL E2EE NEED_MORE_PARAMS PUBLISH">>)),
    close(S).

directory(Port) ->
    Alice = login(Port, <<"alice">>, <<"alicepassword">>),
    Publish = fun(Dev) ->
        send(
            Alice,
            <<"E2EE PUBLISH ", Dev/binary, " ", (?K32("i"))/binary, " 7:", (?K32("s"))/binary, " ",
                (?SIG)/binary>>
        ),
        sync(Alice)
    end,
    ?assert(has(Publish(<<"1001">>), <<"E2EE PUBLISHED 1001">>)),
    ?assert(has(Publish(<<"1002">>), <<"E2EE PUBLISHED 1002">>)),
    %% Republishing a device is an update, not a new device.
    ?assert(has(Publish(<<"1001">>), <<"E2EE PUBLISHED 1001">>)),
    ?assert(has(Publish(<<"1003">>), <<"FAIL E2EE TOO_MANY_DEVICES 1003">>)),
    ?assert(has(Publish(<<"0">>), <<"FAIL E2EE INVALID_PARAMS device">>)),
    send(Alice, <<"E2EE PUBLISH 1004 not*base64 7:", (?K32("s"))/binary, " ", (?SIG)/binary>>),
    ?assert(has(sync(Alice), <<"FAIL E2EE INVALID_PARAMS key">>)),
    %% One-time prekeys: added, counted, capped at max_prekeys (5).
    send(
        Alice,
        <<"E2EE PREKEYS 1001 1:", (?K32("a"))/binary, " 2:", (?K32("b"))/binary, " 3:",
            (?K32("c"))/binary>>
    ),
    ?assert(has(sync(Alice), <<"E2EE PREKEYS 1001 3">>)),
    send(
        Alice,
        <<"E2EE PREKEYS 1001 4:", (?K32("d"))/binary, " 5:", (?K32("e"))/binary, " 6:",
            (?K32("f"))/binary>>
    ),
    ?assert(has(sync(Alice), <<"FAIL E2EE TOO_MANY_PREKEYS 1001">>)),
    send(Alice, <<"E2EE PREKEYS 1001">>),
    ?assert(has(sync(Alice), <<"E2EE PREKEYS 1001 3">>)),
    send(Alice, <<"E2EE PREKEYS 4242 1:", (?K32("a"))/binary>>),
    ?assert(has(sync(Alice), <<"FAIL E2EE UNKNOWN_DEVICE 4242">>)),
    send(Alice, <<"E2EE BIND 1001">>),
    ?assert(has(sync(Alice), <<"E2EE BOUND 1001 0">>)),
    %% Bob lists and fetches Alice's devices by nickname.
    Bob = login(Port, <<"bob">>, <<"bobpassword1">>),
    send(Bob, <<"E2EE DEVICES alice">>),
    ?assert(has(sync(Bob), <<"E2EE DEVICES alice :1001 1002">>)),
    send(Bob, <<"E2EE FETCH alice 1001">>),
    First = sync(Bob),
    ?assert(
        has(
            First,
            <<"E2EE BUNDLE alice 1001 ", (?K32("i"))/binary, " 7:", (?K32("s"))/binary, " ",
                (?SIG)/binary, " 1:", (?K32("a"))/binary>>
        )
    ),
    ?assert(has(First, <<"E2EE FETCHED alice 1">>)),
    %% Each one-time prekey is handed out once; the owner hears it is low.
    ?assert(has(recv_until(Alice, <<"E2EE PREKEYS 1001 2">>), <<"E2EE PREKEYS 1001 2">>)),
    send(Bob, <<"E2EE FETCH alice">>),
    Both = sync(Bob),
    ?assert(has(Both, <<" 2:", (?K32("b"))/binary>>)),
    %% Device 1002 has no prekeys left: its bundle has none.
    ?assert(has(Both, <<" ", (?SIG)/binary, "\r\n">>)),
    ?assert(has(Both, <<"E2EE FETCHED alice 2">>)),
    send(Bob, <<"E2EE FETCH nosuchone">>),
    ?assert(has(sync(Bob), <<"FAIL E2EE NO_SUCH_TARGET nosuchone">>)),
    %% fetch_rate is 4 per minute per connection.
    send(Bob, <<"E2EE FETCH alice 1001">>),
    _ = sync(Bob),
    send(Bob, <<"E2EE FETCH alice 1001">>),
    ?assert(has(sync(Bob), <<"FAIL E2EE RATE_LIMITED alice">>)),
    close(Bob),
    close(Alice).

queue(Port) ->
    Alice = login(Port, <<"alice">>, <<"alicepassword">>),
    send(Alice, <<"E2EE BIND 1001">>),
    ?assert(has(sync(Alice), <<"E2EE BOUND 1001 0">>)),
    Bob = login(Port, <<"bob">>, <<"bobpassword1">>),
    %% Alice is online on device 1001 only: an envelope for 1002 is
    %% delivered to her connection and also queued for 1002.
    send(Bob, <<"@" ?DST "=1002;" ?SRC "=77 PRIVMSG alice :cipher-one">>),
    ?assert(has(sync(Bob), <<"E2EE QUEUED alice 1002 ">>)),
    ?assert(has(recv_until(Alice, <<"cipher-one">>), <<"PRIVMSG alice :cipher-one">>)),
    %% To the bound device: plain delivery, nothing queued.
    send(Bob, <<"@" ?DST "=1001 PRIVMSG alice :cipher-two">>),
    ?assertNot(has(sync(Bob), <<"QUEUED">>)),
    ?assert(has(recv_until(Alice, <<"cipher-two">>), <<"cipher-two">>)),
    close(Alice),
    wait_offline(<<"alice">>),
    %% Alice is offline: envelopes are queued, not refused with 401.
    send(Bob, <<"@" ?DST "=1001;" ?SRC "=77 PRIVMSG alice :cipher-three">>),
    Queued = sync(Bob),
    ?assert(has(Queued, <<"E2EE QUEUED alice 1001 ">>)),
    ?assertNot(has(Queued, <<" 401 ">>)),
    send(Bob, <<"@" ?DST "=1001 TAGMSG alice">>),
    ?assert(has(sync(Bob), <<"E2EE QUEUED alice 1001 ">>)),
    send(Bob, <<"@" ?DST "=9999 PRIVMSG alice :x">>),
    ?assert(has(sync(Bob), <<"FAIL E2EE UNKNOWN_DEVICE alice 9999">>)),
    %% Without the tag the offline nickname is still 401.
    send(Bob, <<"PRIVMSG alice :plain">>),
    ?assert(has(sync(Bob), <<" 401 bob alice ">>)),
    %% queue_limit is 3 per device (1001 holds 2 now).
    send(Bob, <<"@" ?DST "=1001 PRIVMSG alice :cipher-four">>),
    ?assert(has(sync(Bob), <<"E2EE QUEUED alice 1001 ">>)),
    send(Bob, <<"@" ?DST "=1001 PRIVMSG alice :cipher-five">>),
    ?assert(has(sync(Bob), <<"FAIL E2EE QUEUE_FULL alice 1001">>)),
    %% Queueing needs the sender's account too.
    Anon = connect(Port),
    send(Anon, <<"CAP REQ :message-tags " ?CAP "\r\nCAP END\r\nNICK anon\r\nUSER a 0 * :A">>),
    _ = recv_until(Anon, <<" 001 ">>),
    send(Anon, <<"@" ?DST "=1001 PRIVMSG alice :x">>),
    ?assert(has(sync(Anon), <<"FAIL E2EE ACCOUNT_REQUIRED alice">>)),
    close(Anon),
    %% Alice comes back on device 1001: the queue is replayed with the
    %% original sender and tags plus a qid, oldest first.
    Back = login(Port, <<"alice">>, <<"alicepassword">>),
    send(Back, <<"E2EE BIND 1001">>),
    Replay = sync(Back),
    ?assert(has(Replay, <<"E2EE BOUND 1001 3">>)),
    ?assert(has(Replay, <<":bob!">>)),
    ?assert(has(Replay, <<?SRC "=77">>)),
    ?assert(has(Replay, <<"PRIVMSG alice :cipher-three">>)),
    ?assert(has(Replay, <<"TAGMSG alice">>)),
    {Three, _} = binary:match(Replay, <<"cipher-three">>),
    {Four, _} = binary:match(Replay, <<"cipher-four">>),
    ?assert(Three < Four),
    Qids = qids(Replay),
    ?assertEqual(3, length(Qids)),
    %% Acknowledge two; the third is delivered again on the next BIND.
    [Q1, Q2, _] = Qids,
    send(Back, <<"E2EE ACK ", Q1/binary, ",", Q2/binary>>),
    send(Back, <<"E2EE BIND 1001">>),
    Again = sync(Back),
    ?assert(has(Again, <<"E2EE BOUND 1001 1">>)),
    ?assert(has(Again, <<"cipher-four">>)),
    %% REMOVE drops the device and its queue.
    send(Back, <<"E2EE REMOVE 1002">>),
    ?assert(has(sync(Back), <<"E2EE REMOVED 1002">>)),
    ?assertEqual([], [
        K
     || {_, _, _} = K <- mnesia:dirty_all_keys(e2ee_queue), element(2, K) =:= 1002
    ]),
    send(Bob, <<"E2EE DEVICES alice">>),
    ?assert(has(sync(Bob), <<"E2EE DEVICES alice :1001">>)),
    close(Bob),
    close(Back).

expiry() ->
    ok = mnesia:dirty_write(#e2ee_queue{
        key = {<<"alice">>, 1001, 1},
        prefix = <<"old!o@o">>,
        command = <<"PRIVMSG">>,
        target = <<"alice">>,
        text = <<"stale">>,
        tags = [],
        expires = erlang:system_time(second) - 1
    }),
    erase(ircd_e2ee_expired_at),
    ok = ircd_e2ee:expire(),
    ?assertEqual([], mnesia:dirty_read(e2ee_queue, {<<"alice">>, 1001, 1})).

qids(Data) ->
    [Qid || [_, Qid] <- re_all(Data, <<?QID "=([0-9]+)">>)].

re_all(Data, Pattern) ->
    case re:run(Data, Pattern, [global, {capture, all, binary}]) of
        {match, Matches} -> Matches;
        nomatch -> []
    end.

wait_offline(Nick) ->
    wait_offline(Nick, 100).

wait_offline(Nick, 0) ->
    ?assertEqual(undefined, ircd_state:find_nick(Nick));
wait_offline(Nick, N) ->
    case ircd_state:find_nick(Nick) of
        undefined ->
            ok;
        _ ->
            timer:sleep(20),
            wait_offline(Nick, N - 1)
    end.

%%% Server and client helpers

with_server(Extra, Fun) ->
    Dir = filename:join("/tmp", "ircd-e2ee-" ++ integer_to_list(erlang:system_time(nanosecond))),
    ok = filelib:ensure_dir(filename:join(Dir, "db/x")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(
        Config,
        iolist_to_binary([
            <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
            <<"\"log_level\":\"error\",\"resource_delay\":0,\"mnesia_dir\":\"">>,
            filename:join(Dir, "db"),
            <<"\"">>,
            Extra,
            <<"}">>
        ])
    ),
    application:stop(ircd),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    try
        Fun(listener_port())
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

login(Port, Account, Password) ->
    S = connect(Port),
    send(S, <<"CAP REQ :sasl message-tags " ?CAP>>),
    _ = recv_until(S, <<"ACK">>),
    send(S, <<"NICK ", Account/binary, "\r\nUSER u 0 * :U\r\nAUTHENTICATE PLAIN">>),
    _ = recv_until(S, <<"AUTHENTICATE +">>),
    send(S, <<"AUTHENTICATE ", (base64:encode(<<0, Account/binary, 0, Password/binary>>))/binary>>),
    _ = recv_until(S, <<" 903 ">>),
    send(S, <<"CAP END">>),
    _ = recv_until(S, <<" 001 ">>),
    S.

connect(Port) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    S.

send(S, Line) ->
    ok = gen_tcp:send(S, [Line, <<"\r\n">>]).

sync(S) ->
    Token = integer_to_binary(erlang:unique_integer([positive])),
    send(S, <<"PING :sync", Token/binary>>),
    recv_until(S, <<"sync", Token/binary>>).

recv_until(S, Needle) ->
    recv_until(S, Needle, <<>>).

recv_until(S, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            {ok, Data} = gen_tcp:recv(S, 0, 10000),
            recv_until(S, Needle, <<Acc/binary, Data/binary>>);
        {Pos, Len} ->
            %% Keep reading to the end of the line that holds the needle.
            case
                binary:match(Acc, <<"\r\n">>, [{scope, {Pos + Len, byte_size(Acc) - Pos - Len}}])
            of
                nomatch ->
                    {ok, Data} = gen_tcp:recv(S, 0, 10000),
                    recv_until(S, Needle, <<Acc/binary, Data/binary>>);
                _ ->
                    Acc
            end
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

close(S) ->
    gen_tcp:close(S).

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.
