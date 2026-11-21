-module(briskd_link_fix_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("briskd/include/briskd_state.hrl").

%% Regression tests for RFC 2813 server-link fixes: prefixless and malformed
%% peer lines must not crash briskd_state, SQUIT scope, remote REDACT
%% authorization, rejected channel messages, remote NICK/QUIT visibility,
%% stacked NJOIN prefixes, peer batch limits, local channel metadata in the
%% burst, SQUERY to a local service, and link reconnect backoff.

-define(PEER, <<"peer.test">>).
-define(REM, <<"rem!u@h.test">>).

robust_test_() ->
    {timeout, 120, fun robust/0}.

link_rules_test_() ->
    {timeout, 120, fun link_rules/0}.

remote_mode_local_target_test_() ->
    {timeout, 60, fun remote_mode_local_target/0}.

backoff_test_() ->
    {timeout, 60, fun backoff/0}.

%%% Malformed and prefixless peer lines (RFC 2813 3.3)

robust() ->
    Port = start("robust"),
    try
        Alice = client(Port, <<"alice">>),
        send(Alice, <<"JOIN #c">>),
        sync(Alice),
        Peer = handshake(Port, ?PEER),
        sync(Peer),
        ok = cmd(?PEER, <<"NICK">>, nick(<<"rem">>, <<"1">>, <<"+">>)),
        ok = cmd(?REM, <<"JOIN">>, [<<"#c">>]),
        State = whereis(briskd_state),
        Commands = [
            <<"NJOIN">>,
            <<"JOIN">>,
            <<"PART">>,
            <<"TOPIC">>,
            <<"KICK">>,
            <<"NICK">>,
            <<"QUIT">>,
            <<"AWAY">>,
            <<"MODE">>,
            <<"PRIVMSG">>,
            <<"NOTICE">>,
            <<"TAGMSG">>,
            <<"SERVER">>,
            <<"SQUIT">>,
            <<"INVITE">>,
            <<"SERVICE">>,
            <<"SQUERY">>,
            <<"KILL">>,
            <<"BATCH">>,
            <<"ACCOUNT">>,
            <<"SETNAME">>,
            <<"CHGHOST">>,
            <<"REDACT">>,
            <<"ACCOUNTSYNC">>,
            <<"METADATA">>,
            <<"MARKREAD">>,
            <<"PING">>,
            <<"UNKNOWN">>
        ],
        Prefixes = [undefined, <<>>, <<"!">>, <<"x!y@z">>, <<"ghost.test">>, ?REM, ?PEER],
        Garbage = [
            [],
            [<<>>],
            [<<>>, <<>>],
            [<<"#c">>],
            [<<"#c">>, <<>>],
            [<<"#c">>, <<"+o">>],
            [<<"#c">>, <<"+ov">>, <<"rem">>],
            [<<"#c">>, <<"x">>, <<"y">>, <<"z">>],
            [<<"rem">>, <<"#c">>],
            [<<"x">>, <<"x">>, <<"x">>, <<"x">>, <<"x">>, <<"x">>, <<"x">>],
            [<<"+">>, <<"ref">>],
            [<<"+ref">>, <<"draft/multiline">>, <<"#c">>],
            [<<"-ref">>],
            [<<"*">>, <<"key">>, <<"*">>, <<"value">>],
            [<<"#c">>, <<"msgid">>, <<"why">>],
            [<<"a.test">>, <<"1">>, <<"1">>, <<"info">>],
            [<<"svc">>, <<"1">>, <<"*">>, <<"0">>, <<"1">>, <<"info">>],
            [<<"acct">>, <<"#c">>, <<"timestamp=1">>],
            lists:duplicate(15, <<"z">>)
        ],
        lists:foreach(
            fun({Prefix, Command, Params}) ->
                _ = cmd(?PEER, <<"NICK">>, nick(<<"rem">>, <<"1">>, <<"+">>)),
                _ = cmd(?REM, <<"JOIN">>, [<<"#c">>]),
                Result = briskd_state:server_command(?PEER, Prefix, Command, Params),
                ?assert(Result =:= ok orelse element(1, Result) =:= error),
                ?assertEqual({Prefix, Command, Params, State}, {
                    Prefix, Command, Params, whereis(briskd_state)
                })
            end,
            [{P, C, G} || P <- Prefixes, C <- Commands, G <- Garbage]
        ),
        %% A tagged prefixless batch line and message.
        _ = briskd_state:server_command(?PEER, undefined, <<"PRIVMSG">>, [<<"#c">>, <<"x">>], [
            {<<"batch">>, <<"ref">>}
        ]),
        ?assertEqual(State, whereis(briskd_state))
    after
        stop()
    end.

%%% SQUIT scope, REDACT, rejected messages, NICK/QUIT, NJOIN, batches,
%%% burst metadata, and SQUERY

link_rules() ->
    Port = start("rules"),
    try
        Alice = client(Port, <<"alice">>),
        send(Alice, <<"OPER oper opersecret">>),
        send(Alice, <<"SERVICE loc * t :Local">>),
        send(Alice, <<"JOIN #c">>),
        send(Alice, <<"JOIN &loc">>),
        send(Alice, <<"METADATA &loc SET secret :local-only">>),
        send(Alice, <<"METADATA #c SET theme :shared">>),
        sync(Alice),
        Peer = handshake(Port, ?PEER),
        Burst = sync(Peer),
        %% Bug 8: metadata of a local & channel stays out of the burst.
        ?assert(has(Burst, <<"METADATA #c theme">>)),
        ?assertNot(has(Burst, <<"local-only">>)),
        %% A local & channel is not a shared channel (RFC 2811).
        ?assertNot(has(Burst, <<"&loc">>)),
        Other = handshake(Port, <<"other.test">>),
        sync(Other),
        ok = cmd(?PEER, <<"SERVER">>, [<<"leaf.test">>, <<"2">>, <<"2">>, <<"Leaf">>]),
        ok = briskd_state:server_command(
            <<"other.test">>, <<"other.test">>, <<"SERVER">>, [
                <<"far.test">>, <<"2">>, <<"3">>, <<"Far">>
            ]
        ),
        ok = cmd(?PEER, <<"NICK">>, nick(<<"rem">>, <<"1">>, <<"+">>)),
        ok = cmd(?PEER, <<"NICK">>, nick(<<"rem2">>, <<"1">>, <<"+">>)),
        ok = briskd_state:server_command(
            <<"other.test">>, <<"other.test">>, <<"NICK">>, nick(<<"sidey">>, <<"1">>, <<"+">>)
        ),
        ok = briskd_state:server_command(
            <<"other.test">>, <<"sidey!u@h.test">>, <<"JOIN">>, [<<"#x">>]
        ),
        ok = cmd(?REM, <<"JOIN">>, [<<"#c">>]),
        ok = cmd(<<"rem2!u@h.test">>, <<"JOIN">>, [<<"#c">>]),
        sync(Other),
        sync(Alice),
        %% Bug 2: a peer may SQUIT only itself or a server behind it.
        ?assertEqual({error, squit_not_behind_peer}, cmd(?PEER, <<"SQUIT">>, [<<"far.test">>])),
        ?assertEqual({error, squit_not_behind_peer}, cmd(?PEER, <<"SQUIT">>, [<<"other.test">>])),
        ?assertEqual({error, squit_not_behind_peer}, cmd(?PEER, <<"SQUIT">>, [<<"irc.test">>])),
        ?assertMatch([_], mnesia:dirty_read(known_server, <<"far.test">>)),
        ?assertMatch([_], mnesia:dirty_read(known_server, <<"other.test">>)),
        ok = cmd(?PEER, <<"SQUIT">>, [<<"gone.test">>]),
        ok = cmd(?PEER, <<"SQUIT">>, [<<"leaf.test">>, <<"bye">>]),
        ?assertEqual([], mnesia:dirty_read(known_server, <<"leaf.test">>)),
        %% Bug 4: a channel message rejected here is not forwarded.
        ?assertEqual(
            {error, remote_user_not_on_channel},
            cmd(?REM, <<"PRIVMSG">>, [<<"#x">>, <<"not-forwarded">>])
        ),
        ?assertNot(has(sync(Other), <<"not-forwarded">>)),
        %% Bug 3: remote REDACT needs the author or a channel operator.
        Msg = fun(Prefix, Id, Text) ->
            ok = briskd_state:server_command(
                ?PEER, Prefix, <<"PRIVMSG">>, [<<"#c">>, Text], [{<<"msgid">>, Id}]
            )
        end,
        Msg(?REM, <<"m1">>, <<"one">>),
        Msg(?REM, <<"m2">>, <<"two">>),
        sync(Alice),
        ?assertEqual(
            {error, redact_forbidden}, cmd(<<"rem2!u@h.test">>, <<"REDACT">>, [<<"#c">>, <<"m1">>])
        ),
        ?assertEqual(
            {error, unknown_remote_source}, cmd(<<"x!y@z">>, <<"REDACT">>, [<<"#c">>, <<"m1">>])
        ),
        ?assertEqual(
            {error, unknown_remote_source},
            briskd_state:server_command(
                <<"other.test">>, ?REM, <<"REDACT">>, [<<"#c">>, <<"m1">>]
            )
        ),
        ?assertEqual(
            {error, remote_user_not_on_channel},
            cmd(?REM, <<"REDACT">>, [<<"#x">>, <<"m1">>])
        ),
        ?assertEqual([<<"m2">>, <<"m1">>], history_ids(<<"#c">>)),
        ok = cmd(?REM, <<"REDACT">>, [<<"#c">>, <<"m1">>]),
        ?assertEqual([<<"m2">>], history_ids(<<"#c">>)),
        ok = cmd(?PEER, <<"MODE">>, [<<"#c">>, <<"+o">>, <<"rem2">>]),
        ok = cmd(<<"rem2!u@h.test">>, <<"REDACT">>, [<<"#c">>, <<"m2">>]),
        ?assertEqual([], history_ids(<<"#c">>)),
        %% Bug 9: SQUERY from a peer reaches a service on this server.
        ok = cmd(?REM, <<"SQUERY">>, [<<"loc">>, <<"svc-text">>]),
        ?assert(has(recv_until(Alice, <<"svc-text">>), <<":rem!u@h.test NOTICE loc :svc-text">>)),
        ?assertEqual(
            {error, unknown_remote_source}, cmd(<<"x!y@z">>, <<"SQUERY">>, [<<"loc">>, <<"t">>])
        ),
        %% Bug 5: local members see a remote NICK (including case-only) and QUIT.
        ok = cmd(?REM, <<"NICK">>, [<<"remy">>]),
        ?assert(has(recv_until(Alice, <<"remy">>), <<":rem!u@h.test NICK :remy">>)),
        ok = cmd(<<"remy!u@h.test">>, <<"NICK">>, [<<"REMY">>]),
        ?assert(has(recv_until(Alice, <<"REMY">>), <<":remy!u@h.test NICK :REMY">>)),
        ?assert(has(recv_until(Other, <<"NICK REMY">>), <<":remy!u@h.test NICK REMY">>)),
        ok = cmd(<<"REMY!u@h.test">>, <<"NICK">>, [<<"REMY">>]),
        ok = cmd(<<"REMY!u@h.test">>, <<"QUIT">>, [<<"gone">>]),
        ?assert(has(recv_until(Alice, <<"QUIT">>), <<":REMY!u@h.test QUIT :gone">>)),
        %% Bug 6: stacked NJOIN status prefixes (RFC 2813 4.2.2).
        [
            ok = cmd(?PEER, <<"NICK">>, nick(N, <<"1">>, <<"+">>))
         || N <- [<<"n1">>, <<"n2">>, <<"n3">>, <<"n4">>]
        ],
        ok = cmd(?PEER, <<"NJOIN">>, [<<"#s">>, <<"@@+n1,@+n2,@@n3,+n4">>]),
        [#remote_channel{members = Members}] = mnesia:dirty_read(remote_channel, <<"#s">>),
        ?assertEqual({?PEER, [creator, operator, voice]}, maps:get(<<"n1">>, Members)),
        ?assertEqual({?PEER, [operator, voice]}, maps:get(<<"n2">>, Members)),
        ?assertEqual({?PEER, [creator, operator]}, maps:get(<<"n3">>, Members)),
        ?assertEqual({?PEER, [voice]}, maps:get(<<"n4">>, Members)),
        %% Bug 7: open peer batches are capped and dropped on link loss.
        Open = fun(Ref) ->
            cmd(<<"n1!u@h.test">>, <<"BATCH">>, [
                <<"+", Ref/binary>>, <<"draft/multiline">>, <<"#s">>
            ])
        end,
        [ok = Open(integer_to_binary(I)) || I <- lists:seq(1, 10)],
        ?assertEqual({error, too_many_batches}, Open(<<"11">>)),
        ok = Open(<<"5">>),
        ?assertEqual(10, length(peer_batches(?PEER))),
        %% A second PASS/SERVER for the live peer is refused and does not
        %% remove the peer or a local user.
        Dup = connect(Port),
        send(Dup, <<"PASS linksecret 0210 |">>),
        send(Dup, <<"SERVER peer.test 1 1 :peer.test">>),
        ?assertNot(has(recv_until(Dup, <<"SERVER irc.test">>, 1000, false), <<"SERVER irc.test">>)),
        ?assertMatch([_], mnesia:dirty_read(known_server, ?PEER)),
        ?assertMatch(#client{}, briskd_state_client:find_nick(<<"alice">>)),
        ?assert(has(sync(Peer), <<"PONG">>)),
        %% A non-operator on the peer cannot KILL, and cannot invite into +i.
        ok = cmd(?PEER, <<"NICK">>, nick(<<"victim">>, <<"1">>, <<"+">>)),
        ok = cmd(?PEER, <<"NICK">>, nick(<<"peon">>, <<"1">>, <<"+">>)),
        ?assertEqual(
            {error, remote_kill_requires_operator},
            cmd(<<"peon!u@h.test">>, <<"KILL">>, [<<"victim">>, <<"no">>])
        ),
        ?assertMatch([_], mnesia:dirty_read(remote_client, <<"victim">>)),
        ok = cmd(?PEER, <<"KILL">>, [<<"victim">>, <<"server">>]),
        ?assertEqual([], mnesia:dirty_read(remote_client, <<"victim">>)),
        _Bob = client(Port, <<"bob">>),
        send(Alice, <<"MODE #c +i">>),
        sync(Alice),
        ok = cmd(<<"peon!u@h.test">>, <<"INVITE">>, [<<"bob">>, <<"#c">>]),
        #client{pid = BobPid} = briskd_state_client:find_nick(<<"bob">>),
        [#channel{invited = Invited}] = mnesia:dirty_read(channel, <<"#c">>),
        ?assertNot(lists:member(BobPid, Invited)),
        %% Closing the peer socket is what drops its batches. server_disconnect
        %% from a process that does not own the link must not be required.
        ok = gen_tcp:close(Peer),
        wait_until(fun() -> peer_batches(?PEER) =:= [] end),
        ?assertEqual([], peer_batches(?PEER))
    after
        stop()
    end.

history_ids(Key) ->
    [
        Id
     || #{msgid := Id} <- briskd_state_history:channel_history(Key),
        lists:member(Id, [<<"m1">>, <<"m2">>])
    ].

peer_batches(Peer) ->
    {dictionary, Dict} = process_info(state_pid(), dictionary),
    [K || {{briskd_peer_batch, P, _} = K, _} <- Dict, P =:= Peer].

%%% Peer MODE +o/+v whose target is a local member

remote_mode_local_target() ->
    Port = start("modelocal"),
    try
        Alice = client(Port, <<"alice">>),
        Bob = client(Port, <<"bob">>),
        send(Alice, <<"JOIN #m">>),
        sync(Alice),
        send(Bob, <<"JOIN #m">>),
        sync(Bob),
        Peer = handshake(Port, ?PEER),
        sync(Peer),
        send(Peer, <<":peer.test NICK remoteop 1 u h.test 1 + :R">>),
        send(Peer, <<":peer.test NJOIN #m :@remoteop">>),
        sync(Peer),
        recv_until(Alice, <<"JOIN #m">>),
        %% A remote operator gives a local member operator status.
        send(Peer, <<":remoteop!u@h.test MODE #m +o bob">>),
        ?assert(has(recv_until(Alice, <<"MODE #m">>), <<":remoteop!u@h.test MODE #m +o bob">>)),
        sync(Peer),
        ?assertEqual([member, operator], local_roles(<<"#m">>, <<"bob">>)),
        %% A server MODE (as sent on safe-channel reop) is applied and shown.
        send(Peer, <<":peer.test MODE #m +v-o bob bob">>),
        ?assert(has(recv_until(Alice, <<"MODE #m">>), <<":peer.test MODE #m +v-o bob bob">>)),
        sync(Peer),
        ?assertEqual([member, voice], local_roles(<<"#m">>, <<"bob">>)),
        %% A server MODE that changes no local member stays silent.
        send(Peer, <<":peer.test MODE #m +t">>),
        sync(Peer),
        ?assertNot(has(sync(Alice), <<"MODE #m +t">>)),
        %% An unknown target is still rejected without touching briskd_state.
        ?assertEqual(
            {error, unknown_remote_mode_target},
            cmd(?PEER, <<"MODE">>, [<<"#m">>, <<"+o">>, <<"nobody">>])
        ),
        %% The link stayed up throughout.
        ?assertMatch([_], mnesia:dirty_read(known_server, <<"peer.test">>))
    after
        stop()
    end.

local_roles(Channel, Nick) ->
    #client{pid = Pid} = briskd_state_client:find_nick(Nick),
    [#channel{members = Members}] = mnesia:dirty_read(channel, Channel),
    lists:sort(maps:get(Pid, Members)).

%%% Reconnect backoff (bug 12)

backoff() ->
    _ = start("backoff"),
    try
        %% Configured peers listen on port 1, so every attempt is refused.
        Link = link_pid(?PEER),
        wait_until(fun() -> maps:get(attempts, sys:get_state(Link)) >= 1 end),
        Delays = [step(Link) || _ <- lists:seq(1, 8)],
        ?assertEqual(
            [10000, 20000, 40000, 80000, 160000, 300000, 300000, 300000],
            [Base || {Base, _} <- Delays]
        ),
        lists:foreach(
            fun({Base, Left}) ->
                ?assert(Left =< Base),
                ?assert(Left >= Base - Base div 10 - 100)
            end,
            Delays
        )
    after
        stop()
    end.

%% Fire the pending reconnect now and return the new base delay and the time
%% left on the new reconnect timer.
step(Link) ->
    #{timer_gen := Gen, attempts := Attempts} = sys:get_state(Link),
    Link ! {reconnect, Gen},
    wait_until(fun() -> maps:get(attempts, sys:get_state(Link)) =:= Attempts + 1 end),
    #{backoff := Base, reconnect_timer := Timer} = sys:get_state(Link),
    {Base, erlang:read_timer(Timer)}.

link_pid(Name) ->
    [Pid] = [
        Pid
     || {{server_link, Peer}, Pid, worker, _} <- supervisor:which_children(briskd_links),
        Peer =:= Name
    ],
    Pid.

wait_until(Fun) ->
    wait_until(Fun, 100).

wait_until(Fun, 0) ->
    ?assert(Fun());
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(Fun, N - 1)
    end.

%%% Helpers

nick(Nick, Hop, Modes) ->
    [Nick, Hop, <<"u">>, <<"h.test">>, <<"1">>, Modes, <<"Real">>].

cmd(Prefix, Command, Params) ->
    briskd_state:server_command(?PEER, Prefix, Command, Params).

start(Tag) ->
    Dir = filename:join(
        "/tmp",
        "briskd-linkfix-" ++ Tag ++ "-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "briskd.json"),
    ok = file:write_file(Config, config(filename:join(Dir, "db"))),
    os:putenv("BRISKD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(briskd),
    [erase(Key) || {{buf, _} = Key, _} <- get()],
    listener_port().

stop() ->
    _ = application:stop(briskd),
    os:unsetenv("BRISKD_CONFIG").

config(Db) ->
    Link = fun(Name) ->
        [
            <<"{\"name\":\"">>,
            Name,
            <<"\",\"host\":\"127.0.0.1\",\"port\":1,\"password\":\"linksecret\",\"tls\":false}">>
        ]
    end,
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"emergency\",\"log_format\":\"text\",\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\",\"operators\":[{\"name\":\"oper\",\"password\":\"opersecret\"}],">>,
        <<"\"server_links\":[">>,
        lists:join(<<",">>, [Link(<<"peer.test">>), Link(<<"other.test">>)]),
        <<"]}">>
    ]).

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(briskd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

client(Port, Nick) ->
    Sock = connect(Port),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :", Nick/binary>>),
    recv_until(Sock, <<" 001 ">>),
    Sock.

handshake(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    recv_until(Sock, <<"SERVER irc.test">>),
    Sock.

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

sync(Sock) ->
    N = integer_to_binary(erlang:unique_integer([positive])),
    Token = <<"sync", N/binary>>,
    send(Sock, <<"PING ", Token/binary>>),
    recv_until(Sock, Token).

recv_until(Sock, Needle) ->
    recv_until(Sock, Needle, 3000, true).

recv_until(Sock, Needle, Timeout, Strict) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Buffered =
        case get({buf, Sock}) of
            undefined -> <<>>;
            B -> B
        end,
    put({buf, Sock}, <<>>),
    recv_loop(Sock, Needle, Deadline, Strict, Buffered).

recv_loop(Sock, Needle, Deadline, Strict, Acc) ->
    case line_end(Acc, Needle) of
        {ok, End} ->
            put({buf, Sock}, binary:part(Acc, End, byte_size(Acc) - End)),
            binary:part(Acc, 0, End);
        nomatch ->
            Left = Deadline - erlang:monotonic_time(millisecond),
            case Left > 0 andalso gen_tcp:recv(Sock, 0, Left) of
                {ok, <<_/binary>> = Bin} ->
                    recv_loop(Sock, Needle, Deadline, Strict, <<Acc/binary, Bin/binary>>);
                _ when Strict ->
                    error({no_match, Needle, Acc});
                _ ->
                    Acc
            end
    end.

line_end(Acc, Needle) ->
    case binary:match(Acc, Needle) of
        {Pos, Len} ->
            From = Pos + Len,
            case binary:match(Acc, <<"\r\n">>, [{scope, {From, byte_size(Acc) - From}}]) of
                {E, 2} -> {ok, E + 2};
                nomatch -> nomatch
            end;
        nomatch ->
            nomatch
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

state_pid() ->
    case whereis(briskd_state) of
        Pid when is_pid(Pid) -> Pid
    end.
