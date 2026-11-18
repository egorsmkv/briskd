-module(ircd_config_tests).
-include_lib("eunit/include/eunit.hrl").

secret_match_accepts_equal_binaries_test() ->
    ?assert(ircd_config:secret_match(<<"link-secret">>, <<"link-secret">>)).

secret_match_rejects_different_secrets_test() ->
    ?assertNot(ircd_config:secret_match(<<"link-secret">>, <<"link-secreu">>)),
    ?assertNot(ircd_config:secret_match(<<"link-secret">>, <<"link-secret-longer">>)),
    ?assertNot(ircd_config:secret_match(<<"a">>, <<>>)).

secret_match_rejects_non_binaries_test() ->
    ?assertNot(ircd_config:secret_match(null, null)),
    ?assertNot(ircd_config:secret_match(<<"secret">>, null)).

retention_setting_test() ->
    Dir = filename:join(
        "/tmp", "ircd-config-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Channels = filename:join(Dir, "channels.json"),
    ok = file:write_file(
        Channels,
        <<"{\"retention\":\"channels\",\"history_limit\":2}">>
    ),
    {ok, Enabled} = ircd_config:load(Channels),
    ?assertEqual(channels, maps:get(retention, Enabled)),
    ?assertEqual(2, maps:get(history_limit, Enabled)),
    Default = filename:join(Dir, "default.json"),
    ok = file:write_file(Default, <<"{}">>),
    {ok, Transient} = ircd_config:load(Default),
    ?assertEqual(transient, maps:get(retention, Transient)),
    ?assertEqual(100, maps:get(history_limit, Transient)),
    Bad = filename:join(Dir, "bad.json"),
    ok = file:write_file(Bad, <<"{\"retention\":\"forever\"}">>),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_retention, <<"forever">>}}}, ircd_config:load(Bad)
    ),
    BadLimit = filename:join(Dir, "limit.json"),
    ok = file:write_file(BadLimit, <<"{\"history_limit\":0}">>),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_history_limit, 0}}}, ircd_config:load(BadLimit)
    ),
    Explicit = filename:join(Dir, "transient.json"),
    ok = file:write_file(Explicit, <<"{\"retention\":\"transient\"}">>),
    {ok, Named} = ircd_config:load(Explicit),
    ?assertEqual(transient, maps:get(retention, Named)).
