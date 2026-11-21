-module(briskd_webui).
-moduledoc """
Simple HTTP administration WebUI and JSON API for `briskd`.

Opt-in via the `"webui"` configuration object (`bind`, `port`, `username`,
`password`). When enabled, `briskd_webui` opens a TCP listener (default
`127.0.0.1`) serving the web UI and its JSON endpoints.

Every page is one single-page app (Preact, built from `webui/` into
`priv/webui/assets`, which is generated and not committed). Each page route
serves the same shell, `priv/webui/app.html`, with the page's meta tags, its
stylesheet, and a JSON config block filled in by the server; the app then
loads that page's code. The pages:

- `GET /`, `/webirc`, `/status`, `/channel/...`, `/dm/...` — public
  (unauthenticated) browser IRC client over the configured `ws` / `wss`
  IRCv3 WebSocket listener.
- `GET /admin` and `/admin/<tab>` — the administration dashboard, for a
  signed-in administrator (`m:briskd_webui_auth`); otherwise a redirect to the
  sign-in page.
- `GET /admin/login`, `POST /api/admin/login`, and `POST /api/admin/logout` —
  the admin sign-in page and its session endpoints.
- `POST /api/account/delete` — public "Delete my data": with the account's
  password, deletes the account and what it wrote in stored history.
- `GET /assets/<name>` — the app's scripts (`app.js` and content-hashed
  `chunk-*.js`) and page stylesheets.
- `GET /api/stats` — the last hour of `m:briskd_stats` samples, one array per
  metric, for the Stats tab (signed in).
- `GET /api/overview` — returns combined server stats, clients, channels,
  server links, accounts, and DroneBL status/bans as JSON (signed in).
- `POST /api/action` — executes an explicitly whitelisted `m:briskd_ctl`
  management action (`rehash`, `check-config`, `reload-certs`, `search-rebuild`, `log-level`,
  `kick-client`, `notice-all`, `set-topic`, `connect`, `squit`,
  `create-account`, `verify-account`, `delete-account`, `backup`,
  `dronebl-ban`, `dronebl-unban`, `drain`, `stop`).
- `GET /verify` and `POST /api/verify` — public (unauthenticated) account
  verification page and JSON endpoint (with ALTCHA), active when
  `account_verification` is configured.
- `GET /signup` and `POST /api/signup` — public (unauthenticated) user
  self-registration page and JSON endpoint (with ALTCHA), active when
  `account_registration` is `true`.
- `GET /recover`, `POST /api/recover/request`, and `POST /api/recover/confirm`
  — public (unauthenticated) email password recovery page and JSON endpoints
  (with ALTCHA), active when `account_verification` SMTP is configured.
- `GET /favicon.ico`, `GET /favicon.svg`, and `GET /robots.txt` — public
  favicon and crawler policy assets.

Security controls:

- The admin routes (`/admin`, `/admin/*`, `/api/overview`, `/api/media`, `/api/stats`,
  `/api/action`) require a session from the sign-in page (an `HttpOnly`,
  `SameSite=Strict` cookie) or HTTP Basic credentials, both checked in
  constant time against the active configuration (`m:briskd_webui_auth`), so
  `REHASH` updates them live. No `WWW-Authenticate` challenge is sent, so a
  browser shows the sign-in page, never its own password dialog. Failed
  sign-ins are limited per client address.
- `POST /api/action` requires the `X-Requested-With: briskd-webui` header to
  prevent cross-origin CSRF.
- Each connection handles a single HTTP/1.1 request (`Connection: close`) with
  a 16 KiB size cap (uploads: the voice and files limits), at most 5 seconds
  between received chunks, and at most 16 concurrent handlers. An upload body
  may take 30 seconds plus one second per 32 KiB in total, enough for a phone
  on a slow uplink.
- Intended for loopback access (`127.0.0.1`) or placement behind a TLS
  reverse proxy (nginx/Caddy) when exposed remotely.
""".
-behaviour(gen_server).

-export([
    start_link/1,
    port/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    format_status/1,
    terminate/2
]).

-define(MAX_CONNECTIONS, 16).
-define(MAX_REQUEST_BYTES, 16384).
-define(IO_TIMEOUT_MS, 5000).

-doc """
Start the admin WebUI HTTP server, registered as `briskd_webui`.
""".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, [
        {hibernate_after, 15000},
        {spawn_opt, [{fullsweep_after, 20}]}
    ]).

-doc """
Return the TCP port the WebUI listener is currently bound to.
""".
-spec port() -> {ok, inet:port_number()} | {error, not_running}.
port() ->
    case whereis(?MODULE) of
        undefined -> {error, not_running};
        _ -> gen_server:call(?MODULE, port, 5000)
    end.

%%% gen_server callbacks

-doc false.
init(#{webui := #{ip := IP, port := Port}}) ->
    process_flag(trap_exit, true),
    Family =
        case tuple_size(IP) of
            4 -> inet;
            8 -> inet6
        end,
    Opts = [
        Family,
        binary,
        {ip, IP},
        {active, false},
        {packet, raw},
        {reuseaddr, true},
        {nodelay, true},
        {send_timeout, ?IO_TIMEOUT_MS}
    ],
    case gen_tcp:listen(Port, Opts) of
        {ok, Listen} ->
            {ok, {_, ActualPort}} = inet:sockname(Listen),
            ok = briskd_altcha:init(),
            %% Tables shared by the request handlers, owned by this
            %% long-lived process (a handler's own table would die with it).
            ok = briskd_webui_auth:init_tables(),
            ok = briskd_link_preview:init_cache(),
            _ = ensure_upload_rate_table(),
            Assets = #{
                app => load_asset("app.html", <<"briskd web UI asset missing">>),
                favicon_ico => load_raw_asset("favicon.ico", <<>>),
                favicon_svg => load_raw_asset("favicon.svg", <<>>),
                og_image => load_raw_asset("og-image.png", <<>>),
                robots_txt => load_raw_asset("robots.txt", <<"User-agent: *\nDisallow: /admin\n">>),
                static => load_static_assets()
            },
            Counter = atomics:new(1, []),
            Acceptor = spawn_link(fun() -> accept_loop(Listen, Assets, Counter) end),
            logger:notice(#{
                event => webui_listening,
                ip => briskd_wire:ip_text(IP),
                port => ActualPort
            }),
            {ok, #{
                socket => Listen,
                port => ActualPort,
                assets => Assets,
                counter => Counter,
                acceptor => Acceptor
            }};
        {error, Reason} ->
            {stop, {webui_listen_failed, Reason}}
    end.

-doc false.
handle_call(port, _From, #{port := Port} = State) ->
    {reply, {ok, Port}, State};
handle_call(_, _From, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
handle_cast(_, State) ->
    {noreply, State}.

-doc false.
handle_info(
    {'EXIT', Pid, _Reason},
    #{acceptor := Pid, socket := Listen, assets := Assets, counter := Counter} = State
) ->
    Next = spawn_link(fun() -> accept_loop(Listen, Assets, Counter) end),
    {noreply, State#{acceptor := Next}};
handle_info(_, State) ->
    {noreply, State}.

-doc false.
format_status(#{state := State} = Status) ->
    Status#{
        state => #{
            port => maps:get(port, State, undefined),
            active_connections =>
                case maps:get(counter, State, undefined) of
                    undefined -> 0;
                    C -> atomics:get(C, 1)
                end
        }
    };
format_status(Status) ->
    Status.

-doc false.
terminate(_, #{socket := Listen}) ->
    _ = gen_tcp:close(Listen),
    ok;
terminate(_, _) ->
    ok.

%%% Accept & HTTP handling

accept_loop(Listen, Assets, Counter) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            case atomics:add_get(Counter, 1, 1) of
                N when N =< ?MAX_CONNECTIONS ->
                    _ = spawn(fun() ->
                        try
                            handle_connection(Socket, Assets)
                        after
                            atomics:sub(Counter, 1, 1),
                            gen_tcp:close(Socket)
                        end
                    end),
                    ok;
                _ ->
                    atomics:sub(Counter, 1, 1),
                    _ = send_response(
                        Socket,
                        503,
                        <<"Service Unavailable">>,
                        <<"application/json; charset=utf-8">>,
                        [],
                        <<"{\"error\":\"busy\"}">>
                    ),
                    gen_tcp:close(Socket)
            end,
            accept_loop(Listen, Assets, Counter);
        {error, closed} ->
            ok;
        {error, _} ->
            timer:sleep(100),
            accept_loop(Listen, Assets, Counter)
    end.

handle_connection(
    Socket,
    #{
        app := AppHtml,
        favicon_ico := FaviconIco,
        favicon_svg := FaviconSvg,
        og_image := OgImage,
        robots_txt := RobotsTxt,
        static := Static
    }
) ->
    case read_request(Socket) of
        {ok, <<"GET">>, {<<"/favicon.ico">>, _Query}, _Headers, _Body} ->
            send_public_asset(Socket, <<"image/x-icon">>, <<"public, max-age=86400">>, FaviconIco);
        {ok, <<"GET">>, {<<"/favicon.svg">>, _Query}, _Headers, _Body} ->
            send_public_asset(
                Socket, <<"image/svg+xml">>, <<"public, max-age=86400">>, FaviconSvg
            );
        {ok, <<"GET">>, {<<"/og-image.png">>, _Query}, _Headers, _Body} ->
            send_public_asset(Socket, <<"image/png">>, <<"public, max-age=86400">>, OgImage);
        {ok, <<"GET">>, {<<"/robots.txt">>, _Query}, _Headers, _Body} ->
            send_public_asset(
                Socket, <<"text/plain; charset=utf-8">>, <<"public, max-age=3600">>, RobotsTxt
            );
        {ok, <<"GET">>, {<<"/assets/", Name/binary>>, _Query}, _Headers, _Body} ->
            handle_static(Socket, Name, Static);
        {ok, <<"GET">>, {<<"/api/altcha">>, _Query}, _Headers, _Body} ->
            send_json(Socket, 200, <<"OK">>, briskd_altcha:create_challenge());
        {ok, <<"POST">>, {<<"/api/webirc/verify">>, _Query}, Headers, Body} ->
            handle_webirc_verify_api(Socket, Headers, Body);
        {ok, <<"GET">>, {Path, _Query}, Headers, _Body} when
            Path =:= <<"/">>;
            Path =:= <<"/webirc">>;
            Path =:= <<"/status">>;
            binary_part(Path, 0, min(byte_size(Path), 9)) =:= <<"/channel/">>;
            binary_part(Path, 0, min(byte_size(Path), 4)) =:= <<"/dm/">>
        ->
            handle_webirc_page(Socket, AppHtml, Path, Headers);
        {ok, <<"GET">>, {<<"/verify">>, _Query}, Headers, _Body} ->
            handle_verify_page(Socket, AppHtml, Headers);
        {ok, <<"POST">>, {<<"/api/verify">>, _Query}, Headers, Body} ->
            handle_verify_api(Socket, Headers, Body);
        {ok, <<"GET">>, {<<"/signup">>, _Query}, Headers, _Body} ->
            handle_signup_page(Socket, AppHtml, Headers);
        {ok, <<"POST">>, {<<"/api/signup">>, _Query}, Headers, Body} ->
            handle_signup_api(Socket, Headers, Body);
        {ok, <<"GET">>, {<<"/recover">>, _Query}, Headers, _Body} ->
            handle_recover_page(Socket, AppHtml, Headers);
        {ok, <<"POST">>, {<<"/api/recover/request">>, _Query}, Headers, Body} ->
            handle_recover_request_api(Socket, Headers, Body);
        {ok, <<"POST">>, {<<"/api/recover/confirm">>, _Query}, Headers, Body} ->
            handle_recover_confirm_api(Socket, Headers, Body);
        {ok, <<"POST">>, {<<"/api/voice">>, _Query}, Headers, Body} ->
            handle_voice_upload(Socket, Headers, Body);
        {ok, <<"GET">>, {<<"/api/voice/", VoiceId/binary>>, _Query}, _Headers, _Body} ->
            handle_voice_download(Socket, VoiceId);
        {ok, <<"POST">>, {<<"/api/files">>, _Query}, Headers, Body} ->
            handle_file_upload(Socket, Headers, Body);
        {ok, <<"GET">>, {<<"/api/files/", FileId/binary>>, _Query}, _Headers, _Body} ->
            handle_file_download(Socket, FileId);
        {ok, <<"GET">>, {<<"/api/link-preview">>, Query}, Headers, _Body} ->
            handle_link_preview(Socket, Query, Headers);
        {ok, <<"GET">>, {<<"/admin/login">>, _Query}, Headers, _Body} ->
            case briskd_webui_auth:check(Headers) of
                ok -> redirect(Socket, <<"/admin">>);
                unauthorized -> send_app(Socket, AppHtml, login, <<"/admin/login">>, Headers)
            end;
        {ok, <<"POST">>, {<<"/api/admin/login">>, _Query}, Headers, Body} ->
            handle_admin_login(Socket, Headers, Body);
        {ok, <<"POST">>, {<<"/api/admin/logout">>, _Query}, Headers, _Body} ->
            handle_admin_logout(Socket, Headers);
        {ok, <<"POST">>, {<<"/api/account/delete">>, _Query}, Headers, Body} ->
            handle_account_delete(Socket, Headers, Body);
        {ok, Method, {Path, _Query}, Headers, Body} ->
            case admin_path(Path) of
                true ->
                    case briskd_webui_auth:check(Headers) of
                        ok ->
                            route(Socket, Method, Path, Headers, Body, AppHtml);
                        unauthorized when
                            Method =:= <<"GET">>,
                            Path =/= <<"/api/overview">>,
                            Path =/= <<"/api/media">>,
                            Path =/= <<"/api/stats">>
                        ->
                            %% A page: go to the sign-in page, then back here.
                            redirect(Socket, login_url(Path));
                        unauthorized ->
                            send_json(Socket, 401, <<"Unauthorized">>, #{
                                error => <<"unauthorized">>
                            })
                    end;
                false ->
                    %% Not a page or API of this server. Answering with the
                    %% admin Basic challenge made browsers show a password
                    %% dialog on the chat page whenever they probed a path of
                    %% their own (apple-touch-icon, manifest, DevTools'
                    %% /.well-known/appspecific/...).
                    send_json(Socket, 404, <<"Not Found">>, #{error => <<"not_found">>})
            end;
        {error, payload_too_large} ->
            send_json(Socket, 413, <<"Payload Too Large">>, #{error => <<"payload_too_large">>});
        {error, {idle, _}} ->
            ok;
        {error, _} ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"bad_request">>})
    end.

%% Paths of the admin panel and its JSON API (`route/6`), the only ones
%% that need an administrator to be signed in.
admin_path(<<"/admin">>) -> true;
admin_path(<<"/admin/", _/binary>>) -> true;
admin_path(<<"/api/overview">>) -> true;
admin_path(<<"/api/media">>) -> true;
admin_path(<<"/api/stats">>) -> true;
admin_path(<<"/api/action">>) -> true;
admin_path(_) -> false.

%% The sign-in page, returning to `Path` (an admin page) afterwards. Only a
%% plain `/admin/<letters>` path is carried; anything else returns to /admin.
login_url(Path) ->
    case re:run(Path, <<"^/admin(/[a-z]*)?$">>, [{capture, none}]) of
        match -> <<"/admin/login?next=", Path/binary>>;
        nomatch -> <<"/admin/login">>
    end.

redirect(Socket, Location) ->
    send_response(
        Socket,
        302,
        <<"Found">>,
        <<"text/plain; charset=utf-8">>,
        [{<<"Location">>, Location}],
        <<>>
    ).

%% Whether the request reached us over HTTPS (through a TLS proxy).
https_request(Headers) ->
    briskd_wire:lower(maps:get(<<"x-forwarded-proto">>, Headers, <<"http">>)) =:= <<"https">>.

handle_admin_login(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            IP = peer_ip(Socket),
            Creds =
                try json:decode(Body) of
                    #{<<"username">> := U, <<"password">> := P} when
                        is_binary(U), is_binary(P), byte_size(U) =< 256, byte_size(P) =< 1024
                    ->
                        {U, P};
                    _ ->
                        invalid
                catch
                    error:_ -> invalid
                end,
            case Creds of
                invalid ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_request">>,
                        message => <<"Enter the username and password.">>
                    });
                {User, Pass} ->
                    case briskd_webui_auth:login(User, Pass, IP) of
                        {ok, Token} ->
                            logger:notice(#{event => webui_login, result => ok, ip => IP}),
                            send_response(
                                Socket,
                                200,
                                <<"OK">>,
                                <<"application/json; charset=utf-8">>,
                                [
                                    {<<"Set-Cookie">>,
                                        briskd_webui_auth:cookie(Token, https_request(Headers))}
                                ],
                                <<"{\"ok\":true}">>
                            );
                        {error, invalid} ->
                            logger:warning(#{event => webui_login, result => failed, ip => IP}),
                            send_json(Socket, 401, <<"Unauthorized">>, #{
                                error => <<"invalid_credentials">>,
                                message => <<"Wrong username or password.">>
                            });
                        {error, rate_limited} ->
                            Retry = briskd_webui_auth:login_retry_after(IP),
                            logger:warning(#{event => webui_login, result => rate_limited, ip => IP}),
                            send_response(
                                Socket,
                                429,
                                <<"Too Many Requests">>,
                                <<"application/json; charset=utf-8">>,
                                [{<<"Retry-After">>, integer_to_binary(Retry)}],
                                json:encode(#{
                                    error => <<"rate_limited">>,
                                    retry_after => Retry,
                                    message => <<"Too many failed sign-ins. Try again later.">>
                                })
                            )
                    end
            end;
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end.

%% "Delete my data" from WebIRC settings: the account and its password
%% (checked again here, with the same timing for unknown accounts; failures
%% limited per address like admin sign-in), then the account, its read
%% markers, E2EE devices and queued messages, and the messages it wrote in
%% stored history are deleted, and its sessions are logged out.
handle_account_delete(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            IP = peer_ip(Socket),
            Req =
                try json:decode(Body) of
                    #{<<"account">> := A, <<"password">> := P} when
                        is_binary(A),
                        is_binary(P),
                        byte_size(A) > 0,
                        byte_size(A) =< 64,
                        byte_size(P) > 0,
                        byte_size(P) =< 1024
                    ->
                        {A, P};
                    _ ->
                        invalid
                catch
                    error:_ -> invalid
                end,
            case {Req, briskd_webui_auth:retry_after(account_delete, IP)} of
                {invalid, _} ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_request">>,
                        message => <<"Enter your account name and password.">>
                    });
                {_, Retry} when Retry > 0 ->
                    send_response(
                        Socket,
                        429,
                        <<"Too Many Requests">>,
                        <<"application/json; charset=utf-8">>,
                        [{<<"Retry-After">>, integer_to_binary(Retry)}],
                        json:encode(#{
                            error => <<"rate_limited">>,
                            retry_after => Retry,
                            message => <<"Too many wrong passwords. Try again later.">>
                        })
                    );
                {{Account, Password}, 0} ->
                    case briskd_account:check_password(Account, Password) of
                        {ok, _} ->
                            briskd_webui_auth:clear_failures(account_delete, IP),
                            account_erase(Socket, Account);
                        error ->
                            briskd_webui_auth:note_failure(account_delete, IP),
                            send_json(Socket, 401, <<"Unauthorized">>, #{
                                error => <<"invalid_credentials">>,
                                message => <<"Wrong account name or password.">>
                            })
                    end
            end;
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end.

account_erase(Socket, Account) ->
    case briskd_state:ctl({erase_account, Account}) of
        {ok, #{account := Actual} = Reply} ->
            send_json(Socket, 200, <<"OK">>, #{
                ok => true,
                account => Actual,
                channel_messages => maps:get(channel_messages, Reply, 0),
                direct_messages => maps:get(direct_messages, Reply, 0)
            });
        {error, _} ->
            send_json(Socket, 500, <<"Internal Server Error">>, #{
                error => <<"delete_failed">>,
                message => <<"The account could not be deleted. Please try again.">>
            })
    end.

handle_admin_logout(Socket, Headers) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            ok = briskd_webui_auth:logout(Headers),
            send_response(
                Socket,
                200,
                <<"OK">>,
                <<"application/json; charset=utf-8">>,
                [{<<"Set-Cookie">>, briskd_webui_auth:clear_cookie(https_request(Headers))}],
                <<"{\"ok\":true}">>
            );
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end.

send_public_asset(Socket, _ContentType, _Cache, <<>>) ->
    send_json(Socket, 404, <<"Not Found">>, #{error => <<"not_found">>});
send_public_asset(Socket, ContentType, Cache, Body) ->
    send_response(
        Socket,
        200,
        <<"OK">>,
        ContentType,
        [{<<"Cache-Control">>, Cache}],
        Body
    ).

handle_static(Socket, Name, Static) ->
    case maps:find(Name, Static) of
        {ok, {ContentType, Body}} ->
            send_response(
                Socket,
                200,
                <<"OK">>,
                ContentType,
                [{<<"Cache-Control">>, <<"public, max-age=300">>}],
                Body
            );
        error ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"not_found">>})
    end.

handle_webirc_page(Socket, AppHtml, Path, Headers) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(ws, Config, null) =:= null andalso maps:get(wss, Config, null) =:= null of
        true ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"webirc_disabled">>});
        false ->
            send_app(Socket, AppHtml, webirc, Path, Headers)
    end.

%% The single-page app shell (priv/webui/app.html) serves every page. The
%% server fills in what must be there before any script runs: the page meta
%% (link previews and search engines read it), the page's stylesheet (so the
%% first paint is styled), and the client config as JSON.
send_app(Socket, AppHtml, Page, Path, Headers) ->
    Config = briskd_config:current_or_empty(),
    Network = maps:get(network, Config, maps:get(name, Config, <<"IRC">>)),
    Channels = default_channels(Config),
    Origin = public_origin(Headers, Config),
    {Title, Description, Robots} = page_meta(Page, Network, Channels),
    Html = fill_template(AppHtml, #{
        <<"__TITLE__">> => escape_html(Title),
        <<"__DESCRIPTION__">> => escape_html(Description),
        <<"__ROBOTS__">> => Robots,
        <<"__NETWORK_NAME__">> => escape_html(Network),
        <<"__PUBLIC_URL__">> => escape_html(<<Origin/binary, Path/binary>>),
        <<"__OG_IMAGE_URL__">> => escape_html(<<Origin/binary, "/og-image.png">>),
        <<"__STYLE__">> => <<(atom_to_binary(Page))/binary, ".css">>,
        <<"__APP_CONFIG__">> => app_config_json(Config, Network, Channels)
    }),
    send_nonce_html(
        Socket,
        Html,
        <<"connect-src 'self' ws: wss:; img-src 'self' data: blob:; media-src 'self' blob:; ">>
    ).

%% Replace each `__NAME__` placeholder in one pass: text that a value brings
%% in (a network name, say) is never scanned for placeholders again.
fill_template(Template, Values) ->
    Parts = re:split(Template, <<"(__[A-Z_]+__)">>, [{return, binary}]),
    iolist_to_binary([maps:get(P, Values, P) || P <- Parts]).

page_meta(webirc, Network, Channels) ->
    {
        <<Network/binary, " - WebIRC">>,
        <<"Join ", Network/binary, " IRC (", Channels/binary,
            ") directly in your browser with IRCv3 WebSocket, chat history, themes, "
            "and optional end-to-end encryption (E2EE).">>,
        <<"index, follow">>
    };
page_meta(signup, Network, _) ->
    {
        <<"Sign Up - ", Network/binary>>,
        <<
            "Create an IRC SASL account for secure authentication and end-to-end "
            "encrypted messaging."
        >>,
        <<"index, follow">>
    };
page_meta(verify, Network, _) ->
    {
        <<"Verify Account - ", Network/binary>>,
        <<"Verify your IRC account with the code from your email.">>,
        <<"noindex">>
    };
page_meta(recover, Network, _) ->
    {
        <<"Recover Password - ", Network/binary>>,
        <<"Reset your IRC account password with your verified email address.">>,
        <<"noindex">>
    };
page_meta(login, Network, _) ->
    {<<"Admin Sign In - ", Network/binary>>, <<>>, <<"noindex, nofollow">>};
page_meta(admin, Network, _) ->
    {<<"Admin - ", Network/binary>>, <<>>, <<"noindex, nofollow">>}.

%% Client config (webui/src/app/config.ts). It is embedded in a <script
%% type="application/json"> block: `<`, `>`, and `&` are escaped so no value
%% can close the block or start markup.
app_config_json(Config, Network, Channels) ->
    WebCfg =
        case maps:get(webui, Config, null) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    Verification = maps:get(account_verification, Config, null),
    Json = iolist_to_binary(
        json:encode(#{
            network => Network,
            wsPort => port_to_bin(maps:get(ws, Config, null)),
            wssPort => port_to_bin(maps:get(wss, Config, null)),
            defaultChannels => Channels,
            termsUrl => maps:get(terms_url, WebCfg, <<"https://example.com/terms">>),
            privacyUrl => maps:get(privacy_url, WebCfg, <<"https://example.com/privacy">>),
            features => #{
                webirc =>
                    maps:get(ws, Config, null) =/= null orelse
                    maps:get(wss, Config, null) =/= null,
                registration => maps:get(account_registration, Config, true) =:= true,
                verification => Verification =/= null,
                recovery => is_map(Verification) andalso is_map_key(smtp, Verification)
            }
        })
    ),
    lists:foldl(
        fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end,
        Json,
        [{<<"<">>, <<"\\u003c">>}, {<<">">>, <<"\\u003e">>}, {<<"&">>, <<"\\u0026">>}]
    ).

public_origin(Headers, Config) ->
    Proto =
        case briskd_wire:lower(maps:get(<<"x-forwarded-proto">>, Headers, <<"http">>)) of
            <<"https">> -> <<"https">>;
            _ -> <<"http">>
        end,
    RawHost = maps:get(<<"host">>, Headers, maps:get(name, Config, <<"localhost">>)),
    Host = sanitize_host(RawHost, maps:get(name, Config, <<"localhost">>)),
    <<Proto/binary, "://", Host/binary>>.

sanitize_host(Bin, Fallback) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 255 ->
    %% Letters, digits, and `.-:[]` only (host names, IPv4, bracketed IPv6).
    case re:run(Bin, <<"^[A-Za-z0-9.:\\[\\]-]+$">>, [{capture, none}, dollar_endonly]) of
        match -> Bin;
        nomatch -> Fallback
    end;
sanitize_host(_, Fallback) ->
    Fallback.

port_to_bin(null) -> <<>>;
port_to_bin(Port) when is_integer(Port) -> integer_to_binary(Port).

default_channels(Config) ->
    case maps:get(channels, Config, []) of
        [] ->
            <<"#lobby">>;
        Chans ->
            Names = [maps:get(name, C) || C <- lists:sublist(Chans, 5), is_map_key(name, C)],
            case Names of
                [] -> <<"#lobby">>;
                _ -> binary:join(Names, <<",">>)
            end
    end.

handle_webirc_verify_api(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            try json:decode(Body) of
                Req when is_map(Req) ->
                    case require_altcha(Req) of
                        ok ->
                            send_json(Socket, 200, <<"OK">>, #{status => <<"verified">>});
                        {error, Code, Msg} ->
                            send_json(Socket, 400, <<"Bad Request">>, #{
                                error => Code, message => Msg
                            })
                    end;
                _ ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_request">>,
                        message => <<"Invalid verification request.">>
                    })
            catch
                _:_ ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_json">>,
                        message => <<"Invalid JSON request.">>
                    })
            end;
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end.

handle_recover_page(Socket, AppHtml, Headers) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_verification, Config, null) of
        #{smtp := _} ->
            send_app(Socket, AppHtml, recover, <<"/recover">>, Headers);
        _ ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"recovery_disabled">>})
    end.

handle_recover_request_api(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            try json:decode(Body) of
                #{<<"email">> := Email} = Req when is_binary(Email), byte_size(Email) > 0 ->
                    case require_altcha(Req) of
                        ok ->
                            Config = briskd_config:current_or_empty(),
                            Origin = public_origin(Headers, Config),
                            RecoveryUrl = <<Origin/binary, "/recover">>,
                            PeerIP = peer_ip(Socket),
                            case briskd_state:request_password_reset(Email, RecoveryUrl, PeerIP) of
                                ok ->
                                    send_json(Socket, 200, <<"OK">>, #{
                                        status => <<"sent">>,
                                        message =>
                                            <<"If an account exists for that email, a recovery code has been sent.">>
                                    });
                                {error, disabled} ->
                                    send_json(Socket, 404, <<"Not Found">>, #{
                                        error => <<"recovery_disabled">>,
                                        message => <<"Password recovery via email is not enabled.">>
                                    });
                                {error, rate_limited} ->
                                    send_json(Socket, 429, <<"Too Many Requests">>, #{
                                        error => <<"rate_limited">>,
                                        message =>
                                            <<"Too many recovery attempts. Please try again later.">>
                                    });
                                {error, bad_email} ->
                                    send_json(Socket, 400, <<"Bad Request">>, #{
                                        error => <<"invalid_email">>,
                                        message => <<"Enter a valid email address.">>
                                    })
                            end;
                        {error, Code, Msg} ->
                            send_json(Socket, 400, <<"Bad Request">>, #{
                                error => Code, message => Msg
                            })
                    end;
                _ ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_request">>,
                        message => <<"Email address is required.">>
                    })
            catch
                _:_ ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_json">>,
                        message => <<"Invalid JSON request.">>
                    })
            end;
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end.

handle_recover_confirm_api(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            try json:decode(Body) of
                #{
                    <<"email">> := Email,
                    <<"code">> := Code,
                    <<"password">> := Password
                } = Req when
                    is_binary(Email),
                    byte_size(Email) > 0,
                    is_binary(Code),
                    byte_size(Code) > 0,
                    is_binary(Password),
                    byte_size(Password) > 0
                ->
                    case require_altcha(Req) of
                        ok ->
                            PeerIP = peer_ip(Socket),
                            case
                                briskd_state:complete_password_reset(Email, Code, Password, PeerIP)
                            of
                                {ok, AccountName} ->
                                    send_json(Socket, 200, <<"OK">>, #{
                                        status => <<"reset">>,
                                        account => AccountName
                                    });
                                {error, disabled} ->
                                    send_json(Socket, 404, <<"Not Found">>, #{
                                        error => <<"recovery_disabled">>,
                                        message => <<"Password recovery via email is not enabled.">>
                                    });
                                {error, rate_limited} ->
                                    send_json(Socket, 429, <<"Too Many Requests">>, #{
                                        error => <<"rate_limited">>,
                                        message =>
                                            <<"Too many recovery attempts. Please try again later.">>
                                    });
                                {error, bad_password} ->
                                    send_json(Socket, 400, <<"Bad Request">>, #{
                                        error => <<"bad_password">>,
                                        message => <<"Password does not meet length requirements.">>
                                    });
                                {error, invalid_code} ->
                                    send_json(Socket, 400, <<"Bad Request">>, #{
                                        error => <<"invalid_code">>,
                                        message => <<"Invalid or expired recovery code.">>
                                    })
                            end;
                        {error, ErrCode, Msg} ->
                            send_json(Socket, 400, <<"Bad Request">>, #{
                                error => ErrCode, message => Msg
                            })
                    end;
                _ ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_request">>,
                        message => <<"Email, recovery code, and new password are required.">>
                    })
            catch
                _:_ ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_json">>,
                        message => <<"Invalid JSON request.">>
                    })
            end;
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end.

handle_signup_page(Socket, AppHtml, Headers) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_registration, Config, true) of
        true ->
            send_app(Socket, AppHtml, signup, <<"/signup">>, Headers);
        false ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"registration_disabled">>})
    end.

handle_signup_api(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            try json:decode(Body) of
                #{<<"account">> := Account, <<"password">> := Password} = Req when
                    is_binary(Account), is_binary(Password)
                ->
                    case maps:get(<<"accept_terms">>, Req, false) of
                        true ->
                            case require_altcha(Req) of
                                ok ->
                                    handle_signup_submit(Socket, Account, Password, Req);
                                {error, AltchaErr, Msg} ->
                                    send_json(Socket, 400, <<"Bad Request">>, #{
                                        error => AltchaErr, message => Msg
                                    })
                            end;
                        _ ->
                            send_json(Socket, 400, <<"Bad Request">>, #{
                                error => <<"terms_not_accepted">>,
                                message =>
                                    <<"You must accept the Terms of Use and Privacy Policy.">>
                            })
                    end;
                _ ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_request">>,
                        message => <<"Account name and password are required.">>
                    })
            catch
                _:_ ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_json">>,
                        message => <<"Invalid JSON request.">>
                    })
            end;
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end.

handle_signup_submit(Socket, Account, Password, Req) ->
    Email =
        case maps:get(<<"email">>, Req, undefined) of
            undefined -> undefined;
            null -> undefined;
            E when is_binary(E) -> E;
            _ -> invalid
        end,
    case Email of
        invalid ->
            send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_email">>,
                message => <<"Invalid email address.">>
            });
        _ ->
            PeerIP = peer_ip(Socket),
            case briskd_state:signup_account(Account, Email, Password, PeerIP) of
                {ok, created, Name} ->
                    send_json(Socket, 201, <<"Created">>, #{
                        status => <<"created">>, account => Name
                    });
                {ok, verification_required, Name} ->
                    send_json(Socket, 202, <<"Accepted">>, #{
                        status => <<"verification_required">>, account => Name
                    });
                {error, registration_disabled} ->
                    send_json(Socket, 404, <<"Not Found">>, #{
                        error => <<"registration_disabled">>,
                        message => <<"Account registration is disabled.">>
                    });
                {error, rate_limited} ->
                    send_json(Socket, 429, <<"Too Many Requests">>, #{
                        error => <<"rate_limited">>,
                        message => <<"Too many registration attempts. Try again later.">>
                    });
                {error, Reason} ->
                    send_json(Socket, 400, <<"Bad Request">>, #{
                        error => atom_to_binary(Reason),
                        message => signup_error_message(Reason)
                    })
            end
    end.

signup_error_message(account_exists) -> <<"That account name is already taken.">>;
signup_error_message(bad_account_name) -> <<"Invalid account name.">>;
signup_error_message(weak_password) -> <<"Password is too short.">>;
signup_error_message(unacceptable_password) -> <<"Password is too long.">>;
signup_error_message(email_required) -> <<"A valid email address is required.">>;
signup_error_message(invalid_email) -> <<"Invalid email address.">>;
signup_error_message(account_limit_reached) -> <<"Server account limit reached.">>;
signup_error_message(_) -> <<"Could not create account.">>.

handle_voice_upload(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            case check_upload_rate(peer_ip(Socket)) of
                ok ->
                    Duration = parse_voice_duration(
                        maps:get(<<"x-voice-duration">>, Headers, undefined)
                    ),
                    case briskd_voice:store(Body, Duration) of
                        {ok, Meta} ->
                            send_json(Socket, 201, <<"Created">>, Meta);
                        {error, disabled} ->
                            send_json(Socket, 404, <<"Not Found">>, #{error => <<"voice_disabled">>});
                        {error, empty} ->
                            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"empty_audio">>});
                        {error, too_large} ->
                            send_json(Socket, 413, <<"Payload Too Large">>, #{
                                error => <<"payload_too_large">>
                            });
                        {error, too_long} ->
                            send_json(Socket, 400, <<"Bad Request">>, #{
                                error => <<"voice_too_long">>
                            });
                        {error, unsupported_format} ->
                            send_json(Socket, 415, <<"Unsupported Media Type">>, #{
                                error => <<"unsupported_format">>,
                                message => <<"Only OPUS audio (Ogg or WebM) is accepted.">>
                            });
                        {error, Reason} ->
                            logger:warning(#{event => voice_upload_failed, reason => Reason}),
                            send_json(Socket, 502, <<"Bad Gateway">>, #{
                                error => <<"storage_error">>
                            })
                    end;
                rate_limited ->
                    send_json(Socket, 429, <<"Too Many Requests">>, #{
                        error => <<"rate_limited">>,
                        message => <<"Too many uploads. Please wait a moment.">>
                    })
            end;
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end.

handle_voice_download(Socket, VoiceId) ->
    case briskd_voice:fetch(VoiceId) of
        {ok, Bytes, Mime} ->
            send_response(
                Socket,
                200,
                <<"OK">>,
                Mime,
                [
                    {<<"Cache-Control">>, <<"public, max-age=86400">>},
                    {<<"Content-Disposition">>, <<"inline">>}
                ],
                Bytes
            );
        {error, disabled} ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"voice_disabled">>});
        {error, invalid_id} ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_voice_id">>});
        {error, not_found} ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"not_found">>});
        {error, Reason} ->
            logger:warning(#{event => voice_download_failed, id => VoiceId, reason => Reason}),
            send_json(Socket, 502, <<"Bad Gateway">>, #{error => <<"storage_error">>})
    end.

parse_voice_duration(undefined) ->
    undefined;
parse_voice_duration(Bin) when is_binary(Bin) ->
    try binary_to_integer(string:trim(Bin)) of
        N when N >= 0 -> N;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

handle_file_upload(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            case check_upload_rate(peer_ip(Socket)) of
                ok ->
                    RawName = decode_header_filename(
                        maps:get(<<"x-file-name">>, Headers, undefined)
                    ),
                    case briskd_files:store(Body, RawName) of
                        {ok, Meta} ->
                            send_json(Socket, 201, <<"Created">>, Meta);
                        {error, disabled} ->
                            send_json(Socket, 404, <<"Not Found">>, #{error => <<"files_disabled">>});
                        {error, empty} ->
                            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"empty_file">>});
                        {error, too_large} ->
                            send_json(Socket, 413, <<"Payload Too Large">>, #{
                                error => <<"payload_too_large">>
                            });
                        {error, Reason} ->
                            logger:warning(#{event => file_upload_failed, reason => Reason}),
                            send_json(Socket, 502, <<"Bad Gateway">>, #{
                                error => <<"storage_error">>
                            })
                    end;
                rate_limited ->
                    send_json(Socket, 429, <<"Too Many Requests">>, #{
                        error => <<"rate_limited">>,
                        message => <<"Too many uploads. Please wait a moment.">>
                    })
            end;
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end.

%% Bounded per-IP upload rate limiter: at most 20 uploads per 60 seconds.
check_upload_rate(IP) ->
    Tab = ensure_upload_rate_table(),
    Now = erlang:monotonic_time(second),
    Cutoff = Now - 60,
    case ets:lookup(Tab, IP) of
        [{IP, Timestamps}] ->
            Recent = [T || T <- Timestamps, T > Cutoff],
            case length(Recent) >= 20 of
                true ->
                    ets:insert(Tab, {IP, Recent}),
                    rate_limited;
                false ->
                    ets:insert(Tab, {IP, [Now | Recent]}),
                    ok
            end;
        [] ->
            case ets:info(Tab, size) > 5000 of
                true -> ets:delete_all_objects(Tab);
                false -> ok
            end,
            ets:insert(Tab, {IP, [Now]}),
            ok
    end.

ensure_upload_rate_table() ->
    case ets:whereis(briskd_webui_uploads) of
        undefined ->
            try
                ets:new(briskd_webui_uploads, [named_table, public, set])
            catch
                error:badarg -> briskd_webui_uploads
            end;
        Tab ->
            Tab
    end.

handle_file_download(Socket, FileId) ->
    case briskd_files:fetch(FileId) of
        {ok, Bytes, Mime, InlinePreview} ->
            Disp =
                case InlinePreview of
                    true -> <<"inline">>;
                    false -> <<"attachment">>
                end,
            send_response(
                Socket,
                200,
                <<"OK">>,
                Mime,
                [
                    {<<"Cache-Control">>, <<"public, max-age=86400">>},
                    {<<"Content-Disposition">>, Disp},
                    {<<"Content-Security-Policy">>, <<"default-src 'none'; sandbox">>}
                ],
                Bytes
            );
        {error, disabled} ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"files_disabled">>});
        {error, invalid_id} ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_file_id">>});
        {error, not_found} ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"not_found">>});
        {error, Reason} ->
            logger:warning(#{event => file_download_failed, id => FileId, reason => Reason}),
            send_json(Socket, 502, <<"Bad Gateway">>, #{error => <<"storage_error">>})
    end.

decode_header_filename(undefined) ->
    undefined;
decode_header_filename(Bin) when is_binary(Bin) ->
    try uri_string:percent_decode(Bin) of
        Decoded when is_binary(Decoded) -> Decoded;
        _ -> Bin
    catch
        _:_ -> Bin
    end.

handle_link_preview(Socket, Query, Headers) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            Url = extract_query_param(<<"url">>, Query),
            case Url of
                <<>> ->
                    send_json(Socket, 400, <<"Bad Request">>, #{error => <<"missing_url">>});
                _ ->
                    case briskd_link_preview:fetch(Url) of
                        {ok, Meta} ->
                            send_json(Socket, 200, <<"OK">>, Meta);
                        {error, disabled} ->
                            send_json(Socket, 404, <<"Not Found">>, #{
                                error => <<"link_previews_disabled">>
                            });
                        {error, private_address} ->
                            send_json(Socket, 403, <<"Forbidden">>, #{
                                error => <<"private_address">>
                            });
                        {error, invalid_url} ->
                            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_url">>});
                        {error, disallowed_port} ->
                            send_json(Socket, 400, <<"Bad Request">>, #{
                                error => <<"disallowed_port">>
                            });
                        {error, _} ->
                            %% The page exists but has no usable preview (or
                            %% could not be fetched): a normal outcome, so no
                            %% error status for the browser console to report.
                            send_response(Socket, 204, <<"No Content">>, <<>>, [], <<>>)
                    end
            end;
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end.

extract_query_param(Key, Query) ->
    try uri_string:dissect_query(Query) of
        Pairs when is_list(Pairs) ->
            case lists:keyfind(Key, 1, Pairs) of
                {_, Val} when is_binary(Val) -> Val;
                _ -> <<>>
            end;
        _ ->
            <<>>
    catch
        _:_ -> <<>>
    end.

peer_ip(Socket) ->
    case inet:peername(Socket) of
        {ok, {Addr, _}} when is_tuple(Addr) -> briskd_wire:ip_text(Addr);
        _ -> <<"unknown">>
    end.

require_altcha(Req) ->
    case maps:get(<<"altcha">>, Req, undefined) of
        Payload when is_binary(Payload), byte_size(Payload) > 0 ->
            case briskd_altcha:verify_payload(Payload) of
                ok ->
                    ok;
                {error, expired} ->
                    {error, <<"altcha_expired">>,
                        <<"ALTCHA challenge expired. Please verify again.">>};
                {error, replayed} ->
                    {error, <<"altcha_replayed">>,
                        <<"ALTCHA challenge already used. Please verify again.">>};
                {error, busy} ->
                    {error, <<"altcha_busy">>,
                        <<"Too many verifications right now. Please try again in a few minutes.">>};
                {error, invalid} ->
                    {error, <<"altcha_invalid">>, <<"Invalid ALTCHA verification.">>}
            end;
        _ ->
            {error, <<"altcha_required">>, <<"Please complete the ALTCHA verification.">>}
    end.

handle_verify_page(Socket, AppHtml, Headers) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_verification, Config, null) of
        null ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"verification_disabled">>});
        _ ->
            send_app(Socket, AppHtml, verify, <<"/verify">>, Headers)
    end.

handle_verify_api(Socket, Headers, Body) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_verification, Config, null) of
        null ->
            send_json(Socket, 404, <<"Not Found">>, #{
                error => <<"verification_disabled">>,
                message => <<"Account verification is disabled.">>
            });
        _ ->
            case maps:get(<<"x-requested-with">>, Headers, undefined) of
                <<"briskd-webui">> ->
                    try json:decode(Body) of
                        #{<<"code">> := Code} = Req when is_binary(Code), byte_size(Code) > 0 ->
                            case require_altcha(Req) of
                                ok ->
                                    verify_from_json(Socket, Req, Code);
                                {error, AltchaErr, Msg} ->
                                    send_json(Socket, 400, <<"Bad Request">>, #{
                                        error => AltchaErr, message => Msg
                                    })
                            end;
                        _ ->
                            send_json(Socket, 400, <<"Bad Request">>, #{
                                error => <<"invalid_request">>,
                                message => <<"Verification code is required.">>
                            })
                    catch
                        _:_ ->
                            send_json(Socket, 400, <<"Bad Request">>, #{
                                error => <<"invalid_json">>,
                                message => <<"Invalid JSON request.">>
                            })
                    end;
                _ ->
                    send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
            end
    end.

verify_from_json(Socket, Req, Code) ->
    Result =
        case maps:get(<<"email">>, Req, undefined) of
            Email when is_binary(Email), byte_size(Email) > 0 ->
                briskd_state:verify_account_by_email(Email, Code);
            _ ->
                case maps:get(<<"account">>, Req, undefined) of
                    Account when is_binary(Account), byte_size(Account) > 0 ->
                        briskd_state:verify_account(Account, Code);
                    _ ->
                        missing_ident
                end
        end,
    case Result of
        {ok, VerifiedName} ->
            send_json(Socket, 200, <<"OK">>, #{
                status => <<"verified">>, account => VerifiedName
            });
        missing_ident ->
            send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"missing_identifier">>,
                message => <<"Email address or account name is required.">>
            });
        error ->
            send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_code">>,
                message => <<"The verification code is invalid or has expired.">>
            })
    end.

escape_html(Bin) ->
    B1 = binary:replace(Bin, <<"&">>, <<"&amp;">>, [global]),
    B2 = binary:replace(B1, <<"<">>, <<"&lt;">>, [global]),
    B3 = binary:replace(B2, <<">">>, <<"&gt;">>, [global]),
    B4 = binary:replace(B3, <<"\"">>, <<"&quot;">>, [global]),
    binary:replace(B4, <<"'">>, <<"&#39;">>, [global]).

route(Socket, <<"GET">>, Path, Headers, _Body, Html) when
    Path =:= <<"/admin">>;
    Path =:= <<"/admin/">>;
    Path =:= <<"/admin/overview">>;
    Path =:= <<"/admin/stats">>;
    Path =:= <<"/admin/clients">>;
    Path =:= <<"/admin/channels">>;
    Path =:= <<"/admin/links">>;
    Path =:= <<"/admin/accounts">>;
    Path =:= <<"/admin/dronebl">>;
    Path =:= <<"/admin/media">>;
    Path =:= <<"/admin/operations">>
->
    send_app(Socket, Html, admin, Path, Headers);
route(Socket, <<"GET">>, <<"/api/overview">>, _Headers, _Body, _Html) ->
    Config = briskd_config:current_or_empty(),
    Payload = #{
        status => ctl_json([<<"status">>]),
        clients => ctl_json([<<"clients">>]),
        channels => ctl_json([<<"channels">>]),
        links => ctl_json([<<"links">>]),
        accounts => ctl_json([<<"accounts">>]),
        search => ctl_json([<<"search">>]),
        dronebl => #{
            stats => briskd_dronebl:stats(),
            bans => briskd_dronebl:list_bans()
        },
        features => current_features(Config),
        controls => briskd_state:controls(),
        media_summary => #{
            voice_enabled => briskd_voice:enabled(),
            voice_max_bytes => briskd_voice:max_bytes(),
            voice_max_duration => briskd_voice:max_duration(),
            files_enabled => briskd_files:enabled(),
            files_max_bytes => briskd_files:max_bytes()
        }
    },
    send_json(Socket, 200, <<"OK">>, Payload);
route(Socket, <<"GET">>, <<"/api/stats">>, _Headers, _Body, _Html) ->
    try briskd_stats:history() of
        #{interval_ms := Interval, samples := Samples} ->
            send_json(Socket, 200, <<"OK">>, #{
                interval_ms => Interval, metrics => columns(Samples)
            })
    catch
        exit:_ ->
            send_json(Socket, 503, <<"Service Unavailable">>, #{error => <<"stats_unavailable">>})
    end;
route(Socket, <<"GET">>, <<"/api/media">>, _Headers, _Body, _Html) ->
    Config = briskd_config:current_or_empty(),
    send_json(Socket, 200, <<"OK">>, #{
        features => current_features(Config),
        controls => briskd_state:controls(),
        voice => briskd_voice:list(),
        files => briskd_files:list()
    });
route(Socket, <<"POST">>, <<"/api/action">>, Headers, Body, _Html) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            handle_action(Socket, Body);
        _ ->
            send_json(Socket, 403, <<"Forbidden">>, #{error => <<"missing_csrf_header">>})
    end;
route(Socket, Method, _Path, _Headers, _Body, _Html) when
    Method =:= <<"GET">>; Method =:= <<"POST">>
->
    send_json(Socket, 404, <<"Not Found">>, #{error => <<"not_found">>});
route(Socket, _Method, _Path, _Headers, _Body, _Html) ->
    send_json(Socket, 405, <<"Method Not Allowed">>, #{error => <<"method_not_allowed">>}).

handle_action(Socket, Body) ->
    try json:decode(Body) of
        #{<<"action">> := Action} = Req when is_binary(Action) ->
            Args = maps:get(<<"args">>, Req, []),
            case valid_args(Args) of
                true ->
                    dispatch_action(Socket, Action, Args);
                false ->
                    send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_args">>})
            end;
        _ ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_request">>})
    catch
        _:_ ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_json">>})
    end.

dispatch_action(Socket, <<"dronebl-unban">>, [IP]) ->
    ok = briskd_dronebl:unban(IP),
    send_json(Socket, 200, <<"OK">>, #{status => <<"unbanned">>, ip => IP});
dispatch_action(Socket, <<"dronebl-ban">>, [IP | Rest]) ->
    Reason =
        case Rest of
            [R | _] when byte_size(R) > 0 -> R;
            _ -> <<"Manual admin ban">>
        end,
    case briskd_dronebl:ban(IP, 255, Reason) of
        ok ->
            send_json(Socket, 200, <<"OK">>, #{status => <<"banned">>, ip => IP});
        {error, invalid_ip} ->
            send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_ip">>, ip => IP
            })
    end;
%% A chat feature switch (the older form of set-control).
dispatch_action(Socket, <<"toggle-feature">>, [KeyBin, ValBin]) ->
    case parse_feature_toggle(KeyBin, ValBin) of
        {ok, Key, Bool} ->
            Control = <<"features.", (atom_to_binary(Key))/binary>>,
            Text = atom_to_binary(Bool),
            case briskd_state:set_control(Control, Text) of
                {ok, _} ->
                    send_json(Socket, 200, <<"OK">>, #{
                        status => <<"updated">>,
                        features => current_features(briskd_config:current())
                    });
                {error, Reason} ->
                    control_error(Socket, Reason)
            end;
        error ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_feature">>})
    end;
%% Admin overrides of server features (briskd_overrides): set one, or go back
%% to the configuration file's value. Applied live, kept across REHASH and
%% restarts.
dispatch_action(Socket, <<"set-control">>, [Key, Value]) ->
    case briskd_state:set_control(Key, Value) of
        {ok, Controls} ->
            send_json(Socket, 200, <<"OK">>, #{status => <<"updated">>, controls => Controls});
        {error, Reason} ->
            control_error(Socket, Reason)
    end;
dispatch_action(Socket, <<"reset-control">>, [Key]) ->
    case briskd_state:reset_control(Key) of
        {ok, Controls} ->
            send_json(Socket, 200, <<"OK">>, #{status => <<"reset">>, controls => Controls});
        {error, Reason} ->
            control_error(Socket, Reason)
    end;
dispatch_action(Socket, <<"delete-voice">>, [VoiceId]) ->
    case briskd_voice:delete(VoiceId) of
        ok ->
            logger:notice(#{event => admin_voice_deleted, id => VoiceId}),
            send_json(Socket, 200, <<"OK">>, #{status => <<"deleted">>, id => VoiceId});
        {error, invalid_id} ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_voice_id">>});
        {error, disabled} ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"voice_disabled">>});
        {error, _} ->
            send_json(Socket, 502, <<"Bad Gateway">>, #{error => <<"storage_error">>})
    end;
dispatch_action(Socket, <<"delete-file">>, [FileId]) ->
    case briskd_files:delete(FileId) of
        ok ->
            logger:notice(#{event => admin_file_deleted, id => FileId}),
            send_json(Socket, 200, <<"OK">>, #{status => <<"deleted">>, id => FileId});
        {error, invalid_id} ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_file_id">>});
        {error, disabled} ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"files_disabled">>});
        {error, _} ->
            send_json(Socket, 502, <<"Bad Gateway">>, #{error => <<"storage_error">>})
    end;
dispatch_action(Socket, <<"clear-upload-limits">>, []) ->
    case ets:whereis(briskd_webui_uploads) of
        undefined -> ok;
        Tab -> ets:delete_all_objects(Tab)
    end,
    send_json(Socket, 200, <<"OK">>, #{status => <<"cleared">>});
dispatch_action(Socket, Action, Args) ->
    case allowed_action(Action) of
        true ->
            case briskd_ctl:run([Action | Args] ++ [<<"--json">>]) of
                {ok, JsonBin} ->
                    send_response(
                        Socket, 200, <<"OK">>, <<"application/json; charset=utf-8">>, [], JsonBin
                    );
                {error, JsonBin} ->
                    send_response(
                        Socket,
                        400,
                        <<"Bad Request">>,
                        <<"application/json; charset=utf-8">>,
                        [],
                        JsonBin
                    )
            end;
        false ->
            send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"unsupported_action">>, action => Action
            })
    end.

allowed_action(<<"rehash">>) -> true;
allowed_action(<<"check-config">>) -> true;
allowed_action(<<"reload-certs">>) -> true;
allowed_action(<<"search-rebuild">>) -> true;
allowed_action(<<"log-level">>) -> true;
allowed_action(<<"kick-client">>) -> true;
allowed_action(<<"notice-all">>) -> true;
allowed_action(<<"notice-channel">>) -> true;
allowed_action(<<"set-topic">>) -> true;
allowed_action(<<"connect">>) -> true;
allowed_action(<<"squit">>) -> true;
allowed_action(<<"create-account">>) -> true;
allowed_action(<<"verify-account">>) -> true;
allowed_action(<<"reset-password">>) -> true;
allowed_action(<<"delete-account">>) -> true;
allowed_action(<<"set-email">>) -> true;
allowed_action(<<"add-certfp">>) -> true;
allowed_action(<<"remove-certfp">>) -> true;
allowed_action(<<"create-channel">>) -> true;
allowed_action(<<"delete-channel">>) -> true;
allowed_action(<<"set-channel-modes">>) -> true;
allowed_action(<<"backup">>) -> true;
allowed_action(<<"drain">>) -> true;
allowed_action(<<"stop">>) -> true;
allowed_action(_) -> false.

control_error(Socket, Reason) when
    Reason =:= unknown_control; Reason =:= invalid_value; Reason =:= not_configured
->
    send_json(Socket, 400, <<"Bad Request">>, #{error => atom_to_binary(Reason)}).

current_features(Config) ->
    F = maps:get(features, Config, #{}),
    #{
        reactions => maps:get(reactions, F, true),
        replies => maps:get(replies, F, true),
        typing => maps:get(typing, F, true),
        editing => maps:get(editing, F, true),
        redaction => maps:get(redaction, F, true),
        link_previews => maps:get(link_previews, F, true)
    }.

parse_feature_toggle(KeyBin, ValBin) ->
    Key =
        case KeyBin of
            <<"reactions">> -> reactions;
            <<"replies">> -> replies;
            <<"typing">> -> typing;
            <<"editing">> -> editing;
            <<"redaction">> -> redaction;
            <<"link_previews">> -> link_previews;
            _ -> invalid
        end,
    Val =
        case ValBin of
            <<"true">> -> true;
            <<"false">> -> false;
            _ -> invalid
        end,
    case Key =/= invalid andalso Val =/= invalid of
        true -> {ok, Key, Val};
        false -> error
    end.

valid_args(Args) when is_list(Args), length(Args) =< 4 ->
    lists:all(
        fun(A) ->
            is_binary(A) andalso byte_size(A) =< 512 andalso
                binary:match(A, [<<0>>, <<"\r">>, <<"\n">>]) =:= nomatch
        end,
        Args
    );
valid_args(_) ->
    false.

%% Samples as one array per metric (oldest first), about half the size of
%% an array of objects and the shape the charts read.
columns([]) ->
    #{};
columns([First | _] = Samples) ->
    maps:from_list([
        {Key, [maps:get(Key, S, null) || S <- Samples]}
     || Key <- maps:keys(First)
    ]).

ctl_json(Args) ->
    case briskd_ctl:run(Args ++ [<<"--json">>]) of
        {ok, Bin} -> decode_safe(Bin);
        {error, Bin} -> decode_safe(Bin)
    end.

decode_safe(Bin) ->
    try
        json:decode(Bin)
    catch
        _:_ -> #{error => <<"decode_failed">>}
    end.

%%% Minimal HTTP/1.1 request reader & response writer

read_request(Socket) ->
    read_headers(Socket, <<>>).

read_headers(Socket, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [HeaderBlock, Rest] ->
            parse_headers(Socket, HeaderBlock, Rest);
        [_] when byte_size(Buf) >= ?MAX_REQUEST_BYTES ->
            {error, payload_too_large};
        [_] ->
            case gen_tcp:recv(Socket, 0, ?IO_TIMEOUT_MS) of
                {ok, Chunk} when
                    is_binary(Chunk), byte_size(Buf) + byte_size(Chunk) =< ?MAX_REQUEST_BYTES
                ->
                    read_headers(Socket, <<Buf/binary, Chunk/binary>>);
                {ok, _} ->
                    {error, payload_too_large};
                {error, Reason} when Buf =:= <<>> ->
                    %% Nothing was sent: a browser's preconnected socket that
                    %% stayed idle, or one it closed. Answering 400 here would
                    %% be read as the reply to the request the browser sends
                    %% next on that socket (RFC 9112 section 9.5: close idle
                    %% connections without a response).
                    {error, {idle, Reason}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

parse_headers(Socket, HeaderBlock, Rest) ->
    case binary:split(HeaderBlock, <<"\r\n">>, [global]) of
        [ReqLine | HeaderLines] ->
            case binary:split(ReqLine, <<" ">>, [global]) of
                [Method, RawPath, <<"HTTP/1.", _>>] ->
                    Path = split_path(RawPath),
                    Headers = parse_header_lines(HeaderLines, #{}),
                    read_body(Socket, Method, Path, Headers, Rest);
                _ ->
                    {error, malformed_request_line}
            end;
        _ ->
            {error, malformed_request}
    end.

parse_header_lines([], Acc) ->
    Acc;
parse_header_lines([Line | Rest], Acc) ->
    case binary:split(Line, <<":">>) of
        [Key, Val] ->
            Lower = briskd_wire:lower(briskd_websocket:trim_ows(Key)),
            parse_header_lines(Rest, Acc#{Lower => briskd_websocket:trim_ows(Val)});
        _ ->
            parse_header_lines(Rest, Acc)
    end.

read_body(Socket, Method, Path, Headers, Rest) ->
    MaxBytes = max_body_bytes(Method, Path),
    case maps:get(<<"content-length">>, Headers, undefined) of
        undefined ->
            {ok, Method, Path, Headers, <<>>};
        LenBin ->
            try binary_to_integer(LenBin) of
                Len when Len < 0 ->
                    {error, invalid_content_length};
                Len when Len > MaxBytes ->
                    {error, payload_too_large};
                Len ->
                    Deadline = erlang:monotonic_time(millisecond) + body_time_ms(Len),
                    read_exact(Socket, Len, Rest, Method, Path, Headers, Deadline)
            catch
                _:_ -> {error, invalid_content_length}
            end
    end.

max_body_bytes(<<"POST">>, {<<"/api/voice">>, _}) ->
    briskd_voice:max_bytes();
max_body_bytes(<<"POST">>, {<<"/api/files">>, _}) ->
    briskd_files:max_bytes();
max_body_bytes(_, _) ->
    ?MAX_REQUEST_BYTES.

%% Time allowed for a whole request body: 30 s plus a second per 32 KiB, so
%% a 5 MiB photo from a phone on a slow uplink (about 0.3 Mbit/s) still
%% arrives, while a stalled sender is cut off by the per-read timeout.
body_time_ms(Len) ->
    30000 + (Len div 32768) * 1000.

%% Read the body as it arrives. Each read waits up to ?IO_TIMEOUT_MS for more
%% bytes (a stalled sender), and the whole body must arrive by Deadline. A
%% single recv for all remaining bytes would give a large upload only
%% ?IO_TIMEOUT_MS in total, which a mobile connection does not meet.
read_exact(_Socket, Len, Buf, Method, Path, Headers, _Deadline) when byte_size(Buf) >= Len ->
    {ok, Method, Path, Headers, binary:part(Buf, 0, Len)};
read_exact(Socket, Len, Buf, Method, Path, Headers, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case Left > 0 andalso gen_tcp:recv(Socket, 0, min(Left, ?IO_TIMEOUT_MS)) of
        {ok, Chunk} when is_binary(Chunk) ->
            read_exact(
                Socket, Len, <<Buf/binary, Chunk/binary>>, Method, Path, Headers, Deadline
            );
        {error, Reason} ->
            {error, Reason};
        false ->
            {error, timeout}
    end.

split_path(RawPath) ->
    case binary:split(RawPath, <<"?">>) of
        [Path, Query] -> {Path, Query};
        [Path] -> {Path, <<>>}
    end.

send_json(Socket, Code, Reason, Map) ->
    Body = iolist_to_binary(json:encode(Map)),
    send_response(Socket, Code, Reason, <<"application/json; charset=utf-8">>, [], Body).

send_response(Socket, Code, Reason, ContentType, ExtraHeaders, Body) ->
    Bin = iolist_to_binary(Body),
    CacheHeader =
        case lists:keymember(<<"Cache-Control">>, 1, ExtraHeaders) of
            true -> [];
            false -> [<<"Cache-Control: no-store\r\n">>]
        end,
    CspHeader =
        case lists:keymember(<<"Content-Security-Policy">>, 1, ExtraHeaders) of
            true -> [];
            false -> [<<"Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n">>]
        end,
    %% RFC 9110 section 8.6: no Content-Length (and no content) on a 204.
    BodyHeaders =
        case Code of
            204 ->
                [];
            _ ->
                [
                    [<<"Content-Type: ">>, ContentType, <<"\r\n">>],
                    [<<"Content-Length: ">>, integer_to_binary(byte_size(Bin)), <<"\r\n">>]
                ]
        end,
    Headers = [
        [<<"HTTP/1.1 ">>, integer_to_binary(Code), <<" ">>, Reason, <<"\r\n">>],
        BodyHeaders,
        <<"Connection: close\r\n">>,
        CacheHeader,
        <<"X-Content-Type-Options: nosniff\r\n">>,
        <<"X-Frame-Options: DENY\r\n">>,
        <<"Referrer-Policy: no-referrer\r\n">>,
        CspHeader
        | [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- ExtraHeaders]
    ],
    _ = gen_tcp:send(Socket, [Headers, <<"\r\n">>, Bin]),
    ok.

send_nonce_html(Socket, Html, ExtraCsp) ->
    Nonce = base64:encode(crypto:strong_rand_bytes(16)),
    Body = binary:replace(Html, <<"__CSP_NONCE__">>, Nonce, [global]),
    Csp = <<
        "default-src 'self'; ",
        ExtraCsp/binary,
        "style-src 'self'; script-src 'self' 'nonce-",
        Nonce/binary,
        "'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
    >>,
    send_response(
        Socket,
        200,
        <<"OK">>,
        <<"text/html; charset=utf-8">>,
        [{<<"Content-Security-Policy">>, Csp}],
        Body
    ).

%% Every script and stylesheet the build wrote to priv/webui/assets: the app
%% entry (app.js), its lazily loaded chunks (content-hashed names), and the
%% page stylesheets. Names are restricted to a safe character set.
load_static_assets() ->
    case first_dir([asset_dir(Base) || Base <- webui_dirs()]) of
        {ok, Dir} ->
            {ok, Names} = file:list_dir(Dir),
            lists:foldl(
                fun(Name, Acc) ->
                    Bin = unicode:characters_to_binary(Name),
                    case {static_mime(Bin), file:read_file(filename:join(Dir, Name))} of
                        {undefined, _} -> Acc;
                        {Mime, {ok, Body}} -> Acc#{Bin => {Mime, Body}};
                        {_, {error, _}} -> Acc
                    end
                end,
                #{},
                Names
            );
        error ->
            #{}
    end.

webui_dirs() ->
    Priv =
        case code:priv_dir(briskd) of
            {error, _} -> [];
            Dir -> [filename:join(Dir, "webui")]
        end,
    Priv ++ [filename:join("priv", "webui")].

asset_dir(Base) -> filename:join(Base, "assets").

first_dir([Dir | Rest]) ->
    case filelib:is_dir(Dir) of
        true -> {ok, Dir};
        false -> first_dir(Rest)
    end;
first_dir([]) ->
    error.

static_mime(Name) ->
    case re:run(Name, <<"^[A-Za-z0-9_-][A-Za-z0-9._-]*\\.(js|css)$">>, [{capture, [1], binary}]) of
        {match, [<<"js">>]} -> <<"text/javascript; charset=utf-8">>;
        {match, [<<"css">>]} -> <<"text/css; charset=utf-8">>;
        nomatch -> undefined
    end.

read_asset_file(Rel) ->
    Candidates = [
        case code:priv_dir(briskd) of
            {error, _} -> filename:join(["priv", "webui", Rel]);
            Dir -> filename:join([Dir, "webui", Rel])
        end,
        filename:join(["priv", "webui", Rel])
    ],
    read_file_first(Candidates).

read_file_first([Path | Rest]) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> read_file_first(Rest)
    end;
read_file_first([]) ->
    error.

load_raw_asset(File, Fallback) ->
    case read_asset_file(File) of
        {ok, Bin} -> Bin;
        error -> Fallback
    end.

load_asset(File, Fallback) ->
    Candidates = [
        case code:priv_dir(briskd) of
            {error, _} -> filename:join(["priv", "webui", File]);
            Dir -> filename:join([Dir, "webui", File])
        end,
        filename:join(["priv", "webui", File])
    ],
    read_first(Candidates, Fallback).

read_first([Path | Rest], Fallback) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, _} -> read_first(Rest, Fallback)
    end;
read_first([], Fallback) ->
    <<"<!doctype html><title>briskd</title><h1>", Fallback/binary, "</h1>">>.
