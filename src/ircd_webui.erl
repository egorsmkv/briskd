-module(ircd_webui).
-moduledoc """
Simple HTTP administration WebUI and JSON API for `ircd`.

Opt-in via the `"webui"` configuration object (`bind`, `port`, `username`,
`password`). When enabled, `ircd_webui` opens a TCP listener (default
`127.0.0.1`) serving a self-contained single-page dashboard from
`priv/webui/index.html` and two JSON endpoints:

- `GET /` (and `GET /webirc`) — public (unauthenticated) browser IRC client
  over the configured `ws` / `wss` IRCv3 WebSocket listener.
- `GET /admin` — serves the HTML administration dashboard (HTTP Basic auth).
- `GET /api/overview` — returns combined server stats, clients, channels,
  server links, accounts, and DroneBL status/bans as JSON (HTTP Basic auth).
- `POST /api/action` — executes an explicitly whitelisted `m:ircd_ctl`
  management action (`rehash`, `check-config`, `reload-certs`, `log-level`,
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

- Every route requires HTTP Basic authentication verified in constant time
  with `ircd_config:secret_match/2`. Credentials are read from the active
  configuration so `REHASH` updates them live.
- `POST /api/action` requires the `X-Requested-With: ircd-webui` header to
  prevent cross-origin CSRF.
- Each connection handles a single HTTP/1.1 request (`Connection: close`) with
  a 16 KiB size cap, a 5-second timeout, and at most 16 concurrent handlers.
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
Start the admin WebUI HTTP server, registered as `ircd_webui`.
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
            ok = ircd_altcha:init(),
            Assets = #{
                index => load_asset("index.html", <<"ircd admin UI asset missing">>),
                signup => load_asset("signup.html", <<"ircd signup UI asset missing">>),
                verify => load_asset("verify.html", <<"ircd verify UI asset missing">>),
                recover => load_asset("recover.html", <<"ircd recover UI asset missing">>),
                webirc => load_asset("webirc.html", <<"ircd webirc UI asset missing">>),
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
                ip => list_to_binary(inet:ntoa(IP)),
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
        index := IndexHtml,
        signup := SignupHtml,
        verify := VerifyHtml,
        recover := RecoverHtml,
        webirc := WebircHtml,
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
            send_json(Socket, 200, <<"OK">>, ircd_altcha:create_challenge());
        {ok, <<"POST">>, {<<"/api/webirc/verify">>, _Query}, Headers, Body} ->
            handle_webirc_verify_api(Socket, Headers, Body);
        {ok, <<"GET">>, {Path, _Query}, Headers, _Body} when
            Path =:= <<"/">>;
            Path =:= <<"/webirc">>;
            Path =:= <<"/status">>;
            binary_part(Path, 0, min(byte_size(Path), 9)) =:= <<"/channel/">>;
            binary_part(Path, 0, min(byte_size(Path), 4)) =:= <<"/dm/">>
        ->
            handle_webirc_page(Socket, WebircHtml, Path, Headers);
        {ok, <<"GET">>, {<<"/verify">>, Query}, _Headers, _Body} ->
            handle_verify_page(Socket, VerifyHtml, Query);
        {ok, <<"POST">>, {<<"/api/verify">>, _Query}, Headers, Body} ->
            handle_verify_api(Socket, Headers, Body);
        {ok, <<"GET">>, {<<"/signup">>, _Query}, _Headers, _Body} ->
            handle_signup_page(Socket, SignupHtml);
        {ok, <<"POST">>, {<<"/api/signup">>, _Query}, Headers, Body} ->
            handle_signup_api(Socket, Headers, Body);
        {ok, <<"GET">>, {<<"/recover">>, Query}, _Headers, _Body} ->
            handle_recover_page(Socket, RecoverHtml, Query);
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
        {ok, Method, {Path, _Query}, Headers, Body} ->
            case check_auth(Headers) of
                ok ->
                    route(Socket, Method, Path, Headers, Body, IndexHtml);
                unauthorized ->
                    send_response(
                        Socket,
                        401,
                        <<"Unauthorized">>,
                        <<"application/json; charset=utf-8">>,
                        [{<<"WWW-Authenticate">>, <<"Basic realm=\"ircd admin\"">>}],
                        <<"{\"error\":\"unauthorized\"}">>
                    )
            end;
        {error, payload_too_large} ->
            send_json(Socket, 413, <<"Payload Too Large">>, #{error => <<"payload_too_large">>});
        {error, _} ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"bad_request">>})
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

handle_webirc_page(Socket, WebircHtml, Path, Headers) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    WsPort = maps:get(ws, Config, null),
    WssPort = maps:get(wss, Config, null),
    case WsPort =:= null andalso WssPort =:= null of
        true ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"webirc_disabled">>});
        false ->
            Network = escape_html(maps:get(network, Config, maps:get(name, Config, <<"IRC">>))),
            WsBin = port_to_bin(WsPort),
            WssBin = port_to_bin(WssPort),
            DefaultChans = escape_html(default_channels(Config)),
            Origin = public_origin(Headers, Config),
            PublicUrl = escape_html(<<Origin/binary, Path/binary>>),
            OgImageUrl = escape_html(<<Origin/binary, "/og-image.png">>),
            P0 = binary:replace(WebircHtml, <<"__NETWORK_NAME__">>, Network, [global]),
            P1 = binary:replace(P0, <<"__WS_PORT__">>, WsBin, [global]),
            P2 = binary:replace(P1, <<"__WSS_PORT__">>, WssBin, [global]),
            P3 = binary:replace(P2, <<"__DEFAULT_CHANNELS__">>, DefaultChans, [global]),
            P4 = binary:replace(P3, <<"__PUBLIC_URL__">>, PublicUrl, [global]),
            Page = binary:replace(P4, <<"__OG_IMAGE_URL__">>, OgImageUrl, [global]),
            send_nonce_html(
                Socket,
                Page,
                <<"connect-src 'self' ws: wss:; img-src 'self' data: blob:; media-src 'self' blob:; ">>
            )
    end.

public_origin(Headers, Config) ->
    Proto =
        case string:lowercase(maps:get(<<"x-forwarded-proto">>, Headers, <<"http">>)) of
            <<"https">> -> <<"https">>;
            _ -> <<"http">>
        end,
    RawHost = maps:get(<<"host">>, Headers, maps:get(name, Config, <<"localhost">>)),
    Host = sanitize_host(RawHost, maps:get(name, Config, <<"localhost">>)),
    <<Proto/binary, "://", Host/binary>>.

sanitize_host(Bin, Fallback) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 255 ->
    case
        lists:all(
            fun(C) ->
                (C >= $a andalso C =< $z) orelse
                    (C >= $A andalso C =< $Z) orelse
                    (C >= $0 andalso C =< $9) orelse
                    C =:= $. orelse C =:= $- orelse C =:= $: orelse C =:= $[ orelse C =:= $]
            end,
            binary_to_list(Bin)
        )
    of
        true -> Bin;
        false -> Fallback
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
                _ -> iolist_to_binary(lists:join(<<",">>, Names))
            end
    end.

handle_webirc_verify_api(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"ircd-webui">> ->
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

handle_recover_page(Socket, RecoverHtml, Query) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(account_verification, Config, null) of
        #{smtp := _} ->
            {_, Email, Code} = prefill_verify_query(Query),
            P1 = binary:replace(RecoverHtml, <<"__EMAIL_PREFILL__">>, escape_html(Email), [global]),
            Page = binary:replace(P1, <<"__CODE_PREFILL__">>, escape_html(Code), [global]),
            send_nonce_html(Socket, Page);
        _ ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"recovery_disabled">>})
    end.

handle_recover_request_api(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"ircd-webui">> ->
            try json:decode(Body) of
                #{<<"email">> := Email} = Req when is_binary(Email), byte_size(Email) > 0 ->
                    case require_altcha(Req) of
                        ok ->
                            Config = persistent_term:get({ircd_state, config}, #{}),
                            Origin = public_origin(Headers, Config),
                            RecoveryUrl = <<Origin/binary, "/recover">>,
                            PeerIP = peer_ip(Socket),
                            case ircd_state:request_password_reset(Email, RecoveryUrl, PeerIP) of
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
        <<"ircd-webui">> ->
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
                                ircd_state:complete_password_reset(Email, Code, Password, PeerIP)
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

handle_signup_page(Socket, SignupHtml) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(account_registration, Config, true) of
        true ->
            WebCfg =
                case maps:get(webui, Config, null) of
                    M when is_map(M) -> M;
                    _ -> #{}
                end,
            Terms = escape_html(maps:get(terms_url, WebCfg, <<"https://example.com/terms">>)),
            Privacy = escape_html(maps:get(privacy_url, WebCfg, <<"https://example.com/privacy">>)),
            Page0 = binary:replace(SignupHtml, <<"__TERMS_URL__">>, Terms, [global]),
            Page = binary:replace(Page0, <<"__PRIVACY_URL__">>, Privacy, [global]),
            send_nonce_html(Socket, Page);
        false ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"registration_disabled">>})
    end.

handle_signup_api(Socket, Headers, Body) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"ircd-webui">> ->
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
            case ircd_state:signup_account(Account, Email, Password, PeerIP) of
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
        <<"ircd-webui">> ->
            case check_upload_rate(peer_ip(Socket)) of
                ok ->
                    Duration = parse_voice_duration(
                        maps:get(<<"x-voice-duration">>, Headers, undefined)
                    ),
                    case ircd_voice:store(Body, Duration) of
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
                            ircd_log:warning(voice_upload_failed, #{reason => Reason}),
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
    case ircd_voice:fetch(VoiceId) of
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
            ircd_log:warning(voice_download_failed, #{id => VoiceId, reason => Reason}),
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
        <<"ircd-webui">> ->
            case check_upload_rate(peer_ip(Socket)) of
                ok ->
                    RawName = decode_header_filename(
                        maps:get(<<"x-file-name">>, Headers, undefined)
                    ),
                    case ircd_files:store(Body, RawName) of
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
                            ircd_log:warning(file_upload_failed, #{reason => Reason}),
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
    case ets:whereis(ircd_webui_uploads) of
        undefined ->
            try
                ets:new(ircd_webui_uploads, [named_table, public, set])
            catch
                error:badarg -> ircd_webui_uploads
            end;
        Tab ->
            Tab
    end.

handle_file_download(Socket, FileId) ->
    case ircd_files:fetch(FileId) of
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
            ircd_log:warning(file_download_failed, #{id => FileId, reason => Reason}),
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
        <<"ircd-webui">> ->
            Url = extract_query_param(<<"url">>, Query),
            case Url of
                <<>> ->
                    send_json(Socket, 400, <<"Bad Request">>, #{error => <<"missing_url">>});
                _ ->
                    case ircd_link_preview:fetch(Url) of
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
                            send_json(Socket, 404, <<"Not Found">>, #{error => <<"no_preview">>})
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
        {ok, {Addr, _}} -> list_to_binary(inet:ntoa(Addr));
        _ -> <<"unknown">>
    end.

require_altcha(Req) ->
    case maps:get(<<"altcha">>, Req, undefined) of
        Payload when is_binary(Payload), byte_size(Payload) > 0 ->
            case ircd_altcha:verify_payload(Payload) of
                ok ->
                    ok;
                {error, expired} ->
                    {error, <<"altcha_expired">>,
                        <<"ALTCHA challenge expired. Please verify again.">>};
                {error, replayed} ->
                    {error, <<"altcha_replayed">>,
                        <<"ALTCHA challenge already used. Please verify again.">>};
                {error, invalid} ->
                    {error, <<"altcha_invalid">>, <<"Invalid ALTCHA verification.">>}
            end;
        _ ->
            {error, <<"altcha_required">>, <<"Please complete the ALTCHA verification.">>}
    end.

handle_verify_page(Socket, VerifyHtml, Query) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(account_verification, Config, null) of
        null ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"verification_disabled">>});
        _ ->
            {Email, Account, Code} = prefill_verify_query(Query),
            Page0 = binary:replace(VerifyHtml, <<"__EMAIL_PREFILL__">>, escape_html(Email), [
                global
            ]),
            Page1 = binary:replace(Page0, <<"__ACCOUNT_PREFILL__">>, escape_html(Account), [
                global
            ]),
            Page = binary:replace(Page1, <<"__CODE_PREFILL__">>, escape_html(Code), [global]),
            send_nonce_html(Socket, Page)
    end.

handle_verify_api(Socket, Headers, Body) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(account_verification, Config, null) of
        null ->
            send_json(Socket, 404, <<"Not Found">>, #{
                error => <<"verification_disabled">>,
                message => <<"Account verification is disabled.">>
            });
        _ ->
            case maps:get(<<"x-requested-with">>, Headers, undefined) of
                <<"ircd-webui">> ->
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
                ircd_state:verify_account_by_email(Email, Code);
            _ ->
                case maps:get(<<"account">>, Req, undefined) of
                    Account when is_binary(Account), byte_size(Account) > 0 ->
                        ircd_state:verify_account(Account, Code);
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

prefill_verify_query(<<>>) ->
    {<<>>, <<>>, <<>>};
prefill_verify_query(Query) ->
    try uri_string:dissect_query(Query) of
        Pairs when is_list(Pairs) ->
            {
                query_bin(<<"email">>, Pairs),
                query_bin(<<"account">>, Pairs),
                query_bin(<<"code">>, Pairs)
            };
        _ ->
            {<<>>, <<>>, <<>>}
    catch
        _:_ -> {<<>>, <<>>, <<>>}
    end.

query_bin(Key, Pairs) ->
    case lists:keyfind(Key, 1, Pairs) of
        {_, Val} when is_binary(Val), byte_size(Val) =< 254 -> Val;
        _ -> <<>>
    end.

escape_html(Bin) ->
    B1 = binary:replace(Bin, <<"&">>, <<"&amp;">>, [global]),
    B2 = binary:replace(B1, <<"<">>, <<"&lt;">>, [global]),
    B3 = binary:replace(B2, <<">">>, <<"&gt;">>, [global]),
    B4 = binary:replace(B3, <<"\"">>, <<"&quot;">>, [global]),
    binary:replace(B4, <<"'">>, <<"&#39;">>, [global]).

route(Socket, <<"GET">>, Path, _Headers, _Body, Html) when
    Path =:= <<"/admin">>;
    Path =:= <<"/admin/">>;
    Path =:= <<"/admin/overview">>;
    Path =:= <<"/admin/clients">>;
    Path =:= <<"/admin/channels">>;
    Path =:= <<"/admin/links">>;
    Path =:= <<"/admin/accounts">>;
    Path =:= <<"/admin/dronebl">>;
    Path =:= <<"/admin/media">>;
    Path =:= <<"/admin/operations">>
->
    send_nonce_html(Socket, Html);
route(Socket, <<"GET">>, <<"/api/overview">>, _Headers, _Body, _Html) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    Payload = #{
        status => ctl_json([<<"status">>]),
        clients => ctl_json([<<"clients">>]),
        channels => ctl_json([<<"channels">>]),
        links => ctl_json([<<"links">>]),
        accounts => ctl_json([<<"accounts">>]),
        dronebl => #{
            stats => ircd_dronebl:stats(),
            bans => ircd_dronebl:list_bans()
        },
        features => current_features(Config),
        media_summary => #{
            voice_enabled => ircd_voice:enabled(),
            voice_max_bytes => ircd_voice:max_bytes(),
            voice_max_duration => ircd_voice:max_duration(),
            files_enabled => ircd_files:enabled(),
            files_max_bytes => ircd_files:max_bytes()
        }
    },
    send_json(Socket, 200, <<"OK">>, Payload);
route(Socket, <<"GET">>, <<"/api/media">>, _Headers, _Body, _Html) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    send_json(Socket, 200, <<"OK">>, #{
        features => current_features(Config),
        voice => ircd_voice:list(),
        files => ircd_files:list()
    });
route(Socket, <<"POST">>, <<"/api/action">>, Headers, Body, _Html) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"ircd-webui">> ->
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
    ok = ircd_dronebl:unban(IP),
    send_json(Socket, 200, <<"OK">>, #{status => <<"unbanned">>, ip => IP});
dispatch_action(Socket, <<"dronebl-ban">>, [IP | Rest]) ->
    Reason =
        case Rest of
            [R | _] when byte_size(R) > 0 -> R;
            _ -> <<"Manual admin ban">>
        end,
    case ircd_dronebl:ban(IP, 255, Reason) of
        ok ->
            send_json(Socket, 200, <<"OK">>, #{status => <<"banned">>, ip => IP});
        {error, invalid_ip} ->
            send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_ip">>, ip => IP
            })
    end;
dispatch_action(Socket, <<"toggle-feature">>, [KeyBin, ValBin]) ->
    case parse_feature_toggle(KeyBin, ValBin) of
        {ok, Key, Bool} ->
            Config = persistent_term:get({ircd_state, config}, #{}),
            Updated = (current_features(Config))#{Key => Bool},
            persistent_term:put({ircd_state, config}, Config#{features => Updated}),
            ircd_log:notice(admin_feature_toggled, #{feature => Key, enabled => Bool}),
            send_json(Socket, 200, <<"OK">>, #{status => <<"updated">>, features => Updated});
        error ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_feature">>})
    end;
dispatch_action(Socket, <<"delete-voice">>, [VoiceId]) ->
    case ircd_voice:delete(VoiceId) of
        ok ->
            ircd_log:notice(admin_voice_deleted, #{id => VoiceId}),
            send_json(Socket, 200, <<"OK">>, #{status => <<"deleted">>, id => VoiceId});
        {error, invalid_id} ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_voice_id">>});
        {error, disabled} ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"voice_disabled">>});
        {error, _} ->
            send_json(Socket, 502, <<"Bad Gateway">>, #{error => <<"storage_error">>})
    end;
dispatch_action(Socket, <<"delete-file">>, [FileId]) ->
    case ircd_files:delete(FileId) of
        ok ->
            ircd_log:notice(admin_file_deleted, #{id => FileId}),
            send_json(Socket, 200, <<"OK">>, #{status => <<"deleted">>, id => FileId});
        {error, invalid_id} ->
            send_json(Socket, 400, <<"Bad Request">>, #{error => <<"invalid_file_id">>});
        {error, disabled} ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"files_disabled">>});
        {error, _} ->
            send_json(Socket, 502, <<"Bad Gateway">>, #{error => <<"storage_error">>})
    end;
dispatch_action(Socket, <<"clear-upload-limits">>, []) ->
    case ets:whereis(ircd_webui_uploads) of
        undefined -> ok;
        Tab -> ets:delete_all_objects(Tab)
    end,
    send_json(Socket, 200, <<"OK">>, #{status => <<"cleared">>});
dispatch_action(Socket, Action, Args) ->
    case allowed_action(Action) of
        true ->
            case ircd_ctl:run([Action | Args] ++ [<<"--json">>]) of
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
allowed_action(<<"backup">>) -> true;
allowed_action(<<"drain">>) -> true;
allowed_action(<<"stop">>) -> true;
allowed_action(_) -> false.

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

ctl_json(Args) ->
    case ircd_ctl:run(Args ++ [<<"--json">>]) of
        {ok, Bin} -> decode_safe(Bin);
        {error, Bin} -> decode_safe(Bin)
    end.

decode_safe(Bin) ->
    try
        json:decode(Bin)
    catch
        _:_ -> #{error => <<"decode_failed">>}
    end.

%%% Authentication

check_auth(Headers) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(webui, Config, null) of
        #{username := ExpectedUser, password := ExpectedPass} ->
            case maps:get(<<"authorization">>, Headers, undefined) of
                <<"Basic ", Encoded/binary>> ->
                    decode_basic(string:trim(Encoded), ExpectedUser, ExpectedPass);
                _ ->
                    unauthorized
            end;
        _ ->
            unauthorized
    end.

decode_basic(Encoded, ExpectedUser, ExpectedPass) ->
    try base64:decode(Encoded) of
        Decoded ->
            case binary:split(Decoded, <<":">>) of
                [User, Pass] ->
                    UserOk = ircd_config:secret_match(User, ExpectedUser),
                    PassOk = ircd_config:secret_match(Pass, ExpectedPass),
                    case UserOk andalso PassOk of
                        true -> ok;
                        false -> unauthorized
                    end;
                _ ->
                    unauthorized
            end
    catch
        _:_ -> unauthorized
    end.

%%% Minimal HTTP/1.1 request reader & response writer

read_request(Socket) ->
    read_headers(Socket, <<>>).

read_headers(Socket, Buf) ->
    case binary:match(Buf, <<"\r\n\r\n">>) of
        {Pos, 4} ->
            HeaderBlock = binary:part(Buf, 0, Pos),
            Rest = binary:part(Buf, Pos + 4, byte_size(Buf) - Pos - 4),
            parse_headers(Socket, HeaderBlock, Rest);
        nomatch when byte_size(Buf) >= ?MAX_REQUEST_BYTES ->
            {error, payload_too_large};
        nomatch ->
            case gen_tcp:recv(Socket, 0, ?IO_TIMEOUT_MS) of
                {ok, Chunk} when byte_size(Buf) + byte_size(Chunk) =< ?MAX_REQUEST_BYTES ->
                    read_headers(Socket, <<Buf/binary, Chunk/binary>>);
                {ok, _} ->
                    {error, payload_too_large};
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
            Lower = string:lowercase(string:trim(Key)),
            parse_header_lines(Rest, Acc#{Lower => string:trim(Val)});
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
                    read_exact(Socket, Len, Rest, Method, Path, Headers)
            catch
                _:_ -> {error, invalid_content_length}
            end
    end.

max_body_bytes(<<"POST">>, {<<"/api/voice">>, _}) ->
    ircd_voice:max_bytes();
max_body_bytes(<<"POST">>, {<<"/api/files">>, _}) ->
    ircd_files:max_bytes();
max_body_bytes(_, _) ->
    ?MAX_REQUEST_BYTES.

read_exact(_Socket, Len, Buf, Method, Path, Headers) when byte_size(Buf) >= Len ->
    {ok, Method, Path, Headers, binary:part(Buf, 0, Len)};
read_exact(Socket, Len, Buf, Method, Path, Headers) ->
    Remaining = Len - byte_size(Buf),
    case gen_tcp:recv(Socket, Remaining, ?IO_TIMEOUT_MS) of
        {ok, Chunk} ->
            read_exact(Socket, Len, <<Buf/binary, Chunk/binary>>, Method, Path, Headers);
        {error, Reason} ->
            {error, Reason}
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
    Headers = [
        [<<"HTTP/1.1 ">>, integer_to_binary(Code), <<" ">>, Reason, <<"\r\n">>],
        [<<"Content-Type: ">>, ContentType, <<"\r\n">>],
        [<<"Content-Length: ">>, integer_to_binary(byte_size(Bin)), <<"\r\n">>],
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

send_nonce_html(Socket, Html) ->
    send_nonce_html(Socket, Html, <<>>).

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

load_static_assets() ->
    Specs = [
        {<<"admin.js">>, <<"application/javascript; charset=utf-8">>},
        {<<"admin.css">>, <<"text/css; charset=utf-8">>},
        {<<"signup.js">>, <<"application/javascript; charset=utf-8">>},
        {<<"signup.css">>, <<"text/css; charset=utf-8">>},
        {<<"verify.js">>, <<"application/javascript; charset=utf-8">>},
        {<<"verify.css">>, <<"text/css; charset=utf-8">>},
        {<<"recover.js">>, <<"application/javascript; charset=utf-8">>},
        {<<"recover.css">>, <<"text/css; charset=utf-8">>},
        {<<"webirc.js">>, <<"application/javascript; charset=utf-8">>},
        {<<"webirc.css">>, <<"text/css; charset=utf-8">>}
    ],
    lists:foldl(
        fun({Name, Mime}, Acc) ->
            Rel = filename:join("assets", binary_to_list(Name)),
            case read_asset_file(Rel) of
                {ok, Bin} -> Acc#{Name => {Mime, Bin}};
                error -> Acc
            end
        end,
        #{},
        Specs
    ).

read_asset_file(Rel) ->
    Candidates = [
        case code:priv_dir(ircd) of
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
        case code:priv_dir(ircd) of
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
    <<"<!doctype html><title>ircd</title><h1>", Fallback/binary, "</h1>">>.
