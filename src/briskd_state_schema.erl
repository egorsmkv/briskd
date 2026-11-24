-module(briskd_state_schema).
-moduledoc """
Mnesia schema bootstrap, migrations, ETS table initialization, configuration
snapshot keys, and channel seeding for `m:briskd_state`.

All functions execute during `m:briskd_state` startup, `REHASH`, or read-only
accessors inside the `m:briskd_state` ownership boundary. `persistent_term`
keys remain namespaced under `briskd_state` so runtime readers keep an unchanged
contract.
""".
-export([
    history_limit/0,
    init_storage/1,
    nicklen/0,
    predefined_channel/1,
    reset_channels/0,
    retention/0,
    seed_channels/0,
    store_accounts/1,
    table_keys/1
]).
-include("briskd_state.hrl").
-include("briskd_account.hrl").
%% Used only by record_info(fields, ...) when the Mnesia tables are created,
%% which ELP's unused-include check does not count.
% elp:ignore W0020 (record_info/2 use)
-include("briskd_e2ee.hrl").

-doc """
Create or clear all runtime ETS tables, load and migrate Mnesia tables, seed
configured channels, and initialize secondary indexes and population state.
""".
-spec init_storage(map()) -> ok.
init_storage(Config) ->
    Started = calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}]),
    persistent_term:put({briskd_state, started}, Started),
    persistent_term:put({briskd_state, started_at}, erlang:monotonic_time(second)),
    persistent_term:put({briskd_state, started_at_system}, erlang:system_time(second)),
    ensure_ets(briskd_ready_clients),
    ensure_bag(briskd_invites),
    ok = briskd_metrics:init(),
    ok = briskd_info:init_info(),
    ensure_ets_write(briskd_connection_stats),
    ensure_ets(briskd_caps),
    ensure_ets(briskd_nicks),
    ensure_ets(briskd_inbound_peers),
    ensure_ets(briskd_outbound_ready),
    ensure_ets(briskd_holds),
    ok = briskd_oper:init(),
    ensure_ets(briskd_conn),
    ensure_ets(briskd_chan_meta),
    ensure_bag(briskd_monitor),
    ensure_ets(briskd_attached),
    ensure_ets(briskd_account_channels),
    ensure_ets(briskd_remote_meta),
    ensure_ets(briskd_e2ee_bound),
    ensure_ets(briskd_safe_channels),
    ensure_ets(briskd_empty_channels),
    ensure_bag_read(briskd_remote_membership),
    ensure_ets_read(briskd_peer_counts),
    ensure_ets(briskd_peer_batches),
    ensure_bag_read(briskd_account_sessions),
    ok = briskd_flood:init(),
    briskd_config:store(Config),
    persistent_term:put({briskd_state, config_path}, maps:get(config_path, Config)),
    persistent_term:put({briskd_state, motd_file}, maps:get(motd_file, Config, null)),
    persistent_term:put({briskd_state, client_password}, maps:get(client_password, Config, null)),
    persistent_term:put({briskd_state, server_links}, maps:get(server_links, Config, [])),
    persistent_term:put({briskd_state, admin}, maps:get(admin, Config, #{})),
    store_accounts(Config),
    persistent_term:put({briskd_state, reop_delay}, maps:get(reop_delay, Config, 30)),
    table(client, record_info(fields, client), [{index, [nick]}]),
    table(channel, record_info(fields, channel), []),
    table(channel_history, record_info(fields, channel_history), []),
    table(channel_message, record_info(fields, channel_message), [{type, ordered_set}]),
    table(channel_meta, record_info(fields, channel_meta), []),
    table(activity, record_info(fields, activity), []),
    table(whowas, record_info(fields, whowas), []),
    table(user_modes, record_info(fields, user_modes), []),
    table(remote_client, record_info(fields, remote_client), []),
    table(remote_channel, record_info(fields, remote_channel), []),
    table(known_server, record_info(fields, known_server), []),
    table(service, record_info(fields, service), []),
    table(account, record_info(fields, account), []),
    table(read_marker, record_info(fields, read_marker), []),
    %% End-to-end encryption broker (briskd_e2ee): device bundles and the
    %% per-device offline queue, durable under every retention policy.
    table(e2ee_device, record_info(fields, e2ee_device), []),
    table(e2ee_queue, record_info(fields, e2ee_queue), [{type, ordered_set}]),
    table(direct_history, record_info(fields, direct_history), []),
    table(direct_message, record_info(fields, direct_message), [{type, ordered_set}]),
    %% Admin overrides of features (briskd_overrides), durable.
    table(setting, record_info(fields, setting), []),
    ok = mnesia:wait_for_tables(
        [
            setting,
            account,
            read_marker,
            e2ee_device,
            e2ee_queue,
            direct_history,
            direct_message,
            client,
            channel,
            channel_history,
            channel_message,
            channel_meta,
            activity,
            whowas,
            user_modes,
            remote_client,
            remote_channel,
            known_server,
            service
        ],
        5000
    ),
    %% The file's settings with the admin panel's overrides applied.
    briskd_config:store_base(Config),
    Effective = briskd_overrides:apply(Config, briskd_overrides:all()),
    briskd_config:store(Effective),
    ok = briskd_rehash:init(Effective),
    {atomic, ok} = mnesia:clear_table(client),
    reset_channels(),
    seed_channels(),
    {atomic, ok} = mnesia:clear_table(activity),
    {atomic, ok} = mnesia:clear_table(user_modes),
    {atomic, ok} = mnesia:clear_table(remote_client),
    {atomic, ok} = mnesia:clear_table(remote_channel),
    {atomic, ok} = mnesia:clear_table(known_server),
    {atomic, ok} = mnesia:clear_table(service),
    ok = briskd_account:init_indexes(),
    ok = briskd_population:init(),
    ok.

table(Table, Fields, Options) ->
    case mnesia:create_table(Table, [{attributes, Fields}, {storage(Table), [node()]} | Options]) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, Table}} ->
            ok = load_table(Table, Fields, Options),
            ensure_table_shape(Table, Fields),
            ensure_storage(Table)
    end.

%% Tables cleared on every start (sessions, presence, and imported peer
%% state) are kept in memory only: as disc_copies every write went through
%% the Mnesia transaction log, including the `activity` row written for
%% every client command, for data no restart keeps. Everything else (WHOWAS,
%% channels and their history, accounts, ...) stays on disk.
storage(Table) when
    Table =:= client;
    Table =:= activity;
    Table =:= user_modes;
    Table =:= remote_client;
    Table =:= remote_channel;
    Table =:= known_server;
    Table =:= service
->
    ram_copies;
storage(_Table) ->
    disc_copies.

%% An existing schema entry is not readable until its local copy is loaded.
load_table(Table, Fields, Options) ->
    case mnesia:force_load_table(Table) of
        yes ->
            ok;
        Error ->
            logger:warning("Replacing unloaded Mnesia table ~p after ~p", [Table, Error]),
            replace_table(Table, Fields, Options)
    end.

replace_table(Table, Fields, Options) ->
    case mnesia:delete_table(Table) of
        {atomic, ok} ->
            ok;
        {aborted, Reason} ->
            logger:warning("Mnesia delete_table ~p returned ~p", [Table, Reason])
    end,
    case mnesia:create_table(Table, [{attributes, Fields}, {storage(Table), [node()]} | Options]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Table}} -> ok
    end.

%% An existing table keeps the storage type it was created with: convert it
%% (transient tables written to disk by earlier releases become ram_copies).
ensure_storage(Table) ->
    Wanted = storage(Table),
    case mnesia:table_info(Table, storage_type) of
        Wanted ->
            ok;
        _ ->
            {atomic, ok} = mnesia:change_table_copy_type(Table, node(), Wanted),
            ok
    end.

%% Channel rows gain fields over time; every missing trailing field is
%% `undefined` (creator, opless_since, created).
ensure_table_shape(channel, Fields) ->
    case mnesia:table_info(channel, attributes) of
        Fields ->
            ok;
        OldFields ->
            Width = length(Fields) + 1,
            {atomic, ok} = mnesia:transform_table(
                channel,
                fun(Old) ->
                    List = tuple_to_list(Old),
                    list_to_tuple(List ++ lists:duplicate(Width - length(List), undefined))
                end,
                Fields
            ),
            logger:info("Migrated Mnesia channel table from ~p", [OldFields])
    end;
ensure_table_shape(client, Fields) ->
    case mnesia:table_info(client, attributes) of
        Fields ->
            ok;
        OldFields ->
            {atomic, ok} = mnesia:transform_table(
                client,
                fun(Old) -> list_to_tuple(tuple_to_list(Old) ++ [undefined]) end,
                Fields
            ),
            logger:info("Migrated Mnesia client table from ~p", [OldFields])
    end;
ensure_table_shape(account, Fields) ->
    migrate_appended(account, Fields, undefined);
ensure_table_shape(remote_channel, Fields) ->
    migrate_appended(remote_channel, Fields, #{});
ensure_table_shape(remote_client, Fields) ->
    migrate_appended(remote_client, Fields, undefined);
ensure_table_shape(e2ee_device, Fields) ->
    migrate_appended(e2ee_device, Fields, []);
ensure_table_shape(Table, Fields) ->
    case mnesia:table_info(Table, attributes) of
        Fields -> ok;
        OldFields -> logger:warning("Leaving Mnesia table ~p unchanged from ~p", [Table, OldFields])
    end.

%% Append missing record fields. New remote-channel fields default to a map.
%% A migrated remote client gets `server = undefined` and `hop = 1`.
migrate_appended(Table, Fields, Default) ->
    case attributes(Table) of
        Fields ->
            ok;
        OldFields when is_list(OldFields) ->
            Width = length(Fields) + 1,
            case
                mnesia:transform_table(
                    Table,
                    fun(Old) ->
                        List = tuple_to_list(Old),
                        Missing = Width - length(List),
                        Pads = pads(Table, Missing, Default),
                        list_to_tuple(List ++ Pads)
                    end,
                    Fields
                )
            of
                {atomic, ok} ->
                    logger:info("Migrated Mnesia ~p table from ~p", [Table, OldFields]);
                {aborted, Reason} ->
                    recreate_transient_table(Table, Fields, Reason)
            end;
        Other ->
            recreate_transient_table(Table, Fields, Other)
    end.

attributes(Table) ->
    try mnesia:table_info(Table, attributes) of
        Fields when is_list(Fields) -> Fields;
        Other -> Other
    catch
        exit:Reason -> Reason
    end.

%% Remote tables are cleared on startup, so a broken disc copy can be replaced.
recreate_transient_table(Table, Fields, Reason) ->
    logger:warning("Recreating transient Mnesia table ~p after ~p", [Table, Reason]),
    replace_table(Table, Fields, []).

pads(remote_client, Missing, _Default) when Missing >= 2 ->
    [undefined, 1 | lists:duplicate(Missing - 2, undefined)];
pads(_Table, Missing, Default) ->
    lists:duplicate(Missing, Default).

ensure_bag(Name) ->
    ensure_ets_opts(Name, [bag]).

ensure_ets(Name) ->
    ensure_ets_opts(Name, [set]).

ensure_ets_read(Name) ->
    ensure_ets_opts(Name, [set, {read_concurrency, true}]).

ensure_ets_write(Name) ->
    ensure_ets_opts(Name, [set, {write_concurrency, true}]).

ensure_bag_read(Name) ->
    ensure_ets_opts(Name, [bag, {read_concurrency, true}]).

ensure_ets_opts(Name, Opts) ->
    case ets:whereis(Name) of
        undefined ->
            _ = ets:new(Name, [named_table, public | Opts]),
            ok;
        _ ->
            true = ets:delete_all_objects(Name),
            ok
    end.

-doc """
Reset channel membership, metadata, and history according to `retention/0`
and repopulate safe-channel indexes.
""".
-spec reset_channels() -> ok.
reset_channels() ->
    case retention() of
        channels ->
            lists:foreach(
                fun(Key) ->
                    case mnesia:dirty_read(channel, Key) of
                        [#channel{} = Channel] ->
                            mnesia:dirty_write(cleared_membership(Channel));
                        [] ->
                            ok
                    end
                end,
                table_keys(channel)
            ),
            ok = briskd_state_history:init_storage(),
            lists:foreach(
                fun(Key) ->
                    case mnesia:dirty_read(channel, Key) of
                        [] -> briskd_state_history:delete_channel_history(Key);
                        [_] -> ok
                    end
                end,
                briskd_state_history:history_channels()
            ),
            ok;
        transient ->
            lists:foreach(
                fun(Key) ->
                    case mnesia:dirty_read(channel, Key) of
                        [#channel{name = <<$!, _/binary>>} = Channel] ->
                            mnesia:dirty_write(cleared_membership(Channel));
                        [_Channel] ->
                            mnesia:dirty_delete(channel, Key);
                        [] ->
                            ok
                    end
                end,
                table_keys(channel)
            ),
            {atomic, ok} = mnesia:clear_table(channel_history),
            {atomic, ok} = mnesia:clear_table(channel_message),
            {atomic, ok} = mnesia:clear_table(direct_history),
            {atomic, ok} = mnesia:clear_table(direct_message),
            ok = briskd_state_history:init_storage(),
            ok
    end,
    briskd_state_meta:restore_channels(),
    briskd_state_channel:index_safe_channels().

cleared_membership(Channel) ->
    Channel#channel{members = #{}, invited = [], opless_since = undefined}.

-doc """
Publish `OPER` credentials and the configured channel keys from `Config`
in `persistent_term`.
""".
-spec store_accounts(map()) -> ok.
store_accounts(Config) ->
    ok = briskd_oper:store_accounts(Config),
    persistent_term:put(
        {briskd_state, predefined_channels},
        [maps:get(key, Channel) || Channel <- maps:get(channels, Config, [])]
    ),
    ok.

-doc """
Create each channel from the JSON `channels` setting that has no row.
""".
-spec seed_channels() -> ok.
seed_channels() ->
    Config = briskd_config:current_or_empty(),
    lists:foreach(fun seed_channel/1, maps:get(channels, Config, [])).

seed_channel(#{
    key := Key, name := Name, topic := Topic, flags := Flags, limit := Limit, password := Password
}) ->
    case mnesia:dirty_read(channel, Key) of
        [_] ->
            ok;
        [] ->
            mnesia:dirty_write(#channel{
                key = Key,
                name = Name,
                topic = Topic,
                flags = Flags,
                lists = #{},
                members = #{},
                invited = [],
                limit = Limit,
                password = Password,
                creator = undefined,
                opless_since = undefined,
                created = erlang:system_time(second)
            }),
            briskd_population:on_channel_put(Key)
    end.

-doc """
Every key of the Mnesia table `Table`, typed by the table's record key.
""".
-spec table_keys
    (client | user_modes | activity) -> [pid()];
    (
        channel
        | channel_history
        | channel_meta
        | remote_channel
        | remote_client
        | known_server
        | service
        | account
        | setting
    ) -> [binary()];
    (read_marker) -> [{binary(), binary()}];
    (direct_history) -> [{dm_party(), dm_party()}].
table_keys(Table) ->
    stored_keys(mnesia:dirty_all_keys(Table)).

%% mnesia:dirty_all_keys/1 returns [term()]; the key type of each table is the
%% key field of its record (include/*.hrl), which table_keys/1 states.
-spec stored_keys([term()]) -> dynamic().
stored_keys(Keys) ->
    Keys.

-doc """
True when the folded channel key `Key` names a channel from the JSON
`channels` setting.
""".
-spec predefined_channel(binary()) -> boolean().
predefined_channel(Key) when is_binary(Key) ->
    lists:member(Key, persistent_term:get({briskd_state, predefined_channels}, [])).

-doc """
Configured `retention` policy (`channels` or `transient`).
""".
-spec retention() -> transient | channels.
retention() ->
    maps:get(retention, briskd_config:current(), channels).

-doc """
Longest accepted nickname in bytes: the `nicklen` setting, default 9 from
RFC 1459.
""".
-spec nicklen() -> pos_integer().
nicklen() ->
    maps:get(nicklen, briskd_config:current_or_empty(), 9).

-doc """
The `history_limit` setting (default 100): how many messages, and separately
how many events, are kept per channel or direct conversation.
""".
-spec history_limit() -> pos_integer().
history_limit() ->
    maps:get(history_limit, briskd_config:current(), 100).
