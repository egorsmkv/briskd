-module(ircd_files_tests).
-include_lib("eunit/include/eunit.hrl").

valid_id_and_mime_test() ->
    Png = <<"0123456789abcdef0123456789abcdef.png">>,
    Pdf = <<"0123456789abcdef0123456789abcdef.pdf">>,
    Bin = <<"abcdef0123456789abcdef0123456789.bin">>,
    ?assert(ircd_files:valid_id(Png)),
    ?assert(ircd_files:valid_id(Pdf)),
    ?assert(ircd_files:valid_id(Bin)),
    ?assertEqual({ok, <<"image/png">>}, ircd_files:mime_for_id(Png)),
    ?assertEqual({ok, <<"application/pdf">>}, ircd_files:mime_for_id(Pdf)),
    ?assertEqual({ok, <<"application/octet-stream">>}, ircd_files:mime_for_id(Bin)),
    ?assert(ircd_files:is_inline_preview(Png)),
    ?assertNot(ircd_files:is_inline_preview(Pdf)),
    ?assertNot(ircd_files:is_inline_preview(Bin)),
    %% Reject active web types, uppercase, path traversal
    ?assertNot(ircd_files:valid_id(<<"0123456789abcdef0123456789abcdef.html">>)),
    ?assertNot(ircd_files:valid_id(<<"0123456789abcdef0123456789abcdef.svg">>)),
    ?assertNot(ircd_files:valid_id(<<"0123456789abcdef0123456789abcdef.js">>)),
    ?assertNot(ircd_files:valid_id(<<"../0123456789abcdef0123456789abcdef.png">>)),
    ?assertNot(ircd_files:valid_id(<<"0123456789ABCDEF0123456789abcdef.png">>)).

sanitize_filename_test() ->
    ?assertEqual(<<"report.pdf">>, ircd_files:sanitize_filename(<<"/etc/passwd/report.pdf">>)),
    ?assertEqual(<<"photo.png">>, ircd_files:sanitize_filename(<<"C:\\Users\\a\\photo.png">>)),
    ?assertEqual(<<"ab.txt">>, ircd_files:sanitize_filename(<<"a\"b\r\n.txt">>)),
    ?assertEqual(<<"file.bin">>, ircd_files:sanitize_filename(<<"   ">>)),
    ?assertEqual(<<"file.bin">>, ircd_files:sanitize_filename(undefined)).

capability_and_limits_test() ->
    Old = persistent_term:get({ircd_state, config}, undefined),
    try
        persistent_term:put({ircd_state, config}, #{files => null}),
        ?assertNot(ircd_files:enabled()),
        ?assertEqual({error, disabled}, ircd_files:store(<<"hello">>, <<"a.txt">>)),
        ?assertEqual(
            {error, disabled},
            ircd_files:fetch(<<"0123456789abcdef0123456789abcdef.txt">>)
        ),

        persistent_term:put({ircd_state, config}, #{
            files => #{
                endpoint => <<"http://rustfs:9000">>,
                region => <<"us-east-1">>,
                bucket => <<"ircd-files">>,
                access_key_id => <<"key">>,
                secret_access_key => <<"secret">>,
                max_bytes => 2048
            }
        }),
        ?assert(ircd_files:enabled()),
        ?assertEqual(<<"egorsmkv.github.io/files">>, ircd_files:cap()),
        ?assertEqual(<<"v=1,max-bytes=2048">>, ircd_files:cap_value()),
        ?assertEqual(2048, ircd_files:max_bytes()),
        ?assertEqual({error, empty}, ircd_files:store(<<>>, <<"a.txt">>)),
        ?assertEqual({error, too_large}, ircd_files:store(binary:copy(<<0>>, 2049), <<"big.bin">>)),
        ?assertEqual({error, invalid_id}, ircd_files:fetch(<<"../secret.txt">>))
    after
        case Old of
            undefined -> persistent_term:erase({ircd_state, config});
            _ -> persistent_term:put({ircd_state, config}, Old)
        end
    end.

config_load_files_test() ->
    TmpDir = filename:join([
        "/tmp",
        "ircd_files_cfg_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    GoodPath = filename:join(TmpDir, "good.json"),
    BadPath = filename:join(TmpDir, "bad.json"),
    try
        GoodJson = #{
            <<"tcp_port">> => 6667,
            <<"files">> => #{
                <<"endpoint">> => <<"http://rustfs:9000">>,
                <<"region">> => <<"us-east-1">>,
                <<"bucket">> => <<"ircd-files">>,
                <<"access_key_id">> => <<"rustfsadmin">>,
                <<"secret_access_key">> => <<"rustfsadmin">>,
                <<"max_bytes">> => 5242880
            }
        },
        ok = file:write_file(GoodPath, json:encode(GoodJson)),
        {ok, Cfg} = ircd_config:load(GoodPath),
        #{files := FilesCfg} = Cfg,
        ?assertEqual(<<"http://rustfs:9000">>, maps:get(endpoint, FilesCfg)),
        ?assertEqual(<<"ircd-files">>, maps:get(bucket, FilesCfg)),
        ?assertEqual(5242880, maps:get(max_bytes, FilesCfg)),

        BadJson = #{
            <<"tcp_port">> => 6667,
            <<"files">> => #{
                <<"endpoint">> => <<"http://rustfs:9000">>,
                <<"access_key_id">> => <<"k">>,
                <<"secret_access_key">> => <<"s">>,
                <<"max_bytes">> => 10
            }
        },
        ok = file:write_file(BadPath, json:encode(BadJson)),
        ?assertMatch({error, {invalid_config, BadPath, _}}, ircd_config:load(BadPath))
    after
        _ = file:delete(GoodPath),
        _ = file:delete(BadPath),
        _ = file:del_dir(TmpDir)
    end.
