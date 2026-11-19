-module(ircd_shutdown_tests).
-include_lib("eunit/include/eunit.hrl").

%% Graceful shutdown: application:stop(ircd) runs ircd_app:prep_stop/1, which
%% notifies each client, sends ERROR (RFC 2812 3.7.4), and closes the sockets
%% before the supervision tree stops.

drain_test_() ->
    {timeout, 60, fun drain/0}.

drain() ->
    Dir = filename:join(
        "/tmp", "ircd-shutdown-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(filename:join(Dir, "db"))),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    try
        Port = listener_port(),
        Alice = register_client(Port, <<"alice">>),
        Unregistered = connect(Port),
        %% Both connections must have a session before the drain starts; a
        %% connection still in the accept backlog has nothing to drain.
        wait_sessions(2, 100),
        Started = erlang:monotonic_time(millisecond),
        ok = application:stop(ircd),
        Elapsed = erlang:monotonic_time(millisecond) - Started,
        %% Every session closed on its own, well inside shutdown_grace (3 s).
        ?assert(Elapsed < 3000),
        Lines = read_all(Alice),
        ?assert(has(Lines, <<" NOTICE * :Server shutting down">>)),
        ?assert(has(Lines, <<"ERROR :Closing Link: irc.test (Server shutting down)">>)),
        ?assert(has(read_all(Unregistered), <<"ERROR :Closing Link">>)),
        ?assertMatch({error, _}, gen_tcp:connect("127.0.0.1", Port, [binary], 1000))
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

shutdown_grace_config_test() ->
    Load = fun(Extra) ->
        Path = filename:join(
            "/tmp", "ircd-grace-" ++ integer_to_list(erlang:system_time(nanosecond)) ++ ".json"
        ),
        ok = file:write_file(Path, [<<"{\"tcp_port\":6667">>, Extra, <<"}">>]),
        try
            ircd_config:load(Path)
        after
            file:delete(Path)
        end
    end,
    ?assertMatch({ok, #{shutdown_grace := 5}}, Load(<<>>)),
    ?assertMatch({ok, #{shutdown_grace := 0}}, Load(<<",\"shutdown_grace\":0">>)),
    ?assertMatch({ok, #{shutdown_grace := 300}}, Load(<<",\"shutdown_grace\":300">>)),
    ?assertMatch({error, _}, Load(<<",\"shutdown_grace\":301">>)),
    ?assertMatch({error, _}, Load(<<",\"shutdown_grace\":-1">>)),
    ?assertMatch({error, _}, Load(<<",\"shutdown_grace\":\"5\"">>)).

config(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",\"shutdown_grace\":3,">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).

register_client(Port, Nick) ->
    Sock = connect(Port),
    ok = gen_tcp:send(Sock, [<<"NICK ">>, Nick, <<"\r\nUSER ">>, Nick, <<" 0 * :T\r\n">>]),
    ?assert(has(recv_until(Sock, <<" 001 ">>, <<>>), <<" 001 ">>)),
    Sock.

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

recv_until(Sock, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            {ok, Bin} = gen_tcp:recv(Sock, 0, 5000),
            recv_until(Sock, Needle, <<Acc/binary, Bin/binary>>);
        _ ->
            Acc
    end.

%% Read until the server closes the socket.
read_all(Sock) ->
    read_all(Sock, <<>>).

read_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Bin} -> read_all(Sock, <<Acc/binary, Bin/binary>>);
        {error, closed} -> Acc
    end.

wait_sessions(Count, Tries) ->
    Live = [P || {_, P, _, _} <- supervisor:which_children(ircd_sessions), is_pid(P)],
    case length(Live) >= Count of
        true ->
            ok;
        false when Tries > 0 ->
            timer:sleep(20),
            wait_sessions(Count, Tries - 1);
        false ->
            ?assertEqual(Count, length(Live))
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.
