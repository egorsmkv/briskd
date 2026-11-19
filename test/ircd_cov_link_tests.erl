-module(ircd_cov_link_tests).
-include_lib("eunit/include/eunit.hrl").

%% RFC 2813 server links driven through inbound peer sockets: burst contents,
%% import of servers, users, channels, modes, and topics, propagation to the
%% other peers but never back to the ingress link, multi-hop introductions,
%% nick collisions, SQUIT and link loss, and replicated IRCv3 state.
%% Rejected peer input is checked through ircd_state:server_command/4, which
%% is what a link worker calls for each parsed line.

-define(PEER, <<"peer.test">>).
-define(REM, <<"rem!u@h.test">>).
-define(LEAFY, <<"leafy!u@h.test">>).

burst_and_import_test_() ->
    {timeout, 60, fun burst_and_import/0}.

propagation_test_() ->
    {timeout, 60, fun propagation/0}.

rejected_input_test_() ->
    {timeout, 60, fun rejected_input/0}.

operator_and_split_test_() ->
    {timeout, 60, fun operator_and_split/0}.

%%% Burst contents and import

burst_and_import() ->
    Port = start("burst"),
    try
        Alice = client(Port, <<"alice">>),
        lists:foreach(
            fun(Line) -> send(Alice, Line) end,
            [
                <<"MODE alice +i">>,
                <<"JOIN #burst">>,
                <<"MODE #burst +ntk key">>,
                <<"MODE #burst +l 5">>,
                <<"MODE #burst +b bad!*@*">>,
                <<"MODE #burst +e good!*@*">>,
                <<"MODE #burst +I inv!*@*">>,
                <<"TOPIC #burst :burst-topic">>,
                <<"JOIN !safe">>,
                <<"METADATA * SET color :blue">>,
                <<"METADATA #burst SET theme :dark">>
            ]
        ),
        sync(Alice),
        Peer = handshake(Port, ?PEER),
        Burst = sync(Peer),
        ?assert(has(Burst, <<"NICK alice 0 alice ">>)),
        ?assert(has(Burst, <<" 1 +i :alice">>)),
        ?assert(has(Burst, <<"NJOIN #burst :@alice">>)),
        ?assert(has(Burst, <<"MODE #burst +ntkl key 5">>)),
        ?assert(has(Burst, <<"MODE #burst +b bad!*@*">>)),
        ?assert(has(Burst, <<"MODE #burst +e good!*@*">>)),
        ?assert(has(Burst, <<"MODE #burst +I inv!*@*">>)),
        ?assert(has(Burst, <<"TOPIC #burst :burst-topic">>)),
        ?assert(has(Burst, <<"NJOIN !">>)),
        ?assert(has(Burst, <<" +O alice">>)),
        ?assert(has(Burst, <<"METADATA alice color * :blue">>)),
        ?assert(has(Burst, <<"METADATA #burst theme * :dark">>)),
        Other = handshake(Port, <<"other.test">>),
        OtherBurst = sync(Other),
        %% The first peer is a known server and appears in the second burst.
        ?assert(has(OtherBurst, <<"SERVER peer.test 2 ">>)),
        %% A leaf server and a server two hops behind it.
        send(Peer, <<":peer.test SERVER leaf.test 2 2 :Leaf">>),
        ?assert(
            has(
                recv_until(Other, <<"SERVER leaf.test">>),
                <<":peer.test SERVER leaf.test 3 2 :Leaf">>
            )
        ),
        send(Peer, <<":leaf.test SERVER deep.test 3 3 :Deep">>),
        ?assert(
            has(recv_until(Other, <<"SERVER deep.test">>), <<":leaf.test SERVER deep.test 4 3">>)
        ),
        ?assertNot(has(sync(Peer), <<"SERVER leaf.test">>)),
        %% Users at the peer, at the leaf, and at the deep server.
        send(Peer, <<":peer.test NICK rem 1 ruser rhost.test 7 + :Remote">>),
        send(Peer, <<":leaf.test NICK leafy 1 luser lhost.test 8 +i :Leafy">>),
        send(Peer, <<":deep.test NICK deepy 2 duser dhost.test 9 +w :Deepy">>),
        Intro = recv_until(Other, <<"NICK deepy">>),
        ?assert(has(Intro, <<":peer.test NICK rem 2 ruser rhost.test 7 + :Remote">>)),
        ?assert(has(Intro, <<":leaf.test NICK leafy 2 luser lhost.test 8 +i :Leafy">>)),
        ?assert(has(Intro, <<":deep.test NICK deepy 3 duser dhost.test 9 +w :Deepy">>)),
        ?assertNot(has(sync(Peer), <<"NICK rem">>)),
        %% Re-introducing a known nick from the same link updates it silently.
        send(Peer, <<":peer.test NICK rem 1 ruser rhost.test 7 + :Remote">>),
        %% Burst NJOIN with creator, operator, voice, and plain members.
        send(Peer, <<":peer.test NJOIN #burst :@@rem,@leafy,+deepy">>),
        send(Peer, <<":peer.test NJOIN #remote :@rem,deepy">>),
        send(Peer, <<":peer.test MODE #remote +tnl 9">>),
        send(Peer, <<":peer.test MODE #remote +k rkey">>),
        send(Peer, <<":peer.test MODE #remote +b ban!*@*">>),
        send(Peer, <<":peer.test TOPIC #remote :remote-topic">>),
        %% TOPIC is not a burst command, so the netjoin batch is flushed first.
        sync(Peer),
        Joins = sync(Alice),
        ?assert(has(Joins, <<":rem!ruser@rhost.test JOIN #burst">>)),
        ?assert(has(Joins, <<":leafy!luser@lhost.test JOIN #burst">>)),
        ?assert(has(Joins, <<":deepy!duser@dhost.test JOIN #burst">>)),
        OtherSide = recv_until(Other, <<"TOPIC #remote">>),
        ?assert(has(OtherSide, <<"NJOIN #burst :@@rem,@leafy,+deepy">>)),
        ?assert(has(OtherSide, <<"MODE #remote +tnl 9">>)),
        %% Replicated account, metadata, and read marker.
        Sync =
            <<":peer.test ACCOUNTSYNC acct c2FsdA== 4096 c3RvcmVk c2VydmVy 1700000000 :fp1,fp2">>,
        send(Peer, Sync),
        ?assert(has(recv_until(Other, <<"ACCOUNTSYNC">>), <<"ACCOUNTSYNC acct c2FsdA== 4096">>)),
        %% The same account again is kept and not relayed a second time.
        send(Peer, Sync),
        send(Peer, <<":rem!ruser@rhost.test METADATA rem color * :red">>),
        MetaRem = recv_until(Other, <<"METADATA rem">>),
        ?assert(has(MetaRem, <<"METADATA rem color * :red">>)),
        ?assertNot(has(MetaRem, <<"ACCOUNTSYNC">>)),
        send(Peer, <<":peer.test METADATA #burst theme * :light">>),
        ?assert(has(recv_until(Other, <<"METADATA #burst">>), <<"theme * :light">>)),
        send(Peer, <<":peer.test MARKREAD acct #burst 1700000000000">>),
        ?assert(has(recv_until(Other, <<"MARKREAD">>), <<"MARKREAD acct #burst 1700000000000">>)),
        %% An older marker is not newer than the stored one and is not relayed.
        send(Peer, <<":peer.test MARKREAD acct #burst 1600000000000">>),
        send(Peer, <<":peer.test METADATA #burst theme *">>),
        Removed = recv_until(Other, <<"METADATA #burst theme *">>),
        ?assertNot(has(Removed, <<"1600000000000">>)),
        %% A third peer receives every imported record in its burst.
        Third = handshake(Port, <<"third.test">>),
        ThirdBurst = sync(Third),
        ?assert(has(ThirdBurst, <<"SERVER leaf.test 3 2 :Leaf">>)),
        ?assert(has(ThirdBurst, <<":leaf.test SERVER deep.test 4 3 :Deep">>)),
        ?assert(has(ThirdBurst, <<":peer.test NICK rem 2 ruser rhost.test 7 + :Remote">>)),
        ?assert(has(ThirdBurst, <<":leaf.test NICK leafy 2 luser">>)),
        ?assert(has(ThirdBurst, <<"ACCOUNTSYNC acct">>)),
        ?assert(has(ThirdBurst, <<"MARKREAD acct #burst 1700000000000">>)),
        ?assert(has(ThirdBurst, <<"NJOIN #remote :">>)),
        ?assert(has(ThirdBurst, <<"@rem">>)),
        ?assert(has(ThirdBurst, <<"MODE #remote +ntkl rkey 9">>)),
        ?assert(has(ThirdBurst, <<"MODE #remote +b ban!*@*">>)),
        ?assert(has(ThirdBurst, <<"TOPIC #remote :remote-topic">>)),
        %% NAMES and WHOIS on a channel known only through the link.
        send(Alice, <<"NAMES #remote">>),
        Names = recv_until(Alice, <<" 366 ">>),
        ?assert(has(Names, <<"#remote :">>)),
        send(Alice, <<"WHOIS leafy">>),
        ?assert(has(recv_until(Alice, <<" 318 ">>), <<"leafy leaf.test">>)),
        send(Alice, <<"LINKS">>),
        Links = recv_until(Alice, <<" 365 ">>),
        ?assert(has(Links, <<"deep.test">>)),
        ?assert(has(Links, <<"leaf.test">>))
    after
        stop()
    end.

%%% Remote events reach local clients and the other peers, not the ingress

propagation() ->
    Port = start("prop"),
    try
        Alice = client(Port, <<"alice">>),
        send(Alice, <<"JOIN #room">>),
        sync(Alice),
        Peer = handshake(Port, ?PEER),
        sync(Peer),
        Other = handshake(Port, <<"other.test">>),
        sync(Other),
        send(Peer, <<":peer.test SERVER leaf.test 2 2 :Leaf">>),
        send(Peer, <<":peer.test NICK rem 1 ruser rhost.test 7 + :Remote">>),
        send(Peer, <<":leaf.test NICK leafy 1 luser lhost.test 8 + :Leafy">>),
        send(Peer, <<":peer.test NICK farr 1 fuser fhost.test 4 + :Far">>),
        send(Other, <<":other.test NICK sidey 1 suser shost.test 3 + :Side">>),
        recv_until(Other, <<"NICK farr">>),
        recv_until(Peer, <<"NICK sidey">>),
        %% A remote JOIN reaches the local member and the other peer once.
        send(Peer, <<":rem!ruser@rhost.test JOIN #room">>),
        ?assert(has(recv_until(Alice, <<"JOIN #room">>), <<":rem!ruser@rhost.test JOIN #room">>)),
        recv_until(Other, <<":rem!ruser@rhost.test JOIN #room">>),
        send(Peer, <<":leafy!luser@lhost.test JOIN #room">>),
        recv_until(Alice, <<":leafy!luser@lhost.test JOIN #room">>),
        send(Other, <<":sidey!suser@shost.test JOIN #room">>),
        recv_until(Alice, <<":sidey!suser@shost.test JOIN #room">>),
        recv_until(Peer, <<":sidey!suser@shost.test JOIN #room">>),
        %% A duplicate JOIN changes nothing.
        send(Peer, <<":rem!ruser@rhost.test JOIN #room">>),
        ?assertNot(has(sync(Peer), <<"JOIN #room">>)),
        %% A server-sourced MODE gives operator status without a member echo.
        send(Peer, <<":peer.test MODE #room +o rem">>),
        recv_until(Other, <<"MODE #room +o rem">>),
        send(Peer, <<":rem!ruser@rhost.test MODE #room +v leafy">>),
        ?assert(has(recv_until(Alice, <<"MODE #room +v leafy">>), <<":rem!ruser@rhost.test">>)),
        recv_until(Other, <<"MODE #room +v leafy">>),
        send(Peer, <<":rem!ruser@rhost.test MODE #room +imp-p+s-v leafy">>),
        recv_until(Alice, <<"MODE #room +imp-p+s-v leafy">>),
        send(Peer, <<":rem!ruser@rhost.test MODE #room -ims+lk-l+e-e 3 key x!*@* x!*@*">>),
        recv_until(Alice, <<"MODE #room -ims+lk-l+e-e">>),
        send(Peer, <<":rem!ruser@rhost.test MODE #room -k+O-O key leafy leafy">>),
        recv_until(Alice, <<"MODE #room -k+O-O">>),
        %% TOPIC from a member and from a server.
        send(Peer, <<":rem!ruser@rhost.test TOPIC #room :member-topic">>),
        ?assert(has(recv_until(Alice, <<"TOPIC #room">>), <<"member-topic">>)),
        recv_until(Other, <<"member-topic">>),
        send(Peer, <<":leaf.test TOPIC #room :server-topic">>),
        recv_until(Alice, <<"server-topic">>),
        %% Remote user modes are applied and shown to channel members.
        send(Peer, <<":rem!ruser@rhost.test MODE rem +iw-w">>),
        recv_until(Alice, <<"MODE rem +iw-w">>),
        recv_until(Other, <<"MODE rem +iw-w">>),
        %% AWAY set and cleared.
        send(Peer, <<":rem!ruser@rhost.test AWAY :gone">>),
        ?assert(has(recv_until(Other, <<"AWAY">>), <<":rem!ruser@rhost.test AWAY :gone">>)),
        send(Peer, <<":rem!ruser@rhost.test AWAY">>),
        recv_until(Other, <<":rem!ruser@rhost.test AWAY\r\n">>),
        %% Messages: to a local user, to the channel, to a user on the other peer.
        send(Peer, <<":rem!ruser@rhost.test PRIVMSG alice :hello-alice">>),
        recv_until(Alice, <<"hello-alice">>),
        send(
            Peer,
            <<"@msgid=abc123;time=2024-01-01T00:00:00.000Z :rem!ruser@rhost.test NOTICE alice :tagged">>
        ),
        recv_until(Alice, <<"NOTICE alice :tagged">>),
        send(Peer, <<"@msgid=has:colon;time=bogus :rem!ruser@rhost.test NOTICE alice :badtags">>),
        recv_until(Alice, <<"badtags">>),
        send(Peer, <<"@+typing=active :rem!ruser@rhost.test TAGMSG alice">>),
        send(Peer, <<":rem!ruser@rhost.test PRIVMSG #room :hello-room">>),
        ?assert(
            has(recv_until(Alice, <<"hello-room">>), <<":rem!ruser@rhost.test PRIVMSG #room">>)
        ),
        recv_until(Other, <<"PRIVMSG #room :hello-room">>),
        ?assertNot(has(sync(Peer), <<"hello-room">>)),
        send(Peer, <<":rem!ruser@rhost.test PRIVMSG sidey :hello-side">>),
        recv_until(Other, <<"PRIVMSG sidey :hello-side">>),
        send(Peer, <<":rem!ruser@rhost.test PRIVMSG nobody :lost">>),
        %% A message to a user on the ingress side is not sent back.
        send(Peer, <<":rem!ruser@rhost.test PRIVMSG leafy :loop">>),
        ?assertNot(has(sync(Peer), <<":loop">>)),
        %% Multiline batches from a peer to a user, a channel, and a remote user.
        multiline(Peer, <<"alice">>, <<"b1">>),
        recv_until(Alice, <<"ml-two">>),
        multiline(Peer, <<"#room">>, <<"b2">>),
        recv_until(Alice, <<"ml-two">>),
        recv_until(Other, <<"ml-two">>),
        multiline(Peer, <<"sidey">>, <<"b3">>),
        recv_until(Other, <<"ml-two">>),
        send(Peer, <<":rem!ruser@rhost.test BATCH -nosuch">>),
        %% INVITE to a local user and to a user on the other peer.
        send(Peer, <<":rem!ruser@rhost.test INVITE alice #room">>),
        recv_until(Alice, <<"INVITE alice #room">>),
        send(Peer, <<":rem!ruser@rhost.test INVITE sidey #room">>),
        recv_until(Other, <<"INVITE sidey #room">>),
        send(Peer, <<":rem!ruser@rhost.test INVITE leafy #elsewhere">>),
        %% Local actions are sent to the peers.
        send(Alice, <<"TOPIC #room :local-topic">>),
        recv_until(Peer, <<"TOPIC #room :local-topic">>),
        send(Alice, <<"PRIVMSG #room :from-alice">>),
        recv_until(Peer, <<"PRIVMSG #room :from-alice">>),
        recv_until(Other, <<"PRIVMSG #room :from-alice">>),
        send(Alice, <<"PRIVMSG rem :direct">>),
        recv_until(Peer, <<"PRIVMSG rem :direct">>),
        send(Alice, <<"AWAY :brb">>),
        recv_until(Peer, <<"AWAY :brb">>),
        send(Alice, <<"AWAY">>),
        recv_until(Peer, <<" AWAY\r\n">>),
        send(Alice, <<"MODE #room +t">>),
        recv_until(Peer, <<"MODE #room +t">>),
        send(Alice, <<"INVITE farr #room">>),
        recv_until(Peer, <<"INVITE farr #room">>),
        recv_until(Other, <<"INVITE farr #room">>),
        send(Alice, <<"NICK alicia">>),
        recv_until(Peer, <<"NICK alicia">>),
        Bob = client(Port, <<"bob">>),
        recv_until(Peer, <<"NICK bob 0 bob ">>),
        send(Bob, <<"JOIN #room">>),
        ?assert(has(recv_until(Peer, <<"NJOIN #room :bob">>), <<"JOIN #room">>)),
        send(Alice, <<"KICK #room bob :bye">>),
        recv_until(Peer, <<"KICK #room bob :bye">>),
        recv_until(Bob, <<"KICK #room bob">>),
        send(Bob, <<"JOIN #room">>),
        recv_until(Peer, <<"NJOIN #room :bob">>),
        %% Remote KICK of a remote member and of a local member.
        send(Peer, <<":rem!ruser@rhost.test KICK #room sidey :out">>),
        recv_until(Alice, <<"KICK #room sidey">>),
        recv_until(Other, <<"KICK #room sidey">>),
        send(Peer, <<":rem!ruser@rhost.test KICK #room bob :out">>),
        recv_until(Bob, <<"KICK #room bob">>),
        %% Remote PART, NICK change, and QUIT.
        send(Peer, <<":leafy!luser@lhost.test JOIN #room">>),
        send(Peer, <<":leafy!luser@lhost.test PART #room :later">>),
        recv_until(Alice, <<"PART #room :later">>),
        recv_until(Other, <<"PART #room :later">>),
        send(Peer, <<":leafy!luser@lhost.test JOIN #solo">>),
        send(Peer, <<":leafy!luser@lhost.test PART #solo">>),
        send(Peer, <<":leafy!luser@lhost.test NICK leafy2">>),
        recv_until(Other, <<"NICK leafy2">>),
        send(Peer, <<":leafy2!luser@lhost.test NICK LEAFY2">>),
        send(Peer, <<":LEAFY2!luser@lhost.test QUIT :gone-away">>),
        recv_until(Other, <<"QUIT :gone-away">>),
        %% Remote KILL of a remote user and of a local user.
        send(Other, <<":other.test KILL rem :killed">>),
        ?assert(has(recv_until(Peer, <<"QUIT :killed">>), <<"KILL rem :killed">>)),
        send(Peer, <<":peer.test KILL bob :die">>),
        recv_until(Bob, <<"KILL bob">>),
        recv_until(Other, <<"KILL bob">>),
        %% Nick collision between two peers kills both copies.
        send(Peer, <<":peer.test NICK twin 1 tuser thost.test 1 + :Twin">>),
        recv_until(Other, <<"NICK twin">>),
        send(Other, <<":other.test NICK twin 1 tuser thost.test 1 + :Twin">>),
        ?assert(has(recv_until(Peer, <<"twin!tuser@thost.test QUIT">>), <<"KILL twin">>)),
        %% Collision with a local user disconnects it.
        send(Peer, <<":peer.test NICK alicia 1 a ahost.test 1 + :Clash">>),
        recv_until(Alice, <<"KILL alicia">>),
        recv_until(Other, <<"KILL alicia">>),
        ?assertEqual([], [K || K <- mnesia:dirty_all_keys(remote_client), K =:= <<"twin">>])
    after
        stop()
    end.

multiline(Peer, Target, Ref) ->
    send(Peer, <<":rem!ruser@rhost.test BATCH +", Ref/binary, " draft/multiline ", Target/binary>>),
    send(
        Peer,
        <<"@batch=", Ref/binary, " :rem!ruser@rhost.test PRIVMSG ", Target/binary, " :ml-one">>
    ),
    send(
        Peer,
        <<"@batch=", Ref/binary, ";draft/multiline-concat :rem!ruser@rhost.test PRIVMSG ",
            Target/binary, " :ml-two">>
    ),
    send(Peer, <<":rem!ruser@rhost.test BATCH -", Ref/binary>>).

%%% Peer input that the state process rejects

rejected_input() ->
    Port = start("reject"),
    try
        Alice = client(Port, <<"alice">>),
        send(Alice, <<"JOIN #local">>),
        send(Alice, <<"JOIN #both">>),
        send(Alice, <<"MODE #local +t">>),
        sync(Alice),
        Peer = handshake(Port, ?PEER),
        sync(Peer),
        Other = handshake(Port, <<"other.test">>),
        sync(Other),
        ok = cmd(?PEER, <<"SERVER">>, [<<"leaf.test">>, <<"2">>, <<"2">>, <<"Leaf">>]),
        ok = cmd(?PEER, <<"NICK">>, nick(<<"rem">>, <<"1">>, <<"+">>)),
        ok = cmd(<<"leaf.test">>, <<"NICK">>, nick(<<"leafy">>, <<"1">>, <<"+">>)),
        ok = cmd(
            <<"other.test">>, <<"other.test">>, <<"NICK">>, nick(<<"sidey">>, <<"0">>, <<"+">>)
        ),
        ok = cmd(?REM, <<"JOIN">>, [<<"#local">>]),
        ok = cmd(?LEAFY, <<"JOIN">>, [<<"#local">>]),
        ok = cmd(?LEAFY, <<"JOIN">>, [<<"#nolocal">>]),
        ok = cmd(?LEAFY, <<"JOIN">>, [<<"#both">>]),
        %% Server introductions.
        ?assertEqual(
            {error, invalid_server},
            cmd(?PEER, <<"SERVER">>, [<<"a.test">>, <<"x">>, <<"1">>, <<"i">>])
        ),
        ?assertEqual(
            {error, invalid_server},
            cmd(?PEER, <<"SERVER">>, [<<"a.test">>, <<"2">>, <<"t">>, <<"i">>])
        ),
        ?assertEqual(
            {error, loop}, cmd(?PEER, <<"SERVER">>, [<<"irc.test">>, <<"2">>, <<"1">>, <<"i">>])
        ),
        ?assertEqual(
            {error, duplicate_route},
            cmd(?PEER, <<"SERVER">>, [<<"leaf.test">>, <<"2">>, <<"1">>, <<"i">>])
        ),
        %% NICK introductions.
        ?assertEqual(
            {error, invalid_hopcount}, cmd(?PEER, <<"NICK">>, nick(<<"n1">>, <<"x">>, <<"+">>))
        ),
        ?assertEqual(
            {error, invalid_introduction_prefix},
            cmd(<<"ghost.test">>, <<"NICK">>, nick(<<"n1">>, <<"1">>, <<"+">>))
        ),
        ?assertEqual(
            {error, invalid_introduction_prefix},
            cmd(<<"leaf.test">>, <<"NICK">>, nick(<<"n1">>, <<"5">>, <<"+">>))
        ),
        ?assertEqual(
            {error, invalid_nickname}, cmd(?PEER, <<"NICK">>, nick(<<"1bad">>, <<"1">>, <<"+">>))
        ),
        ?assertEqual(
            {error, reserved_nickname},
            cmd(?PEER, <<"NICK">>, nick(<<"anonymous">>, <<"1">>, <<"+">>))
        ),
        ?assertEqual(
            {error, invalid_server_token},
            cmd(?PEER, <<"NICK">>, [
                <<"n1">>, <<"1">>, <<"u">>, <<"h.test">>, <<"t">>, <<"+">>, <<"R">>
            ])
        ),
        ?assertEqual(
            {error, invalid_username},
            cmd(?PEER, <<"NICK">>, [
                <<"n1">>, <<"1">>, <<"u u">>, <<"h.test">>, <<"1">>, <<"+">>, <<"R">>
            ])
        ),
        ?assertEqual(
            {error, invalid_hostname},
            cmd(?PEER, <<"NICK">>, [
                <<"n1">>, <<"1">>, <<"u">>, <<"h h">>, <<"1">>, <<"+">>, <<"R">>
            ])
        ),
        ?assertEqual(
            {error, invalid_user_modes}, cmd(?PEER, <<"NICK">>, nick(<<"n1">>, <<"1">>, <<"+z">>))
        ),
        ?assertEqual(
            {error, invalid_user_modes}, cmd(?PEER, <<"NICK">>, nick(<<"n1">>, <<"1">>, <<"i">>))
        ),
        ?assertEqual(
            {error, invalid_nick_message},
            ircd_state_link:import_remote_nick(?PEER, ?PEER, [<<"n1">>])
        ),
        %% NICK changes.
        ?assertEqual({error, unknown_remote_nick}, cmd(<<"x!y@z">>, <<"NICK">>, [<<"n2">>])),
        ?assertEqual({error, invalid_nickname}, cmd(?REM, <<"NICK">>, [<<"9bad">>])),
        ?assertEqual({error, reserved_nickname}, cmd(?REM, <<"NICK">>, [<<"anonymous">>])),
        ?assertEqual({error, nickname_collision}, cmd(?REM, <<"NICK">>, [<<"alice">>])),
        ?assertEqual({error, nickname_collision}, cmd(?REM, <<"NICK">>, [<<"leafy">>])),
        ?assertEqual({error, nickname_collision}, cmd(?REM, <<"NICK">>, [<<"sidey">>])),
        %% A prefix that does not match the stored user@host is not trusted.
        ?assertEqual({error, unknown_remote_nick}, cmd(<<"rem!other@rhost.test">>, <<"QUIT">>, [])),
        ?assertEqual({error, unknown_remote_nick}, cmd(<<"rem">>, <<"AWAY">>, [])),
        ?assertEqual(
            {error, unknown_remote_nick},
            cmd(<<"other.test">>, ?REM, <<"AWAY">>, [<<"spoofed">>])
        ),
        %% JOIN and PART.
        ?assertEqual({error, unknown_remote_source}, cmd(<<"x!y@z">>, <<"JOIN">>, [<<"#a">>])),
        ?assertEqual({error, invalid_channel}, cmd(?REM, <<"JOIN">>, [<<"nochan">>])),
        ?assertEqual({error, unknown_remote_source}, cmd(<<"x!y@z">>, <<"PART">>, [<<"#none">>])),
        ?assertEqual({error, unknown_remote_channel}, cmd(?REM, <<"PART">>, [<<"#none">>])),
        ?assertEqual({error, remote_user_not_on_channel}, cmd(?REM, <<"PART">>, [<<"#nolocal">>])),
        %% Regression: a spoofed or stale prefix on a channel that exists was a
        %% case_clause crash of ircd_state (and so a restart of every client).
        State = whereis(ircd_state),
        ok = cmd(?REM, <<"JOIN">>, [<<"#spoof">>]),
        ?assertEqual({error, unknown_remote_source}, cmd(<<"x!y@z">>, <<"PART">>, [<<"#spoof">>])),
        ?assertEqual(
            {error, unknown_remote_source}, cmd(<<"rem!other@h.test">>, <<"PART">>, [<<"#spoof">>])
        ),
        ?assertEqual(
            {error, unknown_remote_source},
            cmd(<<"x!y@z">>, <<"TOPIC">>, [<<"#spoof">>, <<"t">>])
        ),
        ?assertEqual(
            {error, unknown_remote_source},
            cmd(<<"x!y@z">>, <<"KICK">>, [<<"#spoof">>, <<"rem">>])
        ),
        %% Regression: a prefixless MARKREAD or ACCOUNTSYNC comes from the link
        %% itself (RFC 2813 3.3) instead of crashing the relay.
        ?assertEqual(
            ok, cmd(undefined, <<"MARKREAD">>, [<<"acct">>, <<"#spoof">>, <<"1900000000000">>])
        ),
        ?assertMatch(
            {error, _}, cmd(undefined, <<"ACCOUNTSYNC">>, [<<"bad name">>, <<"s">>, <<"1">>])
        ),
        ?assertEqual(State, whereis(ircd_state)),
        ok = cmd(?REM, <<"PART">>, [<<"#spoof">>]),
        %% TOPIC.
        ?assertEqual({error, invalid_channel}, cmd(?REM, <<"TOPIC">>, [<<"bad">>, <<"t">>])),
        ?assertEqual(
            {error, unknown_remote_source}, cmd(<<"x!y@z">>, <<"TOPIC">>, [<<"#none">>, <<"t">>])
        ),
        ?assertEqual(
            {error, unknown_remote_channel}, cmd(?REM, <<"TOPIC">>, [<<"#none">>, <<"t">>])
        ),
        ?assertEqual(
            {error, remote_user_not_on_channel}, cmd(?REM, <<"TOPIC">>, [<<"#nolocal">>, <<"t">>])
        ),
        ?assertEqual(
            {error, remote_topic_requires_operator}, cmd(?REM, <<"TOPIC">>, [<<"#local">>, <<"t">>])
        ),
        %% KICK.
        ?assertEqual(
            {error, unknown_remote_source},
            cmd(<<"x!y@z">>, <<"KICK">>, [<<"#none">>, <<"alice">>])
        ),
        ?assertEqual(
            {error, unknown_remote_channel}, cmd(?REM, <<"KICK">>, [<<"#none">>, <<"alice">>])
        ),
        ?assertEqual(
            {error, remote_kick_requires_operator},
            cmd(?REM, <<"KICK">>, [<<"#local">>, <<"alice">>])
        ),
        ?assertEqual(
            {error, remote_kick_requires_operator},
            cmd(?REM, <<"KICK">>, [<<"#nolocal">>, <<"leafy">>])
        ),
        ok = cmd(?PEER, <<"MODE">>, [<<"#local">>, <<"+o">>, <<"rem">>]),
        ok = cmd(?PEER, <<"MODE">>, [<<"#nolocal">>, <<"+o">>, <<"leafy">>]),
        ?assertEqual(
            {error, remote_kick_target_not_on_channel},
            cmd(?LEAFY, <<"KICK">>, [<<"#nolocal">>, <<"alice">>])
        ),
        ?assertEqual(
            {error, remote_kick_target_not_on_channel},
            cmd(?LEAFY, <<"KICK">>, [<<"#nolocal">>, <<"sidey">>])
        ),
        %% NJOIN.
        ?assertEqual({error, invalid_channel}, cmd(?PEER, <<"NJOIN">>, [<<"bad">>, <<"rem">>])),
        ?assertEqual(
            {error, unknown_remote_member}, cmd(?PEER, <<"NJOIN">>, [<<"#n">>, <<"ghost">>])
        ),
        ?assertEqual(
            {error, remote_member_from_other_peer}, cmd(?PEER, <<"NJOIN">>, [<<"#n">>, <<"sidey">>])
        ),
        ?assertEqual({error, unknown_remote_member}, cmd(?PEER, <<"NJOIN">>, [<<"#n">>, <<>>])),
        %% Channel MODE.
        ?assertEqual(
            {error, unknown_remote_channel}, cmd(?REM, <<"MODE">>, [<<"#none">>, <<"+m">>])
        ),
        ?assertEqual(
            {error, remote_mode_requires_operator},
            cmd(?LEAFY, <<"MODE">>, [<<"#local">>, <<"+m">>])
        ),
        ?assertEqual(
            {error, remote_mode_requires_operator},
            cmd(<<"x!y@z">>, <<"MODE">>, [<<"#local">>, <<"+m">>])
        ),
        ?assertEqual(
            {error, {extra_mode_arguments, [<<"x">>]}},
            cmd(?REM, <<"MODE">>, [<<"#local">>, <<"+m">>, <<"x">>])
        ),
        ?assertEqual(
            {error, missing_mode_argument}, cmd(?REM, <<"MODE">>, [<<"#local">>, <<"+o">>])
        ),
        ?assertEqual(
            {error, {unsupported_channel_mode, $Z}}, cmd(?REM, <<"MODE">>, [<<"#local">>, <<"+Z">>])
        ),
        ?assertEqual(
            {error, invalid_channel_limit}, cmd(?REM, <<"MODE">>, [<<"#local">>, <<"+l">>, <<"0">>])
        ),
        ?assertEqual(
            {error, invalid_channel_limit}, cmd(?REM, <<"MODE">>, [<<"#local">>, <<"+l">>, <<"x">>])
        ),
        ?assertEqual(
            {error, missing_channel_limit}, cmd(?REM, <<"MODE">>, [<<"#local">>, <<"+l">>])
        ),
        ?assertEqual(
            {error, unknown_remote_mode_target},
            cmd(?REM, <<"MODE">>, [<<"#local">>, <<"+v">>, <<"ghost">>])
        ),
        %% User MODE.
        ?assertEqual(
            {error, remote_user_mode_source_mismatch},
            cmd(?REM, <<"MODE">>, [<<"leafy">>, <<"+i">>])
        ),
        ?assertEqual(
            {error, unknown_remote_source}, cmd(<<"x!y@z">>, <<"MODE">>, [<<"x">>, <<"+i">>])
        ),
        ok = cmd(?REM, <<"MODE">>, [<<"rem">>, <<"i+x">>]),
        %% Messages.
        ?assertEqual({error, invalid_remote_message}, cmd(?REM, <<"PRIVMSG">>, [<<"alice">>])),
        ?assertEqual(
            {error, malformed_remote_prefix}, cmd(<<"rem">>, <<"PRIVMSG">>, [<<"alice">>, <<"t">>])
        ),
        ?assertEqual(
            {error, unknown_remote_source}, cmd(<<"x!y@z">>, <<"PRIVMSG">>, [<<"alice">>, <<"t">>])
        ),
        ?assertEqual(
            {error, remote_prefix_mismatch},
            cmd(<<"rem!u@h">>, <<"PRIVMSG">>, [<<"alice">>, <<"t">>])
        ),
        ?assertEqual(
            {error, unknown_remote_channel}, cmd(?REM, <<"PRIVMSG">>, [<<"#none">>, <<"t">>])
        ),
        ?assertEqual(
            {error, remote_user_not_on_channel}, cmd(?REM, <<"PRIVMSG">>, [<<"#nolocal">>, <<"t">>])
        ),
        ok = cmd(?LEAFY, <<"PRIVMSG">>, [<<"#nolocal">>, <<"t">>]),
        ?assertEqual(
            {error, remote_user_not_on_channel}, cmd(?REM, <<"PRIVMSG">>, [<<"#both">>, <<"t">>])
        ),
        ok = cmd(?REM, <<"SQUERY">>, [<<"alice">>, <<"t">>]),
        %% A banned or moderated remote member is not shown to the channel.
        send(Alice, <<"MODE #local +b rem!*@*">>),
        sync(Alice),
        ok = cmd(?REM, <<"PRIVMSG">>, [<<"#local">>, <<"banned">>]),
        send(Alice, <<"MODE #local -b+m rem!*@*">>),
        sync(Alice),
        ok = cmd(?LEAFY, <<"PRIVMSG">>, [<<"#local">>, <<"moderated">>]),
        ?assertNot(has(sync(Alice), <<"banned">>)),
        ?assertNot(has(sync(Alice), <<"moderated">>)),
        %% INVITE, KILL, SERVICE.
        ?assertEqual(
            {error, unknown_remote_nick}, cmd(<<"x!y@z">>, <<"INVITE">>, [<<"alice">>, <<"#a">>])
        ),
        ok = cmd(?REM, <<"INVITE">>, [<<"nobody">>, <<"#a">>]),
        ok = cmd(?PEER, <<"KILL">>, [<<"nobody">>]),
        ?assertEqual({error, invalid_service}, cmd(?PEER, <<"SERVICE">>, [<<"svc">>])),
        ?assertEqual(
            {error, invalid_service},
            cmd(?PEER, <<"SERVICE">>, [<<"1svc">>, <<"*">>, <<"t">>, <<"i">>])
        ),
        ?assertEqual(
            {error, nickname_collision},
            cmd(?PEER, <<"SERVICE">>, [<<"alice">>, <<"*">>, <<"t">>, <<"i">>])
        ),
        ok = cmd(undefined, <<"SERVICE">>, [<<"svc">>, <<"*">>, <<"t">>, <<"i">>]),
        %% IRCv3 state replication.
        ?assertEqual({error, invalid_accountsync}, cmd(?PEER, <<"ACCOUNTSYNC">>, [<<"a">>])),
        ?assertEqual(
            {error, invalid_accountsync},
            cmd(?PEER, <<"ACCOUNTSYNC">>, [
                <<"acct">>, <<"c2E=">>, <<"10">>, <<"c2E=">>, <<"c2E=">>, <<"1">>
            ])
        ),
        ok = cmd(
            ?PEER, <<"ACCOUNTSYNC">>, [
                <<"acct">>, <<"c2E=">>, <<"4096">>, <<"c2E=">>, <<"c2E=">>, <<"5">>
            ]
        ),
        %% An older account from another server replaces the newer copy.
        ok = cmd(
            ?PEER, <<"ACCOUNTSYNC">>, [
                <<"acct">>, <<"c2E=">>, <<"4096">>, <<"c2E=">>, <<"c2E=">>, <<"2">>
            ]
        ),
        recv_until(Other, <<"ACCOUNTSYNC acct c2E= 4096 c2E= c2E= 2">>),
        ?assertEqual({error, invalid_metadata}, cmd(?PEER, <<"METADATA">>, [<<"x">>])),
        ?assertEqual(
            {error, metadata_source_mismatch},
            cmd(?LEAFY, <<"METADATA">>, [<<"rem">>, <<"k">>, <<"*">>, <<"v">>])
        ),
        ?assertEqual(
            {error, metadata_source_mismatch},
            cmd(?PEER, <<"METADATA">>, [<<"rem">>, <<"k">>, <<"*">>, <<"v">>])
        ),
        ?assertEqual(
            {error, invalid_metadata_key},
            cmd(?PEER, <<"METADATA">>, [<<"#local">>, <<"bad key">>, <<"*">>, <<"v">>])
        ),
        ok = cmd(?REM, <<"METADATA">>, [<<"rem">>, <<"k">>, <<"*">>]),
        ?assertEqual({error, invalid_markread}, cmd(?PEER, <<"MARKREAD">>, [<<"a">>])),
        ?assertEqual(
            {error, invalid_markread}, cmd(?PEER, <<"MARKREAD">>, [<<"a">>, <<"#b">>, <<"x">>])
        ),
        %% Batches.
        ?assertEqual({error, invalid_batch}, cmd(?REM, <<"BATCH">>, [<<"x">>])),
        ?assertEqual(
            {error, unknown_remote_source},
            cmd(<<"x!y@z">>, <<"BATCH">>, [<<"+r">>, <<"draft/multiline">>, <<"alice">>])
        ),
        Tags = [{<<"batch">>, <<"nope">>}],
        ?assertEqual(
            {error, unknown_batch},
            ircd_state:server_command(?PEER, ?REM, <<"PRIVMSG">>, [<<"alice">>, <<"t">>], Tags)
        ),
        ?assertEqual(
            {error, invalid_multiline},
            ircd_state_link:remote_batch_line(?PEER, ?REM, <<"PRIVMSG">>, [<<"alice">>], Tags)
        ),
        ok = cmd(?REM, <<"BATCH">>, [<<"+r1">>, <<"draft/multiline">>, <<"alice">>]),
        ?assertEqual(
            {error, invalid_multiline},
            ircd_state:server_command(?PEER, ?LEAFY, <<"PRIVMSG">>, [<<"alice">>, <<"t">>], [
                {<<"batch">>, <<"r1">>}
            ])
        ),
        %% An empty batch delivers nothing.
        ok = cmd(?REM, <<"BATCH">>, [<<"+r2">>, <<"draft/multiline">>, <<"alice">>]),
        ok = cmd(?REM, <<"BATCH">>, [<<"-r2">>]),
        %% An unknown server command is accepted and ignored.
        ok = cmd(?PEER, <<"WALLOPS">>, [<<"x">>]),
        %% A rejected line on a live link closes that link only.
        ?assertMatch([_], mnesia:dirty_read(remote_client, <<"rem">>)),
        send(Peer, <<":ghost!g@g PRIVMSG alice :x">>),
        ?assertEqual(closed, wait_closed(Peer)),
        %% Regression: that close runs the link cleanup, so the users behind
        %% the link are gone (the session used to stop without its role).
        wait_until(fun() ->
            [K || K <- mnesia:dirty_all_keys(remote_client), K =:= <<"rem">>] =:= []
        end)
    after
        stop()
    end.

nick(Nick, Hop, Modes) ->
    [Nick, Hop, <<"u">>, <<"h.test">>, <<"1">>, Modes, <<"Real">>].

cmd(Prefix, Command, Params) ->
    cmd(?PEER, Prefix, Command, Params).

cmd(Peer, Prefix, Command, Params) ->
    ircd_state:server_command(Peer, Prefix, Command, Params).

%%% Anonymous channels, channel lifetime edges, and multiline routing

edge_test_() ->
    {timeout, 60, fun edge/0}.

edge() ->
    Port = start("edge"),
    try
        Alice = client(Port, <<"alice">>),
        send(Alice, <<"CAP REQ :userhost-in-names">>),
        send(Alice, <<"JOIN !anon">>),
        send(Alice, <<"JOIN #room">>),
        send(Alice, <<"JOIN #solo">>),
        send(Alice, <<"JOIN &loc">>),
        send(Alice, <<"METADATA &loc SET k :v">>),
        sync(Alice),
        [Safe] = [
            element(3, Row)
         || K <- mnesia:dirty_all_keys(channel),
            binary:first(K) =:= $!,
            Row <- mnesia:dirty_read(channel, K)
        ],
        send(Alice, <<"MODE ", Safe/binary, " +a">>),
        sync(Alice),
        ok = cmd(undefined, <<"SERVER">>, [<<"leaf.test">>, <<"2">>, <<"5">>, <<"Leaf">>]),
        ok = cmd(?PEER, <<"NICK">>, nick(<<"rem">>, <<"1">>, <<"+">>)),
        ok = cmd(<<"leaf.test">>, <<"NICK">>, nick(<<"leafy">>, <<"1">>, <<"+">>)),
        ok = cmd(?PEER, <<"NICK">>, nick(<<"awayer">>, <<"1">>, <<"+a">>)),
        %% In an anonymous channel every remote event shows the anonymous mask.
        ok = cmd(?PEER, <<"NJOIN">>, [Safe, <<"@rem,leafy">>]),
        ok = cmd(?REM, <<"PRIVMSG">>, [Safe, <<"anon-text">>]),
        ok = cmd(?REM, <<"KICK">>, [Safe, <<"leafy">>, <<"out">>]),
        ok = cmd(?REM, <<"TOPIC">>, [Safe, <<"anon-topic">>]),
        ok = cmd(?REM, <<"MODE">>, [Safe, <<"+an">>]),
        ok = cmd(?REM, <<"PART">>, [Safe, <<"bye">>]),
        Anon = sync(Alice),
        ?assert(
            has(Anon, <<":anonymous!anonymous@anonymous. PRIVMSG ", Safe/binary, " :anon-text">>)
        ),
        ?assert(has(Anon, <<":anonymous!anonymous@anonymous. KICK ", Safe/binary, " leafy">>)),
        ?assert(has(Anon, <<":anonymous!anonymous@anonymous. TOPIC ", Safe/binary>>)),
        ?assert(has(Anon, <<":anonymous!anonymous@anonymous. PART ", Safe/binary>>)),
        ?assertNot(has(Anon, <<"rem!u@h.test">>)),
        %% A member that is away is announced as away when it joins.
        ok = cmd(<<"awayer!u@h.test">>, <<"JOIN">>, [<<"#room">>]),
        recv_until(Alice, <<":awayer!u@h.test JOIN #room">>),
        %% A server TOPIC or MODE may create the remote channel record.
        ok = cmd(?PEER, <<"TOPIC">>, [<<"#fresh">>, <<"srv-topic">>]),
        ?assertMatch([_], mnesia:dirty_read(remote_channel, <<"#fresh">>)),
        ok = cmd(?PEER, <<"MODE">>, [<<"#fresh2">>, <<"+I">>, <<"x!*@*">>]),
        ok = cmd(?PEER, <<"MODE">>, [<<"#fresh2">>, <<"-I">>, <<"x!*@*">>]),
        %% Remote-only channel: a member TOPIC, a repeated NJOIN, an op MODE.
        ok = cmd(?PEER, <<"NJOIN">>, [<<"#nolocal">>, <<"@leafy">>]),
        ok = cmd(?PEER, <<"NJOIN">>, [<<"#nolocal">>, <<"@leafy">>]),
        ok = cmd(?LEAFY, <<"TOPIC">>, [<<"#nolocal">>, <<"remote-only">>]),
        ok = cmd(?LEAFY, <<"MODE">>, [<<"#nolocal">>, <<"+n">>]),
        send(Alice, <<"NAMES #nolocal">>),
        ?assert(has(recv_until(Alice, <<" 366 ">>), <<"@leafy!u@h.test">>)),
        %% A secret remote channel is not listed to a non-member.
        ok = cmd(?PEER, <<"NJOIN">>, [<<"#secret">>, <<"rem">>]),
        ok = cmd(?PEER, <<"MODE">>, [<<"#secret">>, <<"+s">>]),
        send(Alice, <<"NAMES #secret">>),
        ?assertNot(has(recv_until(Alice, <<" 366 ">>), <<" 353 ">>)),
        %% A member that kicks itself empties the remote channel.
        ok = cmd(?PEER, <<"NJOIN">>, [<<"#self">>, <<"@leafy">>]),
        ok = cmd(?LEAFY, <<"KICK">>, [<<"#self">>, <<"leafy">>]),
        ?assertEqual([], mnesia:dirty_read(remote_channel, <<"#self">>)),
        %% Kicking the last local member releases the local channel.
        ok = cmd(?PEER, <<"NJOIN">>, [<<"#solo">>, <<"@rem">>]),
        ok = cmd(?REM, <<"KICK">>, [<<"#solo">>, <<"alice">>]),
        recv_until(Alice, <<"KICK #solo alice">>),
        ?assertEqual([], mnesia:dirty_read(channel, <<"#solo">>)),
        %% Multiline batches that reach nobody locally and are not routed back.
        lists:foreach(
            fun({Ref, Target}) ->
                ok = cmd(?REM, <<"BATCH">>, [<<"+", Ref/binary>>, <<"draft/multiline">>, Target]),
                ok = ircd_state:server_command(
                    ?PEER, ?REM, <<"PRIVMSG">>, [Target, <<"line">>], [{<<"batch">>, Ref}]
                ),
                ok = cmd(?REM, <<"BATCH">>, [<<"-", Ref/binary>>])
            end,
            [
                {<<"m1">>, <<"#room">>},
                {<<"m2">>, <<"#ghostchan">>},
                {<<"m3">>, <<"leafy">>},
                {<<"m4">>, <<"nobody">>}
            ]
        ),
        ?assertNot(has(sync(Alice), <<"PRIVMSG #room :line">>)),
        %% A local service with no operator online answers 401.
        send(Alice, <<"OPER oper opersecret">>),
        recv_until(Alice, <<" 381 ">>),
        send(Alice, <<"SERVICE loc * t :Local">>),
        recv_until(Alice, <<" 234 ">>),
        send(Alice, <<"QUIT">>),
        ?assertEqual(closed, wait_closed(Alice)),
        Bob = client(Port, <<"bob">>),
        send(Bob, <<"SQUERY loc :anyone">>),
        recv_until(Bob, <<" 401 bob loc ">>)
    after
        stop()
    end.

%%% Operator server commands, services, SQUIT, and link loss

operator_and_split() ->
    Port = start("oper"),
    try
        Alice = client(Port, <<"alice">>),
        send(Alice, <<"CAP REQ :batch">>),
        send(Alice, <<"JOIN #room">>),
        sync(Alice),
        send(Alice, <<"SQUIT peer.test">>),
        ?assert(has(recv_until(Alice, <<" 481 ">>), <<"Permission Denied">>)),
        send(Alice, <<"OPER oper opersecret">>),
        recv_until(Alice, <<" 381 ">>),
        Peer = handshake(Port, ?PEER),
        sync(Peer),
        Other = handshake(Port, <<"other.test">>),
        sync(Other),
        send(Peer, <<":peer.test SERVER leaf.test 2 2 :Leaf">>),
        send(Peer, <<":leaf.test SERVER deep.test 3 3 :Deep">>),
        send(Peer, <<":peer.test NICK rem 1 ruser rhost.test 7 + :Remote">>),
        send(Peer, <<":leaf.test NICK leafy 1 luser lhost.test 8 + :Leafy">>),
        send(Peer, <<":deep.test NICK deepy 2 duser dhost.test 9 + :Deepy">>),
        send(Peer, <<":peer.test SERVICE helper * *.test 0 * :Help">>),
        send(Peer, <<":rem!ruser@rhost.test JOIN #room">>),
        send(Peer, <<":deepy!duser@dhost.test JOIN #room">>),
        send(Peer, <<":deepy!duser@dhost.test JOIN #deeponly">>),
        recv_until(Alice, <<"deepy!duser@dhost.test JOIN #room">>),
        recv_until(Other, <<"JOIN #deeponly">>),
        %% Services.
        send(Alice, <<"SERVLIST">>),
        ?assert(has(recv_until(Alice, <<" 235 ">>), <<" 234 alice helper peer.test">>)),
        send(Alice, <<"SERVLIST * nomatch">>),
        ?assertNot(has(recv_until(Alice, <<" 235 ">>), <<" 234 ">>)),
        send(Alice, <<"SQUERY helper :hi-service">>),
        recv_until(Peer, <<"SQUERY helper :hi-service">>),
        send(Alice, <<"SQUERY">>),
        recv_until(Alice, <<" 411 ">>),
        send(Alice, <<"SQUERY helper">>),
        recv_until(Alice, <<" 412 ">>),
        send(Alice, <<"SQUERY helper :">>),
        recv_until(Alice, <<" 412 ">>),
        send(Alice, <<"SQUERY nosuch :x">>),
        recv_until(Alice, <<" 401 ">>),
        send(Alice, <<"SERVICE local * svc :Local service">>),
        recv_until(Alice, <<" 234 alice local irc.test">>),
        send(Alice, <<"SERVICE local2 * svc">>),
        recv_until(Alice, <<" 234 alice local2">>),
        send(Alice, <<"SERVICE rem * svc :x">>),
        recv_until(Alice, <<" 433 ">>),
        send(Alice, <<"SERVICE 1bad * svc :x">>),
        recv_until(Alice, <<" 432 ">>),
        send(Alice, <<"SERVICE x">>),
        recv_until(Alice, <<" 461 ">>),
        send(Alice, <<"SQUERY local :to-opers">>),
        recv_until(Alice, <<"NOTICE local :to-opers">>),
        %% CONNECT asks the configured connector to retry now.
        send(Alice, <<"CONNECT peer.test">>),
        recv_until(Alice, <<"Connect attempt for peer.test">>),
        send(Alice, <<"CONNECT nowhere.test">>),
        recv_until(Alice, <<" 402 ">>),
        send(Alice, <<"CONNECT">>),
        recv_until(Alice, <<" 461 ">>),
        ?assertEqual({error, peer_unavailable}, ircd_links:connect_peer(<<"nowhere.test">>)),
        ?assertEqual(
            {error, peer_unavailable}, ircd_links:send(<<"nowhere.test">>, <<"PING x\r\n">>)
        ),
        %% SQUIT from a peer removes the leaf, the server behind it, and their users.
        send(Alice, <<"SQUIT nowhere.test">>),
        recv_until(Alice, <<" 402 ">>),
        send(Alice, <<"SQUIT">>),
        recv_until(Alice, <<" 461 ">>),
        send(Peer, <<":peer.test SQUIT leaf.test :split">>),
        Split = recv_until(Other, <<"SQUIT deep.test">>),
        ?assert(has(Split, <<"SQUIT leaf.test">>) orelse has(sync(Other), <<"SQUIT leaf.test">>)),
        ?assert(has(recv_until(Alice, <<"deepy!duser@dhost.test QUIT">>), <<"BATCH +">>)),
        ?assertEqual([], [K || K <- mnesia:dirty_all_keys(remote_client), K =:= <<"deepy">>]),
        ?assertEqual([], mnesia:dirty_read(remote_channel, <<"#deeponly">>)),
        %% The released nickname is held for the resource delay.
        send(Alice, <<"NICK deepy">>),
        Held = sync(Alice),
        ?assertNot(has(Held, <<"NICK :deepy">>)),
        ?assertNot(has(Held, <<"NICK deepy">>)),
        %% An operator SQUIT of a direct peer.
        send(Alice, <<"SQUIT other.test :bye">>),
        recv_until(Alice, <<"SQUIT other.test">>),
        %% Closing the peer socket splits everything reached through it.
        gen_tcp:close(Peer),
        recv_until(Alice, <<"rem!ruser@rhost.test QUIT">>),
        wait_until(fun() -> mnesia:dirty_all_keys(remote_client) =:= [] end),
        ?assertEqual([], mnesia:dirty_read(service, <<"helper">>)),
        send(Alice, <<"WHOIS rem">>),
        recv_until(Alice, <<" 401 ">>)
    after
        stop()
    end.

%%% Helpers

start(Tag) ->
    Dir = filename:join(
        "/tmp",
        "ircd-covlink-" ++ Tag ++ "-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "db")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config(filename:join(Dir, "db"))),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    [erase(Key) || {{buf, _} = Key, _} <- get()],
    listener_port().

stop() ->
    _ = application:stop(ircd),
    os:unsetenv("IRCD_CONFIG").

config(Db) ->
    Link = fun(Name, TLS) ->
        [
            <<"{\"name\":\"">>,
            Name,
            <<"\",\"host\":\"127.0.0.1\",\"port\":1,\"password\":\"linksecret\",\"tls\":">>,
            TLS,
            <<"}">>
        ]
    end,
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"emergency\",\"log_format\":\"text\",\"retention\":\"transient\",\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\",\"operators\":[{\"name\":\"oper\",\"password\":\"opersecret\"}],">>,
        <<"\"server_links\":[">>,
        lists:join(<<",">>, [
            Link(<<"peer.test">>, <<"false">>),
            Link(<<"other.test">>, <<"false">>),
            Link(<<"third.test">>, <<"false">>),
            Link(<<"tlspeer.test">>, <<"true">>)
        ]),
        <<"]}">>
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

%% Round trip a PING and return what arrived before the PONG. Inbound peer
%% sessions and clients both answer PING after earlier lines are handled.
sync(Sock) ->
    N = integer_to_binary(erlang:unique_integer([positive])),
    Token = <<"sync", N/binary>>,
    send(Sock, <<"PING ", Token/binary>>),
    recv_until(Sock, Token).

recv_until(Sock, Needle) ->
    recv_until(Sock, Needle, 3000, true).

%% Read until Needle appears and its line is complete. Bytes after that line
%% stay buffered for the next call. With Strict, a timeout fails the test.
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
                {ok, Bin} ->
                    recv_loop(Sock, Needle, Deadline, Strict, <<Acc/binary, Bin/binary>>);
                _ when Strict ->
                    error({no_match, Needle, Acc});
                _ ->
                    Acc
            end
    end.

line_end(Acc, Needle) ->
    Size = byte_size(Needle) - 2,
    case binary:match(Acc, Needle) of
        {Pos, Len} when Size >= 0, binary_part(Needle, Size, 2) =:= <<"\r\n">> ->
            {ok, Pos + Len};
        {Pos, Len} ->
            From = Pos + Len,
            case binary:match(Acc, <<"\r\n">>, [{scope, {From, byte_size(Acc) - From}}]) of
                {E, 2} -> {ok, E + 2};
                nomatch -> nomatch
            end;
        nomatch ->
            nomatch
    end.

wait_closed(Sock) ->
    case gen_tcp:recv(Sock, 0, 3000) of
        {ok, _} -> wait_closed(Sock);
        {error, closed} -> closed;
        {error, Reason} -> Reason
    end.

wait_until(Fun) ->
    wait_until(Fun, 50).

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

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.
