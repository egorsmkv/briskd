-module(briskd_webui_auth).
-moduledoc """
Admin panel sign-in for `m:briskd_webui`: a login page that sets a session
cookie, in place of the browser's HTTP Basic dialog.

`POST /api/admin/login` checks the `webui` `username` and `password` (constant
time, `briskd_config:secret_match/2`) and returns a random 256-bit session
token in the `briskd_admin` cookie (`HttpOnly`, `SameSite=Strict`, `Path=/`,
`Secure` when the request came over HTTPS through a proxy that sets
`X-Forwarded-Proto: https`). Only the token's SHA-256 is kept, in the
`briskd_webui_sessions` ETS table, with its expiry and a hash of the
credentials it was issued for: changing the username or password (with
`REHASH`) signs every session out. A session lasts 12 hours and at most 256
exist (the oldest is dropped first). Sessions do not survive a restart.

Failed sign-ins are limited per client address: after 5 failures in 5
minutes, further attempts are refused until the window passes. The same
limiter (`retry_after/2`, `note_failure/2`) guards other password checks of
the WebUI, such as deleting an account, each in its own `t:scope/0`.

HTTP Basic credentials are still accepted on the admin routes, without the
`WWW-Authenticate` challenge, for scripts and monitoring (`curl -u`).

The tables are created by `init_tables/0` in the long-lived `briskd_webui`
server process, which owns them; request handlers only read and write rows.
""".
-export([
    check/1,
    clear_cookie/1,
    cookie/2,
    init_tables/0,
    login/3,
    logout/1,
    login_retry_after/1,
    retry_after/2,
    note_failure/2,
    clear_failures/2
]).
-export_type([scope/0]).

-doc """
What a password attempt was for. Each scope is rate-limited on its own
(`retry_after/2`).
""".
-type scope() :: admin | account_delete.

-define(SESSIONS, briskd_webui_sessions).
-define(ATTEMPTS, briskd_webui_logins).
-define(COOKIE, <<"briskd_admin">>).
%% Session lifetime, seconds (12 hours).
-define(SESSION_TTL, 43200).
-define(MAX_SESSIONS, 256).
%% Failed sign-ins per client address within the window (seconds).
-define(MAX_FAILURES, 5).
-define(FAILURE_WINDOW, 300).
%% Addresses tracked before the attempts table is reset.
-define(MAX_TRACKED, 5000).

-doc """
Create the session and sign-in attempt tables. Call from the process that
should own them (`briskd_webui`'s `init/1`); a second call is a no-op.
""".
-spec init_tables() -> ok.
init_tables() ->
    lists:foreach(
        fun(Name) ->
            case ets:whereis(Name) of
                undefined -> _ = ets:new(Name, [named_table, public, set]);
                _ -> ok
            end
        end,
        [?SESSIONS, ?ATTEMPTS]
    ).

-doc """
Whether the request with lower-cased `Headers` is signed in: a live session
cookie, or HTTP Basic credentials that match the configuration.
""".
-spec check(#{binary() => binary()}) -> ok | unauthorized.
check(Headers) ->
    case credentials() of
        {User, Pass} ->
            case session_ok(Headers, User, Pass) orelse basic_ok(Headers, User, Pass) of
                true -> ok;
                false -> unauthorized
            end;
        none ->
            unauthorized
    end.

-doc """
Sign in from address `IP` with `User` and `Pass`: `{ok, Token}` with a new
session token for the cookie, `{error, invalid}`, or `{error, rate_limited}`
after too many failures from `IP`.
""".
-spec login(binary(), binary(), binary()) -> {ok, binary()} | {error, invalid | rate_limited}.
login(User, Pass, IP) ->
    case login_retry_after(IP) of
        0 ->
            case credentials() of
                {ExpectedUser, ExpectedPass} ->
                    UserOk = briskd_config:secret_match(User, ExpectedUser),
                    PassOk = briskd_config:secret_match(Pass, ExpectedPass),
                    case UserOk andalso PassOk of
                        true ->
                            clear_failures(admin, IP),
                            {ok, new_session(ExpectedUser, ExpectedPass)};
                        false ->
                            note_failure(admin, IP),
                            {error, invalid}
                    end;
                none ->
                    note_failure(admin, IP),
                    {error, invalid}
            end;
        _ ->
            {error, rate_limited}
    end.

-doc """
Seconds until address `IP` may try to sign in again (0: now).
""".
-spec login_retry_after(binary()) -> non_neg_integer().
login_retry_after(IP) ->
    retry_after(admin, IP).

-doc """
Seconds until address `IP` may try a password for `Scope` again (0: now).
""".
-spec retry_after(scope(), binary()) -> non_neg_integer().
retry_after(Scope, IP) ->
    Now = erlang:monotonic_time(second),
    Key = {Scope, IP},
    case ets:lookup(?ATTEMPTS, Key) of
        [{Key, Failures}] ->
            Recent = [T || T <- Failures, is_integer(T), T > Now - ?FAILURE_WINDOW],
            case length(Recent) >= ?MAX_FAILURES of
                true -> max(1, lists:min(Recent) + ?FAILURE_WINDOW - Now);
                false -> 0
            end;
        [] ->
            0
    end.

-doc "End the session named by the request's cookie, if any.".
-spec logout(#{binary() => binary()}) -> ok.
logout(Headers) ->
    case cookie_token(Headers) of
        {ok, Token} -> ets:delete(?SESSIONS, token_hash(Token));
        error -> ok
    end,
    ok.

-doc """
The `Set-Cookie` value for session `Token`; `Secure` adds the `Secure`
attribute (the request came over HTTPS).
""".
-spec cookie(binary(), boolean()) -> binary().
cookie(Token, Secure) ->
    iolist_to_binary([
        ?COOKIE,
        $=,
        Token,
        <<"; Path=/; HttpOnly; SameSite=Strict; Max-Age=">>,
        integer_to_binary(?SESSION_TTL),
        secure_attr(Secure)
    ]).

-doc "The `Set-Cookie` value that removes the session cookie.".
-spec clear_cookie(boolean()) -> binary().
clear_cookie(Secure) ->
    iolist_to_binary([
        ?COOKIE, <<"=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0">>, secure_attr(Secure)
    ]).

secure_attr(true) -> <<"; Secure">>;
secure_attr(false) -> <<>>.

%% The configured admin credentials, or none when the WebUI has none.
credentials() ->
    case maps:get(webui, briskd_config:current_or_empty(), null) of
        #{username := User, password := Pass} when is_binary(User), is_binary(Pass) ->
            {User, Pass};
        _ ->
            none
    end.

%% A session is bound to the credentials it was issued for.
cred_tag(User, Pass) ->
    crypto:hash(sha256, [User, 0, Pass]).

token_hash(Token) ->
    crypto:hash(sha256, Token).

new_session(User, Pass) ->
    Token = base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}),
    Now = erlang:system_time(second),
    prune(Now),
    ets:insert(?SESSIONS, {token_hash(Token), Now + ?SESSION_TTL, cred_tag(User, Pass)}),
    Token.

%% Drop expired sessions; at the cap, also the one that expires first.
prune(Now) ->
    _ = ets:select_delete(?SESSIONS, [{{'_', '$1', '_'}, [{'=<', '$1', Now}], [true]}]),
    case ets:info(?SESSIONS, size) of
        Size when is_integer(Size), Size >= ?MAX_SESSIONS ->
            Oldest = lists:min([{Exp, Hash} || {Hash, Exp, _} <- ets:tab2list(?SESSIONS)]),
            ets:delete(?SESSIONS, element(2, Oldest));
        _ ->
            ok
    end,
    ok.

session_ok(Headers, User, Pass) ->
    case cookie_token(Headers) of
        {ok, Token} ->
            Hash = token_hash(Token),
            case ets:lookup(?SESSIONS, Hash) of
                [{Hash, Expires, Tag}] ->
                    Expires > erlang:system_time(second) andalso
                        crypto:hash_equals(Tag, cred_tag(User, Pass));
                [] ->
                    false
            end;
        error ->
            false
    end.

basic_ok(Headers, User, Pass) ->
    case maps:get(<<"authorization">>, Headers, undefined) of
        <<"Basic ", Encoded/binary>> ->
            try base64:decode(briskd_websocket:trim_ows(Encoded)) of
                Decoded ->
                    case binary:split(Decoded, <<":">>) of
                        [U, P] ->
                            UserOk = briskd_config:secret_match(U, User),
                            PassOk = briskd_config:secret_match(P, Pass),
                            UserOk andalso PassOk;
                        _ ->
                            false
                    end
            catch
                error:_ -> false
            end;
        _ ->
            false
    end.

%% The session token from a `Cookie` header (`a=b; briskd_admin=T; c=d`).
cookie_token(Headers) ->
    Pairs = binary:split(maps:get(<<"cookie">>, Headers, <<>>), <<";">>, [global]),
    Tokens = [
        V
     || Pair <- Pairs,
        [K, V] <- [binary:split(string:trim(Pair), <<"=">>)],
        K =:= ?COOKIE,
        V =/= <<>>,
        byte_size(V) =< 64
    ],
    case Tokens of
        [Token | _] -> {ok, Token};
        [] -> error
    end.

-doc "Forget the failed attempts of `IP` for `Scope` (after a success).".
-spec clear_failures(scope(), binary()) -> ok.
clear_failures(Scope, IP) ->
    ets:delete(?ATTEMPTS, {Scope, IP}),
    ok.

-doc "Count a failed password attempt from `IP` for `Scope`.".
-spec note_failure(scope(), binary()) -> ok.
note_failure(Scope, IP) ->
    Now = erlang:monotonic_time(second),
    Key = {Scope, IP},
    Recent =
        case ets:lookup(?ATTEMPTS, Key) of
            [{Key, Failures}] -> [T || T <- Failures, is_integer(T), T > Now - ?FAILURE_WINDOW];
            [] -> []
        end,
    case ets:info(?ATTEMPTS, size) of
        Size when is_integer(Size), Size >= ?MAX_TRACKED -> ets:delete_all_objects(?ATTEMPTS);
        _ -> ok
    end,
    ets:insert(?ATTEMPTS, {Key, lists:sublist([Now | Recent], ?MAX_FAILURES)}),
    ok.
