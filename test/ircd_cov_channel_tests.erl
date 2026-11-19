-module(ircd_cov_channel_tests).
-include_lib("eunit/include/eunit.hrl").

%% Live coverage of channel management (RFC 2811) and client identity
%% (RFC 2812 3.1, 3.2, 3.1.5). One server instance is shared by the tests in
%% a fixture; each test uses its own nicknames and channel names.

channel_test_() ->
    {setup, fun start_main/0, fun stop/1, fun(#{port := Port}) ->
        [
            {timeout, 60, fun() -> join_restrictions(Port) end},
            {timeout, 60, fun() -> mode_parsing(Port) end},
            {timeout, 60, fun() -> speaking_rules(Port) end},
            {timeout, 60, fun() -> kick_topic_part(Port) end},
            {timeout, 60, fun() -> invite_and_knock(Port) end},
            {timeout, 60, fun() -> visibility(Port) end},
            {timeout, 60, fun() -> special_channels(Port) end},
            {timeout, 60, fun() -> safe_channel_reop(Port) end},
            {timeout, 60, fun() -> user_modes(Port) end},
            {timeout, 60, fun() -> nick_changes(Port) end},
            {timeout, 60, fun() -> registration_errors(Port) end},
            {timeout, 60, fun() -> rename(Port) end},
            {timeout, 60, fun() -> remote_channels(Port) end},
            {timeout, 60, fun() -> predefined(Port) end},
            {timeout, 60, fun() -> capabilities_and_masks(Port) end}
        ]
    end}.

password_test_() ->
    {setup, fun() -> start(<<"\"client_password\":\"letmein\",">>) end, fun stop/1, fun(
        #{port := Port}
    ) ->
        [{timeout, 60, fun() -> client_password(Port) end}]
    end}.

%% --- JOIN restrictions (RFC 2811 4.2, RFC 2812 3.2.1) ----------------------

join_restrictions(Port) ->
    A = client(Port, <<"jr_alice">>),
    B = client(Port, <<"jr_bob">>),
    C = client(Port, <<"jr_carol">>),
    D = client(Port, <<"jr_dave">>),
    join(A, <<"#jr">>),
    %% Channel key.
    cmd(A, <<"MODE #jr +k sesame">>, <<"MODE #jr +k sesame">>),
    want(cmd(B, <<"JOIN #jr">>, <<" 475 ">>), <<"#jr :Cannot join channel (+k)">>),
    want(cmd(B, <<"JOIN #jr wrong">>, <<" 475 ">>), <<" 475 ">>),
    want(cmd(B, <<"JOIN #jr sesame">>, <<" 366 ">>), <<"JOIN #jr">>),
    %% Non-member sees the key masked in RPL_CHANNELMODEIS, a member sees it.
    want(cmd(C, <<"MODE #jr">>, <<" 329 ">>), <<" 324 jr_carol #jr +k *">>),
    want(cmd(B, <<"MODE #jr">>, <<" 329 ">>), <<" 324 jr_bob #jr +k sesame">>),
    cmd(A, <<"MODE #jr -k sesame">>, <<"MODE #jr -k *">>),
    %% Channel limit.
    cmd(A, <<"MODE #jr +l 2">>, <<"MODE #jr +l 2">>),
    want(cmd(C, <<"MODE #jr">>, <<" 329 ">>), <<"+l 2">>),
    want(cmd(C, <<"JOIN #jr">>, <<" 471 ">>), <<"Cannot join channel (+l)">>),
    cmd(A, <<"MODE #jr -l">>, <<"MODE #jr -l">>),
    %% Invite-only, then INVITE, then the invite exception list.
    cmd(A, <<"MODE #jr +i">>, <<"MODE #jr +i">>),
    want(cmd(C, <<"JOIN #jr">>, <<" 473 ">>), <<"Cannot join channel (+i)">>),
    Invite = cmd(A, <<"INVITE jr_carol #jr">>, <<" 341 ">>),
    want(Invite, <<" 341 jr_alice jr_carol #jr">>),
    want(recv_until(C, <<"INVITE">>), <<"INVITE jr_carol #jr">>),
    want(cmd(C, <<"JOIN #jr">>, <<" 366 ">>), <<"JOIN #jr">>),
    cmd(A, <<"MODE #jr +I jr_dave!*@*">>, <<"+I jr_dave!*@*">>),
    want(cmd(D, <<"JOIN #jr">>, <<" 366 ">>), <<"JOIN #jr">>),
    cmd(D, <<"PART #jr">>, <<"PART #jr">>),
    %% The ban list is readable by anyone; exception lists are op-only.
    want(cmd(B, <<"MODE #jr +I">>, <<" 482 ">>), <<"You're not channel operator">>),
    want(cmd(B, <<"MODE #jr +b">>, <<" 368 ">>), <<" 368 jr_bob #jr :End of channel ban">>),
    Invites = cmd(A, <<"MODE #jr +I">>, <<" 347 ">>),
    want(Invites, <<" 346 jr_alice #jr jr_dave!*@*">>),
    cmd(A, <<"MODE #jr -iI jr_dave!*@*">>, <<"MODE #jr -iI jr_dave!*@*">>),
    %% Ban and ban exception.
    cmd(A, <<"MODE #jr +b jr_dave!*@*">>, <<"+b jr_dave!*@*">>),
    want(cmd(D, <<"JOIN #jr">>, <<" 474 ">>), <<"Cannot join channel (+b)">>),
    cmd(A, <<"MODE #jr +e jr_da?e!*@*">>, <<"+e jr_da?e!*@*">>),
    want(cmd(D, <<"JOIN #jr">>, <<" 366 ">>), <<"JOIN #jr">>),
    Bans = cmd(A, <<"MODE #jr +b">>, <<" 368 ">>),
    want(Bans, <<" 367 jr_alice #jr jr_dave!*@*">>),
    want(Bans, <<"End of channel ban list">>),
    Exceptions = cmd(A, <<"MODE #jr +e">>, <<" 349 ">>),
    want(Exceptions, <<" 348 jr_alice #jr jr_da?e!*@*">>),
    cmd(A, <<"MODE #jr -be jr_dave!*@* jr_da?e!*@*">>, <<"-be jr_dave!*@* jr_da?e!*@*">>),
    ?assertNot(has(cmd(A, <<"MODE #jr +b">>, <<" 368 ">>), <<" 367 ">>)),
    want(cmd(A, <<"MODE #nochan +b">>, <<" 403 ">>), <<"#nochan :No such channel">>),
    %% Joining a channel twice is a no-op; a bad name is 403.
    ?assertNot(has(cmd(A, <<"JOIN #jr">>, <<"PONG">>), <<"JOIN #jr">>)),
    want(cmd(A, <<"JOIN bad">>, <<" 403 ">>), <<"bad :No such channel">>),
    %% JOIN with several channels and keys.
    join(A, <<"#jr2">>),
    cmd(A, <<"MODE #jr2 +k two">>, <<"+k two">>),
    Multi = cmd(C, <<"JOIN #jr3,#jr2 x,two">>, <<"366 jr_carol #jr2">>),
    want(Multi, <<"JOIN #jr3">>),
    want(Multi, <<"JOIN #jr2">>),
    %% JOIN 0 parts every channel.
    Zero = cmd(C, <<"JOIN 0">>, <<"PART #jr2">>),
    want(Zero, <<"PART #jr">>),
    close_all([A, B, C, D]).

%% --- MODE parsing (RFC 2811 4, RFC 2812 3.2.3) ------------------------------

mode_parsing(Port) ->
    A = client(Port, <<"mp_alice">>),
    B = client(Port, <<"mp_bob">>),
    O = client(Port, <<"mp_out">>),
    join(A, <<"#mp">>),
    join(B, <<"#mp">>),
    want(cmd(A, <<"MODE #mp +Z">>, <<" 472 ">>), <<" 472 mp_alice Z :">>),
    %% `r` and `a` exist only on safe (and, for `a`, local) channels: 472.
    want(cmd(A, <<"MODE #mp +r">>, <<" 472 ">>), <<"Reop mode is only available on safe">>),
    want(
        cmd(A, <<"MODE #mp +a">>, <<" 472 ">>),
        <<"Anonymous mode is only available on local and safe">>
    ),
    want(cmd(A, <<"MODE #mp +q">>, <<" 481 ">>), <<"Quiet mode is server only">>),
    want(cmd(A, <<"MODE #mp +k">>, <<" 461 ">>), <<"MODE :Not enough parameters">>),
    want(cmd(A, <<"MODE #mp +l">>, <<" 461 ">>), <<" 461 ">>),
    want(cmd(A, <<"MODE #mp +o">>, <<" 461 ">>), <<" 461 ">>),
    want(cmd(A, <<"MODE #mp +l zero">>, <<" 696 ">>), <<"#mp l zero :Invalid channel limit">>),
    want(cmd(A, <<"MODE #mp +l 0">>, <<" 696 ">>), <<"Invalid channel limit">>),
    want(cmd(A, <<"MODE #mp +l :x y">>, <<" 696 ">>), <<"#mp l * :">>),
    want(cmd(A, <<"MODE #mp +k a:b">>, <<" 696 ">>), <<"#mp k * :Invalid channel key">>),
    Long = binary:copy(<<"k">>, 65),
    want(cmd(A, <<"MODE #mp +k ", Long/binary>>, <<" 696 ">>), <<"Invalid channel key">>),
    want(cmd(A, <<"MODE #mp +o mp_ghost">>, <<" 401 ">>), <<"mp_ghost :No such nick">>),
    want(cmd(A, <<"MODE #mp +v mp_out">>, <<" 441 ">>), <<"mp_out #mp :They aren't">>),
    want(cmd(B, <<"MODE #mp +m">>, <<" 482 ">>), <<"#mp :You're not channel operator">>),
    want(cmd(O, <<"MODE #nope +m">>, <<" 403 ">>), <<"#nope :No such channel">>),
    %% Several changes in one command are announced as one line.
    %% Removing an unset flag (`-n`) is dropped from the announcement.
    Many = cmd(A, <<"MODE #mp +ov-n+mi mp_bob mp_bob">>, <<"MODE #mp">>),
    want(Many, <<"MODE #mp +ovmi mp_bob mp_bob">>),
    want(recv_until(B, <<"MODE #mp">>), <<"+ovmi">>),
    %% A no-op change produces no MODE line.
    ?assertNot(has(cmd(A, <<"MODE #mp +i">>, <<"PONG">>), <<"MODE #mp">>)),
    cmd(A, <<"MODE #mp -ov+K mp_bob mp_bob">>, <<"MODE #mp -ov+K">>),
    %% Private and secret replace each other.
    cmd(A, <<"MODE #mp +p">>, <<"MODE #mp +p">>),
    cmd(A, <<"MODE #mp +s">>, <<"MODE #mp +s">>),
    want(cmd(A, <<"MODE #mp">>, <<" 329 ">>), <<"+Kims">>),
    cmd(A, <<"MODE #mp -s">>, <<"MODE #mp -s">>),
    %% Key and limit appear with their parameters, and a key change stays
    %% out of the announced history but still reaches members.
    cmd(A, <<"MODE #mp +kl pw 5">>, <<"MODE #mp +kl pw 5">>),
    want(cmd(A, <<"MODE #mp">>, <<" 329 ">>), <<"+Kimkl pw 5">>),
    close_all([A, B, O]).

%% --- PRIVMSG and NOTICE restrictions (RFC 2811 4.2.3, 4.2.4) ---------------

speaking_rules(Port) ->
    A = client(Port, <<"sp_alice">>),
    B = client(Port, <<"sp_bob">>),
    C = client(Port, <<"sp_carol">>),
    O = client(Port, <<"sp_out">>),
    join(A, <<"#sp">>),
    join(B, <<"#sp">>),
    join(C, <<"#sp">>),
    %% +n: an outsider gets 404, NOTICE gets nothing.
    cmd(A, <<"MODE #sp +n">>, <<"MODE #sp +n">>),
    want(cmd(O, <<"PRIVMSG #sp :hi">>, <<" 404 ">>), <<"#sp :Cannot send to channel">>),
    ?assertNot(has(cmd(O, <<"NOTICE #sp :hi">>, <<"PONG">>), <<" 404 ">>)),
    cmd(A, <<"MODE #sp -n">>, <<"MODE #sp -n">>),
    cmd(O, <<"PRIVMSG #sp :from outside">>, <<"PONG">>),
    want(recv_until(B, <<"from outside">>), <<":sp_out!">>),
    %% +m: only voice and operators speak.
    cmd(A, <<"MODE #sp +mv sp_bob">>, <<"MODE #sp +mv sp_bob">>),
    want(cmd(C, <<"PRIVMSG #sp :muted">>, <<" 404 ">>), <<" 404 ">>),
    cmd(B, <<"PRIVMSG #sp :voiced">>, <<"PONG">>),
    want(recv_until(C, <<"voiced">>), <<"PRIVMSG #sp :voiced">>),
    cmd(A, <<"MODE #sp -m">>, <<"MODE #sp -m">>),
    %% A banned member cannot speak unless voiced.
    cmd(A, <<"MODE #sp +b sp_carol!*@*">>, <<"+b sp_carol">>),
    want(cmd(C, <<"PRIVMSG #sp :banned">>, <<" 404 ">>), <<" 404 ">>),
    cmd(B, <<"PRIVMSG #sp :still">>, <<"PONG">>),
    want(recv_until(A, <<"still">>), <<"PRIVMSG #sp :still">>),
    %% Errors for the generic message forms.
    want(cmd(A, <<"PRIVMSG">>, <<" 411 ">>), <<"No recipient given">>),
    want(cmd(A, <<"PRIVMSG #sp">>, <<" 412 ">>), <<"No text to send">>),
    want(cmd(A, <<"PRIVMSG #sp :">>, <<" 412 ">>), <<"No text to send">>),
    want(cmd(A, <<"PRIVMSG sp_ghost :x">>, <<" 401 ">>), <<"sp_ghost :No such">>),
    TooMany = cmd(A, <<"PRIVMSG a1,a2,a3,a4,a5 :x">>, <<" 407 ">>),
    want(TooMany, <<"a5 :Too many recipients">>),
    %% Direct message with AWAY reply.
    cmd(B, <<"AWAY :lunch">>, <<" 306 ">>),
    want(cmd(A, <<"PRIVMSG sp_bob :hey">>, <<" 301 ">>), <<"sp_bob :lunch">>),
    want(recv_until(B, <<"hey">>), <<"PRIVMSG sp_bob :hey">>),
    close_all([A, B, C, O]).

%% --- KICK, TOPIC, PART (RFC 2812 3.2.2, 3.2.4, 3.2.8) ----------------------

kick_topic_part(Port) ->
    A = client(Port, <<"kt_alice">>),
    B = client(Port, <<"kt_bob">>),
    C = client(Port, <<"kt_carol">>),
    O = client(Port, <<"kt_out">>),
    join(A, <<"#kt">>),
    join(B, <<"#kt">>),
    join(C, <<"#kt">>),
    join(A, <<"#kt2">>),
    join(B, <<"#kt2">>),
    %% KICK errors.
    want(cmd(A, <<"KICK #kt">>, <<" 461 ">>), <<"KICK :Not enough parameters">>),
    want(cmd(A, <<"KICK #a,#b x">>, <<" 461 ">>), <<"Invalid channel/user list">>),
    want(cmd(A, <<"KICK #none x">>, <<" 403 ">>), <<"#none :No such channel">>),
    want(cmd(O, <<"KICK #kt kt_bob">>, <<" 442 ">>), <<"#kt :You're not on">>),
    want(cmd(B, <<"KICK #kt kt_carol">>, <<" 482 ">>), <<"You're not channel operator">>),
    Missing = cmd(A, <<"KICK #kt kt_ghost,kt_out">>, <<" 441 ">>),
    want(Missing, <<" 401 kt_alice kt_ghost">>),
    want(Missing, <<"kt_out #kt :They aren't on that channel">>),
    %% KICK with and without reason, and the pairwise channel list form.
    want(cmd(A, <<"KICK #kt kt_carol :behave">>, <<"KICK">>), <<"KICK #kt kt_carol :behave">>),
    want(recv_until(C, <<"KICK">>), <<"KICK #kt kt_carol :behave">>),
    Pair = cmd(A, <<"KICK #kt,#kt2 kt_bob,kt_bob">>, <<"KICK #kt2">>),
    want(Pair, <<"KICK #kt kt_bob :kt_alice">>),
    %% TOPIC.
    join(B, <<"#kt">>),
    cmd(A, <<"MODE #kt +t">>, <<"MODE #kt +t">>),
    want(cmd(A, <<"TOPIC #kt">>, <<" 331 ">>), <<"#kt :No topic is set">>),
    want(cmd(B, <<"TOPIC #kt :bob topic">>, <<" 482 ">>), <<"not channel operator">>),
    want(cmd(O, <<"TOPIC #kt :x">>, <<" 442 ">>), <<"#kt :You're not on">>),
    want(cmd(A, <<"TOPIC #kt :the topic">>, <<"TOPIC #kt">>), <<":the topic">>),
    Query = cmd(O, <<"TOPIC #kt">>, <<" 333 ">>),
    want(Query, <<" 332 kt_out #kt :the topic">>),
    want(Query, <<" 333 kt_out #kt kt_alice!">>),
    %% Joining a channel with a topic sends 332 and 333.
    want(cmd(O, <<"JOIN #kt">>, <<" 366 ">>), <<" 332 kt_out #kt :the topic">>),
    cmd(O, <<"PART #kt">>, <<"PART">>),
    cmd(A, <<"MODE #kt -t">>, <<"MODE #kt -t">>),
    want(cmd(B, <<"TOPIC #kt :bob topic">>, <<"TOPIC #kt">>), <<":bob topic">>),
    cmd(A, <<"MODE #kt +s">>, <<"MODE #kt +s">>),
    want(cmd(O, <<"TOPIC #kt">>, <<" 403 ">>), <<"#kt :No such channel">>),
    want(cmd(O, <<"TOPIC #void">>, <<" 403 ">>), <<"#void :No such channel">>),
    %% PART with reason, and the error cases.
    want(cmd(O, <<"PART #kt">>, <<" 442 ">>), <<"You're not on that channel">>),
    want(cmd(O, <<"PART #void">>, <<" 403 ">>), <<"#void :No such channel">>),
    want(cmd(B, <<"PART #kt :see you">>, <<"PART">>), <<"PART #kt :see you">>),
    want(recv_until(A, <<"PART #kt">>), <<":see you">>),
    close_all([A, B, C, O]).

%% --- INVITE and KNOCK (RFC 2812 3.2.7) -------------------------------------

invite_and_knock(Port) ->
    A = client(Port, <<"ik_alice">>),
    B = client(Port, <<"ik_bob">>),
    C = client(Port, <<"ik_carol">>),
    join(A, <<"#ik">>),
    join(B, <<"#ik">>),
    want(cmd(A, <<"INVITE">>, <<" 461 ">>), <<"INVITE :Not enough parameters">>),
    want(cmd(A, <<"INVITE ik_ghost #ik">>, <<" 401 ">>), <<"ik_ghost :No such nick">>),
    want(cmd(A, <<"INVITE ik_bob #ik">>, <<" 443 ">>), <<"ik_bob #ik :is already on">>),
    want(cmd(C, <<"INVITE ik_carol #ik">>, <<" 442 ">>), <<"#ik :You're not on">>),
    cmd(A, <<"MODE #ik +i">>, <<"MODE #ik +i">>),
    want(cmd(B, <<"INVITE ik_carol #ik">>, <<" 482 ">>), <<"not channel operator">>),
    %% Invitation to a channel that does not exist, both parameter orders.
    want(cmd(A, <<"INVITE ik_carol #nothere">>, <<" 341 ">>), <<"ik_carol #nothere">>),
    want(recv_until(C, <<"#nothere">>), <<"INVITE ik_carol #nothere">>),
    want(cmd(A, <<"INVITE #gone ik_carol">>, <<"INVITE">>), <<"INVITE #gone ik_carol">>),
    want(cmd(A, <<"INVITE #gone ik_ghost">>, <<" 401 ">>), <<"ik_ghost :No such nick">>),
    %% Reversed order on an existing channel behaves like the RFC order.
    cmd(B, <<"AWAY :out">>, <<" 306 ">>),
    cmd(B, <<"PART #ik">>, <<"PART">>),
    Away = cmd(A, <<"INVITE #ik ik_bob">>, <<" 301 ">>),
    want(Away, <<" 341 ik_alice ik_bob #ik">>),
    want(Away, <<" 301 ik_alice ik_bob :out">>),
    want(cmd(B, <<"JOIN #ik">>, <<" 366 ">>), <<"JOIN #ik">>),
    %% KNOCK.
    want(cmd(C, <<"KNOCK">>, <<" 461 ">>), <<"KNOCK :Not enough parameters">>),
    want(cmd(C, <<"KNOCK #void">>, <<" 403 ">>), <<"#void :No such channel">>),
    want(cmd(A, <<"KNOCK #ik">>, <<" 714 ">>), <<"#ik :You're already on that channel">>),
    want(cmd(C, <<"KNOCK #ik :let me in">>, <<"PONG">>), <<"PONG">>),
    want(recv_until(A, <<"KNOCK">>), <<"KNOCK #ik :let me in">>),
    ?assertNot(has(sync(B), <<"KNOCK">>)),
    want(cmd(C, <<"KNOCK #ik">>, <<"PONG">>), <<"PONG">>),
    want(recv_until(A, <<"KNOCK">>), <<"KNOCK #ik">>),
    cmd(A, <<"MODE #ik +K">>, <<"MODE #ik +K">>),
    want(cmd(C, <<"KNOCK #ik">>, <<" 480 ">>), <<"Cannot knock on channel">>),
    cmd(A, <<"MODE #ik -Ki">>, <<"MODE #ik -Ki">>),
    want(cmd(C, <<"KNOCK #ik">>, <<" 713 ">>), <<"#ik :Channel is open">>),
    cmd(A, <<"MODE #ik +k knockkey">>, <<"+k">>),
    want(cmd(C, <<"KNOCK #ik">>, <<" 480 ">>), <<"Channel is not invite-only">>),
    cmd(A, <<"MODE #ik -k knockkey">>, <<"-k">>),
    cmd(A, <<"MODE #ik +i">>, <<"MODE #ik +i">>),
    cmd(A, <<"PART #ik">>, <<"PART">>),
    want(cmd(C, <<"KNOCK #ik">>, <<" 480 ">>), <<"No channel operators available">>),
    close_all([A, B, C]).

%% --- NAMES and LIST visibility (RFC 2811 4.2.6, 4.2.7, RFC 2812 3.2.5) -----

visibility(Port) ->
    A = client(Port, <<"vi_alice">>),
    B = client(Port, <<"vi_bob">>),
    O = client(Port, <<"vi_out">>),
    Lone = client(Port, <<"vi_lone">>),
    join(A, <<"#vipub">>),
    join(B, <<"#vipub">>),
    join(A, <<"#visec">>),
    join(A, <<"#vipriv">>),
    cmd(A, <<"MODE #visec +s">>, <<"MODE #visec +s">>),
    cmd(A, <<"MODE #vipriv +p">>, <<"MODE #vipriv +p">>),
    cmd(A, <<"MODE #vipub +v vi_bob">>, <<"+v vi_bob">>),
    Public = cmd(O, <<"NAMES #vipub">>, <<" 366 ">>),
    want(Public, <<" 353 vi_out = #vipub :">>),
    want(Public, <<"@vi_alice">>),
    want(Public, <<"+vi_bob">>),
    Secret = cmd(O, <<"NAMES #visec">>, <<" 366 ">>),
    ?assertNot(has(Secret, <<" 353 ">>)),
    want(cmd(A, <<"NAMES #visec">>, <<" 366 ">>), <<" 353 vi_alice @ #visec :@vi_alice">>),
    want(cmd(A, <<"NAMES #vipriv">>, <<" 366 ">>), <<" 353 vi_alice * #vipriv">>),
    ?assertNot(has(cmd(O, <<"NAMES #vipriv">>, <<" 366 ">>), <<" 353 ">>)),
    want(cmd(O, <<"NAMES #nobody">>, <<" 366 ">>), <<"366 vi_out #nobody :End of NAMES">>),
    %% Invisible users are hidden from NAMES unless the requester shares the channel.
    cmd(B, <<"MODE vi_bob +i">>, <<"MODE vi_bob +i">>),
    ?assertNot(has(cmd(O, <<"NAMES #vipub">>, <<" 366 ">>), <<"vi_bob">>)),
    want(cmd(A, <<"NAMES #vipub">>, <<" 366 ">>), <<"+vi_bob">>),
    %% NAMES with no argument lists every visible channel and the users on none.
    All = cmd(O, <<"NAMES">>, <<"366 vi_out * ">>),
    want(All, <<"#vipub :@vi_alice">>),
    ?assertNot(has(All, <<"#visec">>)),
    want(All, <<" 353 vi_out * * :">>),
    want(All, <<"vi_lone">>),
    Mine = cmd(A, <<"NAMES">>, <<"366 vi_alice * ">>),
    want(Mine, <<"#visec">>),
    %% LIST hides secret and private channels from non-members.
    List = cmd(O, <<"LIST">>, <<" 323 ">>),
    want(List, <<" 322 vi_out #vipub 2">>),
    ?assertNot(has(List, <<"#visec">>)),
    ?assertNot(has(List, <<"#vipriv">>)),
    want(cmd(A, <<"LIST #visec">>, <<" 323 ">>), <<" 322 vi_alice #visec 1">>),
    %% A large channel splits RPL_NAMREPLY over several lines.
    Many = [
        client(Port, iolist_to_binary(io_lib:format("vi_bigm~2..0B", [N])))
     || N <- lists:seq(1, 45)
    ],
    lists:foreach(fun(S) -> join(S, <<"#vibig">>) end, Many),
    Big = cmd(O, <<"NAMES #vibig">>, <<" 366 ">>),
    ?assert(count(Big, <<" 353 ">>) >= 2),
    close_all([A, B, O, Lone | Many]).

%% --- Local, modeless, and safe channels (RFC 2811 2.1, 3, 4.2.1) -----------

special_channels(Port) ->
    A = client(Port, <<"sc_alice">>),
    B = client(Port, <<"sc_bob">>),
    %% Modeless `+` channel: nobody is operator, +t is fixed.
    want(join(A, <<"+scplus">>), <<" 353 sc_alice = +scplus :sc_alice">>),
    want(cmd(A, <<"MODE +scplus">>, <<" 324 ">>), <<"+scplus +t">>),
    want(cmd(A, <<"MODE +scplus +m">>, <<" 482 ">>), <<"not channel operator">>),
    %% Local `&` channel with anonymous mode.
    join(A, <<"&scloc">>),
    join(B, <<"&scloc">>),
    cmd(A, <<"MODE &scloc +a">>, <<"MODE &scloc +a">>),
    want(recv_until(B, <<"+a">>), <<"MODE &scloc +a">>),
    cmd(A, <<"PRIVMSG &scloc :masked">>, <<"PONG">>),
    want(recv_until(B, <<"masked">>), <<":anonymous!anonymous@anonymous. PRIVMSG">>),
    Anon = cmd(B, <<"NAMES &scloc">>, <<" 366 ">>),
    want(Anon, <<"&scloc :sc_bob">>),
    ?assertNot(has(Anon, <<"sc_alice">>)),
    want(cmd(A, <<"TOPIC &scloc :anon topic">>, <<"TOPIC">>), <<"anonymous!anonymous">>),
    want(cmd(A, <<"INVITE sc_ghost &scloc">>, <<" 401 ">>), <<" 401 ">>),
    C = client(Port, <<"sc_carol">>),
    join(C, <<"&scloc">>),
    want(recv_until(A, <<"JOIN">>), <<":anonymous!anonymous@anonymous. JOIN">>),
    want(cmd(C, <<"PART &scloc :bye">>, <<"PART">>), <<"PART &scloc">>),
    want(recv_until(A, <<"PART">>), <<":anonymous!anonymous@anonymous. PART">>),
    %% Nick changes are not revealed to anonymous channel members.
    cmd(A, <<"NICK sc_alic2">>, <<"NICK">>),
    ?assertNot(has(sync(B), <<"NICK sc_alic2">>)),
    cmd(A, <<"MODE &scloc -a">>, <<"MODE &scloc -a">>),
    %% A KICK in an anonymous channel hides the operator.
    cmd(A, <<"MODE &scloc +a">>, <<"+a">>),
    want(cmd(A, <<"KICK &scloc sc_bob">>, <<"KICK">>), <<"anonymous!anonymous@anonymous.">>),
    %% Safe channel: created with an id, joined later by short name.
    Joined = join(A, <<"!scsafe">>),
    Safe = safe_name(Joined),
    ?assertEqual(<<"scsafe">>, binary:part(Safe, 6, byte_size(Safe) - 6)),
    want(join(B, <<"!scsafe">>), <<"JOIN ", Safe/binary>>),
    want(join(B, <<"!scsafe">>), <<"PONG">>),
    %% `!!name` with a new short name creates another safe channel.
    Nested = cmd(B, <<"JOIN !", Safe/binary>>, <<" 366 ">>),
    want(Nested, <<"JOIN !">>),
    want(Nested, <<Safe/binary, " :@sc_bob">>),
    want(cmd(B, <<"JOIN !bad,name">>, <<"PONG">>), <<"PONG">>),
    TooLong = binary:copy(<<"x">>, 45),
    want(cmd(B, <<"JOIN !", TooLong/binary>>, <<" 403 ">>), <<"No such channel">>),
    %% Only the creator may set +a and +r; -a is refused on a safe channel.
    cmd(A, <<"MODE ", Safe/binary, " +o sc_bob">>, <<"+o sc_bob">>),
    want(cmd(B, <<"MODE ", Safe/binary, " +r">>, <<" 482 ">>), <<"not channel creator">>),
    want(cmd(B, <<"MODE ", Safe/binary, " +a">>, <<" 482 ">>), <<"not channel creator">>),
    cmd(A, <<"MODE ", Safe/binary, " +ra">>, <<"+ra">>),
    want(cmd(A, <<"MODE ", Safe/binary, " -a">>, <<" 482 ">>), <<"Cannot unset anonymous">>),
    cmd(A, <<"MODE ", Safe/binary, " -r">>, <<"-r">>),
    %% Safe channels outlive their last member.
    cmd(A, <<"PART ", Safe/binary>>, <<"PART">>),
    cmd(B, <<"PART ", Safe/binary>>, <<"PART">>),
    want(cmd(B, <<"MODE ", Safe/binary>>, <<" 324 ">>), <<" 324 ">>),
    %% A safe channel cannot be renamed.
    close_all([A, B, C]).

%% Safe channel with +r: the remaining member is reopped after reop_delay.
safe_channel_reop(Port) ->
    A = client(Port, <<"ro_alice">>),
    B = client(Port, <<"ro_bob">>),
    C = client(Port, <<"ro_carol">>),
    D = client(Port, <<"ro_dave">>),
    Safe = safe_name(join(A, <<"!roreop">>)),
    lists:foreach(fun(S) -> join(S, Safe) end, [B, C, D]),
    cmd(A, <<"MODE ", Safe/binary, " +r">>, <<"+r">>),
    %% The creator may still change modes without operator status. The
    %% channel becomes operatorless, then an operator returns before the
    %% deadline, which clears it on the next reop tick.
    cmd(A, <<"MODE ", Safe/binary, " -o ro_alice">>, <<"-o">>),
    _ = recv_until(A, <<"not expected">>, 1200),
    cmd(A, <<"MODE ", Safe/binary, " +o ro_alice">>, <<"+o">>),
    _ = recv_until(A, <<"not expected">>, 1200),
    ?assertNot(has(sync(B), <<"+o ro_bob">>)),
    %% Without an operator, one remaining member is reopped after reop_delay.
    cmd(A, <<"PART ", Safe/binary>>, <<"PART">>),
    Reop = recv_until(B, <<"MODE ", Safe/binary, " +o ">>, 8000),
    want(Reop, <<"MODE ", Safe/binary, " +o ro_">>),
    _ = recv_until(B, <<"not expected">>, 1200),
    want(cmd(B, <<"NAMES ", Safe/binary>>, <<" 366 ">>), <<"@ro_">>),
    close_all([A, B, C, D]).

%% --- User modes (RFC 2812 3.1.5) --------------------------------------------

user_modes(Port) ->
    A = client(Port, <<"um_alice">>),
    B = client(Port, <<"um_bob">>),
    want(cmd(A, <<"MODE um_alice">>, <<" 221 ">>), <<" 221 um_alice +">>),
    want(cmd(A, <<"MODE um_alice +iw">>, <<"+w">>), <<"MODE um_alice +i">>),
    want(cmd(A, <<"MODE um_alice">>, <<" 221 ">>), <<" 221 um_alice +iw">>),
    ?assertNot(has(cmd(A, <<"MODE um_alice +i">>, <<"PONG">>), <<"MODE um_alice">>)),
    want(cmd(A, <<"MODE um_alice -i">>, <<"MODE">>), <<"MODE um_alice -i">>),
    want(cmd(A, <<"MODE um_alice +o">>, <<" 481 ">>), <<"not an IRC operator">>),
    want(cmd(A, <<"MODE um_alice +x">>, <<" 501 ">>), <<"Unknown MODE flag">>),
    want(cmd(A, <<"MODE um_alice i">>, <<" 501 ">>), <<"Unknown MODE flag">>),
    want(cmd(A, <<"MODE um_bob +i">>, <<" 502 ">>), <<"Cannot change mode for other">>),
    want(cmd(A, <<"MODE um_ghost +i">>, <<" 401 ">>), <<"um_ghost :No such nick">>),
    %% USER mode bit mask 8 sets +i, 4 sets +w.
    C = connect(Port),
    send(C, <<"NICK um_carol">>),
    send(C, <<"USER carol 12 * :Carol">>),
    recv_until(C, <<" 001 ">>),
    sync(C),
    want(cmd(C, <<"MODE um_carol">>, <<" 221 ">>), <<"+iw">>),
    %% Invisible user: WHO-style visibility via NAMES * listing.
    ?assertNot(has(cmd(B, <<"NAMES">>, <<"366 um_bob * ">>), <<"um_carol">>)),
    close_all([A, B, C]).

%% --- NICK (RFC 2812 3.1.2, RFC 1459 case mapping) ---------------------------

nick_changes(Port) ->
    A = client(Port, <<"nc[a]">>),
    B = client(Port, <<"nc_bob">>),
    join(A, <<"#nc">>),
    join(B, <<"#nc">>),
    %% `[]\^` fold to `{}|~`.
    want(cmd(B, <<"NICK NC{A}">>, <<" 433 ">>), <<"NC{A} :Nickname is already in use">>),
    want(cmd(B, <<"NICK nc_bob">>, <<"PONG">>), <<"PONG">>),
    want(cmd(B, <<"NICK">>, <<" 431 ">>), <<"No nickname given">>),
    want(cmd(B, <<"NICK 1bad">>, <<" 432 ">>), <<"1bad :Erroneous nickname">>),
    want(cmd(B, <<"NICK anonymous">>, <<" 432 ">>), <<"Erroneous nickname">>),
    want(cmd(B, <<"NICK toolongnick">>, <<" 432 ">>), <<"Erroneous nickname">>),
    %% A case change of one's own nickname is allowed and seen by members.
    want(cmd(A, <<"NICK NC{a}">>, <<"NICK">>), <<":nc[a]!">>),
    want(recv_until(B, <<"NICK">>), <<"NICK :NC{a}">>),
    cmd(A, <<"NICK nc_al">>, <<"NICK">>),
    want(recv_until(B, <<"NICK">>), <<"NICK :nc_al">>),
    %% Old nickname is held for resource_delay after a change (437).
    Old = cmd(B, <<"NICK nc[a]">>, <<"PONG">>),
    ?assert(has(Old, <<" 437 ">>) orelse has(Old, <<"NICK">>)),
    want(cmd(A, <<"WHOWAS NC{A}">>, <<" 369 ">>), <<" 314 ">>),
    close_all([A, B]).

%% --- Registration errors (RFC 2812 3.1) -------------------------------------

registration_errors(Port) ->
    S = connect(Port),
    want(cmd(S, <<"JOIN #x">>, <<" 451 ">>), <<"You have not registered">>),
    want(cmd(S, <<"USER u 0 *">>, <<" 461 ">>), <<"USER :Not enough parameters">>),
    want(cmd(S, <<"USER u 0 * :">>, <<" 461 ">>), <<"USER :Not enough parameters">>),
    want(cmd(S, <<"USER b@d 0 * :R">>, <<" 468 ">>), <<"Your username is not valid">>),
    want(cmd(S, <<"USER u -1 * :R">>, <<" 461 ">>), <<"Invalid user mode mask">>),
    want(cmd(S, <<"PASS">>, <<" 461 ">>), <<"PASS :Not enough parameters">>),
    want(cmd(S, <<"PING">>, <<" 409 ">>), <<"No origin specified">>),
    send(S, <<"PASS anything">>),
    send(S, <<"NICK re_user">>),
    want(cmd(S, <<"USER u * * :Real">>, <<" 001 ">>), <<" 001 re_user">>),
    sync(S),
    want(cmd(S, <<"PASS again">>, <<" 462 ">>), <<"You may not reregister">>),
    want(cmd(S, <<"USER u 0 * :R">>, <<" 462 ">>), <<"You may not reregister">>),
    %% A nickname is held after QUIT for resource_delay seconds (437).
    T = client(Port, <<"re_quit">>),
    send(T, <<"QUIT :leaving">>),
    want(recv_until(T, <<"ERROR">>), <<"Quit: leaving">>),
    gen_tcp:close(T),
    U = connect(Port),
    want(cmd(U, <<"NICK re_quit">>, <<" 437 ">>), <<"temporarily unavailable">>),
    close_all([S, U]).

%% --- Channel rename (draft/channel-rename) ---------------------------------

rename(Port) ->
    A = client(Port, <<"rn_alice">>),
    B = client(Port, <<"rn_bob">>),
    join(A, <<"#rn">>),
    join(B, <<"#rn">>),
    join(A, <<"#rntaken">>),
    cmd(A, <<"TOPIC #rn :keep">>, <<"TOPIC">>),
    want(cmd(A, <<"RENAME #rn">>, <<" 461 ">>), <<"RENAME :Not enough parameters">>),
    want(cmd(A, <<"RENAME #void #x">>, <<" 403 ">>), <<"#void :No such channel">>),
    want(cmd(B, <<"RENAME #rn #x">>, <<" 482 ">>), <<"not channel operator">>),
    want(cmd(A, <<"RENAME #rn &x">>, <<"FAIL">>), <<"CANNOT_RENAME">>),
    want(cmd(A, <<"RENAME #rn #rntaken">>, <<"FAIL">>), <<"CHANNEL_NAME_IN_USE">>),
    O = client(Port, <<"rn_out">>),
    want(cmd(O, <<"RENAME #rn #x">>, <<" 442 ">>), <<"You're not on that channel">>),
    %% Legacy members see PART then JOIN with topic and names.
    Moved = cmd(A, <<"RENAME #rn #rnnew :moving">>, <<"366 rn_alice #rnnew">>),
    want(Moved, <<"PART #rn :moving">>),
    want(Moved, <<"JOIN #rnnew">>),
    want(Moved, <<" 332 rn_alice #rnnew :keep">>),
    want(recv_until(B, <<"366 rn_bob #rnnew">>), <<"JOIN #rnnew">>),
    ?assertNot(has(cmd(A, <<"RENAME #rnnew #RNNEW">>, <<"PONG">>), <<"PART">>)),
    want(cmd(A, <<"MODE #rnnew">>, <<" 324 ">>), <<"#RNNEW">>),
    close_all([A, B, O]).

%% --- Channels shared with a server link (RFC 2813 4.2) ---------------------

remote_channels(Port) ->
    A = client(Port, <<"rc_alice">>),
    Peer = handshake(Port, <<"peer.test">>),
    sync_peer(Peer),
    send(Peer, <<":peer.test NICK rc_rem 1 user peer.test 1 + :Remote">>),
    send(Peer, <<":rc_rem!user@peer.test JOIN #rcremote">>),
    send(Peer, <<":peer.test TOPIC #rcremote :remote topic">>),
    sync_peer(Peer),
    %% TOPIC and NAMES for a channel that exists only behind the link.
    want(cmd(A, <<"TOPIC #rcremote">>, <<" 332 ">>), <<"#rcremote :remote topic">>),
    want(cmd(A, <<"TOPIC #rcremote :x">>, <<" 442 ">>), <<"You're not on that channel">>),
    want(cmd(A, <<"NAMES #rcremote">>, <<" 366 ">>), <<"rc_rem">>),
    want(cmd(A, <<"NAMES">>, <<"366 rc_alice * ">>), <<"rc_rem">>),
    %% Joining merges with the remote channel and keeps its topic.
    Joined = join(A, <<"#rcremote">>),
    want(Joined, <<"rc_rem">>),
    want(recv_until(Peer, <<"JOIN">>), <<"JOIN">>),
    %% Local channel operations involving a remote user.
    join(A, <<"#rclocal">>),
    want(cmd(A, <<"MODE #rclocal +o rc_rem">>, <<" 441 ">>), <<"rc_rem #rclocal">>),
    Inv = cmd(A, <<"INVITE rc_rem #rclocal">>, <<" 341 ">>),
    want(Inv, <<" 341 rc_alice rc_rem #rclocal">>),
    want(recv_until(Peer, <<"INVITE">>), <<"INVITE rc_rem #rclocal">>),
    want(cmd(A, <<"INVITE rc_rem #rcvoid">>, <<" 403 ">>), <<"#rcvoid :No such">>),
    B = client(Port, <<"rc_bob">>),
    want(cmd(B, <<"INVITE rc_rem #rclocal">>, <<" 442 ">>), <<"not on that channel">>),
    join(B, <<"#rclocal">>),
    cmd(A, <<"MODE #rclocal +i">>, <<"+i">>),
    want(cmd(B, <<"INVITE rc_rem #rclocal">>, <<" 482 ">>), <<"not channel operator">>),
    %% Direct message to the remote user goes over the link.
    cmd(A, <<"PRIVMSG rc_rem :over the link">>, <<"PONG">>),
    want(recv_until(Peer, <<"over the link">>), <<"PRIVMSG rc_rem">>),
    %% A secret remote channel is hidden.
    send(Peer, <<":rc_rem!user@peer.test JOIN #rchidden">>),
    send(Peer, <<":peer.test MODE #rchidden +s">>),
    sync_peer(Peer),
    want(cmd(A, <<"TOPIC #rchidden">>, <<" 403 ">>), <<"No such channel">>),
    ?assertNot(has(cmd(A, <<"NAMES #rchidden">>, <<" 366 ">>), <<" 353 ">>)),
    %% Peer channel messages are kept in history with their tags.
    send(
        Peer,
        <<"@msgid=rc1;time=2026-01-01T00:00:00.000Z :rc_rem!user@peer.test PRIVMSG #rcremote :t1">>
    ),
    send(Peer, <<"@time=bogus :rc_rem!user@peer.test PRIVMSG #rcremote :t2">>),
    send(Peer, <<":rc_rem!user@peer.test NOTICE #rcremote :t3">>),
    sync_peer(Peer),
    Heard = recv_until(A, <<":t3">>),
    want(Heard, <<"PRIVMSG #rcremote :t1">>),
    want(Heard, <<"PRIVMSG #rcremote :t2">>),
    %% Inviting a remote user to a channel shared with the link.
    want(cmd(A, <<"INVITE rc_rem #rcremote">>, <<" 341 ">>), <<"rc_rem #rcremote">>),
    %% A channel shared with a link cannot be renamed.
    want(cmd(A, <<"RENAME #rcremote #rcmoved">>, <<"FAIL">>), <<"CANNOT_RENAME">>),
    %% Private flags set by the peer are reflected in the NAMES symbol.
    send(Peer, <<":peer.test MODE #rcremote +p">>),
    sync_peer(Peer),
    want(cmd(A, <<"NAMES #rcremote">>, <<" 366 ">>), <<" 353 rc_alice * #rcremote">>),
    send(Peer, <<":peer.test MODE #rcremote -p+s">>),
    sync_peer(Peer),
    want(cmd(A, <<"NAMES #rcremote">>, <<" 366 ">>), <<" 353 rc_alice @ #rcremote">>),
    %% A channel whose last remote member quit is held against reuse.
    send(Peer, <<":peer.test NICK rc_gone 1 user peer.test 1 + :Gone">>),
    send(Peer, <<":rc_gone!user@peer.test JOIN #rcheld">>),
    send(Peer, <<":peer.test KILL rc_gone :gone">>),
    sync_peer(Peer),
    want(cmd(A, <<"JOIN #rcheld">>, <<" 437 ">>), <<"#rcheld :Nick/channel is temporarily">>),
    gen_tcp:close(Peer),
    close_all([A, B]).

%% --- Predefined channels and administrators --------------------------------

predefined(Port) ->
    A = client(Port, <<"pre_adm">>),
    B = client(Port, <<"pre_bob">>),
    %% A configured channel exists before anyone joins; joiners are members.
    want(join(B, <<"#pre">>), <<"#pre :pre_bob">>),
    want(join(A, <<"#pre">>), <<"#pre :pre_adm pre_bob">>),
    join(A, <<"+preplus">>),
    join(A, <<"#prenot">>),
    %% OPER as an administrator grants channel operator on configured channels.
    Oper = cmd(A, <<"OPER pre_adm admpw">>, <<" 381 ">>),
    want(Oper, <<"MODE #pre +o pre_adm">>),
    ?assertNot(has(Oper, <<"MODE +preplus">>)),
    want(recv_until(B, <<"+o pre_adm">>), <<"MODE #pre +o pre_adm">>),
    %% A second OPER changes nothing on channels where it is already operator.
    ?assertNot(has(cmd(A, <<"OPER pre_adm admpw">>, <<" 381 ">>), <<"MODE #pre">>)),
    %% An ordinary operator gets no channel status.
    ?assertNot(has(cmd(B, <<"OPER plainop oppw">>, <<" 381 ">>), <<"MODE #pre">>)),
    %% Rejoining a configured channel as administrator gives operator status.
    cmd(A, <<"PART #pre">>, <<"PART">>),
    want(join(A, <<"#pre">>), <<"@pre_adm">>),
    %% STATS l reports per-connection counters.
    want(cmd(A, <<"STATS l">>, <<" 219 ">>), <<" 211 ">>),
    %% The configured channel stays when its last member leaves.
    cmd(A, <<"PART #pre">>, <<"PART">>),
    cmd(B, <<"PART #pre">>, <<"PART">>),
    want(cmd(B, <<"MODE #pre">>, <<" 324 ">>), <<" 324 pre_bob #pre +">>),
    %% An operator alone on an ordinary channel may kick itself; the
    %% channel is then released.
    want(cmd(A, <<"KICK #prenot pre_adm">>, <<"KICK">>), <<"KICK #prenot pre_adm">>),
    want(cmd(A, <<"MODE #prenot">>, <<" 403 ">>), <<"#prenot :No such channel">>),
    %% RFC 2812 3.1.5: an operator may drop +o (administrator status goes too),
    %% and cannot take it back with MODE.
    AdminPid = whois_pid(<<"pre_adm">>),
    ?assert(ircd_state:administrator(AdminPid)),
    want(cmd(A, <<"MODE pre_adm -o">>, <<"MODE">>), <<"MODE pre_adm -o">>),
    ?assertNot(maps:is_key($o, ircd_state:user_modes(AdminPid))),
    ?assertNot(ircd_state:administrator(AdminPid)),
    ?assertNot(has(cmd(A, <<"MODE pre_adm -o">>, <<"PONG">>), <<"MODE pre_adm">>)),
    want(cmd(A, <<"MODE pre_adm +o">>, <<" 481 ">>), <<"not an IRC operator">>),
    close_all([A, B]).

whois_pid(Nick) ->
    [Pid] = [P || {client, P, _, N, _, _, _, _, _} <- ets:tab2list(client), N =:= Nick],
    Pid.

%% --- Capabilities, held registrations, and mask forms ---------------------

capabilities_and_masks(Port) ->
    A = client(Port, <<"cm_alice">>),
    B = client(Port, <<"cm_bob">>),
    join(A, <<"#cm">>),
    join(B, <<"#cm">>),
    cmd(A, <<"MODE #cm +v cm_alice">>, <<"+v">>),
    %% multi-prefix and userhost-in-names change the NAMES entries.
    want(
        cmd(B, <<"CAP REQ :multi-prefix userhost-in-names no-implicit-names">>, <<"ACK">>),
        <<"ACK">>
    ),
    want(cmd(B, <<"NAMES #cm">>, <<" 366 ">>), <<"@+cm_alice!u@127.0.0.1">>),
    %% no-implicit-names: JOIN does not send NAMES.
    ?assertNot(has(join(B, <<"#cm2">>), <<" 353 ">>)),
    %% A RENAME without a reason reaches legacy members as PART and JOIN.
    join(A, <<"#cm3">>),
    join(B, <<"#cm3">>),
    want(cmd(A, <<"RENAME #cm3 #cm4">>, <<"366 cm_alice #cm4">>), <<"PART #cm3\r\n">>),
    Renamed = recv_until(B, <<"JOIN #cm4">>),
    ?assertNot(has(<<Renamed/binary, (sync(B))/binary>>, <<" 353 ">>)),
    want(cmd(A, <<"RENAME #cm4 bad">>, <<"FAIL">>), <<"CANNOT_RENAME">>),
    %% echo-message and message-tags: the sender gets its own channel
    %% message back with the client-only tag.
    want(cmd(A, <<"CAP REQ :echo-message message-tags">>, <<"ACK">>), <<"ACK">>),
    want(cmd(A, <<"@+typing=active PRIVMSG #cm :echoed">>, <<"echoed">>), <<"+typing=active">>),
    want(recv_until(B, <<"echoed">>), <<"PRIVMSG #cm :echoed">>),
    %% TAGMSG without a target, and to a channel.
    want(cmd(A, <<"TAGMSG">>, <<" 411 ">>), <<"No recipient given">>),
    ?assertNot(has(cmd(A, <<"TAGMSG #cm">>, <<"PONG">>), <<" 4">>)),
    %% A client whose registration is held by CAP negotiation cannot be
    %% addressed yet.
    H = connect(Port),
    send(H, <<"CAP LS 302">>),
    send(H, <<"NICK cm_held">>),
    send(H, <<"USER u 0 * :Held">>),
    want(recv_until(H, <<"CAP * LS">>), <<"CAP * LS">>),
    sync(H),
    want(cmd(A, <<"PRIVMSG cm_held :hi">>, <<" 401 ">>), <<"cm_held :No such nick">>),
    want(cmd(A, <<"INVITE cm_held #cm">>, <<" 401 ">>), <<"cm_held :No such nick">>),
    want(cmd(A, <<"INVITE #cmnew cm_held">>, <<" 401 ">>), <<"cm_held :No such nick">>),
    want(cmd(H, <<"CAP END">>, <<" 001 ">>), <<" 001 cm_held">>),
    %% A `b` without a mask inside a longer mode string is ignored.
    want(cmd(A, <<"MODE #cm +bn">>, <<"MODE #cm +n">>), <<"MODE #cm +n\r\n">>),
    %% Account extbans do not match a client that is not logged in, and a
    %% leading `*` mask that does not match must scan the whole identity.
    join(A, <<"#cmban">>),
    cmd(A, <<"MODE #cmban +bbb $a:* $a *zzz">>, <<"+bbb">>),
    want(join(B, <<"#cmban">>), <<"JOIN #cmban">>),
    %% A safe-channel short name that is not a valid channel name.
    want(cmd(A, <<"JOIN !bad:name">>, <<" 403 ">>), <<"No such channel">>),
    %% Anonymous channel: NAMES from outside shows nobody; the full NAMES
    %% listing shows only the requester to a member.
    join(A, <<"&cmanon">>),
    join(B, <<"&cmanon">>),
    cmd(A, <<"MODE &cmanon +a">>, <<"+a">>),
    O = client(Port, <<"cm_out">>),
    ?assertNot(has(cmd(O, <<"NAMES &cmanon">>, <<" 366 ">>), <<" 353 ">>)),
    All = cmd(A, <<"NAMES">>, <<"366 cm_alice * ">>),
    want(All, <<"&cmanon :@cm_alice">>),
    ?assertNot(has(All, <<"&cmanon :@cm_alice cm_bob">>)),
    close_all([A, B, H, O]).

%% --- Server password (RFC 2812 3.1.1) ---------------------------------------

client_password(Port) ->
    S = connect(Port),
    want(cmd(S, <<"PASS wrong">>, <<" 464 ">>), <<"Password incorrect">>),
    want(cmd(S, <<"PASS again">>, <<" 462 ">>), <<"You may not reregister">>),
    gen_tcp:close(S),
    %% NICK and USER without PASS: 464, then ERROR and close.
    N = connect(Port),
    send(N, <<"NICK pw_none">>),
    send(N, <<"USER u 0 * :R">>),
    Closed = recv_until(N, <<"ERROR">>),
    want(Closed, <<" 464 ">>),
    want(Closed, <<"Password required">>),
    gen_tcp:close(N),
    Ok = connect(Port),
    send(Ok, <<"PASS letmein">>),
    send(Ok, <<"NICK pw_ok">>),
    send(Ok, <<"USER u 0 * :R">>),
    want(recv_until(Ok, <<" 001 ">>), <<" 001 pw_ok">>),
    gen_tcp:close(Ok).

%% --- helpers ----------------------------------------------------------------

start_main() ->
    start(<<
        "\"reop_delay\":1,\"resource_delay\":30,"
        "\"operators\":[{\"name\":\"plainop\",\"password\":\"oppw\"}],"
        "\"administrators\":[{\"nick\":\"pre_adm\",\"password\":\"admpw\"}],"
        "\"channels\":[{\"name\":\"#pre\"},{\"name\":\"+preplus\"}],"
    >>).

start(Extra) ->
    Dir = filename:join(
        "/tmp", "ircd-cov-channel-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(Db, Extra)),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    #{port => listener_port(), dir => Dir}.

stop(_) ->
    _ = application:stop(ircd),
    os:unsetenv("IRCD_CONFIG"),
    ok.

config(Db, Extra) ->
    iolist_to_binary([
        <<"{">>,
        <<"\"name\":\"irc.test\",">>,
        <<"\"bind\":\"127.0.0.1\",">>,
        <<"\"tcp_port\":0,">>,
        <<"\"tls_port\":null,">>,
        <<"\"log_level\":\"emergency\",">>,
        <<"\"log_format\":\"text\",">>,
        <<"\"max_clients\":500,">>,
        <<"\"retention\":\"transient\",\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\",">>,
        Extra,
        <<"\"server_links\":[">>,
        <<"{\"name\":\"peer.test\",\"host\":\"127.0.0.1\",\"port\":1,">>,
        <<"\"password\":\"linksecret\",\"tls\":false}]">>,
        <<"}">>
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
    Welcome = recv_until(Sock, <<" 001 ">>),
    want(Welcome, <<" 001 ", Nick/binary>>),
    sync(Sock),
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
    cmd(Sock, <<"JOIN ", Name/binary>>, <<" 366 ">>).

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

%% Send one command followed by a PING marker. Everything the command
%% produced for this connection arrives before the PONG. `_Needle` documents
%% the reply the caller asserts on.
cmd(Sock, Line, _Needle) ->
    send(Sock, Line),
    sync(Sock).

%% PING round trip: returns all data received up to and including the PONG.
sync(Sock) ->
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
                        {ok, Bin} -> recv_loop(Sock, Needle, Deadline, <<Acc/binary, Bin/binary>>);
                        {error, _} -> Acc
                    end
            end
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

count(Bin, Needle) ->
    length(binary:matches(Bin, Needle)).

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
