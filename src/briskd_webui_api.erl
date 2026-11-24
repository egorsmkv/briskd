-module(briskd_webui_api).
-moduledoc """
Public self-service JSON/page endpoints, media upload/download, link preview,
and authenticated admin route/action handlers for `m:briskd_webui`.
""".

-export([
    handle_account_delete/3,
    handle_file_download/2,
    handle_file_upload/3,
    handle_link_preview/3,
    handle_recover_confirm_api/3,
    handle_recover_page/3,
    handle_recover_request_api/3,
    handle_signup_api/3,
    handle_signup_page/3,
    handle_verify_api/3,
    handle_verify_page/3,
    handle_voice_download/2,
    handle_voice_upload/3,
    handle_webirc_verify_api/3,
    route/6
]).

with_csrf(Socket, Headers, Fun) ->
    case maps:get(<<"x-requested-with">>, Headers, undefined) of
        <<"briskd-webui">> ->
            Fun();
        _ ->
            briskd_webui:send_json(Socket, 403, <<"Forbidden">>, #{
                error => <<"missing_csrf_header">>
            })
    end.

decode_csrf_json(Socket, Headers, Body, Fun) ->
    with_csrf(Socket, Headers, fun() ->
        try json:decode(Body) of
            Decoded -> Fun(Decoded)
        catch
            _:_ ->
                briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                    error => <<"invalid_json">>,
                    message => <<"Invalid JSON request.">>
                })
        end
    end).

with_altcha(Socket, Req, Fun) ->
    case require_altcha(Req) of
        ok ->
            Fun();
        {error, Code, Msg} ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => Code, message => Msg
            })
    end.

with_upload_rate(Socket, Headers, Fun) ->
    with_csrf(Socket, Headers, fun() ->
        case check_upload_rate(briskd_webui:peer_ip(Socket)) of
            ok ->
                Fun();
            rate_limited ->
                briskd_webui:send_json(Socket, 429, <<"Too Many Requests">>, #{
                    error => <<"rate_limited">>,
                    message => <<"Too many uploads. Please wait a moment.">>
                })
        end
    end).

%% "Delete my data" from WebIRC settings: the account and its password
%% (checked again here, with the same timing for unknown accounts; failures
%% limited per address like admin sign-in), then the account, its read
%% markers, E2EE devices and queued messages, and the messages it wrote in
%% stored history are deleted, and its sessions are logged out.
-doc "Handle `POST /api/account/delete` to erase an account and its stored messages.".
-spec handle_account_delete(gen_tcp:socket(), map(), binary()) -> ok.
handle_account_delete(Socket, Headers, Body) ->
    decode_csrf_json(Socket, Headers, Body, fun(Decoded) ->
        IP = briskd_webui:peer_ip(Socket),
        Req =
            case Decoded of
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
            end,
        case {Req, briskd_webui_auth:retry_after(account_delete, IP)} of
            {invalid, _} ->
                briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                    error => <<"invalid_request">>,
                    message => <<"Enter your account name and password.">>
                });
            {_, Retry} when Retry > 0 ->
                briskd_webui:send_response(
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
                        briskd_webui:send_json(Socket, 401, <<"Unauthorized">>, #{
                            error => <<"invalid_credentials">>,
                            message => <<"Wrong account name or password.">>
                        })
                end
        end
    end).

account_erase(Socket, Account) ->
    case briskd_state:ctl({erase_account, Account}) of
        {ok, #{account := Actual} = Reply} ->
            briskd_webui:send_json(Socket, 200, <<"OK">>, #{
                ok => true,
                account => Actual,
                channel_messages => maps:get(channel_messages, Reply, 0),
                direct_messages => maps:get(direct_messages, Reply, 0)
            });
        {error, _} ->
            briskd_webui:send_json(Socket, 500, <<"Internal Server Error">>, #{
                error => <<"delete_failed">>,
                message => <<"The account could not be deleted. Please try again.">>
            })
    end.

-doc "Handle `POST /api/webirc/verify` with ALTCHA verification.".
-spec handle_webirc_verify_api(gen_tcp:socket(), map(), binary()) -> ok.
handle_webirc_verify_api(Socket, Headers, Body) ->
    decode_csrf_json(Socket, Headers, Body, fun
        (Req) when is_map(Req) ->
            with_altcha(Socket, Req, fun() ->
                briskd_webui:send_json(Socket, 200, <<"OK">>, #{status => <<"verified">>})
            end);
        (_) ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_request">>,
                message => <<"Invalid verification request.">>
            })
    end).

-doc "Serve `GET /recover` when SMTP password recovery is enabled.".
-spec handle_recover_page(gen_tcp:socket(), binary(), map()) -> ok.
handle_recover_page(Socket, AppHtml, Headers) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_verification, Config, null) of
        #{smtp := _} ->
            briskd_webui:send_app(Socket, AppHtml, recover, <<"/recover">>, Headers);
        _ ->
            briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                error => <<"recovery_disabled">>
            })
    end.

-doc "Handle `POST /api/recover/request` to email a password recovery code.".
-spec handle_recover_request_api(gen_tcp:socket(), map(), binary()) -> ok.
handle_recover_request_api(Socket, Headers, Body) ->
    decode_csrf_json(Socket, Headers, Body, fun
        (#{<<"email">> := Email} = Req) when is_binary(Email), byte_size(Email) > 0 ->
            with_altcha(Socket, Req, fun() ->
                Config = briskd_config:current_or_empty(),
                Origin = briskd_webui:public_origin(Headers, Config),
                RecoveryUrl = <<Origin/binary, "/recover">>,
                PeerIP = briskd_webui:peer_ip(Socket),
                case briskd_state:request_password_reset(Email, RecoveryUrl, PeerIP) of
                    ok ->
                        briskd_webui:send_json(Socket, 200, <<"OK">>, #{
                            status => <<"sent">>,
                            message =>
                                <<"If an account exists for that email, a recovery code has been sent.">>
                        });
                    {error, disabled} ->
                        briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                            error => <<"recovery_disabled">>,
                            message => <<"Password recovery via email is not enabled.">>
                        });
                    {error, rate_limited} ->
                        briskd_webui:send_json(Socket, 429, <<"Too Many Requests">>, #{
                            error => <<"rate_limited">>,
                            message =>
                                <<"Too many recovery attempts. Please try again later.">>
                        });
                    {error, bad_email} ->
                        briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                            error => <<"invalid_email">>,
                            message => <<"Enter a valid email address.">>
                        })
                end
            end);
        (_) ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_request">>,
                message => <<"Email address is required.">>
            })
    end).

-doc "Handle `POST /api/recover/confirm` to reset an account password.".
-spec handle_recover_confirm_api(gen_tcp:socket(), map(), binary()) -> ok.
handle_recover_confirm_api(Socket, Headers, Body) ->
    decode_csrf_json(Socket, Headers, Body, fun
        (
            #{
                <<"email">> := Email,
                <<"code">> := Code,
                <<"password">> := Password
            } = Req
        ) when
            is_binary(Email),
            byte_size(Email) > 0,
            is_binary(Code),
            byte_size(Code) > 0,
            is_binary(Password),
            byte_size(Password) > 0
        ->
            with_altcha(Socket, Req, fun() ->
                PeerIP = briskd_webui:peer_ip(Socket),
                case briskd_state:complete_password_reset(Email, Code, Password, PeerIP) of
                    {ok, AccountName} ->
                        briskd_webui:send_json(Socket, 200, <<"OK">>, #{
                            status => <<"reset">>,
                            account => AccountName
                        });
                    {error, disabled} ->
                        briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                            error => <<"recovery_disabled">>,
                            message => <<"Password recovery via email is not enabled.">>
                        });
                    {error, rate_limited} ->
                        briskd_webui:send_json(Socket, 429, <<"Too Many Requests">>, #{
                            error => <<"rate_limited">>,
                            message =>
                                <<"Too many recovery attempts. Please try again later.">>
                        });
                    {error, bad_password} ->
                        briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                            error => <<"bad_password">>,
                            message => <<"Password does not meet length requirements.">>
                        });
                    {error, invalid_code} ->
                        briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                            error => <<"invalid_code">>,
                            message => <<"Invalid or expired recovery code.">>
                        })
                end
            end);
        (_) ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_request">>,
                message => <<"Email, recovery code, and new password are required.">>
            })
    end).

-doc "Serve `GET /signup` when self-registration is enabled.".
-spec handle_signup_page(gen_tcp:socket(), binary(), map()) -> ok.
handle_signup_page(Socket, AppHtml, Headers) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_registration, Config, true) of
        true ->
            briskd_webui:send_app(Socket, AppHtml, signup, <<"/signup">>, Headers);
        false ->
            briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                error => <<"registration_disabled">>
            })
    end.

-doc "Handle `POST /api/signup` for account registration.".
-spec handle_signup_api(gen_tcp:socket(), map(), binary()) -> ok.
handle_signup_api(Socket, Headers, Body) ->
    decode_csrf_json(Socket, Headers, Body, fun
        (#{<<"account">> := Account, <<"password">> := Password} = Req) when
            is_binary(Account), is_binary(Password)
        ->
            case maps:get(<<"accept_terms">>, Req, false) of
                true ->
                    with_altcha(Socket, Req, fun() ->
                        handle_signup_submit(Socket, Account, Password, Req)
                    end);
                _ ->
                    briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"terms_not_accepted">>,
                        message =>
                            <<"You must accept the Terms of Use and Privacy Policy.">>
                    })
            end;
        (_) ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_request">>,
                message => <<"Account name and password are required.">>
            })
    end).

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
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_email">>,
                message => <<"Invalid email address.">>
            });
        _ ->
            PeerIP = briskd_webui:peer_ip(Socket),
            case briskd_state:signup_account(Account, Email, Password, PeerIP) of
                {ok, created, Name} ->
                    briskd_webui:send_json(Socket, 201, <<"Created">>, #{
                        status => <<"created">>, account => Name
                    });
                {ok, verification_required, Name} ->
                    briskd_webui:send_json(Socket, 202, <<"Accepted">>, #{
                        status => <<"verification_required">>, account => Name
                    });
                {error, registration_disabled} ->
                    briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                        error => <<"registration_disabled">>,
                        message => <<"Account registration is disabled.">>
                    });
                {error, rate_limited} ->
                    briskd_webui:send_json(Socket, 429, <<"Too Many Requests">>, #{
                        error => <<"rate_limited">>,
                        message => <<"Too many registration attempts. Try again later.">>
                    });
                {error, Reason} ->
                    briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
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

-doc "Handle `POST /api/voice` uploads.".
-spec handle_voice_upload(gen_tcp:socket(), map(), binary()) -> ok.
handle_voice_upload(Socket, Headers, Body) ->
    with_upload_rate(Socket, Headers, fun() ->
        Duration = parse_voice_duration(
            maps:get(<<"x-voice-duration">>, Headers, undefined)
        ),
        case briskd_voice:store(Body, Duration) of
            {ok, Meta} ->
                briskd_webui:send_json(Socket, 201, <<"Created">>, Meta);
            {error, disabled} ->
                briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                    error => <<"voice_disabled">>
                });
            {error, empty} ->
                briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                    error => <<"empty_audio">>
                });
            {error, too_large} ->
                briskd_webui:send_json(Socket, 413, <<"Payload Too Large">>, #{
                    error => <<"payload_too_large">>
                });
            {error, too_long} ->
                briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                    error => <<"voice_too_long">>
                });
            {error, unsupported_format} ->
                briskd_webui:send_json(Socket, 415, <<"Unsupported Media Type">>, #{
                    error => <<"unsupported_format">>,
                    message => <<"Only OPUS audio (Ogg or WebM) is accepted.">>
                });
            {error, Reason} ->
                logger:warning(#{event => voice_upload_failed, reason => Reason}),
                briskd_webui:send_json(Socket, 502, <<"Bad Gateway">>, #{
                    error => <<"storage_error">>
                })
        end
    end).

-doc "Handle `GET /api/voice/:id` downloads.".
-spec handle_voice_download(gen_tcp:socket(), binary()) -> ok.
handle_voice_download(Socket, VoiceId) ->
    case briskd_voice:fetch(VoiceId) of
        {ok, Bytes, Mime} ->
            briskd_webui:send_response(
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
            briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                error => <<"voice_disabled">>
            });
        {error, invalid_id} ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_voice_id">>
            });
        {error, not_found} ->
            briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{error => <<"not_found">>});
        {error, Reason} ->
            logger:warning(#{event => voice_download_failed, id => VoiceId, reason => Reason}),
            briskd_webui:send_json(Socket, 502, <<"Bad Gateway">>, #{error => <<"storage_error">>})
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

-doc "Handle `POST /api/files` uploads.".
-spec handle_file_upload(gen_tcp:socket(), map(), binary()) -> ok.
handle_file_upload(Socket, Headers, Body) ->
    with_upload_rate(Socket, Headers, fun() ->
        RawName = decode_header_filename(
            maps:get(<<"x-file-name">>, Headers, undefined)
        ),
        case briskd_files:store(Body, RawName) of
            {ok, Meta} ->
                briskd_webui:send_json(Socket, 201, <<"Created">>, Meta);
            {error, disabled} ->
                briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                    error => <<"files_disabled">>
                });
            {error, empty} ->
                briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                    error => <<"empty_file">>
                });
            {error, too_large} ->
                briskd_webui:send_json(Socket, 413, <<"Payload Too Large">>, #{
                    error => <<"payload_too_large">>
                });
            {error, Reason} ->
                logger:warning(#{event => file_upload_failed, reason => Reason}),
                briskd_webui:send_json(Socket, 502, <<"Bad Gateway">>, #{
                    error => <<"storage_error">>
                })
        end
    end).

%% Bounded per-IP upload rate limiter: at most 20 uploads per 60 seconds.
check_upload_rate(IP) ->
    Tab = briskd_webui:ensure_upload_rate_table(),
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

-doc "Handle `GET /api/files/:id` downloads.".
-spec handle_file_download(gen_tcp:socket(), binary()) -> ok.
handle_file_download(Socket, FileId) ->
    case briskd_files:fetch(FileId) of
        {ok, Bytes, Mime, InlinePreview} ->
            Disp =
                case InlinePreview of
                    true -> <<"inline">>;
                    false -> <<"attachment">>
                end,
            briskd_webui:send_response(
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
            briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                error => <<"files_disabled">>
            });
        {error, invalid_id} ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_file_id">>
            });
        {error, not_found} ->
            briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{error => <<"not_found">>});
        {error, Reason} ->
            logger:warning(#{event => file_download_failed, id => FileId, reason => Reason}),
            briskd_webui:send_json(Socket, 502, <<"Bad Gateway">>, #{error => <<"storage_error">>})
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

-doc "Handle `GET /api/link-preview?url=...`.".
-spec handle_link_preview(gen_tcp:socket(), binary(), map()) -> ok.
handle_link_preview(Socket, Query, Headers) ->
    with_csrf(Socket, Headers, fun() ->
        Url = extract_query_param(<<"url">>, Query),
        case Url of
            <<>> ->
                briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                    error => <<"missing_url">>
                });
            _ ->
                case briskd_link_preview:fetch(Url) of
                    {ok, Meta} ->
                        briskd_webui:send_json(Socket, 200, <<"OK">>, Meta);
                    {error, disabled} ->
                        briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                            error => <<"link_previews_disabled">>
                        });
                    {error, private_address} ->
                        briskd_webui:send_json(Socket, 403, <<"Forbidden">>, #{
                            error => <<"private_address">>
                        });
                    {error, invalid_url} ->
                        briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                            error => <<"invalid_url">>
                        });
                    {error, disallowed_port} ->
                        briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                            error => <<"disallowed_port">>
                        });
                    {error, _} ->
                        %% The page exists but has no usable preview (or
                        %% could not be fetched): a normal outcome, so no
                        %% error status for the browser console to report.
                        briskd_webui:send_response(Socket, 204, <<"No Content">>, <<>>, [], <<>>)
                end
        end
    end).

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

-doc "Serve `GET /verify` when account verification is configured.".
-spec handle_verify_page(gen_tcp:socket(), binary(), map()) -> ok.
handle_verify_page(Socket, AppHtml, Headers) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_verification, Config, null) of
        null ->
            briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                error => <<"verification_disabled">>
            });
        _ ->
            briskd_webui:send_app(Socket, AppHtml, verify, <<"/verify">>, Headers)
    end.

-doc "Handle `POST /api/verify` for account email verification.".
-spec handle_verify_api(gen_tcp:socket(), map(), binary()) -> ok.
handle_verify_api(Socket, Headers, Body) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_verification, Config, null) of
        null ->
            briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{
                error => <<"verification_disabled">>,
                message => <<"Account verification is disabled.">>
            });
        _ ->
            decode_csrf_json(Socket, Headers, Body, fun
                (#{<<"code">> := Code} = Req) when is_binary(Code), byte_size(Code) > 0 ->
                    with_altcha(Socket, Req, fun() ->
                        verify_from_json(Socket, Req, Code)
                    end);
                (_) ->
                    briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_request">>,
                        message => <<"Verification code is required.">>
                    })
            end)
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
            briskd_webui:send_json(Socket, 200, <<"OK">>, #{
                status => <<"verified">>, account => VerifiedName
            });
        missing_ident ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"missing_identifier">>,
                message => <<"Email address or account name is required.">>
            });
        error ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_code">>,
                message => <<"The verification code is invalid or has expired.">>
            })
    end.

-doc "Dispatch an authenticated admin WebUI page or JSON API route.".
-spec route(gen_tcp:socket(), binary(), binary(), map(), binary(), binary()) -> ok.
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
    briskd_webui:send_app(Socket, Html, admin, Path, Headers);
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
    briskd_webui:send_json(Socket, 200, <<"OK">>, Payload);
route(Socket, <<"GET">>, <<"/api/stats">>, _Headers, _Body, _Html) ->
    try briskd_stats:history() of
        #{interval_ms := Interval, samples := Samples} ->
            briskd_webui:send_json(Socket, 200, <<"OK">>, #{
                interval_ms => Interval, metrics => columns(Samples)
            })
    catch
        exit:_ ->
            briskd_webui:send_json(Socket, 503, <<"Service Unavailable">>, #{
                error => <<"stats_unavailable">>
            })
    end;
route(Socket, <<"GET">>, <<"/api/media">>, _Headers, _Body, _Html) ->
    Config = briskd_config:current_or_empty(),
    briskd_webui:send_json(Socket, 200, <<"OK">>, #{
        features => current_features(Config),
        controls => briskd_state:controls(),
        voice => briskd_voice:list(),
        files => briskd_files:list()
    });
route(Socket, <<"POST">>, <<"/api/action">>, Headers, Body, _Html) ->
    decode_csrf_json(Socket, Headers, Body, fun
        (#{<<"action">> := Action} = Req) when is_binary(Action) ->
            Args = maps:get(<<"args">>, Req, []),
            case valid_args(Args) of
                true ->
                    dispatch_action(Socket, Action, Args);
                false ->
                    briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                        error => <<"invalid_args">>
                    })
            end;
        (_) ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_request">>
            })
    end);
route(Socket, Method, _Path, _Headers, _Body, _Html) when
    Method =:= <<"GET">>; Method =:= <<"POST">>
->
    briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{error => <<"not_found">>});
route(Socket, _Method, _Path, _Headers, _Body, _Html) ->
    briskd_webui:send_json(Socket, 405, <<"Method Not Allowed">>, #{
        error => <<"method_not_allowed">>
    }).

dispatch_action(Socket, <<"dronebl-unban">>, [IP]) ->
    ok = briskd_dronebl:unban(IP),
    briskd_webui:send_json(Socket, 200, <<"OK">>, #{status => <<"unbanned">>, ip => IP});
dispatch_action(Socket, <<"dronebl-ban">>, [IP | Rest]) ->
    Reason =
        case Rest of
            [R | _] when byte_size(R) > 0 -> R;
            _ -> <<"Manual admin ban">>
        end,
    case briskd_dronebl:ban(IP, 255, Reason) of
        ok ->
            briskd_webui:send_json(Socket, 200, <<"OK">>, #{status => <<"banned">>, ip => IP});
        {error, invalid_ip} ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
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
                    briskd_webui:send_json(Socket, 200, <<"OK">>, #{
                        status => <<"updated">>,
                        features => current_features(briskd_config:current())
                    });
                {error, Reason} ->
                    control_error(Socket, Reason)
            end;
        error ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_feature">>
            })
    end;
%% Admin overrides of server features (briskd_overrides): set one, or go back
%% to the configuration file's value. Applied live, kept across REHASH and
%% restarts.
dispatch_action(Socket, <<"set-control">>, [Key, Value]) ->
    case briskd_state:set_control(Key, Value) of
        {ok, Controls} ->
            briskd_webui:send_json(Socket, 200, <<"OK">>, #{
                status => <<"updated">>, controls => Controls
            });
        {error, Reason} ->
            control_error(Socket, Reason)
    end;
dispatch_action(Socket, <<"reset-control">>, [Key]) ->
    case briskd_state:reset_control(Key) of
        {ok, Controls} ->
            briskd_webui:send_json(Socket, 200, <<"OK">>, #{
                status => <<"reset">>, controls => Controls
            });
        {error, Reason} ->
            control_error(Socket, Reason)
    end;
dispatch_action(Socket, <<"delete-voice">>, [VoiceId]) ->
    case briskd_voice:delete(VoiceId) of
        ok ->
            logger:notice(#{event => admin_voice_deleted, id => VoiceId}),
            briskd_webui:send_json(Socket, 200, <<"OK">>, #{
                status => <<"deleted">>, id => VoiceId
            });
        {error, invalid_id} ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_voice_id">>
            });
        {error, disabled} ->
            briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{error => <<"voice_disabled">>});
        {error, _} ->
            briskd_webui:send_json(Socket, 502, <<"Bad Gateway">>, #{error => <<"storage_error">>})
    end;
dispatch_action(Socket, <<"delete-file">>, [FileId]) ->
    case briskd_files:delete(FileId) of
        ok ->
            logger:notice(#{event => admin_file_deleted, id => FileId}),
            briskd_webui:send_json(Socket, 200, <<"OK">>, #{status => <<"deleted">>, id => FileId});
        {error, invalid_id} ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"invalid_file_id">>
            });
        {error, disabled} ->
            briskd_webui:send_json(Socket, 404, <<"Not Found">>, #{error => <<"files_disabled">>});
        {error, _} ->
            briskd_webui:send_json(Socket, 502, <<"Bad Gateway">>, #{error => <<"storage_error">>})
    end;
dispatch_action(Socket, <<"clear-upload-limits">>, []) ->
    case ets:whereis(briskd_webui_uploads) of
        undefined -> ok;
        Tab -> ets:delete_all_objects(Tab)
    end,
    briskd_webui:send_json(Socket, 200, <<"OK">>, #{status => <<"cleared">>});
dispatch_action(Socket, Action, Args) ->
    case allowed_action(Action) of
        true ->
            case briskd_ctl:run([Action | Args] ++ [<<"--json">>]) of
                {ok, JsonBin} ->
                    briskd_webui:send_response(
                        Socket, 200, <<"OK">>, <<"application/json; charset=utf-8">>, [], JsonBin
                    );
                {error, JsonBin} ->
                    briskd_webui:send_response(
                        Socket,
                        400,
                        <<"Bad Request">>,
                        <<"application/json; charset=utf-8">>,
                        [],
                        JsonBin
                    )
            end;
        false ->
            briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{
                error => <<"unsupported_action">>, action => Action
            })
    end.

allowed_action(Action) ->
    lists:member(Action, [
        <<"rehash">>,
        <<"check-config">>,
        <<"reload-certs">>,
        <<"search-rebuild">>,
        <<"log-level">>,
        <<"kick-client">>,
        <<"notice-all">>,
        <<"notice-channel">>,
        <<"set-topic">>,
        <<"connect">>,
        <<"squit">>,
        <<"create-account">>,
        <<"verify-account">>,
        <<"reset-password">>,
        <<"delete-account">>,
        <<"set-email">>,
        <<"add-certfp">>,
        <<"remove-certfp">>,
        <<"create-channel">>,
        <<"delete-channel">>,
        <<"set-channel-modes">>,
        <<"backup">>,
        <<"drain">>,
        <<"stop">>
    ]).

control_error(Socket, Reason) when
    Reason =:= unknown_control; Reason =:= invalid_value; Reason =:= not_configured
->
    briskd_webui:send_json(Socket, 400, <<"Bad Request">>, #{error => atom_to_binary(Reason)}).

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
