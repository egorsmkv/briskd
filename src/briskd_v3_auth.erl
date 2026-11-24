-module(briskd_v3_auth).
-moduledoc """
IRCv3 SASL authentication (`AUTHENTICATE`), account registration (`REGISTER`,
`VERIFY`), email verification, and password reset flows.
""".
-export([
    authenticate/3,
    complete_password_reset_web/4,
    expire_password_resets/0,
    logout/2,
    register/3,
    request_password_reset_web/3,
    signup_account_web/4,
    valid_email/1,
    verify/3,
    verify_account_email_web/2,
    verify_account_web/2
]).
-include("briskd_client.hrl").
-include("briskd_account.hrl").

%%% SASL

-doc """
`AUTHENTICATE` (SASL 3.1 and 3.2). Reauthentication is allowed.
""".
-spec authenticate([binary()], #client{}, binary()) -> ok.
authenticate([], Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"AUTHENTICATE">>], <<"Not enough parameters">>
    );
authenticate([Param | _], #client{pid = Pid} = Client, Server) ->
    case {Param, briskd_conn:get(Pid, sasl)} of
        {<<"*">>, _} ->
            clear_sasl(Pid),
            sasl_numeric(Client, Server, <<"906">>, [], <<"SASL authentication aborted">>);
        {Mechanism, undefined} ->
            Context = #{certfp => maps:get(certfp, briskd_cap:info(Pid), undefined)},
            case briskd_sasl:start(Mechanism, Context) of
                {continue, Challenge, State} ->
                    briskd_conn:put(Pid, sasl, State),
                    briskd_conn:put(Pid, sasl_buf, <<>>),
                    send_challenge(Pid, Server, Challenge);
                {error, unknown_mechanism} ->
                    sasl_numeric(
                        Client,
                        Server,
                        <<"908">>,
                        [binary:join(briskd_cap:sasl_mechanisms(), <<",">>)],
                        <<"are available SASL mechanisms">>
                    ),
                    sasl_numeric(Client, Server, <<"904">>, [], <<"SASL authentication failed">>)
            end;
        {Chunk, State} ->
            case briskd_sasl:decode_chunk(briskd_conn:get(Pid, sasl_buf, <<>>), Chunk) of
                {more, Buffer} ->
                    briskd_conn:put(Pid, sasl_buf, Buffer);
                {error, too_long} ->
                    clear_sasl(Pid),
                    sasl_numeric(Client, Server, <<"905">>, [], <<"SASL message too long">>);
                {error, invalid} ->
                    sasl_fail(Client, Server);
                {error, overflow} ->
                    sasl_fail(Client, Server);
                {done, Data} ->
                    sasl_step(Client, Server, State, Data)
            end
    end.

sasl_step(#client{pid = Pid} = Client, Server, State, Data) ->
    case briskd_sasl:step(State, Data) of
        {continue, Challenge, Next} ->
            briskd_conn:put(Pid, sasl, Next),
            briskd_conn:put(Pid, sasl_buf, <<>>),
            send_challenge(Pid, Server, Challenge);
        {success, Account} ->
            sasl_success(Client, Account, Server);
        {check_password, Name, Password} ->
            %% PLAIN: derive the candidate key in a worker (briskd_deferred) so
            %% the PBKDF2 rounds never block briskd_state.
            {Salt, Iterations} = briskd_account:password_params(Name),
            briskd_deferred:request(
                fun() -> briskd_account:derive_stored_key(Password, Salt, Iterations) end,
                fun(Result) -> plain_checked(Pid, Server, Name, Salt, Iterations, Result) end
            );
        {error, _} ->
            sasl_fail(Client, Server)
    end.

plain_checked(Pid, Server, Name, Salt, Iterations, Result) ->
    Client = briskd_state_client:client(Pid),
    case Result of
        {ok, Candidate} ->
            case briskd_account:password_matches(Name, Salt, Iterations, Candidate) of
                {ok, #account{name = Account}} -> sasl_success(Client, Account, Server);
                error -> sasl_fail(Client, Server)
            end;
        {error, _} ->
            sasl_fail(Client, Server)
    end.

sasl_success(#client{pid = Pid} = Client, Account, Server) ->
    clear_sasl(Pid),
    login(Client, Account, Server),
    sasl_numeric(Client, Server, <<"903">>, [], <<"SASL authentication successful">>).

sasl_fail(#client{pid = Pid, nick = Nick, host = Host} = Client, Server) ->
    clear_sasl(Pid),
    logger:info(#{event => sasl_failed, nick => Nick, host => Host}),
    sasl_numeric(Client, Server, <<"904">>, [], <<"SASL authentication failed">>).

clear_sasl(Pid) ->
    briskd_conn:remove(Pid, sasl),
    briskd_conn:remove(Pid, sasl_buf).

send_challenge(Pid, Server, Challenge) ->
    lists:foreach(
        fun(Chunk) -> briskd_state_send:send(Pid, Server, <<"AUTHENTICATE">>, [Chunk], none) end,
        briskd_sasl:encode_chunks(Challenge)
    ).

sasl_numeric(#client{pid = Pid, nick = Nick}, Server, Number, Params, Text) ->
    briskd_state_send:send(Pid, Server, Number, [Nick | Params], Text).

%% Log in and announce the account (RPL_LOGGEDIN, account-notify, peers).
login(#client{pid = Pid}, Account, Server) ->
    Client = briskd_state_client:client(Pid),
    Previous = briskd_state_v3:account(Pid),
    case
        Previous =/= undefined andalso
            briskd_wire:fold(Previous) =/= briskd_wire:fold(Account)
    of
        true -> ok = briskd_e2ee:session_down(Pid);
        false -> ok
    end,
    briskd_conn:put(Pid, account, Account),
    logger:info(#{event => account_login, nick => Client#client.nick, account => Account}),
    briskd_state_send:send(
        Pid,
        Server,
        <<"900">>,
        [Client#client.nick, mask(Client), Account],
        [<<"You are now logged in as ">>, Account]
    ),
    case briskd_state_client:ready(Client) andalso Previous =/= Account of
        true -> account_changed(Client, Account);
        false -> ok
    end.

-doc """
Log the client out (used when its account is removed). When it was logged
in, sends 901 RPL_LOGGEDOUT, `ACCOUNT *` to account-notify clients, and
`ACCOUNT *` to peers.
""".
-spec logout(#client{}, binary()) -> ok.
logout(#client{pid = Pid} = Client, Server) ->
    case briskd_state_v3:account(Pid) of
        undefined ->
            ok;
        _ ->
            ok = briskd_e2ee:session_down(Pid),
            briskd_conn:remove(Pid, account),
            briskd_state_send:send(
                Pid,
                Server,
                <<"901">>,
                [Client#client.nick, mask(Client)],
                <<"You are now logged out">>
            ),
            account_changed(Client, undefined)
    end.

account_changed(Client, Account) ->
    Value =
        case Account of
            undefined -> <<"*">>;
            _ -> Account
        end,
    briskd_state_v3:notify(Client, <<"account-notify">>, <<"ACCOUNT">>, [Value], none, true),
    briskd_state_link:server_broadcast(
        briskd_wire:line(briskd_state_send:prefix(Client), <<"ACCOUNT">>, [Value], none)
    ).

mask(#client{user = undefined}) -> <<"*">>;
mask(Client) -> iolist_to_binary(briskd_state_send:prefix(Client)).

%%% draft/account-registration

-doc """
`REGISTER <account|*> <email|*> <password>` (draft/account-registration).
""".
-spec register([binary()], #client{}, binary()) -> ok.
register([Requested, Email, Password | _], #client{pid = Pid, nick = Current} = Client, Server) ->
    Nick =
        case Current of
            <<"*">> -> briskd_conn:get(Pid, wanted_nick, <<"*">>);
            _ -> Current
        end,
    Name =
        case Requested of
            <<"*">> -> Nick;
            _ -> Requested
        end,
    Enabled = maps:get(
        account_registration, briskd_config:current(), true
    ),
    Verification = maps:get(
        account_verification, briskd_config:current(), null
    ),
    Config = briskd_config:current(),
    EmailRequired =
        Verification =/= null orelse maps:get(account_registration_email_required, Config, false),
    EmailOk = valid_email(Email) andalso (not EmailRequired orelse Email =/= <<"*">>),
    %% Without `before-connect`, REGISTER needs a completed connection.
    TooEarly =
        not maps:get(account_registration_before_connect, Config, true) andalso
            not briskd_state_client:ready(Client),
    Held = Nick =/= <<"*">> andalso nick_held_by_other(Name, Pid),
    case {Enabled, Nick, briskd_state_v3:account(Pid), EmailOk} of
        {false, _, _, _} ->
            reg_fail(Pid, <<"TEMPORARILY_UNAVAILABLE">>, Name, <<"Registration is disabled">>);
        _ when TooEarly ->
            briskd_state_send:fail(
                Pid,
                <<"REGISTER">>,
                <<"COMPLETE_CONNECTION_REQUIRED">>,
                [Name],
                <<"Finish connecting before registering">>
            );
        {_, <<"*">>, _, _} ->
            reg_fail(Pid, <<"NEED_NICK">>, <<"*">>, <<"Send NICK before REGISTER">>);
        {_, _, Logged, _} when Logged =/= undefined ->
            reg_fail(Pid, <<"ALREADY_AUTHENTICATED">>, Logged, <<"You are already logged in">>);
        {_, _, _, _} when Held ->
            reg_fail(Pid, <<"ACCOUNT_EXISTS">>, Name, <<"Account already exists">>);
        {_, _, _, false} ->
            reg_fail(Pid, <<"INVALID_EMAIL">>, Name, <<"Invalid email address">>);
        {true, _, undefined, true} ->
            Stored =
                case Email of
                    <<"*">> -> undefined;
                    _ -> Email
                end,
            CertFps =
                case maps:get(certfp, briskd_cap:info(Pid), undefined) of
                    undefined -> [];
                    Fp -> [Fp]
                end,
            case briskd_account:validate_new(Name, Password) of
                ok ->
                    case briskd_flood:allow_register(Client#client.host) of
                        false ->
                            reg_fail(
                                Pid,
                                <<"TEMPORARILY_UNAVAILABLE">>,
                                Name,
                                <<"Registration rate limit exceeded, try again">>
                            );
                        true ->
                            briskd_deferred:request(
                                fun() -> briskd_account:new_verifier(Password) end,
                                fun(Result) ->
                                    register_derived(
                                        Result, Pid, Name, Stored, CertFps, Verification, Server
                                    )
                                end
                            )
                    end;
                {error, _} = Invalid ->
                    register_result(Invalid, Pid, Name, Stored, Verification, undefined, Server)
            end
    end;
register(_, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"REGISTER">>], <<"Not enough parameters">>
    ).

register_derived({ok, Verifier}, Pid, Name, Stored, CertFps, Verification, Server) ->
    Pending =
        case Verification of
            null -> undefined;
            #{ttl := Ttl} -> {verification_code(), Ttl * 1000}
        end,
    Result = briskd_account:store_new(Name, Stored, Verifier, CertFps, Pending),
    register_result(Result, Pid, Name, Stored, Verification, Pending, Server);
register_derived({error, _}, Pid, Name, _Stored, _CertFps, _Verification, _Server) ->
    reg_fail(Pid, <<"TEMPORARILY_UNAVAILABLE">>, Name, <<"Registration is busy, try again">>).

register_result(Result, Pid, Name, Stored, Verification, Pending, Server) ->
    Client = briskd_state_client:client(Pid),
    case Result of
        {ok, Account} when Pending =:= undefined ->
            logger:info(#{event => account_registered, account => Name}),
            briskd_state_sync:account_created(Account),
            briskd_state_send:send(
                Pid,
                Server,
                <<"REGISTER">>,
                [<<"SUCCESS">>, Name],
                <<"Account created">>
            ),
            login(Client, Name, Server);
        {ok, _} ->
            {Code, _} = Pending,
            logger:info(#{event => account_verification_sent, account => Name}),
            send_verification(Verification, Name, Stored, Code),
            briskd_state_send:send(
                Pid,
                Server,
                <<"REGISTER">>,
                [<<"VERIFICATION_REQUIRED">>, Name],
                <<"Check your email for a verification code">>
            );
        {error, account_exists} ->
            reg_fail(Pid, <<"ACCOUNT_EXISTS">>, Name, <<"Account already exists">>);
        {error, bad_account_name} ->
            reg_fail(Pid, <<"BAD_ACCOUNT_NAME">>, Name, <<"Invalid account name">>);
        {error, weak_password} ->
            reg_fail(Pid, <<"WEAK_PASSWORD">>, Name, <<"Password is too short">>);
        {error, unacceptable_password} ->
            reg_fail(Pid, <<"UNACCEPTABLE_PASSWORD">>, Name, <<"Password is too long">>);
        {error, account_limit_reached} ->
            reg_fail(Pid, <<"TEMPORARILY_UNAVAILABLE">>, Name, <<"Account limit reached">>)
    end.

%% True when another local or remote client currently uses the nickname.
nick_held_by_other(Name, Pid) ->
    case briskd_state_client:find_nick(Name) of
        #client{pid = Other} when Other =/= Pid ->
            true;
        _ ->
            mnesia:dirty_read(remote_client, briskd_wire:fold(Name)) =/= []
    end.

reg_fail(Pid, Code, Name, Text) ->
    briskd_state_send:fail(Pid, <<"REGISTER">>, Code, [Name], Text).

-doc """
Whether `Email` is an acceptable email address: at most 254 bytes of UTF-8,
one `@`, a non-empty local part, and a dot in the domain. `*` (REGISTER's
"no address") is accepted.
""".
-spec valid_email(binary()) -> boolean().
valid_email(<<"*">>) ->
    true;
valid_email(Email) ->
    byte_size(Email) =< 254 andalso briskd_state_v3:valid_utf8(Email) andalso
        case binary:split(Email, <<"@">>) of
            [Local, Domain] -> Local =/= <<>> andalso binary:match(Domain, <<".">>) =/= nomatch;
            _ -> false
        end.

%% Eight random characters from an unambiguous alphabet.
verification_code() ->
    Alphabet = <<"ABCDEFGHJKLMNPQRSTUVWXYZ23456789">>,
    <<<<(binary:at(Alphabet, B rem 32))>> || <<B>> <= crypto:strong_rand_bytes(8)>>.

send_verification(Verification, Account, Email, Code) ->
    case maps:is_key(smtp, Verification) of
        true -> briskd_mail:send_verification(Verification, Account, Email, Code);
        false -> ok
    end,
    case maps:find(command, Verification) of
        {ok, [Exe | Args]} ->
            ExtraEnv =
                case maps:get(verify_url, Verification, null) of
                    BaseUrl when is_binary(BaseUrl), byte_size(BaseUrl) > 0 ->
                        [
                            {
                                "BRISKD_VERIFY_URL",
                                binary_to_list(briskd_mail:verify_link(BaseUrl, Account, Code))
                            }
                        ];
                    _ ->
                        []
                end,
            _ = spawn(fun() ->
                try
                    Port = open_port({spawn_executable, Exe}, [
                        {args, Args},
                        {env, [
                            {"BRISKD_ACCOUNT", binary_to_list(Account)},
                            {"BRISKD_EMAIL", binary_to_list(Email)},
                            {"BRISKD_CODE", binary_to_list(Code)}
                            | ExtraEnv
                        ]},
                        exit_status,
                        use_stdio,
                        stderr_to_stdout
                    ]),
                    wait_sender(Port, Account)
                catch
                    error:Reason ->
                        logger:warning(#{
                            event => account_verification_failed,
                            account => Account,
                            reason => Reason
                        })
                end
            end),
            ok;
        error ->
            ok
    end.

wait_sender(Port, Account) ->
    receive
        {Port, {data, _}} ->
            wait_sender(Port, Account);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Status}} ->
            logger:warning(#{
                event => account_verification_failed, account => Account, reason => {exit, Status}
            })
    after 30000 ->
        port_close(Port),
        logger:warning(#{
            event => account_verification_failed, account => Account, reason => timeout
        })
    end.

-doc """
`VERIFY <account> <code>` (draft/account-registration). A correct,
unexpired code for a pending account activates it, replies
`VERIFY SUCCESS`, and logs the client in, as SASL would.
""".
-spec verify([binary()], #client{}, binary()) -> ok.
verify([Requested, Code | _], #client{pid = Pid, nick = Nick} = Client, Server) ->
    Name =
        case Requested of
            <<"*">> -> Nick;
            _ -> Requested
        end,
    case briskd_state_v3:account(Pid) of
        undefined ->
            case briskd_account:verify(Name, Code) of
                {ok, Account} ->
                    logger:info(#{event => account_registered, account => Name}),
                    briskd_state_sync:account_created(Account),
                    briskd_state_send:send(
                        Pid, Server, <<"VERIFY">>, [<<"SUCCESS">>, Name], <<"Account verified">>
                    ),
                    login(Client, Account#account.name, Server);
                error ->
                    briskd_state_send:fail(
                        Pid,
                        <<"VERIFY">>,
                        <<"INVALID_CODE">>,
                        [Name],
                        <<"Invalid verification code">>
                    )
            end;
        Account ->
            briskd_state_send:fail(
                Pid,
                <<"VERIFY">>,
                <<"ALREADY_AUTHENTICATED">>,
                [Account],
                <<"You are already logged in">>
            )
    end;
verify(_, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"VERIFY">>], <<"Not enough parameters">>
    ).

-doc """
Activate a pending account via the web verification link.
Runs inside `m:briskd_state`; returns `{ok, AccountName}` or `error`.
""".
-spec verify_account_web(binary(), binary()) -> {ok, binary()} | error.
verify_account_web(Name, Code) when is_binary(Name), is_binary(Code) ->
    case briskd_account:verify(string:trim(Name), string:trim(Code)) of
        {ok, #account{name = Actual} = Account} ->
            logger:info(#{event => account_registered, account => Actual, via => web}),
            briskd_state_sync:account_created(Account),
            {ok, Actual};
        error ->
            error
    end.

-doc """
Activate a pending account via email address and verification code from `/verify`.
Runs inside `m:briskd_state`; returns `{ok, AccountName}` or `error`.
""".
-spec verify_account_email_web(binary(), binary()) -> {ok, binary()} | error.
verify_account_email_web(Email, Code) when is_binary(Email), is_binary(Code) ->
    case briskd_account:verify_by_email(Email, Code) of
        {ok, #account{name = Actual} = Account} ->
            logger:info(#{event => account_registered, account => Actual, via => web}),
            briskd_state_sync:account_created(Account),
            {ok, Actual};
        error ->
            error
    end.

-doc """
Initiate email password recovery for a verified account. Runs inside
`m:briskd_state`. Always returns `ok` for valid email addresses even when no
account matches (to prevent email enumeration).
""".
-spec request_password_reset_web(binary(), binary() | null, binary()) ->
    ok | {error, disabled | rate_limited | bad_email}.
request_password_reset_web(Email0, RecoveryUrl, PeerIP) when is_binary(Email0) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_verification, Config, null) of
        #{ttl := Ttl, smtp := _} = Verification ->
            case briskd_flood:allow_register(PeerIP) of
                false ->
                    {error, rate_limited};
                true ->
                    case normalize_web_email(Email0, true) of
                        {error, _} ->
                            {error, bad_email};
                        {ok, Email} ->
                            maybe_send_reset(Verification, Ttl, Email, RecoveryUrl),
                            ok
                    end
            end;
        _ ->
            {error, disabled}
    end;
request_password_reset_web(_, _, _) ->
    {error, bad_email}.

maybe_send_reset(Verification, Ttl, Email, RecoveryUrl) ->
    case briskd_account:find_by_email(Email) of
        {ok, #account{key = Folded, name = AccountName, email = StoredEmail}} when
            is_binary(StoredEmail)
        ->
            _ = ensure_reset_table(),
            Code = verification_code(),
            Hash = crypto:hash(sha256, Code),
            Expires = erlang:system_time(millisecond) + Ttl * 1000,
            EmailKey = briskd_account:email_key(StoredEmail),
            ets:insert(briskd_password_reset, {EmailKey, Folded, AccountName, Hash, Expires}),
            logger:info(#{event => password_reset_requested, account => AccountName}),
            briskd_mail:send_password_reset(
                Verification, AccountName, StoredEmail, Code, RecoveryUrl
            );
        error ->
            ok
    end.

-doc """
Delete expired password-reset codes. Called every minute by `m:briskd_state`.
""".
-spec expire_password_resets() -> ok.
expire_password_resets() ->
    case ets:whereis(briskd_password_reset) of
        undefined ->
            ok;
        _ ->
            Now = erlang:system_time(millisecond),
            _ = ets:select_delete(briskd_password_reset, [
                {{'_', '_', '_', '_', '$1'}, [{'<', '$1', Now}], [true]}
            ]),
            ok
    end.

-doc """
Complete email password recovery by checking the single-use reset code and
updating the account's SCRAM-SHA-256 password verifier. Runs inside
`m:briskd_state`.
""".
-spec complete_password_reset_web(binary(), binary(), binary(), binary()) ->
    {ok, binary()} | {error, disabled | rate_limited | invalid_code | bad_password}.
complete_password_reset_web(Email0, Code0, NewPassword, PeerIP) when
    is_binary(Email0), is_binary(Code0), is_binary(NewPassword)
->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_verification, Config, null) of
        #{smtp := _} ->
            case briskd_flood:allow_register(PeerIP) of
                false ->
                    {error, rate_limited};
                true ->
                    EmailKey = briskd_account:email_key(Email0),
                    CodeHash = crypto:hash(sha256, string:trim(Code0)),
                    Now = erlang:system_time(millisecond),
                    _ = ensure_reset_table(),
                    case ets:lookup(briskd_password_reset, EmailKey) of
                        [{EmailKey, _Folded, AccountName, StoredHash, Expires}] when
                            Now =< Expires
                        ->
                            case crypto:hash_equals(CodeHash, StoredHash) of
                                true ->
                                    case briskd_account:set_password(AccountName, NewPassword) of
                                        {ok, #account{name = Actual} = Updated} ->
                                            ets:delete(briskd_password_reset, EmailKey),
                                            logger:info(#{
                                                event => password_reset_completed,
                                                account => Actual
                                            }),
                                            briskd_state_sync:account_created(Updated),
                                            {ok, Actual};
                                        {error, bad_password} ->
                                            {error, bad_password};
                                        {error, no_such_account} ->
                                            ets:delete(briskd_password_reset, EmailKey),
                                            {error, invalid_code}
                                    end;
                                false ->
                                    {error, invalid_code}
                            end;
                        [{EmailKey, _, _, _, _}] ->
                            ets:delete(briskd_password_reset, EmailKey),
                            {error, invalid_code};
                        [] ->
                            {error, invalid_code}
                    end
            end;
        _ ->
            {error, disabled}
    end;
complete_password_reset_web(_, _, _, _) ->
    {error, invalid_code}.

ensure_reset_table() ->
    case ets:whereis(briskd_password_reset) of
        undefined ->
            ets:new(briskd_password_reset, [named_table, set, public]);
        _ ->
            ok
    end.

-doc """
Create an IRC account from the public WebUI sign-up page.
""".
-spec signup_account_web(binary(), undefined | binary(), binary(), binary()) ->
    {ok, created | verification_required, binary()} | {error, atom()}.
signup_account_web(Name, Email0, Password, PeerIP) ->
    Config = briskd_config:current_or_empty(),
    case maps:get(account_registration, Config, true) of
        false ->
            {error, registration_disabled};
        true ->
            case briskd_flood:allow_register(PeerIP) of
                false ->
                    {error, rate_limited};
                true ->
                    Verification = maps:get(account_verification, Config, null),
                    EmailRequired =
                        Verification =/= null orelse
                            maps:get(account_registration_email_required, Config, false),
                    case normalize_web_email(Email0, EmailRequired) of
                        {error, Reason} ->
                            {error, Reason};
                        {ok, StoredEmail} ->
                            Pending =
                                case Verification of
                                    #{ttl := Ttl} ->
                                        {verification_code(), Ttl * 1000};
                                    null ->
                                        undefined
                                end,
                            case briskd_account:create(Name, StoredEmail, Password, [], Pending) of
                                {ok, #account{name = Actual} = Account} when
                                    Pending =:= undefined
                                ->
                                    logger:info(#{
                                        event => account_registered, account => Actual, via => web
                                    }),
                                    briskd_state_sync:account_created(Account),
                                    {ok, created, Actual};
                                {ok, #account{name = Actual}} ->
                                    {Code, _} = Pending,
                                    logger:info(#{
                                        event => account_verification_sent,
                                        account => Actual,
                                        via => web
                                    }),
                                    send_verification(Verification, Actual, StoredEmail, Code),
                                    {ok, verification_required, Actual};
                                {error, Reason} ->
                                    {error, Reason}
                            end
                    end
            end
    end.

normalize_web_email(undefined, true) ->
    {error, email_required};
normalize_web_email(<<>>, true) ->
    {error, email_required};
normalize_web_email(undefined, false) ->
    {ok, undefined};
normalize_web_email(<<>>, false) ->
    {ok, undefined};
normalize_web_email(<<"*">>, _) ->
    {error, invalid_email};
normalize_web_email(Email, _) when is_binary(Email) ->
    case valid_email(Email) of
        true -> {ok, Email};
        false -> {error, invalid_email}
    end;
normalize_web_email(_, _) ->
    {error, invalid_email}.
