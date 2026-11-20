-module(ircd_cov_v3_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ircd/include/ircd_state.hrl").
-include_lib("ircd/include/ircd_account.hrl").

%% Live coverage for the IRCv3 state modules: accounts and SASL
%% (ircd_account, ircd_sasl, ircd_state_v3), draft/account-registration,
%% setname, chghost, pre-away, WEBIRC, multiclient and account rejoin,
%% MONITOR, draft/multiline client batches, draft/metadata-2 (and the legacy
%% metadata replies), draft/chathistory, draft/read-marker, and
%% draft/message-redaction, including FAIL replies and remote (peer) paths.

-define(SERVER, <<"irc.test">>).
-define(PEER, <<"peer.test">>).

main_test_() ->
    {timeout, 240, fun main/0}.

main() ->
    with_server(main_config, fun(Port, Dir) ->
        accounts_unit(),
        sasl_unit(),
        sasl_live(Port),
        registration_verification(Port, Dir),
        multiclient_and_rejoin(Port),
        setname_chghost(Port),
        pre_away_starttls_isupport(Port),
        webirc(Port),
        monitor(Port),
        batch(Port),
        metadata(Port),
        history(Port),
        direct_history_and_markers(Port),
        remote_paths(Port)
    end).

%%% Accounts (ircd_account) and SASL steps that need stored accounts.

accounts_unit() ->
    ?assertNot(ircd_account:valid_name(42)),
    ?assertNot(ircd_account:valid_name(<<"anonymous">>)),
    ?assertEqual(
        {error, bad_account_name},
        ircd_account:create(<<"bad name">>, undefined, <<"password1">>, [], undefined)
    ),
    ?assertEqual(
        {error, weak_password},
        ircd_account:create(<<"shortpw">>, undefined, <<"pw">>, [], undefined)
    ),
    ?assertEqual(
        {error, unacceptable_password},
        ircd_account:create(<<"longpw">>, undefined, binary:copy(<<"p">>, 301), [], undefined)
    ),
    {ok, #account{name = <<"Unit1">>}} = ircd_account:create(
        <<"Unit1">>, <<"u@example.org">>, <<"password1">>, [<<"abcdef">>], undefined
    ),
    ?assertEqual(
        {error, account_exists},
        ircd_account:create(<<"UNIT1">>, undefined, <<"password1">>, [], undefined)
    ),
    ?assertMatch({ok, #account{name = <<"Unit1">>}}, ircd_account:find(<<"unit1">>)),
    ?assertEqual(error, ircd_account:check_password(<<"nobodyx">>, <<"password1">>)),
    ?assertEqual(error, ircd_account:check_password(<<"unit1">>, <<"wrongpass">>)),
    ?assertMatch({ok, _}, ircd_account:check_password(<<"unit1">>, <<"password1">>)),
    ?assertEqual(error, ircd_account:scram_credentials(<<"nobodyx">>)),
    ?assertMatch({ok, #account{name = <<"Unit1">>}}, ircd_account:by_certfp(<<"ABCDEF">>)),
    ?assertEqual(error, ircd_account:by_certfp(<<"0000">>)),
    %% A pending account holds its name until verified or expired.
    {ok, _} = ircd_account:create(
        <<"Pend1">>, <<"p@example.org">>, <<"password1">>, [], {<<"CODE1234">>, 60000}
    ),
    ?assertEqual(error, ircd_account:find(<<"pend1">>)),
    ?assertEqual(
        {error, account_exists},
        ircd_account:create(<<"pend1">>, undefined, <<"password1">>, [], undefined)
    ),
    ?assertEqual(error, ircd_account:verify(<<"pend1">>, <<"WRONG">>)),
    ?assertEqual(error, ircd_account:verify(<<"nobodyx">>, <<"CODE1234">>)),
    ?assertMatch(
        {ok, #account{pending = undefined}}, ircd_account:verify(<<"pend1">>, <<"CODE1234">>)
    ),
    ?assertMatch({ok, _}, ircd_account:find(<<"pend1">>)),
    %% An expired pending row can be registered again.
    {ok, _} = ircd_account:create(<<"Exp1">>, undefined, <<"password1">>, [], {<<"C">>, 1}),
    timer:sleep(5),
    ?assertEqual(error, ircd_account:verify(<<"exp1">>, <<"C">>)),
    ?assertMatch(
        {ok, _}, ircd_account:create(<<"Exp1">>, undefined, <<"password1">>, [], undefined)
    ),
    %% Replicated accounts: the oldest copy wins.
    {ok, Base} = ircd_account:find(<<"unit1">>),
    Imported = Base#account{key = <<"imp1">>, name = <<"Imp1">>, created = 100},
    ?assertEqual(stored, ircd_account:import(Imported)),
    ?assertEqual(kept, ircd_account:import(Imported#account{created = 200})),
    ?assertEqual(stored, ircd_account:import(Imported#account{created = 50})),
    ?assert(lists:any(fun(#account{name = N}) -> N =:= <<"Imp1">> end, ircd_account:list())),
    ok.

sasl_unit() ->
    %% PLAIN hands the password check to the caller (ircd_state runs the
    %% PBKDF2 step in a worker); check_password/2 is the synchronous form.
    ?assertEqual(
        {check_password, <<"unit1">>, <<"password1">>},
        ircd_sasl:step(plain, <<0, "unit1", 0, "password1">>)
    ),
    ?assertEqual(
        {check_password, <<"unit1">>, <<"password1">>},
        ircd_sasl:step(plain, <<"UNIT1", 0, "unit1", 0, "password1">>)
    ),
    ?assertMatch(
        {ok, #account{name = <<"Unit1">>}},
        ircd_account:check_password(<<"unit1">>, <<"password1">>)
    ),
    ?assertEqual(error, ircd_account:check_password(<<"unit1">>, <<"nope">>)),
    ?assertEqual({success, <<"Unit1">>}, ircd_sasl:step({external, <<"abcdef">>}, <<>>)),
    ?assertEqual({success, <<"Unit1">>}, ircd_sasl:step({external, <<"abcdef">>}, <<"unit1">>)),
    ?assertEqual({error, failed}, ircd_sasl:step({external, <<"abcdef">>}, <<"other">>)),
    ?assertEqual({error, failed}, ircd_sasl:step({external, <<"1234">>}, <<>>)),
    ?assertEqual(
        {error, failed}, ircd_sasl:step({scram_first, undefined}, <<"n,,n=nobodyx,r=abc">>)
    ),
    %% A full SCRAM-SHA-256 exchange through the pure module, with authzid
    %% and an escaped (here: plain) username.
    Bare = <<"n=unit1,r=clientnonce">>,
    {continue, ServerFirst, State} =
        ircd_sasl:step({scram_first, undefined}, <<"y,a=Unit1,", Bare/binary>>),
    Attrs = #{K => V || <<K, $=, V/binary>> <- binary:split(ServerFirst, <<",">>, [global])},
    #{$r := Nonce, $s := Salt64, $i := Iter} = Attrs,
    Salted = crypto:pbkdf2_hmac(
        sha256, <<"password1">>, base64:decode(Salt64), binary_to_integer(Iter), 32
    ),
    ClientKey = crypto:mac(hmac, sha256, Salted, <<"Client Key">>),
    Stored = crypto:hash(sha256, ClientKey),
    Without = <<"c=", (base64:encode(<<"y,a=Unit1,">>))/binary, ",r=", Nonce/binary>>,
    Auth = <<Bare/binary, ",", ServerFirst/binary, ",", Without/binary>>,
    Proof = crypto:exor(ClientKey, crypto:mac(hmac, sha256, Stored, Auth)),
    {continue, <<"v=", _/binary>>, Done} =
        ircd_sasl:step(State, <<Without/binary, ",p=", (base64:encode(Proof))/binary>>),
    ?assertEqual({success, <<"Unit1">>}, ircd_sasl:step(Done, <<>>)),
    ok.

%%% SASL over the wire (AUTHENTICATE errors and chunking)

sasl_live(Port) ->
    S = connect(Port),
    send(S, <<"CAP REQ :sasl">>),
    send(S, <<"NICK sasl1">>),
    send(S, <<"USER sasl1 0 * :S">>),
    _ = sync(S),
    ?assert(has(cmd(S, <<"AUTHENTICATE">>), <<" 461 sasl1 AUTHENTICATE ">>)),
    send(S, <<"AUTHENTICATE PLAIN">>),
    ?assert(has(cmd(S, <<"AUTHENTICATE ", (binary:copy(<<"A">>, 401))/binary>>), <<" 905 ">>)),
    send(S, <<"AUTHENTICATE PLAIN">>),
    ?assert(has(cmd(S, <<"AUTHENTICATE !!!!">>), <<" 904 ">>)),
    %% A full 400-byte chunk waits for more; "+" ends it (garbage payload).
    send(S, <<"AUTHENTICATE PLAIN">>),
    ?assertNot(has(cmd(S, <<"AUTHENTICATE ", (binary:copy(<<"A">>, 400))/binary>>), <<" 90">>)),
    ?assert(has(cmd(S, <<"AUTHENTICATE +">>), <<" 904 ">>)),
    %% A correctly chunked but oversized response.
    send(S, <<"AUTHENTICATE PLAIN">>),
    lists:foreach(
        fun(_) -> send(S, <<"AUTHENTICATE ", (binary:copy(<<"A">>, 400))/binary>>) end,
        lists:seq(1, 21)
    ),
    ?assert(has(sync(S), <<" 904 ">>)),
    %% Success before registration completes.
    send(S, <<"AUTHENTICATE PLAIN">>),
    Ok = cmd(S, <<"AUTHENTICATE ", (base64:encode(<<0, "unit1", 0, "password1">>))/binary>>),
    ?assert(has(Ok, <<" 900 sasl1 ">>)),
    ?assert(has(Ok, <<" 903 ">>)),
    ?assert(has(cmd(S, <<"CAP END">>), <<" 001 ">>)),
    %% Logging out (used when an account is removed) sends 901 once.
    #client{} = Client = ircd_state_client:find_nick(<<"sasl1">>),
    ok = ircd_state_v3:logout(Client, ?SERVER),
    ?assert(has(sync(S), <<" 901 sasl1 ">>)),
    ok = ircd_state_v3:logout(Client, ?SERVER),
    ?assertNot(has(sync(S), <<" 901 ">>)),
    close(S).

%%% draft/account-registration with email verification (main config)

registration_verification(Port, Dir) ->
    S = connect(Port),
    send(S, <<"CAP REQ :draft/account-registration">>),
    send(S, <<"NICK regv1">>),
    _ = sync(S),
    ?assert(has(cmd(S, <<"REGISTER a">>), <<" 461 ">>)),
    ?assert(has(cmd(S, <<"VERIFY">>), <<" 461 ">>)),
    %% Verification makes the email mandatory.
    ?assert(has(cmd(S, <<"REGISTER * * password1">>), <<"FAIL REGISTER INVALID_EMAIL regv1">>)),
    ?assert(
        has(
            cmd(S, <<"REGISTER bad!name a@example.org password1">>),
            <<"FAIL REGISTER BAD_ACCOUNT_NAME bad!name">>
        )
    ),
    ?assert(
        has(
            cmd(S, <<"REGISTER * a@example.org ", (binary:copy(<<"p">>, 301))/binary>>),
            <<"FAIL REGISTER UNACCEPTABLE_PASSWORD regv1">>
        )
    ),
    Code = filename:join(Dir, "code"),
    _ = file:delete(Code),
    ?assert(
        has(
            cmd(S, <<"REGISTER * v@example.org password1">>),
            <<"REGISTER VERIFICATION_REQUIRED regv1">>
        )
    ),
    Sent = wait_file(Code, 50),
    ?assert(has(cmd(S, <<"VERIFY * WRONGCODE">>), <<"FAIL VERIFY INVALID_CODE regv1">>)),
    Verified = cmd(S, <<"VERIFY regv1 ", Sent/binary>>),
    ?assert(has(Verified, <<"VERIFY SUCCESS regv1">>)),
    ?assert(has(Verified, <<" 900 ">>)),
    close(S).

wait_file(Path, 0) ->
    erlang:error({missing_file, Path});
wait_file(Path, N) ->
    case file:read_file(Path) of
        {ok, <<_, _/binary>> = Bin} ->
            string:trim(Bin);
        _ ->
            timer:sleep(50),
            wait_file(Path, N - 1)
    end.

%%% multiclient attach and account rejoin

sasl_connect(Port, Nick, Account, Caps) ->
    S = connect(Port),
    case Caps of
        <<>> -> send(S, <<"CAP REQ :sasl">>);
        _ -> send(S, <<"CAP REQ :sasl ", Caps/binary>>)
    end,
    send(S, <<"AUTHENTICATE PLAIN">>),
    send(S, <<"AUTHENTICATE ", (base64:encode(<<0, Account/binary, 0, "password1">>))/binary>>),
    ?assert(has(sync(S), <<" 903 ">>)),
    send(S, <<"NICK ", Nick/binary>>),
    send(S, <<"USER ", Nick/binary, " 0 * :", Nick/binary>>),
    S.

multiclient_and_rejoin(Port) ->
    {ok, _} = ircd_account:create(<<"multi">>, undefined, <<"password1">>, [], undefined),
    First = sasl_connect(Port, <<"multi">>, <<"multi">>, <<>>),
    ?assert(has(cmd(First, <<"CAP END">>), <<" 001 ">>)),
    Second = sasl_connect(Port, <<"multi">>, <<"multi">>, <<>>),
    %% Regression: a line pipelined behind CAP END reaches ircd_state after
    %% the attach dropped this connection's client row. It used to crash
    %% ircd_state; now it runs as the holder session.
    State = whereis(ircd_state),
    send(Second, <<"CAP END\r\nPING :pipelined">>),
    Attached = expect(Second, <<"pipelined">>),
    ?assertEqual(State, whereis(ircd_state)),
    ?assertNot(has(Attached, <<" 433 ">>)),
    ?assert(has(Attached, <<" 001 multi ">>)),
    %% A connection without that account still gets 433.
    Other = connect(Port),
    send(Other, <<"NICK multi">>),
    ?assert(has(sync(Other), <<" 433 ">>)),
    close(Other),
    close(Second),
    close(First),
    %% account_rejoin: channels are remembered at disconnect.
    {ok, _} = ircd_account:create(<<"rejoiner">>, undefined, <<"password1">>, [], undefined),
    R1 = sasl_connect(Port, <<"rejoin1">>, <<"rejoiner">>, <<>>),
    _ = cmd(R1, <<"CAP END">>),
    _ = cmd(R1, <<"JOIN #rejoin">>),
    send(R1, <<"QUIT :bye">>),
    wait_closed(R1),
    R2 = sasl_connect(Port, <<"rejoin2">>, <<"rejoiner">>, <<>>),
    ?assert(has(cmd(R2, <<"CAP END">>), <<"JOIN #rejoin">>)),
    close(R2).

%%% SETNAME and CHGHOST

setname_chghost(Port) ->
    Target = client(Port, <<"chtarget">>, <<"setname">>),
    Capable = client(Port, <<"chcap">>, <<"chghost setname">>),
    Legacy = client(Port, <<"chlegacy">>, <<>>),
    Watcher = client(Port, <<"chwatch">>, <<"extended-monitor chghost">>),
    Oper = client(Port, <<"choper">>, <<>>),
    ?assert(has(cmd(Oper, <<"OPER oper opersecret">>), <<" 381 ">>)),
    _ = cmd(Target, <<"JOIN #chg">>),
    _ = cmd(Target, <<"JOIN &chga">>),
    _ = cmd(Target, <<"MODE &chga +a">>),
    _ = cmd(Capable, <<"JOIN #chg">>),
    _ = cmd(Legacy, <<"JOIN #chg">>),
    _ = cmd(Legacy, <<"JOIN &chga">>),
    _ = cmd(Target, <<"MODE #chg +v chtarget">>),
    _ = cmd(Watcher, <<"MONITOR + chtarget">>),
    lists:foreach(fun sync/1, [Target, Capable, Legacy, Watcher]),
    %% SETNAME
    ?assert(has(cmd(Target, <<"SETNAME">>), <<" 461 ">>)),
    ?assert(
        has(
            cmd(Target, <<"SETNAME :", (binary:copy(<<"r">>, 201))/binary>>),
            <<"FAIL SETNAME INVALID_REALNAME">>
        )
    ),
    ?assert(has(cmd(Target, <<"SETNAME :New Real">>), <<"SETNAME :New Real">>)),
    ?assert(has(sync(Capable), <<"chtarget!chtarget@127.0.0.1 SETNAME :New Real">>)),
    ?assertNot(has(sync(Legacy), <<"SETNAME">>)),
    %% CHGHOST
    ?assert(has(cmd(Legacy, <<"CHGHOST chtarget u h">>), <<" 481 ">>)),
    ?assert(has(cmd(Oper, <<"CHGHOST chtarget">>), <<" 461 ">>)),
    ?assert(has(cmd(Oper, <<"CHGHOST nobodyx u h">>), <<" 401 choper nobodyx ">>)),
    ?assert(
        has(cmd(Oper, <<"CHGHOST chtarget bad!user h">>), <<"FAIL CHGHOST INVALID_USERNAME">>)
    ),
    ?assert(
        has(cmd(Oper, <<"CHGHOST chtarget user bad_host">>), <<"FAIL CHGHOST INVALID_HOSTNAME">>)
    ),
    _ = cmd(Oper, <<"CHGHOST chtarget newuser new.host">>),
    %% A target without shared channels has no legacy viewers.
    _ = cmd(Oper, <<"CHGHOST choper operu oper.host">>),
    ?assert(has(sync(Capable), <<"chtarget!chtarget@127.0.0.1 CHGHOST newuser new.host">>)),
    ?assert(has(sync(Watcher), <<"CHGHOST newuser new.host">>)),
    Seen = sync(Legacy),
    ?assert(has(Seen, <<"QUIT :Changing hostname">>)),
    ?assert(has(Seen, <<":chtarget!newuser@new.host JOIN #chg">>)),
    ?assert(has(Seen, <<"MODE #chg +ov :chtarget chtarget">>)),
    ?assertNot(has(Seen, <<"JOIN &chga">>)),
    lists:foreach(fun close/1, [Target, Capable, Legacy, Watcher, Oper]).

%%% draft/pre-away, STARTTLS without TLS, ISUPPORT

pre_away_starttls_isupport(Port) ->
    S = connect(Port),
    ?assert(has(cmd(S, <<"AWAY :x">>), <<" 451 ">>)),
    ?assert(has(cmd(S, <<"STARTTLS">>), <<" 691 ">>)),
    send(S, <<"CAP REQ :draft/pre-away away-notify">>),
    ?assert(has(cmd(S, <<"AWAY :brb">>), <<" 306 ">>)),
    ?assert(has(cmd(S, <<"AWAY">>), <<" 305 ">>)),
    ?assert(has(cmd(S, <<"AWAY *">>), <<" 306 ">>)),
    send(S, <<"NICK preaway">>),
    send(S, <<"USER preaway 0 * :P">>),
    ?assert(has(cmd(S, <<"CAP END">>), <<" 001 ">>)),
    Member = client(Port, <<"awaymem">>, <<"away-notify">>),
    _ = cmd(Member, <<"JOIN #away">>),
    _ = cmd(S, <<"JOIN #away">>),
    ?assert(has(sync(Member), <<"preaway!preaway@127.0.0.1 AWAY :Away">>)),
    close(S),
    close(Member).

%%% WEBIRC

webirc(Port) ->
    Short = connect(Port),
    ?assert(has(cmd(Short, <<"WEBIRC gatepass gw">>), <<" 461 ">>)),
    close(Short),
    %% An invalid hostname falls back to the IP; a leading ':' is escaped.
    V6 = connect(Port),
    send(V6, <<"WEBIRC gatepass gw bad_host :::1">>),
    send(V6, <<"NICK webv6">>),
    send(V6, <<"USER webv6 0 * :W">>),
    _ = sync(V6),
    ?assert(has(cmd(V6, <<"WHOIS webv6">>), <<" 311 webv6 webv6 webv6 0::1 ">>)),
    close(V6),
    Named = connect(Port),
    send(Named, <<"WEBIRC gatepass gw user.example 192.0.2.7 :secure x=y">>),
    send(Named, <<"NICK webname">>),
    send(Named, <<"USER webname 0 * :W">>),
    _ = sync(Named),
    ?assert(has(cmd(Named, <<"WHOIS webname">>), <<" user.example ">>)),
    close(Named),
    Bad = connect(Port),
    send(Bad, <<"WEBIRC wrongpass gw host.example 192.0.2.8">>),
    ?assert(has(until_closed(Bad), <<"ERROR :Invalid WebIRC password">>)).

%%% MONITOR

monitor(Port) ->
    M = client(Port, <<"monx">>, <<>>),
    Online = client(Port, <<"monon">>, <<>>),
    ?assert(has(cmd(M, <<"MONITOR">>), <<" 461 ">>)),
    ?assert(has(cmd(M, <<"MONITOR +">>), <<" 461 ">>)),
    ?assert(has(cmd(M, <<"MONITOR X">>), <<" 421 monx MONITOR ">>)),
    Added = cmd(M, <<"MONITOR + bad!nick,monon,MONON,monoff">>),
    ?assert(has(Added, <<" 730 monx :monon!monon@127.0.0.1">>)),
    ?assert(has(Added, <<" 731 monx :monoff">>)),
    ?assertNot(has(Added, <<"bad!nick">>)),
    %% An unregistered nickname is not online.
    Half = connect(Port),
    send(Half, <<"NICK monhalf">>),
    _ = sync(Half),
    ?assert(has(cmd(M, <<"MONITOR + monhalf">>), <<" 731 monx :monhalf">>)),
    close(Half),
    %% Long lists are split over several numerics.
    Nicks = [<<"monlist", (integer_to_binary(N))/binary>> || N <- lists:seq(10, 59)],
    Many = cmd(M, <<"MONITOR + ", (iolist_to_binary(lists:join(<<",">>, Nicks)))/binary>>),
    ?assert(count_lines(Many, <<" 731 monx ">>) >= 2),
    ?assert(count_lines(cmd(M, <<"MONITOR L">>), <<" 732 monx ">>) >= 2),
    close(Online),
    close(M).

%%% draft/multiline client batches

batch(Port) ->
    Caps = <<"batch draft/multiline message-tags labeled-response echo-message">>,
    S = client(Port, <<"mlx">>, Caps),
    Plain = client(Port, <<"mlplainx">>, <<>>),
    _ = cmd(S, <<"JOIN #mlx">>),
    _ = cmd(Plain, <<"JOIN #mlx">>),
    ?assert(has(cmd(S, <<"BATCH">>), <<" 461 mlx BATCH ">>)),
    ?assert(
        has(cmd(S, <<"BATCH +bad! draft/multiline #mlx">>), <<"FAIL BATCH INVALID_REFTAG bad!">>)
    ),
    ?assert(has(cmd(S, <<"BATCH +c draft/multiline">>), <<"FAIL BATCH MULTILINE_INVALID">>)),
    ?assert(has(cmd(S, <<"BATCH -zzz">>), <<"FAIL BATCH INVALID_REFTAG zzz">>)),
    ?assert(has(cmd(S, <<"@batch=nope PRIVMSG #mlx :x">>), <<"FAIL BATCH INVALID_REFTAG nope">>)),
    ?assert(
        has(cmd(Plain, <<"BATCH +d draft/multiline #mlx">>), <<"FAIL BATCH UNKNOWN_TYPE d">>)
    ),
    %% Nested batches.
    _ = cmd(S, <<"BATCH +a draft/multiline #mlx">>),
    ?assert(
        has(cmd(S, <<"BATCH +b draft/multiline #mlx">>), <<"FAIL BATCH MULTILINE_INVALID">>)
    ),
    %% Mixed commands.
    _ = cmd(S, <<"BATCH +e draft/multiline #mlx">>),
    _ = cmd(S, <<"@batch=e PRIVMSG #mlx :a">>),
    ?assert(has(cmd(S, <<"@batch=e NOTICE #mlx :b">>), <<"Mixed message types">>)),
    %% Blank concatenated line.
    _ = cmd(S, <<"BATCH +f draft/multiline #mlx">>),
    _ = cmd(S, <<"@batch=f PRIVMSG #mlx :a">>),
    ?assert(
        has(
            cmd(S, <<"@batch=f;draft/multiline-concat PRIVMSG #mlx :">>),
            <<"Blank concatenated line">>
        )
    ),
    %% Line without text, and TAGMSG, are invalid in a batch.
    _ = cmd(S, <<"BATCH +g draft/multiline #mlx">>),
    ?assert(has(cmd(S, <<"@batch=g PRIVMSG #mlx">>), <<"Invalid line in multiline batch">>)),
    %% Too many bytes.
    _ = cmd(S, <<"BATCH +h draft/multiline #mlx">>),
    Long = binary:copy(<<"x">>, 480),
    lists:foreach(
        fun(_) -> send(S, <<"@batch=h PRIVMSG #mlx :", Long/binary>>) end, lists:seq(1, 9)
    ),
    ?assert(has(sync(S), <<"FAIL BATCH MULTILINE_MAX_BYTES 4096">>)),
    %% Empty and blank batches.
    _ = cmd(S, <<"BATCH +i draft/multiline #mlx">>),
    ?assert(has(cmd(S, <<"BATCH -i">>), <<"Empty multiline batch">>)),
    _ = cmd(S, <<"BATCH +j draft/multiline #mlx">>),
    _ = cmd(S, <<"@batch=j PRIVMSG #mlx :">>),
    ?assert(has(cmd(S, <<"BATCH -j">>), <<"Blank multiline message">>)),
    %% A labeled batch with a client-only tag delivers to both kinds of member.
    _ = cmd(S, <<"@label=L1;+draft/reply=abc BATCH +k draft/multiline #mlx">>),
    _ = cmd(S, <<"@batch=k PRIVMSG #mlx :first">>),
    _ = cmd(S, <<"@batch=k;draft/multiline-concat PRIVMSG #mlx :+joined">>),
    _ = cmd(S, <<"@batch=k PRIVMSG #mlx :">>),
    _ = cmd(S, <<"@batch=k PRIVMSG #mlx :last">>),
    Echo = cmd(S, <<"BATCH -k">>),
    ?assert(has(Echo, <<"label=L1">>)),
    ?assert(has(Echo, <<"draft/multiline #mlx">>)),
    Fallback = sync(Plain),
    %% TAGMSG is not delivered to members without message-tags.
    _ = cmd(S, <<"@+typing=active TAGMSG #mlx">>),
    ?assertNot(has(sync(Plain), <<"TAGMSG">>)),
    ?assertEqual(3, count_lines(Fallback, <<"PRIVMSG #mlx">>)),
    %% Multiline to a user.
    _ = cmd(S, <<"BATCH +u draft/multiline mlplainx">>),
    _ = cmd(S, <<"@batch=u PRIVMSG MLPLAINX :one">>),
    _ = cmd(S, <<"@batch=u PRIVMSG mlplainx :two">>),
    _ = cmd(S, <<"BATCH -u">>),
    ?assertEqual(2, count_lines(sync(Plain), <<"PRIVMSG mlplainx">>)),
    close(S),
    close(Plain).

%%% draft/metadata-2 and legacy metadata

metadata(Port) ->
    V3 = <<"batch draft/metadata-2 labeled-response">>,
    A = client(Port, <<"metax">>, V3),
    B = client(Port, <<"metay">>, V3),
    L = client(Port, <<"metaleg">>, <<>>),
    ?assert(has(cmd(A, <<"METADATA *">>), <<" 461 ">>)),
    ?assert(has(cmd(A, <<"METADATA * FOO">>), <<"FAIL METADATA SUBCOMMAND_INVALID FOO">>)),
    ?assert(has(cmd(A, <<"METADATA * SET">>), <<" 461 ">>)),
    ?assert(has(cmd(A, <<"METADATA * SET nokey">>), <<"FAIL METADATA KEY_NOT_SET metax nokey">>)),
    ?assert(
        has(
            cmd(A, <<"METADATA * SET big :", (binary:copy(<<"v">>, 301))/binary>>),
            <<"FAIL METADATA VALUE_INVALID">>
        )
    ),
    ?assert(has(cmd(A, <<"METADATA #nochan GET x">>), <<"FAIL METADATA INVALID_TARGET #nochan">>)),
    %% Subscriptions.
    ?assert(has(cmd(B, <<"METADATA * SUB avatar Bad!">>), <<"FAIL METADATA KEY_INVALID Bad!">>)),
    ?assert(has(cmd(B, <<"METADATA * SUB avatar topic">>), <<" 770 metay avatar topic">>)),
    Keys = [<<"s", (integer_to_binary(N))/binary>> || N <- lists:seq(1, 52)],
    Subbed = iolist_to_binary([
        cmd(B, <<"METADATA * SUB ", (iolist_to_binary(lists:join(<<" ">>, Chunk)))/binary>>)
     || Chunk <- chunks(Keys, 13)
    ]),
    ?assert(has(Subbed, <<"FAIL METADATA TOO_MANY_SUBS">>)),
    ?assert(count_lines(cmd(B, <<"METADATA * SUBS">>), <<" 772 ">>) > 1),
    Unsub = cmd(B, <<"METADATA * UNSUB s1 s2 Bad!">>),
    ?assert(has(Unsub, <<" 771 metay s1 s2">>)),
    ?assert(has(Unsub, <<"FAIL METADATA KEY_INVALID Bad!">>)),
    %% User keys: set, announce, delete.
    _ = cmd(A, <<"METADATA * SET avatar :https://example.org/x.png">>),
    _ = cmd(A, <<"JOIN #mpub">>),
    _ = cmd(L, <<"JOIN #mpub">>),
    %% The joiner gets the channel's and members' subscribed values.
    Joined = cmd(B, <<"JOIN #mpub">>),
    ?assert(has(Joined, <<"METADATA metax avatar * :https://example.org/x.png">>)),
    _ = sync(A),
    ?assert(has(cmd(A, <<"METADATA * SET avatar">>), <<" 766 metax metax avatar ">>)),
    ?assert(has(sync(B), <<"METADATA metax avatar *">>)),
    %% Joining a channel shows the joiner's values to subscribed members.
    _ = cmd(A, <<"METADATA * SET avatar :again">>),
    _ = cmd(B, <<"JOIN #mjoin">>),
    _ = sync(B),
    _ = cmd(A, <<"JOIN #mjoin">>),
    ?assert(has(sync(B), <<"METADATA metax avatar * :again">>)),
    %% Channel keys and SYNC.
    _ = cmd(A, <<"METADATA #mpub SET topic :blue">>),
    ?assert(has(sync(B), <<"METADATA #mpub topic * :blue">>)),
    Synced = cmd(B, <<"METADATA #mpub SYNC">>),
    ?assert(has(Synced, <<"METADATA #mpub topic * :blue">>)),
    ?assert(has(Synced, <<"METADATA metax avatar * :again">>)),
    ?assert(has(cmd(B, <<"METADATA metax SYNC">>), <<"METADATA metax avatar * :again">>)),
    ?assert(has(cmd(B, <<"@label=lm METADATA metax LIST">>), <<"metax avatar">>)),
    ?assert(has(cmd(B, <<"@label=ls METADATA * SUBS">>), <<"label=ls">>)),
    ?assert(has(cmd(B, <<"METADATA metax GET Bad!">>), <<"FAIL METADATA KEY_INVALID Bad!">>)),
    ?assertNot(has(cmd(B, <<"METADATA * SUB Bad!">>), <<" 770 ">>)),
    ?assertNot(has(cmd(B, <<"METADATA * UNSUB Bad!">>), <<" 771 ">>)),
    %% Anonymous channels hide members' values.
    _ = cmd(A, <<"JOIN &manon">>),
    _ = cmd(A, <<"MODE &manon +a">>),
    _ = cmd(B, <<"JOIN &manon">>),
    ?assertNot(has(cmd(B, <<"METADATA &manon SYNC">>), <<"METADATA metax avatar">>)),
    %% Secret channel: non-members may not read, non-operators may not write.
    _ = cmd(A, <<"JOIN #msec">>),
    _ = cmd(A, <<"MODE #msec +s">>),
    _ = cmd(A, <<"METADATA #msec SET k :v">>),
    lists:foreach(
        fun(Line) ->
            ?assert(has(cmd(B, Line), <<"FAIL METADATA KEY_NO_PERMISSION #msec">>))
        end,
        [
            <<"METADATA #msec GET k">>,
            <<"METADATA #msec LIST">>,
            <<"METADATA #msec SYNC">>,
            <<"METADATA #msec SET k :x">>,
            <<"METADATA #msec CLEAR">>
        ]
    ),
    ?assert(has(cmd(A, <<"METADATA #msec CLEAR">>), <<" 766 metax #msec k ">>)),
    %% Key limit.
    lists:foreach(
        fun(N) -> send(A, <<"METADATA * SET k", (integer_to_binary(N))/binary, " :v">>) end,
        lists:seq(1, 49)
    ),
    _ = sync(A),
    ?assert(has(cmd(A, <<"METADATA * SET k50 :v">>), <<"FAIL METADATA LIMIT_REACHED metax">>)),
    _ = cmd(A, <<"METADATA * CLEAR">>),
    %% Legacy metadata for clients without draft/metadata-2.
    ?assert(has(cmd(L, <<"METADATA nobodyx GET a">>), <<" 765 nobodyx ">>)),
    Set = cmd(L, <<"METADATA * SET avatar :legacy">>),
    ?assert(has(Set, <<" 761 metaleg avatar * :legacy">>)),
    ?assert(has(Set, <<" 762 ">>)),
    ?assert(has(sync(B), <<"METADATA metaleg avatar * :legacy">>)),
    Get = cmd(L, <<"METADATA * GET avatar Bad! missing">>),
    ?assert(has(Get, <<" 761 metaleg avatar * :legacy">>)),
    ?assert(has(Get, <<" 767 Bad! ">>)),
    ?assert(has(Get, <<" 766 metaleg missing ">>)),
    List = cmd(L, <<"METADATA * LIST">>),
    ?assert(has(List, <<" 761 metaleg avatar ">>)),
    ?assert(has(List, <<" 762 ">>)),
    ?assert(has(cmd(L, <<"METADATA * SET Bad! :x">>), <<" 767 Bad! ">>)),
    ?assert(has(cmd(L, <<"METADATA metax SET avatar :x">>), <<" 769 metax avatar ">>)),
    ?assert(has(cmd(L, <<"METADATA metax CLEAR">>), <<" 769 metax * ">>)),
    ?assert(
        has(
            cmd(L, <<"METADATA * SET big :", (binary:copy(<<"v">>, 301))/binary>>),
            <<" 764 metaleg ">>
        )
    ),
    ?assert(has(cmd(L, <<"METADATA * SET avatar">>), <<" 762 ">>)),
    ?assert(has(cmd(L, <<"METADATA * CLEAR">>), <<" 762 ">>)),
    ?assert(has(cmd(L, <<"METADATA * FOO">>), <<" 461 ">>)),
    %% RENAME moves channel metadata.
    _ = cmd(A, <<"METADATA #mpub SET topic :kept">>),
    _ = cmd(A, <<"RENAME #mpub #mpub2 :moving">>),
    ?assert(has(cmd(A, <<"METADATA #mpub2 GET topic">>), <<"#mpub2 topic * :kept">>)),
    lists:foreach(fun close/1, [A, B, L]).

chunks([], _N) ->
    [];
chunks(List, N) when length(List) =< N ->
    [List];
chunks(List, N) ->
    {Head, Tail} = lists:split(N, List),
    [Head | chunks(Tail, N)].

%%% draft/chathistory (channel), event-playback, and REDACT

history(Port) ->
    Caps =
        <<"batch server-time message-tags echo-message draft/chathistory ",
            "draft/event-playback draft/message-redaction labeled-response">>,
    H1 = client(Port, <<"histx">>, Caps),
    H2 = client(Port, <<"histy">>, Caps),
    _ = cmd(H1, <<"JOIN #hx">>),
    _ = cmd(H2, <<"JOIN #hx">>),
    Echoes = iolist_to_binary([
        cmd(H1, <<"PRIVMSG #hx :m", (integer_to_binary(N))/binary>>)
     || N <- lists:seq(1, 4)
    ]),
    _ = sync(H2),
    [M1, M2, M3, M4] = [msgid(Echoes, <<"PRIVMSG #hx :m", N>>) || N <- [$1, $2, $3, $4]],
    Old = <<"timestamp=2000-01-01T00:00:00.000Z">>,
    New = <<"timestamp=2100-01-01T00:00:00.000Z">>,
    Latest = cmd(H2, <<"CHATHISTORY LATEST #hx ", Old/binary, " 10">>),
    ?assert(has(Latest, <<":m1">>)),
    ?assert(has(Latest, <<"JOIN #hx">>)),
    After = cmd(H2, <<"CHATHISTORY AFTER #hx ", Old/binary, " 50">>),
    ?assert(has(After, <<":m4">>)),
    ?assert(has(After, <<"draft/chathistory-end">>)),
    Before = cmd(H2, <<"CHATHISTORY BEFORE #hx ", New/binary, " 1">>),
    ?assert(has(Before, <<":m4">>)),
    ?assertNot(has(Before, <<":m3">>)),
    Backward = cmd(
        H2, <<"CHATHISTORY BETWEEN #hx msgid=", M4/binary, " msgid=", M1/binary, " 10">>
    ),
    ?assert(has(Backward, <<":m2">>)),
    ?assert(has(Backward, <<":m3">>)),
    ?assertNot(has(Backward, <<":m4">>)),
    Forward = cmd(H2, <<"CHATHISTORY BETWEEN #hx msgid=", M1/binary, " ", New/binary, " 1">>),
    ?assert(has(Forward, <<":m2">>)),
    ?assertNot(has(Forward, <<":m3">>)),
    Ref = <<"FAIL CHATHISTORY INVALID_MSGREFTYPE BETWEEN #hx">>,
    ?assert(has(cmd(H2, <<"CHATHISTORY BETWEEN #hx foo=bar ", New/binary, " 5">>), Ref)),
    ?assert(has(cmd(H2, <<"CHATHISTORY BETWEEN #hx ", Old/binary, " foo=bar 5">>), Ref)),
    Invalid = <<"FAIL CHATHISTORY INVALID_PARAMS">>,
    lists:foreach(
        fun(Line) -> ?assert(has(cmd(H2, Line), Invalid)) end,
        [
            <<"CHATHISTORY BETWEEN #hx junk junk 5">>,
            <<"CHATHISTORY BEFORE #hx msgid=unknown 5">>,
            <<"CHATHISTORY LATEST #hx * 0">>,
            <<"CHATHISTORY LATEST #hx * abc">>,
            <<"CHATHISTORY AFTER #hx timestamp=notatime 5">>,
            <<"CHATHISTORY AFTER #hx =x 5">>,
            <<"CHATHISTORY TARGETS foo bar 5">>,
            <<"CHATHISTORY BEFORE #hx">>,
            <<"CHATHISTORY TARGETS">>
        ]
    ),
    ?assert(has(cmd(H2, <<"CHATHISTORY LATEST #hx msgid=unknown 5">>), <<"chathistory #hx">>)),
    ?assert(has(cmd(H2, <<"CHATHISTORY">>), <<" 461 histy CHATHISTORY ">>)),
    ?assert(
        has(
            cmd(H2, <<"CHATHISTORY LATEST someone * 5">>),
            <<"FAIL CHATHISTORY INVALID_TARGET LATEST someone">>
        )
    ),
    %% TARGETS in both directions.
    ?assert(
        has(
            cmd(H2, <<"CHATHISTORY TARGETS ", New/binary, " ", Old/binary, " 5">>),
            <<"TARGETS #hx">>
        )
    ),
    %% Events: NICK and QUIT replay without a channel parameter.
    _ = cmd(H2, <<"NICK histz">>),
    _ = sync(H1),
    ok = ircd_state_history:note_event(<<"#hx">>, <<"TOPIC">>, <<"x!y@z">>, [], <<"topic">>),
    ok = ircd_state_history:note_user_event([<<"#hx">>], <<"QUIT">>, <<"x!y@z">>, <<"gone">>),
    Events = cmd(H1, <<"CHATHISTORY LATEST #hx * 10">>),
    ?assert(has(Events, <<"histy!histy@127.0.0.1 NICK :histz">>)),
    ?assert(has(Events, <<":x!y@z QUIT :gone">>)),
    ?assert(has(Events, <<":x!y@z TOPIC #hx :topic">>)),
    %% REDACT: errors, operator redaction of another member's message.
    ?assert(has(cmd(H1, <<"REDACT #hx">>), <<" 461 ">>)),
    ?assert(has(cmd(H1, <<"REDACT #notjoined ", M1/binary>>), <<"FAIL REDACT INVALID_TARGET">>)),
    Theirs = msgid(cmd(H2, <<"PRIVMSG #hx :from-two">>), <<"PRIVMSG #hx :from-two">>),
    _ = sync(H1),
    _ = cmd(H1, <<"REDACT #hx ", Theirs/binary, " :mod">>),
    ?assert(has(sync(H2), <<"REDACT #hx ", Theirs/binary, " :mod">>)),
    _ = cmd(H1, <<"REDACT #hx ", M2/binary>>),
    ?assertNot(has(cmd(H2, <<"CHATHISTORY LATEST #hx * 50">>), <<":m2">>)),
    _ = M3,
    %% Legacy tuple entries replay without msgid and time.
    _ = cmd(H1, <<"JOIN #legacy">>),
    ok = mnesia:dirty_write(#channel_history{
        channel = <<"#legacy">>, entries = [{<<"PRIVMSG">>, <<"old!u@h">>, <<"old text">>}]
    }),
    _ = cmd(H2, <<"JOIN #legacy">>),
    Legacy = cmd(H1, <<"CHATHISTORY LATEST #legacy * 10">>),
    ?assert(has(Legacy, <<":old!u@h PRIVMSG #legacy :old text">>)),
    %% A multiline message replays as a batch or as separate lines.
    ML = client(Port, <<"histml">>, <<"batch draft/multiline draft/chathistory">>),
    _ = cmd(ML, <<"JOIN #hx">>),
    _ = cmd(ML, <<"BATCH +r draft/multiline #hx">>),
    _ = cmd(ML, <<"@batch=r PRIVMSG #hx :part one">>),
    _ = cmd(ML, <<"@batch=r PRIVMSG #hx :part two">>),
    _ = cmd(ML, <<"BATCH -r">>),
    ?assert(has(cmd(ML, <<"CHATHISTORY LATEST #hx * 2">>), <<"draft/multiline #hx">>)),
    Split = cmd(H1, <<"CHATHISTORY LATEST #hx * 2">>),
    ?assert(has(Split, <<"PRIVMSG #hx :part one">>)),
    ?assert(has(Split, <<"PRIVMSG #hx :part two">>)),
    %% A target whose newest entries are events, or only events.
    _ = cmd(H1, <<"JOIN #quiet">>),
    _ = cmd(H1, <<"PART #hx">>),
    _ = cmd(H1, <<"JOIN #hx">>),
    ?assert(
        has(
            cmd(H1, <<"CHATHISTORY TARGETS ", Old/binary, " ", New/binary, " 10">>),
            <<"TARGETS #hx">>
        )
    ),
    ok = ircd_state_history:note_channel(<<"#hx">>, #{cmd => <<"JOIN">>}),
    lists:foreach(fun close/1, [H1, H2, ML]).

msgid(Bin, Needle) ->
    [Line | _] = [L || L <- lines(Bin), has(L, Needle)],
    {match, [Id]} = re:run(Line, <<"msgid=([^; ]+)">>, [{capture, all_but_first, binary}]),
    Id.

%%% Direct-message history, TARGETS, read markers, and direct REDACT

direct_history_and_markers(Port) ->
    {ok, _} = ircd_account:create(<<"dmone">>, undefined, <<"password1">>, [], undefined),
    {ok, _} = ircd_account:create(<<"dmtwo">>, undefined, <<"password1">>, [], undefined),
    {ok, _} = ircd_account:create(<<"dmoff">>, undefined, <<"password1">>, [], undefined),
    Caps =
        <<"batch server-time message-tags echo-message draft/chathistory ",
            "draft/read-marker draft/message-redaction">>,
    One = sasl_connect(Port, <<"dmone">>, <<"dmone">>, Caps),
    ?assert(has(cmd(One, <<"CAP END">>), <<" 001 ">>)),
    Two = sasl_connect(Port, <<"dmtwo">>, <<"dmtwo">>, Caps),
    ?assert(has(cmd(Two, <<"CAP END">>), <<" 001 ">>)),
    Mine = msgid(cmd(One, <<"PRIVMSG dmtwo :hello two">>), <<"PRIVMSG dmtwo :hello two">>),
    Reply = msgid(cmd(Two, <<"PRIVMSG dmone :hello one">>), <<"PRIVMSG dmone :hello one">>),
    _ = sync(One),
    Range = <<"timestamp=2000-01-01T00:00:00.000Z timestamp=2100-01-01T00:00:00.000Z 10">>,
    ?assert(has(cmd(One, <<"CHATHISTORY TARGETS ", Range/binary>>), <<"TARGETS dmtwo ">>)),
    ?assert(has(cmd(Two, <<"CHATHISTORY TARGETS ", Range/binary>>), <<"TARGETS dmone ">>)),
    %% An offline account, and an unknown nickname, are valid DM targets.
    ?assert(has(cmd(One, <<"CHATHISTORY LATEST dmoff * 5">>), <<"chathistory dmoff">>)),
    ?assert(has(cmd(One, <<"CHATHISTORY LATEST nobodyx * 5">>), <<"chathistory nobodyx">>)),
    %% Direct REDACT.
    ?assert(
        has(
            cmd(Two, <<"REDACT dmone ", Mine/binary>>),
            <<"FAIL REDACT REDACT_FORBIDDEN dmone">>
        )
    ),
    ?assert(has(cmd(One, <<"REDACT dmtwo nosuchid">>), <<"FAIL REDACT UNKNOWN_MSGID dmtwo">>)),
    ?assert(has(cmd(One, <<"REDACT dmtwo ", Mine/binary, " :oops">>), <<"REDACT dmtwo">>)),
    ?assert(has(sync(Two), <<"REDACT dmtwo ", Mine/binary, " :oops">>)),
    _ = Reply,
    ?assert(has(cmd(One, <<"REDACT dmoff someid">>), <<"FAIL REDACT UNKNOWN_MSGID dmoff">>)),
    Anon = client(Port, <<"dmanon">>, <<"draft/message-redaction">>),
    Anon2 = client(Port, <<"dmanon2">>, <<"echo-message message-tags">>),
    %% Account-less and logged-in senders cannot redact each other.
    _ = cmd(Anon, <<"JOIN #rx">>),
    _ = cmd(One, <<"JOIN #rx">>),
    _ = cmd(Anon2, <<"JOIN #rx">>),
    AnonId = msgid(cmd(Anon2, <<"PRIVMSG #rx :anon">>), <<"PRIVMSG #rx :anon">>),
    OneId = msgid(cmd(One, <<"PRIVMSG #rx :logged">>), <<"PRIVMSG #rx :logged">>),
    ?assert(has(cmd(One, <<"REDACT #rx ", AnonId/binary>>), <<"REDACT_FORBIDDEN">>)),
    ?assert(has(cmd(Anon2, <<"REDACT #rx ", OneId/binary>>), <<"REDACT_FORBIDDEN">>)),
    close(Anon2),
    ?assert(has(cmd(Anon, <<"REDACT dmone xyz">>), <<"FAIL REDACT INVALID_TARGET dmone">>)),
    %% Read markers.
    ?assert(
        has(
            cmd(Anon, <<"MARKREAD #m timestamp=bad">>), <<"FAIL MARKREAD INVALID_PARAMS bad">>
        )
    ),
    ?assert(has(cmd(Anon, <<"MARKREAD #m other">>), <<"FAIL MARKREAD INVALID_PARAMS other">>)),
    OneAgain = sasl_connect(Port, <<"dmone2">>, <<"dmone">>, Caps),
    ?assert(has(cmd(OneAgain, <<"CAP END">>), <<" 001 ">>)),
    _ = cmd(One, <<"JOIN #mark">>),
    _ = cmd(One, <<"MARKREAD #mark timestamp=2030-01-01T00:00:00.000Z">>),
    ?assert(has(sync(OneAgain), <<"MARKREAD #mark timestamp=2030-01-01T00:00:00.000Z">>)),
    ?assert(
        has(cmd(OneAgain, <<"MARKREAD #mark">>), <<"MARKREAD #mark timestamp=2030-01-01T00:00:00">>)
    ),
    _ = cmd(One, <<"MARKREAD #other timestamp=2030-01-01T00:00:00.000Z">>),
    _ = sync(OneAgain),
    _ = cmd(One, <<"RENAME #mark #mark2">>),
    ?assert(
        has(cmd(One, <<"MARKREAD #mark2">>), <<"MARKREAD #mark2 timestamp=2030-01-01T00:00:00">>)
    ),
    lists:foreach(fun close/1, [One, Two, Anon, OneAgain]).

%%% Remote (server-link) IRCv3 paths

remote_paths(Port) ->
    {ok, _} = ircd_account:create(<<"remacct">>, undefined, <<"password1">>, [], undefined),
    Caps =
        <<"batch account-notify setname chghost extended-monitor draft/metadata-2 ",
            "draft/message-redaction draft/read-marker message-tags">>,
    Local = sasl_connect(Port, <<"remloc">>, <<"remacct">>, Caps),
    ?assert(has(cmd(Local, <<"CAP END">>), <<" 001 ">>)),
    Legacy = client(Port, <<"remleg">>, <<>>),
    NoAcct = client(Port, <<"remnoac">>, <<"draft/read-marker">>),
    _ = cmd(Local, <<"JOIN #remote">>),
    _ = cmd(Legacy, <<"JOIN #remote">>),
    _ = cmd(Local, <<"METADATA * SUB avatar topic">>),
    Peer = handshake(Port, ?PEER),
    Call = fun(Prefix, Command, Params) ->
        ircd_state:server_command(?PEER, Prefix, Command, Params)
    end,
    ok = Call(?PEER, <<"NICK">>, [
        <<"farnick">>, <<"1">>, <<"user">>, ?PEER, <<"1">>, <<"+o">>, <<"Far">>
    ]),
    ok = Call(?PEER, <<"NJOIN">>, [<<"#remote">>, <<"farnick">>]),
    ok = Call(?PEER, <<"NICK">>, [<<"farb">>, <<"1">>, <<"user">>, ?PEER, <<"1">>, <<"+">>, <<"B">>]),
    ok = Call(?PEER, <<"NJOIN">>, [<<"#farb">>, <<"farb">>]),
    ok = Call(<<"farb!user@peer.test">>, <<"NICK">>, [<<"farc">>]),
    {ok, _} = ircd_account:create(<<"remother">>, undefined, <<"password1">>, [], undefined),
    Other = sasl_connect(Port, <<"remoth">>, <<"remother">>, <<>>),
    _ = cmd(Other, <<"CAP END">>),
    Far = <<"farnick!user@peer.test">>,
    _ = sync(Local),
    ?assert(has(cmd(Local, <<"MONITOR + farnick">>), <<" 730 remloc :farnick!user@peer.test">>)),
    ?assertMatch(#{oper := <<"farnick">>}, ircd_state_v3:remote_source_info(Far)),
    ?assertEqual(#{}, ircd_state_v3:remote_source_info(<<"ghost!u@h">>)),
    ?assertEqual(#{}, ircd_state_v3:remote_source_info(?PEER)),
    ?assertEqual(#{}, ircd_state_v3:remote_source_info(undefined)),
    %% ACCOUNT, SETNAME, CHGHOST.
    ok = Call(Far, <<"ACCOUNT">>, [<<"faracct">>]),
    ?assert(has(sync(Local), <<":farnick!user@peer.test ACCOUNT faracct">>)),
    ?assert(has(cmd(Local, <<"CHATHISTORY LATEST farnick * 5">>), <<"chathistory farnick">>)),
    ok = Call(Far, <<"SETNAME">>, [<<"Far Away">>]),
    ?assert(has(sync(Local), <<"SETNAME :Far Away">>)),
    ok = Call(Far, <<"CHGHOST">>, [<<"newu">>, <<"new.peer">>]),
    ?assert(has(sync(Local), <<"CHGHOST newu new.peer">>)),
    Rejoined = sync(Legacy),
    ?assert(has(Rejoined, <<"QUIT :Changing hostname">>)),
    ?assert(has(Rejoined, <<":farnick!newu@new.peer JOIN #remote">>)),
    Far2 = <<"farnick!newu@new.peer">>,
    %% Error replies for malformed or unknown sources.
    ?assertEqual({error, unknown_remote_source}, Call(<<"ghost!u@h">>, <<"ACCOUNT">>, [<<"a">>])),
    ?assertEqual({error, unknown_remote_source}, Call(Far, <<"SETNAME">>, [<<"stale">>])),
    ?assertEqual(
        {error, unknown_remote_source}, Call(<<"farnick">>, <<"CHGHOST">>, [<<"u">>, <<"h">>])
    ),
    ?assertEqual(
        {error, invalid_chghost_message}, Call(Far2, <<"CHGHOST">>, [<<"bad!u">>, <<"h">>])
    ),
    ?assertEqual(
        {error, invalid_account_message}, ircd_state_v3:receive_remote_account(?PEER, Far2, [])
    ),
    ?assertEqual(
        {error, invalid_setname_message}, ircd_state_v3:receive_remote_setname(?PEER, Far2, [])
    ),
    ?assertEqual(
        {error, invalid_chghost_message},
        ircd_state_v3:receive_remote_chghost(?PEER, Far2, [<<"u">>])
    ),
    ?assertEqual(
        {error, unknown_remote_source},
        ircd_state_v3:receive_remote_account(<<"other.test">>, Far2, [<<"x">>])
    ),
    %% Metadata of remote users and shared channels.
    ok = Call(Far2, <<"METADATA">>, [<<"farnick">>, <<"avatar">>, <<"*">>, <<"far.png">>]),
    ?assert(has(sync(Local), <<"METADATA farnick avatar * :far.png">>)),
    ?assert(has(cmd(Local, <<"METADATA farnick GET avatar">>), <<"farnick avatar * :far.png">>)),
    ?assert(has(cmd(Local, <<"METADATA farnick LIST">>), <<"farnick avatar * :far.png">>)),
    ?assert(
        has(cmd(Local, <<"METADATA farnick SET avatar :x">>), <<"FAIL METADATA KEY_NO_PERMISSION">>)
    ),
    ok = Call(?PEER, <<"METADATA">>, [<<"#remote">>, <<"topic">>, <<"*">>, <<"green">>]),
    ?assert(has(sync(Local), <<"METADATA #remote topic * :green">>)),
    ok = Call(?PEER, <<"METADATA">>, [<<"#remote">>, <<"topic">>, <<"*">>]),
    ok = Call(?PEER, <<"METADATA">>, [<<"#nolocal">>, <<"topic">>, <<"*">>, <<"x">>]),
    ?assertEqual(
        {error, invalid_metadata_key},
        ircd_state_meta:remote_channel_change(<<"#remote">>, <<"Bad!">>, none, ?PEER)
    ),
    ?assertEqual(
        {error, invalid_metadata_key},
        ircd_state_meta:remote_user_change(<<"farnick">>, <<"Bad!">>, none, Far2)
    ),
    ?assertEqual(
        {error, unknown_metadata_target},
        ircd_state_meta:remote_user_change(<<"ghost">>, <<"avatar">>, none, Far2)
    ),
    %% A remote nick change moves the metadata; removal clears it.
    ok = Call(Far2, <<"NICK">>, [<<"farnew">>]),
    _ = sync(Local),
    ?assert(has(cmd(Local, <<"METADATA farnew GET avatar">>), <<"farnew avatar * :far.png">>)),
    Far3 = <<"farnew!newu@new.peer">>,
    ok = Call(Far3, <<"METADATA">>, [<<"farnew">>, <<"avatar">>, <<"*">>]),
    ?assert(has(sync(Local), <<"METADATA farnew avatar *">>)),
    %% Remote REDACT.
    ok = Call(Far3, <<"REDACT">>, [<<"#remote">>, <<"someid">>, <<"why">>]),
    ?assert(has(sync(Local), <<"REDACT #remote someid :why">>)),
    %% A peer may only redact for a remote user who is on that channel.
    ?assertEqual(
        {error, remote_user_not_on_channel},
        Call(Far3, <<"REDACT">>, [<<"#nochannel">>, <<"someid">>])
    ),
    ?assertEqual(
        {error, invalid_redact_message},
        ircd_state_history:receive_remote_redact(?PEER, Far3, [<<"#remote">>])
    ),
    %% Remote read markers only move forward.
    ok = Call(?PEER, <<"MARKREAD">>, [<<"remacct">>, <<"#remote">>, <<"1900000000000">>]),
    ?assert(has(sync(Local), <<"MARKREAD #remote timestamp=">>)),
    ?assertNot(has(sync(NoAcct), <<"MARKREAD #remote">>)),
    ?assertEqual(unchanged, ircd_state_history:remote_marker(<<"remacct">>, <<"#remote">>, 1)),
    %% A second peer receives remote accounts in its burst.
    ok = Call(Far3, <<"ACCOUNT">>, [<<"*">>]),
    ok = Call(Far3, <<"ACCOUNT">>, [<<"faracct">>]),
    Burst = handshake_burst(Port, <<"peer2.test">>),
    ?assert(has(Burst, <<":farnew!newu@new.peer ACCOUNT faracct">>)),
    ?assert(has(Burst, <<"ACCOUNT remacct">>)),
    ok = Call(Far3, <<"QUIT">>, [<<"bye">>]),
    _ = sync(Local),
    close(Peer),
    lists:foreach(fun close/1, [Local, Legacy, NoAcct, Other]).

handshake(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    _ = expect(Sock, <<"SERVER irc.test">>),
    peer_sync(Sock),
    Sock.

%% Link a peer and return what it received up to a PONG after the burst.
handshake_burst(Port, Name) ->
    Sock = connect(Port),
    send(Sock, <<"PASS linksecret 0210 |">>),
    send(Sock, <<"SERVER ", Name/binary, " 1 1 :", Name/binary>>),
    Burst = peer_sync(Sock),
    close(Sock),
    Burst.

peer_sync(Sock) ->
    Token = <<"peer", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    send(Sock, <<"PING ", Token/binary>>),
    recv_until(Sock, fun(Line) -> has(Line, <<"PONG">>) andalso has(Line, Token) end).

%%% Second configuration: registration disabled, no history, UTF8ONLY

restricted_test_() ->
    {timeout, 120, fun restricted/0}.

restricted() ->
    with_server(restricted_config, fun(Port, _Dir) ->
        S = connect(Port),
        send(S, <<"NICK restr1">>),
        ?assert(
            has(
                cmd(S, <<"REGISTER * * password1">>),
                <<"FAIL REGISTER TEMPORARILY_UNAVAILABLE restr1">>
            )
        ),
        close(S),
        {ok, _} = ircd_account:create(<<"nohist1">>, undefined, <<"password1">>, [], undefined),
        {ok, _} = ircd_account:create(<<"nohist2">>, undefined, <<"password1">>, [], undefined),
        Caps = <<"setname">>,
        A = sasl_connect(Port, <<"nohist1">>, <<"nohist1">>, Caps),
        _ = cmd(A, <<"CAP END">>),
        B = sasl_connect(Port, <<"nohist2">>, <<"nohist2">>, Caps),
        _ = cmd(B, <<"CAP END">>),
        _ = cmd(A, <<"JOIN #nohist">>),
        _ = cmd(B, <<"JOIN #nohist">>),
        _ = cmd(A, <<"PRIVMSG #nohist :not kept">>),
        _ = cmd(A, <<"PRIVMSG nohist2 :not kept either">>),
        ?assert(has(sync(B), <<"not kept either">>)),
        ?assert(has(cmd(A, <<"SETNAME :Valid name">>), <<"SETNAME :Valid name">>)),
        ?assert(has(cmd(A, <<"SETNAME :", 16#ff, "bad">>), <<"FAIL SETNAME INVALID_UTF8">>)),
        close(A),
        close(B)
    end).

%%% Third configuration: REGISTER only after connecting, email required,
%%% channel retention (history replay on join).

retention_test_() ->
    {timeout, 120, fun retention/0}.

retention() ->
    with_server(retention_config, fun(Port, _Dir) ->
        S = connect(Port),
        send(S, <<"NICK early1">>),
        ?assert(
            has(
                cmd(S, <<"REGISTER * e@example.org password1">>),
                <<"FAIL REGISTER COMPLETE_CONNECTION_REQUIRED early1">>
            )
        ),
        send(S, <<"USER early1 0 * :E">>),
        _ = sync(S),
        ?assert(
            has(cmd(S, <<"REGISTER * * password1">>), <<"FAIL REGISTER INVALID_EMAIL early1">>)
        ),
        ?assert(
            has(cmd(S, <<"REGISTER * e@example.org password1">>), <<"REGISTER SUCCESS early1">>)
        ),
        _ = cmd(S, <<"JOIN #keep">>),
        _ = cmd(S, <<"PRIVMSG #keep :remember me">>),
        _ = cmd(S, <<"TOPIC #keep :kept topic">>),
        Joiner = client(Port, <<"joiner1">>, <<"batch server-time">>),
        Replay = cmd(Joiner, <<"JOIN #keep">>),
        ?assert(has(Replay, <<"chathistory #keep">>)),
        ?assert(has(Replay, <<"PRIVMSG #keep :remember me">>)),
        Events = client(Port, <<"joiner2">>, <<"batch draft/event-playback">>),
        ?assert(has(cmd(Events, <<"JOIN #keep">>), <<"TOPIC #keep :kept topic">>)),
        lists:foreach(fun close/1, [S, Joiner, Events])
    end).

%%% Server lifecycle and configuration

with_server(Kind, Fun) ->
    Dir = filename:join(
        "/tmp", "ircd-cov-v3-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(Kind, Dir, Db)),
    _ = application:stop(ircd),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    try
        Fun(listener_port(), Dir)
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

config(Kind, Dir, Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,">>,
        <<"\"log_level\":\"critical\",\"log_format\":\"text\",\"mnesia_dir\":\"">>,
        Db,
        <<"\",">>,
        extra(Kind, Dir),
        <<"}">>
    ]).

extra(main_config, Dir) ->
    Code = filename:join(Dir, "code"),
    [
        <<"\"operators\":[{\"name\":\"oper\",\"password\":\"opersecret\"}],">>,
        <<"\"server_links\":[">>,
        <<"{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false},">>,
        <<"{\"name\":\"peer2.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false}],">>,
        <<"\"webirc\":[{\"password\":\"gatepass\",\"hosts\":[\"127.0.0.1\"]}],">>,
        <<"\"monitor_limit\":60,\"multiclient\":true,\"account_rejoin\":true,">>,
        <<"\"history_limit\":50,">>,
        <<"\"account_verification\":{\"command\":[\"/bin/sh\",\"-c\",">>,
        <<"\"printf %s \\\"$IRCD_CODE\\\" > ">>,
        Code,
        <<"; echo sent; exit 3\"],\"ttl\":60}">>
    ];
extra(restricted_config, _Dir) ->
    <<"\"account_registration\":false,\"chathistory\":false,\"utf8_only\":true">>;
extra(retention_config, _Dir) ->
    [
        <<"\"account_registration_before_connect\":false,">>,
        <<"\"account_registration_email_required\":true,\"retention\":\"channels\"">>
    ].

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    {ok, {_, Port}} = inet:sockname(sys:get_state(Pid)),
    Port.

%%% Socket helpers. Replies are synchronised with a PING marker: client
%%% commands are processed in order by ircd_state, so every reply to earlier
%%% commands arrives before the matching PONG.

client(Port, Nick, Caps) ->
    S = connect(Port),
    case Caps of
        <<>> -> ok;
        _ -> send(S, <<"CAP REQ :", Caps/binary>>)
    end,
    send(S, <<"NICK ", Nick/binary>>),
    send(S, <<"USER ", Nick/binary, " 0 * :Real ", Nick/binary>>),
    case Caps of
        <<>> -> ok;
        _ -> send(S, <<"CAP END">>)
    end,
    Welcome = sync(S),
    ?assert(has(Welcome, <<" 001 ">>)),
    S.

connect(Port) ->
    {ok, S} = gen_tcp:connect(
        "127.0.0.1", Port, [binary, {active, false}, {packet, line}, {buffer, 65536}]
    ),
    S.

close(S) ->
    gen_tcp:close(S).

send(S, Line) ->
    ok = gen_tcp:send(S, [Line, <<"\r\n">>]).

cmd(S, Line) ->
    send(S, Line),
    sync(S).

sync(S) ->
    Token = <<"cov", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    send(S, <<"PING ", Token/binary>>),
    recv_until(S, fun(Line) -> has(Line, <<"PONG">>) andalso has(Line, Token) end).

expect(S, Needle) ->
    recv_until(S, fun(Line) -> has(Line, Needle) end).

recv_until(S, Pred) ->
    recv_until(S, Pred, [], erlang:monotonic_time(millisecond) + 5000).

recv_until(S, Pred, Acc, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case gen_tcp:recv(S, 0, Left) of
        {ok, <<_/binary>> = Line} ->
            case Pred(Line) of
                true -> iolist_to_binary(lists:reverse([Line | Acc]));
                false -> recv_until(S, Pred, [Line | Acc], Deadline)
            end;
        {error, Reason} ->
            erlang:error({recv_failed, Reason, iolist_to_binary(lists:reverse(Acc))})
    end.

until_closed(S) ->
    until_closed(S, []).

until_closed(S, Acc) ->
    case gen_tcp:recv(S, 0, 5000) of
        {ok, Line} -> until_closed(S, [Line | Acc]);
        {error, closed} -> iolist_to_binary(lists:reverse(Acc))
    end.

wait_closed(S) ->
    _ = until_closed(S),
    close(S).

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

lines(Bin) ->
    binary:split(Bin, <<"\r\n">>, [global, trim_all]).

count_lines(Bin, Needle) ->
    length([Line || Line <- lines(Bin), has(Line, Needle)]).
