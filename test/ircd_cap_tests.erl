-module(ircd_cap_tests).
-include_lib("eunit/include/eunit.hrl").

%% Capability decisions against the shipped ircd_cap table.

pack_splits_on_the_byte_budget_test() ->
    Names = [binary:copy(<<"a">>, 20) || _ <- lists:seq(1, 5)],
    ?assertEqual(3, length(ircd_cap:pack(Names, 45))),
    Huge = binary:copy(<<"z">>, 50),
    ?assertEqual([Huge], ircd_cap:pack([Huge], 10)),
    ?assertEqual([<<>>], ircd_cap:pack([], 10)).

offered_caps_cover_the_ircv3_registry_test() ->
    Offered = ircd_cap:offered(),
    ?assertEqual(lists:sort(Offered), Offered),
    lists:foreach(
        fun(Name) -> ?assert(lists:member(Name, Offered)) end,
        [
            <<"account-notify">>,
            <<"account-tag">>,
            <<"away-notify">>,
            <<"batch">>,
            <<"cap-notify">>,
            <<"chghost">>,
            <<"echo-message">>,
            <<"extended-join">>,
            <<"extended-monitor">>,
            <<"invite-notify">>,
            <<"labeled-response">>,
            <<"message-tags">>,
            <<"multi-prefix">>,
            <<"no-implicit-names">>,
            <<"sasl">>,
            <<"server-time">>,
            <<"setname">>,
            <<"standard-replies">>,
            <<"sts">>,
            <<"userhost-in-names">>,
            <<"draft/account-registration">>,
            <<"draft/channel-rename">>,
            <<"draft/chathistory">>,
            <<"draft/extended-isupport">>,
            <<"draft/message-redaction">>,
            <<"draft/metadata-2">>,
            <<"draft/multiline">>,
            <<"draft/oper-tag">>,
            <<"draft/pre-away">>,
            <<"draft/read-marker">>
        ]
    ).

sts_is_advertised_only_when_configured_and_never_requested_test() ->
    with_cap(fun(Pid) ->
        ?assertNot(lists:keymember(<<"sts">>, 1, ircd_cap:advertised(Pid))),
        ?assertEqual({nak, <<"sts">>}, ircd_cap:request(Pid, [<<"sts">>]))
    end),
    Previous = persistent_term:get({ircd_state, config}, undefined),
    persistent_term:put(
        {ircd_state, config},
        #{sts => #{port => 6697, duration => 300, preload => false}}
    ),
    try
        with_cap(fun(Pid) ->
            ?assertEqual(
                {<<"sts">>, <<"port=6697">>},
                lists:keyfind(<<"sts">>, 1, ircd_cap:advertised(Pid))
            ),
            ok = ircd_cap:set_info(Pid, secure, true),
            ?assertEqual(
                {<<"sts">>, <<"duration=300">>},
                lists:keyfind(<<"sts">>, 1, ircd_cap:advertised(Pid))
            ),
            ?assertEqual({nak, <<"sts">>}, ircd_cap:request(Pid, [<<"sts">>]))
        end)
    after
        case Previous of
            undefined -> persistent_term:erase({ircd_state, config});
            _ -> persistent_term:put({ircd_state, config}, Previous)
        end
    end.

capability_values_test() ->
    with_cap(fun(Pid) ->
        Advertised = ircd_cap:advertised(Pid),
        ?assertEqual(
            {<<"sasl">>, <<"EXTERNAL,PLAIN,SCRAM-SHA-256">>},
            lists:keyfind(<<"sasl">>, 1, Advertised)
        ),
        {_, Multiline} = lists:keyfind(<<"draft/multiline">>, 1, Advertised),
        ?assertMatch({match, _}, re:run(Multiline, <<"max-bytes=[0-9]+">>)),
        ?assertEqual({<<"batch">>, undefined}, lists:keyfind(<<"batch">>, 1, Advertised))
    end).

atomic_request_and_version_test() ->
    with_cap(fun(Pid) ->
        ?assertEqual({nak, <<"bogus">>}, ircd_cap:request(Pid, [<<"bogus">>])),
        ?assertEqual([], ircd_cap:list_names(Pid)),
        ?assertEqual(
            {nak, <<"message-tags bogus">>},
            ircd_cap:request(Pid, [<<"message-tags bogus">>])
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
