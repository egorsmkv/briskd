-module(briskd_route_tests).
-include_lib("eunit/include/eunit.hrl").

%% RFC-oriented decisions that do not need a live listener.

channel_limits_test() ->
    ?assertEqual(10, briskd_route:max_channels()),
    ?assert(briskd_route:channel_allowed(9, 10)),
    ?assertNot(briskd_route:channel_allowed(10, 10)).

nick_delay_and_collision_test() ->
    Now = 1000,
    ?assert(briskd_route:nick_delay_blocked(key, Now, #{key => Now + 1})),
    ?assertNot(briskd_route:nick_delay_blocked(key, Now, #{key => Now})),
    ?assertEqual(kill_both, briskd_route:nick_collision(true, false)),
    ?assertEqual(kill_both, briskd_route:nick_collision(false, true)),
    ?assertEqual(ok, briskd_route:nick_collision(false, false)).

burst_order_and_netsplit_test() ->
    Peer = #{
        name => <<"peer.test">>, hop => 1, parent => <<"irc.test">>, adjacent => <<"peer.test">>
    },
    Leaf = #{
        name => <<"leaf.test">>, hop => 2, parent => <<"peer.test">>, adjacent => <<"peer.test">>
    },
    ?assertEqual([Peer, Leaf], briskd_route:burst_order([Leaf, Peer])),
    Behind = briskd_route:servers_behind(<<"peer.test">>, [Peer, Leaf]),
    ?assert(lists:member(<<"peer.test">>, Behind)),
    ?assert(lists:member(<<"leaf.test">>, Behind)),
    ?assertEqual([<<"leaf.test">>], briskd_route:servers_behind(<<"leaf.test">>, [Peer, Leaf])),
    ?assertNot(briskd_route:should_forward(<<"peer.test">>, <<"peer.test">>)),
    ?assert(briskd_route:should_forward(<<"peer.test">>, <<"other.test">>)).

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
        briskd_route:accept_server(<<"irc.test">>, <<"peer.test">>, Intro, Servers)
    ),
    ?assertEqual(
        {error, duplicate_route},
        briskd_route:accept_server(
            <<"irc.test">>, <<"peer.test">>, Intro#{name => <<"peer.test">>}, Servers
        )
    ),
    ?assertEqual(
        {error, loop},
        briskd_route:accept_server(
            <<"irc.test">>, <<"peer.test">>, Intro#{name => <<"irc.test">>, hop => 2}, []
        )
    ),
    ?assertEqual(
        {error, bad_hop},
        briskd_route:accept_server(<<"irc.test">>, <<"peer.test">>, Intro#{hop => 4}, Servers)
    ).
