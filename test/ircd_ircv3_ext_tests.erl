-module(ircd_ircv3_ext_tests).
-include_lib("eunit/include/eunit.hrl").

%% Live tests for the IRCv3 extensions beyond capability negotiation, tags,
%% and labeled responses: accounts and SASL, identity notifications, echo,
%% server-time, msgid, MONITOR, WHOX, multiline, chathistory, read markers,
%% redaction, metadata, rename, pre-away, UTF8ONLY, WEBIRC, WebSocket, STS,
%% netsplit/netjoin batches, and CAP NEW on REHASH.

-define(ALL_CAPS,
    <<"account-notify account-tag away-notify batch chghost echo-message extended-join ",
        "extended-monitor invite-notify labeled-response message-tags multi-prefix ",
        "server-time setname userhost-in-names draft/chathistory draft/read-marker ",
        "draft/message-redaction draft/metadata-2 draft/multiline draft/channel-rename ",
        "draft/oper-tag">>
).

ircv3_ext_test_() ->
    {timeout, 180, fun run/0}.

run() ->
    Dir = filename:join(
        "/tmp", "ircd-ircv3-ext-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(filename:join(Dir, "db"), false)),
    application:stop(ircd),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    Port = listener_port(tcp),
    try
        isupport_and_values(Port),
        accounts_and_sasl(Port),
        identity_notifications(Port),
        echo_time_msgid(Port),
        monitor(Port),
        whox(Port),
        multiline(Port),
        history_markers_redaction(Port),
        metadata(Port),
        rename(Port),
        pre_away_and_utf8(Port),
        webirc(Port),
        websocket(listener_port(ws)),
        audit_regressions(Port),
        netsplit(Port),
        cap_new_on_rehash(Port, Config, filename:join(Dir, "db"))
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

isupport_and_values(Port) ->
    Sock = connect(Port),
    send(Sock, <<"CAP LS 302">>),
    Ls = collect(Sock),
    ?assert(has(Ls, <<"sts=port=6697">>)),
    ?assert(has(Ls, <<"draft/metadata-2=before-connect">>)),
    ?assert(has(Ls, <<"draft/account-registration=before-connect">>)),
    send(Sock, <<"CAP REQ :batch draft/extended-isupport">>),
    ?assert(has(collect(Sock), <<" ACK ">>)),
    send(Sock, <<"ISUPPORT">>),
    Pre = collect(Sock),
    ?assert(has(Pre, <<"draft/isupport">>)),
    ?assert(has(Pre, <<" 005 ">>)),
    ?assert(has(Pre, <<"WHOX">>)),
    send(Sock, <<"NICK isup">>),
    send(Sock, <<"USER isup 0 * :I">>),
    send(Sock, <<"CAP END">>),
    Welcome = collect(Sock),
    ?assert(has(Welcome, <<" 001 ">>)),
    lists:foreach(
        fun(Token) -> ?assert(has(Welcome, Token)) end,
        [
            <<"MONITOR=3">>,
            <<"BOT=B">>,
            <<"CHATHISTORY=">>,
            <<"MSGREFTYPES=timestamp,msgid">>,
            <<"ACCOUNTEXTBAN=a">>,
            <<"EXTBAN=$,a">>,
            <<"UTF8ONLY">>,
            <<"draft/ICON=https://example.org/icon.svg">>,
            <<"NETWORK=TestNet">>,
            <<"CASEMAPPING=rfc1459">>
        ]
    ),
    Plain = connect(Port),
    send(Plain, <<"ISUPPORT">>),
    ?assert(has(collect(Plain), <<" 451 ">>)),
    gen_tcp:close(Plain),
    gen_tcp:close(Sock).

accounts_and_sasl(Port) ->
    Reg = connect(Port),
    send(Reg, <<"CAP LS 302">>),
    _ = collect(Reg),
    send(Reg, <<"CAP REQ :draft/account-registration sasl">>),
    _ = collect(Reg),
    send(Reg, <<"REGISTER * * secretpass">>),
    ?assert(has(collect(Reg), <<"FAIL REGISTER NEED_NICK">>)),
    send(Reg, <<"NICK acct">>),
    send(Reg, <<"REGISTER * * short">>),
    ?assert(has(collect(Reg), <<"FAIL REGISTER WEAK_PASSWORD acct">>)),
    send(Reg, <<"REGISTER * bad-email secretpass">>),
    ?assert(has(collect(Reg), <<"FAIL REGISTER INVALID_EMAIL">>)),
    send(Reg, <<"REGISTER * a@example.org secretpass">>),
    Done = collect(Reg),
    ?assert(has(Done, <<"REGISTER SUCCESS acct">>)),
    ?assert(has(Done, <<" 900 acct * acct :You are now logged in as acct">>)),
    send(Reg, <<"REGISTER other * secretpass">>),
    ?assert(has(collect(Reg), <<"FAIL REGISTER ALREADY_AUTHENTICATED acct">>)),
    send(Reg, <<"VERIFY acct 123">>),
    ?assert(has(collect(Reg), <<"FAIL VERIFY ALREADY_AUTHENTICATED acct">>)),
    gen_tcp:close(Reg),
    timer:sleep(100),
    Taken = connect(Port),
    send(Taken, <<"NICK taken">>),
    send(Taken, <<"REGISTER acct * secretpass">>),
    ?assert(has(collect(Taken), <<"FAIL REGISTER ACCOUNT_EXISTS acct">>)),
    gen_tcp:close(Taken),
    %% SASL PLAIN before registration completes.
    Plain = connect(Port),
    send(Plain, <<"CAP LS 302">>),
    _ = collect(Plain),
    send(Plain, <<"CAP REQ sasl">>),
    _ = collect(Plain),
    send(Plain, <<"NICK plain1">>),
    send(Plain, <<"USER plain1 0 * :P">>),
    send(Plain, <<"AUTHENTICATE PLAIN">>),
    ?assert(has(collect(Plain), <<"AUTHENTICATE +">>)),
    send(Plain, <<"AUTHENTICATE ", (base64:encode(<<0, "acct", 0, "wrongpass">>))/binary>>),
    ?assert(has(collect(Plain), <<" 904 ">>)),
    send(Plain, <<"AUTHENTICATE PLAIN">>),
    _ = collect(Plain),
    send(Plain, <<"AUTHENTICATE ", (base64:encode(<<0, "acct", 0, "secretpass">>))/binary>>),
    Ok = collect(Plain),
    ?assert(has(Ok, <<" 900 plain1 plain1!plain1@127.0.0.1 acct ">>)),
    ?assert(has(Ok, <<" 903 ">>)),
    ?assertNot(has(Ok, <<" 001 ">>)),
    send(Plain, <<"CAP END">>),
    ?assert(has(collect(Plain), <<" 001 ">>)),
    send(Plain, <<"AUTHENTICATE FOO">>),
    Unknown = collect(Plain),
    ?assert(has(Unknown, <<" 908 plain1 EXTERNAL,PLAIN,SCRAM-SHA-256 ">>)),
    ?assert(has(Unknown, <<" 904 ">>)),
    send(Plain, <<"AUTHENTICATE PLAIN">>),
    _ = collect(Plain),
    send(Plain, <<"AUTHENTICATE *">>),
    ?assert(has(collect(Plain), <<" 906 ">>)),
    send(Plain, <<"AUTHENTICATE EXTERNAL">>),
    _ = collect(Plain),
    send(Plain, <<"AUTHENTICATE +">>),
    ?assert(has(collect(Plain), <<" 904 ">>)),
    gen_tcp:close(Plain),
    %% SASL SCRAM-SHA-256 after registration (re-authentication).
    Scram = register_client(Port, <<"scram1">>),
    _ = collect(Scram),
    ok = scram_login(Scram, <<"acct">>, <<"secretpass">>),
    gen_tcp:close(Scram),
    BadScram = register_client(Port, <<"scram2">>),
    _ = collect(BadScram),
    ?assertEqual(failed, scram_login(BadScram, <<"acct">>, <<"wrongpass">>)),
    gen_tcp:close(BadScram).

scram_login(Sock, User, Password) ->
    send(Sock, <<"AUTHENTICATE SCRAM-SHA-256">>),
    ?assert(has(collect(Sock), <<"AUTHENTICATE +">>)),
    Nonce = base64:encode(crypto:strong_rand_bytes(12)),
    Bare = <<"n=", User/binary, ",r=", Nonce/binary>>,
    send(Sock, <<"AUTHENTICATE ", (base64:encode(<<"n,,", Bare/binary>>))/binary>>),
    ServerFirst = base64:decode(authenticate_payload(collect(Sock))),
    #{$r := Combined, $s := Salt64, $i := Iter} = scram_attrs(ServerFirst),
    ?assertEqual(Nonce, binary:part(Combined, 0, byte_size(Nonce))),
    Salted = crypto:pbkdf2_hmac(
        sha256, Password, base64:decode(Salt64), binary_to_integer(Iter), 32
    ),
    ClientKey = crypto:mac(hmac, sha256, Salted, <<"Client Key">>),
    Stored = crypto:hash(sha256, ClientKey),
    Without = <<"c=biws,r=", Combined/binary>>,
    Auth = <<Bare/binary, ",", ServerFirst/binary, ",", Without/binary>>,
    Proof = crypto:exor(ClientKey, crypto:mac(hmac, sha256, Stored, Auth)),
    Final = <<Without/binary, ",p=", (base64:encode(Proof))/binary>>,
    send(Sock, <<"AUTHENTICATE ", (base64:encode(Final))/binary>>),
    Reply = collect(Sock),
    case has(Reply, <<" 904 ">>) of
        true ->
            failed;
        false ->
            ServerKey = crypto:mac(hmac, sha256, Salted, <<"Server Key">>),
            Expected = <<"v=", (base64:encode(crypto:mac(hmac, sha256, ServerKey, Auth)))/binary>>,
            ?assertEqual(Expected, base64:decode(authenticate_payload(Reply))),
            send(Sock, <<"AUTHENTICATE +">>),
            Done = collect(Sock),
            ?assert(has(Done, <<" 900 ">>)),
            ?assert(has(Done, <<" 903 ">>)),
            ok
    end.

authenticate_payload(Bin) ->
    [Line | _] = [L || L <- lines(Bin), has(L, <<"AUTHENTICATE ">>)],
    [_, Payload] = binary:split(Line, <<"AUTHENTICATE ">>),
    Payload.

scram_attrs(Message) ->
    #{K => V || <<K, $=, V/binary>> <- binary:split(Message, <<",">>, [global])}.

identity_notifications(Port) ->
    Watcher = client(Port, <<"watch">>, ?ALL_CAPS),
    Legacy = register_client(Port, <<"legacy">>),
    _ = collect(Legacy),
    Logged = client(Port, <<"logged">>, <<"sasl">>),
    send(Watcher, <<"JOIN #ident">>),
    _ = collect(Watcher),
    send(Legacy, <<"JOIN #ident">>),
    _ = collect(Legacy),
    _ = collect(Watcher),
    %% account-notify on login; extended-join shows account and realname.
    send(Logged, <<"AUTHENTICATE PLAIN">>),
    _ = collect(Logged),
    send(Logged, <<"AUTHENTICATE ", (base64:encode(<<0, "acct", 0, "secretpass">>))/binary>>),
    _ = collect(Logged),
    send(Logged, <<"JOIN #ident">>),
    _ = collect(Logged),
    Joined = collect(Watcher),
    ?assert(has(Joined, <<"JOIN #ident acct :Real logged">>)),
    ?assert(has(collect(Legacy), <<"JOIN #ident\r\n">>)),
    %% account-tag on messages from a logged-in user.
    send(Logged, <<"PRIVMSG #ident :tagged">>),
    Tagged = collect(Watcher),
    ?assert(has(Tagged, <<"account=acct">>)),
    ?assert(has(Tagged, <<"PRIVMSG #ident :tagged">>)),
    ?assertNot(starts_with_tag(collect(Legacy))),
    %% WHOIS 330.
    send(Watcher, <<"WHOIS logged">>),
    ?assert(has(collect(Watcher), <<" 330 watch logged acct :is logged in as">>)),
    %% account-extban: `$a:<account>` bans by account name.
    send(Watcher, <<"JOIN #extban">>),
    _ = collect(Watcher),
    send(Watcher, <<"MODE #extban +b $a:ACCT">>),
    _ = collect(Watcher),
    send(Logged, <<"JOIN #extban">>),
    ?assert(has(collect(Logged), <<" 474 ">>)),
    send(Legacy, <<"JOIN #extban">>),
    ?assert(has(collect(Legacy), <<"JOIN #extban">>)),
    _ = collect(Watcher),
    %% away-notify, including AWAY on join.
    send(Logged, <<"AWAY :lunch">>),
    _ = collect(Logged),
    ?assert(has(collect(Watcher), <<"AWAY :lunch">>)),
    ?assertNot(has(collect_quiet(Legacy), <<"AWAY">>)),
    send(Logged, <<"PART #ident">>),
    send(Logged, <<"JOIN #ident">>),
    _ = collect(Logged),
    Rejoin = collect(Watcher),
    ?assert(has(Rejoin, <<"AWAY :lunch">>)),
    _ = collect(Legacy),
    send(Logged, <<"AWAY">>),
    _ = collect(Logged),
    ?assert(has(collect(Watcher), <<"AWAY\r\n">>)),
    %% setname.
    send(Logged, <<"SETNAME :New Name">>),
    _ = collect(Logged),
    ?assert(has(collect(Watcher), <<"SETNAME :New Name">>)),
    ?assertNot(has(collect_quiet(Legacy), <<"SETNAME">>)),
    send(Logged, <<"SETNAME :", (binary:copy(<<"x">>, 201))/binary>>),
    ?assert(has(collect(Logged), <<"FAIL SETNAME INVALID_REALNAME">>)),
    %% bot mode: user mode B, WHOIS 335, WHO flag, and the bot tag.
    send(Logged, <<"MODE logged +B">>),
    _ = collect(Logged),
    send(Watcher, <<"WHOIS logged">>),
    ?assert(has(collect(Watcher), <<" 335 watch logged ">>)),
    send(Watcher, <<"WHO #ident">>),
    WhoBot = collect(Watcher),
    ?assertMatch(
        {match, _}, re:run(WhoBot, <<" 352 watch #ident [^ ]+ [^ ]+ [^ ]+ logged H[*]?B">>)
    ),
    send(Logged, <<"PRIVMSG #ident :beep">>),
    ?assert(has(collect(Watcher), <<"bot">>)),
    _ = collect(Legacy),
    %% chghost: operator command; capable clients see CHGHOST, others QUIT+JOIN.
    send(Watcher, <<"OPER oper opersecret">>),
    _ = collect(Watcher),
    send(Watcher, <<"CHGHOST logged newuser new.host">>),
    ?assert(has(collect(Watcher), <<"CHGHOST newuser new.host">>)),
    LegacyView = collect(Legacy),
    ?assert(has(LegacyView, <<"QUIT :Changing hostname">>)),
    ?assert(has(LegacyView, <<":logged!newuser@new.host JOIN #ident">>)),
    %% oper-tag on an operator's message.
    send(Watcher, <<"PRIVMSG #ident :from oper">>),
    _ = collect(Watcher),
    _ = collect(Legacy),
    Viewer = client(Port, <<"viewer">>, <<"draft/oper-tag message-tags">>),
    send(Viewer, <<"JOIN #ident">>),
    _ = collect(Viewer),
    _ = collect(Watcher),
    _ = collect(Legacy),
    _ = collect(Logged),
    send(Watcher, <<"PRIVMSG #ident :oper says">>),
    ?assert(has(collect(Viewer), <<"draft/oper=watch">>)),
    _ = collect(Legacy),
    _ = collect(Logged),
    %% multi-prefix and userhost-in-names.
    send(Viewer, <<"NAMES #ident">>),
    Names = collect(Viewer),
    ?assert(has(Names, <<" 353 ">>)),
    send(Watcher, <<"MODE #ident +v watch">>),
    _ = collect(Watcher),
    _ = collect(Viewer),
    _ = collect(Legacy),
    _ = collect(Logged),
    send(Watcher, <<"NAMES #ident">>),
    Multi = collect(Watcher),
    ?assert(has(Multi, <<"@+watch!">>)),
    %% invite-notify on an invite-only channel reaches operators only.
    send(Watcher, <<"MODE #ident +i">>),
    _ = collect(Watcher),
    _ = collect(Viewer),
    _ = collect(Legacy),
    _ = collect(Logged),
    Outsider = register_client(Port, <<"outside">>),
    _ = collect(Outsider),
    send(Watcher, <<"MODE #ident +o logged">>),
    _ = collect(Watcher),
    _ = collect(Viewer),
    _ = collect(Legacy),
    _ = collect(Logged),
    send(Logged, <<"INVITE outside #ident">>),
    _ = collect(Logged),
    ?assert(has(collect(Outsider), <<"INVITE outside #ident">>)),
    ?assert(has(collect(Watcher), <<"INVITE outside #ident">>)),
    ?assertNot(has(collect_quiet(Viewer), <<"INVITE">>)),
    lists:foreach(fun gen_tcp:close/1, [Watcher, Legacy, Logged, Viewer, Outsider]).

echo_time_msgid(Port) ->
    Sender = client(
        Port, <<"echoer">>, <<"echo-message server-time message-tags batch labeled-response">>
    ),
    Other = client(Port, <<"echoed">>, <<"server-time">>),
    Implicit = client(Port, <<"implicit">>, <<"no-implicit-names">>),
    send(Implicit, <<"JOIN #echo">>),
    ImplicitJoin = collect(Implicit),
    ?assert(has(ImplicitJoin, <<"JOIN #echo">>)),
    ?assertNot(has(ImplicitJoin, <<" 353 ">>)),
    send(Sender, <<"JOIN #echo">>),
    _ = collect(Sender),
    send(Other, <<"JOIN #echo">>),
    _ = collect(Other),
    _ = collect(Sender),
    _ = collect(Implicit),
    send(Sender, <<"@label=e1 PRIVMSG #echo :hello">>),
    Echo = collect(Sender),
    ?assert(has(Echo, <<"label=e1">>)),
    ?assert(has(Echo, <<"msgid=">>)),
    ?assert(has(Echo, <<"time=">>)),
    ?assert(has(Echo, <<"PRIVMSG #echo :hello">>)),
    Seen = collect(Other),
    ?assert(has(Seen, <<"@time=">>)),
    ?assertNot(has(Seen, <<"msgid=">>)),
    ?assertMatch(
        {match, _}, re:run(Seen, <<"time=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\\.[0-9]{3}Z">>)
    ),
    send(Sender, <<"PRIVMSG echoed :direct">>),
    ?assert(has(collect(Sender), <<"PRIVMSG echoed :direct">>)),
    ?assert(has(collect(Other), <<"PRIVMSG echoed :direct">>)),
    _ = collect(Implicit),
    lists:foreach(fun gen_tcp:close/1, [Sender, Other, Implicit]).

monitor(Port) ->
    Mon = client(Port, <<"mon">>, <<"extended-monitor away-notify">>),
    send(Mon, <<"MONITOR + target1,target2">>),
    Offline = collect(Mon),
    ?assert(has(Offline, <<" 731 mon :target1,target2">>)),
    T1 = register_client(Port, <<"target1">>),
    _ = collect(T1),
    ?assert(has(collect(Mon), <<" 730 mon :target1!target1@127.0.0.1">>)),
    send(T1, <<"AWAY :gone">>),
    _ = collect(T1),
    ?assert(has(collect(Mon), <<"target1!target1@127.0.0.1 AWAY :gone">>)),
    send(Mon, <<"MONITOR L">>),
    List = collect(Mon),
    ?assert(has(List, <<" 732 mon :target1,target2">>)),
    ?assert(has(List, <<" 733 ">>)),
    send(Mon, <<"MONITOR S">>),
    Status = collect(Mon),
    ?assert(has(Status, <<" 730 ">>)),
    ?assert(has(Status, <<" 731 mon :target2">>)),
    send(T1, <<"NICK target3">>),
    _ = collect(T1),
    ?assert(has(collect(Mon), <<" 731 mon :target1">>)),
    send(Mon, <<"MONITOR + target4,target5">>),
    ?assert(has(collect(Mon), <<" 734 mon 3 target5 :Monitor list is full.">>)),
    send(Mon, <<"MONITOR - target2">>),
    send(Mon, <<"MONITOR L">>),
    ?assertNot(has(collect(Mon), <<"target2">>)),
    send(Mon, <<"MONITOR C">>),
    send(Mon, <<"MONITOR L">>),
    Cleared = collect(Mon),
    ?assertNot(has(Cleared, <<" 732 ">>)),
    ?assert(has(Cleared, <<" 733 ">>)),
    gen_tcp:close(T1),
    gen_tcp:close(Mon).

whox(Port) ->
    A = client(Port, <<"whoxa">>, <<>>),
    B = client(Port, <<"whoxb">>, <<>>),
    send(A, <<"JOIN #whox">>),
    _ = collect(A),
    send(B, <<"JOIN #whox">>),
    _ = collect(B),
    _ = collect(A),
    send(A, <<"WHO #whox %tcnfa,42">>),
    Reply = collect(A),
    ?assert(has(Reply, <<" 354 whoxa 42 #whox whoxb H 0">>)),
    ?assert(has(Reply, <<" 354 whoxa 42 #whox whoxa H@ 0">>)),
    ?assertNot(has(Reply, <<" 352 ">>)),
    ?assert(has(Reply, <<" 315 ">>)),
    send(A, <<"WHO whoxb %nuhr">>),
    ?assert(has(collect(A), <<" 354 whoxa whoxb 127.0.0.1 whoxb :Real whoxb">>)),
    send(A, <<"WHO whoxb %ni">>),
    ?assert(has(collect(A), <<" 354 whoxa 255.255.255.255 whoxb">>)),
    gen_tcp:close(A),
    gen_tcp:close(B).

multiline(Port) ->
    Caps = <<"batch draft/multiline message-tags echo-message">>,
    Sender = client(Port, <<"mlsend">>, Caps),
    Capable = client(Port, <<"mlcap">>, <<"batch draft/multiline message-tags">>),
    Plain = register_client(Port, <<"mlplain">>),
    _ = collect(Plain),
    lists:foreach(
        fun(S) ->
            send(S, <<"JOIN #ml">>),
            _ = collect(S)
        end,
        [Sender, Capable, Plain]
    ),
    _ = collect(Sender),
    _ = collect(Capable),
    send(Sender, <<"BATCH +b1 draft/multiline #ml">>),
    send(Sender, <<"@batch=b1 PRIVMSG #ml :line one">>),
    send(Sender, <<"@batch=b1;draft/multiline-concat PRIVMSG #ml :+cont">>),
    send(Sender, <<"@batch=b1 PRIVMSG #ml :line two">>),
    send(Sender, <<"BATCH -b1">>),
    Batched = collect(Capable),
    ?assert(has(Batched, <<"BATCH +">>)),
    ?assert(has(Batched, <<"draft/multiline #ml">>)),
    ?assert(has(Batched, <<"draft/multiline-concat">>)),
    ?assert(has(Batched, <<"PRIVMSG #ml :line two">>)),
    ?assert(has(Batched, <<"BATCH -">>)),
    Fallback = collect(Plain),
    ?assertEqual(3, count_lines(Fallback, <<"PRIVMSG #ml">>)),
    ?assertNot(has(Fallback, <<"BATCH">>)),
    ?assert(has(collect(Sender), <<"draft/multiline #ml">>)),
    send(Sender, <<"BATCH +b2 draft/multiline #ml">>),
    send(Sender, <<"@batch=b2 PRIVMSG #other :wrong">>),
    ?assert(has(collect(Sender), <<"FAIL BATCH MULTILINE_INVALID_TARGET #ml #other">>)),
    send(Sender, <<"BATCH +b3 nope #ml">>),
    ?assert(has(collect(Sender), <<"FAIL BATCH UNKNOWN_TYPE b3 nope">>)),
    send(Sender, <<"BATCH +b4 draft/multiline #ml">>),
    lists:foreach(
        fun(N) -> send(Sender, <<"@batch=b4 PRIVMSG #ml :", (integer_to_binary(N))/binary>>) end,
        lists:seq(1, 101)
    ),
    ?assert(has(collect(Sender), <<"FAIL BATCH MULTILINE_MAX_LINES 100">>)),
    lists:foreach(fun gen_tcp:close/1, [Sender, Capable, Plain]).

history_markers_redaction(Port) ->
    Caps =
        <<"batch server-time message-tags echo-message draft/chathistory ",
            "draft/read-marker draft/message-redaction">>,
    A = client(Port, <<"hista">>, Caps),
    B = client(Port, <<"histb">>, Caps),
    send(A, <<"JOIN #hist">>),
    _ = collect(A),
    send(B, <<"JOIN #hist">>),
    Join = collect(B),
    ?assert(has(Join, <<"MARKREAD #hist *">>)),
    _ = collect(A),
    lists:foreach(
        fun(N) -> send(A, <<"PRIVMSG #hist :msg", (integer_to_binary(N))/binary>>) end,
        lists:seq(1, 5)
    ),
    Echoes = collect(A),
    _ = collect(B),
    {match, [Third]} = re:run(Echoes, <<"msgid=([^; ]+)[^\\r]*PRIVMSG #hist :msg3">>, [
        {capture, all_but_first, binary}
    ]),
    send(B, <<"CHATHISTORY LATEST #hist * 2">>),
    Latest = collect(B),
    ?assert(has(Latest, <<"BATCH +">>)),
    ?assert(has(Latest, <<"chathistory #hist">>)),
    ?assert(has(Latest, <<"PRIVMSG #hist :msg4">>)),
    ?assert(has(Latest, <<"PRIVMSG #hist :msg5">>)),
    ?assertNot(has(Latest, <<"msg3">>)),
    send(B, <<"CHATHISTORY BEFORE #hist msgid=", Third/binary, " 10">>),
    Before = collect(B),
    ?assert(has(Before, <<":msg1">>)),
    ?assert(has(Before, <<":msg2">>)),
    ?assertNot(has(Before, <<":msg3">>)),
    send(B, <<"CHATHISTORY AFTER #hist msgid=", Third/binary, " 1">>),
    After = collect(B),
    ?assert(has(After, <<":msg4">>)),
    ?assertNot(has(After, <<":msg5">>)),
    send(
        B,
        <<"CHATHISTORY TARGETS timestamp=2000-01-01T00:00:00.000Z timestamp=2100-01-01T00:00:00.000Z 10">>
    ),
    Targets = collect(B),
    ?assert(has(Targets, <<"draft/chathistory-targets">>)),
    ?assert(has(Targets, <<"CHATHISTORY TARGETS #hist ">>)),
    send(B, <<"CHATHISTORY LATEST #nowhere * 5">>),
    ?assert(has(collect(B), <<"FAIL CHATHISTORY INVALID_TARGET LATEST #nowhere">>)),
    send(B, <<"CHATHISTORY NOPE">>),
    ?assert(has(collect(B), <<"FAIL CHATHISTORY INVALID_PARAMS">>)),
    %% Read markers only move forward.
    send(B, <<"MARKREAD #hist timestamp=2030-01-01T00:00:00.000Z">>),
    ?assert(has(collect(B), <<"MARKREAD #hist timestamp=2030-01-01T00:00:00.000Z">>)),
    send(B, <<"MARKREAD #hist timestamp=2020-01-01T00:00:00.000Z">>),
    ?assert(has(collect(B), <<"MARKREAD #hist timestamp=2030-01-01T00:00:00.000Z">>)),
    send(B, <<"MARKREAD #hist">>),
    ?assert(has(collect(B), <<"MARKREAD #hist timestamp=2030-01-01T00:00:00.000Z">>)),
    send(B, <<"MARKREAD">>),
    ?assert(has(collect(B), <<"FAIL MARKREAD NEED_MORE_PARAMS">>)),
    %% Redaction: B may not redact A's message, A may.
    send(B, <<"REDACT #hist ", Third/binary>>),
    ?assert(has(collect(B), <<"FAIL REDACT REDACT_FORBIDDEN #hist">>)),
    send(A, <<"REDACT #hist ", Third/binary, " :oops">>),
    _ = collect(A),
    ?assert(has(collect(B), <<"REDACT #hist ", Third/binary, " :oops">>)),
    send(B, <<"CHATHISTORY LATEST #hist * 10">>),
    ?assertNot(has(collect(B), <<":msg3">>)),
    send(A, <<"REDACT #hist ", Third/binary>>),
    ?assert(has(collect(A), <<"FAIL REDACT UNKNOWN_MSGID">>)),
    {match, [Second]} = re:run(Echoes, <<"msgid=([^; ]+)[^\\r]*PRIVMSG #hist :msg2">>, [
        {capture, all_but_first, binary}
    ]),
    send(B, <<"CHATHISTORY AROUND #hist msgid=", Second/binary, " 2">>),
    Around = collect(B),
    %% AROUND includes the reference: (limit - 1) div 2 before it, then it
    %% and the following messages (msg3 was redacted above).
    ?assertNot(has(Around, <<":msg1">>)),
    ?assert(has(Around, <<":msg2">>)),
    ?assert(has(Around, <<":msg4">>)),
    send(
        B,
        <<"CHATHISTORY BETWEEN #hist timestamp=2000-01-01T00:00:00.000Z ",
            "timestamp=2100-01-01T00:00:00.000Z 2">>
    ),
    Between = collect(B),
    ?assert(has(Between, <<":msg1">>)),
    ?assert(has(Between, <<":msg2">>)),
    ?assertNot(has(Between, <<":msg5">>)),
    %% Direct-message history between two logged-in accounts.
    send(A, <<"REGISTER * * historypass">>),
    ?assert(has(collect(A), <<"REGISTER SUCCESS hista">>)),
    send(B, <<"REGISTER * * historypass">>),
    ?assert(has(collect(B), <<"REGISTER SUCCESS histb">>)),
    send(A, <<"PRIVMSG histb :private hello">>),
    _ = collect(A),
    _ = collect(B),
    send(B, <<"CHATHISTORY LATEST hista * 5">>),
    Direct = collect(B),
    ?assert(has(Direct, <<"chathistory hista">>)),
    ?assert(has(Direct, <<"PRIVMSG histb :private hello">>)),
    gen_tcp:close(A),
    gen_tcp:close(B).

metadata(Port) ->
    Caps = <<"batch draft/metadata-2">>,
    A = client(Port, <<"metaa">>, Caps),
    B = client(Port, <<"metab">>, Caps),
    send(B, <<"METADATA * SUB avatar">>),
    ?assert(has(collect(B), <<" 770 metab avatar">>)),
    send(A, <<"JOIN #meta">>),
    _ = collect(A),
    send(B, <<"JOIN #meta">>),
    _ = collect(B),
    _ = collect(A),
    send(A, <<"METADATA * SET avatar :https://example.org/a.png">>),
    ?assert(has(collect(A), <<" 761 metaa metaa avatar * :https://example.org/a.png">>)),
    ?assert(has(collect(B), <<"METADATA metaa avatar * :https://example.org/a.png">>)),
    send(B, <<"METADATA metaa GET avatar missing">>),
    Get = collect(B),
    ?assert(has(Get, <<"BATCH +">>)),
    ?assert(has(Get, <<" 761 metab metaa avatar * ">>)),
    ?assert(has(Get, <<" 766 metab metaa missing ">>)),
    send(B, <<"METADATA metaa SET avatar :x">>),
    ?assert(has(collect(B), <<"FAIL METADATA KEY_NO_PERMISSION metaa avatar">>)),
    send(A, <<"METADATA * SET Bad!Key :x">>),
    ?assert(has(collect(A), <<"FAIL METADATA KEY_INVALID">>)),
    send(A, <<"METADATA #meta SET topic-color :blue">>),
    ?assert(has(collect(A), <<" 761 metaa #meta topic-color * :blue">>)),
    send(B, <<"METADATA #meta LIST">>),
    ?assert(has(collect(B), <<"topic-color * :blue">>)),
    send(A, <<"METADATA * SUBS">>),
    ?assert(has(collect(A), <<"metadata-subs">>)),
    send(A, <<"METADATA * CLEAR">>),
    ?assert(has(collect(A), <<" 766 metaa metaa avatar ">>)),
    ?assert(has(collect(B), <<"METADATA metaa avatar *\r\n">>)),
    send(A, <<"METADATA nobody GET x">>),
    ?assert(has(collect(A), <<"FAIL METADATA INVALID_TARGET nobody">>)),
    gen_tcp:close(A),
    gen_tcp:close(B).

rename(Port) ->
    Op = client(Port, <<"renop">>, <<"draft/channel-rename">>),
    Legacy = register_client(Port, <<"renleg">>),
    _ = collect(Legacy),
    send(Op, <<"JOIN #oldname">>),
    _ = collect(Op),
    send(Legacy, <<"JOIN #oldname">>),
    _ = collect(Legacy),
    _ = collect(Op),
    send(Legacy, <<"RENAME #oldname #newname">>),
    ?assert(has(collect(Legacy), <<" 482 ">>)),
    send(Op, <<"RENAME #oldname &local">>),
    ?assert(has(collect(Op), <<"FAIL RENAME CANNOT_RENAME #oldname &local">>)),
    send(Op, <<"RENAME #oldname #newname :moving">>),
    ?assert(has(collect(Op), <<"RENAME #oldname #newname :moving">>)),
    Fallback = collect(Legacy),
    ?assert(has(Fallback, <<"PART #oldname :moving">>)),
    ?assert(has(Fallback, <<"JOIN #newname">>)),
    ?assert(has(Fallback, <<" 366 renleg #newname ">>)),
    send(Legacy, <<"PRIVMSG #newname :still here">>),
    ?assert(has(collect(Op), <<"PRIVMSG #newname :still here">>)),
    send(Op, <<"JOIN #taken">>),
    _ = collect(Op),
    send(Op, <<"RENAME #newname #taken">>),
    ?assert(has(collect(Op), <<"FAIL RENAME CHANNEL_NAME_IN_USE">>)),
    gen_tcp:close(Op),
    gen_tcp:close(Legacy).

pre_away_and_utf8(Port) ->
    Sock = connect(Port),
    send(Sock, <<"CAP LS 302">>),
    _ = collect(Sock),
    send(Sock, <<"CAP REQ draft/pre-away">>),
    _ = collect(Sock),
    send(Sock, <<"AWAY *">>),
    ?assert(has(collect(Sock), <<" 306 ">>)),
    send(Sock, <<"NICK preaway">>),
    send(Sock, <<"USER preaway 0 * :P">>),
    send(Sock, <<"CAP END">>),
    _ = collect(Sock),
    Asker = client(Port, <<"asker">>, <<>>),
    send(Asker, <<"WHOIS preaway">>),
    ?assert(has(collect(Asker), <<" 301 asker preaway :Away">>)),
    No = connect(Port),
    send(No, <<"AWAY :x">>),
    ?assert(has(collect(No), <<" 451 ">>)),
    gen_tcp:close(No),
    send(Asker, <<"PRIVMSG preaway :", 16#ff, 16#fe>>),
    ?assert(has(collect(Asker), <<"FAIL PRIVMSG INVALID_UTF8">>)),
    send(Asker, <<"JOIN #utf">>),
    _ = collect(Asker),
    send(Asker, <<"TOPIC #utf :", 16#c3>>),
    ?assert(has(collect(Asker), <<"FAIL TOPIC INVALID_UTF8">>)),
    send(Asker, <<"TOPIC #utf :caf", 16#c3, 16#a9>>),
    ?assert(has(collect(Asker), <<"TOPIC #utf :caf", 16#c3, 16#a9>>)),
    ?assertNot(has(collect_quiet(Sock), <<"PRIVMSG">>)),
    gen_tcp:close(Sock),
    gen_tcp:close(Asker).

webirc(Port) ->
    Bad = connect(Port),
    send(Bad, <<"WEBIRC wrong gateway client.example 192.0.2.10">>),
    ?assert(has(collect(Bad), <<"ERROR :Invalid WebIRC password">>)),
    gen_tcp:close(Bad),
    Good = connect(Port),
    send(Good, <<"WEBIRC gatepass gateway client.example 192.0.2.10 :secure">>),
    send(Good, <<"NICK webuser">>),
    send(Good, <<"USER webuser 0 * :W">>),
    ?assert(has(collect(Good), <<" 001 ">>)),
    send(Good, <<"WHOIS webuser">>),
    ?assert(has(collect(Good), <<" 311 webuser webuser webuser client.example ">>)),
    send(Good, <<"WHO webuser %i">>),
    ?assert(has(collect(Good), <<" 354 webuser 192.0.2.10">>)),
    send(Good, <<"WEBIRC gatepass gateway other.example 192.0.2.11">>),
    ?assert(has(collect(Good), <<"ERROR">>)),
    gen_tcp:close(Good).

websocket(WsPort) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", WsPort, [binary, {active, false}, {packet, raw}]),
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    ok = gen_tcp:send(Sock, [
        <<"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n">>,
        <<"Sec-WebSocket-Protocol: binary.ircv3.net, text.ircv3.net\r\n">>,
        <<"Sec-WebSocket-Key: ", Key/binary, "\r\n\r\n">>
    ]),
    Response = collect(Sock),
    ?assert(has(Response, <<"101 Switching Protocols">>)),
    ?assert(has(Response, <<"Sec-WebSocket-Protocol: binary.ircv3.net">>)),
    Accept = base64:encode(
        crypto:hash(sha, <<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)
    ),
    ?assert(has(Response, Accept)),
    ws_send(Sock, <<"NICK wsuser">>),
    ws_send(Sock, <<"USER wsuser 0 * :Web">>),
    Frames = ws_collect(Sock),
    ?assert(lists:any(fun(F) -> has(F, <<" 001 wsuser ">>) end, Frames)),
    ?assert(lists:all(fun(F) -> not has(F, <<"\r\n">>) end, Frames)),
    ws_send(Sock, <<"PING ws">>),
    ?assert(lists:any(fun(F) -> has(F, <<"PONG">>) end, ws_collect(Sock))),
    ok = gen_tcp:send(Sock, ws_frame(9, <<"hi">>)),
    {ok, <<1:1, 0:3, 10:4, 0:1, 2:7, "hi">>} = gen_tcp:recv(Sock, 4, 1000),
    ok = gen_tcp:send(Sock, ws_frame(8, <<1000:16>>)),
    {ok, <<1:1, 0:3, 8:4, _/binary>>} = gen_tcp:recv(Sock, 0, 1000),
    gen_tcp:close(Sock),
    {ok, Bad} = gen_tcp:connect("127.0.0.1", WsPort, [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Bad, <<"GET / HTTP/1.1\r\nHost: x\r\n\r\n">>),
    ?assert(has(collect(Bad), <<"400 Bad Request">>)),
    gen_tcp:close(Bad).

ws_send(Sock, Line) ->
    ok = gen_tcp:send(Sock, ws_frame(2, Line)).

ws_frame(Opcode, Payload) ->
    Mask = crypto:strong_rand_bytes(4),
    Len = byte_size(Payload),
    <<1:1, 0:3, Opcode:4, 1:1, Len:7, Mask/binary, (mask(Payload, Mask))/binary>>.

mask(Payload, Mask) ->
    list_to_binary([
        B bxor binary:at(Mask, I rem 4)
     || {B, I} <- lists:zip(binary_to_list(Payload), lists:seq(0, byte_size(Payload) - 1))
    ]).

ws_collect(Sock) ->
    Data = collect(Sock),
    ws_parse(Data, []).

ws_parse(<<_:4, _:4, 0:1, 126:7, Len:16, Payload:Len/binary, Rest/binary>>, Acc) ->
    ws_parse(Rest, [Payload | Acc]);
ws_parse(<<_:4, _:4, 0:1, Len:7, Payload:Len/binary, Rest/binary>>, Acc) when Len < 126 ->
    ws_parse(Rest, [Payload | Acc]);
ws_parse(_, Acc) ->
    lists:reverse(Acc).

audit_regressions(Port) ->
    %% Registration does not complete before CAP END.
    Held = connect(Port),
    send(Held, <<"CAP LS 302">>),
    _ = collect(Held),
    send(Held, <<"NICK heldnick">>),
    send(Held, <<"USER heldnick 0 * :H">>),
    send(Held, <<"JOIN #held">>),
    ?assert(has(collect(Held), <<" 451 ">>)),
    Asker = client(Port, <<"auditask">>, <<>>),
    send(Asker, <<"WHOIS heldnick">>),
    ?assert(has(collect(Asker), <<" 401 ">>)),
    %% The ACK for server-time is not itself time-tagged.
    send(
        Held,
        <<"CAP REQ :server-time message-tags batch labeled-response echo-message draft/multiline">>
    ),
    Ack = collect(Held),
    ?assert(has(Ack, <<" ACK ">>)),
    ?assertNot(has(Ack, <<"time=">>)),
    send(Held, <<"CAP END">>),
    ?assert(has(collect(Held), <<" 001 ">>)),
    send(Asker, <<"WHOIS heldnick">>),
    ?assert(has(collect(Asker), <<" 311 ">>)),
    %% Server tags come before client-only tags.
    send(Held, <<"@+x=1 PRIVMSG auditask :ordered">>),
    Ordered = collect(Held),
    ?assertMatch({match, _}, re:run(Ordered, <<"^@(msgid|time)=[^ ]*\\+x=1">>, [multiline])),
    %% A labeled multiline echo carries the label on its opening BATCH.
    send(Held, <<"@label=ml BATCH +m1 draft/multiline auditask">>),
    send(Held, <<"@batch=m1 PRIVMSG AUDITASK :one">>),
    send(Held, <<"@batch=m1 PRIVMSG auditask :two">>),
    send(Held, <<"BATCH -m1">>),
    Labeled = collect(Held),
    ?assertMatch({match, _}, re:run(Labeled, <<"label=ml[^\\r]* BATCH \\+[^ ]+ draft/multiline">>)),
    ?assertNot(has(Labeled, <<"labeled-response">>)),
    _ = collect(Asker),
    %% Unknown chathistory reference type.
    send(Asker, <<"JOIN #auditch">>),
    _ = collect(Asker),
    send(Asker, <<"CHATHISTORY LATEST #auditch foo=bar 5">>),
    ?assert(has(collect(Asker), <<"FAIL CHATHISTORY INVALID_MSGREFTYPE LATEST #auditch">>)),
    %% An empty AWAY clears away status.
    send(Asker, <<"AWAY :gone">>),
    _ = collect(Asker),
    send(Asker, <<"AWAY :">>),
    ?assert(has(collect(Asker), <<" 305 ">>)),
    %% RENAME fallback honours no-implicit-names.
    Quiet = client(Port, <<"quietren">>, <<"no-implicit-names">>),
    send(Quiet, <<"JOIN #auditch">>),
    _ = collect(Quiet),
    _ = collect(Asker),
    send(Asker, <<"RENAME #auditch #auditnew">>),
    _ = collect(Asker),
    Renamed = collect(Quiet),
    ?assert(has(Renamed, <<"JOIN #auditnew">>)),
    ?assertNot(has(Renamed, <<" 353 ">>)),
    %% Second audit pass.
    %% labeled-response needs only batch, not message-tags.
    LabelOnly = client(Port, <<"lblonly">>, <<"batch labeled-response">>),
    send(LabelOnly, <<"@label=w1 WHOIS lblonly">>),
    LabelReply = collect(LabelOnly),
    ?assert(has(LabelReply, <<"label=w1">>)),
    ?assert(has(LabelReply, <<"labeled-response">>)),
    %% CAP without a subcommand.
    send(LabelOnly, <<"CAP">>),
    ?assert(has(collect(LabelOnly), <<" 461 lblonly CAP ">>)),
    %% An over-long tagged line without CR LF gets 417 and the session lives.
    ok = gen_tcp:send(LabelOnly, <<"@a=", (binary:copy(<<"x">>, 9000))/binary>>),
    ok = gen_tcp:send(LabelOnly, <<"yyy\r\nPING alive\r\n">>),
    Survived = collect(LabelOnly),
    ?assert(has(Survived, <<" 417 ">>)),
    ?assert(has(Survived, <<"PONG">>)),
    %% A labeled CHATHISTORY: the labeled BATCH comes before the history lines.
    Hist = client(Port, <<"lblhist">>, <<"batch labeled-response message-tags draft/chathistory">>),
    send(Hist, <<"JOIN #lblhist">>),
    send(Hist, <<"PRIVMSG #lblhist :first">>),
    _ = collect(Hist),
    send(Hist, <<"@label=h1 CHATHISTORY LATEST #lblhist * 5">>),
    HistReply = collect(Hist),
    [FirstLine | _] = binary:split(HistReply, <<"\r\n">>),
    ?assert(has(FirstLine, <<"label=h1">>)),
    ?assert(has(FirstLine, <<"BATCH +">>)),
    ?assert(has(HistReply, <<"PRIVMSG #lblhist :first">>)),
    %% Registration metadata burst uses METADATA, not 761.
    Meta = connect(Port),
    send(Meta, <<"CAP LS 302">>),
    _ = collect(Meta),
    send(Meta, <<"CAP REQ :batch draft/metadata-2">>),
    _ = collect(Meta),
    send(Meta, <<"METADATA * SET color :green">>),
    _ = collect(Meta),
    send(Meta, <<"NICK metareg">>),
    send(Meta, <<"USER metareg 0 * :M">>),
    send(Meta, <<"CAP END">>),
    MetaWelcome = collect(Meta),
    ?assert(has(MetaWelcome, <<"METADATA metareg color * :green">>)),
    lists:foreach(fun gen_tcp:close/1, [Held, Asker, Quiet, LabelOnly, Hist, Meta]).

netsplit(Port) ->
    Local = client(Port, <<"splitter">>, <<"batch extended-join">>),
    send(Local, <<"JOIN #split">>),
    _ = collect(Local),
    Peer = handshake(Port, <<"peer.test">>),
    _ = collect(Peer),
    send(Peer, <<":peer.test NICK farnick 0 user peer.test 1 + :Far">>),
    send(Peer, <<":peer.test NJOIN #split :farnick">>),
    Joined = collect(Local),
    ?assert(has(Joined, <<"netjoin">>)),
    ?assert(has(Joined, <<"JOIN #split * :Far">>)),
    send(Peer, <<":farnick!user@peer.test ACCOUNT faracct">>),
    _ = collect(Local),
    send(Local, <<"WHOIS farnick">>),
    ?assert(has(collect(Local), <<" 330 splitter farnick faracct ">>)),
    gen_tcp:close(Peer),
    Split = collect(Local),
    ?assert(has(Split, <<"BATCH +">>)),
    ?assert(has(Split, <<"netsplit irc.test peer.test">>)),
    ?assert(has(Split, <<"QUIT">>)),
    ?assert(has(Split, <<"BATCH -">>)),
    gen_tcp:close(Local).

cap_new_on_rehash(Port, ConfigPath, Db) ->
    Notified = connect(Port),
    send(Notified, <<"CAP LS 302">>),
    _ = collect(Notified),
    send(Notified, <<"NICK notified">>),
    send(Notified, <<"USER notified 0 * :N">>),
    send(Notified, <<"CAP END">>),
    _ = collect(Notified),
    ok = file:write_file(ConfigPath, config(Db, true)),
    Oper = client(Port, <<"rehasher">>, <<>>),
    send(Oper, <<"OPER oper opersecret">>),
    _ = collect(Oper),
    send(Oper, <<"REHASH">>),
    ?assert(has(collect(Oper), <<" 382 ">>)),
    Changes = collect(Notified),
    ?assert(has(Changes, <<"CAP notified DEL :draft/account-registration">>)),
    ?assert(has(Changes, <<"CAP notified NEW :sts=port=7000">>)),
    gen_tcp:close(Oper),
    gen_tcp:close(Notified).

%%% Helpers

config(Db, Rehashed) ->
    {Sts, Registration} =
        case Rehashed of
            false -> {<<"6697">>, <<"true">>};
            true -> {<<"7000">>, <<"false">>}
        end,
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"ws_port\":0,">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",">>,
        <<"\"network\":\"TestNet\",\"network_icon\":\"https://example.org/icon.svg\",">>,
        <<"\"utf8_only\":true,\"monitor_limit\":3,">>,
        <<"\"sts\":{\"port\":">>,
        Sts,
        <<",\"duration\":600},">>,
        <<"\"account_registration\":">>,
        Registration,
        <<",">>,
        <<"\"webirc\":[{\"password\":\"gatepass\",\"hosts\":[\"127.0.0.1\"]}],">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\",">>,
        <<"\"operators\":[{\"name\":\"oper\",\"password\":\"opersecret\"}],">>,
        <<"\"server_links\":[{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false}]}">>
    ]).

client(Port, Nick, Caps) ->
    Sock = connect(Port),
    send(Sock, <<"CAP LS 302">>),
    _ = collect(Sock),
    case Caps of
        <<>> ->
            ok;
        _ ->
            send(Sock, <<"CAP REQ :", Caps/binary>>),
            ?assert(has(collect(Sock), <<" ACK ">>))
    end,
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :Real ", Nick/binary>>),
    send(Sock, <<"CAP END">>),
    Welcome = collect(Sock),
    ?assert(has(Welcome, <<" 001 ">>)),
    Sock.

handshake(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    ?assert(has(collect(Sock), <<"SERVER irc.test">>)),
    Sock.

register_client(Port, Nick) ->
    Sock = connect(Port),
    send(Sock, <<"NICK ", Nick/binary>>),
    send(Sock, <<"USER ", Nick/binary, " 0 * :Real ", Nick/binary>>),
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
        {ok, <<_/binary>> = Bin} ->
            collect(Sock, <<Acc/binary, Bin/binary>>, N + 1, Wait);
        {error, timeout} when Wait, Acc =:= <<>>, N < 15 ->
            collect(Sock, Acc, N + 1, Wait);
        {error, timeout} ->
            Acc;
        {error, closed} ->
            Acc
    end;
collect(_Sock, Acc, _, _) ->
    Acc.

listener_port(Kind) ->
    {_, Pid, _, _} = lists:keyfind(Kind, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

lines(Bin) ->
    binary:split(Bin, <<"\r\n">>, [global, trim_all]).

starts_with_tag(Bin) ->
    lists:any(
        fun
            (<<$@, _/binary>>) -> true;
            (_) -> false
        end,
        lines(Bin)
    ).

count_lines(Bin, Needle) ->
    length([Line || Line <- lines(Bin), has(Line, Needle)]).
