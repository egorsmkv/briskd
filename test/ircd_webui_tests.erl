-module(ircd_webui_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ircd/include/ircd_state.hrl").
-include_lib("ircd/include/ircd_account.hrl").

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
                password := <<"s3cr3t">>,
                terms_url := <<"https://example.com/terms">>,
                privacy_url := <<"https://example.com/privacy">>
            }
        }},
        Load(<<",\"webui\":{\"port\":8080,\"password\":\"s3cr3t\"}">>)
    ),
    ?assertMatch(
        {error, _},
        Load(
            <<",\"webui\":{\"port\":8080,\"password\":\"s3cr3t\",\"terms_url\":\"javascript:alert(1)\"}">>
        )
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

        %% Signed out, an admin page goes to the sign-in page (and back to
        %% the tab afterwards); the API answers 401. Neither sends a Basic
        %% challenge, so a browser never shows its own password dialog.
        {302, Headers302, _} = http_req(Port, <<"GET">>, <<"/admin/channels">>, [], <<>>),
        ?assertEqual(
            <<"/admin/login?next=/admin/channels">>, maps:get(<<"location">>, Headers302)
        ),
        ?assertNot(maps:is_key(<<"www-authenticate">>, Headers302)),
        {302, OddHeaders, _} = http_req(Port, <<"GET">>, <<"/admin/x%2F%2Fevil">>, [], <<>>),
        ?assertEqual(<<"/admin/login">>, maps:get(<<"location">>, OddHeaders)),
        {401, Headers401, _} = http_req(
            Port, <<"GET">>, <<"/api/overview">>, [{<<"Authorization">>, BadAuth}], <<>>
        ),
        ?assertNot(maps:is_key(<<"www-authenticate">>, Headers401)),
        {200, LoginPageHeaders, LoginPage} = http_req(
            Port, <<"GET">>, <<"/admin/login">>, [], <<>>
        ),
        ?assert(binary:match(LoginPage, <<"login.css">>) =/= nomatch),
        ?assert(binary:match(LoginPage, <<"noindex">>) =/= nomatch),
        ?assertEqual(<<"DENY">>, maps:get(<<"x-frame-options">>, LoginPageHeaders)),

        %% Sign in: wrong password 401, no CSRF header 403, right one sets
        %% an HttpOnly SameSite=Strict cookie that opens the panel and API.
        Login = fun(User, Pass, Extra) ->
            http_req(
                Port,
                <<"POST">>,
                <<"/api/admin/login">>,
                [{<<"Content-Type">>, <<"application/json">>} | Extra],
                iolist_to_binary(json:encode(#{username => User, password => Pass}))
            )
        end,
        Csrf = [{<<"X-Requested-With">>, <<"ircd-webui">>}],
        {401, _, WrongBody} = Login(<<"admin">>, <<"wrong">>, Csrf),
        ?assertMatch(#{<<"error">> := <<"invalid_credentials">>}, json:decode(WrongBody)),
        {403, _, _} = Login(<<"admin">>, <<"topsecret">>, []),
        {400, _, _} = http_req(
            Port, <<"POST">>, <<"/api/admin/login">>, Csrf, <<"{\"username\":1}">>
        ),
        {200, OkHeaders, _} = Login(<<"admin">>, <<"topsecret">>, Csrf),
        SetCookie = maps:get(<<"set-cookie">>, OkHeaders),
        ?assert(binary:match(SetCookie, <<"HttpOnly">>) =/= nomatch),
        ?assert(binary:match(SetCookie, <<"SameSite=Strict">>) =/= nomatch),
        ?assertEqual(nomatch, binary:match(SetCookie, <<"Secure">>)),
        [CookiePair | _] = binary:split(SetCookie, <<";">>),
        Cookie = [{<<"Cookie">>, <<"theme=dark; ", CookiePair/binary>>}],
        {200, _, _} = http_req(Port, <<"GET">>, <<"/admin/channels">>, Cookie, <<>>),
        {200, _, _} = http_req(Port, <<"GET">>, <<"/api/overview">>, Cookie, <<>>),
        {302, SignedInHeaders, _} = http_req(Port, <<"GET">>, <<"/admin/login">>, Cookie, <<>>),
        ?assertEqual(<<"/admin">>, maps:get(<<"location">>, SignedInHeaders)),
        %% Behind an HTTPS proxy the cookie is Secure.
        {200, TlsHeaders, _} = Login(
            <<"admin">>, <<"topsecret">>, [{<<"X-Forwarded-Proto">>, <<"https">>} | Csrf]
        ),
        ?assert(binary:match(maps:get(<<"set-cookie">>, TlsHeaders), <<"; Secure">>) =/= nomatch),
        %% A forged token is refused; signing out ends the session.
        {401, _, _} = http_req(
            Port,
            <<"GET">>,
            <<"/api/overview">>,
            [{<<"Cookie">>, <<"ircd_admin=forged">>}],
            <<>>
        ),
        {200, OutHeaders, _} = http_req(
            Port, <<"POST">>, <<"/api/admin/logout">>, Cookie ++ Csrf, <<>>
        ),
        ?assert(binary:match(maps:get(<<"set-cookie">>, OutHeaders), <<"Max-Age=0">>) =/= nomatch),
        {401, _, _} = http_req(Port, <<"GET">>, <<"/api/overview">>, Cookie, <<>>),

        %% A connection that sends nothing (a browser's idle preconnect) is
        %% closed without a reply: a 400 written to it would be read as the
        %% answer to the page request the browser sends on it later.
        {ok, Idle} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
        ?assertEqual({error, closed}, gen_tcp:recv(Idle, 0, 10000)),
        ok = gen_tcp:close(Idle),
        %% A partial request that stalls still gets 400.
        {ok, Partial} = gen_tcp:connect("127.0.0.1", Port, [
            binary, {active, false}, {packet, raw}
        ]),
        ok = gen_tcp:send(Partial, <<"GET / HTTP/1.1\r\nHost: x\r\n">>),
        {ok, <<"HTTP/1.1 400", _/binary>>} = gen_tcp:recv(Partial, 0, 10000),
        ok = gen_tcp:close(Partial),

        %% Paths that are not the admin panel get a plain 404 with no Basic
        %% challenge, so a browser on the chat page never shows the admin
        %% password dialog for its own probes.
        lists:foreach(
            fun({Method, Path}) ->
                {404, NotFoundHeaders, _} = http_req(Port, Method, Path, [], <<>>),
                ?assertNot(maps:is_key(<<"www-authenticate">>, NotFoundHeaders))
            end,
            [
                {<<"GET">>, <<"/.well-known/appspecific/com.chrome.devtools.json">>},
                {<<"GET">>, <<"/apple-touch-icon.png">>},
                {<<"GET">>, <<"/manifest.json">>},
                {<<"GET">>, <<"/channel">>},
                {<<"POST">>, <<"/">>},
                {<<"GET">>, <<"/administrator">>}
            ]
        ),
        %% A link with no preview (here a host that does not resolve) is
        %% 204 No Content, without body headers, not an error status.
        {204, NoPreviewHeaders, <<>>} = http_req(
            Port,
            <<"GET">>,
            <<"/api/link-preview?url=https%3A%2F%2Fno-preview.invalid%2F">>,
            [{<<"X-Requested-With">>, <<"ircd-webui">>}],
            <<>>
        ),
        ?assertNot(maps:is_key(<<"content-length">>, NoPreviewHeaders)),
        %% Every admin path still needs a session: pages redirect, the API
        %% is 401.
        lists:foreach(
            fun({Method, Path, Code}) ->
                {Code, AdminHeaders, _} = http_req(Port, Method, Path, [], <<>>),
                ?assertNot(maps:is_key(<<"www-authenticate">>, AdminHeaders))
            end,
            [
                {<<"GET">>, <<"/admin/">>, 302},
                {<<"GET">>, <<"/admin/unknown">>, 302},
                {<<"GET">>, <<"/api/media">>, 401},
                {<<"POST">>, <<"/api/action">>, 401}
            ]
        ),

        %% Authenticated GET /admin serves the HTML dashboard with strict CSP.
        {200, HtmlHeaders, HtmlBody} = http_req(
            Port, <<"GET">>, <<"/admin">>, [{<<"Authorization">>, GoodAuth}], <<>>
        ),
        ?assertEqual(<<"DENY">>, maps:get(<<"x-frame-options">>, HtmlHeaders)),
        ?assertEqual(<<"nosniff">>, maps:get(<<"x-content-type-options">>, HtmlHeaders)),
        Csp = maps:get(<<"content-security-policy">>, HtmlHeaders),
        ?assert(binary:match(Csp, <<"script-src 'self' 'nonce-">>) =/= nomatch),
        ?assert(binary:match(Csp, <<"style-src 'self'">>) =/= nomatch),
        ?assertEqual(nomatch, binary:match(Csp, <<"'unsafe-inline'">>)),
        ?assert(binary:match(Csp, <<"frame-ancestors 'none'">>) =/= nomatch),
        ?assertEqual(nomatch, binary:match(HtmlBody, <<"__CSP_NONCE__">>)),
        %% The single-page app shell, with escaped page meta and config.
        ?assert(
            binary:match(HtmlBody, <<"<title>Admin - Net&lt;/script&gt;&lt;b&gt;&amp;</title>">>) =/=
                nomatch
        ),
        ?assert(binary:match(HtmlBody, <<"noindex, nofollow">>) =/= nomatch),
        ?assert(binary:match(HtmlBody, <<"<div id=\"app\"></div>">>) =/= nomatch),
        ?assert(binary:match(HtmlBody, <<"/assets/admin.css">>) =/= nomatch),
        %% The config block cannot be closed or broken by a value.
        ?assert(
            binary:match(
                HtmlBody, <<"\"network\":\"Net\\u003c/script\\u003e\\u003cb\\u003e\\u0026\"">>
            ) =/=
                nomatch
        ),
        ?assertEqual(nomatch, binary:match(HtmlBody, <<"</script><b>">>)),
        ?assertEqual(nomatch, binary:match(HtmlBody, <<"__APP_CONFIG__">>)),
        {200, _, SubAdminBody} = http_req(
            Port, <<"GET">>, <<"/admin/accounts">>, [{<<"Authorization">>, GoodAuth}], <<>>
        ),
        ?assert(binary:match(SubAdminBody, <<"<title>Admin - ">>) =/= nomatch),
        {302, _, _} = http_req(Port, <<"GET">>, <<"/admin/accounts">>, [], <<>>),

        %% Public favicon.ico, favicon.svg, and robots.txt are served without auth.
        {200, IcoHeaders, IcoBody} = http_req(Port, <<"GET">>, <<"/favicon.ico">>, [], <<>>),
        ?assertEqual(<<"image/x-icon">>, maps:get(<<"content-type">>, IcoHeaders)),
        ?assert(byte_size(IcoBody) > 100),
        {200, SvgHeaders, SvgBody} = http_req(Port, <<"GET">>, <<"/favicon.svg">>, [], <<>>),
        ?assertEqual(<<"image/svg+xml">>, maps:get(<<"content-type">>, SvgHeaders)),
        ?assert(binary:match(SvgBody, <<"<svg">>) =/= nomatch),
        {200, OgHeaders, OgBody} = http_req(Port, <<"GET">>, <<"/og-image.png">>, [], <<>>),
        ?assertEqual(<<"image/png">>, maps:get(<<"content-type">>, OgHeaders)),
        ?assertMatch(<<137, "PNG", _/binary>>, OgBody),
        {200, RobotsHeaders, RobotsBody} = http_req(Port, <<"GET">>, <<"/robots.txt">>, [], <<>>),
        ?assertEqual(<<"text/plain; charset=utf-8">>, maps:get(<<"content-type">>, RobotsHeaders)),
        ?assert(binary:match(RobotsBody, <<"Disallow: /admin">>) =/= nomatch),

        %% Second GET /admin issues a fresh per-request CSP nonce.
        {200, HtmlHeaders2, _} = http_req(
            Port, <<"GET">>, <<"/admin">>, [{<<"Authorization">>, GoodAuth}], <<>>
        ),
        ?assertNotEqual(Csp, maps:get(<<"content-security-policy">>, HtmlHeaders2)),

        %% JSON API sets default-src 'none' CSP to block script execution even if opened directly.
        {200, OverviewHeaders, OverviewBody} = http_req(
            Port, <<"GET">>, <<"/api/overview">>, [{<<"Authorization">>, GoodAuth}], <<>>
        ),
        ?assertEqual(
            <<"default-src 'none'; frame-ancestors 'none'">>,
            maps:get(<<"content-security-policy">>, OverviewHeaders)
        ),
        Overview = json:decode(OverviewBody),
        ?assertMatch(
            #{
                <<"status">> := #{
                    <<"name">> := <<"irc.test">>,
                    <<"status">> := <<"running">>,
                    <<"db_disk_bytes">> := _,
                    <<"db_memory_bytes">> := _
                },
                <<"clients">> := #{<<"clients">> := []},
                <<"channels">> := #{<<"channels">> := []},
                <<"links">> := #{<<"connected">> := []},
                <<"accounts">> := #{<<"accounts">> := []},
                <<"dronebl">> := #{<<"stats">> := #{<<"enabled">> := false}, <<"bans">> := []}
            },
            Overview
        ),
        #{<<"status">> := #{<<"db_disk_bytes">> := DbDisk, <<"db_memory_bytes">> := DbMem}} =
            Overview,
        ?assert(is_integer(DbDisk) andalso DbDisk >= 0),
        ?assert(is_integer(DbMem) andalso DbMem > 0),

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

        %% A body that arrives slowly (as an upload from a phone does) is read
        %% to the end: each chunk comes within the per-read timeout, though
        %% the whole takes longer than one.
        SlowBody = iolist_to_binary(
            json:encode(#{action => <<"log-level">>, args => [<<"info">>]})
        ),
        {ok, Slow} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
        ok = gen_tcp:send(Slow, [
            <<"POST /api/action HTTP/1.1\r\nHost: x\r\nAuthorization: ">>,
            GoodAuth,
            <<"\r\nX-Requested-With: ircd-webui\r\nContent-Type: application/json\r\n">>,
            <<"Content-Length: ">>,
            integer_to_binary(byte_size(SlowBody)),
            <<"\r\n\r\n">>
        ]),
        Half = byte_size(SlowBody) div 2,
        timer:sleep(3500),
        ok = gen_tcp:send(Slow, binary:part(SlowBody, 0, Half)),
        timer:sleep(3500),
        ok = gen_tcp:send(Slow, binary:part(SlowBody, Half, byte_size(SlowBody) - Half)),
        {200, _, SlowReply} = parse_response(read_all(Slow, <<>>)),
        ?assertMatch(#{<<"status">> := <<"updated">>}, json:decode(SlowReply)),
        ok = gen_tcp:close(Slow),

        {200, _, RehashBody} = post_action(Port, GoodAuth, <<"rehash">>, []),
        ?assertMatch(#{<<"status">> := <<"rehashed">>}, json:decode(RehashBody)),

        %% Feature controls (ircd_overrides): switching chat history off
        %% withdraws the capability from CAP LS, survives REHASH, and a reset
        %% brings back the file's value.
        Control = fun(Key) ->
            {200, _, Ov} = http_req(
                Port, <<"GET">>, <<"/api/overview">>, [{<<"Authorization">>, GoodAuth}], <<>>
            ),
            #{<<"controls">> := Controls} = json:decode(Ov),
            hd([C || #{<<"key">> := K} = C <- Controls, K =:= Key])
        end,
        ?assertMatch(
            #{<<"value">> := true, <<"overridden">> := false}, Control(<<"chathistory">>)
        ),
        ?assert(has_cap(<<"draft/chathistory">>)),
        {200, _, SetBody} = post_action(
            Port, GoodAuth, <<"set-control">>, [<<"chathistory">>, <<"false">>]
        ),
        ?assertMatch(#{<<"status">> := <<"updated">>}, json:decode(SetBody)),
        ?assertNot(has_cap(<<"draft/chathistory">>)),
        {200, _, _} = post_action(Port, GoodAuth, <<"rehash">>, []),
        ?assertMatch(
            #{<<"value">> := false, <<"default">> := true, <<"overridden">> := true},
            Control(<<"chathistory">>)
        ),
        ?assertNot(has_cap(<<"draft/chathistory">>)),
        {200, _, _} = post_action(Port, GoodAuth, <<"reset-control">>, [<<"chathistory">>]),
        ?assertMatch(
            #{<<"value">> := true, <<"overridden">> := false}, Control(<<"chathistory">>)
        ),
        ?assert(has_cap(<<"draft/chathistory">>)),
        %% Limits are bounded; a subsystem the file does not configure, or an
        %% unknown control, is refused.
        {200, _, _} = post_action(Port, GoodAuth, <<"set-control">>, [<<"history_limit">>, <<"42">>]),
        ?assertMatch(#{<<"value">> := 42}, Control(<<"history_limit">>)),
        {400, _, Range} = post_action(
            Port, GoodAuth, <<"set-control">>, [<<"history_limit">>, <<"0">>]
        ),
        ?assertMatch(#{<<"error">> := <<"invalid_value">>}, json:decode(Range)),
        {400, _, NotCfg} = post_action(Port, GoodAuth, <<"set-control">>, [<<"calls">>, <<"true">>]),
        ?assertMatch(#{<<"error">> := <<"not_configured">>}, json:decode(NotCfg)),
        {400, _, Unknown} = post_action(Port, GoodAuth, <<"set-control">>, [<<"name">>, <<"x">>]),
        ?assertMatch(#{<<"error">> := <<"unknown_control">>}, json:decode(Unknown)),
        {200, _, _} = post_action(Port, GoodAuth, <<"reset-control">>, [<<"history_limit">>]),
        %% The older chat feature switch goes through the same controls.
        {200, _, _} = post_action(Port, GoodAuth, <<"toggle-feature">>, [<<"typing">>, <<"false">>]),
        ?assertMatch(
            #{<<"value">> := false, <<"overridden">> := true}, Control(<<"features.typing">>)
        ),
        {200, _, _} = post_action(Port, GoodAuth, <<"reset-control">>, [<<"features.typing">>]),

        {200, _, CheckCfgBody} = post_action(Port, GoodAuth, <<"check-config">>, []),
        ?assertMatch(#{<<"status">> := <<"valid">>}, json:decode(CheckCfgBody)),

        {200, _, NoticeBody} = post_action(Port, GoodAuth, <<"notice-all">>, [
            <<"Maintenance soon">>
        ]),
        ?assertMatch(#{<<"status">> := <<"sent">>}, json:decode(NoticeBody)),

        {200, _, BanBody} = post_action(Port, GoodAuth, <<"dronebl-ban">>, [
            <<"198.51.100.42">>, <<"Abuse">>
        ]),
        ?assertMatch(#{<<"status">> := <<"banned">>}, json:decode(BanBody)),
        {200, _, Unban42} = post_action(Port, GoodAuth, <<"dronebl-unban">>, [<<"198.51.100.42">>]),
        ?assertMatch(#{<<"status">> := <<"unbanned">>}, json:decode(Unban42)),

        %% Compiled static TypeScript/Sass assets are served with exact MIME types.
        {200, JsHdrs, JsBody} = http_req(Port, <<"GET">>, <<"/assets/app.js">>, [], <<>>),
        ?assertEqual(<<"text/javascript; charset=utf-8">>, maps:get(<<"content-type">>, JsHdrs)),
        ?assert(byte_size(JsBody) > 100),
        %% Lazily loaded page chunks (content-hashed names) are served too.
        {match, [Chunk | _]} = re:run(
            JsBody, <<"chunk-[A-Z0-9]+\\.js">>, [global, {capture, first, binary}]
        ),
        {200, _, ChunkBody} = http_req(
            Port, <<"GET">>, <<"/assets/", (hd(Chunk))/binary>>, [], <<>>
        ),
        ?assert(byte_size(ChunkBody) > 0),
        {200, CssHdrs, CssBody} = http_req(Port, <<"GET">>, <<"/assets/webirc.css">>, [], <<>>),
        ?assertEqual(<<"text/css; charset=utf-8">>, maps:get(<<"content-type">>, CssHdrs)),
        ?assert(byte_size(CssBody) > 100),
        {404, _, _} = http_req(Port, <<"GET">>, <<"/recover">>, [], <<>>),
        {404, _, _} = http_req(Port, <<"GET">>, <<"/assets/../../etc/passwd">>, [], <<>>),

        {200, _, CreateBody} = post_action(
            Port, GoodAuth, <<"create-account">>, [<<"webops">>, <<"strongpass123">>]
        ),
        ?assertMatch(
            #{<<"status">> := <<"created">>, <<"account">> := <<"webops">>}, json:decode(CreateBody)
        ),
        {200, _, ResetPassBody} = post_action(
            Port, GoodAuth, <<"reset-password">>, [<<"webops">>, <<"newstrongpass456">>]
        ),
        ?assertMatch(
            #{<<"status">> := <<"password_updated">>, <<"account">> := <<"webops">>},
            json:decode(ResetPassBody)
        ),
        {200, _, DelBody} = post_action(Port, GoodAuth, <<"delete-account">>, [<<"webops">>]),
        ?assertMatch(
            #{<<"status">> := <<"deleted">>, <<"account">> := <<"webops">>}, json:decode(DelBody)
        ),

        ok = ircd_dronebl:ban(<<"198.51.100.9">>, 3, <<"IRC Drone">>),
        {200, _, UnbanBody} = post_action(Port, GoodAuth, <<"dronebl-unban">>, [<<"198.51.100.9">>]),
        ?assertMatch(#{<<"status">> := <<"unbanned">>}, json:decode(UnbanBody)),
        ?assertEqual([], ircd_dronebl:list_bans()),

        %% Public GET /signup works without Basic Auth and uses a CSP nonce.
        %% Public GET /api/altcha returns a valid ALTCHA SHA-256 challenge.
        {200, _, AltchaChBody} = http_req(Port, <<"GET">>, <<"/api/altcha">>, [], <<>>),
        ?assertMatch(
            #{
                <<"algorithm">> := <<"SHA-256">>,
                <<"challenge">> := _,
                <<"maxnumber">> := _,
                <<"salt">> := _,
                <<"signature">> := _
            },
            json:decode(AltchaChBody)
        ),

        {200, SignupHdrs, SignupHtml} = http_req(Port, <<"GET">>, <<"/signup">>, [], <<>>),
        ?assert(
            binary:match(
                maps:get(<<"content-security-policy">>, SignupHdrs), <<"script-src 'self' 'nonce-">>
            ) =/=
                nomatch
        ),
        ?assert(binary:match(SignupHtml, <<"<title>Sign Up - Net">>) =/= nomatch),
        ?assert(binary:match(SignupHtml, <<"/assets/signup.css">>) =/= nomatch),
        %% The form is rendered by the app from the config block.
        [ConfigJson] = [
            J
         || [_, J] <- [
                binary:split(
                    hd(binary:split(SignupHtml, <<"</script>">>)),
                    <<"<script type=\"application/json\" id=\"app-config\">">>
                )
            ]
        ],
        ?assertMatch(
            #{
                <<"termsUrl">> := <<"https://example.com/terms">>,
                <<"privacyUrl">> := <<"https://example.com/privacy">>,
                <<"features">> := #{<<"registration">> := true, <<"webirc">> := true}
            },
            json:decode(ConfigJson)
        ),

        %% Public POST /api/signup enforces CSRF, terms acceptance, and required ALTCHA.
        {403, _, _} = http_req(
            Port,
            <<"POST">>,
            <<"/api/signup">>,
            [{<<"Content-Type">>, <<"application/json">>}],
            <<"{\"account\":\"newuser\",\"password\":\"strongpass123\",\"accept_terms\":true}">>
        ),
        {400, _, NoTermsBody} = http_req(
            Port,
            <<"POST">>,
            <<"/api/signup">>,
            [
                {<<"Content-Type">>, <<"application/json">>},
                {<<"X-Requested-With">>, <<"ircd-webui">>}
            ],
            <<"{\"account\":\"newuser\",\"password\":\"strongpass123\"}">>
        ),
        ?assertMatch(#{<<"error">> := <<"terms_not_accepted">>}, json:decode(NoTermsBody)),
        {400, _, NoAltchaBody} = http_req(
            Port,
            <<"POST">>,
            <<"/api/signup">>,
            [
                {<<"Content-Type">>, <<"application/json">>},
                {<<"X-Requested-With">>, <<"ircd-webui">>}
            ],
            <<"{\"account\":\"newuser\",\"password\":\"strongpass123\",\"accept_terms\":true}">>
        ),
        ?assertMatch(#{<<"error">> := <<"altcha_required">>}, json:decode(NoAltchaBody)),
        {400, _, BadAltchaBody} = http_req(
            Port,
            <<"POST">>,
            <<"/api/signup">>,
            [
                {<<"Content-Type">>, <<"application/json">>},
                {<<"X-Requested-With">>, <<"ircd-webui">>}
            ],
            <<"{\"account\":\"newuser\",\"password\":\"strongpass123\",\"accept_terms\":true,\"altcha\":\"bogus\"}">>
        ),
        ?assertMatch(#{<<"error">> := <<"altcha_invalid">>}, json:decode(BadAltchaBody)),
        WeakPayload = test_altcha_payload(42, 300),
        {400, _, WeakBody} = http_req(
            Port,
            <<"POST">>,
            <<"/api/signup">>,
            [
                {<<"Content-Type">>, <<"application/json">>},
                {<<"X-Requested-With">>, <<"ircd-webui">>}
            ],
            iolist_to_binary(
                json:encode(#{
                    account => <<"newuser">>,
                    password => <<"123">>,
                    accept_terms => true,
                    altcha => WeakPayload
                })
            )
        ),
        ?assertMatch(#{<<"error">> := <<"weak_password">>}, json:decode(WeakBody)),
        {400, _, ReplayBody} = http_req(
            Port,
            <<"POST">>,
            <<"/api/signup">>,
            [
                {<<"Content-Type">>, <<"application/json">>},
                {<<"X-Requested-With">>, <<"ircd-webui">>}
            ],
            iolist_to_binary(
                json:encode(#{
                    account => <<"newuser">>,
                    password => <<"strongpass123">>,
                    accept_terms => true,
                    altcha => WeakPayload
                })
            )
        ),
        ?assertMatch(#{<<"error">> := <<"altcha_replayed">>}, json:decode(ReplayBody)),
        {400, _, ExpBody} = http_req(
            Port,
            <<"POST">>,
            <<"/api/signup">>,
            [
                {<<"Content-Type">>, <<"application/json">>},
                {<<"X-Requested-With">>, <<"ircd-webui">>}
            ],
            iolist_to_binary(
                json:encode(#{
                    account => <<"newuser">>,
                    password => <<"strongpass123">>,
                    accept_terms => true,
                    altcha => test_altcha_payload(7, -10)
                })
            )
        ),
        ?assertMatch(#{<<"error">> := <<"altcha_expired">>}, json:decode(ExpBody)),
        {201, _, SignupOk} = http_req(
            Port,
            <<"POST">>,
            <<"/api/signup">>,
            [
                {<<"Content-Type">>, <<"application/json">>},
                {<<"X-Requested-With">>, <<"ircd-webui">>}
            ],
            iolist_to_binary(
                json:encode(#{
                    account => <<"newuser">>,
                    password => <<"strongpass123">>,
                    email => <<"u@example.com">>,
                    accept_terms => true,
                    altcha => test_altcha_payload(99, 300)
                })
            )
        ),
        ?assertMatch(
            #{<<"status">> := <<"created">>, <<"account">> := <<"newuser">>},
            json:decode(SignupOk)
        ),
        {400, _, DupBody} = http_req(
            Port,
            <<"POST">>,
            <<"/api/signup">>,
            [
                {<<"Content-Type">>, <<"application/json">>},
                {<<"X-Requested-With">>, <<"ircd-webui">>}
            ],
            iolist_to_binary(
                json:encode(#{
                    account => <<"newuser">>,
                    password => <<"strongpass123">>,
                    accept_terms => true,
                    altcha => test_altcha_payload(100, 300)
                })
            )
        ),
        ?assertMatch(#{<<"error">> := <<"account_exists">>}, json:decode(DupBody)),

        %% Admin WebUI lists pending accounts and can verify them with verify-account.
        {ok, _} = ircd_account:create(
            <<"penduser">>, <<"p@example.com">>, <<"strongpass123">>, [], {<<"CODE1234">>, 60000}
        ),
        {200, _, OvPend} = http_req(
            Port, <<"GET">>, <<"/api/overview">>, [{<<"Authorization">>, GoodAuth}], <<>>
        ),
        #{<<"accounts">> := #{<<"accounts">> := AcctsBefore}} = json:decode(OvPend),
        ?assert(
            lists:any(
                fun
                    (#{<<"name">> := <<"penduser">>, <<"verified">> := false}) -> true;
                    (_) -> false
                end,
                AcctsBefore
            )
        ),
        {200, _, VerifyActBody} = post_action(Port, GoodAuth, <<"verify-account">>, [<<"penduser">>]),
        ?assertMatch(
            #{<<"status">> := <<"verified">>, <<"account">> := <<"penduser">>},
            json:decode(VerifyActBody)
        ),
        {400, _, AlreadyBody} = post_action(Port, GoodAuth, <<"verify-account">>, [<<"penduser">>]),
        ?assertMatch(#{<<"error">> := <<"already_verified">>}, json:decode(AlreadyBody)),

        %% Public GET / (and /webirc) serves the browser IRC client with ws/wss CSP.
        {200, WebircHdrs, WebircHtml} = http_req(Port, <<"GET">>, <<"/">>, [], <<>>),
        WebircCsp = maps:get(<<"content-security-policy">>, WebircHdrs),
        ?assert(binary:match(WebircCsp, <<"connect-src 'self' ws: wss:">>) =/= nomatch),
        ?assert(binary:match(WebircCsp, <<"script-src 'self' 'nonce-">>) =/= nomatch),
        ?assert(binary:match(WebircHtml, <<"WebIRC">>) =/= nomatch),
        ?assertEqual(nomatch, binary:match(WebircHtml, <<"__NETWORK_NAME__">>)),
        ?assertEqual(nomatch, binary:match(WebircHtml, <<"__WS_PORT__">>)),
        {200, _, _} = http_req(Port, <<"GET">>, <<"/webirc">>, [], <<>>),

        %% 404 for unknown path.
        {404, _, _} = http_req(
            Port, <<"GET">>, <<"/nope">>, [{<<"Authorization">>, GoodAuth}], <<>>
        ),

        %% "Delete my data": the password is checked again; the account and
        %% what it wrote in stored history are deleted, other people's
        %% messages are kept.
        {ok, _} = ircd_ctl:run(["create-account", "eraseme", "erase-pass-1"]),
        {ok, _} = ircd_ctl:run(["create-account", "keeper", "keeper-pass-1"]),
        Entry = fun(Account, Text) ->
            #{cmd => <<"PRIVMSG">>, prefix => <<"x!x@x">>, text => Text, account => Account}
        end,
        Me = {account, <<"eraseme">>},
        Keeper = {account, <<"keeper">>},
        Guest = {nick, <<"guest">>},
        ok = ircd_state_history:replace_channel(<<"#erase">>, [
            Entry(<<"EraseMe">>, <<"mine">>),
            Entry(<<"keeper">>, <<"theirs">>),
            {<<"PRIVMSG">>, <<"old!x@x">>, <<"legacy">>}
        ]),
        %% Keys are the sorted pair ({account, _} sorts before {nick, _}).
        WithKeeper = {Me, Keeper},
        WithGuest = {Me, Guest},
        ok = mnesia:dirty_write(#direct_history{
            key = WithKeeper,
            entries = [Entry(<<"eraseme">>, <<"hi">>), Entry(<<"keeper">>, <<"hello">>)]
        }),
        ok = mnesia:dirty_write(#direct_history{
            key = WithGuest, entries = [Entry(undefined, <<"from guest">>)]
        }),
        DeleteReq = fun(Account, Pass, Extra) ->
            http_req(
                Port,
                <<"POST">>,
                <<"/api/account/delete">>,
                Extra,
                iolist_to_binary(json:encode(#{account => Account, password => Pass}))
            )
        end,
        {403, _, _} = DeleteReq(<<"eraseme">>, <<"erase-pass-1">>, []),
        {401, _, _} = DeleteReq(<<"eraseme">>, <<"wrong">>, Csrf),
        {401, _, _} = DeleteReq(<<"nobody">>, <<"erase-pass-1">>, Csrf),
        {400, _, _} = DeleteReq(<<>>, <<"x">>, Csrf),
        {200, _, ErasedBody} = DeleteReq(<<"EraseMe">>, <<"erase-pass-1">>, Csrf),
        ?assertMatch(
            #{
                <<"ok">> := true,
                <<"account">> := <<"eraseme">>,
                <<"channel_messages">> := 1,
                <<"direct_messages">> := 1
            },
            json:decode(ErasedBody)
        ),
        ?assertEqual(error, ircd_account:find(<<"eraseme">>)),
        ChanLeft = ircd_state_history:channel_history(<<"#erase">>),
        ?assertMatch(
            [#{text := <<"theirs">>}, #{text := <<"legacy">>, account := undefined}], ChanLeft
        ),
        ?assertMatch(
            [#direct_history{entries = [#{text := <<"hello">>}]}],
            mnesia:dirty_read(direct_history, WithKeeper)
        ),
        ?assertEqual([], mnesia:dirty_read(direct_history, WithGuest)),
        {401, _, _} = DeleteReq(<<"eraseme">>, <<"erase-pass-1">>, Csrf),
        ?assertMatch({ok, _}, ircd_account:find(<<"keeper">>)),

        %% Failed sign-ins from one address are limited: after 5 in 5
        %% minutes even the right password waits (the successful sign-in
        %% above cleared the earlier failure).
        LoginReq = fun(Pass) ->
            http_req(
                Port,
                <<"POST">>,
                <<"/api/admin/login">>,
                [{<<"X-Requested-With">>, <<"ircd-webui">>}],
                iolist_to_binary(json:encode(#{username => <<"admin">>, password => Pass}))
            )
        end,
        [{401, _, _} = LoginReq(<<"nope">>) || _ <- lists:seq(1, 5)],
        {429, LimitedHeaders, LimitedBody} = LoginReq(<<"topsecret">>),
        ?assert(binary_to_integer(maps:get(<<"retry-after">>, LimitedHeaders)) > 0),
        ?assertMatch(#{<<"error">> := <<"rate_limited">>}, json:decode(LimitedBody)),
        %% Password checks for deleting an account are limited separately:
        %% one failure (after the deletion) plus four more reach the limit.
        [{401, _, _} = DeleteReq(<<"keeper">>, <<"nope">>, Csrf) || _ <- lists:seq(1, 4)],
        {429, _, _} = DeleteReq(<<"keeper">>, <<"keeper-pass-1">>, Csrf),
        ?assertMatch({ok, _}, ircd_account:find(<<"keeper">>)),
        %% Basic credentials (scripts) still work meanwhile.
        {200, _, _} = http_req(
            Port, <<"GET">>, <<"/api/overview">>, [{<<"Authorization">>, GoodAuth}], <<>>
        )
    after
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG")
    end.

test_altcha_payload(Number, TtlOffset) ->
    Key = persistent_term:get({ircd_altcha, hmac_key}),
    Ch = ircd_altcha:build_challenge(Key, Number, erlang:system_time(second) + TtlOffset),
    base64:encode(iolist_to_binary(json:encode(Ch#{number => Number}))).

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
        {ok, <<_/binary>> = Chunk} -> read_all(Sock, <<Acc/binary, Chunk/binary>>);
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
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,\"ws_port\":0,">>,
        %% A network name with markup characters: the app shell must escape it.
        <<"\"network\":\"Net</script><b>&\",">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",\"shutdown_grace\":2,">>,
        <<"\"webui\":{\"bind\":\"127.0.0.1\",\"port\":0,\"username\":\"admin\",\"password\":\"topsecret\"},">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).

%% The pages are served with `style-src 'self'`, which blocks `style`
%% attributes and `<style>` blocks; styling belongs in the stylesheets.
no_inline_styles_test() ->
    Pages = filelib:wildcard("priv/webui/*.html"),
    ?assertNotEqual([], Pages),
    lists:foreach(
        fun(Page) ->
            {ok, Html} = file:read_file(Page),
            ?assertEqual({Page, nomatch}, {Page, re:run(Html, <<"\\sstyle\\s*=">>, [caseless])}),
            ?assertEqual({Page, nomatch}, {Page, re:run(Html, <<"<style[\\s>]">>, [caseless])})
        end,
        Pages
    ).

%% Whether a new IRC connection sees `Cap` in CAP LS.
has_cap(Cap) ->
    {tcp, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    true = is_pid(Pid),
    {ok, IrcPort} = ircd_listener:port(Pid),
    {ok, S} = gen_tcp:connect("127.0.0.1", IrcPort, [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(S, <<"CAP LS 302\r\n">>),
    Ls = cap_ls(S, <<>>),
    ok = gen_tcp:close(S),
    binary:match(Ls, <<" ", Cap/binary>>) =/= nomatch orelse
        binary:match(Ls, <<":", Cap/binary>>) =/= nomatch.

cap_ls(S, Acc) ->
    %% CAP LS 302 may span lines: "CAP * LS * :..." continues, and the last
    %% line is "CAP * LS :...".
    Lines = binary:split(Acc, <<"\r\n">>, [global, trim]),
    Done =
        binary:last(<<0, Acc/binary>>) =:= $\n andalso Lines =/= [] andalso
            binary:match(lists:last(Lines), <<" LS :">>) =/= nomatch,
    case Done of
        true ->
            Acc;
        false ->
            {ok, <<_/binary>> = More} = gen_tcp:recv(S, 0, 5000),
            cap_ls(S, <<Acc/binary, More/binary>>)
    end.
