-module(ircd_route_tests).
-include_lib("eunit/include/eunit.hrl").

%% RFC-oriented decisions that do not need a live listener.

channel_limits_test() ->
    ?assertEqual(10, ircd_route:max_channels()),
    ?assert(ircd_route:channel_allowed(9, 10)),
    ?assertNot(ircd_route:channel_allowed(10, 10)).

nick_delay_and_collision_test() ->
    Now = 1000,
    ?assert(ircd_route:nick_delay_blocked(key, Now, #{key => Now + 1})),
    ?assertNot(ircd_route:nick_delay_blocked(key, Now, #{key => Now})),
    ?assertEqual(kill_both, ircd_route:nick_collision(true, false)),
    ?assertEqual(kill_both, ircd_route:nick_collision(false, true)),
    ?assertEqual(ok, ircd_route:nick_collision(false, false)).

burst_order_and_netsplit_test() ->
    Peer = #{
        name => <<"peer.test">>, hop => 1, parent => <<"irc.test">>, adjacent => <<"peer.test">>
    },
    Leaf = #{
        name => <<"leaf.test">>, hop => 2, parent => <<"peer.test">>, adjacent => <<"peer.test">>
    },
    ?assertEqual([Peer, Leaf], ircd_route:burst_order([Leaf, Peer])),
    Behind = ircd_route:servers_behind(<<"peer.test">>, [Peer, Leaf]),
    ?assert(lists:member(<<"peer.test">>, Behind)),
    ?assert(lists:member(<<"leaf.test">>, Behind)),
    ?assertEqual([<<"leaf.test">>], ircd_route:servers_behind(<<"leaf.test">>, [Peer, Leaf])),
    ?assertNot(ircd_route:should_forward(<<"peer.test">>, <<"peer.test">>)),
    ?assert(ircd_route:should_forward(<<"peer.test">>, <<"other.test">>)).

server_introduction_test() ->
    Servers = [
        #{
            name => <<"peer.test">>,
            hop => 1,
            token => <<"1">>,
            adjacent => <<"peer.test">>,
            parent => <<"irc.test">>,
            info => <<>>
        }
    ],
    Intro = #{
        name => <<"leaf.test">>,
        hop => 2,
        token => <<"2">>,
        parent => <<"peer.test">>,
        info => <<"leaf">>
    },
    ?assertMatch(
        {ok, #{hop := 2, adjacent := <<"peer.test">>}},
        ircd_route:accept_server(<<"irc.test">>, <<"peer.test">>, Intro, Servers)
    ),
    ?assertEqual(
        {error, duplicate_route},
        ircd_route:accept_server(
            <<"irc.test">>, <<"peer.test">>, Intro#{name => <<"peer.test">>}, Servers
        )
    ),
    ?assertEqual(
        {error, loop},
        ircd_route:accept_server(
            <<"irc.test">>, <<"peer.test">>, Intro#{name => <<"irc.test">>, hop => 2}, []
        )
    ),
    ?assertEqual(
        {error, bad_hop},
        ircd_route:accept_server(<<"irc.test">>, <<"peer.test">>, Intro#{hop => 4}, Servers)
    ).
