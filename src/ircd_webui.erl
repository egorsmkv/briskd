-module(ircd_webui).
-moduledoc """
Simple HTTP administration WebUI and JSON API for `ircd`.

Opt-in via the `"webui"` configuration object (`bind`, `port`, `username`,
`password`). When enabled, `ircd_webui` opens a TCP listener (default
`127.0.0.1`) serving a self-contained single-page dashboard from
`priv/webui/index.html` and two JSON endpoints:

- `GET /` — serves the HTML administration dashboard (no external assets).
- `GET /api/overview` — returns combined server stats, clients, channels,
  server links, accounts, and DroneBL status/bans as JSON.
- `POST /api/action` — executes an explicitly whitelisted `m:ircd_ctl`
  management action (`rehash`, `reload-certs`, `log-level`, `kick-client`,
  `connect`, `squit`, `create-account`, `delete-account`, `backup`,
  `dronebl-unban`, `drain`, `stop`).
- `GET /verify?account=<name>&code=<code>` — public (unauthenticated)
  account verification landing page, active when `account_verification` is
  configured.
- `GET /signup` and `POST /api/signup` — public (unauthenticated) user
  self-registration page and JSON endpoint, active when `account_registration`
  is `true` (rate-limited per IP and protected with CSRF header + CSP nonce).

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
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

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
            Assets = #{
                index => load_asset("index.html", <<"ircd admin UI asset missing">>),
                signup => load_asset("signup.html", <<"ircd signup UI asset missing">>)
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

handle_connection(Socket, #{index := IndexHtml, signup := SignupHtml}) ->
    case read_request(Socket) of
        {ok, <<"GET">>, {<<"/verify">>, Query}, _Headers, _Body} ->
            handle_verify(Socket, Query);
        {ok, <<"GET">>, {<<"/signup">>, _Query}, _Headers, _Body} ->
            handle_signup_page(Socket, SignupHtml);
        {ok, <<"POST">>, {<<"/api/signup">>, _Query}, Headers, Body} ->
            handle_signup_api(Socket, Headers, Body);
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

handle_signup_page(Socket, SignupHtml) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(account_registration, Config, true) of
        true ->
            send_nonce_html(Socket, SignupHtml);
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
                                        message =>
                                            <<"Too many registration attempts. Try again later.">>
                                    });
                                {error, Reason} ->
                                    send_json(Socket, 400, <<"Bad Request">>, #{
                                        error => atom_to_binary(Reason),
                                        message => signup_error_message(Reason)
                                    })
                            end
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

signup_error_message(account_exists) -> <<"That account name is already taken.">>;
signup_error_message(bad_account_name) -> <<"Invalid account name.">>;
signup_error_message(weak_password) -> <<"Password is too short.">>;
signup_error_message(unacceptable_password) -> <<"Password is too long.">>;
signup_error_message(email_required) -> <<"A valid email address is required.">>;
signup_error_message(invalid_email) -> <<"Invalid email address.">>;
signup_error_message(account_limit_reached) -> <<"Server account limit reached.">>;
signup_error_message(_) -> <<"Could not create account.">>.

peer_ip(Socket) ->
    case inet:peername(Socket) of
        {ok, {Addr, _}} -> list_to_binary(inet:ntoa(Addr));
        _ -> <<"unknown">>
    end.

handle_verify(Socket, <<>>) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(account_verification, Config, null) of
        null ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"verification_disabled">>});
        _ ->
            send_response(
                Socket,
                200,
                <<"OK">>,
                <<"text/html; charset=utf-8">>,
                [{<<"Content-Security-Policy">>, verify_csp()}],
                verify_form_page(<<>>)
            )
    end;
handle_verify(Socket, Query) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(account_verification, Config, null) of
        null ->
            send_json(Socket, 404, <<"Not Found">>, #{error => <<"verification_disabled">>});
        _ ->
            case parse_verify_query(Query) of
                {ok, Account, Code} ->
                    case ircd_state:verify_account(Account, Code) of
                        {ok, VerifiedName} ->
                            Page = verify_page(
                                <<"Account verified">>,
                                <<"Your IRC account '", (escape_html(VerifiedName))/binary,
                                    "' has been verified. You can now log in via SASL.">>,
                                true
                            ),
                            send_response(
                                Socket,
                                200,
                                <<"OK">>,
                                <<"text/html; charset=utf-8">>,
                                [{<<"Content-Security-Policy">>, verify_csp()}],
                                Page
                            );
                        error ->
                            Page = verify_page(
                                <<"Verification failed">>,
                                <<"The verification link is invalid or has expired.">>,
                                false
                            ),
                            send_response(
                                Socket,
                                400,
                                <<"Bad Request">>,
                                <<"text/html; charset=utf-8">>,
                                [{<<"Content-Security-Policy">>, verify_csp()}],
                                Page
                            )
                    end;
                error ->
                    Page = verify_page(
                        <<"Verification failed">>,
                        <<"Missing account or verification code.">>,
                        false
                    ),
                    send_response(
                        Socket,
                        400,
                        <<"Bad Request">>,
                        <<"text/html; charset=utf-8">>,
                        [{<<"Content-Security-Policy">>, verify_csp()}],
                        Page
                    )
            end
    end.

parse_verify_query(Query) ->
    try uri_string:dissect_query(Query) of
        Pairs when is_list(Pairs) ->
            case {lists:keyfind(<<"account">>, 1, Pairs), lists:keyfind(<<"code">>, 1, Pairs)} of
                {{_, Account}, {_, Code}} when
                    is_binary(Account),
                    byte_size(Account) > 0,
                    is_binary(Code),
                    byte_size(Code) > 0
                ->
                    {ok, Account, Code};
                _ ->
                    error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end.

verify_form_page(AccountPrefill) ->
    EscAcct = escape_html(AccountPrefill),
    iolist_to_binary([
        <<"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">">>,
        <<"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">">>,
        <<"<title>Verify Account - ircd</title>">>,
        <<"<style>:root{color-scheme:light dark}body{font-family:system-ui,sans-serif;max-width:420px;margin:64px auto;padding:0 20px;line-height:1.5}">>,
        <<"label{display:block;font-size:13px;font-weight:500;margin:12px 0 4px}">>,
        <<"input{width:100%;box-sizing:border-box;font:inherit;padding:8px 10px;border-radius:5px;border:1px solid #8886}">>,
        <<"button{margin-top:16px;width:100%;font:inherit;padding:9px 14px;border-radius:5px;border:0;background:#1d4ed8;color:#fff;cursor:pointer;font-weight:500}</style></head><body>">>,
        <<"<h1>Verify IRC Account</h1>">>,
        <<"<p>Enter your account name and the verification code from your email.</p>">>,
        <<"<form method=\"get\" action=\"/verify\">">>,
        <<"<label for=\"account\">Account name</label>">>,
        <<"<input id=\"account\" name=\"account\" required maxlength=\"64\" value=\"">>,
        EscAcct,
        <<"\">">>,
        <<"<label for=\"code\">Verification code</label>">>,
        <<"<input id=\"code\" name=\"code\" required maxlength=\"64\" autocomplete=\"one-time-code\">">>,
        <<"<button type=\"submit\">Verify Account</button>">>,
        <<"</form></body></html>">>
    ]).

verify_page(Title, Message, Ok) ->
    Accent =
        case Ok of
            true -> <<"#15803d">>;
            false -> <<"#b91c1c">>
        end,
    iolist_to_binary([
        <<"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">">>,
        <<"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">">>,
        <<"<title>">>,
        Title,
        <<" - ircd</title>">>,
        <<"<style>:root{color-scheme:light dark}body{font-family:system-ui,sans-serif;max-width:480px;margin:64px auto;padding:0 20px;line-height:1.5}h1{color:">>,
        Accent,
        <<";font-size:20px}</style></head><body><h1>">>,
        Title,
        <<"</h1><p>">>,
        Message,
        <<"</p></body></html>">>
    ]).

escape_html(Bin) ->
    B1 = binary:replace(Bin, <<"&">>, <<"&amp;">>, [global]),
    B2 = binary:replace(B1, <<"<">>, <<"&lt;">>, [global]),
    B3 = binary:replace(B2, <<">">>, <<"&gt;">>, [global]),
    B4 = binary:replace(B3, <<"\"">>, <<"&quot;">>, [global]),
    binary:replace(B4, <<"'">>, <<"&#39;">>, [global]).

route(Socket, <<"GET">>, <<"/">>, _Headers, _Body, Html) ->
    send_nonce_html(Socket, Html);
route(Socket, <<"GET">>, <<"/api/overview">>, _Headers, _Body, _Html) ->
    Payload = #{
        status => ctl_json([<<"status">>]),
        clients => ctl_json([<<"clients">>]),
        channels => ctl_json([<<"channels">>]),
        links => ctl_json([<<"links">>]),
        accounts => ctl_json([<<"accounts">>]),
        dronebl => #{
            stats => ircd_dronebl:stats(),
            bans => ircd_dronebl:list_bans()
        }
    },
    send_json(Socket, 200, <<"OK">>, Payload);
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
allowed_action(<<"reload-certs">>) -> true;
allowed_action(<<"log-level">>) -> true;
allowed_action(<<"kick-client">>) -> true;
allowed_action(<<"connect">>) -> true;
allowed_action(<<"squit">>) -> true;
allowed_action(<<"create-account">>) -> true;
allowed_action(<<"verify-account">>) -> true;
allowed_action(<<"delete-account">>) -> true;
allowed_action(<<"backup">>) -> true;
allowed_action(<<"drain">>) -> true;
allowed_action(<<"stop">>) -> true;
allowed_action(_) -> false.

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
    case maps:get(<<"content-length">>, Headers, undefined) of
        undefined ->
            {ok, Method, Path, Headers, <<>>};
        LenBin ->
            try binary_to_integer(LenBin) of
                Len when Len < 0 ->
                    {error, invalid_content_length};
                Len when Len > ?MAX_REQUEST_BYTES ->
                    {error, payload_too_large};
                Len ->
                    read_exact(Socket, Len, Rest, Method, Path, Headers)
            catch
                _:_ -> {error, invalid_content_length}
            end
    end.

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

verify_csp() ->
    <<
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; "
        "object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
    >>.

send_json(Socket, Code, Reason, Map) ->
    Body = iolist_to_binary(json:encode(Map)),
    send_response(Socket, Code, Reason, <<"application/json; charset=utf-8">>, [], Body).

send_response(Socket, Code, Reason, ContentType, ExtraHeaders, Body) ->
    Bin = iolist_to_binary(Body),
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
        <<"Cache-Control: no-store\r\n">>,
        <<"X-Content-Type-Options: nosniff\r\n">>,
        <<"X-Frame-Options: DENY\r\n">>,
        <<"Referrer-Policy: no-referrer\r\n">>,
        CspHeader
        | [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- ExtraHeaders]
    ],
    _ = gen_tcp:send(Socket, [Headers, <<"\r\n">>, Bin]),
    ok.

send_nonce_html(Socket, Html) ->
    Nonce = base64:encode(crypto:strong_rand_bytes(16)),
    Body = binary:replace(Html, <<"__CSP_NONCE__">>, Nonce, [global]),
    Csp = <<
        "default-src 'self'; style-src 'unsafe-inline'; script-src 'nonce-",
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
