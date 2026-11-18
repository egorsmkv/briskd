-module(ircd_conn).
-export([delete/1, get/2, get/3, put/3, remove/2]).

%% Per-connection IRCv3 state in the `ircd_conn` ETS table, owned by
%% `ircd_state` (its only writer). Keys in use:
%%   account   - logged-in account name (SASL or REGISTER)
%%   sasl      - in-progress AUTHENTICATE state
%%   sasl_buf  - partial base64 AUTHENTICATE payload
%%   monitor   - MONITOR targets, folded nick => given spelling
%%   metadata  - draft/metadata-2 user keys, key => value
%%   metasubs  - draft/metadata-2 subscriptions, sorted list of keys
%%   batch     - open client-initiated batch (draft/multiline)
%%   markread  - draft/read-marker timestamps for a connection without account
%% The row is deleted when the client disconnects.

-spec get(pid(), atom()) -> term().
get(Pid, Key) ->
    get(Pid, Key, undefined).

-spec get(pid(), atom(), term()) -> term().
get(Pid, Key, Default) ->
    case ets:lookup(ircd_conn, Pid) of
        [{_, Map}] -> maps:get(Key, Map, Default);
        [] -> Default
    end.

-spec put(pid(), atom(), term()) -> ok.
put(Pid, Key, Value) ->
    Map =
        case ets:lookup(ircd_conn, Pid) of
            [{_, Existing}] -> Existing;
            [] -> #{}
        end,
    ets:insert(ircd_conn, {Pid, Map#{Key => Value}}),
    ok.

-spec remove(pid(), atom()) -> ok.
remove(Pid, Key) ->
    case ets:lookup(ircd_conn, Pid) of
        [{_, Map}] -> ets:insert(ircd_conn, {Pid, maps:remove(Key, Map)});
        [] -> ok
    end,
    ok.

-spec delete(pid()) -> ok.
delete(Pid) ->
    ets:delete(ircd_conn, Pid),
    ok.
