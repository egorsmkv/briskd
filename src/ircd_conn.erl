-module(ircd_conn).
-export([delete/1, get/2, get/3, put/3, remove/2]).

-moduledoc """
Per-connection IRCv3 state, stored as one map per client pid in the
`ircd_conn` ETS table.

The table is created and owned by `m:ircd_state`, which is its only writer;
every function here runs inside that process. Keys in use:

- `account`: logged-in account name (SASL or `REGISTER`)
- `sasl`: in-progress `AUTHENTICATE` state (`t:ircd_sasl:state/0`)
- `sasl_buf`: partial base64 `AUTHENTICATE` payload
- `monitor`: `MONITOR` targets, folded nick => given spelling
- `metadata`: draft/metadata-2 user keys, key => value
- `metasubs`: draft/metadata-2 subscriptions, sorted list of keys
- `batch`: open client-initiated batch (draft/multiline)
- `markread`: draft/read-marker timestamps for a connection without an account
- `signon`: registration time, seconds since the epoch (`WHOIS` 317)
- `wanted_nick`: the nickname a registering connection asked for
- `attach_to`: the holder a second connection of the same account attaches to
- `e2ee_fetch`: `E2EE FETCH` rate window, `{MonotonicSeconds, Count}`
- `reclaim`: SHA-256 of the connection's `RECLAIM` secret (never the secret)

The row is deleted with `delete/1` when the client disconnects, so nothing
here survives the connection or a server restart.
""".

-type key() ::
    account
    | sasl
    | sasl_buf
    | monitor
    | metadata
    | metasubs
    | batch
    | markread
    | signon
    | wanted_nick
    | attach_to
    | e2ee_fetch
    | reclaim.

-type batch() :: #{
    ref := binary(),
    %% The labeled-response label of the BATCH +ref line, if any.
    label := undefined | binary(),
    target := binary(),
    command := undefined | binary(),
    %% Newest line first; `true` marks a draft/multiline-concat line.
    lines := [{boolean(), binary()}],
    bytes := non_neg_integer(),
    count := non_neg_integer(),
    tags := [{binary(), undefined | binary()}]
}.
-export_type([key/0, batch/0]).

-doc """
Value of `Key` for the connection `Pid`, or `undefined` when unset.

The spec gives each key its value type (see the module documentation).
""".
-spec get
    (pid(), account) -> undefined | binary();
    (pid(), sasl) -> undefined | ircd_sasl:state();
    (pid(), batch) -> undefined | batch();
    (pid(), attach_to) -> undefined | pid();
    (pid(), reclaim) -> undefined | binary().
get(Pid, Key) ->
    maps:get(Key, row(Pid), undefined).

-doc """
Value of `Key` for the connection `Pid`, or `Default` when the key or the
whole row is absent.
""".
-spec get
    (pid(), sasl_buf, binary()) -> binary();
    (pid(), monitor, #{binary() => binary()}) -> #{binary() => binary()};
    (pid(), metadata, #{binary() => binary()}) -> #{binary() => binary()};
    (pid(), metasubs, [binary()]) -> [binary()];
    (pid(), markread, #{binary() => integer()}) -> #{binary() => integer()};
    (pid(), signon, integer()) -> integer();
    (pid(), wanted_nick, binary()) -> binary();
    (pid(), e2ee_fetch, {integer(), non_neg_integer()}) -> {integer(), non_neg_integer()}.
get(Pid, Key, Default) ->
    maps:get(Key, row(Pid), Default).

-doc """
Set `Key` to `Value` for the connection `Pid`, creating the row if needed.

Call only from `m:ircd_state`; the read-modify-write is not atomic against
another writer.
""".
-spec put
    (pid(), account, binary()) -> ok;
    (pid(), sasl, ircd_sasl:state()) -> ok;
    (pid(), sasl_buf, binary()) -> ok;
    (pid(), monitor, #{binary() => binary()}) -> ok;
    (pid(), metadata, #{binary() => binary()}) -> ok;
    (pid(), metasubs, [binary()]) -> ok;
    (pid(), batch, batch()) -> ok;
    (pid(), markread, #{binary() => integer()}) -> ok;
    (pid(), signon, integer()) -> ok;
    (pid(), wanted_nick, binary()) -> ok;
    (pid(), attach_to, pid()) -> ok;
    (pid(), e2ee_fetch, {integer(), non_neg_integer()}) -> ok;
    (pid(), reclaim, binary()) -> ok.
put(Pid, Key, Value) ->
    ets:insert(ircd_conn, {Pid, (row(Pid))#{Key => Value}}),
    ok.

%% The row is a map whose value types depend on the key, which the specs of
%% get/2, get/3, and put/3 state; the map itself is untyped.
-spec row(pid()) -> dynamic().
row(Pid) ->
    case ets:lookup(ircd_conn, Pid) of
        [{_, Map}] -> Map;
        [] -> #{}
    end.

-doc """
Remove `Key` from the connection `Pid`. A missing row or key is not an error.
""".
-spec remove(pid(), key()) -> ok.
remove(Pid, Key) ->
    case ets:lookup(ircd_conn, Pid) of
        [{_, Map}] -> ets:insert(ircd_conn, {Pid, maps:remove(Key, Map)});
        [] -> ok
    end,
    ok.

-doc """
Drop every key of the connection `Pid`. Called when the client disconnects.
""".
-spec delete(pid()) -> ok.
delete(Pid) ->
    ets:delete(ircd_conn, Pid),
    ok.
