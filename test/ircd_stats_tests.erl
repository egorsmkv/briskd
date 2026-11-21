-module(ircd_stats_tests).
-include_lib("eunit/include/eunit.hrl").

%% ircd_stats samples the server on a timer and GET /api/stats returns the
%% samples as one array per metric, for signed-in administrators only.

stats_test_() ->
    {timeout, 60, fun run/0}.

run() ->
    Dir = filename:join(
        "/tmp", "ircd-stats-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config_json(Db)),
    os:putenv("IRCD_CONFIG", Config),
    _ = application:load(ircd),
    ok = application:set_env(ircd, stats_interval, 100),
    {ok, _} = application:ensure_all_started(ircd),
    try
        sampled_traffic(),
        api()
    after
        _ = application:stop(ircd),
        ok = application:unset_env(ircd, stats_interval),
        os:unsetenv("IRCD_CONFIG"),
        _ = file:del_dir_r(Dir)
    end.

%% A registered client and its lines show up in the samples: one session
%% and registered user, and received and sent line rates above zero.
sampled_traffic() ->
    Sock = client(listener_port(), <<"statsy">>),
    try
        [ok = gen_tcp:send(Sock, <<"PING :x\r\n">>) || _ <- lists:seq(1, 20)],
        ok = wait_until(fun() ->
            Samples = maps:get(samples, ircd_stats:history()),
            lists:any(
                fun(S) ->
                    maps:get(registered, S) =:= 1 andalso maps:get(sessions, S) =:= 1 andalso
                        positive(maps:get(lines_in, S)) andalso positive(maps:get(lines_out, S))
                end,
                Samples
            )
        end),
        #{interval_ms := 100, samples := [First | _]} = ircd_stats:history(),
        %% The first sample has rates, from the counters at start-up.
        ?assert(is_number(maps:get(lines_in, First))),
        [
            ?assert(is_integer(maps:get(K, First)))
         || K <- [t, memory_total, processes, run_queue, state_queue, links, channels]
        ]
    after
        gen_tcp:close(Sock)
    end.

api() ->
    {ok, Port} = ircd_webui:port(),
    ?assertMatch({401, _, _}, http_get(Port, <<"/api/stats">>, [])),
    {200, _, Body} = http_get(Port, <<"/api/stats">>, [
        {<<"Authorization">>, basic_auth(<<"admin">>, <<"topsecret">>)}
    ]),
    #{<<"interval_ms">> := 100, <<"metrics">> := Metrics} = json:decode(Body),
    #{<<"t">> := Times} = Metrics,
    ?assert(length(Times) >= 1),
    %% Every metric has one value per sample.
    [?assertEqual({K, length(Times)}, {K, length(V)}) || K := V <- Metrics],
    ?assert(lists:member(<<"scheduler_util">>, maps:keys(Metrics))).

positive(N) -> is_number(N) andalso N > 0.

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    true = is_pid(Pid),
    {ok, Port} = ircd_listener:port(Pid),
    Port.

client(Port, Nick) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Sock, [<<"NICK ">>, Nick, <<"\r\nUSER ">>, Nick, <<" 0 * :T\r\n">>]),
    _ = recv_until(Sock, <<" 001 ">>, <<>>),
    Sock.

recv_until(Sock, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            {ok, <<_/binary>> = Bin} = gen_tcp:recv(Sock, 0, 5000),
            recv_until(Sock, Needle, <<Acc/binary, Bin/binary>>);
        _ ->
            Acc
    end.

wait_until(Fun) -> wait_until(Fun, 100).

wait_until(_Fun, 0) ->
    erlang:error(timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, N - 1)
    end.

basic_auth(User, Pass) ->
    <<"Basic ", (base64:encode(<<User/binary, ":", Pass/binary>>))/binary>>.

http_get(Port, Path, Headers) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    try
        Extra = [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Headers],
        ok = gen_tcp:send(Sock, [
            <<"GET ">>, Path, <<" HTTP/1.1\r\nHost: 127.0.0.1\r\n">>, Extra, <<"\r\n">>
        ]),
        [Head, Body] = binary:split(read_all(Sock, <<>>), <<"\r\n\r\n">>),
        [StatusLine | _] = binary:split(Head, <<"\r\n">>),
        [_, Code | _] = binary:split(StatusLine, <<" ">>, [global]),
        {binary_to_integer(Code), Head, Body}
    after
        gen_tcp:close(Sock)
    end.

read_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, <<_/binary>> = Chunk} -> read_all(Sock, <<Acc/binary, Chunk/binary>>);
        {error, closed} -> Acc
    end.

config_json(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"error\",\"log_format\":\"text\",\"shutdown_grace\":2,">>,
        <<"\"webui\":{\"bind\":\"127.0.0.1\",\"port\":0,\"username\":\"admin\",">>,
        <<"\"password\":\"topsecret\"},">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).
