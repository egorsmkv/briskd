-module(briskd_dronebl_tests).
-include_lib("eunit/include/eunit.hrl").

pure_helpers_test() ->
    ?assertEqual(
        "4.3.2.1.dnsbl.dronebl.org",
        briskd_dronebl:query_name({1, 2, 3, 4}, <<"dnsbl.dronebl.org">>)
    ),
    ?assertEqual(
        "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.dnsbl.dronebl.org",
        briskd_dronebl:query_name({16#2001, 16#0db8, 0, 0, 0, 0, 0, 1}, "dnsbl.dronebl.org")
    ),

    ?assertEqual({ok, {198, 51, 100, 7}}, briskd_dronebl:parse_peer(<<"198.51.100.7">>)),
    ?assertEqual({ok, {0, 0, 0, 0, 0, 0, 0, 1}}, briskd_dronebl:parse_peer(<<"0::1">>)),
    ?assertEqual({ok, {0, 0, 0, 0, 0, 0, 0, 1}}, briskd_dronebl:parse_peer("::1")),
    ?assertEqual(error, briskd_dronebl:parse_peer(<<"not-an-ip">>)),

    ?assert(briskd_dronebl:is_private({127, 0, 0, 1})),
    ?assert(briskd_dronebl:is_private({10, 1, 2, 3})),
    ?assert(briskd_dronebl:is_private({172, 16, 0, 1})),
    ?assert(briskd_dronebl:is_private({192, 168, 1, 1})),
    ?assert(briskd_dronebl:is_private({100, 64, 0, 1})),
    ?assert(briskd_dronebl:is_private({0, 0, 0, 0, 0, 0, 0, 1})),
    ?assert(briskd_dronebl:is_private({0, 0, 0, 0, 0, 16#FFFF, 16#7F00, 1})),
    ?assertNot(briskd_dronebl:is_private({198, 51, 100, 7})),
    ?assertNot(briskd_dronebl:is_private({16#2001, 16#0db8, 0, 0, 0, 0, 0, 1})),

    ?assertEqual(clean, briskd_dronebl:classify_answers([], all)),
    ?assertEqual(clean, briskd_dronebl:classify_answers([{127, 0, 0, 1}], all)),
    ?assertEqual(clean, briskd_dronebl:classify_answers([{198, 51, 100, 1}], all)),
    ?assertEqual(
        {listed, 3, <<"IRC Drone">>},
        briskd_dronebl:classify_answers([{127, 0, 0, 3}], all)
    ),
    ?assertEqual(
        clean,
        briskd_dronebl:classify_answers([{127, 0, 0, 19}], [3, 8])
    ),
    ?assertEqual(
        {listed, 8, <<"SOCKS Proxy">>},
        briskd_dronebl:classify_answers([{127, 0, 0, 19}, {127, 0, 0, 8}], [3, 8])
    ).

config_validation_test() ->
    Load = fun(Extra) ->
        Path = filename:join(
            "/tmp",
            "briskd-dronebl-cfg-" ++ integer_to_list(erlang:system_time(nanosecond)) ++ ".json"
        ),
        ok = file:write_file(Path, [<<"{\"tcp_port\":6667">>, Extra, <<"}">>]),
        try
            briskd_config:load(Path)
        after
            file:delete(Path)
        end
    end,
    ?assertMatch({ok, #{dronebl := #{enabled := false}}}, Load(<<>>)),
    ?assertMatch(
        {ok, #{dronebl := #{enabled := true, zone := <<"dnsbl.dronebl.org">>, types := all}}},
        Load(<<",\"dronebl\":true">>)
    ),
    ?assertMatch(
        {ok, #{
            dronebl := #{
                enabled := true,
                zone := <<"rbl.example.org">>,
                types := [3, 8],
                ban_ttl := 600,
                skip_private := false
            }
        }},
        Load(
            <<",\"dronebl\":{\"enabled\":true,\"zone\":\"rbl.example.org\",\"types\":[8,3],\"ban_ttl\":600,\"skip_private\":false}">>
        )
    ),
    ?assertMatch({error, _}, Load(<<",\"dronebl\":123">>)),
    ?assertMatch({error, _}, Load(<<",\"dronebl\":{\"types\":[1]}">>)),
    ?assertMatch({error, _}, Load(<<",\"dronebl\":{\"types\":[]}">>)),
    ?assertMatch({error, _}, Load(<<",\"dronebl\":{\"ban_ttl\":10}">>)),
    ?assertMatch({error, _}, Load(<<",\"dronebl\":{\"zone\":\"bad zone\"}">>)).

live_lookup_and_ban_test_() ->
    {timeout, 60, fun live_lookup_and_ban/0}.

live_lookup_and_ban() ->
    Dir = filename:join(
        "/tmp",
        "briskd-dronebl-live-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "briskd.json"),
    ok = file:write_file(Config, config_json(Db)),
    os:putenv("BRISKD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(briskd),
    Counter = atomics:new(1, []),
    try
        ?assert(briskd_dronebl:is_enabled()),
        ok = briskd_dronebl:set_resolver(fun("1.0.0.127.dnsbl.dronebl.org", _Timeout) ->
            atomics:add(Counter, 1, 1),
            {ok, [{127, 0, 0, 3}]}
        end),
        Port = listener_port(),

        %% First connection triggers async lookup, receives ERROR, and bans 127.0.0.1.
        Sock1 = connect(Port),
        Lines1 = read_all(Sock1),
        ?assert(has(Lines1, <<"ERROR :Closing Link: irc.test (Banned: listed in DroneBL">>)),
        ?assert(has(Lines1, <<"IRC Drone, type 3">>)),
        ?assertEqual(1, atomics:get(Counter, 1)),
        ?assertMatch([#{ip := <<"127.0.0.1">>, code := 3}], briskd_dronebl:list_bans()),

        %% Second connection hits the ban cache immediately (no second DNS lookup).
        Sock2 = connect(Port),
        Lines2 = read_all(Sock2),
        ?assert(has(Lines2, <<"Banned: listed in DroneBL">>)),
        ?assertEqual(1, atomics:get(Counter, 1)),
        ?assertMatch(#{enabled := true, bans := 1}, briskd_dronebl:stats()),

        %% Unban and switch resolver to clean; client should register normally.
        ok = briskd_dronebl:unban(<<"127.0.0.1">>),
        ?assertEqual([], briskd_dronebl:list_bans()),
        ok = briskd_dronebl:set_resolver(fun("1.0.0.127.dnsbl.dronebl.org", _Timeout) ->
            %% A slow resolver: registration always finishes first, as it
            %% did on a busy CI runner.
            timer:sleep(200),
            atomics:add(Counter, 1, 1),
            {ok, []}
        end),
        %% The lookup is asynchronous: the client may register (001) before
        %% the worker has asked the resolver, so wait for it.
        Sock3 = register_client(Port, <<"alice">>),
        ok = wait_until(fun() -> atomics:get(Counter, 1) =:= 2 end),
        %% ...and for its clean result to be cached.
        ok = wait_until(fun() -> maps:get(cached_clean, briskd_dronebl:stats(), 0) >= 1 end),
        ok = gen_tcp:close(Sock3),

        %% Subsequent connection hits the clean cache synchronously: no lookup
        %% is started, so the count stays 2.
        Sock4 = register_client(Port, <<"bob">>),
        ?assertEqual(2, atomics:get(Counter, 1)),
        ?assertMatch(#{in_flight := 0}, briskd_dronebl:stats()),
        ok = gen_tcp:close(Sock4),

        %% Resolver timeout fails open so legitimate users can still connect.
        ok = briskd_dronebl:unban(<<"127.0.0.1">>),
        ok = briskd_dronebl:set_resolver(fun(_, _) ->
            atomics:add(Counter, 1, 1),
            {error, timeout}
        end),
        Sock5 = register_client(Port, <<"carol">>),
        ok = wait_until(fun() -> atomics:get(Counter, 1) =:= 3 end),
        ok = gen_tcp:close(Sock5)
    after
        _ = application:stop(briskd),
        os:unsetenv("BRISKD_CONFIG")
    end.

config_json(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",\"shutdown_grace\":2,">>,
        <<"\"dronebl\":{\"enabled\":true,\"skip_private\":false,\"ban_ttl\":600,\"cache_ttl\":300},">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

register_client(Port, Nick) ->
    Sock = connect(Port),
    ok = gen_tcp:send(Sock, [<<"NICK ">>, Nick, <<"\r\nUSER ">>, Nick, <<" 0 * :T\r\n">>]),
    ?assert(has(recv_until(Sock, <<" 001 ">>, <<>>), <<" 001 ">>)),
    Sock.

recv_until(Sock, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            {ok, <<_/binary>> = Bin} = gen_tcp:recv(Sock, 0, 5000),
            recv_until(Sock, Needle, <<Acc/binary, Bin/binary>>);
        _ ->
            Acc
    end.

read_all(Sock) ->
    read_all(Sock, <<>>).

read_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, <<_/binary>> = Bin} -> read_all(Sock, <<Acc/binary, Bin/binary>>);
        {error, closed} -> Acc
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(briskd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.

%% Poll `Fun` every 20 ms, for up to 5 seconds.
wait_until(Fun) -> wait_until(Fun, 250).

wait_until(_Fun, 0) ->
    erlang:error(timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(Fun, N - 1)
    end.
