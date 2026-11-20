-module(ircd_cov_query_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ircd/include/ircd_state.hrl").
-include_lib("ircd/include/ircd_account.hrl").

%% Live coverage for server queries (RFC 2812 3.4), service queries (3.5),
%% user queries (3.6), and operator and optional commands (3.7, 4), plus the
%% ircd_state dispatcher and its gen_server API. Each test starts the `ircd`
%% application on an ephemeral TCP port with its own Mnesia directory.

info_and_operator_test_() ->
    {timeout, 120, fun info_and_operator/0}.

queries_test_() ->
    {timeout, 120, fun queries/0}.

dispatcher_test_() ->
    {timeout, 120, fun dispatcher/0}.

migration_test_() ->
    {timeout, 60, fun migration/0}.

%% ---------------------------------------------------------------------------
%% Server queries, STATS, LUSERS, TRACE, OPER, operator commands, REHASH.

info_and_operator() ->
    Dir = dir(<<"cov-info">>),
    Config = start(Dir, info_extra(Dir, #{})),
    try
        Port = listener_port(),
        Alice = register_client(Port, <<"alice">>),
        Bob = register_client(Port, <<"bob">>),
        ?assert(has(cmd(Bob, <<"MODE bob +w">>), <<"+w">>)),
        %% An unregistered connection counts as unknown in LUSERS.
        Carol = connect(Port),
        send(Carol, <<"NICK carol">>),
        %% A connection that has sent nothing has no nickname yet.
        Bare = connect(Port),
        ?assert(has(cmd(Bare, <<"CAP LS 302">>), <<"CAP * LS">>)),
        server_queries(Alice),
        motd_and_stats(Alice),
        lusers_before_oper(Alice),
        trace_before_oper(Alice),
        permission_denied(Alice),
        oper_login(Alice),
        after_oper(Alice, Bob),
        services(Alice),
        server_commands(Alice),
        kill_commands(Alice, Bob),
        rehash(Port, Alice, Dir, Config),
        %% KILL on one's own nickname closes the operator's connection.
        send(Alice, <<"KILL alice :self">>),
        ?assert(has(recv_until(Alice, <<"KILL alice">>), <<"KILL alice :self">>)),
        gen_tcp:close(Carol),
        gen_tcp:close(Bare)
    after
        stop()
    end.

server_queries(Alice) ->
    Version = cmd(Alice, <<"VERSION">>),
    ?assert(has(Version, <<" 351 alice 0.1.0 irc.test :Erlang/OTP IRC server">>)),
    ?assert(has(cmd(Alice, <<"VERSION irc.*">>), <<" 351 ">>)),
    ?assert(has(cmd(Alice, <<"VERSION no.such">>), <<" 402 alice no.such ">>)),
    ?assert(has(cmd(Alice, <<"TIME">>), <<" 391 alice irc.test :">>)),
    ?assert(has(cmd(Alice, <<"TIME no.such">>), <<" 402 alice no.such ">>)),
    Admin = cmd(Alice, <<"ADMIN">>),
    ?assert(has(Admin, <<" 256 alice irc.test :Test Admin">>)),
    ?assert(has(Admin, <<" 257 alice :Kyiv">>)),
    ?assert(has(Admin, <<" 258 alice :Server room">>)),
    ?assert(has(Admin, <<" 259 alice :admin@example.test">>)),
    %% RFC 2812 3.4.9: the target may be a nickname on this server.
    ?assert(has(cmd(Alice, <<"ADMIN bob">>), <<" 256 ">>)),
    ?assert(has(cmd(Alice, <<"ADMIN no.such">>), <<" 402 alice no.such ">>)),
    Info = cmd(Alice, <<"INFO">>),
    ?assert(has(Info, <<" 371 alice :ircd-0.1.0">>)),
    ?assert(has(Info, <<" 371 alice :Started: ">>)),
    ?assert(has(Info, <<" 374 alice :End of INFO list">>)),
    ?assert(has(cmd(Alice, <<"INFO no.such">>), <<" 402 ">>)),
    Links = cmd(Alice, <<"LINKS">>),
    ?assert(has(Links, <<" 364 alice irc.test irc.test :0 Coverage server">>)),
    ?assert(has(Links, <<" 365 alice * :End of LINKS list">>)),
    Masked = cmd(Alice, <<"LINKS nomatch.*">>),
    ?assertNot(has(Masked, <<" 364 ">>)),
    ?assert(has(Masked, <<" 365 alice nomatch.* ">>)),
    ?assert(has(cmd(Alice, <<"LINKS irc.test irc.*">>), <<" 364 ">>)),
    ?assert(has(cmd(Alice, <<"LINKS no.such *">>), <<" 402 alice no.such ">>)),
    ?assert(has(cmd(Alice, <<"USERS">>), <<" 446 ">>)),
    ?assert(has(cmd(Alice, <<"USERS no.such">>), <<" 402 ">>)),
    ?assert(has(cmd(Alice, <<"SUMMON bob">>), <<" 445 ">>)).

motd_and_stats(Alice) ->
    Motd = cmd(Alice, <<"MOTD">>),
    ?assert(has(Motd, <<" 375 alice :- Message of the day -">>)),
    ?assert(has(Motd, <<" 372 alice :- Welcome\r\n">>)),
    %% A blank line stays a blank 372; CR before LF is stripped.
    ?assert(has(Motd, <<" 372 alice :- \r\n">>)),
    %% A line longer than 80 octets is wrapped into 80-octet pieces.
    Long = binary:copy(<<"x">>, 80),
    Tail = binary:copy(<<"x">>, 20),
    ?assert(has(Motd, <<" 372 alice :- ", Long/binary, "\r\n">>)),
    ?assert(has(Motd, <<" 372 alice :- ", Tail/binary, "\r\n">>)),
    ?assert(has(Motd, <<" 376 alice :End of MOTD command">>)),
    ?assert(has(cmd(Alice, <<"MOTD no.such">>), <<" 402 ">>)),
    Uptime = cmd(Alice, <<"STATS u">>),
    ?assert(has(Uptime, <<" 242 alice :Server Up 0 days 00:">>)),
    ?assert(has(Uptime, <<" 219 alice u :End of STATS report">>)),
    ?assert(has(cmd(Alice, <<"STATS u irc.test">>), <<" 242 ">>)),
    ?assert(has(cmd(Alice, <<"STATS u no.such">>), <<" 402 alice no.such ">>)),
    Messages = cmd(Alice, <<"STATS m">>),
    ?assert(has(Messages, <<" 212 alice VERSION 3 ">>)),
    ?assert(has(Messages, <<" 219 alice m ">>)),
    %% A non-operator sees only its own STATS l line and no O-lines.
    Links = cmd(Alice, <<"STATS l">>),
    ?assert(has(Links, <<" 211 alice alice 0 ">>)),
    ?assertNot(has(Links, <<" 211 alice bob ">>)),
    ?assert(has(Links, <<" 219 alice l ">>)),
    Opers = cmd(Alice, <<"STATS o">>),
    ?assert(has(Opers, <<" 481 alice :Permission Denied">>)),
    ?assertNot(has(Opers, <<" 243 ">>)),
    ?assert(has(Opers, <<" 219 alice o ">>)),
    ?assert(has(cmd(Alice, <<"STATS q">>), <<" 219 alice q :End of STATS report">>)),
    ?assert(has(cmd(Alice, <<"STATS">>), <<" 219 alice * ">>)).

lusers_before_oper(Alice) ->
    Lusers = cmd(Alice, <<"LUSERS">>),
    ?assert(has(Lusers, <<" 251 alice :There are 2 users and 0 invisible on 1 servers">>)),
    ?assertNot(has(Lusers, <<" 252 ">>)),
    ?assert(has(Lusers, <<" 253 alice 2 :unknown connection(s)">>)),
    %% The configured #Lobby exists before anyone joins.
    ?assert(has(Lusers, <<" 254 alice 1 :channels formed">>)),
    ?assert(has(Lusers, <<" 255 alice :I have 2 clients and 0 servers">>)),
    ?assert(has(Lusers, <<" 265 alice 2 2 ">>)),
    ?assert(has(Lusers, <<" 266 alice 2 2 ">>)),
    Masked = cmd(Alice, <<"LUSERS nomatch.*">>),
    ?assert(has(Masked, <<"There are 0 users and 0 invisible on 0 servers">>)),
    ?assert(has(cmd(Alice, <<"LUSERS * irc.test">>), <<" 251 ">>)),
    ?assert(has(cmd(Alice, <<"LUSERS * no.such">>), <<" 402 alice no.such ">>)),
    ?assert(has(cmd(Alice, <<"MODE alice +i">>), <<"+i">>)),
    ?assert(has(cmd(Alice, <<"LUSERS">>), <<"There are 1 users and 1 invisible">>)),
    %% A non-matching mask zeroes the invisible count too.
    ?assert(has(cmd(Alice, <<"LUSERS nomatch.*">>), <<"There are 0 users and 0 invisible">>)),
    ?assert(has(cmd(Alice, <<"MODE alice -i">>), <<"-i">>)).

trace_before_oper(Alice) ->
    %% A non-operator sees only operators in a server TRACE; there are none.
    Trace = cmd(Alice, <<"TRACE">>),
    ?assertNot(has(Trace, <<" 205 ">>)),
    ?assert(has(Trace, <<" 262 alice irc.test ircd-0.1.0 :End of TRACE">>)),
    ?assert(has(cmd(Alice, <<"TRACE irc.test">>), <<" 262 ">>)),
    User = cmd(Alice, <<"TRACE bob">>),
    ?assert(has(User, <<" 205 alice User 0 bob">>)),
    ?assert(has(User, <<" 262 ">>)),
    ?assert(has(cmd(Alice, <<"TRACE nobody">>), <<" 402 alice nobody ">>)).

permission_denied(Alice) ->
    lists:foreach(
        fun(Line) -> ?assert(has(cmd(Alice, Line), <<" 481 alice ">>)) end,
        [
            <<"KILL bob :no">>,
            <<"REHASH">>,
            %% DIE and RESTART are only ever sent by a non-operator here.
            <<"DIE">>,
            <<"RESTART">>,
            <<"CONNECT peer.test">>,
            <<"SQUIT peer.test">>,
            <<"SERVICE helper * svc :Helper">>,
            <<"WALLOPS :hello">>
        ]
    ),
    ?assert(has(cmd(Alice, <<"WALLOPS">>), <<" 461 alice WALLOPS ">>)).

oper_login(Alice) ->
    ?assert(has(cmd(Alice, <<"OPER">>), <<" 461 alice OPER ">>)),
    ?assert(has(cmd(Alice, <<"OPER oper">>), <<" 461 alice OPER ">>)),
    NoLine = cmd(Alice, <<"OPER nobody secret">>),
    ?assert(has(NoLine, <<" 491 alice :No O-lines for your host">>)),
    Wrong = cmd(Alice, <<"OPER oper wrongpass">>),
    ?assert(has(Wrong, <<" 464 alice :Password incorrect">>)),
    ?assertNot(has(Wrong, <<"wrongpass">>)),
    Ok = cmd(Alice, <<"OPER oper opersecret">>),
    ?assert(has(Ok, <<" 381 alice :You are now an IRC operator">>)),
    ?assert(has(Ok, <<"MODE alice +o">>)).

after_oper(Alice, Bob) ->
    ?assert(has(cmd(Alice, <<"LUSERS">>), <<" 252 alice 1 :operator(s) online">>)),
    %% An operator sees every connection and the O-lines (never passwords).
    Links = cmd(Alice, <<"STATS l">>),
    ?assert(has(Links, <<" 211 alice alice 0 ">>)),
    ?assert(has(Links, <<" 211 alice bob 0 ">>)),
    Opers = cmd(Alice, <<"STATS o">>),
    ?assert(has(Opers, <<" 243 alice O * * oper">>)),
    ?assert(has(Opers, <<" 243 alice O * * admin">>)),
    ?assertNot(has(Opers, <<"opersecret">>)),
    ?assert(has(Opers, <<" 219 alice o ">>)),
    Trace = cmd(Alice, <<"TRACE">>),
    ?assert(has(Trace, <<" 204 alice Oper 0 alice">>)),
    ?assert(has(Trace, <<" 205 alice User 0 bob">>)),
    ?assert(has(cmd(Alice, <<"TRACE alice">>), <<" 204 alice Oper 0 alice">>)),
    %% Bob (not an operator) now sees the operator in TRACE.
    BobTrace = cmd(Bob, <<"TRACE">>),
    ?assert(has(BobTrace, <<" 204 bob Oper 0 alice">>)),
    ?assertNot(has(BobTrace, <<" 205 bob User 0 bob">>)),
    send(Alice, <<"WALLOPS :network notice">>),
    ?assert(has(recv_until(Bob, <<"network notice">>), <<"WALLOPS :network notice">>)),
    ?assertNot(has(cmd(Alice, <<"PING :x">>), <<"network notice">>)).

services(Alice) ->
    ?assert(has(cmd(Alice, <<"SERVICE">>), <<" 461 alice SERVICE ">>)),
    ?assert(has(cmd(Alice, <<"SERVICE 1bad * svc :x">>), <<" 432 alice 1bad ">>)),
    ?assert(has(cmd(Alice, <<"SERVICE bob * svc :x">>), <<" 433 alice bob ">>)),
    Made = cmd(Alice, <<"SERVICE helper * svc :Helper bot">>),
    ?assert(has(Made, <<" 234 alice helper irc.test * svc 0 :Helper bot">>)),
    List = cmd(Alice, <<"SERVLIST">>),
    ?assert(has(List, <<" 234 alice helper irc.test * svc 1 :Helper bot">>)),
    ?assert(has(List, <<" 235 alice * * :End of service listing">>)),
    ?assert(has(cmd(Alice, <<"SERVLIST help*">>), <<" 234 ">>)),
    ?assert(has(cmd(Alice, <<"SERVLIST help* svc">>), <<" 234 ">>)),
    Other = cmd(Alice, <<"SERVLIST * other">>),
    ?assertNot(has(Other, <<" 234 ">>)),
    ?assert(has(Other, <<" 235 alice * other ">>)),
    ?assert(has(cmd(Alice, <<"SQUERY">>), <<" 411 alice ">>)),
    ?assert(has(cmd(Alice, <<"SQUERY helper">>), <<" 412 alice ">>)),
    ?assert(has(cmd(Alice, <<"SQUERY helper :">>), <<" 412 alice ">>)),
    ?assert(has(cmd(Alice, <<"SQUERY nosvc :hi">>), <<" 401 alice nosvc ">>)),
    %% A local service's queries go to the IRC operators as NOTICEs.
    ?assert(has(cmd(Alice, <<"SQUERY helper :status">>), <<"NOTICE helper :status">>)).

server_commands(Alice) ->
    ?assert(has(cmd(Alice, <<"CONNECT">>), <<" 461 alice CONNECT ">>)),
    ?assert(has(cmd(Alice, <<"CONNECT no.such">>), <<" 402 alice no.such ">>)),
    ?assert(has(cmd(Alice, <<"SQUIT">>), <<" 461 alice SQUIT ">>)),
    ?assert(has(cmd(Alice, <<"SQUIT no.such :bye">>), <<" 402 alice no.such ">>)).

kill_commands(Alice, Bob) ->
    ?assert(has(cmd(Alice, <<"KILL">>), <<" 461 alice KILL ">>)),
    ?assert(has(cmd(Alice, <<"KILL bob">>), <<" 461 alice KILL ">>)),
    ?assert(has(cmd(Alice, <<"KILL nobody :gone">>), <<" 401 alice nobody ">>)),
    _ = cmd(Alice, <<"MODE alice +w">>),
    send(Alice, <<"KILL bob :flooding">>),
    ?assert(has(recv_until(Bob, <<"KILL bob">>), <<"KILL bob :flooding">>)),
    %% Users with +w get the operator notice for the KILL.
    Notice = recv_until(Alice, <<"used KILL">>),
    ?assert(has(Notice, <<"WALLOPS :Oper alice used KILL on bob: flooding">>)),
    ?assert(has(cmd(Alice, <<"WHOIS bob">>), <<" 401 alice bob ">>)),
    gen_tcp:close(Bob).

rehash(Port, Alice, Dir, Config) ->
    Dave = connect(Port),
    send(Dave, <<"CAP REQ :draft/extended-isupport">>),
    send(Dave, <<"NICK dave">>),
    send(Dave, <<"USER dave 0 * :Dave">>),
    ?assert(has(cmd(Dave, <<"CAP END">>), <<"NICKLEN=9">>)),
    %% A client still in CAP negotiation is not sent the ISUPPORT update.
    Erin = connect(Port),
    send(Erin, <<"CAP REQ :draft/extended-isupport">>),
    ?assert(has(cmd(Erin, <<"NICK erin">>), <<"ACK">>)),
    %% The last MOTD line need not end with a newline.
    Motd2 = filename:join(Dir, "motd2.txt"),
    ok = file:write_file(Motd2, <<"Second edition">>),
    ok = file:write_file(
        Config,
        config(
            Dir,
            info_extra(Dir, #{motd => Motd2, admin => <<"New Admin">>, nicklen => 12, utf8 => true})
        )
    ),
    Rehashed = cmd(Alice, <<"REHASH">>),
    ?assert(has(Rehashed, <<" 382 alice ">>)),
    ?assert(has(Rehashed, <<":Rehashing">>)),
    Changed = recv_until(Dave, <<"NICKLEN=12">>),
    ?assert(has(Changed, <<" 005 dave ">>)),
    ?assert(has(Changed, <<"UTF8ONLY">>)),
    ?assertNot(has(cmd(Erin, <<"PING :x">>), <<"NICKLEN">>)),
    gen_tcp:close(Erin),
    ?assert(has(cmd(Alice, <<"ADMIN">>), <<" 256 alice irc.test :New Admin">>)),
    Motd = cmd(Alice, <<"MOTD">>),
    ?assert(has(Motd, <<" 372 alice :- Second edition">>)),
    ?assertNot(has(Motd, <<"Welcome">>)),
    %% An empty MOTD file has a start and an end and no text lines.
    ok = file:write_file(Motd2, <<>>),
    Empty = cmd(Alice, <<"MOTD">>),
    ?assert(has(Empty, <<" 375 ">>)),
    ?assertNot(has(Empty, <<" 372 ">>)),
    ?assert(has(Empty, <<" 376 ">>)),
    %% A configured file that cannot be read is RFC 2812 ERR_NOMOTD.
    ok = file:write_file(
        Config,
        config(Dir, info_extra(Dir, #{motd => filename:join(Dir, "missing.txt"), nicklen => 12}))
    ),
    ?assert(has(cmd(Alice, <<"REHASH">>), <<" 382 ">>)),
    %% A token that goes away is announced as `-TOKEN`.
    ?assert(has(recv_until(Dave, <<"-UTF8ONLY">>), <<" 005 dave -UTF8ONLY">>)),
    ?assert(has(cmd(Alice, <<"MOTD">>), <<" 422 alice :MOTD File is missing">>)),
    ok = file:write_file(Config, config(Dir, info_extra(Dir, #{motd => none, nicklen => 12}))),
    ?assert(has(cmd(Alice, <<"REHASH">>), <<" 382 ">>)),
    ?assert(has(cmd(Alice, <<"MOTD">>), <<" 422 ">>)),
    %% Listener changes need a restart and are refused.
    ok = file:write_file(
        Config, config(Dir, info_extra(Dir, #{tcp_port => <<"6999">>, nicklen => 12}))
    ),
    ?assert(has(cmd(Alice, <<"REHASH">>), <<" 400 alice REHASH :Listener and database">>)),
    ok = file:write_file(Config, <<"{not json">>),
    ?assert(has(cmd(Alice, <<"REHASH">>), <<" 400 alice REHASH :Configuration reload failed">>)),
    gen_tcp:close(Dave).

info_extra(Dir, Opts) ->
    Motd =
        case maps:get(motd, Opts, filename:join(Dir, "motd.txt")) of
            none -> <<>>;
            Path -> iolist_to_binary([<<"\"motd_file\":\"">>, Path, <<"\",">>])
        end,
    Utf8 =
        case maps:get(utf8, Opts, false) of
            true -> <<"\"utf8_only\":true,">>;
            false -> <<>>
        end,
    iolist_to_binary([
        Motd,
        Utf8,
        <<"\"admin_name\":\"">>,
        maps:get(admin, Opts, <<"Test Admin">>),
        <<"\",">>,
        <<"\"admin_location1\":\"Kyiv\",\"admin_location2\":\"Server room\",">>,
        <<"\"admin_email\":\"admin@example.test\",">>,
        <<"\"server_info\":\"Coverage server\",">>,
        <<"\"nicklen\":">>,
        integer_to_binary(maps:get(nicklen, Opts, 9)),
        <<",\"tcp_port\":">>,
        maps:get(tcp_port, Opts, <<"0">>),
        <<",">>
    ]).

%% ---------------------------------------------------------------------------
%% WHO, WHOIS, WHOWAS, ISON, USERHOST, AWAY, with local and remote users.

queries() ->
    _ = start(dir(<<"cov-queries">>), <<"\"tcp_port\":0,">>),
    try
        Port = listener_port(),
        Alice = register_client(Port, <<"alice">>),
        Bob = register_client(Port, <<"bob">>),
        Carol = register_client(Port, <<"carol">>),
        _ = cmd(Carol, <<"MODE carol +i">>),
        _ = cmd(Alice, <<"JOIN #q">>),
        _ = cmd(Bob, <<"JOIN #q">>),
        _ = cmd(Alice, <<"MODE #q +v bob">>),
        _ = cmd(Alice, <<"JOIN #sec">>),
        _ = cmd(Alice, <<"MODE #sec +s">>),
        who_local(Alice, Bob, Carol),
        whois_local(Alice, Bob, Carol),
        userhost_ison_away(Alice, Bob),
        whowas(Port, Alice),
        remote_queries(Port, Alice, Bob),
        gen_tcp:close(Alice),
        gen_tcp:close(Bob),
        gen_tcp:close(Carol)
    after
        stop()
    end.

who_local(Alice, Bob, Carol) ->
    All = cmd(Alice, <<"WHO">>),
    ?assert(has(All, <<" irc.test alice H@ :0 alice">>)),
    ?assert(has(All, <<" bob H+ :0 bob">>)),
    %% +i hides carol from a mask search by someone who shares no channel.
    ?assertNot(has(All, <<" carol ">>)),
    ?assert(has(All, <<" 315 alice * :End of WHO list">>)),
    %% An exact nickname still answers for an invisible user.
    Exact = cmd(Alice, <<"WHO carol">>),
    ?assert(has(Exact, <<" 352 alice * carol ">>)),
    ?assert(has(Exact, <<" 315 alice carol ">>)),
    ?assert(has(cmd(Carol, <<"WHO *">>), <<" carol H :0 carol">>)),
    Channel = cmd(Alice, <<"WHO #q">>),
    ?assert(has(Channel, <<" 352 alice #q alice 127.0.0.1 irc.test alice H@ :0 alice">>)),
    ?assert(has(Channel, <<" 352 alice #q bob 127.0.0.1 irc.test bob H+ :0 bob">>)),
    ?assert(has(Channel, <<" 315 alice #q ">>)),
    Masked = cmd(Alice, <<"WHO b*">>),
    ?assert(has(Masked, <<" bob H+ ">>)),
    ?assertNot(has(Masked, <<" alice H@ ">>)),
    ?assert(has(cmd(Alice, <<"WHO alice!*@*">>), <<" irc.test alice H@ ">>)),
    ?assertNot(has(cmd(Alice, <<"WHO #q o">>), <<" 352 ">>)),
    %% The secret channel is hidden from a non-member, shown to a member.
    ?assertNot(has(cmd(Bob, <<"WHO #sec">>), <<" 352 ">>)),
    ?assert(has(cmd(Alice, <<"WHO #sec">>), <<" 352 alice #sec alice ">>)),
    %% WHO for alice from bob names a channel bob can see, not #sec.
    ?assert(has(cmd(Bob, <<"WHO a*">>), <<" 352 bob #q alice ">>)),
    %% WHOX (IRCv3): requested fields in fixed order, with the query token.
    Whox = cmd(Alice, <<"WHO #q %tcuihsnfdlaor,42">>),
    ?assert(has(Whox, <<" 354 alice 42 #q alice 127.0.0.1 127.0.0.1 irc.test alice H@ 0 ">>)),
    ?assert(has(Whox, <<" 0 n/a :alice">>)),
    ?assert(has(Whox, <<" 315 alice #q ">>)),
    ?assert(has(cmd(Alice, <<"WHO bob %t">>), <<" 354 alice\r\n">>)),
    %% Another user's address is hidden from a non-operator.
    ?assert(has(cmd(Alice, <<"WHO bob %ni">>), <<" 354 alice 255.255.255.255 bob">>)),
    %% A malformed WHOX token falls back to an ordinary 352 reply.
    ?assert(has(cmd(Alice, <<"WHO bob %n,abcd">>), <<" 352 alice ">>)),
    ?assert(has(cmd(Alice, <<"WHO bob x%n">>), <<" 354 alice bob">>)).

whois_local(Alice, Bob, Carol) ->
    _ = cmd(Alice, <<"AWAY :lunch">>),
    _ = cmd(Alice, <<"OPER oper opersecret">>),
    Whois = cmd(Bob, <<"WHOIS alice">>),
    ?assert(has(Whois, <<" 311 bob alice alice 127.0.0.1 * :alice">>)),
    ?assert(has(Whois, <<" 301 bob alice :lunch">>)),
    ?assert(has(Whois, <<" 319 bob alice :@#q">>)),
    ?assertNot(has(Whois, <<"#sec">>)),
    ?assert(has(Whois, <<" 312 bob alice irc.test :IRC server">>)),
    ?assert(has(Whois, <<" 313 bob alice :is an IRC operator">>)),
    ?assert(has(Whois, <<" 317 bob alice ">>)),
    ?assert(has(Whois, <<" 318 bob alice :End of WHOIS list">>)),
    ?assert(has(cmd(Alice, <<"WHOIS alice">>), <<"#sec">>)),
    Many = cmd(Bob, <<"WHOIS alice,bob">>),
    ?assert(has(Many, <<" 311 bob alice ">>)),
    ?assert(has(Many, <<" 311 bob bob ">>)),
    ?assert(has(cmd(Bob, <<"WHOIS irc.test alice">>), <<" 311 bob alice ">>)),
    ?assert(has(cmd(Bob, <<"WHOIS alice alice">>), <<" 311 bob alice ">>)),
    ?assert(has(cmd(Bob, <<"WHOIS no.such alice">>), <<" 402 bob no.such ">>)),
    Missing = cmd(Bob, <<"WHOIS nobody">>),
    ?assert(has(Missing, <<" 401 bob nobody ">>)),
    ?assert(has(Missing, <<" 318 bob nobody ">>)),
    ?assert(has(cmd(Bob, <<"WHOIS">>), <<" 461 bob WHOIS ">>)),
    %% Invisible carol shares no channel with bob.
    ?assert(has(cmd(Bob, <<"WHOIS carol">>), <<" 401 bob carol ">>)),
    %% A user with no channels gets no 319 line about herself.
    Self = cmd(Carol, <<"WHOIS carol">>),
    ?assert(has(Self, <<" 311 carol carol ">>)),
    ?assertNot(has(Self, <<" 319 ">>)),
    %% An administrators entry is reported as an administrator.
    ?assert(has(cmd(Carol, <<"OPER admin adminsecret">>), <<" 381 ">>)),
    ?assert(has(cmd(Carol, <<"WHOIS carol">>), <<" 313 carol carol :is an IRC administrator">>)),
    %% The operator flag shows in WHO, and `o` restricts to operators.
    Ops = cmd(Bob, <<"WHO #q o">>),
    ?assert(has(Ops, <<" alice G*@ ">>)),
    ?assertNot(has(Ops, <<" bob H">>)),
    ?assert(has(cmd(Bob, <<"WHO * o">>), <<" alice G*@ ">>)),
    ?assert(has(cmd(Bob, <<"WHO alice o">>), <<" alice G* :0 alice">>)),
    ?assertNot(has(cmd(Bob, <<"WHO bob o">>), <<" 352 ">>)),
    ?assert(has(cmd(Bob, <<"WHO * %no">>), <<" 354 bob alice n/a">>)),
    %% Operators see a user's address in WHOX.
    ?assert(has(cmd(Alice, <<"WHO bob %ni">>), <<" 354 alice 127.0.0.1 bob">>)),
    %% Bot mode and an account appear in WHOIS (330, 335) and WHOX.
    _ = cmd(Bob, <<"MODE bob +B">>),
    ?assert(has(cmd(Bob, <<"REGISTER * * bobpassword">>), <<"REGISTER SUCCESS">>)),
    BobInfo = cmd(Alice, <<"WHOIS bob">>),
    ?assert(has(BobInfo, <<" 335 alice bob :is a bot">>)),
    ?assert(has(BobInfo, <<" 330 alice bob bob :is logged in as">>)),
    ?assert(has(cmd(Alice, <<"WHO bob %na">>), <<" 354 alice bob bob">>)),
    ?assert(has(cmd(Alice, <<"WHO #q">>), <<" bob HB+ ">>)),
    %% A long channel list wraps into more than one 319 line.
    Names = [long_channel(N) || N <- lists:seq(1, 8)],
    lists:foreach(fun(Name) -> _ = cmd(Bob, <<"JOIN ", Name/binary>>) end, Names),
    Wrapped = cmd(Alice, <<"WHOIS bob">>),
    ?assertEqual(2, count(Wrapped, <<" 319 alice bob :">>)),
    lists:foreach(fun(Name) -> _ = cmd(Bob, <<"PART ", Name/binary>>) end, Names).

long_channel(N) ->
    <<"#", (binary:copy(<<"c">>, 45))/binary, (integer_to_binary(N))/binary>>.

userhost_ison_away(Alice, Bob) ->
    Hosts = cmd(Bob, <<"USERHOST alice bob nobody">>),
    ?assert(has(Hosts, <<" 302 bob :alice*=-127.0.0.1 bob=+127.0.0.1\r\n">>)),
    ?assert(has(cmd(Bob, <<"USERHOST">>), <<" 461 bob USERHOST ">>)),
    ?assert(has(cmd(Bob, <<"ISON alice nobody bob">>), <<" 303 bob :alice bob\r\n">>)),
    ?assert(has(cmd(Bob, <<"ISON">>), <<" 461 bob ISON ">>)),
    ?assert(has(cmd(Bob, <<"ISON :">>), <<" 461 bob ISON ">>)),
    ?assert(has(cmd(Alice, <<"AWAY">>), <<" 305 alice ">>)),
    ?assert(has(cmd(Alice, <<"AWAY">>), <<" 305 alice ">>)),
    ?assert(has(cmd(Alice, <<"AWAY *">>), <<" 306 alice ">>)),
    ?assert(has(cmd(Bob, <<"WHOIS alice">>), <<" 301 bob alice :Away">>)),
    ?assert(has(cmd(Alice, <<"AWAY :">>), <<" 305 alice ">>)),
    ?assertNot(has(cmd(Bob, <<"WHOIS alice">>), <<" 301 ">>)).

whowas(Port, Alice) ->
    lists:foreach(
        fun(Real) ->
            Dave = connect(Port),
            send(Dave, <<"NICK dave">>),
            send(Dave, <<"USER dave 0 * :", Real/binary>>),
            send(Dave, <<"QUIT :bye">>),
            _ = recv_until(Dave, <<"ERROR">>),
            gen_tcp:close(Dave)
        end,
        [<<"first">>, <<"dave">>]
    ),
    %% Every earlier use is kept; a count limits the entries.
    All = cmd(Alice, <<"WHOWAS dave">>),
    ?assertEqual(2, count(All, <<" 314 alice dave ">>)),
    ?assertEqual(1, count(cmd(Alice, <<"WHOWAS dave 1">>), <<" 314 ">>)),
    Gone = cmd(Alice, <<"WHOWAS dave">>),
    ?assert(has(Gone, <<" 314 alice dave dave 127.0.0.1 * :dave">>)),
    ?assert(has(Gone, <<" 312 alice dave irc.test ">>)),
    ?assert(has(Gone, <<" 369 alice dave :End of WHOWAS">>)),
    ?assert(has(cmd(Alice, <<"WHOWAS dave 1">>), <<" 314 ">>)),
    ?assert(has(cmd(Alice, <<"WHOWAS dave many">>), <<" 314 ">>)),
    ?assert(has(cmd(Alice, <<"WHOWAS dave 1 irc.test">>), <<" 314 ">>)),
    ?assert(has(cmd(Alice, <<"WHOWAS dave 1 no.such">>), <<" 402 alice no.such ">>)),
    %% A mask resolving to one nickname ends with that nickname.
    ?assert(has(cmd(Alice, <<"WHOWAS dav?">>), <<" 369 alice dave ">>)),
    Missing = cmd(Alice, <<"WHOWAS nobody">>),
    ?assert(has(Missing, <<" 406 alice nobody :There was no such nickname">>)),
    ?assert(has(Missing, <<" 369 alice nobody ">>)),
    Mixed = cmd(Alice, <<"WHOWAS dave,nobody">>),
    ?assert(has(Mixed, <<" 314 ">>)),
    ?assert(has(Mixed, <<" 369 alice dave,nobody ">>)),
    Empty = cmd(Alice, <<"WHOWAS">>),
    ?assert(has(Empty, <<" 431 alice :No nickname given">>)),
    ?assert(has(Empty, <<" 369 alice * ">>)).

remote_queries(Port, Alice, Bob) ->
    Peer = handshake(Port, <<"peer.test">>),
    peer_lines(Peer, [
        <<":peer.test NICK rop 1 ruser peer.test 1 +oaB :Remote Op">>,
        <<":peer.test NICK rinv 1 ruser peer.test 1 +i :Remote Inv">>,
        <<":peer.test NICK rplain 1 ruser peer.test 1 + :Remote Plain">>,
        <<":rop!ruser@peer.test JOIN #remote">>,
        <<":rinv!ruser@peer.test JOIN #remote">>,
        <<":rplain!ruser@peer.test JOIN #q">>
    ]),
    Remote = cmd(Alice, <<"WHO #remote">>),
    ?assert(has(Remote, <<" 352 alice #remote ruser peer.test peer.test rop G*B">>)),
    %% The hop count is the peer's distance plus this link.
    ?assert(has(Remote, <<" rop G*B :2 Remote Op">>)),
    %% rinv is invisible and shares no channel with alice.
    ?assertNot(has(Remote, <<" rinv ">>)),
    ?assert(has(cmd(Alice, <<"WHO #remote o">>), <<" rop G*B">>)),
    ?assert(has(cmd(Alice, <<"WHO #remote %tna,7">>), <<" 354 alice 7 rop 0">>)),
    ?assert(has(cmd(Alice, <<"WHO #q">>), <<" 352 alice #q ruser peer.test peer.test rplain H ">>)),
    %% A WHO mask also matches a remote user's real name.
    Real = cmd(Alice, <<"WHO *Plain">>),
    ?assert(has(Real, <<" rplain H ">>)),
    ?assertNot(has(Real, <<" rop ">>)),
    Masked = cmd(Alice, <<"WHO r*">>),
    ?assert(has(Masked, <<" 352 alice * ruser peer.test peer.test rop G*B ">>)),
    ?assert(has(Masked, <<" rplain H ">>)),
    ?assertNot(has(Masked, <<" rinv ">>)),
    OpsOnly = cmd(Alice, <<"WHO r* o">>),
    ?assert(has(OpsOnly, <<" rop G*B ">>)),
    ?assertNot(has(OpsOnly, <<" rplain ">>)),
    Whois = cmd(Bob, <<"WHOIS rop">>),
    ?assert(has(Whois, <<" 311 bob rop ruser peer.test * :Remote Op">>)),
    ?assert(has(Whois, <<" 312 bob rop peer.test ">>)),
    ?assert(has(Whois, <<" 301 bob rop :is away">>)),
    ?assert(has(Whois, <<" 313 bob rop :is an IRC operator">>)),
    ?assert(has(Whois, <<" 335 bob rop :is a bot">>)),
    ?assert(has(cmd(Bob, <<"WHOIS rop rop">>), <<" 311 bob rop ">>)),
    ?assert(has(cmd(Bob, <<"WHOIS rinv">>), <<" 401 bob rinv ">>)),
    ?assert(has(cmd(Bob, <<"WHOIS rplain">>), <<" 311 bob rplain ">>)),
    ?assert(
        has(cmd(Bob, <<"USERHOST rop rplain">>), <<" 302 bob :rop*=-peer.test rplain=+peer.test">>)
    ),
    ?assert(has(cmd(Bob, <<"ISON rop rinv gone">>), <<" 303 bob :rop rinv\r\n">>)),
    %% NAMES without parameters also lists channels known only from peers.
    Names = cmd(Bob, <<"NAMES">>),
    ?assert(has(Names, <<"#remote">>)),
    ?assert(has(Names, <<" 366 bob * ">>)),
    %% LINKS and LUSERS include the peer.
    ?assert(has(cmd(Bob, <<"LINKS">>), <<" 364 bob peer.test irc.test :1 ">>)),
    ?assertNot(has(cmd(Bob, <<"LINKS irc.*">>), <<"peer.test">>)),
    Lusers = cmd(Bob, <<"LUSERS">>),
    ?assert(has(Lusers, <<" 252 bob 3 ">>)),
    ?assert(has(Lusers, <<"on 2 servers">>)),
    %% A local client cannot take a nickname in use behind a peer.
    ?assert(has(cmd(Bob, <<"NICK rop">>), <<" 433 bob rop ">>)),
    %% A secret channel known only from the peer is hidden from non-members.
    _ = peer_lines(Peer, [<<":peer.test MODE #remote +s">>]),
    ?assertNot(has(cmd(Alice, <<"WHO #remote">>), <<" 352 ">>)),
    %% Peer state commands keep the queries consistent.
    peer_lines(Peer, [
        <<":rplain!ruser@peer.test NICK rnew">>,
        <<":rop!ruser@peer.test AWAY">>,
        <<":rinv!ruser@peer.test QUIT :later">>
    ]),
    ?assert(has(cmd(Bob, <<"ISON rplain rnew rinv">>), <<" 303 bob :rnew\r\n">>)),
    ?assert(has(cmd(Bob, <<"USERHOST rop">>), <<"rop*=+peer.test">>)),
    ?assert(has(cmd(Bob, <<"WHOIS rnew">>), <<" 311 bob rnew ">>)),
    %% Only this server's own name is accepted as a WHOIS target server.
    ?assert(has(cmd(Bob, <<"WHOIS peer.test rnew">>), <<" 402 bob peer.test ">>)),
    peer_dispatch(Peer, Bob),
    gen_tcp:close(Peer),
    %% Link loss removes users reachable only through the peer.
    ?assert(eventually(fun() -> has(cmd(Bob, <<"WHOIS rop">>), <<" 401 bob rop ">>) end)).

%% Peer commands that the dispatcher routes to link handlers. Each line is
%% applied before the PING that follows it is answered.
peer_dispatch(Peer, Bob) ->
    peer_lines(Peer, [
        <<":peer.test SERVER leaf.test 2 2 :Leaf">>,
        <<":leaf.test NICK lu 1 luser leaf.test 2 + :Leaf User">>,
        <<":rnew!ruser@peer.test SETNAME :Renamed Real">>,
        <<":rnew!ruser@peer.test CHGHOST nuser new.host">>,
        <<":rnew!nuser@new.host REDACT #q someid">>,
        <<":rnew!nuser@new.host PART #q :leaving">>,
        <<":rnew!nuser@new.host JOIN #q">>,
        <<":rnew!nuser@new.host PART #q">>,
        <<":rnew!nuser@new.host JOIN #remote">>,
        <<":peer.test MODE #remote +o rop">>,
        <<":rop!ruser@peer.test KICK #remote rnew">>,
        <<":rop!ruser@peer.test INVITE bob #remote">>,
        <<":rop!ruser@peer.test SQUERY nosvc :hi">>,
        <<":peer.test FROB something">>
    ]),
    ?assert(has(recv_until(Bob, <<"INVITE bob">>), <<"INVITE bob #remote">>)),
    ?assert(has(cmd(Bob, <<"WHOIS rnew">>), <<"nuser new.host * :Renamed Real">>)),
    ?assert(has(cmd(Bob, <<"WHOIS lu">>), <<" 312 bob lu leaf.test ">>)),
    _ = peer_lines(Peer, [<<":peer.test SQUIT leaf.test">>]),
    ?assert(has(cmd(Bob, <<"WHOIS lu">>), <<" 401 bob lu ">>)),
    _ = peer_lines(Peer, [<<":peer.test KILL rnew :collision">>, <<":peer.test KILL rop">>]),
    ?assert(has(cmd(Bob, <<"ISON rnew rop">>), <<" 303 bob :\r\n">>)),
    _ = peer_lines(Peer, [
        <<":peer.test NICK rq 1 ruser peer.test 1 + :Quitter">>, <<":rq!ruser@peer.test QUIT">>
    ]),
    ?assert(has(cmd(Bob, <<"ISON rq">>), <<" 303 bob :\r\n">>)).

eventually(Check) ->
    eventually(Check, 20).

eventually(Check, 0) ->
    Check();
eventually(Check, N) ->
    case Check() of
        true ->
            true;
        false ->
            timer:sleep(100),
            eventually(Check, N - 1)
    end.

%% ---------------------------------------------------------------------------
%% Dispatcher: pre-registration rules, parameter checks, unknown commands,
%% and the gen_server API surface of ircd_state.

dispatcher() ->
    _ = start(dir(<<"cov-dispatch">>), <<"\"tcp_port\":0,">>),
    try
        Port = listener_port(),
        unregistered(Port),
        registered(Port),
        state_api()
    after
        stop()
    end,
    %% With the state process gone, a link close is ignored and nobody is an
    %% administrator.
    ?assertEqual(ok, ircd_state:server_disconnect(<<"peer.test">>)),
    ?assertNot(ircd_state:administrator(self())).

%% ---------------------------------------------------------------------------
%% Startup over an older Mnesia schema: rows gain the fields added since.

migration() ->
    Dir = dir(<<"cov-migrate">>),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    ok = application:set_env(mnesia, dir, Db),
    ok = mnesia:create_schema([node()]),
    ok = mnesia:start(),
    Old = fun(Fields, Drop) -> lists:sublist(Fields, length(Fields) - Drop) end,
    Disc = [{disc_copies, [node()]}],
    ChannelFields = Old(record_info(fields, channel), 3),
    {atomic, ok} = mnesia:create_table(channel, [{attributes, ChannelFields} | Disc]),
    {atomic, ok} = mnesia:create_table(client, [
        {attributes, Old(record_info(fields, client), 1)}, {index, [nick]} | Disc
    ]),
    {atomic, ok} = mnesia:create_table(account, [
        {attributes, Old(record_info(fields, account), 1)} | Disc
    ]),
    {atomic, ok} = mnesia:create_table(remote_channel, [
        {attributes, Old(record_info(fields, remote_channel), 2)} | Disc
    ]),
    {atomic, ok} = mnesia:create_table(remote_client, [
        {attributes, Old(record_info(fields, remote_client), 3)} | Disc
    ]),
    %% A table with an unknown older shape is left as it is.
    {atomic, ok} = mnesia:create_table(service, [
        {attributes, record_info(fields, service) ++ [extra]} | Disc
    ]),
    %% A RAM-only table becomes a disc copy.
    {atomic, ok} = mnesia:create_table(activity, [
        {attributes, record_info(fields, activity)}, {ram_copies, [node()]}
    ]),
    %% A safe channel row survives a transient restart, so it shows the
    %% migrated shape; the account row keeps its data.
    Safe = <<"!abcdesafe">>,
    ok = mnesia:dirty_write(
        list_to_tuple(
            [
                channel,
                Safe,
                Safe,
                <<"kept">>,
                #{},
                #{},
                #{},
                [],
                undefined,
                undefined,
                undefined,
                undefined
            ]
        )
    ),
    AccountRow = list_to_tuple([
        account,
        <<"acc">>,
        <<"Acc">>,
        <<"salt">>,
        4096,
        <<"s">>,
        <<"k">>,
        <<"*">>,
        [],
        1
    ]),
    ok = mnesia:dirty_write(AccountRow),
    ok = mnesia:dirty_write(
        list_to_tuple([
            remote_client,
            <<"r">>,
            <<"p">>,
            <<"r">>,
            <<"u">>,
            <<"h">>,
            <<"1">>,
            #{},
            <<"R">>
        ])
    ),
    stopped = mnesia:stop(),
    _ = start(Dir, <<"\"tcp_port\":0,">>),
    try
        ?assertEqual(record_info(fields, channel), mnesia:table_info(channel, attributes)),
        ?assertEqual(record_info(fields, client), mnesia:table_info(client, attributes)),
        ?assertEqual(record_info(fields, account), mnesia:table_info(account, attributes)),
        ?assertEqual(
            record_info(fields, remote_client), mnesia:table_info(remote_client, attributes)
        ),
        ?assertEqual(
            record_info(fields, remote_channel), mnesia:table_info(remote_channel, attributes)
        ),
        ?assertEqual(disc_copies, mnesia:table_info(activity, storage_type)),
        ?assertEqual(
            record_info(fields, service) ++ [extra], mnesia:table_info(service, attributes)
        ),
        [#channel{} = Channel] = mnesia:dirty_read(channel, Safe),
        ?assertEqual(<<"kept">>, Channel#channel.topic),
        ?assertEqual(undefined, Channel#channel.topic_at),
        [#account{} = Account] = mnesia:dirty_read(account, <<"acc">>),
        ?assertEqual(<<"Acc">>, Account#account.name),
        ?assertEqual(undefined, Account#account.pending),
        %% Imported peer state is cleared on startup after migration.
        ?assertEqual([], mnesia:dirty_all_keys(remote_client)),
        Port = listener_port(),
        Sock = register_client(Port, <<"mig">>),
        ?assert(has(cmd(Sock, <<"JOIN #fresh">>), <<"JOIN #fresh">>)),
        gen_tcp:close(Sock)
    after
        stop()
    end.

unregistered(Port) ->
    Sock = connect(Port),
    ?assert(has(cmd(Sock, <<"WHO">>), <<" 451 * :You have not registered">>)),
    ?assert(has(cmd(Sock, <<"LUSERS">>), <<" 451 ">>)),
    ?assert(has(cmd(Sock, <<"PING">>), <<" 409 * :No origin specified">>)),
    ?assertNot(has(cmd(Sock, <<"PONG :whatever">>), <<"whatever">>)),
    ?assert(has(cmd(Sock, <<"NICK">>), <<" 431 * :No nickname given">>)),
    ?assert(has(cmd(Sock, <<"NICK 1bad">>), <<" 432 * 1bad ">>)),
    ?assert(has(cmd(Sock, <<"NICK anonymous">>), <<" 432 * anonymous ">>)),
    ?assert(has(cmd(Sock, <<"USER u 0 * :">>), <<" 461 * USER ">>)),
    ?assert(has(cmd(Sock, <<"USER bad!user 0 * :Real">>), <<" 468 * ">>)),
    ?assert(has(cmd(Sock, <<"USER u 0 *">>), <<" 461 * USER ">>)),
    ?assert(has(cmd(Sock, <<"USER u -1 * :Real">>), <<" 461 * USER :Invalid user mode mask">>)),
    Other = register_client(Port, <<"taken">>),
    %% A nickname held by another client is refused before registration.
    ?assert(has(cmd(Sock, <<"NICK Taken">>), <<" 433 * Taken ">>)),
    Welcome = cmd(Sock, <<"NICK fresh\r\nUSER fresh 0 * :Fresh">>),
    ?assert(has(Welcome, <<" 001 fresh ">>)),
    ?assert(has(cmd(Sock, <<"USER again 0 * :Again">>), <<" 462 fresh ">>)),
    ?assert(has(cmd(Sock, <<"USER again">>), <<" 462 fresh ">>)),
    ?assert(has(cmd(Sock, <<"PASS secret">>), <<" 462 fresh ">>)),
    ?assert(has(cmd(Sock, <<"NICK taken">>), <<" 433 fresh taken ">>)),
    ?assertNot(has(cmd(Sock, <<"NICK fresh">>), <<"NICK">>)),
    ?assert(has(cmd(Sock, <<"NICK Fresh">>), <<"NICK :Fresh">>)),
    ?assert(has(cmd(Sock, <<"NICK fresh2">>), <<"NICK :fresh2">>)),
    ?assert(has(cmd(Sock, <<"WHOIS Fresh">>), <<" 401 fresh2 Fresh ">>)),
    send(Sock, <<"QUIT">>),
    ?assert(has(recv_until(Sock, <<"ERROR">>), <<"(Quit: Client quit)">>)),
    gen_tcp:close(Sock),
    gen_tcp:close(Other).

registered(Port) ->
    A = register_client(Port, <<"ann">>),
    B = register_client(Port, <<"ben">>),
    Pending = connect(Port),
    send(Pending, <<"NICK pend">>),
    ?assert(has(cmd(A, <<"FOO bar">>), <<" 421 ann FOO :Unknown command">>)),
    lists:foreach(
        fun(Command) ->
            ?assert(has(cmd(A, Command), <<" 461 ann ", Command/binary, " ">>))
        end,
        [<<"JOIN">>, <<"PART">>, <<"TOPIC">>, <<"MODE">>, <<"KICK">>, <<"KNOCK">>, <<"INVITE">>]
    ),
    ?assert(has(cmd(A, <<"KICK #x">>), <<" 461 ann KICK ">>)),
    _ = cmd(A, <<"JOIN #one,#two">>),
    _ = cmd(B, <<"JOIN #one,#two">>),
    ?assert(has(cmd(A, <<"KICK #one,#two ben">>), <<" 461 ann KICK :Invalid channel/user list">>)),
    Kicked = cmd(A, <<"KICK #one,#two ben,ben :out">>),
    ?assert(has(Kicked, <<"KICK #one ben :out">>)),
    ?assert(has(Kicked, <<"KICK #two ben :out">>)),
    _ = cmd(B, <<"JOIN #one">>),
    ?assert(has(cmd(A, <<"KICK #one ben">>), <<"KICK #one ben :ann">>)),
    ?assert(has(cmd(A, <<"INVITE ben #one">>), <<" 341 ann ben #one">>)),
    ?assert(has(cmd(A, <<"INVITE #one ben">>), <<" 341 ann ben #one">>)),
    %% INVITE <channel> <nick> for a channel that does not exist.
    Invited = cmd(A, <<"INVITE #nowhere ben">>),
    ?assert(has(Invited, <<"INVITE #nowhere ben">>)),
    ?assert(has(recv_until(B, <<"#nowhere">>), <<"INVITE #nowhere ben">>)),
    ?assert(has(cmd(A, <<"INVITE #nowhere nobody">>), <<" 401 ann nobody ">>)),
    ?assert(has(cmd(A, <<"INVITE #nowhere pend">>), <<" 401 ann pend ">>)),
    ?assert(has(cmd(A, <<"PART #nochan">>), <<" 403 ann #nochan ">>)),
    _ = cmd(B, <<"JOIN #bens">>),
    ?assert(has(cmd(A, <<"PART #bens">>), <<" 442 ann #bens ">>)),
    _ = cmd(B, <<"MODE #bens +s">>),
    List = cmd(A, <<"LIST">>),
    ?assert(has(List, <<" 322 ann #one ">>)),
    ?assertNot(has(List, <<"#bens">>)),
    ?assert(has(List, <<" 323 ann ">>)),
    Named = cmd(A, <<"LIST #one,#nochan">>),
    ?assert(has(Named, <<" 322 ann #one 1 ">>)),
    ?assertNot(has(Named, <<"#nochan">>)),
    ?assert(has(cmd(B, <<"LIST #bens">>), <<" 322 ben #bens 1">>)),
    _ = cmd(A, <<"JOIN #three">>),
    ?assert(has(cmd(A, <<"PART #three :done here">>), <<"PART #three :done here">>)),
    Parted = cmd(A, <<"JOIN 0">>),
    ?assert(has(Parted, <<"PART #one">>)),
    ?assert(has(Parted, <<"PART #two">>)),
    %% Unregistered clients cannot be reached by WALLOPS and are not ready.
    ?assert(has(cmd(A, <<"WHOIS pend">>), <<" 401 ann pend ">>)),
    ?assert(has(cmd(A, <<"USERHOST pend">>), <<" 302 ann :\r\n">>)),
    ?assert(has(cmd(A, <<"ISON pend">>), <<" 303 ann :\r\n">>)),
    ?assert(has(cmd(A, <<"WHO pend">>), <<" 315 ann pend ">>)),
    ?assertNot(has(cmd(A, <<"WHO pend">>), <<" 352 ">>)),
    %% Command counters feed STATS m.
    ?assert(has(cmd(A, <<"STATS m">>), <<" 212 ann WHO ">>)),
    gen_tcp:close(Pending),
    gen_tcp:close(A),
    gen_tcp:close(B).

state_api() ->
    %% format_status/1 redacts PASS and OPER secrets in the current message
    %% and in the system log.
    Status = ircd_state:format_status(#{
        message => {'$gen_call', from, {command, <<"OPER">>, [<<"o">>, <<"pw">>], 10, []}},
        log => [
            {in, {command, <<"PASS">>, [<<"pw">>], 5}},
            {in, {command, <<"OPER">>, [<<"o">>, <<"pw">>], 5}, extra},
            {in, {command, <<"PASS">>, [<<"pw">>], 5, []}, extra},
            other
        ],
        state => <<"irc.test">>
    }),
    ?assertEqual(
        {'$gen_call', from, {command, <<"OPER">>, [<<"o">>, redacted], 10, []}},
        maps:get(message, Status)
    ),
    ?assertEqual(
        [
            {in, {command, <<"PASS">>, [redacted], 5}},
            {in, {command, <<"OPER">>, [<<"o">>, redacted], 5}, extra},
            {in, {command, <<"PASS">>, [redacted], 5, []}, extra},
            other
        ],
        maps:get(log, Status)
    ),
    ?assertEqual(<<"irc.test">>, maps:get(state, Status)),
    ?assertEqual(#{log => nolog}, ircd_state:format_status(#{log => nolog})),
    Plain = {command, <<"PRIVMSG">>, [<<"#c">>, <<"hi">>], 12, []},
    ?assertEqual(#{message => Plain}, ircd_state:format_status(#{message => Plain})),
    ?assertEqual(
        #{message => {command, <<"PASS">>, [redacted], 8}},
        ircd_state:format_status(#{message => {command, <<"PASS">>, [<<"pw">>], 8}})
    ),
    ?assertEqual(
        #{message => {command, <<"OPER">>, [<<"o">>, redacted], 8}},
        ircd_state:format_status(#{message => {command, <<"OPER">>, [<<"o">>, <<"pw">>], 8}})
    ),
    %% A peer line for an unknown command from an unknown peer is ignored.
    ?assertEqual(ok, ircd_state:server_command(<<"ghost.test">>, undefined, <<"FROB">>, [])),
    %% Unknown casts and info messages are ignored; the server stays up.
    Before = whereis(ircd_state),
    gen_server:cast(ircd_state, unexpected),
    ircd_state ! unexpected,
    ircd_state ! {flush_netjoin, <<"nobody.test">>},
    ?assertEqual(Before, whereis(ircd_state)),
    %% A process that is not attached cannot act for another client.
    ?assertEqual(
        quit,
        gen_server:call(ircd_state, {command_as, self(), <<"PING">>, [<<"x">>], 6, []})
    ),
    %% A fake session registers through the old connect/1 call shape, reaches
    %% the dispatcher through command/3, and is cleaned up on DOWN.
    Parent = self(),
    Fake = spawn(fun() -> fake_session(Parent) end),
    receive
        {fake_ready, Fake, Registered} -> ?assertEqual(false, Registered)
    after 5000 -> error(fake_session_timeout)
    end,
    ?assertMatch([_], mnesia:dirty_read(client, Fake)),
    Fake ! {pong, self()},
    receive
        {fake_pong, Fake, Lines} ->
            ?assert(has(Lines, <<"PONG irc.test :tok">>)),
            ?assert(has(Lines, <<" 417 ">>))
    after 5000 -> error(fake_pong_timeout)
    end,
    %% An attached connection acts for its primary client (multiclient).
    true = ets:insert(ircd_attached, {self(), Fake}),
    try
        ?assertEqual(
            ok, ircd_state:command_as(Fake, <<"VERSION">>, [], 9, [])
        )
    after
        ets:delete(ircd_attached, self())
    end,
    Fake ! {drain, self()},
    receive
        {drained, Fake, Version} -> ?assert(has(Version, <<" 451 ">>))
    after 5000 -> error(fake_drain_timeout)
    end,
    Ref = monitor(process, Fake),
    Fake ! stop,
    receive
        {'DOWN', Ref, process, Fake, _} -> ok
    after 5000 -> error(fake_down_timeout)
    end,
    ?assert(eventually(fun() -> mnesia:dirty_read(client, Fake) =:= [] end)),
    %% An attachment whose primary client is gone is refused.
    true = ets:insert(ircd_attached, {self(), Fake}),
    try
        ?assertEqual(
            quit, gen_server:call(ircd_state, {command_as, Fake, <<"PING">>, [], 4, []})
        )
    after
        ets:delete(ircd_attached, self())
    end.

fake_session(Parent) ->
    ok = gen_server:call(ircd_state, {connect, <<"10.0.0.9">>}),
    ok = ircd_state:connect(<<"10.0.0.9">>),
    Registered = ircd_state:registered(),
    Parent ! {fake_ready, self(), Registered},
    receive
        {pong, From} ->
            _ = ircd_state:command(<<"PING">>, [<<"tok">>], 10),
            ok = ircd_state:input_too_long([]),
            From ! {fake_pong, self(), drain_irc(<<>>)}
    end,
    fake_loop().

fake_loop() ->
    receive
        {drain, From} ->
            From ! {drained, self(), drain_irc(<<>>)},
            fake_loop();
        stop ->
            ok
    end.

drain_irc(Acc) ->
    receive
        {irc, Line} -> drain_irc(<<Acc/binary, (iolist_to_binary(Line))/binary>>)
    after 200 -> Acc
    end.

%% ---------------------------------------------------------------------------
%% Helpers.

dir(Prefix) ->
    filename:join(
        "/tmp",
        binary_to_list(Prefix) ++ "-" ++ integer_to_list(erlang:system_time(nanosecond))
    ).

start(Dir, Extra) ->
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    ok = file:write_file(
        filename:join(Dir, "motd.txt"),
        <<"Welcome\r\n\n", (binary:copy(<<"x">>, 100))/binary, "\n">>
    ),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(Dir, Extra)),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    Config.

stop() ->
    _ = application:stop(ircd),
    os:unsetenv("IRCD_CONFIG").

config(Dir, Extra) ->
    iolist_to_binary([
        <<"{">>,
        <<"\"name\":\"irc.test\",">>,
        <<"\"bind\":\"127.0.0.1\",">>,
        <<"\"tls_port\":null,">>,
        <<"\"log_level\":\"warning\",">>,
        <<"\"log_format\":\"text\",">>,
        <<"\"resource_delay\":0,">>,
        <<"\"mnesia_dir\":\"">>,
        filename:join(Dir, "db"),
        <<"\",">>,
        Extra,
        <<"\"operators\":[{\"name\":\"oper\",\"password\":\"opersecret\"}],">>,
        <<"\"administrators\":[{\"nick\":\"admin\",\"password\":\"adminsecret\"}],">>,
        <<"\"channels\":[{\"name\":\"#Lobby\",\"topic\":\"lobby\"}],">>,
        <<"\"server_links\":[">>,
        <<"{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false}]">>,
        <<"}">>
    ]).

handshake(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    ?assert(has(recv_until(Sock, <<"SERVER irc.test">>), <<"SERVER irc.test">>)),
    _ = peer_lines(Sock, []),
    Sock.

%% Send peer lines, then a PING; the PONG proves every earlier line was applied.
peer_lines(Sock, Lines) ->
    lists:foreach(fun(Line) -> send(Sock, Line) end, Lines),
    Token = token(),
    send(Sock, <<"PING ", Token/binary>>),
    recv_until(Sock, Token).

register_client(Port, Nick) ->
    Sock = connect(Port),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :", Nick/binary>>),
    Welcome = cmd(Sock, <<"PING :welcome">>),
    ?assert(has(Welcome, <<" 001 ", Nick/binary, " ">>)),
    Sock.

connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    Sock.

send(Sock, Line) ->
    ok = gen_tcp:send(Sock, [Line, <<"\r\n">>]).

%% Send one command, then a PING with a fresh token, and return everything
%% the server wrote up to the matching PONG.
cmd(Sock, Line) ->
    send(Sock, Line),
    Token = token(),
    send(Sock, <<"PING ", Token/binary>>),
    recv_until(Sock, Token).

token() ->
    <<"mk", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

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

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

count(Bin, Needle) ->
    length(binary:matches(Bin, Needle)).
