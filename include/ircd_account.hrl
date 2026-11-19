%% Registered accounts (draft/account-registration, SASL). Disc copies survive
%% restart under both retention policies. Only SCRAM-SHA-256 verifiers are
%% stored: `salt`, `iterations`, `stored_key`, and `server_key`. The password
%% itself is never written. `certfps` lists lowercase hex SHA-256 client
%% certificate fingerprints accepted by SASL EXTERNAL. `pending` is
%% `undefined` for a usable account, or `{CodeHash, ExpiresMs}` while
%% draft/account-registration verification is outstanding.
-record(account, {
    key :: binary(),
    name :: binary(),
    salt :: binary(),
    iterations :: pos_integer(),
    stored_key :: binary(),
    server_key :: binary(),
    email :: binary() | undefined,
    certfps = [] :: [binary()],
    %% Seconds since the epoch.
    created :: integer(),
    pending :: {binary(), integer()} | undefined
}).
%% draft/read-marker timestamps per account and folded target. Disc copies.
%% `time` is milliseconds since the epoch.
-record(read_marker, {key :: {binary(), binary()}, time :: integer()}).
%% Direct-message history between two accounts (draft/chathistory). `key` is
%% the sorted pair of folded account names; `entries` is newest-first and
%% capped by history_limit. Cleared at startup under `transient` retention.
-record(direct_history, {key :: {binary(), binary()}, entries = [] :: [map() | tuple()]}).
