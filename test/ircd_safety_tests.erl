-module(ircd_safety_tests).
-include_lib("eunit/include/eunit.hrl").

%% Memory-safety regressions: linear mask matching, copied peer fields,
%% bounded WHOWAS and list modes, the client SendQ limit, MARKREAD targets,
%% expired holds, and the max_sendq configuration range.

%%% Pure checks

glob_semantics_test() ->
    M = fun ircd_state_channel:wildcard_match/2,
    ?assert(M(<<"*">>, <<>>)),
    ?assert(M(<<"*">>, <<"anything">>)),
    ?assert(M(<<"a*c">>, <<"abc">>)),
    ?assert(M(<<"a*c">>, <<"ac">>)),
    ?assert(M(<<"a?c">>, <<"abc">>)),
    ?assertNot(M(<<"a?c">>, <<"ac">>)),
    ?assert(M(<<"**a**">>, <<"bab">>)),
    ?assert(M(<<"*!*@*.example">>, <<"nick!user@host.example">>)),
    ?assertNot(M(<<"*!*@*.example">>, <<"nick!user@host.example.org">>)),
    %% RFC 1459 case mapping: [ ] \ ^ fold to { } | ~.
    ?assert(M(<<"NICK[1]">>, <<"nick{1}">>)),
    ?assertNot(M(<<"abc">>, <<"abcd">>)),
    ?assertNot(M(<<"abcd">>, <<"abc">>)).

glob_is_not_exponential_test() ->
    %% The old matcher took exponential time on this mask; the linear one
    %% finishes in well under a second.
    Mask = binary:copy(<<"*a">>, 30),
    Value = binary:copy(<<"a">>, 4000),
    {Micros, Result} = timer:tc(fun() ->
        ircd_state_channel:wildcard_match(<<Mask/binary, "b">>, Value)
    end),
    ?assertNot(Result),
    ?assert(Micros < 1000000).

retain_fields_copies_sub_binaries_test() ->
    %% Slices under 64 bytes are already their own heap binaries on OTP 29;
    %% a long value such as a topic or real name references the packet.
    Packet = binary:copy(<<"x">>, 4096),
    Sub = binary:part(Packet, 10, 100),
    ?assertEqual(4096, binary:referenced_byte_size(Sub)),
    {row, Copied, 7, [Sub]} = ircd_wire:retain_fields({row, Sub, 7, [Sub]}),
    ?assertEqual(100, binary:referenced_byte_size(Copied)),
    ?assertEqual(Sub, Copied).

max_sendq_config_test() ->
    Load = fun(Value) ->
        Path = filename:join(
            "/tmp", "ircd-sendq-" ++ integer_to_list(erlang:system_time(nanosecond)) ++ ".json"
        ),
        ok = file:write_file(Path, [<<"{\"tcp_port\":6667">>, Value, <<"}">>]),
        try
            ircd_config:load(Path)
        after
            file:delete(Path)
        end
    end,
    ?assertMatch({ok, #{max_sendq := 10000}}, Load(<<>>)),
    ?assertMatch({ok, #{max_sendq := 100}}, Load(<<",\"max_sendq\":100">>)),
    ?assertMatch({ok, #{max_sendq := 1000000}}, Load(<<",\"max_sendq\":1000000">>)),
    ?assertMatch({error, _}, Load(<<",\"max_sendq\":99">>)),
    ?assertMatch({error, _}, Load(<<",\"max_sendq\":1000001">>)),
    ?assertMatch({error, _}, Load(<<",\"max_sendq\":\"10\"">>)).

%%% Live server

live_test_() ->
    {timeout, 120, fun live/0}.

live() ->
    Dir = filename:join("/tmp", "ircd-safety-" ++ integer_to_list(erlang:system_time(nanosecond))),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(filename:join(Dir, "db"))),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    try
        Port = listener_port(),
        whowas_is_bounded(Port),
        list_modes_are_bounded(Port),
        markread_targets(Port),
        holds_expire(),
        sendq_limit(Port)
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

config(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"error\",\"log_format\":\"text\",\"resource_delay\":0,">>,
        <<"\"max_sendq\":100,\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).

whowas_is_bounded(Port) ->
    S = register_client(Port, <<"wwa">>),
    %% Each change records the old nickname in WHOWAS.
    lists:foreach(
        fun(N) ->
            Next =
                case N rem 2 of
                    0 -> <<"wwa">>;
                    1 -> <<"wwb">>
                end,
            send(S, <<"NICK ", Next/binary>>),
            _ = sync(S)
        end,
        lists:seq(1, 30)
    ),
    Rows = [
        K
     || {whowas, {F, _, _} = K, _, _, _, _, _, _} <- ets:tab2list(whowas), F =:= <<"wwa">>
    ],
    ?assertEqual(10, length(Rows)),
    send(S, <<"WHOWAS wwa">>),
    ?assertEqual(10, count(sync(S), <<" 314 ">>)),
    close(S).

list_modes_are_bounded(Port) ->
    S = register_client(Port, <<"lister">>),
    send(S, <<"JOIN #full">>),
    _ = sync(S),
    send(S, <<"ISUPPORT">>),
    ?assert(has(sync(S), <<"MAXLIST=beI:100">>)),
    lists:foreach(
        fun(N) ->
            send(S, iolist_to_binary([<<"MODE #full +b ban">>, integer_to_binary(N), <<"!*@*">>]))
        end,
        lists:seq(1, 100)
    ),
    _ = sync(S),
    send(S, <<"MODE #full +b onemore!*@*">>),
    ?assert(has(sync(S), <<" 478 lister #full b :Channel list is full">>)),
    %% Re-adding an existing mask is a no-op, not an error.
    send(S, <<"MODE #full +b ban1!*@*">>),
    ?assertNot(has(sync(S), <<" 478 ">>)),
    %% Removing one makes room again.
    send(S, <<"MODE #full -b ban1!*@*">>),
    send(S, <<"MODE #full +b onemore!*@*">>),
    ?assertNot(has(sync(S), <<" 478 ">>)),
    close(S).

markread_targets(Port) ->
    S = register_client(Port, <<"marker">>),
    send(S, <<"CAP REQ draft/read-marker">>),
    _ = sync(S),
    send(S, <<"MARKREAD not*valid timestamp=2030-01-01T00:00:00.000Z">>),
    ?assert(has(sync(S), <<"FAIL MARKREAD INVALID_PARAMS not*valid">>)),
    send(S, <<"MARKREAD #ok timestamp=2030-01-01T00:00:00.000Z">>),
    ?assert(has(sync(S), <<"MARKREAD #ok timestamp=2030-01-01T00:00:00.000Z">>)),
    ?assertEqual(
        {error, invalid_markread},
        ircd_state_sync:receive_markread(
            <<"peer.test">>, <<"peer.test">>, [<<"acct">>, <<"bad target">>, <<"1">>]
        )
    ),
    close(S).

holds_expire() ->
    Past = erlang:monotonic_time(second) - 5,
    Future = erlang:monotonic_time(second) + 600,
    true = ets:insert(ircd_holds, [{{nick, <<"gone">>}, Past}, {{nick, <<"kept">>}, Future}]),
    ok = ircd_state_net:expire_holds(),
    ?assertEqual([], ets:lookup(ircd_holds, {nick, <<"gone">>})),
    ?assertMatch([_], ets:lookup(ircd_holds, {nick, <<"kept">>})),
    %% A lookup of an expired hold also removes it.
    true = ets:insert(ircd_holds, {{nick, <<"stale">>}, Past}),
    ?assertNot(ircd_state_net:nick_blocked(<<"stale">>)),
    ?assertEqual([], ets:lookup(ircd_holds, {nick, <<"stale">>})),
    true = ets:delete(ircd_holds, {nick, <<"kept">>}).

sendq_limit(Port) ->
    %% Lines that pile up for a session past max_sendq (100 here) close the
    %% connection with ERROR. Suspending the session makes the queue build
    %% deterministically; the first line handled after resume sees it.
    Slow = register_client(Port, <<"slowpoke">>),
    {ok, LocalPort} = inet:port(Slow),
    [Pid] = [
        P
     || {_, P, _, _} <- supervisor:which_children(ircd_sessions),
        is_pid(P),
        peer_port(P) =:= {ok, LocalPort}
    ],
    Ref = monitor(process, Pid),
    ok = sys:suspend(Pid),
    Line = <<":irc.test NOTICE slowpoke :queued\r\n">>,
    lists:foreach(fun(_) -> Pid ! {irc, Line} end, lists:seq(1, 150)),
    ok = sys:resume(Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 -> ?assert(false)
    end,
    Data = read_all(Slow, <<>>),
    ?assert(has(Data, <<"ERROR :Closing Link: irc.test (Max SendQ exceeded)">>)),
    ?assertNot(has(Data, <<"queued">>)),
    close(Slow).

read_all(S, Acc) ->
    case gen_tcp:recv(S, 0, 2000) of
        {ok, Data} -> read_all(S, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

%% The session's socket peer port is the client's local port.
peer_port(Pid) ->
    case sys:get_state(Pid, 1000) of
        {tcp, Socket, _, _, _} ->
            case inet:peername(Socket) of
                {ok, {_, Port}} -> {ok, Port};
                Other -> Other
            end;
        _ ->
            error
    end.

%%% Helpers

register_client(Port, Nick) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    send(S, <<"NICK ", Nick/binary>>),
    send(S, <<"USER ", Nick/binary, " 0 * :T">>),
    ?assert(has(sync(S), <<" 001 ">>)),
    S.

send(S, Line) ->
    ok = gen_tcp:send(S, [Line, <<"\r\n">>]).

sync(S) ->
    Token = integer_to_binary(erlang:unique_integer([positive])),
    send(S, <<"PING :t", Token/binary>>),
    recv_until(S, <<"t", Token/binary>>, <<>>).

recv_until(S, Needle, Acc) ->
    case binary:match(Acc, <<"PONG">>) =/= nomatch andalso binary:match(Acc, Needle) of
        {_, _} ->
            Acc;
        _ ->
            {ok, Data} = gen_tcp:recv(S, 0, 5000),
            recv_until(S, Needle, <<Acc/binary, Data/binary>>)
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

count(Bin, Needle) ->
    length(binary:matches(Bin, Needle)).

close(S) ->
    gen_tcp:close(S).

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.
