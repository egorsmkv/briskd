-module(briskd_cap_tests).
-include_lib("eunit/include/eunit.hrl").

%% Capability decisions against the shipped briskd_cap table.

pack_splits_on_the_byte_budget_test() ->
    Names = [binary:copy(<<"a">>, 20) || _ <- lists:seq(1, 5)],
    ?assertEqual(3, length(briskd_cap:pack(Names, 45))),
    Huge = binary:copy(<<"z">>, 50),
    ?assertEqual([Huge], briskd_cap:pack([Huge], 10)),
    ?assertEqual([<<>>], briskd_cap:pack([], 10)).

offered_caps_cover_the_ircv3_registry_test() ->
    Offered = briskd_cap:offered(),
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
        ?assertNot(lists:keymember(<<"sts">>, 1, briskd_cap:advertised(Pid))),
        ?assertEqual({nak, <<"sts">>}, briskd_cap:request(Pid, [<<"sts">>]))
    end),
    Previous = persistent_term:get({briskd_state, config}, undefined),
    persistent_term:put(
        {briskd_state, config},
        #{sts => #{port => 6697, duration => 300, preload => false}}
    ),
    try
        with_cap(fun(Pid) ->
            ?assertEqual(
                {<<"sts">>, <<"port=6697">>},
                lists:keyfind(<<"sts">>, 1, briskd_cap:advertised(Pid))
            ),
            ok = briskd_cap:set_info(Pid, secure, true),
            ?assertEqual(
                {<<"sts">>, <<"duration=300">>},
                lists:keyfind(<<"sts">>, 1, briskd_cap:advertised(Pid))
            ),
            ?assertEqual({nak, <<"sts">>}, briskd_cap:request(Pid, [<<"sts">>]))
        end)
    after
        case Previous of
            undefined -> persistent_term:erase({briskd_state, config});
            _ -> persistent_term:put({briskd_state, config}, Previous)
        end
    end.

capability_values_test() ->
    with_cap(fun(Pid) ->
        Advertised = briskd_cap:advertised(Pid),
        ?assertEqual(
            {<<"sasl">>, <<"EXTERNAL,PLAIN,SCRAM-SHA-256">>},
            lists:keyfind(<<"sasl">>, 1, Advertised)
        ),
        {_, <<_/binary>> = Multiline} = lists:keyfind(<<"draft/multiline">>, 1, Advertised),
        ?assertMatch({match, _}, re:run(Multiline, <<"max-bytes=[0-9]+">>)),
        ?assertEqual({<<"batch">>, undefined}, lists:keyfind(<<"batch">>, 1, Advertised))
    end).

atomic_request_and_version_test() ->
    with_cap(fun(Pid) ->
        ?assertEqual({nak, <<"bogus">>}, briskd_cap:request(Pid, [<<"bogus">>])),
        ?assertEqual([], briskd_cap:list_names(Pid)),
        ?assertEqual(
            {nak, <<"message-tags bogus">>},
            briskd_cap:request(Pid, [<<"message-tags bogus">>])
        ),
        ?assertEqual([], briskd_cap:list_names(Pid)),
        ?assertEqual(
            {nak, <<"message-tags=1">>}, briskd_cap:request(Pid, [<<"message-tags=1">>])
        ),
        ?assertEqual({ack, <<"message-tags">>}, briskd_cap:request(Pid, [<<"message-tags">>])),
        ?assertEqual({ack, <<"message-tags">>}, briskd_cap:request(Pid, [<<"message-tags">>])),
        ?assertEqual({ack, <<"-batch">>}, briskd_cap:request(Pid, [<<"-batch">>])),
        ?assertEqual({ack, <<"-message-tags">>}, briskd_cap:request(Pid, [<<"-message-tags">>])),
        ?assertEqual([], briskd_cap:list_names(Pid)),
        ?assertEqual({ack, <<"cap-notify">>}, briskd_cap:request(Pid, [<<"cap-notify">>])),
        ?assertEqual({ack, <<"-cap-notify">>}, briskd_cap:request(Pid, [<<"-cap-notify">>])),
        ?assertNot(lists:member(<<"cap-notify">>, briskd_cap:list_names(Pid))),
        ok = briskd_cap:note_ls(Pid, [<<"LS">>, <<"302">>]),
        ?assertEqual([<<"cap-notify">>], briskd_cap:list_names(Pid)),
        ?assertEqual({nak, <<"-cap-notify">>}, briskd_cap:request(Pid, [<<"-cap-notify">>])),
        ?assert(lists:member(<<"cap-notify">>, briskd_cap:list_names(Pid))),
        ok = briskd_cap:note_ls(Pid, [<<"LS">>]),
        ok = briskd_cap:note_ls(Pid, [<<"LS">>, <<"301">>]),
        ?assertEqual(302, maps:get(version, briskd_cap:state(Pid))),
        ?assertEqual(
            {nak, <<"-cap-notify message-tags">>},
            briskd_cap:request(Pid, [
                <<"-cap-notify message-tags">>
            ])
        ),
        ?assertNot(briskd_cap:enabled(Pid, <<"message-tags">>)),
        ?assertEqual({ack, <<>>}, briskd_cap:request(Pid, [])),
        ?assertEqual(
            {ack, <<"batch labeled-response message-tags">>},
            briskd_cap:request(Pid, [<<"batch labeled-response message-tags">>])
        )
    end).

label_requires_the_three_caps_and_a_short_value_test() ->
    Off = #{version => 302, enabled => #{}, negotiating => false, welcomed => false},
    ?assertEqual(undefined, briskd_cap:label(Off, [{<<"label">>, <<"one">>}])),
    On = Off#{
        enabled => #{
            <<"batch">> => true,
            <<"labeled-response">> => true,
            <<"message-tags">> => true
        }
    },
    ?assertEqual(<<"one">>, briskd_cap:label(On, [{<<"label">>, <<"one">>}])),
    ?assertEqual(undefined, briskd_cap:label(On, [{<<"label">>, <<>>}])),
    ?assertEqual(undefined, briskd_cap:label(On, [])),
    ?assertEqual(undefined, briskd_cap:label(On, [{<<"label">>, binary:copy(<<"a">>, 65)}])),
    ?assertEqual(
        binary:copy(<<"a">>, 64),
        briskd_cap:label(On, [{<<"label">>, binary:copy(<<"a">>, 64)}])
    ).

with_cap(Fun) ->
    case ets:whereis(briskd_caps) of
        undefined -> ets:new(briskd_caps, [named_table, public, set]);
        _ -> ok
    end,
    Pid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    true = briskd_cap:connect(Pid),
    try
        Fun(Pid)
    after
        briskd_cap:disconnect(Pid),
        Pid ! stop
    end.
