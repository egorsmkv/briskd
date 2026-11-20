-module(ircd_ctl_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

offline_commands_test() ->
    ?assertMatch({ok, _}, ircd_ctl:run(["help"])),
    ?assertMatch({error, _}, ircd_ctl:run(["no-such-command"])),
    {ok, JsonErr} = catch_json_error(["no-such-command", "--json"]),
    ?assertMatch(#{<<"error">> := <<"unknown_command">>}, json:decode(JsonErr)),

    Dir = tmp_dir("offline"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Good = filename:join(Dir, "good.json"),
    Bad = filename:join(Dir, "bad.json"),
    ok = file:write_file(
        Good,
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":6667,\"tls_port\":null}">>
    ),
    ok = file:write_file(Bad, <<"{\"tcp_port\":99999}">>),
    try
        ?assertMatch({ok, _}, ircd_ctl:run(["check-config", Good])),
        {ok, GoodJson} = ircd_ctl:run(["check-config", Good, "--json"]),
        ?assertMatch(
            #{<<"status">> := <<"valid">>, <<"name">> := <<"irc.test">>},
            json:decode(GoodJson)
        ),
        ?assertMatch({error, _}, ircd_ctl:run(["check-config", Bad]))
    after
        file:delete(Good),
        file:delete(Bad),
        file:del_dir(Dir)
    end.

live_ctl_test_() ->
    {timeout, 60, fun live_ctl/0}.

live_ctl() ->
    Dir = tmp_dir("live"),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "ircd.json"),
    SockPath = "/tmp/ircdctl-" ++ integer_to_list(erlang:system_time(nanosecond)) ++ ".sock",
    Backup = filename:join(Dir, "mnesia.bak"),
    ok = file:write_file(Config, config_json(Db)),
    os:putenv("IRCD_CONFIG", Config),
    os:putenv("IRCD_CTL_SOCKET", SockPath),
    {ok, _} = application:ensure_all_started(ircd),
    try
        %% Verify Unix domain socket exists with 0600 permissions.
        {ok, #file_info{mode = Mode}} = file:read_file_info(SockPath),
        ?assert(is_integer(Mode) andalso Mode band 8#777 =:= 8#600),

        %% ping & status
        {ok, PingJson} = ircd_ctl:run(["ping", "--json"]),
        ?assertMatch(#{<<"status">> := <<"ok">>, <<"reply">> := <<"pong">>}, json:decode(PingJson)),
        {ok, StatusJson} = ircd_ctl:run(["status", "--json"]),
        ?assertMatch(
            #{<<"status">> := <<"running">>, <<"name">> := <<"irc.test">>, <<"sessions">> := 0},
            json:decode(StatusJson)
        ),

        %% log-level get/set/reject
        {ok, Lvl0} = ircd_ctl:run(["log-level", "--json"]),
        ?assertMatch(#{<<"log_level">> := <<"warning">>}, json:decode(Lvl0)),
        {ok, Lvl1} = ircd_ctl:run(["log-level", "info", "--json"]),
        ?assertMatch(
            #{<<"status">> := <<"updated">>, <<"log_level">> := <<"info">>}, json:decode(Lvl1)
        ),
        ?assertMatch({error, _}, ircd_ctl:run(["log-level", "bogus"])),
        {ok, _} = ircd_ctl:run(["log-level", "warning"]),

        %% rehash
        {ok, RehashJson} = ircd_ctl:run(["rehash", "--json"]),
        ?assertMatch(#{<<"status">> := <<"rehashed">>}, json:decode(RehashJson)),

        %% Register a client and join a channel
        Port = listener_port(),
        Alice = register_client(Port, <<"alice">>),
        ok = gen_tcp:send(Alice, <<"JOIN #ops\r\n">>),
        _ = recv_until(Alice, <<" 366 ">>, <<>>),

        {ok, ClientsJson} = ircd_ctl:run(["clients", "--json"]),
        #{<<"clients">> := Clients} = json:decode(ClientsJson),
        ?assertEqual(1, length(Clients)),
        ?assertMatch([#{<<"nick">> := <<"alice">>}], Clients),

        {ok, ChansJson} = ircd_ctl:run(["channels", "--json"]),
        #{<<"channels">> := Chans} = json:decode(ChansJson),
        ?assertMatch([#{<<"name">> := <<"#ops">>, <<"local_members">> := 1}], Chans),

        {ok, LinksJson} = ircd_ctl:run(["links", "--json"]),
        ?assertMatch(
            #{<<"configured">> := [], <<"connected">> := [], <<"count">> := 0},
            json:decode(LinksJson)
        ),

        %% Account management
        {ok, CreatedJson} = ircd_ctl:run([
            "create-account", "devops", "s3cr3tpass", "ops@example.com", "--json"
        ]),
        ?assertMatch(
            #{<<"status">> := <<"created">>, <<"account">> := <<"devops">>},
            json:decode(CreatedJson)
        ),
        ?assertMatch(
            {error, _},
            ircd_ctl:run(["create-account", "devops", "s3cr3tpass"])
        ),
        {ok, AcctsJson} = ircd_ctl:run(["accounts", "--json"]),
        #{<<"accounts">> := Accts} = json:decode(AcctsJson),
        ?assertMatch([#{<<"name">> := <<"devops">>}], Accts),
        {ok, DelJson} = ircd_ctl:run(["delete-account", "devops", "--json"]),
        ?assertMatch(
            #{<<"status">> := <<"deleted">>, <<"account">> := <<"devops">>}, json:decode(DelJson)
        ),

        %% Kick client
        {ok, KickJson} = ircd_ctl:run(["kick-client", "alice", "Maintenance", "--json"]),
        ?assertMatch(
            #{<<"status">> := <<"kicked">>, <<"nick">> := <<"alice">>}, json:decode(KickJson)
        ),
        AliceRest = read_all(Alice),
        ?assert(has(AliceRest, <<"KILL alice :Maintenance">>)),
        ?assertMatch({error, _}, ircd_ctl:run(["kick-client", "nobody"])),

        %% Mnesia backup
        {ok, BakJson} = ircd_ctl:run(["backup", Backup, "--json"]),
        ?assertMatch(#{<<"status">> := <<"backed_up">>}, json:decode(BakJson)),
        ?assert(filelib:is_regular(Backup)),

        %% Exercise live Unix domain socket via bin/ircdctl
        Cmd =
            "IRCD_CTL_SOCKET='" ++ SockPath ++
                "' ./bin/ircdctl status --json",
        Out = list_to_binary(os:cmd(Cmd)),
        ?assertMatch(
            #{<<"status">> := <<"running">>, <<"name">> := <<"irc.test">>},
            json:decode(string:trim(Out))
        )
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG"),
        os:unsetenv("IRCD_CTL_SOCKET"),
        _ = file:delete(SockPath),
        _ = file:delete(Backup)
    end.

catch_json_error(Args) ->
    case ircd_ctl:run(Args) of
        {error, Out} -> {ok, Out};
        Other -> Other
    end.

tmp_dir(Tag) ->
    filename:join(
        "/tmp",
        "ircd-ctl-" ++ Tag ++ "-" ++ integer_to_list(erlang:system_time(nanosecond))
    ).

config_json(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",\"shutdown_grace\":2,">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).

register_client(Port, Nick) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
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
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.
