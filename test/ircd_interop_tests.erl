-module(ircd_interop_tests).
-include_lib("eunit/include/eunit.hrl").

%% Interoperability gate: two independent ircd instances, each its own BEAM
%% OS process with its own Mnesia directory, linked over a real RFC 2813 TCP
%% connection. Clients on both servers exercise the IRCv3 state that crosses
%% the link: account replication and SASL, extended-join, account-tag,
%% msgid and time, SETNAME, away-notify, metadata, and the netsplit batch.

interop_test_() ->
    {timeout, 240, fun run/0}.

run() ->
    Base = filename:join(
        "/tmp", "ircd-interop-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    [PortA, PortB] = free_ports(2),
    A = start_node(Base, "alpha", PortA, [{<<"beta.test">>, PortB}]),
    %% beta authenticates alpha's inbound link but never dials out to it.
    B = start_node(Base, "beta", PortB, [{<<"alpha.test">>, 1}]),
    try
        ok = wait_listening(PortA),
        ok = wait_listening(PortB),
        scenario(PortA, PortB, A)
    after
        stop_node(A),
        stop_node(B)
    end.

scenario(PortA, PortB, NodeA) ->
    Caps =
        <<"batch message-tags server-time account-tag account-notify extended-join ",
            "away-notify setname echo-message sasl draft/metadata-2 draft/account-registration">>,
    A1 = client(PortA, <<"aone">>, Caps),
    B1 = client(PortB, <<"bone">>, Caps),
    %% Wait for the link: aone becomes visible on beta.
    ok = wait_until(fun() ->
        send(B1, <<"WHOIS aone">>),
        has(collect(B1), <<" 311 bone aone ">>)
    end),
    %% An account registered on alpha logs in on beta.
    send(A1, <<"REGISTER * * interoppass">>),
    ?assert(has(collect(A1), <<"REGISTER SUCCESS aone">>)),
    B2 = client(PortB, <<"btwo">>, <<"sasl">>),
    ok = wait_until(fun() ->
        send(B2, <<"AUTHENTICATE PLAIN">>),
        _ = collect(B2),
        send(B2, <<"AUTHENTICATE ", (base64:encode(<<0, "aone", 0, "interoppass">>))/binary>>),
        has(collect(B2), <<" 903 ">>)
    end),
    %% Shared channel: extended-join carries alpha's account to beta.
    send(B1, <<"JOIN #interop">>),
    _ = collect(B1),
    send(B1, <<"METADATA * SUB avatar">>),
    _ = collect(B1),
    send(A1, <<"JOIN #interop">>),
    _ = collect(A1),
    ?assert(has(collect(B1), <<"JOIN #interop aone :Real">>)),
    %% One message, the same msgid on both servers, with account and time.
    send(A1, <<"PRIVMSG #interop :across the link">>),
    Echo = collect(A1),
    {match, [MsgId]} = re:run(Echo, <<"msgid=([^; ]+)">>, [{capture, all_but_first, binary}]),
    Seen = collect(B1),
    ?assert(has(Seen, <<"msgid=", MsgId/binary>>)),
    ?assert(has(Seen, <<"account=aone">>)),
    ?assert(has(Seen, <<"time=">>)),
    ?assert(has(Seen, <<"PRIVMSG #interop :across the link">>)),
    send(A1, <<"SETNAME :Renamed Across">>),
    _ = collect(A1),
    ?assert(has(collect(B1), <<"SETNAME :Renamed Across">>)),
    send(A1, <<"AWAY :afk">>),
    _ = collect(A1),
    ?assert(has(collect(B1), <<"AWAY :afk">>)),
    send(A1, <<"METADATA * SET avatar :https://example.org/me.png">>),
    _ = collect(A1),
    ?assert(has(collect(B1), <<"METADATA aone avatar * :https://example.org/me.png">>)),
    send(B1, <<"METADATA aone GET avatar">>),
    ?assert(has(collect(B1), <<" 761 bone aone avatar * :https://example.org/me.png">>)),
    send(B1, <<"WHO #interop %na">>),
    ?assert(has(collect(B1), <<" 354 bone aone aone">>)),
    %% Losing alpha splits the network: one netsplit batch on beta.
    stop_node(NodeA),
    Split = collect_long(B1),
    ?assert(has(Split, <<"netsplit">>)),
    ?assert(has(Split, <<"aone!">>)),
    ?assert(has(Split, <<"QUIT">>)),
    lists:foreach(fun gen_tcp:close/1, [A1, B1, B2]).

%%% External nodes

start_node(Base, Name, Port, Links) ->
    Dir = filename:join(Base, Name),
    ok = filelib:ensure_dir(filename:join([Dir, "db", "x"])),
    Config = filename:join(Dir, "ircd.json"),
    LinkJson = lists:join(<<",">>, [
        [
            <<"{\"name\":\"">>,
            Peer,
            <<"\",\"host\":\"127.0.0.1\",\"port\":">>,
            integer_to_binary(PeerPort),
            <<",\"password\":\"linkpass\",\"tls\":false}">>
        ]
     || {Peer, PeerPort} <- Links
    ]),
    ok = file:write_file(
        Config,
        iolist_to_binary([
            <<"{\"name\":\"">>,
            Name,
            <<".test\",\"bind\":\"127.0.0.1\",\"tcp_port\":">>,
            integer_to_binary(Port),
            <<",\"log_level\":\"warning\",\"log_format\":\"text\",\"mnesia_dir\":\"">>,
            filename:join(Dir, "db"),
            <<"\",\"server_links\":[">>,
            LinkJson,
            <<"]}">>
        ])
    ),
    Erl = os:find_executable("erl"),
    Paths = lists:append([["-pa", P] || P <- code:get_path(), lists:prefix("/workspace", P)]),
    erlang:open_port({spawn_executable, Erl}, [
        {args,
            ["-noshell", "-noinput" | Paths] ++
                ["-eval", "{ok, _} = application:ensure_all_started(ircd)."]},
        {env, [{"IRCD_CONFIG", Config}]},
        {cd, Dir},
        exit_status,
        use_stdio,
        stderr_to_stdout
    ]).

stop_node(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} ->
            _ = os:cmd("kill " ++ integer_to_list(OsPid)),
            try
                port_close(Port)
            catch
                error:badarg -> ok
            end,
            ok;
        undefined ->
            ok
    end.

free_ports(N) ->
    Socks = [
        begin
            {ok, S} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
            S
        end
     || _ <- lists:seq(1, N)
    ],
    Ports = [element(2, inet:port(S)) || S <- Socks],
    lists:foreach(fun gen_tcp:close/1, Socks),
    Ports.

wait_listening(Port) ->
    wait_until(fun() ->
        case gen_tcp:connect("127.0.0.1", Port, [], 200) of
            {ok, S} ->
                gen_tcp:close(S),
                true;
            _ ->
                false
        end
    end).

wait_until(Fun) ->
    wait_until(Fun, 60).

wait_until(_Fun, 0) ->
    erlang:error(timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(500),
            wait_until(Fun, N - 1)
    end.

%%% Clients

client(Port, Nick, Caps) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    send(Sock, <<"CAP LS 302">>),
    _ = collect(Sock),
    send(Sock, <<"CAP REQ :", Caps/binary>>),
    ?assert(has(collect(Sock), <<" ACK ">>)),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :Real">>),
    send(Sock, <<"CAP END">>),
    ?assert(has(collect(Sock), <<" 001 ">>)),
    Sock.

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

collect(Sock) ->
    collect(Sock, <<>>, 0, 15).

collect_long(Sock) ->
    collect(Sock, <<>>, 0, 40).

collect(Sock, Acc, N, Waits) when N < 80 ->
    Timeout =
        case Acc of
            <<>> -> 250;
            _ -> 150
        end,
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Bin} -> collect(Sock, <<Acc/binary, Bin/binary>>, N + 1, Waits);
        {error, timeout} when Acc =:= <<>>, N < Waits -> collect(Sock, Acc, N + 1, Waits);
        {error, _} -> Acc
    end;
collect(_Sock, Acc, _, _) ->
    Acc.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.
