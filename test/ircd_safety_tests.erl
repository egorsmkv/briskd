-module(ircd_safety_tests).
-include_lib("eunit/include/eunit.hrl").
-include("ircd_channel.hrl").
-include("ircd_client.hrl").

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
    {row, <<_/binary>> = Copied, 7, [Sub]} = ircd_wire:retain_fields({row, Sub, 7, [Sub]}),
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
    ?assertMatch({error, _}, Load(<<",\"max_sendq\":\"10\"">>)),
    ?assertMatch({ok, #{flood := null}}, Load(<<",\"flood\":null">>)),
    ?assertMatch(
        {ok, #{flood := #{messages_burst := 5}}},
        Load(<<",\"flood\":{\"messages_burst\":5}">>)
    ),
    ?assertMatch({error, _}, Load(<<",\"flood\":{\"unknown_key\":1}">>)),
    ?assertMatch({error, _}, Load(<<",\"flood\":{\"lines_burst\":0}">>)),
    ?assertMatch({ok, #{flood := #{lines_burst := 500}}}, ircd_config:load("config/ircd.json")),
    ?assertMatch({ok, #{flood := #{lines_burst := 500}}}, ircd_config:load("config/ircd.dev.json")),
    ?assertMatch(
        {ok, #{flood := #{lines_burst := 500}}}, ircd_config:load("config/ircd.prod.json")
    ).

flood_bucket_pure_test() ->
    %% Burst of 3, refill 1 per 1000 ms.
    {allow, U1, 100} = ircd_flood:consume_bucket(3000, 100, 100, 3, 1, 1000, 2),
    ?assertEqual(1000, U1),
    {allow, U2, 100} = ircd_flood:consume_bucket(U1, 100, 100, 3, 1, 1000, 1),
    ?assertEqual(0, U2),
    ?assertEqual(deny, ircd_flood:consume_bucket(U2, 100, 100, 3, 1, 1000, 1)),
    %% After 1000 ms, 1 token is restored.
    {allow, 0, 1100} = ircd_flood:consume_bucket(U2, 100, 1100, 3, 1, 1000, 1).

format_status_redacts_secrets_test() ->
    Calls = [
        {command, <<"PASS">>, [<<"s1">>], 10, []},
        {command, <<"OPER">>, [<<"admin">>, <<"s2">>], 15, []},
        {command, <<"AUTHENTICATE">>, [<<"c2VjcmV0">>], 20, []},
        {command, <<"REGISTER">>, [<<"alice">>, <<"a@b.c">>, <<"s3">>], 25, []},
        {command, <<"VERIFY">>, [<<"alice">>, <<"s4">>], 20, []},
        {command, <<"WEBIRC">>, [<<"s5">>, <<"gw">>, <<"h">>, <<"1.2.3.4">>], 30, []},
        {command_as, self(), <<"OPER">>, [<<"admin">>, <<"s6">>], 15, []}
    ],
    Status = ircd_state:format_status(#{
        message => {'$gen_call', {self(), make_ref()}, hd(Calls)},
        log => [{in, {'$gen_call', {self(), make_ref()}, C}} || C <- Calls]
    }),
    Formatted = io_lib:format("~p", [Status]),
    Flat = iolist_to_binary(Formatted),
    lists:foreach(
        fun(Secret) ->
            ?assertEqual(nomatch, binary:match(Flat, Secret))
        end,
        [<<"s1">>, <<"s2">>, <<"c2VjcmV0">>, <<"s3">>, <<"s4">>, <<"s5">>, <<"s6">>]
    ).

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
        roadmap_memory_bounds(Port),
        gc_process_options(Port),
        safelist_avoids_sendq_kill(Port),
        flood_control_disconnects_spammer(Port),
        sendq_limit(Port)
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

%% Verify OTP GC and mailbox tuning on core processes.
gc_process_options(Port) ->
    StatePid =
        case whereis(ircd_state) of
            Found when is_pid(Found) -> Found
        end,
    {message_queue_data, off_heap} = erlang:process_info(StatePid, message_queue_data),
    {garbage_collection, StateGc} = erlang:process_info(StatePid, garbage_collection),
    ?assertEqual(200, proplists:get_value(fullsweep_after, StateGc)),
    Client = register_client(Port, <<"gctest">>),
    try
        SessionPids = [P || {_, P, _, _} <- supervisor:which_children(ircd_sessions), is_pid(P)],
        ?assert(SessionPids =/= []),
        lists:foreach(
            fun(Pid) ->
                {garbage_collection, SessGc} = erlang:process_info(Pid, garbage_collection),
                ?assertEqual(20, proplists:get_value(fullsweep_after, SessGc))
            end,
            SessionPids
        )
    after
        gen_tcp:close(Client)
    end.

%% SAFELIST: 005 advertises SAFELIST, and a LIST returning more channels than
%% max_sendq (100 here) completes with 323 End of LIST instead of tripping SendQ.
safelist_avoids_sendq_kill(Port) ->
    ?assert(lists:member(<<"SAFELIST">>, ircd_isupport:tokens())),
    %% Seed 150 public channels directly in Mnesia (exceeds max_sendq = 100).
    lists:foreach(
        fun(N) ->
            Name = <<"#sl", (integer_to_binary(N))/binary>>,
            Key = ircd_wire:fold(Name),
            mnesia:dirty_write(#channel{
                key = Key,
                name = Name,
                topic = <<"Safelist topic">>,
                created = erlang:system_time(second)
            })
        end,
        lists:seq(1, 150)
    ),
    Viewer = register_client(Port, <<"slview">>),
    try
        send(Viewer, <<"LIST">>),
        Reply = recv_until_needle(Viewer, <<" 323 slview :End of LIST">>, <<>>),
        ?assert(has(Reply, <<" 322 slview #sl1 ">>)),
        ?assert(has(Reply, <<" 322 slview #sl150 ">>)),
        ?assert(has(Reply, <<" 323 slview :End of LIST">>)),
        ?assertNot(has(Reply, <<"Max SendQ exceeded">>))
    after
        gen_tcp:close(Viewer),
        lists:foreach(
            fun(N) ->
                mnesia:dirty_delete(channel, <<"#sl", (integer_to_binary(N))/binary>>)
            end,
            lists:seq(1, 150)
        )
    end.

config(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"error\",\"log_format\":\"text\",\"resource_delay\":0,">>,
        <<"\"max_sendq\":100,\"retention\":\"transient\",\"mnesia_dir\":\"">>,
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
     || #whowas{key = {F, _, _} = K} <- ets:tab2list(whowas), F =:= <<"wwa">>
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
    ?assertEqual(
        {error, invalid_markread},
        ircd_state_sync:receive_markread(
            <<"peer.test">>, <<"spoofed.test">>, [<<"acct">>, <<"#ok">>, <<"1">>]
        )
    ),
    ?assertEqual(
        {error, invalid_markread},
        ircd_state_sync:receive_markread(
            <<"peer.test">>, <<"peer.test">>, [<<"acct">>, <<"#ok">>, <<"-1">>]
        )
    ),
    ?assertEqual(
        {error, invalid_accountsync},
        ircd_state_sync:receive_accountsync(
            <<"peer.test">>,
            <<"spoofed.test">>,
            [<<"acct">>, <<"c2E=">>, <<"4096">>, <<"c2E=">>, <<"c2E=">>, <<"5">>]
        )
    ),
    ?assertEqual(
        {error, metadata_source_mismatch},
        ircd_state_sync:receive_metadata(
            <<"peer.test">>, <<"spoofed.test">>, [<<"#ok">>, <<"k">>, <<"*">>, <<"v">>]
        )
    ),
    ?assertEqual(
        {error, invalid_service},
        ircd_state_net:import_service(
            <<"peer.test">>, <<"spoofed.test">>, [<<"svc">>, <<"*">>, <<"t">>, <<"info">>]
        )
    ),
    ?assertEqual(
        {error, unknown_remote_source},
        ircd_state:server_command(
            <<"peer.test">>, <<"spoofed.test">>, <<"NJOIN">>, [<<"#ok">>, <<"rem">>]
        )
    ),
    ?assertEqual(
        {error, unknown_remote_source},
        ircd_state:server_command(
            <<"peer.test">>, <<"spoofed.test">>, <<"KILL">>, [<<"marker">>]
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
    true = ets:delete(ircd_holds, {nick, <<"kept">>}),
    %% An owned hold (a local client's nickname) blocks others; the owner's
    %% RECLAIM secret or account takes it back and clears it.
    Token = crypto:hash(sha256, <<"0123456789abcdef">>),
    Owned = fun(Nick, Account) ->
        true = ets:insert(
            ircd_holds, {{nick, Nick}, Future, #{token => Token, account => Account}}
        )
    end,
    Other = #client{pid = self(), host = <<"203.0.113.9">>},
    Owned(<<"owned">>, undefined),
    ?assert(ircd_state_net:nick_blocked(<<"OWNED">>, Other)),
    ok = ircd_conn:put(self(), reclaim, crypto:hash(sha256, <<"fedcba9876543210">>)),
    ?assert(ircd_state_net:nick_blocked(<<"owned">>, Other)),
    ok = ircd_conn:put(self(), reclaim, Token),
    ?assertNot(ircd_state_net:nick_blocked(<<"owned">>, Other)),
    ?assertEqual([], ets:lookup(ircd_holds, {nick, <<"owned">>})),
    ok = ircd_conn:remove(self(), reclaim),
    Owned(<<"acct">>, <<"Carol">>),
    ?assert(ircd_state_net:nick_blocked(<<"acct">>, Other)),
    ok = ircd_conn:put(self(), account, <<"carol">>),
    ?assertNot(ircd_state_net:nick_blocked(<<"acct">>, Other)),
    ok = ircd_conn:remove(self(), account),
    %% A hold with no owner (netsplit, KILL) blocks everyone.
    true = ets:insert(ircd_holds, {{nick, <<"split">>}, Future}),
    ?assert(ircd_state_net:nick_blocked(<<"split">>, Other)),
    true = ets:delete(ircd_holds, {nick, <<"split">>}),
    %% Owned holds expire like the others.
    true = ets:insert(
        ircd_holds, {{nick, <<"old">>}, Past, #{host => <<"h">>, account => undefined}}
    ),
    ok = ircd_state_net:expire_holds(),
    ?assertEqual([], ets:lookup(ircd_holds, {nick, <<"old">>})).

roadmap_memory_bounds(Port) ->
    %% 1. Disconnected pids are pruned from channel `invited` lists.
    Host = register_client(Port, <<"invhost">>),
    Guest = register_client(Port, <<"invguest">>),
    send(Host, <<"JOIN #invprune">>),
    _ = sync(Host),
    send(Host, <<"INVITE invguest #invprune">>),
    _ = sync(Host),
    [#channel{invited = Invited1}] = mnesia:dirty_read(channel, <<"#invprune">>),
    ?assertEqual(1, length(Invited1)),
    send(Guest, <<"QUIT">>),
    close(Guest),
    _ = sync(Host),
    [Chan2] = mnesia:dirty_read(channel, <<"#invprune">>),
    ?assertEqual([], element(8, Chan2)),
    %% 2. Safe channel short-name index and empty safe channel cap.
    send(Host, <<"JOIN !safecap1">>),
    send(Host, <<"JOIN !safecap2">>),
    _ = sync(Host),
    ?assertMatch([{<<"safecap1">>, _}], ets:lookup(ircd_safe_channels, <<"safecap1">>)),
    ?assertMatch([{<<"safecap2">>, _}], ets:lookup(ircd_safe_channels, <<"safecap2">>)),
    [{_, FullSafe1}] = ets:lookup(ircd_safe_channels, <<"safecap1">>),
    [{_, FullSafe2}] = ets:lookup(ircd_safe_channels, <<"safecap2">>),
    send(Host, <<"PART ", FullSafe1/binary>>),
    send(Host, <<"PART ", FullSafe2/binary>>),
    _ = sync(Host),
    OldCfg = persistent_term:get({ircd_state, config}),
    try
        persistent_term:put(
            {ircd_state, config},
            OldCfg#{
                max_empty_channels => 1,
                max_read_markers => 2,
                max_direct_conversations => 2,
                max_accounts => 2,
                max_peer_users => 1,
                max_peer_servers => 1,
                max_peer_services => 1
            }
        ),
        ok = ircd_state_channel:prune_empty_channels(),
        RemainingSafe =
            ets:lookup(ircd_safe_channels, <<"safecap1">>) ++
                ets:lookup(ircd_safe_channels, <<"safecap2">>),
        ?assertEqual(1, length(RemainingSafe)),
        %% 3. Per-account read-marker cap (max_read_markers = 2).
        updated = ircd_state_history:remote_marker(<<"capuser">>, <<"#m1">>, 100),
        updated = ircd_state_history:remote_marker(<<"capuser">>, <<"#m2">>, 200),
        updated = ircd_state_history:remote_marker(<<"capuser">>, <<"#m3">>, 300),
        Markers = [
            T
         || {A, T} <- mnesia:dirty_all_keys(read_marker), A =:= <<"capuser">>
        ],
        ?assertEqual([<<"#m2">>, <<"#m3">>], lists:sort(Markers)),
        %% 4. Per-account direct-history conversation cap (max_direct_conversations = 2).
        E1 = ircd_state_history:entry(
            <<"PRIVMSG">>, <<"a!u@h">>, <<"1">>, <<"id1">>, 10, [], <<"capuser">>
        ),
        E2 = ircd_state_history:entry(
            <<"PRIVMSG">>, <<"a!u@h">>, <<"2">>, <<"id2">>, 20, [], <<"capuser">>
        ),
        E3 = ircd_state_history:entry(
            <<"PRIVMSG">>, <<"a!u@h">>, <<"3">>, <<"id3">>, 30, [], <<"capuser">>
        ),
        ok = ircd_state_history:note_direct(
            {<<"capuser">>, <<"a">>}, {<<"u1">>, <<"u1">>}, <<"u1">>, E1
        ),
        ok = ircd_state_history:note_direct(
            {<<"capuser">>, <<"a">>}, {<<"u2">>, <<"u2">>}, <<"u2">>, E2
        ),
        ok = ircd_state_history:note_direct(
            {<<"capuser">>, <<"a">>}, {<<"u3">>, <<"u3">>}, <<"u3">>, E3
        ),
        Convos = [
            K
         || K <- ircd_state:table_keys(direct_history),
            element(1, K) =:= {account, <<"capuser">>} orelse
                element(2, K) =:= {account, <<"capuser">>}
        ],
        ?assertEqual(2, length(Convos)),
        %% 5. Account cap (max_accounts = 2).
        {ok, _} = ircd_account:create(<<"acct1">>, undefined, <<"password123">>, [], undefined),
        {ok, _} = ircd_account:create(<<"acct2">>, undefined, <<"password123">>, [], undefined),
        ?assertEqual(
            {error, account_limit_reached},
            ircd_account:validate_new(<<"acct3">>, <<"password123">>)
        ),
        %% 6. Per-peer caps on introduced users, servers, and services.
        ok = ircd_state_net:register_adjacent(<<"peer.test">>, <<"1">>, inbound, self()),
        ok = ircd_state_link:import_remote_nick(
            <<"peer.test">>,
            <<"peer.test">>,
            [<<"rem1">>, <<"1">>, <<"u">>, <<"h.test">>, <<"1">>, <<"+">>, <<"R">>]
        ),
        ?assertEqual(
            {error, too_many_remote_users},
            ircd_state_link:import_remote_nick(
                <<"peer.test">>,
                <<"peer.test">>,
                [<<"rem2">>, <<"1">>, <<"u">>, <<"h.test">>, <<"1">>, <<"+">>, <<"R">>]
            )
        ),
        ok = ircd_state_net:introduce_server(
            <<"peer.test">>, <<"peer.test">>, <<"leaf1.test">>, <<"2">>, <<"2">>, <<"L1">>
        ),
        ?assertEqual(
            {error, too_many_remote_servers},
            ircd_state_net:introduce_server(
                <<"peer.test">>, <<"peer.test">>, <<"leaf2.test">>, <<"2">>, <<"3">>, <<"L2">>
            )
        ),
        ok = ircd_state_net:import_service(
            <<"peer.test">>, <<"peer.test">>, [<<"svc1">>, <<"*">>, <<"t">>, <<"S1">>]
        ),
        ?assertEqual(
            {error, too_many_remote_services},
            ircd_state_net:import_service(
                <<"peer.test">>, <<"peer.test">>, [<<"svc2">>, <<"*">>, <<"t">>, <<"S2">>]
            )
        ),
        ircd_state_net:split(<<"peer.test">>, <<"done">>, undefined)
    after
        persistent_term:put({ircd_state, config}, OldCfg)
    end,
    close(Host).

flood_control_disconnects_spammer(Port) ->
    OldCfg = persistent_term:get({ircd_state, config}),
    FloodCfg = (ircd_flood:default_config())#{
        messages_burst => 3,
        messages_per_second => 1,
        register_per_minute => 1
    },
    try
        persistent_term:put({ircd_state, config}, OldCfg#{flood => FloodCfg}),
        %% Per-host REGISTER rate limit (1 per minute).
        Reg = register_client(Port, <<"reglim">>),
        send(Reg, <<"CAP REQ draft/account-registration">>),
        _ = sync(Reg),
        ?assert(ircd_flood:allow_register(<<"198.51.100.9">>)),
        ?assertNot(ircd_flood:allow_register(<<"198.51.100.9">>)),
        close(Reg),
        %% Message flood closes the connection with Excess Flood.
        Spam = register_client(Port, <<"spammer">>),
        send(Spam, <<"PRIVMSG spammer :m1">>),
        send(Spam, <<"PRIVMSG spammer :m2">>),
        send(Spam, <<"PRIVMSG spammer :m3">>),
        send(Spam, <<"PRIVMSG spammer :m4">>),
        Data = read_all(Spam, <<>>),
        ?assert(has(Data, <<"ERROR :Closing Link: 127.0.0.1 (Excess Flood)">>)),
        close(Spam)
    after
        persistent_term:put({ircd_state, config}, OldCfg)
    end.

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
        {ok, <<_/binary>> = Data} -> read_all(S, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

%% The session's socket peer port is the client's local port.
peer_port(Pid) ->
    case sys:get_state(Pid, 1000) of
        {tcp, Socket, _, _, _} when is_port(Socket) ->
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
            {ok, <<_/binary>> = Data} = gen_tcp:recv(S, 0, 5000),
            recv_until(S, Needle, <<Acc/binary, Data/binary>>)
    end.

recv_until_needle(S, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        {_, _} ->
            Acc;
        nomatch ->
            {ok, <<_/binary>> = Data} = gen_tcp:recv(S, 0, 5000),
            recv_until_needle(S, Needle, <<Acc/binary, Data/binary>>)
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
