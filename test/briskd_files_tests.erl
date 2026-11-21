-module(briskd_files_tests).
-include_lib("eunit/include/eunit.hrl").

valid_id_and_mime_test() ->
    Png = <<"0123456789abcdef0123456789abcdef.png">>,
    Pdf = <<"0123456789abcdef0123456789abcdef.pdf">>,
    Bin = <<"abcdef0123456789abcdef0123456789.bin">>,
    ?assert(briskd_files:valid_id(Png)),
    ?assert(briskd_files:valid_id(Pdf)),
    ?assert(briskd_files:valid_id(Bin)),
    ?assertEqual({ok, <<"image/png">>}, briskd_files:mime_for_id(Png)),
    ?assertEqual({ok, <<"application/pdf">>}, briskd_files:mime_for_id(Pdf)),
    ?assertEqual({ok, <<"application/octet-stream">>}, briskd_files:mime_for_id(Bin)),
    ?assert(briskd_files:is_inline_preview(Png)),
    ?assertNot(briskd_files:is_inline_preview(Pdf)),
    ?assertNot(briskd_files:is_inline_preview(Bin)),
    %% Reject active web types, uppercase, path traversal
    ?assertNot(briskd_files:valid_id(<<"0123456789abcdef0123456789abcdef.html">>)),
    ?assertNot(briskd_files:valid_id(<<"0123456789abcdef0123456789abcdef.svg">>)),
    ?assertNot(briskd_files:valid_id(<<"0123456789abcdef0123456789abcdef.js">>)),
    ?assertNot(briskd_files:valid_id(<<"../0123456789abcdef0123456789abcdef.png">>)),
    ?assertNot(briskd_files:valid_id(<<"0123456789ABCDEF0123456789abcdef.png">>)).

sanitize_filename_test() ->
    ?assertEqual(<<"report.pdf">>, briskd_files:sanitize_filename(<<"/etc/passwd/report.pdf">>)),
    ?assertEqual(<<"photo.png">>, briskd_files:sanitize_filename(<<"C:\\Users\\a\\photo.png">>)),
    ?assertEqual(<<"ab.txt">>, briskd_files:sanitize_filename(<<"a\"b\r\n.txt">>)),
    ?assertEqual(<<"file.bin">>, briskd_files:sanitize_filename(<<"   ">>)),
    ?assertEqual(<<"file.bin">>, briskd_files:sanitize_filename(undefined)).

capability_and_limits_test() ->
    Old = persistent_term:get({briskd_state, config}, undefined),
    try
        persistent_term:put({briskd_state, config}, #{files => null}),
        ?assertNot(briskd_files:enabled()),
        ?assertEqual({error, disabled}, briskd_files:store(<<"hello">>, <<"a.txt">>)),
        ?assertEqual(
            {error, disabled},
            briskd_files:fetch(<<"0123456789abcdef0123456789abcdef.txt">>)
        ),

        persistent_term:put({briskd_state, config}, #{
            files => #{
                endpoint => <<"http://rustfs:9000">>,
                region => <<"us-east-1">>,
                bucket => <<"briskd-files">>,
                access_key_id => <<"key">>,
                secret_access_key => <<"secret">>,
                max_bytes => 2048
            }
        }),
        ?assert(briskd_files:enabled()),
        ?assertEqual(<<"egorsmkv.github.io/files">>, briskd_files:cap()),
        ?assertEqual(<<"v=1,max-bytes=2048">>, briskd_files:cap_value()),
        ?assertEqual(2048, briskd_files:max_bytes()),
        ?assertEqual({error, empty}, briskd_files:store(<<>>, <<"a.txt">>)),
        ?assertEqual(
            {error, too_large}, briskd_files:store(binary:copy(<<0>>, 2049), <<"big.bin">>)
        ),
        ?assertEqual({error, invalid_id}, briskd_files:fetch(<<"../secret.txt">>))
    after
        case Old of
            undefined -> persistent_term:erase({briskd_state, config});
            _ -> persistent_term:put({briskd_state, config}, Old)
        end
    end.

config_load_files_test() ->
    TmpDir = filename:join([
        "/tmp",
        "briskd_files_cfg_" ++ integer_to_list(erlang:unique_integer([positive]))
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
                <<"bucket">> => <<"briskd-files">>,
                <<"access_key_id">> => <<"rustfsadmin">>,
                <<"secret_access_key">> => <<"rustfsadmin">>,
                <<"max_bytes">> => 5242880
            }
        },
        ok = file:write_file(GoodPath, json:encode(GoodJson)),
        {ok, Cfg} = briskd_config:load(GoodPath),
        #{files := #{} = FilesCfg} = Cfg,
        ?assertEqual(<<"http://rustfs:9000">>, maps:get(endpoint, FilesCfg)),
        ?assertEqual(<<"briskd-files">>, maps:get(bucket, FilesCfg)),
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
        ?assertMatch({error, {invalid_config, BadPath, _}}, briskd_config:load(BadPath))
    after
        _ = file:delete(GoodPath),
        _ = file:delete(BadPath),
        _ = file:del_dir(TmpDir)
    end.
