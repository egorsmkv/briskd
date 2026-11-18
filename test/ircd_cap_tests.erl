-module(ircd_cap_tests).
-include_lib("eunit/include/eunit.hrl").

%% Capability decisions against the shipped ircd_cap table.

pack_splits_on_the_byte_budget_test() ->
    Names = [binary:copy(<<"a">>, 20) || _ <- lists:seq(1, 5)],
    ?assertEqual(3, length(ircd_cap:pack(Names, 45))),
    Huge = binary:copy(<<"z">>, 50),
    ?assertEqual([Huge], ircd_cap:pack([Huge], 10)),
    ?assertEqual([<<>>], ircd_cap:pack([], 10)).

offered_caps_are_the_four_implemented_names_test() ->
    ?assertEqual(
        [<<"batch">>, <<"cap-notify">>, <<"labeled-response">>, <<"message-tags">>],
        ircd_cap:offered()
    ).

atomic_request_and_version_test() ->
    with_cap(fun(Pid) ->
        ?assertEqual({nak, <<"sasl">>}, ircd_cap:request(Pid, [<<"sasl">>])),
        ?assertEqual([], ircd_cap:list_names(Pid)),
        ?assertEqual(
            {nak, <<"message-tags sasl">>},
            ircd_cap:request(Pid, [<<"message-tags sasl">>])
        ),
        ?assertEqual([], ircd_cap:list_names(Pid)),
        ?assertEqual(
            {nak, <<"message-tags=1">>}, ircd_cap:request(Pid, [<<"message-tags=1">>])
        ),
        ?assertEqual({ack, <<"message-tags">>}, ircd_cap:request(Pid, [<<"message-tags">>])),
        ?assertEqual({ack, <<"message-tags">>}, ircd_cap:request(Pid, [<<"message-tags">>])),
        ?assertEqual({ack, <<"-batch">>}, ircd_cap:request(Pid, [<<"-batch">>])),
        ?assertEqual({ack, <<"-message-tags">>}, ircd_cap:request(Pid, [<<"-message-tags">>])),
        ?assertEqual([], ircd_cap:list_names(Pid)),
        ?assertEqual({ack, <<"cap-notify">>}, ircd_cap:request(Pid, [<<"cap-notify">>])),
        ?assertEqual({ack, <<"-cap-notify">>}, ircd_cap:request(Pid, [<<"-cap-notify">>])),
        ?assertNot(lists:member(<<"cap-notify">>, ircd_cap:list_names(Pid))),
        ok = ircd_cap:note_ls(Pid, [<<"LS">>, <<"302">>]),
        ?assertEqual([<<"cap-notify">>], ircd_cap:list_names(Pid)),
        ?assertEqual({nak, <<"-cap-notify">>}, ircd_cap:request(Pid, [<<"-cap-notify">>])),
        ?assert(lists:member(<<"cap-notify">>, ircd_cap:list_names(Pid))),
        ok = ircd_cap:note_ls(Pid, [<<"LS">>]),
        ok = ircd_cap:note_ls(Pid, [<<"LS">>, <<"301">>]),
        ?assertEqual(302, maps:get(version, ircd_cap:state(Pid))),
        ?assertEqual(
            {nak, <<"-cap-notify message-tags">>},
            ircd_cap:request(Pid, [
                <<"-cap-notify message-tags">>
            ])
        ),
        ?assertNot(ircd_cap:enabled(Pid, <<"message-tags">>)),
        ?assertEqual({ack, <<>>}, ircd_cap:request(Pid, [])),
        ?assertEqual(
            {ack, <<"batch labeled-response message-tags">>},
            ircd_cap:request(Pid, [<<"batch labeled-response message-tags">>])
        )
    end).

label_requires_the_three_caps_and_a_short_value_test() ->
    Off = #{version => 302, enabled => #{}, negotiating => false, welcomed => false},
    ?assertEqual(undefined, ircd_cap:label(Off, [{<<"label">>, <<"one">>}])),
    On = Off#{
        enabled => #{
            <<"batch">> => true,
            <<"labeled-response">> => true,
            <<"message-tags">> => true
        }
    },
    ?assertEqual(<<"one">>, ircd_cap:label(On, [{<<"label">>, <<"one">>}])),
    ?assertEqual(undefined, ircd_cap:label(On, [{<<"label">>, <<>>}])),
    ?assertEqual(undefined, ircd_cap:label(On, [])),
    ?assertEqual(undefined, ircd_cap:label(On, [{<<"label">>, binary:copy(<<"a">>, 65)}])),
    ?assertEqual(
        binary:copy(<<"a">>, 64),
        ircd_cap:label(On, [{<<"label">>, binary:copy(<<"a">>, 64)}])
    ).

with_cap(Fun) ->
    case ets:whereis(ircd_caps) of
        undefined -> ets:new(ircd_caps, [named_table, public, set]);
        _ -> ok
    end,
    Pid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    true = ircd_cap:connect(Pid),
    try
        Fun(Pid)
    after
        ircd_cap:disconnect(Pid),
        Pid ! stop
    end.
