-module(ircd_webui_tests).
-include_lib("eunit/include/eunit.hrl").

config_validation_test() ->
    Load = fun(Extra) ->
        Path = filename:join(
            "/tmp",
            "ircd-webui-cfg-" ++ integer_to_list(erlang:system_time(nanosecond)) ++ ".json"
        ),
        ok = file:write_file(Path, [<<"{\"tcp_port\":6667">>, Extra, <<"}">>]),
        try
            ircd_config:load(Path)
        after
            file:delete(Path)
        end
    end,
    ?assertMatch({ok, #{webui := null}}, Load(<<>>)),
    ?assertMatch({ok, #{webui := null}}, Load(<<",\"webui\":false">>)),
    ?assertMatch(
        {ok, #{
            webui := #{
                ip := {127, 0, 0, 1},
                port := 8080,
                username := <<"admin">>,
                password := <<"s3cr3t">>
            }
        }},
        Load(<<",\"webui\":{\"port\":8080,\"password\":\"s3cr3t\"}">>)
    ),
    ?assertMatch({error, _}, Load(<<",\"webui\":{\"port\":8080}">>)),
    ?assertMatch({error, _}, Load(<<",\"webui\":{\"password\":\"s3cr3t\"}">>)),
    ?assertMatch(
        {error, _},
        Load(<<",\"webui\":{\"port\":8080,\"username\":\"a:b\",\"password\":\"s3cr3t\"}">>)
    ),
    ?assertMatch(
        {error, _},
        Load(<<",\"webui\":{\"bind\":\"not-an-ip\",\"port\":8080,\"password\":\"s3cr3t\"}">>)
    ).

live_webui_test_() ->
    {timeout, 60, fun live_webui/0}.

live_webui() ->
    Dir = filename:join(
        "/tmp",
        "ircd-webui-live-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config_json(Db)),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    try
        {ok, Port} = ircd_webui:port(),
        GoodAuth = basic_auth(<<"admin">>, <<"topsecret">>),
        BadAuth = basic_auth(<<"admin">>, <<"wrong">>),

        %% Unauthenticated and wrong credentials are rejected.
        {401, Headers401, _} = http_req(Port, <<"GET">>, <<"/">>, [], <<>>),
        ?assert(maps:is_key(<<"www-authenticate">>, Headers401)),
        {401, _, _} = http_req(
            Port, <<"GET">>, <<"/api/overview">>, [{<<"Authorization">>, BadAuth}], <<>>
        ),

        %% Authenticated GET / serves the HTML dashboard with security headers.
        {200, HtmlHeaders, HtmlBody} = http_req(
            Port, <<"GET">>, <<"/">>, [{<<"Authorization">>, GoodAuth}], <<>>
        ),
        ?assertEqual(<<"DENY">>, maps:get(<<"x-frame-options">>, HtmlHeaders)),
        ?assertEqual(<<"nosniff">>, maps:get(<<"x-content-type-options">>, HtmlHeaders)),
        ?assert(binary:match(HtmlBody, <<"<title>ircd admin</title>">>) =/= nomatch),

        %% Authenticated GET /api/overview returns server stats and tables.
        {200, _, OverviewBody} = http_req(
            Port, <<"GET">>, <<"/api/overview">>, [{<<"Authorization">>, GoodAuth}], <<>>
        ),
        Overview = json:decode(OverviewBody),
        ?assertMatch(
            #{
                <<"status">> := #{<<"name">> := <<"irc.test">>, <<"status">> := <<"running">>},
                <<"clients">> := #{<<"clients">> := []},
                <<"channels">> := #{<<"channels">> := []},
                <<"links">> := #{<<"connected">> := []},
                <<"accounts">> := #{<<"accounts">> := []},
                <<"dronebl">> := #{<<"stats">> := #{<<"enabled">> := false}, <<"bans">> := []}
            },
            Overview
        ),

        %% POST /api/action without CSRF header is rejected (403).
        {403, _, _} = http_req(
            Port,
            <<"POST">>,
            <<"/api/action">>,
            [{<<"Authorization">>, GoodAuth}, {<<"Content-Type">>, <<"application/json">>}],
            <<"{\"action\":\"rehash\",\"args\":[]}">>
        ),

        %% Unknown action is rejected (400).
        {400, _, BadActBody} = post_action(Port, GoodAuth, <<"eval">>, []),
        ?assertMatch(#{<<"error">> := <<"unsupported_action">>}, json:decode(BadActBody)),

        %% Valid actions: log-level, rehash, create-account, delete-account, dronebl-unban.
        {200, _, LvlBody} = post_action(Port, GoodAuth, <<"log-level">>, [<<"info">>]),
        ?assertMatch(
            #{<<"status">> := <<"updated">>, <<"log_level">> := <<"info">>}, json:decode(LvlBody)
        ),
        {200, _, _} = post_action(Port, GoodAuth, <<"log-level">>, [<<"warning">>]),

        {200, _, RehashBody} = post_action(Port, GoodAuth, <<"rehash">>, []),
        ?assertMatch(#{<<"status">> := <<"rehashed">>}, json:decode(RehashBody)),

        {200, _, CreateBody} = post_action(
            Port, GoodAuth, <<"create-account">>, [<<"webops">>, <<"strongpass123">>]
        ),
        ?assertMatch(
            #{<<"status">> := <<"created">>, <<"account">> := <<"webops">>}, json:decode(CreateBody)
        ),
        {200, _, DelBody} = post_action(Port, GoodAuth, <<"delete-account">>, [<<"webops">>]),
        ?assertMatch(
            #{<<"status">> := <<"deleted">>, <<"account">> := <<"webops">>}, json:decode(DelBody)
        ),

        ok = ircd_dronebl:ban(<<"198.51.100.9">>, 3, <<"IRC Drone">>),
        {200, _, UnbanBody} = post_action(Port, GoodAuth, <<"dronebl-unban">>, [<<"198.51.100.9">>]),
        ?assertMatch(#{<<"status">> := <<"unbanned">>}, json:decode(UnbanBody)),
        ?assertEqual([], ircd_dronebl:list_bans()),

        %% 404 for unknown path.
        {404, _, _} = http_req(
            Port, <<"GET">>, <<"/nope">>, [{<<"Authorization">>, GoodAuth}], <<>>
        )
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

post_action(Port, Auth, Action, Args) ->
    Body = iolist_to_binary(json:encode(#{action => Action, args => Args})),
    http_req(
        Port,
        <<"POST">>,
        <<"/api/action">>,
        [
            {<<"Authorization">>, Auth},
            {<<"Content-Type">>, <<"application/json">>},
            {<<"X-Requested-With">>, <<"ircd-webui">>}
        ],
        Body
    ).

basic_auth(User, Pass) ->
    <<"Basic ", (base64:encode(<<User/binary, ":", Pass/binary>>))/binary>>.

http_req(Port, Method, Path, Headers, Body) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    try
        Extra = [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Headers],
        LenHdr =
            case byte_size(Body) of
                0 -> [];
                N -> [<<"Content-Length: ">>, integer_to_binary(N), <<"\r\n">>]
            end,
        Req = [
            Method,
            <<" ">>,
            Path,
            <<" HTTP/1.1\r\nHost: 127.0.0.1\r\n">>,
            Extra,
            LenHdr,
            <<"\r\n">>,
            Body
        ],
        ok = gen_tcp:send(Sock, Req),
        Raw = read_all(Sock, <<>>),
        parse_response(Raw)
    after
        gen_tcp:close(Sock)
    end.

read_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Chunk} -> read_all(Sock, <<Acc/binary, Chunk/binary>>);
        {error, closed} -> Acc
    end.

parse_response(Raw) ->
    [Head, Body] = binary:split(Raw, <<"\r\n\r\n">>),
    [StatusLine | HdrLines] = binary:split(Head, <<"\r\n">>, [global]),
    [<<"HTTP/1.1">>, CodeBin | _] = binary:split(StatusLine, <<" ">>, [global]),
    Headers = lists:foldl(
        fun(Line, Acc) ->
            case binary:split(Line, <<":">>) of
                [K, V] -> Acc#{string:lowercase(string:trim(K)) => string:trim(V)};
                _ -> Acc
            end
        end,
        #{},
        HdrLines
    ),
    {binary_to_integer(CodeBin), Headers, Body}.

config_json(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",\"shutdown_grace\":2,">>,
        <<"\"webui\":{\"bind\":\"127.0.0.1\",\"port\":0,\"username\":\"admin\",\"password\":\"topsecret\"},">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).
