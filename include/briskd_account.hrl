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
    %% Microseconds since the epoch (`erlang:system_time(microsecond)`).
    created :: integer(),
    pending :: {binary(), integer()} | undefined
}).
%% draft/read-marker timestamps per account and folded target. Disc copies.
%% `time` is milliseconds since the epoch.
-record(read_marker, {key :: {binary(), binary()}, time :: integer()}).
%% Direct-message history (draft/chathistory), recorded when at least one side
%% is logged in. `key` is the sorted pair of the two parties, each
%% `{account, FoldedAccount}` or `{nick, FoldedNick}`; `entries` is
%% newest-first and capped by history_limit. Cleared at startup under
%% `transient` retention.
-type dm_party() :: {account | nick, binary()}.
-record(direct_history, {
    key :: {dm_party(), dm_party()},
    entries = [] :: [map() | tuple()]
}).
%% Direct-message history, one row per entry (ordered_set,
%% briskd_state_history), keyed {PartyPair, Class, Seq} like channel_message;
%% the `direct_history` row above (one list per pair) is only read to migrate
%% it.
-record(direct_message, {
    key :: {{dm_party(), dm_party()}, msg | event, pos_integer()},
    entry :: map() | tuple()
}).
