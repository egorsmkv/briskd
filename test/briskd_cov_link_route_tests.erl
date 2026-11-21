-module(briskd_cov_link_route_tests).
-include_lib("eunit/include/eunit.hrl").

%% Pure RFC 2813 routing decisions in briskd_route: server introductions behind
%% an adjacent peer, hop validation, loops, and the split set.

servers() ->
    [
        server(<<"peer.test">>, 1, <<"peer.test">>, <<"irc.test">>),
        server(<<"leaf.test">>, 2, <<"peer.test">>, <<"peer.test">>),
        server(<<"other.test">>, 1, <<"other.test">>, <<"irc.test">>)
    ].

server(Name, Hop, Adjacent, Parent) ->
    #{
        name => Name,
        hop => Hop,
        token => <<"1">>,
        adjacent => Adjacent,
        parent => Parent,
        info => <<"i">>
    }.

intro(Name, Hop, Parent) ->
    #{name => Name, hop => Hop, token => <<"7">>, parent => Parent, info => <<"x">>}.

accept(Ingress, Intro) ->
    briskd_route:accept_server(<<"irc.test">>, Ingress, Intro, servers()).

invalid_introduction_test() ->
    ?assertEqual({error, invalid_server}, accept(<<"peer.test">>, intro(<<"-bad">>, 2, <<"x">>))),
    ?assertEqual(
        {error, invalid_server}, accept(<<"peer.test">>, intro(<<"ok.test">>, <<"2">>, <<"x">>))
    ),
    ?assertEqual(
        {error, invalid_server},
        accept(<<"peer.test">>, (intro(<<"ok.test">>, 2, <<"x">>))#{token => 7})
    ),
    ?assertEqual({error, invalid_server}, accept(<<"peer.test">>, intro(42, 2, <<"x">>))),
    %% Name length is capped at 63 octets by the server-name pattern.
    Long = binary:copy(<<"a">>, 64),
    ?assertEqual({error, invalid_server}, accept(<<"peer.test">>, intro(Long, 2, <<"x">>))).

parent_is_local_server_test() ->
    %% A peer may not claim that a new server hangs off this server.
    ?assertEqual(
        {error, bad_hop}, accept(<<"peer.test">>, intro(<<"new.test">>, 2, <<"IRC.test">>))
    ).

direct_child_of_ingress_test() ->
    ?assertMatch(
        {ok, #{name := <<"new.test">>, hop := 2, adjacent := <<"peer.test">>}},
        accept(<<"peer.test">>, intro(<<"new.test">>, 2, <<"PEER.test">>))
    ),
    ?assertEqual(
        {error, bad_hop}, accept(<<"peer.test">>, intro(<<"new.test">>, 3, <<"peer.test">>))
    ),
    %% Without an explicit parent, the ingress link is the parent.
    ?assertMatch(
        {ok, #{parent := <<"peer.test">>}},
        accept(<<"peer.test">>, maps:remove(parent, intro(<<"new.test">>, 2, <<"x">>)))
    ).

multi_hop_introduction_test() ->
    ?assertEqual(
        {ok, #{
            name => <<"deep.test">>,
            hop => 3,
            token => <<"7">>,
            adjacent => <<"peer.test">>,
            parent => <<"leaf.test">>,
            info => <<"x">>
        }},
        accept(<<"peer.test">>, intro(<<"deep.test">>, 3, <<"leaf.test">>))
    ),
    ?assertEqual(
        {error, bad_hop}, accept(<<"peer.test">>, intro(<<"deep.test">>, 4, <<"leaf.test">>))
    ),
    ?assertEqual(
        {error, unknown_parent},
        accept(<<"peer.test">>, intro(<<"deep.test">>, 3, <<"nowhere.test">>))
    ),
    %% other.test may not introduce a server behind a parent reached via peer.test.
    ?assertEqual(
        {error, loop}, accept(<<"other.test">>, intro(<<"deep.test">>, 3, <<"leaf.test">>))
    ).

servers_behind_cycle_test() ->
    %% A corrupt parent cycle must terminate rather than recurse forever.
    Cycle = [
        server(<<"a.test">>, 2, <<"b.test">>, <<"b.test">>),
        server(<<"b.test">>, 2, <<"a.test">>, <<"a.test">>)
    ],
    ?assertEqual([], briskd_route:servers_behind(<<"c.test">>, Cycle)),
    ?assertEqual(
        [<<"a.test">>, <<"b.test">>], briskd_route:servers_behind(<<"a.test">>, Cycle)
    ),
    %% A server without a binary parent stops the walk.
    Root = [(server(<<"r.test">>, 1, <<"r.test">>, <<"irc.test">>))#{parent => undefined}],
    ?assertEqual([], briskd_route:servers_behind(<<"irc.test">>, Root)).

limits_test() ->
    ?assertEqual(10, briskd_route:max_channels()),
    ?assertEqual(60, briskd_route:resource_delay_seconds()),
    ?assert(briskd_route:channel_allowed(9, 10)),
    ?assertNot(briskd_route:channel_allowed(10, 10)),
    ?assert(briskd_route:nick_delay_blocked(k, 5, #{k => 6})),
    ?assertNot(briskd_route:nick_delay_blocked(k, 6, #{k => 6})),
    ?assertNot(briskd_route:nick_delay_blocked(k, 6, #{})).
