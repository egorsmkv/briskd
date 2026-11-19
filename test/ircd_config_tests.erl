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
    {ok, Defaults} = ircd_config:load(Default),
    ?assertEqual(channels, maps:get(retention, Defaults)),
    ?assertEqual(100, maps:get(history_limit, Defaults)),
    ?assertEqual([], maps:get(administrators, Defaults)),
    ?assertEqual([], maps:get(channels, Defaults)),
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

log_level_test() ->
    Dir = filename:join(
        "/tmp", "ircd-config-log-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    lists:foreach(
        fun({Name, Expected}) ->
            Path = filename:join(Dir, Name ++ ".json"),
            ok = file:write_file(
                Path, <<"{\"log_level\":\"", (list_to_binary(Name))/binary, "\"}">>
            ),
            {ok, Config} = ircd_config:load(Path),
            ?assertEqual(Expected, maps:get(level, Config))
        end,
        [{"debug", debug}, {"info", info}, {"error", error}, {"trace", trace}]
    ),
    Bad = filename:join(Dir, "bad.json"),
    ok = file:write_file(Bad, <<"{\"log_level\":\"verbose\"}">>),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_log_level, <<"verbose">>}}}, ircd_config:load(Bad)
    ),
    #{level := Primary} = logger:get_primary_config(),
    {ok, #{level := Handler}} = logger:get_handler_config(default),
    try
        ok = ircd_log:apply_level(trace),
        ?assertMatch(#{level := all}, logger:get_primary_config()),
        ?assertMatch({ok, #{level := all}}, logger:get_handler_config(default)),
        ok = ircd_log:apply_level(error),
        ?assertMatch(#{level := error}, logger:get_primary_config())
    after
        ok = logger:set_primary_config(level, Primary),
        ok = logger:update_handler_config(default, level, Handler)
    end.

predefined_lists_test() ->
    Dir = filename:join(
        "/tmp", "ircd-config-lists-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "lists.json"),
    ok = file:write_file(Path, <<
        "{\"operators\":[{\"name\":\"oper\",\"password\":\"opersecret\"}],",
        "\"administrators\":[{\"nick\":\"Admin\",\"password\":\"adminsecret\"}],",
        "\"channels\":[{\"name\":\"#Lobby\",\"topic\":\"hello topic\",\"key\":\"roomkey\",",
        "\"limit\":5,\"modes\":\"+nt\"},{\"name\":\"&local\",\"modes\":\"a\"},",
        "{\"name\":\"+notes\"}]}"
    >>),
    {ok, Config} = ircd_config:load(Path),
    ?assertEqual([{<<"admin">>, <<"adminsecret">>}], maps:get(administrators, Config)),
    [Lobby, Local, Notes] = maps:get(channels, Config),
    ?assertEqual(<<"#Lobby">>, maps:get(name, Lobby)),
    ?assertEqual(<<"#lobby">>, maps:get(key, Lobby)),
    ?assertEqual(<<"hello topic">>, maps:get(topic, Lobby)),
    ?assertEqual(<<"roomkey">>, maps:get(password, Lobby)),
    ?assertEqual(5, maps:get(limit, Lobby)),
    ?assertEqual(#{$n => true, $t => true}, maps:get(flags, Lobby)),
    ?assertEqual(#{$a => true}, maps:get(flags, Local)),
    ?assertEqual(#{$t => true}, maps:get(flags, Notes)),
    DuplicateAdmin = filename:join(Dir, "dup-admin.json"),
    ok = file:write_file(DuplicateAdmin, <<
        "{\"administrators\":[",
        "{\"nick\":\"Admin\",\"password\":\"one\"},",
        "{\"nick\":\"admin\",\"password\":\"two\"}]}"
    >>),
    ?assertMatch(
        {error, {invalid_config, _, {duplicate_administrator, <<"admin">>}}},
        ircd_config:load(DuplicateAdmin)
    ),
    Shared = filename:join(Dir, "shared.json"),
    ok = file:write_file(Shared, <<
        "{\"operators\":[{\"name\":\"admin\",\"password\":\"opersecret\"}],",
        "\"administrators\":[{\"nick\":\"admin\",\"password\":\"adminsecret\"}]}"
    >>),
    ?assertMatch(
        {error, {invalid_config, _, {duplicate_administrator, <<"admin">>}}},
        ircd_config:load(Shared)
    ),
    BadNick = filename:join(Dir, "bad-nick.json"),
    ok = file:write_file(BadNick, <<
        "{\"administrators\":[{\"nick\":\"123\",\"password\":\"secret\"}]}"
    >>),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_administrator, <<"123">>}}},
        ircd_config:load(BadNick)
    ),
    DuplicateChannel = filename:join(Dir, "dup-channel.json"),
    ok = file:write_file(DuplicateChannel, <<
        "{\"channels\":[{\"name\":\"#Lobby\"},{\"name\":\"#lobby\"}]}"
    >>),
    ?assertMatch(
        {error, {invalid_config, _, {duplicate_channel, <<"#lobby">>}}},
        ircd_config:load(DuplicateChannel)
    ),
    BadChannel = filename:join(Dir, "bad-channel.json"),
    ok = file:write_file(BadChannel, <<"{\"channels\":[{\"name\":\"lobby\"}]}">>),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_channel, <<"lobby">>}}},
        ircd_config:load(BadChannel)
    ),
    Safe = filename:join(Dir, "safe.json"),
    ok = file:write_file(Safe, <<"{\"channels\":[{\"name\":\"!ABCDERoom\"}]}">>),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_channel, <<"!ABCDERoom">>}}},
        ircd_config:load(Safe)
    ),
    BadModes = filename:join(Dir, "modes.json"),
    ok = file:write_file(BadModes, <<"{\"channels\":[{\"name\":\"#room\",\"modes\":\"ps\"}]}">>),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_channel_modes, $s}}},
        ircd_config:load(BadModes)
    ),
    Anonymous = filename:join(Dir, "anon.json"),
    ok = file:write_file(Anonymous, <<"{\"channels\":[{\"name\":\"#room\",\"modes\":\"a\"}]}">>),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_channel_modes, $a}}},
        ircd_config:load(Anonymous)
    ),
    BadLimit = filename:join(Dir, "bad-limit.json"),
    ok = file:write_file(BadLimit, <<"{\"channels\":[{\"name\":\"#room\",\"limit\":0}]}">>),
    ?assertMatch(
        {error, {invalid_config, _, {invalid_channel_limit, 0}}},
        ircd_config:load(BadLimit)
    ).
