-module(ircd_channel_fix_tests).
-include_lib("eunit/include/eunit.hrl").

%% Regression tests for channel and operator query fixes: STATS privilege
%% (RFC 2812 3.4.4), KILL/REHASH audit events (AGENTS.md section 11), LUSERS
%% masking (3.4.2), safe-channel reop propagation (RFC 2811 3.2, RFC 2813),
%% ban and exception list visibility (3.2.3), TOPIC on hidden channels
%% (3.2.4), KNOCK numerics, channel keys, and MODE/KICK on members of another
%% server reached through a fake peer link.

-export([log/2]).

fix_test_() ->
    {setup, fun start/0, fun stop/1, fun(#{port := Port, config := Config}) ->
        [
            {timeout, 60, fun() -> stats_privilege(Port) end},
            {timeout, 60, fun() -> audit_events(Port, Config) end},
            {timeout, 60, fun() -> lusers_mask(Port) end},
            {timeout, 60, fun() -> list_visibility(Port) end},
            {timeout, 60, fun() -> topic_hidden(Port) end},
            {timeout, 60, fun() -> knock_numerics(Port) end},
            {timeout, 60, fun() -> channel_key(Port) end},
            {timeout, 60, fun() -> remote_members(Port) end},
            {timeout, 60, fun() -> reop_propagated(Port) end}
        ]
    end}.

%% --- STATS l and o (RFC 2812 3.4.4) -----------------------------------------

stats_privilege(Port) ->
    A = client(Port, <<"st_alice">>),
    B = client(Port, <<"st_bob">>),
    cmd(B, <<"MODE st_bob +i">>),
    Own = cmd(A, <<"STATS l">>),
    want(Own, <<" 211 st_alice st_alice 0 ">>),
    ?assertNot(has(Own, <<"st_bob">>)),
    want(Own, <<" 219 st_alice l :End of STATS report">>),
    Denied = cmd(A, <<"STATS o">>),
    want(Denied, <<" 481 st_alice :Permission Denied">>),
    ?assertNot(has(Denied, <<" 243 ">>)),
    want(Denied, <<" 219 st_alice o ">>),
    %% u and m stay public.
    want(cmd(A, <<"STATS u">>), <<" 242 st_alice ">>),
    want(cmd(A, <<"STATS m">>), <<" 219 st_alice m ">>),
    want(cmd(A, <<"OPER fixop fixpw">>), <<" 381 ">>),
    All = cmd(A, <<"STATS l">>),
    want(All, <<" 211 st_alice st_bob 0 ">>),
    want(cmd(A, <<"STATS o">>), <<" 243 st_alice O * * fixop">>),
    close_all([A, B]).

%% --- KILL and REHASH audit events (AGENTS.md section 11) -------------------

audit_events(Port, _Config) ->
    Primary = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = logger:add_handler(fix_audit, ?MODULE, #{level => notice, config => #{pid => self()}}),
    try
        Op = client(Port, <<"au_op">>),
        Victim = client(Port, <<"au_victim">>),
        want(cmd(Op, <<"OPER fixop fixpw">>), <<" 381 ">>),
        cmd(Op, <<"KILL au_victim :secret reason text">>),
        Kill = wait_report(oper_kill),
        ?assertEqual(<<"au_op">>, maps:get(nick, Kill)),
        ?assertEqual(<<"au_victim">>, maps:get(target, Kill)),
        ?assertNot(lists:member(<<"secret reason text">>, maps:values(Kill))),
        want(cmd(Op, <<"REHASH">>), <<" 382 ">>),
        Rehash = wait_report(oper_rehash),
        ?assertEqual(<<"au_op">>, maps:get(nick, Rehash)),
        ?assertEqual(accepted, maps:get(result, Rehash)),
        gen_tcp:close(Victim),
        close_all([Op])
    after
        _ = logger:remove_handler(fix_audit),
        ok = logger:set_primary_config(level, maps:get(level, Primary))
    end.

%% logger handler callback: forward reports to the test process.
log(#{msg := {report, Report}}, #{config := #{pid := Pid}}) when is_map(Report) ->
    Pid ! {fix_audit, Report},
    ok;
log(_, _) ->
    ok.

wait_report(Event) ->
    receive
        {fix_audit, #{event := Event} = Report} -> Report
    after 3000 -> error({no_audit_event, Event})
    end.

%% --- LUSERS mask (RFC 2812 3.4.2) ------------------------------------------

lusers_mask(Port) ->
    A = client(Port, <<"lu_alice">>),
    cmd(A, <<"MODE lu_alice +i">>),
    ?assertNot(has(cmd(A, <<"LUSERS">>), <<"and 0 invisible">>)),
    want(cmd(A, <<"LUSERS nomatch.*">>), <<"There are 0 users and 0 invisible on 0 servers">>),
    close_all([A]).

%% --- Ban and exception list visibility (RFC 2812 3.2.3) --------------------

list_visibility(Port) ->
    A = client(Port, <<"lv_alice">>),
    B = client(Port, <<"lv_bob">>),
    O = client(Port, <<"lv_out">>),
    join(A, <<"#lv">>),
    join(B, <<"#lv">>),
    cmd(A, <<"MODE #lv +b lv_x!*@*">>),
    cmd(A, <<"MODE #lv +e lv_y!*@*">>),
    cmd(A, <<"MODE #lv +I lv_z!*@*">>),
    %% Ban list: any member or outsider, with or without the sign.
    want(cmd(B, <<"MODE #lv +b">>), <<" 367 lv_bob #lv lv_x!*@*">>),
    want(cmd(B, <<"MODE #lv b">>), <<" 367 lv_bob #lv lv_x!*@*">>),
    want(cmd(O, <<"MODE #lv b">>), <<" 367 lv_out #lv lv_x!*@*">>),
    %% Exception and invite lists need channel operator.
    lists:foreach(
        fun(Line) -> want(cmd(B, Line), <<" 482 lv_bob #lv :You're not channel operator">>) end,
        [<<"MODE #lv +e">>, <<"MODE #lv e">>, <<"MODE #lv +I">>, <<"MODE #lv I">>]
    ),
    want(cmd(A, <<"MODE #lv e">>), <<" 348 lv_alice #lv lv_y!*@*">>),
    want(cmd(A, <<"MODE #lv I">>), <<" 346 lv_alice #lv lv_z!*@*">>),
    %% A non-member of a secret channel gets an empty ban list.
    cmd(A, <<"MODE #lv +s">>),
    Hidden = cmd(O, <<"MODE #lv b">>),
    ?assertNot(has(Hidden, <<" 367 ">>)),
    want(Hidden, <<" 368 lv_out #lv :End of channel ban list">>),
    close_all([A, B, O]).

%% --- TOPIC on +p and +s channels (RFC 2812 3.2.4) --------------------------

topic_hidden(Port) ->
    A = client(Port, <<"tp_alice">>),
    O = client(Port, <<"tp_out">>),
    join(A, <<"#tppriv">>),
    cmd(A, <<"TOPIC #tppriv :private topic">>),
    want(cmd(O, <<"TOPIC #tppriv">>), <<" 332 tp_out #tppriv :private topic">>),
    cmd(A, <<"MODE #tppriv +p">>),
    Query = cmd(O, <<"TOPIC #tppriv">>),
    want(Query, <<" 403 tp_out #tppriv :No such channel">>),
    ?assertNot(has(Query, <<"private topic">>)),
    want(cmd(O, <<"TOPIC #tppriv :x">>), <<" 403 tp_out #tppriv ">>),
    want(cmd(A, <<"TOPIC #tppriv">>), <<" 332 tp_alice #tppriv :private topic">>),
    close_all([A, O]).

%% --- KNOCK numerics ----------------------------------------------------------

knock_numerics(Port) ->
    A = client(Port, <<"kn_alice">>),
    C = client(Port, <<"kn_carol">>),
    join(A, <<"#kn">>),
    want(cmd(A, <<"KNOCK #kn">>), <<" 714 kn_alice #kn :You're already on that channel">>),
    want(cmd(C, <<"KNOCK #kn">>), <<" 713 kn_carol #kn :Channel is open">>),
    cmd(A, <<"MODE #kn +l 5">>),
    want(cmd(C, <<"KNOCK #kn">>), <<" 480 kn_carol #kn :Channel is not invite-only">>),
    cmd(A, <<"MODE #kn -l+i">>),
    ?assertNot(has(cmd(C, <<"KNOCK #kn">>), <<" 4">>)),
    want(recv_until(A, <<"KNOCK">>), <<"KNOCK #kn">>),
    close_all([A, C]).

%% --- Channel key (RFC 2811 4.2.10) ------------------------------------------

channel_key(Port) ->
    A = client(Port, <<"ck_alice">>),
    B = client(Port, <<"ck_bob">>),
    join(A, <<"#ck">>),
    cmd(A, <<"MODE #ck +k sesame">>),
    want(cmd(B, <<"JOIN #ck">>), <<" 475 ck_bob #ck :Cannot join channel (+k)">>),
    want(cmd(B, <<"JOIN #ck sesamE">>), <<" 475 ">>),
    want(cmd(B, <<"JOIN #ck sesame-longer">>), <<" 475 ">>),
    want(cmd(B, <<"JOIN #ck sesame">>), <<" 366 ck_bob #ck ">>),
    close_all([A, B]).

%% --- MODE and KICK on a member of another server ---------------------------

remote_members(Port) ->
    A = client(Port, <<"rm_alice">>),
    B = client(Port, <<"rm_bob">>),
    Peer = handshake(Port, <<"peer.test">>),
    sync_peer(Peer),
    join(A, <<"#rm">>),
    join(B, <<"#rm">>),
    send(Peer, <<":peer.test NICK rm_rem 1 user peer.test 1 + :Remote">>),
    send(Peer, <<":peer.test NICK rm_far 1 user peer.test 1 + :Far">>),
    send(Peer, <<":rm_rem!user@peer.test JOIN #rm">>),
    sync_peer(Peer),
    _ = recv_until(A, <<"JOIN #rm">>),
    _ = recv_until(B, <<"JOIN #rm">>),
    %% Only a channel operator may change a remote member's status.
    want(cmd(B, <<"MODE #rm +o rm_rem">>), <<" 482 ">>),
    Op = cmd(A, <<"MODE #rm +o rm_rem">>),
    want(Op, <<" MODE #rm +o rm_rem">>),
    want(recv_until(B, <<"+o rm_rem">>), <<"MODE #rm +o rm_rem">>),
    want(recv_until(Peer, <<"+o rm_rem">>), <<" MODE #rm +o rm_rem">>),
    want(cmd(B, <<"NAMES #rm">>), <<"@rm_rem">>),
    %% Repeating the change is not announced again.
    ?assertNot(has(cmd(A, <<"MODE #rm +o rm_rem">>), <<"MODE #rm">>)),
    want(cmd(A, <<"MODE #rm -o+v rm_rem rm_rem">>), <<"MODE #rm -o+v rm_rem rm_rem">>),
    want(recv_until(Peer, <<"-o+v">>), <<"MODE #rm -o+v rm_rem rm_rem">>),
    want(cmd(B, <<"NAMES #rm">>), <<"+rm_rem">>),
    %% A remote user who is not on the channel is 441; an unknown one 401.
    want(cmd(A, <<"MODE #rm +v rm_far">>), <<" 441 rm_alice rm_far #rm ">>),
    want(cmd(A, <<"KICK #rm rm_far">>), <<" 441 rm_alice rm_far #rm ">>),
    want(cmd(A, <<"KICK #rm rm_ghost">>), <<" 401 rm_alice rm_ghost ">>),
    %% KICK of the remote member: local members see it, the peer is told.
    Kick = cmd(A, <<"KICK #rm rm_rem :bye">>),
    want(Kick, <<"KICK #rm rm_rem :bye">>),
    want(recv_until(B, <<"KICK">>), <<"KICK #rm rm_rem :bye">>),
    want(recv_until(Peer, <<"KICK">>), <<" KICK #rm rm_rem :bye">>),
    ?assertNot(has(cmd(B, <<"NAMES #rm">>), <<"rm_rem">>)),
    want(cmd(A, <<"MODE #rm +o rm_rem">>), <<" 441 rm_alice rm_rem #rm ">>),
    gen_tcp:close(Peer),
    close_all([A, B]).

%% --- Safe-channel reop reaches peers (RFC 2811 3.2, RFC 2813) --------------

reop_propagated(Port) ->
    A = client(Port, <<"rp_alice">>),
    B = client(Port, <<"rp_bob">>),
    Peer = handshake(Port, <<"peer.test">>),
    sync_peer(Peer),
    Safe = safe_name(join(A, <<"!rpreop">>)),
    join(B, Safe),
    cmd(A, <<"MODE ", Safe/binary, " +r">>),
    cmd(A, <<"PART ", Safe/binary>>),
    want(recv_until(B, <<"MODE ", Safe/binary, " +o rp_bob">>, 8000), <<":irc.test MODE">>),
    want(
        recv_until(Peer, <<"MODE ", Safe/binary, " +o rp_bob">>, 3000),
        <<":irc.test MODE ", Safe/binary, " +o rp_bob">>
    ),
    gen_tcp:close(Peer),
    close_all([A, B]).

%% --- helpers ----------------------------------------------------------------

start() ->
    Dir = filename:join(
        "/tmp", "ircd-channel-fix-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(Db)),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    #{port => listener_port(), config => Config}.

stop(_) ->
    _ = application:stop(ircd),
    os:unsetenv("IRCD_CONFIG"),
    ok.

config(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"emergency\",\"log_format\":\"text\",\"max_clients\":100,">>,
        <<"\"reop_delay\":1,">>,
        <<"\"operators\":[{\"name\":\"fixop\",\"password\":\"fixpw\"}],">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\",\"server_links\":[{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false}]}">>
    ]).

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

client(Port, Nick) ->
    Sock = connect(Port),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER u 0 * :Real">>),
    want(recv_until(Sock, <<" 001 ">>), <<" 001 ", Nick/binary>>),
    _ = cmd(Sock, <<"PING :ready">>),
    Sock.

handshake(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    want(recv_until(Sock, <<"SERVER irc.test">>), <<"SERVER irc.test">>),
    Sock.

%% A PING round trip on a link: every earlier line from the peer is applied.
sync_peer(Peer) ->
    Token = integer_to_binary(erlang:unique_integer([positive])),
    send(Peer, <<"PING :", Token/binary>>),
    recv_until(Peer, Token).

join(Sock, Name) ->
    cmd(Sock, <<"JOIN ", Name/binary>>).

close_all(Socks) ->
    lists:foreach(
        fun(S) ->
            _ = gen_tcp:send(S, <<"QUIT\r\n">>),
            gen_tcp:close(S)
        end,
        Socks
    ).

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

%% Send one command followed by a PING marker; returns everything up to the PONG.
cmd(Sock, Line) ->
    send(Sock, Line),
    Token = <<"sync", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    send(Sock, <<"PING :", Token/binary>>),
    recv_until(Sock, Token).

recv_until(Sock, Needle) ->
    recv_until(Sock, Needle, 3000).

recv_until(Sock, Needle, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    recv_loop(Sock, Needle, Deadline, <<>>).

recv_loop(Sock, Needle, Deadline, Acc) ->
    case has(Acc, Needle) andalso binary:last(Acc) =:= $\n of
        true ->
            Acc;
        false ->
            Left = Deadline - erlang:monotonic_time(millisecond),
            case Left > 0 of
                false ->
                    Acc;
                true ->
                    case gen_tcp:recv(Sock, 0, Left) of
                        {ok, <<_/binary>> = Bin} ->
                            recv_loop(Sock, Needle, Deadline, <<Acc/binary, Bin/binary>>);
                        {error, _} ->
                            Acc
                    end
            end
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

safe_name(Bin) ->
    case binary:match(Bin, <<"JOIN !">>) of
        {Start, _} ->
            <<_:Start/binary, "JOIN ", Rest/binary>> = Bin,
            {End, _} = binary:match(Rest, <<"\r\n">>),
            binary:part(Rest, 0, End);
        nomatch ->
            error(missing_safe_channel)
    end.

want(Bin, Needle) ->
    case has(Bin, Needle) of
        true -> ok;
        false -> erlang:error({missing, Needle, Bin})
    end.
