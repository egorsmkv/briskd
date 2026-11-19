-module(ircd_mail).
-moduledoc """
Outbound SMTP email delivery for account verification via `gen_smtp`.

When `account_verification` is configured with an `"smtp"` block,
`send_verification/4` delivers a plain-text RFC 5322 email containing:

- A clickable web verification link when `"verify_url"` is configured
  (`<verify_url>?account=<account>&code=<code>`);
- The fallback IRC `VERIFY <account> <code>` command.

Delivery runs asynchronously in a short-lived worker process so SMTP network
I/O never blocks `m:ircd_state`. Header values are stripped of CR/LF/NUL to
prevent header injection, and verification codes and SMTP passwords are never
logged.
""".

-export([
    send_verification/4,
    send_verification_sync/4,
    verify_link/3,
    build_message/5,
    smtp_options/1
]).

-doc """
Deliver a verification email asynchronously using the `smtp` section of
`Verification` (the normalized `account_verification` config map).
""".
-spec send_verification(map(), binary(), binary(), binary()) -> ok.
send_verification(Verification, Account, Email, Code) ->
    _ = spawn(fun() ->
        case send_verification_sync(Verification, Account, Email, Code) of
            {ok, _Receipt} ->
                ok;
            {error, Reason} ->
                logger:warning(#{
                    event => account_verification_failed,
                    account => Account,
                    reason => Reason
                })
        end
    end),
    ok.

-doc """
Deliver a verification email synchronously via `gen_smtp_client:send_blocking/2`.
Returns `{ok, Receipt}` on SMTP acceptance or `{error, Reason}` on failure.
""".
-spec send_verification_sync(map(), binary(), binary(), binary()) ->
    {ok, binary()} | {error, term()}.
send_verification_sync(#{smtp := Smtp} = Verification, Account, Email, Code) ->
    From = maps:get(from, Smtp),
    Subject = maps:get(subject, Smtp, <<"Verify your IRC account">>),
    VerifyUrl = maps:get(verify_url, Verification, null),
    Body = build_message(From, Email, Subject, Account, #{
        code => Code,
        verify_url => VerifyUrl
    }),
    Opts = smtp_options(Smtp),
    try gen_smtp_client:send_blocking({From, [Email], Body}, Opts) of
        Receipt when is_binary(Receipt) ->
            {ok, Receipt};
        {error, Type, Message} ->
            {error, {Type, Message}};
        {error, Reason} ->
            {error, Reason}
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

-doc """
Build a web verification URL by appending `account` and `code` query parameters
to `BaseUrl`.
""".
-spec verify_link(binary(), binary(), binary()) -> binary().
verify_link(BaseUrl, Account, Code) ->
    Query = iolist_to_binary(
        uri_string:compose_query([{<<"account">>, Account}, {<<"code">>, Code}])
    ),
    Sep =
        case binary:match(BaseUrl, <<"?">>) of
            nomatch -> <<"?">>;
            _ -> <<"&">>
        end,
    <<BaseUrl/binary, Sep/binary, Query/binary>>.

-doc """
Format an RFC 5322 verification email body for `Account`.
`Opts` must include `code` and may include `verify_url` (`binary() | null`).
""".
-spec build_message(binary(), binary(), binary(), binary(), map()) -> binary().
build_message(From, To, Subject, Account, #{code := Code} = Opts) ->
    SafeFrom = sanitize_header(From),
    SafeTo = sanitize_header(To),
    SafeSubject = sanitize_header(Subject),
    SafeAccount = sanitize_header(Account),
    LinkLines =
        case maps:get(verify_url, Opts, null) of
            BaseUrl when is_binary(BaseUrl), byte_size(BaseUrl) > 0 ->
                Link = verify_link(BaseUrl, Account, Code),
                [
                    <<"Verify your account by opening this link:\r\n">>,
                    Link,
                    <<"\r\n\r\n">>
                ];
            _ ->
                []
        end,
    iolist_to_binary([
        <<"From: ">>,
        SafeFrom,
        <<"\r\n">>,
        <<"To: ">>,
        SafeTo,
        <<"\r\n">>,
        <<"Subject: ">>,
        SafeSubject,
        <<"\r\n">>,
        <<"MIME-Version: 1.0\r\n">>,
        <<"Content-Type: text/plain; charset=utf-8\r\n">>,
        <<"\r\n">>,
        <<"Hello ">>,
        SafeAccount,
        <<",\r\n\r\n">>,
        LinkLines,
        <<"Or run this command in your IRC client:\r\n">>,
        <<"VERIFY ">>,
        SafeAccount,
        <<" ">>,
        Code,
        <<"\r\n">>
    ]).

-doc """
Convert a validated `smtp` config map into `gen_smtp_client` options.
""".
-spec smtp_options(map()) -> list().
smtp_options(#{relay := Relay, port := Port, tls := Tls, ssl := Ssl} = Smtp) ->
    Base = [
        {relay, binary_to_list(Relay)},
        {port, Port},
        {tls, Tls},
        {ssl, Ssl},
        {retries, 0},
        {timeout, 15000}
    ],
    Auth =
        case {maps:get(username, Smtp, null), maps:get(password, Smtp, null)} of
            {User, Pass} when is_binary(User), is_binary(Pass) ->
                [
                    {username, binary_to_list(User)},
                    {password, binary_to_list(Pass)},
                    {auth, always}
                ];
            _ ->
                [{auth, never}]
        end,
    Base ++ Auth.

sanitize_header(Bin) ->
    binary:replace(Bin, [<<"\r">>, <<"\n">>, <<0>>], <<>>, [global]).
