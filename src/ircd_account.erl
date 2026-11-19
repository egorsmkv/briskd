-module(ircd_account).
-export([
    min_password/0,
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
        _ ->
            mnesia:dirty_write(Incoming#account{pending = undefined}),
            stored
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
    | {error, bad_account_name | account_exists | weak_password | unacceptable_password}.
create(Name, Email, Password, CertFps, Pending) ->
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

-doc """
Verify a password for a usable account (SASL PLAIN) by deriving its
SCRAM-SHA-256 StoredKey. The comparison is constant time. An unknown account
runs the same PBKDF2 derivation with the iteration count `create/5` gives every
new account (4096), so it costs the same time as a local account. An account
imported from a peer with another iteration count is derived with its own
count.
""".
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
            %% Spend the same derivation time for an unknown account: the
            %% same PBKDF2 path and ?ITERATIONS that create/5 stores, with a
            %% fixed salt of the same 16-byte size.
            _ = verifier(Password, {<<0:128>>, ?ITERATIONS}),
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
