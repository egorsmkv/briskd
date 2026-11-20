-module(ircd_account).
-export([
    email_key/1,
    max_accounts/0,
    min_password/0,
    import/1,
    list/0,
    list_all/0,
    force_verify/1,
    verify/2,
    verify_by_email/2,
    by_certfp/1,
    check_password/2,
    create/5,
    derive_stored_key/3,
    new_verifier/1,
    password_matches/4,
    password_params/1,
    store_new/5,
    validate_new/2,
    find/1,
    find_by_email/1,
    set_password/2,
    scram_credentials/1,
    valid_name/1,
    verifier/2
]).
-include("ircd_account.hrl").
-export_type([verifier/0]).

-type verifier() :: #{
    salt := binary(),
    iterations := pos_integer(),
    stored_key := binary(),
    server_key := binary()
}.

-moduledoc """
Account storage for [SASL](https://ircv3.net/specs/extensions/sasl-3.2) and
[draft/account-registration](https://ircv3.net/specs/extensions/account-registration).

Accounts are rows of the Mnesia `account` table (`disc_copies`, record in
`include/ircd_account.hrl`), keyed by the folded name. They survive every
restart regardless of `retention` and are replicated to linked servers by
`m:ircd_state_sync`. The table is written only from `m:ircd_state`;
`verifier/2` is pure.

Names use the nickname character set and RFC 1459 folding
(`ircd_wire:fold/1`), so an account can be the same as a nickname.
Passwords are never stored: only SCRAM-SHA-256 verifiers (RFC 5802,
RFC 7677) with a random 16-byte salt and 4096 PBKDF2 iterations, which also
verify SASL PLAIN. Verification codes are stored as SHA-256 hashes, and
secret comparisons use `crypto:hash_equals/2`.
""".

-define(ITERATIONS, 4096).
%% Default shortest password; `account_password_min` in configuration overrides it.
-define(MIN_PASSWORD, 8).
-define(MAX_PASSWORD, 300).
-define(DEFAULT_MAX_ACCOUNTS, 100000).

-doc """
Maximum number of stored accounts: `max_accounts` from the configuration,
default 100000.
""".
-spec max_accounts() -> pos_integer().
max_accounts() ->
    maps:get(
        max_accounts, persistent_term:get({ircd_state, config}, #{}), ?DEFAULT_MAX_ACCOUNTS
    ).

-doc """
Shortest accepted password in bytes: `account_password_min` from the
configuration, default 8. The longest accepted password is 300 bytes.
""".
-spec min_password() -> pos_integer().
min_password() ->
    maps:get(
        account_password_min, persistent_term:get({ircd_state, config}, #{}), ?MIN_PASSWORD
    ).

-doc """
True when `Name` is a valid account name: a valid nickname under
`ircd_wire:nickname/2` with the configured `nicklen`, other than
`anonymous` (in any case).
""".
-spec valid_name(binary()) -> boolean().
valid_name(Name) when is_binary(Name) ->
    ircd_wire:nickname(Name, ircd_state:nicklen()) andalso ircd_wire:fold(Name) =/= <<"anonymous">>;
valid_name(_) ->
    false.

-doc """
Look up a usable (verified) account by name, compared folded. An account
awaiting verification is `error`.
""".
-spec find(binary()) -> {ok, #account{}} | error.
find(Name) ->
    case lookup(Name) of
        {ok, #account{pending = undefined} = Account} -> {ok, Account};
        _ -> error
    end.

-doc """
The comparison key for an email address: trimmed and lower-cased.

`string:trim/1` and `string:lowercase/1` raise on invalid UTF-8, and these
lookups run inside `m:ircd_state`, so an address that is not valid UTF-8
(stored before `REGISTER` checked it) is returned unchanged. Such a key never
equals one built from web input, which `json:decode/1` guarantees is UTF-8.
""".
-spec email_key(binary()) -> binary().
email_key(Email) when is_binary(Email) ->
    case unicode:characters_to_binary(Email, utf8, utf8) of
        Valid when is_binary(Valid) ->
            case string:lowercase(string:trim(Valid)) of
                Key when is_binary(Key) -> Key;
                _ -> Email
            end;
        _ ->
            Email
    end.

-doc """
Look up a usable (verified) account by email address (case-insensitive).
""".
-spec find_by_email(binary()) -> {ok, #account{}} | error.
find_by_email(Email) when is_binary(Email) ->
    Target = email_key(Email),
    find_verified_email(mnesia:dirty_all_keys(account), Target).

find_verified_email([], _Target) ->
    error;
find_verified_email([Key | Rest], Target) ->
    case mnesia:dirty_read(account, Key) of
        [#account{pending = undefined, email = Stored} = Account] when is_binary(Stored) ->
            case email_key(Stored) =:= Target of
                true -> {ok, Account};
                false -> find_verified_email(Rest, Target)
            end;
        _ ->
            find_verified_email(Rest, Target)
    end.

-doc """
Replace the SCRAM-SHA-256 password verifier of an existing usable account.
Returns `{ok, UpdatedAccount}` or `{error, bad_password | no_such_account}`.
""".
-spec set_password(binary(), binary()) ->
    {ok, #account{}} | {error, bad_password | no_such_account}.
set_password(Name, Password) when is_binary(Name), is_binary(Password) ->
    Min = min_password(),
    case byte_size(Password) >= Min andalso byte_size(Password) =< ?MAX_PASSWORD of
        false ->
            {error, bad_password};
        true ->
            case find(Name) of
                {ok, #account{} = Account} ->
                    #{
                        salt := Salt,
                        iterations := Iterations,
                        stored_key := StoredKey,
                        server_key := ServerKey
                    } = new_verifier(Password),
                    Updated = Account#account{
                        salt = Salt,
                        iterations = Iterations,
                        stored_key = StoredKey,
                        server_key = ServerKey
                    },
                    mnesia:dirty_write(Updated),
                    {ok, Updated};
                error ->
                    {error, no_such_account}
            end
    end;
set_password(_, _) ->
    {error, bad_password}.

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

-doc """
Every usable (verified) account, for a server-link burst.
""".
-spec list() -> [#account{}].
list() ->
    [
        Account
     || Key <- mnesia:dirty_all_keys(account),
        [#account{pending = undefined} = Account] <- [mnesia:dirty_read(account, Key)]
    ].

-doc """
All accounts, including non-expired pending registrations, for admin inspection.
""".
-spec list_all() -> [#account{}].
list_all() ->
    Now = erlang:system_time(millisecond),
    [
        Account
     || Key <- mnesia:dirty_all_keys(account),
        [Account] <- [mnesia:dirty_read(account, Key)],
        case Account#account.pending of
            undefined -> true;
            {_, Expires} -> Now =< Expires
        end
    ].

-doc """
Administratively verify a pending account without requiring its email code.
""".
-spec force_verify(binary()) -> {ok, #account{}} | {error, already_verified | no_such_account}.
force_verify(Name) ->
    case mnesia:dirty_read(account, ircd_wire:fold(Name)) of
        [#account{pending = undefined}] ->
            {error, already_verified};
        [#account{} = Account] ->
            Verified = Account#account{pending = undefined},
            mnesia:dirty_write(Verified),
            {ok, Verified};
        [] ->
            {error, no_such_account}
    end.

-doc """
Store an account replicated from a peer server and return `stored`, or
`kept` when the local copy wins.

The account created first wins: an incoming copy created at the same time
or later does not replace an existing verified row. A local row still
waiting for verification is always replaced. The stored copy is marked
verified.
""".
-spec import(#account{}) -> stored | kept.
import(#account{key = Key, created = Created} = Incoming) ->
    case mnesia:dirty_read(account, Key) of
        [#account{pending = undefined, created = Existing}] when Existing =< Created ->
            kept;
        [_] ->
            mnesia:dirty_write(Incoming#account{pending = undefined}),
            stored;
        [] ->
            case room_available() of
                true ->
                    mnesia:dirty_write(Incoming#account{pending = undefined}),
                    stored;
                false ->
                    kept
            end
    end.

-doc """
Complete draft/account-registration verification of `Name` with `Code`.

Returns the now usable account when the account is pending, the code has
not expired, and its SHA-256 hash matches; otherwise `error`.
""".
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

-doc """
Complete account verification by matching a pending account's email address
(case-insensitive) and verification `Code`.
""".
-spec verify_by_email(binary(), binary()) -> {ok, #account{}} | error.
verify_by_email(Email, Code) when is_binary(Email), is_binary(Code) ->
    Target = email_key(Email),
    CodeHash = crypto:hash(sha256, string:trim(Code)),
    Now = erlang:system_time(millisecond),
    find_and_verify_email(mnesia:dirty_all_keys(account), Target, CodeHash, Now).

find_and_verify_email([], _Target, _CodeHash, _Now) ->
    error;
find_and_verify_email([Key | Rest], Target, CodeHash, Now) ->
    case mnesia:dirty_read(account, Key) of
        [#account{email = StoredEmail, pending = {Hash, Expires}} = Account] when
            is_binary(StoredEmail), Now =< Expires
        ->
            case
                email_key(StoredEmail) =:= Target andalso
                    crypto:hash_equals(CodeHash, Hash)
            of
                true ->
                    Verified = Account#account{pending = undefined},
                    mnesia:dirty_write(Verified),
                    {ok, Verified};
                false ->
                    find_and_verify_email(Rest, Target, CodeHash, Now)
            end;
        _ ->
            find_and_verify_email(Rest, Target, CodeHash, Now)
    end.

-doc """
Create an account and store its SCRAM-SHA-256 verifier; the password itself
is not kept.

`Email` is `undefined` when not given. `CertFps` are lowercase hex SHA-256
client certificate fingerprints accepted by SASL EXTERNAL. `Pending` is
`undefined` for an immediately usable account, or `{Code, TtlMs}` to hold it
until `VERIFY` presents the code. A name whose pending registration expired
can be registered again.

Errors: `bad_account_name` (`valid_name/1`), `weak_password` (shorter than
`min_password/0`), `unacceptable_password` (over 300 bytes),
`account_exists`.
""".
-spec create(
    binary(), undefined | binary(), binary(), [binary()], undefined | {binary(), pos_integer()}
) ->
    {ok, #account{}}
    | {error,
        account_limit_reached
        | bad_account_name
        | account_exists
        | weak_password
        | unacceptable_password}.
create(Name, Email, Password, CertFps, Pending) ->
    case validate_new(Name, Password) of
        ok -> store_new(Name, Email, new_verifier(Password), CertFps, Pending);
        {error, _} = Error -> Error
    end.

-doc """
Cheap checks for a new account, done before any PBKDF2 work: the name is
valid (`valid_name/1`) and free, the password length is acceptable, and the
account table is below `max_accounts/0`.
""".
-spec validate_new(binary(), binary()) ->
    ok
    | {error,
        account_limit_reached
        | bad_account_name
        | account_exists
        | weak_password
        | unacceptable_password}.
validate_new(Name, Password) ->
    case
        {
            valid_name(Name),
            byte_size(Password) >= min_password(),
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
            case room_available() of
                true -> ok;
                false -> {error, account_limit_reached}
            end
    end.

room_available() ->
    Max = max_accounts(),
    case mnesia:table_info(account, size) < Max of
        true ->
            true;
        false ->
            prune_expired_pending(),
            mnesia:table_info(account, size) < Max
    end.

prune_expired_pending() ->
    Now = erlang:system_time(millisecond),
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(account, Key) of
                [#account{pending = {_, Expires}}] when Now > Expires ->
                    mnesia:dirty_delete(account, Key);
                _ ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(account)
    ).

-doc """
A fresh SCRAM-SHA-256 verifier for `Password`: a random 16-byte salt, the
standard iteration count, StoredKey, and ServerKey. This is the expensive
PBKDF2 step; it touches no state, so `ircd_state` runs it in a worker
process (`m:ircd_deferred`).
""".
-spec new_verifier(binary()) -> verifier().
new_verifier(Password) ->
    Salt = crypto:strong_rand_bytes(16),
    {StoredKey, ServerKey} = verifier(Password, {Salt, ?ITERATIONS}),
    #{salt => Salt, iterations => ?ITERATIONS, stored_key => StoredKey, server_key => ServerKey}.

-doc """
Write a new account from a verifier made by `new_verifier/1`. The name and
table cap are checked again because another client may have registered while
the verifier was being derived.
""".
-spec store_new(
    binary(), undefined | binary(), verifier(), [binary()], undefined | {binary(), pos_integer()}
) ->
    {ok, #account{}} | {error, account_limit_reached | bad_account_name | account_exists}.
store_new(Name, Email, Verifier, CertFps, Pending) ->
    case {valid_name(Name), lookup(Name), room_available()} of
        {false, _, _} ->
            {error, bad_account_name};
        {_, {ok, _}, _} ->
            {error, account_exists};
        {true, error, false} ->
            {error, account_limit_reached};
        {true, error, true} ->
            #{
                salt := Salt,
                iterations := Iterations,
                stored_key := StoredKey,
                server_key := ServerKey
            } =
                Verifier,
            Account = #account{
                key = ircd_wire:fold(Name),
                name = ircd_wire:retain(Name),
                salt = Salt,
                iterations = Iterations,
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

-doc """
Verify a password for a usable account (SASL PLAIN). Runs the PBKDF2
derivation in the calling process; `ircd_state` uses the split form
(`password_params/1`, `derive_stored_key/3`, `password_matches/4`) so the
derivation runs in a worker instead.
""".
-spec check_password(binary(), binary()) -> {ok, #account{}} | error.
check_password(Name, Password) ->
    {Salt, Iterations} = password_params(Name),
    password_matches(Name, Salt, Iterations, derive_stored_key(Password, Salt, Iterations)).

-doc """
Salt and PBKDF2 iteration count to derive a candidate key for `Name`. An
unknown or unusable account gets a fixed 16-byte salt and the iteration count
`create/5` gives every new account (4096), so the derivation costs the same
time as for a local account. An account imported from a peer with another
iteration count is derived with its own count.
""".
-spec password_params(binary()) -> {binary(), pos_integer()}.
password_params(Name) ->
    case find(Name) of
        {ok, #account{salt = Salt, iterations = Iterations}} -> {Salt, Iterations};
        error -> {<<0:128>>, ?ITERATIONS}
    end.

-doc """
The candidate SCRAM StoredKey for `Password` (the expensive PBKDF2 step;
pure, safe to run in a worker).
""".
-spec derive_stored_key(binary(), binary(), pos_integer()) -> binary().
derive_stored_key(Password, Salt, Iterations) ->
    {StoredKey, _} = verifier(Password, {Salt, Iterations}),
    StoredKey.

-doc """
Compare a candidate StoredKey with the account's, in constant time. The
account is read again: if it disappeared or its salt or iteration count
changed since `password_params/1`, the check fails.
""".
-spec password_matches(binary(), binary(), pos_integer(), binary()) -> {ok, #account{}} | error.
password_matches(Name, Salt, Iterations, Candidate) ->
    case find(Name) of
        {ok, #account{salt = Salt, iterations = Iterations, stored_key = Stored} = Account} ->
            case crypto:hash_equals(Candidate, Stored) of
                true -> {ok, Account};
                false -> error
            end;
        _ ->
            error
    end.

-doc """
SCRAM-SHA-256 `{StoredKey, ServerKey}` for a password, salt, and PBKDF2
iteration count (RFC 5802 section 3). Pure.
""".
-spec verifier(binary(), {binary(), pos_integer()}) -> {binary(), binary()}.
verifier(Password, {Salt, Iterations}) ->
    Salted = crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, 32),
    ClientKey = crypto:mac(hmac, sha256, Salted, <<"Client Key">>),
    ServerKey = crypto:mac(hmac, sha256, Salted, <<"Server Key">>),
    {crypto:hash(sha256, ClientKey), ServerKey}.

-doc """
SCRAM credentials of a usable account (stored spelling of the name, salt,
iterations, StoredKey, ServerKey) for `m:ircd_sasl`, or `error`.
""".
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

-doc """
Find the usable account that lists a client certificate fingerprint
(compared lowercase), for SASL EXTERNAL. Scans the whole table.
""".
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
