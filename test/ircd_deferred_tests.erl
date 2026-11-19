-module(ircd_deferred_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ircd/include/ircd_account.hrl").

%% PBKDF2 work for SASL PLAIN and REGISTER runs in workers (ircd_deferred), so
%% ircd_state keeps serving other clients, and the deferred reply keeps the
%% caller's ordering and labeled-response context.

%% A verifier this expensive takes on the order of a second to derive.
-define(SLOW_ITERATIONS, 1000000).

busy_pool_fails_fast_test() ->
    %% With every worker slot taken the continuation runs at once with
    %% {error, busy}, in the caller's reply context.
    put(ircd_deferred_count, 32),
    try
        Self = self(),
        {reply, Reply, <<"irc.test">>} = ircd_deferred:start(
            {Self, make_ref()},
            Self,
            fun() -> error(must_not_run) end,
            fun(Result) -> {continued, Result} end,
            <<"irc.test">>
        ),
        ?assertEqual({continued, {error, busy}}, Reply),
        ?assertEqual(32, ircd_deferred:in_flight())
    after
        erase(ircd_deferred_count)
    end.

request_is_taken_once_test() ->
    ?assertEqual(none, ircd_deferred:take()),
    ok = ircd_deferred:request(fun() -> 1 end, fun(R) -> R end),
    ?assertMatch({_, _}, ircd_deferred:take()),
    ?assertEqual(none, ircd_deferred:take()).

live_test_() ->
    {timeout, 120, fun live/0}.

live() ->
    Dir = filename:join(
        "/tmp", "ircd-deferred-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(filename:join(Dir, "db"))),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    try
        Port = listener_port(),
        slow_account(<<"slowacct">>, <<"slowpassword">>),
        state_stays_responsive(Port),
        pipelined_cap_end_and_label(Port),
        disconnect_while_deriving(Port),
        wrong_password_fails(Port),
        register_creates_account(Port)
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

config(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"error\",\"log_format\":\"text\",\"resource_delay\":0,">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).

%% An account whose verifier uses many PBKDF2 rounds (as one imported from a
%% peer may), so its PLAIN check is slow enough to observe.
slow_account(Name, Password) ->
    Salt = crypto:strong_rand_bytes(16),
    {Stored, ServerKey} = ircd_account:verifier(Password, {Salt, ?SLOW_ITERATIONS}),
    ok = mnesia:dirty_write(#account{
        key = Name,
        name = Name,
        salt = Salt,
        iterations = ?SLOW_ITERATIONS,
        stored_key = Stored,
        server_key = ServerKey,
        created = erlang:system_time(microsecond)
    }).

plain(Name, Password) ->
    base64:encode(<<0, Name/binary, 0, Password/binary>>).

state_stays_responsive(Port) ->
    Other = register_client(Port, <<"other">>),
    Slow = connect(Port),
    send(Slow, <<"CAP LS 302\r\nCAP REQ :sasl\r\nNICK slowone\r\nUSER s 0 * :S">>),
    _ = recv_until(Slow, <<"ACK">>),
    send(Slow, <<"AUTHENTICATE PLAIN">>),
    _ = recv_until(Slow, <<"AUTHENTICATE +">>),
    Started = erlang:monotonic_time(millisecond),
    send(Slow, <<"AUTHENTICATE ", (plain(<<"slowacct">>, <<"slowpassword">>))/binary>>),
    %% While the slow derivation runs, another client is served at once.
    timer:sleep(50),
    ?assertEqual(1, ircd_deferred_in_flight()),
    PingStart = erlang:monotonic_time(millisecond),
    send(Other, <<"PING :fast">>),
    _ = recv_until(Other, <<"PONG">>),
    PingMs = erlang:monotonic_time(millisecond) - PingStart,
    Logged = recv_until(Slow, <<" 903 ">>),
    AuthMs = erlang:monotonic_time(millisecond) - Started,
    ?assert(has(Logged, <<" 900 slowone ">>)),
    %% The PING was answered well before the login finished.
    ?assert(PingMs < AuthMs),
    ?assert(PingMs < 250),
    ?assertEqual(0, ircd_deferred_in_flight()),
    close(Slow),
    close(Other).

pipelined_cap_end_and_label(Port) ->
    S = connect(Port),
    send(
        S, <<"CAP LS 302\r\nCAP REQ :sasl labeled-response batch\r\nNICK piped\r\nUSER p 0 * :P">>
    ),
    _ = recv_until(S, <<"ACK">>),
    send(S, <<"AUTHENTICATE PLAIN">>),
    _ = recv_until(S, <<"AUTHENTICATE +">>),
    %% The final chunk, labeled, with CAP END pipelined in the same packet:
    %% the session waits for the deferred reply, so registration happens
    %% after the login and 001 follows 903.
    send(
        S,
        <<"@label=lbl1 AUTHENTICATE ", (plain(<<"slowacct">>, <<"slowpassword">>))/binary,
            "\r\nCAP END">>
    ),
    Data = recv_until(S, <<" 001 ">>),
    {Login, _} = binary:match(Data, <<" 903 ">>),
    {Welcome, _} = binary:match(Data, <<" 001 ">>),
    ?assert(Login < Welcome),
    %% Several replies (900, 903) come back in one labeled-response batch.
    ?assert(has(Data, <<"@label=lbl1 ">>)),
    ?assert(has(Data, <<"labeled-response">>)),
    send(S, <<"WHOIS piped">>),
    ?assert(has(recv_until(S, <<" 318 ">>), <<" 330 piped piped slowacct ">>)),
    close(S).

disconnect_while_deriving(Port) ->
    State = whereis(ircd_state),
    S = connect(Port),
    send(S, <<"CAP LS 302\r\nCAP REQ :sasl\r\nNICK leaver\r\nUSER l 0 * :L">>),
    _ = recv_until(S, <<"ACK">>),
    send(S, <<"AUTHENTICATE PLAIN">>),
    _ = recv_until(S, <<"AUTHENTICATE +">>),
    send(S, <<"AUTHENTICATE ", (plain(<<"slowacct">>, <<"slowpassword">>))/binary>>),
    timer:sleep(50),
    close(S),
    wait_until(fun() -> ircd_deferred_in_flight() =:= 0 end, 100),
    ?assertEqual(State, whereis(ircd_state)),
    ?assertEqual(undefined, ircd_state:find_nick(<<"leaver">>)).

wrong_password_fails(Port) ->
    S = connect(Port),
    send(S, <<"CAP LS 302\r\nCAP REQ :sasl\r\nNICK wrongpw\r\nUSER w 0 * :W">>),
    _ = recv_until(S, <<"ACK">>),
    send(S, <<"AUTHENTICATE PLAIN">>),
    _ = recv_until(S, <<"AUTHENTICATE +">>),
    send(S, <<"AUTHENTICATE ", (plain(<<"slowacct">>, <<"not-the-password">>))/binary>>),
    ?assert(has(recv_until(S, <<" 904 ">>), <<" 904 wrongpw ">>)),
    %% Unknown accounts take the same path and fail the same way.
    send(S, <<"AUTHENTICATE PLAIN">>),
    _ = recv_until(S, <<"AUTHENTICATE +">>),
    send(S, <<"AUTHENTICATE ", (plain(<<"nobodyhere">>, <<"whatever1">>))/binary>>),
    ?assert(has(recv_until(S, <<" 904 ">>), <<" 904 wrongpw ">>)),
    close(S).

register_creates_account(Port) ->
    S = register_client(Port, <<"newbie">>),
    send(S, <<"CAP REQ draft/account-registration">>),
    _ = recv_until(S, <<"ACK">>),
    send(S, <<"REGISTER newbie * longenoughpassword">>),
    Data = recv_until(S, <<"REGISTER SUCCESS">>),
    ?assert(has(Data, <<" 900 newbie ">>)),
    ?assertMatch({ok, #account{name = <<"newbie">>}}, ircd_account:find(<<"newbie">>)),
    ?assertMatch({ok, _}, ircd_account:check_password(<<"newbie">>, <<"longenoughpassword">>)),
    %% The name check repeats before the write, so a second REGISTER fails.
    S2 = register_client(Port, <<"second">>),
    send(S2, <<"CAP REQ draft/account-registration">>),
    _ = recv_until(S2, <<"ACK">>),
    send(S2, <<"REGISTER newbie * anotherpassword">>),
    ?assert(has(recv_until(S2, <<"FAIL REGISTER">>), <<"ACCOUNT_EXISTS">>)),
    close(S2),
    close(S).

ircd_deferred_in_flight() ->
    %% The counter lives in the ircd_state process dictionary.
    {dictionary, Dict} = process_info(whereis(ircd_state), dictionary),
    proplists:get_value(ircd_deferred_count, Dict, 0).

wait_until(Fun, 0) ->
    ?assert(Fun());
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, N - 1)
    end.

%%% Helpers

register_client(Port, Nick) ->
    S = connect(Port),
    send(S, <<"NICK ", Nick/binary, "\r\nUSER ", Nick/binary, " 0 * :T">>),
    _ = recv_until(S, <<" 001 ">>),
    S.

connect(Port) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    S.

send(S, Line) ->
    ok = gen_tcp:send(S, [Line, <<"\r\n">>]).

recv_until(S, Needle) ->
    recv_until(S, Needle, <<>>).

recv_until(S, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            {ok, Data} = gen_tcp:recv(S, 0, 10000),
            recv_until(S, Needle, <<Acc/binary, Data/binary>>);
        _ ->
            %% Collect the rest of the burst that arrived with the needle.
            case gen_tcp:recv(S, 0, 200) of
                {ok, More} -> recv_until(S, Needle, <<Acc/binary, More/binary>>);
                {error, timeout} -> Acc
            end
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

close(S) ->
    gen_tcp:close(S).

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.
