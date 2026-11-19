-module(ircd_voice_tests).
-include_lib("eunit/include/eunit.hrl").

detect_opus_test() ->
    ?assertEqual({ok, <<"audio/ogg">>, <<"ogg">>}, ircd_voice:detect_opus(<<"OggS", 0, 2, 0, 0>>)),
    ?assertEqual(
        {ok, <<"audio/webm">>, <<"webm">>},
        ircd_voice:detect_opus(<<16#1A, 16#45, 16#DF, 16#A3, 1, 2, 3>>)
    ),
    ?assertEqual({error, unsupported_format}, ircd_voice:detect_opus(<<>>)),
    ?assertEqual({error, unsupported_format}, ircd_voice:detect_opus(<<"<html>bad</html>">>)),
    ?assertEqual({error, unsupported_format}, ircd_voice:detect_opus(<<"ID3", 3, 0, 0>>)).

valid_id_test() ->
    GoodOgg = <<"0123456789abcdef0123456789abcdef.ogg">>,
    GoodWebm = <<"abcdef0123456789abcdef0123456789.webm">>,
    ?assert(ircd_voice:valid_id(GoodOgg)),
    ?assert(ircd_voice:valid_id(GoodWebm)),
    ?assertEqual({ok, <<"audio/ogg">>}, ircd_voice:mime_for_id(GoodOgg)),
    ?assertEqual({ok, <<"audio/webm">>}, ircd_voice:mime_for_id(GoodWebm)),
    %% Reject uppercase, short hex, traversal, non-opus extensions.
    ?assertNot(ircd_voice:valid_id(<<"0123456789ABCDEF0123456789abcdef.ogg">>)),
    ?assertNot(ircd_voice:valid_id(<<"short.ogg">>)),
    ?assertNot(ircd_voice:valid_id(<<"../0123456789abcdef0123456789abcdef.ogg">>)),
    ?assertNot(ircd_voice:valid_id(<<"0123456789abcdef0123456789abcdef.html">>)),
    ?assertNot(ircd_voice:valid_id(<<"0123456789abcdef0123456789abcdef.mp3">>)),
    ?assertNot(ircd_voice:valid_id(not_a_binary)).

capability_and_config_test() ->
    Old = persistent_term:get({ircd_state, config}, undefined),
    try
        persistent_term:put({ircd_state, config}, #{voice => null}),
        ?assertNot(ircd_voice:enabled()),
        ?assertEqual({error, disabled}, ircd_voice:store(<<"OggS1234">>, 5)),
        ?assertEqual(
            {error, disabled},
            ircd_voice:fetch(<<"0123456789abcdef0123456789abcdef.ogg">>)
        ),

        persistent_term:put({ircd_state, config}, #{
            voice => #{
                endpoint => <<"http://rustfs:9000">>,
                region => <<"us-east-1">>,
                bucket => <<"ircd-voice">>,
                access_key_id => <<"key">>,
                secret_access_key => <<"secret">>,
                max_bytes => 524288,
                max_duration => 60
            }
        }),
        ?assert(ircd_voice:enabled()),
        ?assertEqual(<<"egorsmkv.github.io/voice">>, ircd_voice:cap()),
        ?assertEqual(
            <<"v=1,codec=opus,max-bytes=524288,max-duration=60">>,
            ircd_voice:cap_value()
        ),
        ?assertEqual(524288, ircd_voice:max_bytes()),
        ?assertEqual(60, ircd_voice:max_duration()),
        ?assertEqual({error, empty}, ircd_voice:store(<<>>, 0)),
        ?assertEqual({error, too_long}, ircd_voice:store(<<"OggS1234">>, 61)),
        ?assertEqual({error, unsupported_format}, ircd_voice:store(<<"not-opus">>, 5)),
        ?assertEqual({error, invalid_id}, ircd_voice:fetch(<<"../secret">>))
    after
        case Old of
            undefined -> persistent_term:erase({ircd_state, config});
            _ -> persistent_term:put({ircd_state, config}, Old)
        end
    end.

config_load_voice_test() ->
    TmpDir = filename:join([
        "/tmp",
        "ircd_voice_cfg_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    GoodPath = filename:join(TmpDir, "good.json"),
    BadPath = filename:join(TmpDir, "bad.json"),
    try
        GoodJson = #{
            <<"tcp_port">> => 6667,
            <<"voice">> => #{
                <<"endpoint">> => <<"http://rustfs:9000">>,
                <<"region">> => <<"us-east-1">>,
                <<"bucket">> => <<"ircd-voice">>,
                <<"access_key_id">> => <<"rustfsadmin">>,
                <<"secret_access_key">> => <<"rustfsadmin">>,
                <<"max_bytes">> => 1048576,
                <<"max_duration">> => 120
            }
        },
        ok = file:write_file(GoodPath, json:encode(GoodJson)),
        {ok, Cfg} = ircd_config:load(GoodPath),
        #{voice := VoiceCfg} = Cfg,
        ?assertEqual(<<"http://rustfs:9000">>, maps:get(endpoint, VoiceCfg)),
        ?assertEqual(<<"ircd-voice">>, maps:get(bucket, VoiceCfg)),
        ?assertEqual(1048576, maps:get(max_bytes, VoiceCfg)),
        ?assertEqual(120, maps:get(max_duration, VoiceCfg)),

        BadJson = #{
            <<"tcp_port">> => 6667,
            <<"voice">> => #{
                <<"endpoint">> => <<"ftp://invalid:9000">>,
                <<"access_key_id">> => <<"k">>,
                <<"secret_access_key">> => <<"s">>
            }
        },
        ok = file:write_file(BadPath, json:encode(BadJson)),
        ?assertMatch({error, {invalid_config, BadPath, _}}, ircd_config:load(BadPath))
    after
        _ = file:delete(GoodPath),
        _ = file:delete(BadPath),
        _ = file:del_dir(TmpDir)
    end.
