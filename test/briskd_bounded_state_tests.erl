-module(briskd_bounded_state_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("briskd/include/briskd_state.hrl").

%% State that used to grow or survive without bound: memberless
%% remote_channel rows, a link process that died without its own cleanup,
%% ETS tables owned by short-lived request handlers, expired password-reset
%% codes, and saved rejoin channels of deleted accounts.

bounded_state_test_() ->
    {timeout, 60, fun run/0}.

run() ->
    Dir = filename:join(
        "/tmp", "briskd-bounded-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "briskd.json"),
    ok = file:write_file(Config, config_json(Db)),
    os:putenv("BRISKD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(briskd),
    try
        sweep_remote_channels(),
        link_process_down(),
        table_owners(),
        password_resets(),
        account_channels(),
        overloaded_command()
    after
        _ = application:stop(briskd),
        os:unsetenv("BRISKD_CONFIG")
    end.

%% A row with no members (left by a peer's TOPIC, MODE, or an INVITE) is
%% deleted; a row with members keeps them and loses its unused invites.
sweep_remote_channels() ->
    Member = #{<<"bob">> => {<<"peer.test">>, []}},
    ok = mnesia:dirty_write(#remote_channel{key = <<"#empty">>, name = <<"#empty">>}),
    ok = mnesia:dirty_write(#remote_channel{
        key = <<"#topic">>, name = <<"#topic">>, flags = #{topic => <<"t">>}
    }),
    ok = mnesia:dirty_write(#remote_channel{
        key = <<"#busy">>,
        name = <<"#busy">>,
        members = Member,
        invited = #{<<"carol">> => true}
    }),
    ?assertEqual(2, briskd_state_link:sweep_remote_channels()),
    ?assertEqual([], mnesia:dirty_read(remote_channel, <<"#empty">>)),
    ?assertEqual([], mnesia:dirty_read(remote_channel, <<"#topic">>)),
    ?assertMatch(
        [#remote_channel{members = Member, invited = Invited}] when map_size(Invited) =:= 0,
        mnesia:dirty_read(remote_channel, <<"#busy">>)
    ),
    mnesia:dirty_delete(remote_channel, <<"#busy">>).

%% A registered link process that is killed (no terminate, no
%% server_disconnect) still splits its peer: the users behind it go.
link_process_down() ->
    Test = self(),
    Link = spawn(fun() ->
        ok = briskd_state:register_adjacent(<<"ghost.test">>, <<"1">>, outbound),
        Test ! registered,
        receive
            never -> ok
        end
    end),
    receive
        registered -> ok
    after 5000 -> error(not_registered)
    end,
    ok = mnesia:dirty_write(#remote_client{
        key = <<"phantom">>,
        peer = <<"ghost.test">>,
        nick = <<"phantom">>,
        user = <<"p">>,
        host = <<"ghost.test">>,
        real = <<"P">>,
        server = <<"ghost.test">>
    }),
    ?assertMatch([_], ets:lookup(briskd_outbound_ready, <<"ghost.test">>)),
    exit(Link, kill),
    ok = wait_until(fun() -> mnesia:dirty_read(remote_client, <<"phantom">>) =:= [] end),
    ?assertEqual([], ets:lookup(briskd_outbound_ready, <<"ghost.test">>)),
    ?assertEqual([], mnesia:dirty_read(known_server, <<"ghost.test">>)).

%% Tables shared by request handlers belong to the long-lived WebUI
%% process, so they outlive each request.
table_owners() ->
    Webui = whereis(briskd_webui),
    ?assert(is_pid(Webui)),
    lists:foreach(
        fun(Table) -> ?assertEqual({Table, Webui}, {Table, ets:info(Table, owner)}) end,
        [
            briskd_link_preview_cache,
            briskd_webui_uploads,
            briskd_webui_sessions,
            briskd_webui_logins
        ]
    ).

%% Codes nobody completes are swept once expired.
password_resets() ->
    Table =
        case ets:whereis(briskd_password_reset) of
            undefined -> ets:new(briskd_password_reset, [named_table, set, public]);
            T -> T
        end,
    Now = erlang:system_time(millisecond),
    true = ets:insert(Table, [
        {<<"old@example.org">>, <<"a">>, <<"a">>, <<"h">>, Now - 1000},
        {<<"new@example.org">>, <<"b">>, <<"b">>, <<"h">>, Now + 600000}
    ]),
    ok = briskd_state_v3:expire_password_resets(),
    ?assertEqual([], ets:lookup(Table, <<"old@example.org">>)),
    ?assertMatch([_], ets:lookup(Table, <<"new@example.org">>)).

%% Deleting an account drops the channels saved for its next login.
account_channels() ->
    {ok, _} = briskd_ctl:run(["create-account", "leaver", "leaver-pass-1"]),
    Table =
        case ets:whereis(briskd_account_channels) of
            undefined -> ets:new(briskd_account_channels, [named_table, set, public]);
            T -> T
        end,
    true = ets:insert(Table, {<<"leaver">>, [<<"#a">>]}),
    {ok, _} = briskd_ctl:run(["delete-account", "leaver"]),
    ?assertEqual([], ets:lookup(Table, <<"leaver">>)).

%% A command the state process does not apply within its deadline closes
%% the client with "Server overloaded" instead of crashing the session, and
%% the server serves new clients once it catches up.
overloaded_command() ->
    Port = listener_port(),
    Sock = client(Port, <<"slowpoke">>),
    ok = application:set_env(briskd, command_timeout, 200),
    State =
        case whereis(briskd_state) of
            P when is_pid(P) -> P
        end,
    ok = sys:suspend(State),
    try
        ok = gen_tcp:send(Sock, <<"LUSERS\r\n">>),
        Closed = recv_all(Sock, <<>>),
        ?assertNotEqual(nomatch, binary:match(Closed, <<"Server overloaded">>))
    after
        ok = sys:resume(State),
        ok = application:unset_env(briskd, command_timeout),
        gen_tcp:close(Sock)
    end,
    ?assertEqual(State, whereis(briskd_state)),
    Next = client(Port, <<"nextone">>),
    gen_tcp:close(Next).

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(briskd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
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

%% Everything until the server closes the connection.
recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, <<_/binary>> = Bin} -> recv_all(Sock, <<Acc/binary, Bin/binary>>);
        {error, closed} -> Acc
    end.

wait_until(Fun) -> wait_until(Fun, 50).

wait_until(_Fun, 0) ->
    erlang:error(timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(Fun, N - 1)
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
