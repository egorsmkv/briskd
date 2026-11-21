-module(briskd_overrides_tests).
-include_lib("eunit/include/eunit.hrl").

base() ->
    #{
        features => #{
            reactions => true,
            replies => true,
            typing => true,
            editing => true,
            redaction => true,
            link_previews => true
        },
        chathistory => true,
        history_limit => 100,
        account_registration => true,
        account_registration_before_connect => true,
        account_registration_email_required => false,
        multiclient => false,
        account_rejoin => false,
        max_accounts => 100000,
        e2ee => #{max_devices => 4},
        calls => null,
        voice => null,
        files => null,
        search => null,
        dronebl => #{enabled => false, zone => <<"dnsbl.dronebl.org">>},
        utf8_only => false,
        monitor_limit => 100,
        resource_delay => 60,
        level => info
    }.

validate_test() ->
    ?assertEqual({ok, false}, briskd_overrides:validate(<<"chathistory">>, <<"false">>)),
    ?assertEqual({ok, true}, briskd_overrides:validate(<<"features.typing">>, <<"true">>)),
    ?assertEqual({ok, 250}, briskd_overrides:validate(<<"history_limit">>, <<"250">>)),
    %% Bounds are inclusive.
    ?assertEqual({ok, 0}, briskd_overrides:validate(<<"resource_delay">>, <<"0">>)),
    ?assertEqual({ok, 86400}, briskd_overrides:validate(<<"resource_delay">>, <<"86400">>)),
    ?assertEqual(
        {error, invalid_value}, briskd_overrides:validate(<<"resource_delay">>, <<"86401">>)
    ),
    ?assertEqual({error, invalid_value}, briskd_overrides:validate(<<"history_limit">>, <<"0">>)),
    ?assertEqual({error, invalid_value}, briskd_overrides:validate(<<"history_limit">>, <<"x">>)),
    ?assertEqual({error, invalid_value}, briskd_overrides:validate(<<"chathistory">>, <<"yes">>)),
    ?assertEqual({error, unknown_control}, briskd_overrides:validate(<<"name">>, <<"x">>)),
    ?assertEqual(
        {error, unknown_control}, briskd_overrides:validate(<<"features.nope">>, <<"true">>)
    ).

apply_test() ->
    Base = base(),
    ?assertEqual(Base, briskd_overrides:apply(Base, #{})),
    C = briskd_overrides:apply(Base, #{
        <<"chathistory">> => false,
        <<"features.reactions">> => false,
        <<"history_limit">> => 500,
        <<"e2ee">> => false,
        <<"dronebl">> => true,
        <<"gone.in.a.later.version">> => true
    }),
    ?assertEqual(false, maps:get(chathistory, C)),
    ?assertMatch(#{reactions := false, typing := true}, maps:get(features, C)),
    ?assertEqual(500, maps:get(history_limit, C)),
    %% A subsystem switched off is unset; DroneBL keeps its settings.
    ?assertEqual(null, maps:get(e2ee, C)),
    ?assertEqual(#{enabled => true, zone => <<"dnsbl.dronebl.org">>}, maps:get(dronebl, C)),
    %% A subsystem the file does not configure stays off.
    ?assertEqual(null, maps:get(calls, briskd_overrides:apply(Base, #{<<"calls">> => true}))),
    %% Switched back on, it is the file's section again.
    Off = briskd_overrides:apply(Base, #{<<"e2ee">> => false}),
    ?assertEqual(
        #{max_devices => 4}, maps:get(e2ee, briskd_overrides:effective(Off, Base, #{}))
    ).

effective_keeps_other_settings_test() ->
    Base = base(),
    %% The log level changed at runtime (briskdctl) is not one of the controls.
    Current = (briskd_overrides:apply(Base, #{<<"chathistory">> => false}))#{level => debug},
    E = briskd_overrides:effective(Current, Base, #{}),
    ?assertEqual(true, maps:get(chathistory, E)),
    ?assertEqual(debug, maps:get(level, E)).

describe_test() ->
    Base = base(),
    Overrides = #{<<"multiclient">> => true},
    Rows = briskd_overrides:describe(briskd_overrides:apply(Base, Overrides), Base, Overrides),
    Row = fun(Key) -> hd([R || #{key := K} = R <- Rows, K =:= Key]) end,
    ?assertMatch(
        #{value := true, default := false, overridden := true, type := <<"boolean">>},
        Row(<<"multiclient">>)
    ),
    ?assertMatch(
        #{value := 100, overridden := false, type := <<"integer">>, min := 1, max := 10000},
        Row(<<"history_limit">>)
    ),
    ?assertMatch(#{available := false, value := false}, Row(<<"calls">>)),
    ?assertMatch(#{available := true, value := true}, Row(<<"e2ee">>)),
    ?assertMatch(#{group := <<"chat">>, value := true}, Row(<<"features.redaction">>)),
    ?assert(briskd_overrides:available(<<"e2ee">>, Base)),
    ?assertNot(briskd_overrides:available(<<"calls">>, Base)),
    ?assertNot(briskd_overrides:available(<<"nope">>, Base)).
