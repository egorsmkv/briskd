-module(briskd_info_redesign_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("briskd/include/briskd_population.hrl").

%% Tests for the redesigned info, population accounting, metrics, MOTD caching,
%% operator authentication/indexes, versioned rehash, explicit reply context,
%% and chunked query workers.

motd_utf8_and_sanitization_test() ->
    %% 79 ASCII bytes + 3-byte euro sign (bytes 80..82) must not split mid-codepoint.
    Prefix79 = binary:copy(<<"a">>, 79),
    Euro = <<16#E2, 16#82, 16#AC>>,
    Line3 = <<Prefix79/binary, Euro/binary, "tail">>,
    Chunks3 = briskd_motd:wrap_line(Line3),
    ?assertEqual([Prefix79, <<Euro/binary, "tail">>], Chunks3),
    lists:foreach(
        fun(C) ->
            ?assert(byte_size(C) =< 80),
            ?assertEqual(C, unicode:characters_to_binary(C))
        end,
        Chunks3
    ),
    %% 78 ASCII bytes + 4-byte emoji (bytes 79..82) must split at 78.
    Prefix78 = binary:copy(<<"b">>, 78),
    Emoji = <<16#F0, 16#9F, 16#98, 16#80>>,
    Line4 = <<Prefix78/binary, Emoji/binary, "z">>,
    Chunks4 = briskd_motd:wrap_line(Line4),
    ?assertEqual([Prefix78, <<Emoji/binary, "z">>], Chunks4),
    %% CR and NUL injection bytes are stripped; blank lines kept; trailing LF trimmed.
    Lines = briskd_motd:lines(<<"hello\rworld\n\nline", 0, "two\n">>),
    ?assertEqual([<<"helloworld">>, <<>>, <<"linetwo">>], Lines),
    %% Oversized MOTD (> 64 KiB) returns missing.
    BigPath = filename:join("/tmp", "briskd-big-motd.txt"),
    ok = file:write_file(BigPath, binary:copy(<<"x">>, 65537)),
    try
        ?assertEqual(missing, briskd_motd:load(BigPath))
    after
        _ = file:delete(BigPath)
    end.

metrics_counters_test() ->
    ok = briskd_metrics:init(),
    ?assertEqual(true, briskd_metrics:supported_command(<<"LUSERS">>)),
    ?assertEqual(false, briskd_metrics:supported_command(<<"UNKNOWNCMD">>)),
    ?assertEqual([], briskd_metrics:command_stats()),
    ok = briskd_metrics:count_command(self(), <<"PING">>, 12),
    ok = briskd_metrics:count_command(self(), <<"PING">>, 8),
    ok = briskd_metrics:count_command(self(), <<"UNKNOWNCMD">>, 20),
    ?assertEqual([{<<"PING">>, 2, 20}], briskd_metrics:command_stats()),
    ok = briskd_metrics:init(),
    ?assertEqual([], briskd_metrics:command_stats()).

oper_authenticate_test() ->
    ok = briskd_oper:store_accounts(#{
        operators => [{<<"opone">>, <<"oppass">>}],
        administrators => [{<<"adm[1]">>, <<"admpass">>}]
    }),
    ?assertEqual({ok, operator}, briskd_oper:authenticate(<<"OPONE">>, <<"oppass">>)),
    %% RFC 1459 case mapping folds `[` to `{`.
    ?assertEqual({ok, administrator}, briskd_oper:authenticate(<<"ADM{1}">>, <<"admpass">>)),
    ?assertEqual({error, bad_password}, briskd_oper:authenticate(<<"opone">>, <<"wrong">>)),
    ?assertEqual({error, unknown_account}, briskd_oper:authenticate(<<"nobody">>, <<"oppass">>)).

redesign_live_test_() ->
    {timeout, 120, fun live/0}.

live() ->
    Dir = filename:join(
        "/tmp", "briskd-redesign-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    Motd = filename:join(Dir, "motd.txt"),
    Config = filename:join(Dir, "briskd.json"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    ok = file:write_file(Motd, <<"Cached MOTD line 1\n">>),
    ok = file:write_file(Config, config_json(Db, Motd, <<"Test Admin">>)),
    os:putenv("BRISKD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(briskd),
    try
        Port = listener_port(),
        population_and_lusers(Port),
        motd_and_rehash(Port, Config, Motd, Db),
        chunked_queries_and_labels(Port)
    after
        _ = application:stop(briskd),
        os:unsetenv("BRISKD_CONFIG"),
        _ = file:del_dir_r(Dir)
    end.

population_and_lusers(Port) ->
    %% Initial state: 1 predefined channel (#Lobby), 1 server, 0 users.
    InitPop = briskd_population:snapshot(),
    ?assertEqual(0, InitPop#population.local_users),
    ?assertEqual(0, InitPop#population.unknown_users),
    ?assertEqual(1, InitPop#population.channels),
    ?assertEqual(1, InitPop#population.servers),

    %% Unregistered socket increments unknown_users.
    Unreg = connect(Port),
    send(Unreg, <<"CAP LS 302">>),
    _ = recv_until(Unreg, <<"CAP * LS">>),
    PopUnreg = briskd_population:snapshot(),
    ?assertEqual(1, PopUnreg#population.unknown_users),

    Alice = register_client(Port, <<"alice">>),
    Bob = register_client(Port, <<"bob">>),
    PopReg = briskd_population:snapshot(),
    ?assertEqual(2, PopReg#population.local_users),
    ?assertEqual(1, PopReg#population.unknown_users),
    ?assertEqual(2, PopReg#population.max_local),
    ?assertEqual(2, PopReg#population.max_global),

    %% +i and +o tracking.
    _ = cmd(Bob, <<"MODE bob +iw">>),
    ?assertEqual(1, (briskd_population:snapshot())#population.invisible_users),
    ?assertEqual([session_pid(Bob)], briskd_oper:wallops_recipients()),
    _ = cmd(Alice, <<"OPER opone oppass">>),
    ?assertEqual(1, (briskd_population:snapshot())#population.operators),

    %% Canonical channel counting across local + remote.
    _ = cmd(Alice, <<"JOIN #shared">>),
    ?assertEqual(2, (briskd_population:snapshot())#population.channels),

    %% Link a peer (0 remote users yet -> servers = 2).
    Peer = handshake(Port, <<"peer.test">>),
    ?assertEqual(2, (briskd_population:snapshot())#population.servers),
    Lusers0 = cmd(Alice, <<"LUSERS">>),
    ?assert(has(Lusers0, <<" 251 alice :There are 1 users and 1 invisible on 2 servers">>)),
    ?assert(has(Lusers0, <<" 255 alice :I have 2 clients and 1 servers">>)),

    %% Introduce a remote +io user joining #shared: channels stays 2, remote +1, ops +1, inv +1.
    peer_lines(Peer, [
        <<":peer.test NICK ruser 1 r peer.test 1 +io :Remote">>,
        <<":ruser!r@peer.test JOIN #shared">>
    ]),
    PopRemote = briskd_population:snapshot(),
    ?assertEqual(1, PopRemote#population.remote_users),
    ?assertEqual(2, PopRemote#population.invisible_users),
    ?assertEqual(2, PopRemote#population.operators),
    ?assertEqual(2, PopRemote#population.channels),
    ?assertEqual(3, PopRemote#population.max_global),

    %% Unmatched mask must never emit "-1 servers" in 255.
    Masked = cmd(Alice, <<"LUSERS nomatch.*">>),
    ?assert(has(Masked, <<"There are 0 users and 0 invisible on 0 servers">>)),
    ?assert(has(Masked, <<"I have 2 clients and 0 servers">>)),

    %% Drop peer: remote population clears, maxima remain at peak.
    gen_tcp:close(Peer),
    ok = wait_until(fun() -> (briskd_population:snapshot())#population.servers =:= 1 end),
    PopSplit = briskd_population:snapshot(),
    ?assertEqual(0, PopSplit#population.remote_users),
    ?assertEqual(1, PopSplit#population.invisible_users),
    ?assertEqual(1, PopSplit#population.operators),
    ?assertEqual(2, PopSplit#population.max_local),
    ?assertEqual(3, PopSplit#population.max_global),

    %% Clean up connections.
    gen_tcp:close(Unreg),
    gen_tcp:close(Bob),
    gen_tcp:close(Alice),
    ok = wait_until(fun() -> (briskd_population:snapshot())#population.local_users =:= 0 end).

motd_and_rehash(Port, Config, Motd, Db) ->
    Alice = register_client(Port, <<"rehashop">>),
    _ = cmd(Alice, <<"OPER opone oppass">>),
    Gen0 = briskd_rehash:generation(),
    ?assert(has(cmd(Alice, <<"MOTD">>), <<"Cached MOTD line 1">>)),
    %% Editing file on disk does not change cached MOTD until REHASH.
    ok = file:write_file(Motd, <<"Reloaded MOTD line 2\n">>),
    ?assert(has(cmd(Alice, <<"MOTD">>), <<"Cached MOTD line 1">>)),
    ok = file:write_file(Config, config_json(Db, Motd, <<"Updated Admin">>)),
    ?assert(has(cmd(Alice, <<"REHASH">>), <<" 382 rehashop ">>)),
    ?assertEqual(Gen0 + 1, briskd_rehash:generation()),
    ?assert(has(cmd(Alice, <<"MOTD">>), <<"Reloaded MOTD line 2">>)),
    ?assert(has(cmd(Alice, <<"ADMIN">>), <<" 256 rehashop irc.test :Updated Admin">>)),
    gen_tcp:close(Alice).

chunked_queries_and_labels(Port) ->
    %% Spawn 135 fake registered sessions (> CHUNK_SIZE 128) so TRACE and STATS l
    %% exercise multi-chunk ets:select/3 -> ets:select/1 continuation traversal.
    Parent = self(),
    Fakes = [
        spawn_link(fun() ->
            ok = briskd_state:connect(<<"10.0.0.1">>),
            Nick = <<"f", (integer_to_binary(I))/binary>>,
            _ = briskd_state:command(<<"NICK">>, [Nick], 8),
            _ = briskd_state:command(<<"USER">>, [<<"u">>, <<"0">>, <<"*">>, <<"Real">>], 16),
            Parent ! {fake_up, self()},
            receive
                stop -> ok
            end
        end)
     || I <- lists:seq(1, 135)
    ],
    lists:foreach(
        fun(P) ->
            receive
                {fake_up, P} -> ok
            after 5000 -> error(fake_timeout)
            end
        end,
        Fakes
    ),
    try
        Op = register_client(Port, <<"qop">>),
        _ = cmd(Op, <<"CAP REQ :labeled-response batch">>),
        _ = cmd(Op, <<"OPER opone oppass">>),

        %% Unlabeled TRACE streams all 135+ clients in chunks and finishes with 262.
        Trace = cmd(Op, <<"TRACE">>),
        ?assert(count(Trace, <<" 205 qop User 0 ">>) >= 135),
        ?assert(has(Trace, <<" 262 qop irc.test ">>)),

        %% Labeled TRACE wraps all lines in one labeled-response batch.
        LabeledTrace = cmd(Op, <<"@label=tr1 TRACE">>),
        ?assert(has(LabeledTrace, <<"@label=tr1 :irc.test BATCH +">>)),
        ?assert(has(LabeledTrace, <<" labeled-response\r\n">>)),
        ?assert(count(LabeledTrace, <<" 205 qop User 0 ">>) >= 135),
        ?assert(has(LabeledTrace, <<" 262 qop irc.test ">>)),

        %% Labeled STATS l wraps all 211 lines + 219 in one labeled-response batch.
        LabeledStats = cmd(Op, <<"@label=st1 STATS l">>),
        ?assert(has(LabeledStats, <<"@label=st1 :irc.test BATCH +">>)),
        ?assert(count(LabeledStats, <<" 211 qop ">>) >= 136),
        ?assert(has(LabeledStats, <<" 219 qop l :End of STATS report">>)),

        %% STATS m reports command counts from briskd_metrics.
        StatsM = cmd(Op, <<"STATS m">>),
        ?assert(has(StatsM, <<" 212 qop TRACE ">>)),
        ?assert(has(StatsM, <<" 219 qop m :End of STATS report">>)),

        gen_tcp:close(Op)
    after
        lists:foreach(fun(P) -> P ! stop end, Fakes)
    end.

%%% Helpers

config_json(Db, Motd, AdminName) ->
    iolist_to_binary([
        <<"{">>,
        <<"\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"error\",\"log_format\":\"text\",\"resource_delay\":0,">>,
        <<"\"max_clients\":500,">>,
        <<"\"motd_file\":\"">>,
        list_to_binary(Motd),
        <<"\",\"admin_name\":\"">>,
        AdminName,
        <<"\",\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\",\"operators\":[{\"name\":\"opone\",\"password\":\"oppass\"}],">>,
        <<"\"channels\":[{\"name\":\"#Lobby\",\"topic\":\"lobby\"}],">>,
        <<"\"server_links\":[{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false}]">>,
        <<"}">>
    ]).

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(briskd_sup)),
    true = is_pid(Pid),
    {ok, Port} = briskd_listener:port(Pid),
    Port.

session_pid(Sock) ->
    {ok, SockName} = inet:sockname(Sock),
    [Pid] = [
        P
     || {_, P, _, _} <- supervisor:which_children(briskd_sessions),
        is_pid(P),
        case sys:get_state(P) of
            {_, S, _, _, _} -> inet:peername(S) =:= {ok, SockName};
            _ -> false
        end
    ],
    Pid.

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

register_client(Port, Nick) ->
    Sock = connect(Port),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :", Nick/binary>>),
    Welcome = cmd(Sock, <<"PING :welcome">>),
    ?assert(has(Welcome, <<" 001 ", Nick/binary, " ">>)),
    Sock.

handshake(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    ?assert(has(recv_until(Sock, <<"SERVER irc.test">>), <<"SERVER irc.test">>)),
    _ = peer_lines(Sock, []),
    Sock.

peer_lines(Sock, Lines) ->
    lists:foreach(fun(Line) -> send(Sock, Line) end, Lines),
    Token = token(),
    send(Sock, <<"PING ", Token/binary>>),
    recv_until(Sock, Token).

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

cmd(Sock, Line) ->
    send(Sock, Line),
    Token = token(),
    send(Sock, <<"PING ", Token/binary>>),
    recv_until(Sock, Token).

token() ->
    <<"tk", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

recv_until(Sock, Needle) ->
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    recv_until(Sock, Needle, <<>>, Deadline).

recv_until(Sock, Needle, Acc, Deadline) ->
    case has(Acc, Needle) andalso has_line_end_after(Acc, Needle) of
        true ->
            Acc;
        false ->
            Left = Deadline - erlang:monotonic_time(millisecond),
            case Left > 0 andalso gen_tcp:recv(Sock, 0, Left) of
                {ok, <<_/binary>> = Bin} ->
                    recv_until(Sock, Needle, <<Acc/binary, Bin/binary>>, Deadline);
                _ ->
                    Acc
            end
    end.

has_line_end_after(Acc, Needle) ->
    {Start, Length} = binary:match(Acc, Needle),
    Rest = binary:part(Acc, Start + Length, byte_size(Acc) - Start - Length),
    has(Rest, <<"\r\n">>).

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

count(Bin, Needle) ->
    length(binary:matches(Bin, Needle)).

wait_until(Fun) ->
    wait_until(Fun, 50).

wait_until(_Fun, 0) ->
    timeout;
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, N - 1)
    end.
