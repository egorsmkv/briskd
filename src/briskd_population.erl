-module(briskd_population).
-moduledoc """
Incremental O(1) network population accounting.

Maintains a coherent `#population{}` snapshot in the `briskd_population` ETS
table (`{current, #population{}}`) so `LUSERS` (RFC 2812 section 3.4.2) runs
in O(1) without scanning `client`, `remote_client`, `channel`, or
`remote_channel`.

`briskd_sup` creates `briskd_population` in `init_table/0`, so peak user counts
(`max_local`, `max_global`) survive a `briskd_state` restart while resetting
when the `briskd` application stops. `m:briskd_state` and its helper modules
call the transition hooks whenever clients connect, register, change `+i` or
`+o`, disconnect, join/leave channels, or link/split servers. Canonical
channel keys live in `briskd_canonical_channels` so a channel present in both
`channel` and `remote_channel` is counted once.
""".

-export([
    init_table/0,
    init/0,
    snapshot/0,
    note_user_counts/0,
    publish/0,
    on_client_connect/1,
    on_client_registered/2,
    on_client_disconnect/1,
    on_local_mode_change/3,
    on_remote_user_put/2,
    on_remote_user_rename/3,
    on_remote_user_delete/1,
    on_channel_put/1,
    on_channel_delete/1,
    reconcile_channels/0,
    on_server_change/0
]).

-include("briskd_population.hrl").

-define(POP_TABLE, briskd_population).
-define(INVISIBLE_TABLE, briskd_invisible).
-define(CHANNELS_TABLE, briskd_canonical_channels).

-doc """
Create the `briskd_population` ETS table if it does not yet exist.

Called by `m:briskd_sup` so the table is owned by the top-level supervisor
and retains `max_local`/`max_global` across `m:briskd_state` restarts.
""".
-spec init_table() -> ok.
init_table() ->
    case ets:whereis(?POP_TABLE) of
        undefined ->
            _ = ets:new(?POP_TABLE, [named_table, public, set, {read_concurrency, true}]),
            ets:insert(?POP_TABLE, {current, #population{}}),
            ok;
        _ ->
            ok
    end.

-doc """
Initialize transient population index tables and publish the initial snapshot.

Called by `m:briskd_state` at startup after Mnesia tables and predefined
channels have been initialized. Preserves existing `max_local` and
`max_global` when `briskd_population` already exists.
""".
-spec init() -> ok.
init() ->
    init_table(),
    ensure_set(?INVISIBLE_TABLE),
    ensure_set(?CHANNELS_TABLE),
    ok = briskd_oper:init(),
    reconcile_channels(),
    ok.

-doc """
Return the latest coherent population snapshot in O(1).
""".
-spec snapshot() -> #population{}.
snapshot() ->
    try ets:lookup_element(?POP_TABLE, current, 2) of
        #population{} = Pop -> Pop;
        _ -> #population{}
    catch
        error:badarg -> #population{}
    end.

-doc """
Recompute and publish the current `#population{}` snapshot and return
`{LocalUsers, GlobalUsers}` for `265 RPL_LOCALUSERS` and `266 RPL_GLOBALUSERS`.
""".
-spec note_user_counts() -> {non_neg_integer(), non_neg_integer()}.
note_user_counts() ->
    Pop = publish(),
    {Pop#population.local_users, Pop#population.local_users + Pop#population.remote_users}.

-doc """
Publish an updated coherent `#population{}` record to `briskd_population`.
""".
-spec publish() -> #population{}.
publish() ->
    LocalUsers = ets_size(briskd_ready_clients),
    TotalLocal = mnesia_size(client),
    UnknownUsers = max(0, TotalLocal - LocalUsers),
    RemoteUsers = mnesia_size(remote_client),
    InvisibleUsers = ets_size(?INVISIBLE_TABLE),
    Operators = briskd_oper:operator_count(),
    Channels = ets_size(?CHANNELS_TABLE),
    Servers = 1 + mnesia_size(known_server),
    Prev = snapshot(),
    GlobalUsers = LocalUsers + RemoteUsers,
    MaxLocal = max(LocalUsers, Prev#population.max_local),
    MaxGlobal = max(GlobalUsers, Prev#population.max_global),
    Pop = #population{
        local_users = LocalUsers,
        remote_users = RemoteUsers,
        unknown_users = UnknownUsers,
        invisible_users = InvisibleUsers,
        operators = Operators,
        channels = Channels,
        servers = Servers,
        max_local = MaxLocal,
        max_global = MaxGlobal
    },
    case ets:whereis(?POP_TABLE) of
        undefined ->
            ok;
        _ ->
            ets:insert(?POP_TABLE, {current, Pop}),
            ok
    end,
    Pop.

-doc "Record a new unauthenticated local connection (`unknown_users` +1).".
-spec on_client_connect(pid()) -> ok.
on_client_connect(_Pid) ->
    _ = publish(),
    ok.

-doc """
Record that a local connection completed registration (`unknown_users` -1,
`local_users` +1) and index its initial `+i`, `+o`, and `+w` modes.
Returns `{LocalUsers, GlobalUsers}`.
""".
-spec on_client_registered(pid(), #{char() => true}) -> {non_neg_integer(), non_neg_integer()}.
on_client_registered(Pid, Modes) ->
    case ets:whereis(briskd_ready_clients) of
        undefined -> ok;
        _ -> true = ets:insert(briskd_ready_clients, {Pid})
    end,
    sync_invisible({local, Pid}, maps:is_key($i, Modes)),
    briskd_oper:sync_local_modes(Pid, true, Modes),
    note_user_counts().

-doc "Remove a disconnecting local client from population indexes.".
-spec on_client_disconnect(pid()) -> ok.
on_client_disconnect(Pid) ->
    case ets:whereis(briskd_ready_clients) of
        undefined -> ok;
        _ -> true = ets:delete(briskd_ready_clients, Pid)
    end,
    delete_invisible({local, Pid}),
    briskd_oper:remove_local(Pid),
    _ = publish(),
    ok.

-doc "Update population indexes when a local user's modes change.".
-spec on_local_mode_change(pid(), boolean(), #{char() => true}) -> ok.
on_local_mode_change(Pid, Ready, Modes) ->
    sync_invisible({local, Pid}, Ready andalso maps:is_key($i, Modes)),
    briskd_oper:sync_local_modes(Pid, Ready, Modes),
    _ = publish(),
    ok.

-doc "Update population indexes when a remote user is introduced or changes modes.".
-spec on_remote_user_put(binary(), #{char() => true}) -> ok.
on_remote_user_put(Key, Modes) ->
    sync_invisible({remote, Key}, maps:is_key($i, Modes)),
    briskd_oper:sync_remote_modes(Key, Modes),
    _ = publish(),
    ok.

-doc "Move a remote user's population index entries when its nickname changes.".
-spec on_remote_user_rename(binary(), binary(), #{char() => true}) -> ok.
on_remote_user_rename(OldKey, NewKey, Modes) ->
    delete_invisible({remote, OldKey}),
    sync_invisible({remote, NewKey}, maps:is_key($i, Modes)),
    briskd_oper:rename_remote(OldKey, NewKey, Modes),
    _ = publish(),
    ok.

-doc "Remove a remote user from population indexes.".
-spec on_remote_user_delete(binary()) -> ok.
on_remote_user_delete(Key) ->
    delete_invisible({remote, Key}),
    briskd_oper:remove_remote(Key),
    _ = publish(),
    ok.

-doc "Ensure folded channel `Key` is counted in `briskd_canonical_channels`.".
-spec on_channel_put(binary()) -> ok.
on_channel_put(Key) ->
    case ets:whereis(?CHANNELS_TABLE) of
        undefined ->
            ok;
        _ ->
            true = ets:insert(?CHANNELS_TABLE, {Key}),
            _ = publish(),
            ok
    end.

-doc """
Remove folded channel `Key` from `briskd_canonical_channels` when neither
`channel` nor `remote_channel` holds a row for it.
""".
-spec on_channel_delete(binary()) -> ok.
on_channel_delete(Key) ->
    case ets:whereis(?CHANNELS_TABLE) of
        undefined ->
            ok;
        _ ->
            StillPresent =
                mnesia_has(channel, Key) orelse mnesia_has(remote_channel, Key),
            case StillPresent of
                true ->
                    ok;
                false ->
                    true = ets:delete(?CHANNELS_TABLE, Key),
                    _ = publish(),
                    ok
            end
    end.

-doc """
Rebuild `briskd_canonical_channels` from `channel` and `remote_channel`
(used at startup and after `REHASH` seeds channels) and publish the snapshot.
""".
-spec reconcile_channels() -> ok.
reconcile_channels() ->
    case ets:whereis(?CHANNELS_TABLE) of
        undefined ->
            ok;
        _ ->
            true = ets:delete_all_objects(?CHANNELS_TABLE),
            insert_channel_keys(table_keys_safe(channel)),
            insert_channel_keys(table_keys_safe(remote_channel)),
            _ = publish(),
            ok
    end.

-doc "Recompute the snapshot after a server is introduced or split.".
-spec on_server_change() -> ok.
on_server_change() ->
    _ = publish(),
    ok.

%% Internal helpers

sync_invisible(Key, true) ->
    case ets:whereis(?INVISIBLE_TABLE) of
        undefined -> ok;
        _ -> true = ets:insert(?INVISIBLE_TABLE, {Key})
    end;
sync_invisible(Key, false) ->
    delete_invisible(Key).

delete_invisible(Key) ->
    case ets:whereis(?INVISIBLE_TABLE) of
        undefined -> ok;
        _ -> true = ets:delete(?INVISIBLE_TABLE, Key)
    end.

insert_channel_keys(Keys) ->
    lists:foreach(fun(Key) -> ets:insert(?CHANNELS_TABLE, {Key}) end, Keys).

table_keys_safe(Table) ->
    try mnesia:dirty_all_keys(Table) of
        Keys when is_list(Keys) -> [K || K <- Keys, is_binary(K)]
    catch
        exit:_ -> []
    end.

mnesia_has(Table, Key) ->
    try mnesia:dirty_read(Table, Key) of
        [_ | _] -> true;
        [] -> false
    catch
        exit:_ -> false
    end.

ensure_set(Name) ->
    case ets:whereis(Name) of
        undefined ->
            _ = ets:new(Name, [named_table, public, set]),
            ok;
        _ ->
            true = ets:delete_all_objects(Name),
            ok
    end.

ets_size(Table) ->
    case ets:whereis(Table) of
        undefined ->
            0;
        _ ->
            case ets:info(Table, size) of
                N when is_integer(N), N >= 0 -> N;
                _ -> 0
            end
    end.

mnesia_size(Table) ->
    try mnesia:table_info(Table, size) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    catch
        exit:_ -> 0
    end.
