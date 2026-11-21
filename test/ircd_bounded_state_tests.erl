-module(ircd_bounded_state_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ircd/include/ircd_state.hrl").

%% State that used to grow or survive without bound: memberless
%% remote_channel rows, a link process that died without its own cleanup,
%% ETS tables owned by short-lived request handlers, expired password-reset
%% codes, and saved rejoin channels of deleted accounts.

bounded_state_test_() ->
    {timeout, 60, fun run/0}.

run() ->
    Dir = filename:join(
        "/tmp", "ircd-bounded-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config_json(Db)),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    try
        sweep_remote_channels(),
        link_process_down(),
        table_owners(),
        password_resets(),
        account_channels()
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
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
    ?assertEqual(2, ircd_state_link:sweep_remote_channels()),
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
        ok = ircd_state:register_adjacent(<<"ghost.test">>, <<"1">>, outbound),
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
    ?assertMatch([_], ets:lookup(ircd_outbound_ready, <<"ghost.test">>)),
    exit(Link, kill),
    ok = wait_until(fun() -> mnesia:dirty_read(remote_client, <<"phantom">>) =:= [] end),
    ?assertEqual([], ets:lookup(ircd_outbound_ready, <<"ghost.test">>)),
    ?assertEqual([], mnesia:dirty_read(known_server, <<"ghost.test">>)).

%% Tables shared by request handlers belong to the long-lived WebUI
%% process, so they outlive each request.
table_owners() ->
    Webui = whereis(ircd_webui),
    ?assert(is_pid(Webui)),
    lists:foreach(
        fun(Table) -> ?assertEqual({Table, Webui}, {Table, ets:info(Table, owner)}) end,
        [ircd_link_preview_cache, ircd_webui_uploads, ircd_webui_sessions, ircd_webui_logins]
    ).

%% Codes nobody completes are swept once expired.
password_resets() ->
    Table =
        case ets:whereis(ircd_password_reset) of
            undefined -> ets:new(ircd_password_reset, [named_table, set, public]);
            T -> T
        end,
    Now = erlang:system_time(millisecond),
    true = ets:insert(Table, [
        {<<"old@example.org">>, <<"a">>, <<"a">>, <<"h">>, Now - 1000},
        {<<"new@example.org">>, <<"b">>, <<"b">>, <<"h">>, Now + 600000}
    ]),
    ok = ircd_state_v3:expire_password_resets(),
    ?assertEqual([], ets:lookup(Table, <<"old@example.org">>)),
    ?assertMatch([_], ets:lookup(Table, <<"new@example.org">>)).

%% Deleting an account drops the channels saved for its next login.
account_channels() ->
    {ok, _} = ircd_ctl:run(["create-account", "leaver", "leaver-pass-1"]),
    Table =
        case ets:whereis(ircd_account_channels) of
            undefined -> ets:new(ircd_account_channels, [named_table, set, public]);
            T -> T
        end,
    true = ets:insert(Table, {<<"leaver">>, [<<"#a">>]}),
    {ok, _} = ircd_ctl:run(["delete-account", "leaver"]),
    ?assertEqual([], ets:lookup(Table, <<"leaver">>)).

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
