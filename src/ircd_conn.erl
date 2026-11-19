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

The row is deleted with `delete/1` when the client disconnects, so nothing
here survives the connection or a server restart.
""".

-doc """
Value of `Key` for the connection `Pid`, or `undefined` when unset.
""".
-spec get(pid(), atom()) -> term().
get(Pid, Key) ->
    get(Pid, Key, undefined).

-doc """
Value of `Key` for the connection `Pid`, or `Default` when the key or the
whole row is absent.
""".
-spec get(pid(), atom(), term()) -> term().
get(Pid, Key, Default) ->
    case ets:lookup(ircd_conn, Pid) of
        [{_, Map}] -> maps:get(Key, Map, Default);
        [] -> Default
    end.

-doc """
Set `Key` to `Value` for the connection `Pid`, creating the row if needed.

Call only from `m:ircd_state`; the read-modify-write is not atomic against
another writer.
""".
-spec put(pid(), atom(), term()) -> ok.
put(Pid, Key, Value) ->
    Map =
        case ets:lookup(ircd_conn, Pid) of
            [{_, Existing}] -> Existing;
            [] -> #{}
        end,
    ets:insert(ircd_conn, {Pid, Map#{Key => Value}}),
    ok.

-doc """
Remove `Key` from the connection `Pid`. A missing row or key is not an error.
""".
-spec remove(pid(), atom()) -> ok.
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
