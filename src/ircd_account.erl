-module(ircd_account).
-export([
    add_certfp/2,
    import/1,
    list/0,
    verify/2,
    by_certfp/1,
    check_password/2,
    create/5,
    find/1,
    scram_credentials/1,
    valid_name/1,
    verifier/2
]).
-include("ircd_account.hrl").

%% Account storage for SASL and draft/account-registration.
%% Names use the nickname character set and RFC 1459 folding, so an account
%% can be the same as a nickname. Passwords are stored only as SCRAM-SHA-256
%% verifiers (RFC 5802, RFC 7677), which also verify SASL PLAIN.

-define(ITERATIONS, 4096).
-define(MIN_PASSWORD, 8).
-define(MAX_PASSWORD, 300).

%% @doc Account names follow the nickname rules of `ircd_wire:nickname/1`.
-spec valid_name(binary()) -> boolean().
valid_name(Name) when is_binary(Name) ->
    ircd_wire:nickname(Name) andalso ircd_wire:fold(Name) =/= <<"anonymous">>;
valid_name(_) ->
    false.

%% @doc Look up a usable (verified) account by name.
-spec find(binary()) -> {ok, #account{}} | error.
find(Name) ->
    case lookup(Name) of
        {ok, #account{pending = undefined} = Account} -> {ok, Account};
        _ -> error
    end.

%% Any row, including one waiting for verification. An expired pending row is
%% treated as absent so the name can be registered again.
lookup(Name) ->
    case mnesia:dirty_read(account, ircd_wire:fold(Name)) of
        [#account{pending = {_, Expires}}] ->
            case erlang:system_time(millisecond) > Expires of
                true -> error;
                false -> {ok, pending}
            end;
        [Account] ->
            {ok, Account};
        [] ->
            error
    end.

%% @doc Every usable account, for a server-link burst.
-spec list() -> [#account{}].
list() ->
    [
        Account
     || Key <- mnesia:dirty_all_keys(account),
        [#account{pending = undefined} = Account] <- [mnesia:dirty_read(account, Key)]
    ].

%% @doc Store an account replicated from a peer server. The account created
%% first wins; an equal or newer copy does not replace an existing row.
-spec import(#account{}) -> stored | kept.
import(#account{key = Key, created = Created} = Incoming) ->
    case mnesia:dirty_read(account, Key) of
        [#account{pending = undefined, created = Existing}] when Existing =< Created ->
            kept;
        _ ->
            mnesia:dirty_write(Incoming#account{pending = undefined}),
            stored
    end.

%% @doc Complete draft/account-registration verification with a code.
-spec verify(binary(), binary()) -> {ok, #account{}} | error.
verify(Name, Code) ->
    case mnesia:dirty_read(account, ircd_wire:fold(Name)) of
        [#account{pending = {Hash, Expires}} = Account] ->
            Fresh = erlang:system_time(millisecond) =< Expires,
            case Fresh andalso crypto:hash_equals(crypto:hash(sha256, Code), Hash) of
                true ->
                    Verified = Account#account{pending = undefined},
                    mnesia:dirty_write(Verified),
                    {ok, Verified};
                false ->
                    error
            end;
        _ ->
            error
    end.

%% @doc Create an account. `Email` is `undefined` when not given. `Pending`
%% is `undefined` for an immediately usable account, or `{Code, TtlMs}` to
%% hold it until VERIFY presents the code.
-spec create(
    binary(), undefined | binary(), binary(), [binary()], undefined | {binary(), pos_integer()}
) ->
    {ok, #account{}}
    | {error, bad_account_name | account_exists | weak_password | unacceptable_password}.
create(Name, Email, Password, CertFps, Pending) ->
    case
        {
            valid_name(Name),
            byte_size(Password) >= ?MIN_PASSWORD,
            byte_size(Password) =< ?MAX_PASSWORD,
            lookup(Name)
        }
    of
        {false, _, _, _} ->
            {error, bad_account_name};
        {_, false, _, _} ->
            {error, weak_password};
        {_, _, false, _} ->
            {error, unacceptable_password};
        {_, _, _, {ok, _}} ->
            {error, account_exists};
        {true, true, true, error} ->
            Salt = crypto:strong_rand_bytes(16),
            {StoredKey, ServerKey} = verifier(Password, {Salt, ?ITERATIONS}),
            Account = #account{
                key = ircd_wire:fold(Name),
                name = ircd_wire:retain(Name),
                salt = Salt,
                iterations = ?ITERATIONS,
                stored_key = StoredKey,
                server_key = ServerKey,
                email = ircd_wire:retain(Email),
                certfps = CertFps,
                created = erlang:system_time(microsecond),
                pending =
                    case Pending of
                        undefined ->
                            undefined;
                        {Code, Ttl} ->
                            {crypto:hash(sha256, Code), erlang:system_time(millisecond) + Ttl}
                    end
            },
            mnesia:dirty_write(Account),
            {ok, Account}
    end.

%% @doc Verify a password (SASL PLAIN). The comparison is constant time.
-spec check_password(binary(), binary()) -> {ok, #account{}} | error.
check_password(Name, Password) ->
    case find(Name) of
        {ok, #account{salt = Salt, iterations = Iterations, stored_key = Stored} = Account} ->
            {Candidate, _} = verifier(Password, {Salt, Iterations}),
            case crypto:hash_equals(Candidate, Stored) of
                true -> {ok, Account};
                false -> error
            end;
        error ->
            %% Spend the same derivation time for an unknown account.
            _ = verifier(Password, {<<0:128>>, ?ITERATIONS}),
            error
    end.

%% @doc SCRAM-SHA-256 StoredKey and ServerKey for a password and salt.
-spec verifier(binary(), {binary(), pos_integer()}) -> {binary(), binary()}.
verifier(Password, {Salt, Iterations}) ->
    Salted = crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, 32),
    ClientKey = crypto:mac(hmac, sha256, Salted, <<"Client Key">>),
    ServerKey = crypto:mac(hmac, sha256, Salted, <<"Server Key">>),
    {crypto:hash(sha256, ClientKey), ServerKey}.

%% @doc SCRAM credentials for an account name, or `error`.
-spec scram_credentials(binary()) ->
    {ok, #{
        name := binary(),
        salt := binary(),
        iterations := pos_integer(),
        stored_key := binary(),
        server_key := binary()
    }}
    | error.
scram_credentials(Name) ->
    case find(Name) of
        {ok, #account{
            name = Actual, salt = Salt, iterations = I, stored_key = Stored, server_key = ServerKey
        }} ->
            {ok, #{
                name => Actual,
                salt => Salt,
                iterations => I,
                stored_key => Stored,
                server_key => ServerKey
            }};
        error ->
            error
    end.

%% @doc Find the account that owns a client certificate fingerprint.
-spec by_certfp(binary()) -> {ok, #account{}} | error.
by_certfp(Fingerprint) ->
    Wanted = string:lowercase(Fingerprint),
    case
        [
            Account
         || Key <- mnesia:dirty_all_keys(account),
            [#account{certfps = Fps, pending = undefined} = Account] <- [
                mnesia:dirty_read(account, Key)
            ],
            lists:member(Wanted, Fps)
        ]
    of
        [Account | _] -> {ok, Account};
        [] -> error
    end.

%% @doc Remember a client certificate fingerprint for an account.
-spec add_certfp(binary(), binary()) -> ok | error.
add_certfp(Name, Fingerprint) ->
    case find(Name) of
        {ok, #account{certfps = Fps} = Account} ->
            Fp = string:lowercase(Fingerprint),
            mnesia:dirty_write(Account#account{certfps = lists:usort([Fp | Fps])}),
            ok;
        error ->
            error
    end.
