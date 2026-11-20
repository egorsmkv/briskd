-module(ircd_conformance_tests).
-include_lib("eunit/include/eunit.hrl").

%% Regression tests for behaviour fixed while passing irctest
%% (`-m "not implementation-specific and not deprecated"`): channel mode
%% numerics, RPL_CREATIONTIME and RPL_TOPICWHOTIME, list numerics, TARGMAX,
%% WALLOPS, LUSERS 265/266, WHOIS 317, USER validation, the server password,
%% WHO of an invisible nickname, and the opt-in multiclient and account rejoin.

conformance_test_() ->
    {timeout, 120, fun run/0}.

run() ->
    Dir = filename:join(
        "/tmp", "ircd-conformance-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(filename:join(Dir, "db"))),
    application:stop(ircd),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    try
        channel_numerics(Port),
        messaging_and_queries(Port),
        registration(Port),
        deprecated_compatibility(Port),
        multiclient_and_rejoin(Port)
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

channel_numerics(Port) ->
    Op = client(Port, <<"chanop">>),
    send(Op, <<"JOIN #chan">>),
    Joined = collect(Op),
    ?assertNot(has(Joined, <<" 331 ">>)),
    send(Op, <<"MODE #chan +k :has space">>),
    ?assert(has(collect(Op), <<" 696 chanop #chan k * :">>)),
    send(Op, <<"MODE #chan +l :zero">>),
    ?assert(has(collect(Op), <<" 696 chanop #chan l zero :">>)),
    send(Op, <<"MODE #chan +int">>),
    ?assertEqual(1, count_lines(collect(Op), <<"MODE #chan +int">>)),
    send(Op, <<"MODE #chan">>),
    Modes = collect(Op),
    ?assert(has(Modes, <<" 324 chanop #chan +int">>)),
    ?assert(has(Modes, <<" 329 chanop #chan ">>)),
    send(Op, <<"MODE #chan +e bar!*@*">>),
    send(Op, <<"MODE #chan +I baz!*@*">>),
    _ = collect(Op),
    send(Op, <<"MODE #chan e">>),
    send(Op, <<"MODE #chan +e">>),
    Exceptions = collect(Op),
    ?assert(has(Exceptions, <<" 348 chanop #chan bar!*@*">>)),
    ?assert(has(Exceptions, <<" 349 chanop #chan :">>)),
    send(Op, <<"MODE #chan +I">>),
    Invites = collect(Op),
    ?assert(has(Invites, <<" 346 chanop #chan baz!*@*">>)),
    ?assert(has(Invites, <<" 347 chanop #chan :">>)),
    send(Op, <<"MODE #chan +o nobody">>),
    ?assert(has(collect(Op), <<" 401 chanop nobody ">>)),
    send(Op, <<"TOPIC #chan :hello">>),
    _ = collect(Op),
    Other = client(Port, <<"joiner">>),
    send(Other, <<"JOIN #chan">>),
    send(Op, <<"INVITE joiner #chan">>),
    _ = collect(Op),
    send(Other, <<"JOIN #chan">>),
    Topic = collect(Other),
    ?assert(has(Topic, <<" 332 joiner #chan :hello">>)),
    ?assert(has(Topic, <<" 333 joiner #chan chanop!">>)),
    gen_tcp:close(Other),
    gen_tcp:close(Op).

messaging_and_queries(Port) ->
    A = client(Port, <<"alpha">>),
    B = client(Port, <<"bravo">>),
    send(A, <<"PRIVMSG bravo,t1,t2,t3,t4 :hi">>),
    ?assert(has(collect(A), <<" 407 alpha t4 ">>)),
    ?assert(has(collect(B), <<"PRIVMSG bravo :hi">>)),
    send(A, <<"WHOIS bravo bravo">>),
    Whois = collect(A),
    ?assertMatch({match, _}, re:run(Whois, <<" 317 alpha bravo [0-9]+ [0-9]+ :">>)),
    send(B, <<"MODE bravo +iw">>),
    _ = collect(B),
    send(A, <<"WHO bravo">>),
    ?assert(has(collect(A), <<" 352 alpha * ">>)),
    send(A, <<"WHO brav*">>),
    ?assertNot(has(collect(A), <<" 352 ">>)),
    send(A, <<"LUSERS">>),
    Lusers = collect(A),
    ?assert(has(Lusers, <<" 251 alpha :There are 1 users and 1 invisible on 1 servers">>)),
    ?assert(has(Lusers, <<" 255 alpha :I have 2 clients and 0 servers">>)),
    ?assert(has(Lusers, <<" 265 alpha 2 2 :">>)),
    ?assert(has(Lusers, <<" 266 alpha 2 2 :">>)),
    send(A, <<"NICK alpha">>),
    ?assertNot(has(collect_quiet(A), <<"NICK">>)),
    send(A, <<"WALLOPS :hello">>),
    ?assert(has(collect(A), <<" 481 ">>)),
    send(A, <<"OPER oper opersecret">>),
    ?assert(has(collect(A), <<"MODE alpha +o">>)),
    send(A, <<"WALLOPS :hello opers">>),
    ?assert(has(collect(B), <<"WALLOPS :hello opers">>)),
    send(A, <<"LINKS">>),
    ?assert(has(collect(A), <<" 364 alpha irc.test irc.test :0 conformance server">>)),
    gen_tcp:close(A),
    gen_tcp:close(B).

registration(Port) ->
    Empty = connect(Port),
    send(Empty, <<"NICK emptyreal">>),
    send(Empty, <<"USER u * * :">>),
    ?assert(has(collect(Empty), <<" 461 ">>)),
    gen_tcp:close(Empty),
    Bad = connect(Port),
    send(Bad, <<"NICK baduser">>),
    send(Bad, <<"USER b@d * * :Real">>),
    ?assert(has(collect(Bad), <<" 468 ">>)),
    gen_tcp:close(Bad),
    Star = connect(Port),
    send(Star, <<"NICK starmode">>),
    send(Star, <<"USER star * * :Real">>),
    ?assert(has(collect(Star), <<" 001 ">>)),
    send(Star, <<"NONEXISTENT_COMMAND">>),
    ?assert(has(collect(Star), <<" 421 ">>)),
    send(Star, <<"QUIT :bye">>),
    ?assert(has(collect(Star), <<"ERROR :Closing Link">>)),
    gen_tcp:close(Star).

deprecated_compatibility(Port) ->
    A = client(Port, <<"legacy">>),
    %% Metadata 3.2 for a client without draft/metadata-2.
    send(A, <<"METADATA * GET display-name">>),
    ?assert(has(collect(A), <<" 766 legacy display-name :">>)),
    send(A, <<"METADATA * SET display-name :shown">>),
    Set = collect(A),
    ?assert(has(Set, <<" 761 legacy display-name * :shown">>)),
    ?assert(has(Set, <<" 762 ">>)),
    send(A, <<"METADATA nobodyhere LIST">>),
    ?assert(has(collect(A), <<" 765 nobodyhere :">>)),
    %% INVITE with the channel first, for a channel that does not exist.
    B = client(Port, <<"invitee">>),
    send(A, <<"INVITE #nowhere invitee">>),
    ?assert(has(collect(A), <<"INVITE #nowhere invitee">>)),
    ?assert(has(collect(B), <<"INVITE #nowhere invitee">>)),
    %% WHOWAS by mask, ending with the matched nickname.
    Gone = client(Port, <<"vanished">>),
    send(Gone, <<"QUIT">>),
    _ = collect(Gone),
    timer:sleep(100),
    send(A, <<"WHOWAS van*">>),
    Whowas = collect(A),
    ?assert(has(Whowas, <<" 314 legacy vanished ">>)),
    ?assert(has(Whowas, <<" 369 legacy vanished :">>)),
    send(A, <<"WHOWAS">>),
    NoParam = collect(A),
    ?assert(has(NoParam, <<" 431 ">>)),
    ?assert(has(NoParam, <<" 369 legacy * :">>)),
    %% NAMES lists users in secret channels under no channel.
    send(B, <<"JOIN #hidden">>),
    send(B, <<"MODE #hidden +s">>),
    _ = collect(B),
    send(A, <<"NAMES">>),
    ?assertNot(has(collect(A), <<"invitee">>)),
    gen_tcp:close(A),
    gen_tcp:close(B).

multiclient_and_rejoin(Port) ->
    Reg = client(Port, <<"owner">>),
    send(Reg, <<"REGISTER * * ownerpass">>),
    ?assert(has(collect(Reg), <<"REGISTER SUCCESS owner">>)),
    send(Reg, <<"JOIN #home">>),
    _ = collect(Reg),
    %% A second connection logged into the same account attaches to the nick.
    Second = connect(Port),
    send(Second, <<"CAP LS 302">>),
    _ = collect(Second),
    send(Second, <<"CAP REQ sasl">>),
    _ = collect(Second),
    send(Second, <<"AUTHENTICATE PLAIN">>),
    _ = collect(Second),
    send(Second, <<"AUTHENTICATE ", (base64:encode(<<0, "owner", 0, "ownerpass">>))/binary>>),
    _ = collect(Second),
    send(Second, <<"NICK owner">>),
    send(Second, <<"USER o * * :Owner">>),
    send(Second, <<"CAP END">>),
    ?assert(has(collect(Second), <<" 001 owner ">>)),
    Friend = client(Port, <<"friend">>),
    send(Friend, <<"PRIVMSG owner :to both">>),
    ?assert(has(collect(Reg), <<"PRIVMSG owner :to both">>)),
    ?assert(has(collect(Second), <<"PRIVMSG owner :to both">>)),
    send(Second, <<"QUIT">>),
    _ = collect(Second),
    send(Friend, <<"WHOIS owner">>),
    ?assert(has(collect(Friend), <<" 311 friend owner ">>)),
    %% With account_rejoin, the account is rejoined to its channels.
    gen_tcp:close(Reg),
    timer:sleep(200),
    Back = connect(Port),
    send(Back, <<"CAP LS 302">>),
    _ = collect(Back),
    send(Back, <<"CAP REQ sasl">>),
    _ = collect(Back),
    send(Back, <<"AUTHENTICATE PLAIN">>),
    _ = collect(Back),
    send(Back, <<"AUTHENTICATE ", (base64:encode(<<0, "owner", 0, "ownerpass">>))/binary>>),
    _ = collect(Back),
    send(Back, <<"NICK owner2">>),
    send(Back, <<"USER o * * :Owner">>),
    send(Back, <<"CAP END">>),
    ?assert(has(collect(Back), <<"JOIN #home">>)),
    gen_tcp:close(Back),
    gen_tcp:close(Friend).

%%% Helpers

config(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",">>,
        <<"\"server_info\":\"conformance server\",\"multiclient\":true,\"account_rejoin\":true,">>,
        <<"\"operators\":[{\"name\":\"oper\",\"password\":\"opersecret\"}],">>,
        <<"\"mnesia_dir\":\"">>,
        Db,
        <<"\"}">>
    ]).

client(Port, Nick) ->
    Sock = connect(Port),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :Real ", Nick/binary>>),
    ?assert(has(collect(Sock), <<" 001 ">>)),
    Sock.

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

collect(Sock) ->
    collect(Sock, <<>>, 0, true).

collect_quiet(Sock) ->
    collect(Sock, <<>>, 0, false).

collect(Sock, Acc, N, Wait) when N < 60 ->
    Timeout =
        case {Wait, Acc} of
            {true, <<>>} -> 200;
            _ -> 80
        end,
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, <<_/binary>> = Bin} -> collect(Sock, <<Acc/binary, Bin/binary>>, N + 1, Wait);
        {error, timeout} when Wait, Acc =:= <<>>, N < 15 -> collect(Sock, Acc, N + 1, Wait);
        {error, _} -> Acc
    end;
collect(_Sock, Acc, _, _) ->
    Acc.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

count_lines(Bin, Needle) ->
    length([L || L <- binary:split(Bin, <<"\r\n">>, [global]), has(L, Needle)]).
