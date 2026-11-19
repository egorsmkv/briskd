-module(ircd_state).
-behaviour(gen_server).
-export([
    authenticate_server_link/2,
    command/3,
    command/4,
    command_as/5,
    ctl/1,
    input_too_long/1,
    connect/1,
    connect/2,
    tls_upgraded/1,
    find_nick/1,
    format_status/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    init/1,
    numeric/5,
    ready/1,
    registered/0,
    register_adjacent/3,
    remote_channel_flags/1,
    remote_user_visible_to_requester/3,
    server_burst/0,
    server_command/4,
    server_command/5,
    server_disconnect/1,
    start_link/1,
    user_modes/1,
    user_visible/2,
    history_limit/0,
    nicklen/0,
    retention/0,
    administrator/1,
    predefined_channel/1,
    store_accounts/1,
    seed_channels/0,
    verify_account/2,
    visible_member/3,
    wildcard_match/2
]).
-include("ircd_state.hrl").
-include("ircd_account.hrl").
-include("ircd_e2ee.hrl").

-moduledoc """
Single-writer owner of this server's IRC protocol state, and the entry point
that sessions and links call to apply commands.

`ircd_state` is a registered `gen_server`. Sessions (`m:ircd_session`) and
links (`m:ircd_link`) parse lines and call `command/4` or `server_command/5`;
this process applies the effect and writes replies straight to client
sockets through `m:ircd_state_send`. The `ircd_state_*` modules
(`m:ircd_state_client`, `m:ircd_state_channel`, `m:ircd_state_link`,
`m:ircd_state_net`, `m:ircd_state_v3`, `m:ircd_state_history`, and the
others) are libraries that run inside this process, so every protocol write
is serialized here and ordering per nick and channel is the order of calls.
Client commands follow RFC 2812 / RFC 1459, channel rules RFC 2811, and peer
messages RFC 2813; IRCv3 commands are dispatched to their own modules.

## Mnesia tables

`init/1` creates (or loads and migrates) these `disc_copies` tables:
`client`, `channel`, `channel_history`, `channel_meta`, `activity`, `whowas`,
`user_modes`, `remote_client`, `remote_channel`, `known_server`, `service`,
`account`, `read_marker`, `e2ee_device`, `e2ee_queue`, and `direct_history`.
On every start it clears `client`, `activity`, `user_modes`, and all imported
peer state (`remote_client`, `remote_channel`, `known_server`, `service`).
`whowas`, safe `!` channels (with their metadata), `account`, `read_marker`,
`e2ee_device`, and `e2ee_queue` always survive a restart. The JSON `retention`
setting decides the rest:

- `channels` (default): every channel row is kept with membership cleared,
  together with its history and metadata, plus direct-message history; history
  and metadata of channels that no longer exist are dropped.
- `transient`: ordinary channels, their metadata, and both history tables are
  deleted; safe channels and their metadata are kept with their membership
  cleared.

Configured `channels` entries are then created when no row exists. See
`docs/mnesia.md` for backup, restore, and migration.

## ETS tables and configuration

Named ETS tables are created (or emptied) at startup and are transient:
`ircd_caps` (negotiated capabilities, `m:ircd_cap`), `ircd_conn`
(per-connection IRCv3 state, `m:ircd_conn`), `ircd_nicks` (folded-nick
index), `ircd_safe_channels` (safe-channel short-name index), `ircd_monitor`
(MONITOR watcher bag), `ircd_chan_meta` and `ircd_remote_meta` (metadata),
`ircd_holds` (nick and channel holds after a split or nick change),
`ircd_admins`, `ircd_attached` (multiclient), `ircd_account_channels`
(account rejoin), `ircd_e2ee_bound` (bound E2EE devices), `ircd_flood`
(per-client flood token buckets and per-host `REGISTER` rate limits,
`m:ircd_flood`), `ircd_inbound_peers`, `ircd_outbound_ready`, and the
`ircd_command_stats` / `ircd_connection_stats` counters used by `STATS`.
Validated configuration, operator credentials, and link secrets are published
in `persistent_term` and replaced on `REHASH`.

## Timers and lifecycle

A `reop_tick` message every second reopens operatorless safe channels after
`reop_delay`, expires empty non-predefined channels after `empty_channel_ttl`,
and expires nick/channel holds, E2EE queues, `REGISTER` rate-limit windows,
and stale open peer batches. Each session is monitored when it connects; its
`'DOWN'` removes the client, its memberships, and its IRCv3, E2EE, and flood
state. `format_status/1` redacts secrets in `PASS`, `OPER`, `AUTHENTICATE`,
`REGISTER`, `VERIFY`, and `WEBIRC` commands.
""".

-doc """
Start and register the `ircd_state` process with the validated configuration
map from `m:ircd_config`. Called by `m:ircd_sup`.
""".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

-doc """
Register the calling session as a connected, unregistered client.

Same as `connect(Host, #{})`. `Host` is the peer address or resolved name.
""".
-spec connect(binary()) -> ok.
connect(Host) -> connect(Host, #{}).

-doc """
Register the calling session as a connected, unregistered client.

`Info` carries connection facts used for capability negotiation and SASL
EXTERNAL: `secure` (TLS) and `certfp` (lowercase hex SHA-256 of the client
certificate, if any). The caller is monitored, and a `client` and
`user_modes` row are written for it.
""".
-spec connect(binary(), map()) -> ok.
connect(Host, Info) -> gen_server:call(?MODULE, {connect, Host, Info}).

-doc """
Record that the calling session finished a `STARTTLS` handshake.

The `Info` keys update the connection facts. Because the offered capability
set changes (`tls` disappears, `sts` switches to its persistence value),
clients with `cap-notify` receive `CAP DEL` / `CAP NEW`.
""".
-spec tls_upgraded(map()) -> ok.
tls_upgraded(Info) -> gen_server:call(?MODULE, {tls_upgraded, Info}).

-doc """
Apply an untagged client command on behalf of the calling session.

Same as `command(Command, Params, Bytes, [])`.
""".
-spec command(binary(), [binary()], non_neg_integer()) -> ok | quit | starttls.
command(Command, Params, Bytes) -> command(Command, Params, Bytes, []).

-doc """
Apply a client command, with its IRCv3 message tags, on behalf of the calling
session.

`Params` are the parsed parameters and `Bytes` is the wire line size (counted
for `STATS m` and connection statistics). Replies are written directly to
the client; a `label` tag wraps them per labeled-response. Returns `quit`
when the session must close, `starttls` when it must start the TLS
handshake, and `ok` otherwise. Unregistered clients get 451 for commands
that need registration.
""".
-spec command(binary(), [binary()], non_neg_integer(), [{binary(), undefined | binary()}]) ->
    ok | quit | starttls.
command(Command, Params, Bytes, Tags) ->
    gen_server:call(?MODULE, {command, Command, Params, Bytes, Tags}).

-doc """
Apply a command from a secondary connection attached to `Primary`
(the opt-in multiclient feature).

The command runs as the primary client. Returns `quit` when the caller is
not attached to `Primary` or the primary is gone.
""".
-spec command_as(pid(), binary(), [binary()], non_neg_integer(), list()) -> ok | quit.
command_as(Primary, Command, Params, Bytes, Tags) ->
    gen_server:call(?MODULE, {command_as, Primary, Command, Params, Bytes, Tags}).

-doc """
Run an administrative control action from `m:ircd_ctl` inside the `ircd_state`
process so state writes stay serialized.
""".
-spec ctl(term()) -> term().
ctl(Action) ->
    gen_server:call(?MODULE, {ctl, Action}, 15000).

-doc """
Answer an over-long tagged line from the calling session with
`417 ERR_INPUTTOOLONG`, honouring its `label` tag. The line is not applied.
""".
-spec input_too_long([{binary(), undefined | binary()}]) -> ok.
input_too_long(Tags) -> gen_server:call(?MODULE, {input_too_long, Tags}).

-doc """
Return whether the calling session is registered: `NICK`, `USER`, and any
required `PASS` are accepted and the welcome has been sent (not held by
`CAP` negotiation).
""".
-spec registered() -> boolean().
registered() -> gen_server:call(?MODULE, registered).

-doc """
Return the RFC 2813 burst lines for a newly authenticated link: known
servers, local and remote users, IRCv3 account state, channels, synchronized
accounts, metadata, and read markers.
""".
-spec server_burst() -> [binary()].
server_burst() -> gen_server:call(?MODULE, server_burst).

-doc """
Record a directly connected peer after its `PASS`/`SERVER` handshake
succeeds. Writes a hop-1 `known_server` row and indexes the calling link
process under the folded name as an `inbound` or `outbound` peer.
""".
-spec register_adjacent(binary(), binary(), inbound | outbound) -> ok.
register_adjacent(Name, Token, Kind) ->
    gen_server:call(?MODULE, {register_adjacent, Name, Token, Kind}).

-doc """
Apply an untagged message received from the authenticated peer `Peer`.

Same as `server_command(Peer, Prefix, Command, Params, [])`.
""".
-spec server_command(binary(), undefined | binary(), binary(), [binary()]) -> ok | {error, term()}.
server_command(Peer, Prefix, Command, Params) ->
    server_command(Peer, Prefix, Command, Params, []).

-doc """
Apply a message received from the authenticated peer `Peer` (RFC 2813).

`Prefix` is the source prefix, or `undefined` when the line had none (the
link's own server is then the source). `Tags` are the client-only tags kept
for relay to local recipients. With `utf8_only` set, invalid UTF-8 in the
parameters is replaced by U+FFFD before delivery. Unknown commands are
ignored. Returns `{error, Reason}` when the message breaks link rules; the
caller then drops the link.
""".
-spec server_command(
    binary(), undefined | binary(), binary(), [binary()], [{binary(), undefined | binary()}]
) ->
    ok | {error, term()}.
server_command(Peer, Prefix, Command, Params, Tags) ->
    ircd_log:server_command(Peer, Command, Params),
    gen_server:call(?MODULE, {server_command, Peer, Prefix, Command, Params, Tags}).

-doc """
Treat the loss of the link to `Peer` as a netsplit: remove the users,
services, servers, and channel memberships reachable only through it and tell
the remaining peers.

A missing state process during shutdown is ignored. Other failures propagate.
""".
-spec server_disconnect(binary()) -> ok.
server_disconnect(Peer) ->
    try gen_server:call(?MODULE, {server_disconnect, Peer}) of
        ok -> ok
    catch
        exit:{noproc, _} -> ok;
        exit:shutdown -> ok;
        exit:{shutdown, _} -> ok
    end.

-doc """
Verify a pending account registration via the web verification link.
Returns `{ok, AccountName}` on success or `error` when invalid or expired.
""".
-spec verify_account(binary(), binary()) -> {ok, binary()} | error.
verify_account(Name, Code) when is_binary(Name), is_binary(Code) ->
    gen_server:call(?MODULE, {verify_account, Name, Code}, 5000).

-doc """
Check an inbound server's name (RFC 1459 folded) and shared password against
the configured `server_links`. The password comparison uses
`ircd_config:secret_match/2`. Runs in the caller's process.
""".
-spec authenticate_server_link(binary(), binary()) -> boolean().
authenticate_server_link(Name, Password) ->
    Links = persistent_term:get({?MODULE, server_links}, []),
    lists:any(
        fun(#{name := Expected, password := Secret}) ->
            ircd_wire:fold(Name) =:= ircd_wire:fold(Expected) andalso
                ircd_config:secret_match(Password, Secret)
        end,
        Links
    ).

-doc false.
-spec init(map()) -> {ok, binary()}.
init(#{name := Name} = Config) ->
    Started = calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}]),
    persistent_term:put({?MODULE, started}, Started),
    persistent_term:put({?MODULE, started_at}, erlang:monotonic_time(second)),
    persistent_term:put({?MODULE, started_at_system}, erlang:system_time(second)),
    ircd_command_stats = ets:new(ircd_command_stats, [
        named_table, public, set, {write_concurrency, true}
    ]),
    ircd_connection_stats = ets:new(ircd_connection_stats, [
        named_table, public, set, {write_concurrency, true}
    ]),
    ensure_ets(ircd_caps),
    ensure_ets(ircd_nicks),
    ensure_ets(ircd_inbound_peers),
    ensure_ets(ircd_outbound_ready),
    ensure_ets(ircd_holds),
    ensure_ets(ircd_admins),
    ensure_ets(ircd_conn),
    ensure_ets(ircd_chan_meta),
    ensure_bag(ircd_monitor),
    ensure_ets(ircd_attached),
    ensure_ets(ircd_account_channels),
    ensure_ets(ircd_remote_meta),
    ensure_ets(ircd_e2ee_bound),
    ensure_ets(ircd_safe_channels),
    ensure_ets(ircd_empty_channels),
    ok = ircd_flood:init(),
    persistent_term:put({?MODULE, config}, Config),
    persistent_term:put({?MODULE, config_path}, maps:get(config_path, Config)),
    persistent_term:put({?MODULE, motd_file}, maps:get(motd_file, Config, null)),
    persistent_term:put({?MODULE, client_password}, maps:get(client_password, Config, null)),
    persistent_term:put({?MODULE, server_links}, maps:get(server_links, Config, [])),
    persistent_term:put({?MODULE, admin}, maps:get(admin, Config, #{})),
    store_accounts(Config),
    persistent_term:put({?MODULE, reop_delay}, maps:get(reop_delay, Config, 30)),
    table(client, record_info(fields, client), [{index, [nick]}]),
    table(channel, record_info(fields, channel), []),
    table(channel_history, record_info(fields, channel_history), []),
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
    %% End-to-end encryption broker (ircd_e2ee): device bundles and the
    %% per-device offline queue, durable under every retention policy.
    table(e2ee_device, record_info(fields, e2ee_device), []),
    table(e2ee_queue, record_info(fields, e2ee_queue), [{type, ordered_set}]),
    table(direct_history, record_info(fields, direct_history), []),
    ok = mnesia:wait_for_tables(
        [
            account,
            read_marker,
            e2ee_device,
            e2ee_queue,
            direct_history,
            client,
            channel,
            channel_history,
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
    {atomic, ok} = mnesia:clear_table(client),
    reset_channels(),
    seed_channels(),
    {atomic, ok} = mnesia:clear_table(activity),
    {atomic, ok} = mnesia:clear_table(user_modes),
    {atomic, ok} = mnesia:clear_table(remote_client),
    {atomic, ok} = mnesia:clear_table(remote_channel),
    {atomic, ok} = mnesia:clear_table(known_server),
    {atomic, ok} = mnesia:clear_table(service),
    erlang:send_after(1000, self(), reop_tick),
    {ok, Name}.

table(Table, Fields, Options) ->
    case mnesia:create_table(Table, [{attributes, Fields}, {disc_copies, [node()]} | Options]) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, Table}} ->
            ok = load_table(Table, Fields, Options),
            ensure_table_shape(Table, Fields),
            ensure_disc_copy(Table)
    end.

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
    case mnesia:create_table(Table, [{attributes, Fields}, {disc_copies, [node()]} | Options]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Table}} -> ok
    end.

ensure_disc_copy(Table) ->
    case mnesia:table_info(Table, storage_type) of
        ram_copies ->
            {atomic, ok} = mnesia:change_table_copy_type(Table, node(), disc_copies),
            ok;
        disc_copies ->
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

-spec ensure_bag(atom()) -> ok.
ensure_bag(Name) ->
    case ets:whereis(Name) of
        undefined -> Name = ets:new(Name, [named_table, public, bag]);
        _ -> true = ets:delete_all_objects(Name)
    end,
    ok.

-spec ensure_ets(atom()) -> ok.
ensure_ets(Name) ->
    case ets:whereis(Name) of
        undefined -> Name = ets:new(Name, [named_table, public, set]);
        _ -> true = ets:delete_all_objects(Name)
    end,
    ok.

reset_channels() ->
    case retention() of
        channels ->
            lists:foreach(
                fun(Key) ->
                    case mnesia:dirty_read(channel, Key) of
                        [Channel] ->
                            mnesia:dirty_write(cleared_membership(Channel));
                        [] ->
                            ok
                    end
                end,
                mnesia:dirty_all_keys(channel)
            ),
            lists:foreach(
                fun(Key) ->
                    case mnesia:dirty_read(channel, Key) of
                        [] -> mnesia:dirty_delete(channel_history, Key);
                        [_] -> ok
                    end
                end,
                mnesia:dirty_all_keys(channel_history)
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
                mnesia:dirty_all_keys(channel)
            ),
            {atomic, ok} = mnesia:clear_table(channel_history),
            {atomic, ok} = mnesia:clear_table(direct_history),
            ok
    end,
    ircd_state_meta:restore_channels(),
    ircd_state_channel:index_safe_channels().

cleared_membership(Channel) ->
    Channel#channel{members = #{}, invited = [], opless_since = undefined}.

-doc """
Publish `OPER` credentials and the configured channel keys from `Config`
in `persistent_term`.

Administrator entries join the operator list so `OPER` and `STATS o` accept
them; their names are also stored separately so a successful `OPER` can be
told apart from an ordinary operator. Called at startup and by `REHASH`.
""".
-spec store_accounts(map()) -> ok.
store_accounts(Config) ->
    Operators = maps:get(operators, Config, []),
    Administrators = maps:get(administrators, Config, []),
    persistent_term:put({?MODULE, operators}, Operators ++ Administrators),
    persistent_term:put({?MODULE, administrators}, [Nick || {Nick, _} <- Administrators]),
    persistent_term:put(
        {?MODULE, predefined_channels},
        [maps:get(key, Channel) || Channel <- maps:get(channels, Config, [])]
    ),
    ok.

-doc """
Create each channel from the JSON `channels` setting that has no row.

An existing row, including one kept by `channels` retention, keeps its
topic, modes, key, and limit. Called at startup and by `REHASH`.
""".
-spec seed_channels() -> ok.
seed_channels() ->
    Config = persistent_term:get({?MODULE, config}, #{}),
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
            })
    end.

-doc """
True after the session `Pid` used `OPER` with an `administrators` entry.
Reads the `ircd_admins` ETS table; safe to call from any process.
""".
-spec administrator(pid()) -> boolean().
administrator(Pid) when is_pid(Pid) ->
    case ets:whereis(ircd_admins) of
        undefined -> false;
        _ -> ets:lookup(ircd_admins, Pid) =/= []
    end.

-doc """
True when the folded channel key `Key` names a channel from the JSON
`channels` setting. Such a channel is kept when its last member leaves.
""".
-spec predefined_channel(binary()) -> boolean().
predefined_channel(Key) when is_binary(Key) ->
    lists:member(Key, persistent_term:get({?MODULE, predefined_channels}, [])).

-doc """
Configured `retention` policy.

`channels` (default) keeps ordinary channels and message history across
restarts; `transient` deletes them at startup and when a channel empties. Both
clear client sessions and imported peer state.
""".
-spec retention() -> transient | channels.
retention() ->
    maps:get(retention, persistent_term:get({?MODULE, config}), channels).

-doc """
Longest accepted nickname in bytes: the `nicklen` setting, default 9 from
RFC 1459. Advertised as `NICKLEN` in RPL_ISUPPORT.
""".
-spec nicklen() -> pos_integer().
nicklen() ->
    maps:get(nicklen, persistent_term:get({?MODULE, config}, #{}), 9).

-doc """
The `history_limit` setting (default 100): how many messages, and separately
how many events, are kept per channel or direct conversation. Advertised as
`CHATHISTORY` in RPL_ISUPPORT.
""".
-spec history_limit() -> pos_integer().
history_limit() ->
    maps:get(history_limit, persistent_term:get({?MODULE, config}), 100).

-doc false.
handle_call({connect, Host}, From, Server) ->
    handle_call({connect, Host, #{}}, From, Server);
handle_call({connect, Host, Info}, {Pid, _}, Server) ->
    monitor(process, Pid),
    mnesia:dirty_write(#client{pid = Pid, host = ircd_wire:retain(Host)}),
    ircd_cap:connect(Pid, Info),
    ircd_state_client:touch_activity(Pid),
    ircd_state_client:put_connection_stats(Pid, #{}),
    mnesia:dirty_write(#user_modes{pid = Pid}),
    logger:info(#{event => client_connected, peer => Host}),
    {reply, ok, Server};
handle_call({tls_upgraded, Info}, {Pid, _}, Server) ->
    %% STARTTLS changes what is offered (`tls` goes away, `sts` switches to
    %% its persistence value): cap-notify clients get CAP DEL and CAP NEW.
    Before = #{Pid => ircd_cap:advertised(Pid)},
    maps:foreach(fun(Key, Value) -> ircd_cap:set_info(Pid, Key, Value) end, Info),
    ircd_state_net:notify_cap_changes(Before, Server),
    {reply, ok, Server};
handle_call(registered, {Pid, _}, Server) ->
    {reply, ircd_state_client:ready(ircd_state_client:client(Pid)), Server};
handle_call(server_burst, _, Server) ->
    {reply, ircd_state_link:server_burst_lines(Server), Server};
handle_call({register_adjacent, Name, Token, Kind}, {Pid, _}, Server) ->
    %% Both inbound sessions and outbound link workers register here, and
    %% ircd_state_net:register_adjacent/4 records the caller as {Pid, Name}.
    Result = ircd_state_net:register_adjacent(Name, Token, Kind, Pid),
    {reply, Result, Server};
handle_call({ctl, Action}, _From, Server) ->
    {reply, ircd_ctl:handle_state_action(Action, Server), Server};
handle_call({server_command, Peer, Prefix0, Command, Params, Tags}, From, Server) ->
    case burst_command(Command) of
        true -> ok;
        false -> ircd_state_link:flush_netjoin(Peer)
    end,
    %% RFC 2813 3.3: a line without a prefix comes from the link itself, so
    %% every handler below sees a binary source and never `undefined`.
    Prefix = link_source(Peer, Prefix0),
    ircd_state_send:set_source(ircd_state_v3:remote_source_info(Prefix)),
    %% UTF8ONLY: text from peers reaches local clients only as valid UTF-8;
    %% invalid bytes become U+FFFD.
    Safe =
        case maps:get(utf8_only, persistent_term:get({?MODULE, config}), false) of
            true -> [ircd_websocket:utf8_safe(P) || P <- Params];
            false -> Params
        end,
    try
        server_call({server_command, Peer, Prefix, Command, Safe, Tags}, From, Server)
    after
        ircd_state_send:clear_source()
    end;
handle_call(Request, From, Server) ->
    other_call(Request, From, Server).

%% Commands that may appear inside a peer's burst between NJOIN lines.
burst_command(Command) ->
    lists:member(Command, [
        <<"NJOIN">>,
        <<"NICK">>,
        <<"SERVER">>,
        <<"MODE">>,
        <<"SERVICE">>,
        <<"ACCOUNT">>,
        <<"ACCOUNTSYNC">>,
        <<"METADATA">>,
        <<"MARKREAD">>,
        <<"E2EE">>,
        <<"AWAY">>
    ]).

server_call({server_command, Peer, Prefix, <<"BATCH">>, Params, Tags}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_link:receive_remote_batch(Peer, Prefix, Params, Tags), Server};
server_call({server_command, Peer, Prefix, Command, Params, Tags}, _, Server) when
    is_binary(Prefix),
    (Command =:= <<"PRIVMSG">> orelse Command =:= <<"NOTICE">>),
    is_list(Tags),
    Tags =/= []
->
    case lists:keymember(<<"batch">>, 1, Tags) of
        true ->
            {reply, ircd_state_link:remote_batch_line(Peer, Prefix, Command, Params, Tags), Server};
        false ->
            other_call(
                {server_command, Peer, Prefix, Command, Params, Tags}, {self(), make_ref()}, Server
            )
    end;
server_call({server_command, Peer, Prefix, <<"ACCOUNT">>, Params, _Tags}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_v3:receive_remote_account(Peer, Prefix, Params), Server};
server_call({server_command, Peer, Prefix, <<"SETNAME">>, Params, _Tags}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_v3:receive_remote_setname(Peer, Prefix, Params), Server};
server_call({server_command, Peer, Prefix, <<"CHGHOST">>, Params, _Tags}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_v3:receive_remote_chghost(Peer, Prefix, Params), Server};
server_call({server_command, Peer, Prefix, <<"REDACT">>, Params, _Tags}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_history:receive_remote_redact(Peer, Prefix, Params), Server};
server_call({server_command, Peer, Prefix, <<"ACCOUNTSYNC">>, Params, _Tags}, _, Server) ->
    {reply, ircd_state_sync:receive_accountsync(Peer, link_source(Peer, Prefix), Params), Server};
server_call({server_command, Peer, Prefix, <<"METADATA">>, Params, _Tags}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_sync:receive_metadata(Peer, Prefix, Params), Server};
server_call({server_command, Peer, Prefix, <<"E2EE">>, Params, Tags}, _, Server) ->
    {reply, ircd_e2ee:receive_link(Peer, link_source(Peer, Prefix), Params, Tags), Server};
server_call({server_command, Peer, Prefix, <<"MARKREAD">>, Params, _Tags}, _, Server) ->
    {reply, ircd_state_sync:receive_markread(Peer, link_source(Peer, Prefix), Params), Server};
server_call(Request, From, Server) ->
    other_call(Request, From, Server).

other_call({server_command, Peer, Prefix, <<"NJOIN">>, [Name, Members]}, _, Server) ->
    case ircd_state_link:trusted_server(Peer, link_source(Peer, Prefix)) of
        true -> {reply, ircd_state_link:import_remote_njoin(Peer, Name, Members), Server};
        false -> {reply, {error, unknown_remote_source}, Server}
    end;
other_call({server_command, Peer, Prefix, <<"JOIN">>, [Name | _]}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_link:import_remote_join(Peer, Prefix, Name), Server};
other_call({server_command, Peer, Prefix, <<"PART">>, [Name | Rest]}, _, Server) when
    is_binary(Prefix)
->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    {reply, ircd_state_link:remove_remote_channel_member(Peer, Prefix, Name, Reason), Server};
other_call({server_command, Peer, Prefix, <<"TOPIC">>, [Name, Text]}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_link:update_remote_topic(Peer, Prefix, Name, Text), Server};
other_call({server_command, Peer, Prefix, <<"KICK">>, [Name, Nick | Rest]}, _, Server) when
    is_binary(Prefix)
->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    {reply, ircd_state_link:receive_remote_kick(Peer, Prefix, Name, Nick, Reason), Server};
other_call({server_command, Peer, Prefix, <<"NICK">>, [Nick]}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_link:rename_remote_nick(Peer, Prefix, Nick), Server};
other_call({server_command, Peer, Prefix, <<"QUIT">>, Params}, _, Server) when
    is_binary(Prefix)
->
    Reason =
        case Params of
            [Text | _] -> Text;
            [] -> <<"QUIT">>
        end,
    {reply, ircd_state_link:remove_remote_nick(Peer, Prefix, Reason), Server};
other_call({server_command, Peer, Prefix, <<"AWAY">>, Params}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_link:set_remote_away(Peer, Prefix, Params), Server};
other_call({server_command, Peer, Prefix, <<"NICK">>, Params}, _, Server) when
    is_binary(Prefix), length(Params) =:= 7
->
    {reply, ircd_state_link:import_remote_nick(Peer, Prefix, Params), Server};
other_call({server_command, Peer, Prefix, <<"MODE">>, [Name, Modes | Args]}, _, Server) ->
    {reply, ircd_state_link:update_remote_modes(Peer, Prefix, Name, Modes, Args), Server};
other_call({server_command, Peer, Prefix, Command, Params, Tags}, _, Server) when
    is_binary(Prefix),
    (Command =:= <<"PRIVMSG">> orelse Command =:= <<"NOTICE">> orelse Command =:= <<"TAGMSG">>)
->
    {reply, ircd_state_link:receive_remote_message(Peer, Prefix, Command, Params, Tags), Server};
other_call({server_command, Peer, Prefix, Command, Params, _Tags}, From, Server) ->
    other_call({server_command, Peer, Prefix, Command, Params}, From, Server);
other_call({server_command, Peer, Prefix, <<"SERVER">>, [Name, Hop, Token, Info | _]}, _, Server) ->
    {reply, ircd_state_net:introduce_server(Peer, Prefix, Name, Hop, Token, Info), Server};
other_call({server_command, Peer, _Prefix, <<"SQUIT">>, [Target | Rest]}, _, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> <<"SQUIT">>
        end,
    %% A peer may only split itself or a server it introduced (RFC 2813
    %% 4.1.6); any other target would let it remove servers it does not route.
    %% An unknown target is a stale SQUIT that crossed a split and is ignored.
    case behind_peer(Peer, Target) of
        true ->
            ircd_state_net:split(Target, Reason, Peer),
            {reply, ok, Server};
        unknown ->
            {reply, ok, Server};
        false ->
            logger:warning(#{event => squit_rejected, peer => Peer, target => Target}),
            {reply, {error, squit_not_behind_peer}, Server}
    end;
other_call({server_command, Peer, Prefix, <<"INVITE">>, [Nick, Name | _]}, _, Server) ->
    {reply, ircd_state_link:receive_remote_invite(Peer, Prefix, Nick, Name), Server};
other_call({server_command, Peer, Prefix, <<"SERVICE">>, Params}, _, Server) ->
    {reply, ircd_state_net:import_service(Peer, Prefix, Params), Server};
other_call({server_command, Peer, Prefix, <<"SQUERY">>, Params}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_net:remote_squery(Peer, Prefix, Params), Server};
other_call({server_command, Peer, Prefix, <<"KILL">>, [Nick | Rest]}, _, Server) ->
    Source = link_source(Peer, Prefix),
    case
        ircd_state_link:trusted_server(Peer, Source) orelse
            is_tuple(ircd_state_link:remote_source(Peer, Source))
    of
        true ->
            Reason =
                case Rest of
                    [Text | _] -> Text;
                    [] -> <<"KILL">>
                end,
            {reply, ircd_state_link:receive_remote_kill(Peer, Nick, Reason), Server};
        false ->
            {reply, {error, unknown_remote_source}, Server}
    end;
other_call({server_command, _Peer, _Prefix, _Command, _Params}, _, Server) ->
    {reply, ok, Server};
other_call({verify_account, Name, Code}, _, Server) ->
    {reply, ircd_state_v3:verify_account_web(Name, Code), Server};
other_call({server_disconnect, Peer}, _, Server) ->
    ircd_state_link:flush_netjoin(Peer),
    ircd_state_link:forget_peer_batches(Peer),
    ircd_state_net:split(Peer, <<"Netsplit ", Peer/binary>>, Peer),
    {reply, ok, Server};
other_call({input_too_long, Tags}, {Pid, _}, Server) ->
    Client = ircd_state_client:client(Pid),
    Label = ircd_cap:label(ircd_cap:state(Pid), Tags),
    ok = ircd_state_send:begin_label(Pid, Label),
    try
        ircd_state_send:numeric(Client, Server, <<"417">>, [], <<"Input line was too long">>)
    after
        ircd_state_send:end_label(Server)
    end,
    {reply, ok, Server};
other_call({command_as, Primary, Command, Params, Bytes, Tags}, {Caller, Ref}, Server) ->
    case ets:lookup(ircd_attached, Caller) of
        [{Caller, Primary}] ->
            case mnesia:dirty_read(client, Primary) of
                [_] -> other_call({command, Command, Params, Bytes, Tags}, {Primary, Ref}, Server);
                [] -> {reply, quit, Server}
            end;
        _ ->
            {reply, quit, Server}
    end;
other_call({command, Command, Params, Bytes, Tags}, {Pid, Ref}, Server) ->
    case mnesia:dirty_read(client, Pid) of
        [_] ->
            client_command(Command, Params, Bytes, Tags, {Pid, Ref}, Server);
        [] ->
            %% multiclient: finish_attach/2 dropped this connection's client
            %% row, but lines the session read before it saw {attach, Holder}
            %% still arrive as plain commands. Run them as the holder; a
            %% connection with no client row and no holder is closed.
            case ets:lookup(ircd_attached, Pid) of
                [{Pid, Holder}] ->
                    other_call(
                        {command_as, Holder, Command, Params, Bytes, Tags}, {Pid, Ref}, Server
                    );
                [] ->
                    {reply, quit, Server}
            end
    end.

client_command(Command, Params, Bytes, Tags, {Pid, _} = From, Server) ->
    count_command(Pid, Command, Bytes),
    Client = ircd_state_client:client(Pid),
    ircd_log:client_command(Client#client.nick, Command, Params),
    case
        ircd_flood:check_command(
            Pid, Command, Params, Tags, ircd_state_client:ready(Client)
        )
    of
        {flood, Category} ->
            logger:warning(#{
                event => flood_exceeded,
                nick => Client#client.nick,
                host => Client#client.host,
                category => Category
            }),
            ircd_state_send:send(
                Pid,
                Server,
                <<"ERROR">>,
                [],
                [<<"Closing Link: ">>, Client#client.host, <<" (Excess Flood)">>]
            ),
            ircd_state_client:disconnect(Client, <<"Excess Flood">>, Server),
            {reply, quit, Server};
        allow ->
            run_client_command(Command, Params, Tags, Client, From, Server)
    end.

run_client_command(Command, Params, Tags, #client{pid = Pid} = Client, From, Server) ->
    Label =
        case welcomed_cap_end(Client, Command, Params) of
            true -> undefined;
            false -> command_label(Pid, Command, Params, Tags)
        end,
    ok = ircd_state_send:begin_label(Pid, Label),
    ircd_state_send:set_source(ircd_state_v3:source_info(Client)),
    Reply =
        try
            dispatch(Command, Params, Client, Server, Tags)
        catch
            Class:Reason:Stack ->
                _ = ircd_deferred:take(),
                end_reply(Server),
                erlang:raise(Class, Reason, Stack)
        end,
    case ircd_deferred:take() of
        none ->
            end_reply(Server),
            case Reply of
                quit -> ok;
                _ -> ircd_state_client:touch_activity(Pid)
            end,
            {reply, Reply, Server};
        {Work, Then} ->
            %% Costly work (PBKDF2) runs in a worker; the reply follows when
            %% it finishes (ircd_deferred:resume/3 from handle_info 'DOWN').
            ircd_deferred:start(From, Pid, Work, Then, Server)
    end.

end_reply(Server) ->
    ircd_state_send:end_label(Server),
    ircd_state_send:clear_source().

%% `true` when Target is the adjacent Peer or a known server reached through
%% it, `false` for the local server or a server routed through another link,
%% and `unknown` for a name that is not a known server.
behind_peer(Peer, Target) ->
    Folded = ircd_wire:fold(Peer),
    Local = ircd_wire:fold(maps:get(name, persistent_term:get({?MODULE, config}))),
    case ircd_wire:fold(Target) of
        Folded ->
            true;
        Local ->
            false;
        Key ->
            case mnesia:dirty_read(known_server, Key) of
                [#known_server{adjacent = Adjacent}] -> ircd_wire:fold(Adjacent) =:= Folded;
                [] -> unknown
            end
    end.

%% A server message without a prefix comes from the link it arrived on
%% (RFC 2813 3.3), so relays name that server as the source.
link_source(Peer, undefined) -> Peer;
link_source(_Peer, Prefix) -> Prefix.

-doc false.
handle_cast(_, State) -> {noreply, State}.

-doc false.
handle_info({'DOWN', Ref, process, Pid, Reason}, State) ->
    case ircd_deferred:resume(Ref, Reason, State) of
        handled -> {noreply, State};
        not_ours -> session_down(Pid, State)
    end;
handle_info({flush_netjoin, Peer}, Server) ->
    ircd_state_link:flush_netjoin(Peer),
    {noreply, Server};
handle_info(reop_tick, Server) ->
    ircd_state_channel:reop_channels(Server),
    ok = ircd_state_net:expire_holds(),
    ok = ircd_e2ee:expire(),
    ok = ircd_flood:expire(),
    ok = ircd_state_link:expire_peer_batches(),
    erlang:send_after(1000, self(), reop_tick),
    {noreply, Server};
%% Ignore unknown messages. Session and worker DOWN, `reop_tick`, and
%% `flush_netjoin` are the only expected info events.
handle_info(_, State) ->
    {noreply, State}.

%% A session process ended: drop its attachment and client state.
session_down(Pid, State) ->
    ets:delete(ircd_attached, Pid),
    ok = ircd_e2ee:session_down(Pid),
    case mnesia:dirty_read(client, Pid) of
        [Client] -> ircd_state_client:disconnect(Client, <<"Connection closed">>, State);
        [] -> ok
    end,
    {noreply, State}.

-doc """
Redact secrets from status and crash reports.

Secrets in `PASS`, `OPER`, `AUTHENTICATE`, `REGISTER`, `VERIFY`, and `WEBIRC`
commands (including those sent through an attached `multiclient` session) are
replaced by `redacted` in the current message and in the `sys` log. Other
state is returned unchanged.
""".
-spec format_status(map()) -> map().
format_status(Status) ->
    maps:map(fun redact_status/2, Status).

redact_status(message, Message) ->
    redact_command(Message);
redact_status(log, Log) when is_list(Log) ->
    [redact_log_event(Event) || Event <- Log];
redact_status(_, Value) ->
    Value.

redact_log_event({Type, Message}) ->
    {Type, redact_command(Message)};
redact_log_event({Type, Message, Extra}) ->
    {Type, redact_command(Message), Extra};
redact_log_event(Event) ->
    Event.

redact_command({'$gen_call', From, Request}) ->
    {'$gen_call', From, redact_command(Request)};
redact_command({ctl, {create_account, Name, _Password, Email}}) ->
    {ctl, {create_account, Name, redacted, Email}};
redact_command({command_as, Primary, Command, Params, Bytes, Tags}) ->
    {command, _, Redacted, _, _} = redact_command({command, Command, Params, Bytes, Tags}),
    {command_as, Primary, Command, Redacted, Bytes, Tags};
redact_command({command, <<"PASS">>, [_Password | Rest], Bytes, Tags}) ->
    {command, <<"PASS">>, [redacted | Rest], Bytes, Tags};
redact_command({command, <<"PASS">>, [_Password | Rest], Bytes}) ->
    {command, <<"PASS">>, [redacted | Rest], Bytes};
redact_command({command, <<"OPER">>, [Name, _Password | Rest], Bytes, Tags}) ->
    {command, <<"OPER">>, [Name, redacted | Rest], Bytes, Tags};
redact_command({command, <<"OPER">>, [Name, _Password | Rest], Bytes}) ->
    {command, <<"OPER">>, [Name, redacted | Rest], Bytes};
redact_command({command, <<"AUTHENTICATE">>, [_ | _], Bytes, Tags}) ->
    {command, <<"AUTHENTICATE">>, [redacted], Bytes, Tags};
redact_command({command, <<"AUTHENTICATE">>, [_ | _], Bytes}) ->
    {command, <<"AUTHENTICATE">>, [redacted], Bytes};
redact_command({command, <<"REGISTER">>, [Account, Email, _Password | Rest], Bytes, Tags}) ->
    {command, <<"REGISTER">>, [Account, Email, redacted | Rest], Bytes, Tags};
redact_command({command, <<"REGISTER">>, [Account, Email, _Password | Rest], Bytes}) ->
    {command, <<"REGISTER">>, [Account, Email, redacted | Rest], Bytes};
redact_command({verify_account, Account, _Code}) ->
    {verify_account, Account, redacted};
redact_command({command, <<"VERIFY">>, [Account, _Code | Rest], Bytes, Tags}) ->
    {command, <<"VERIFY">>, [Account, redacted | Rest], Bytes, Tags};
redact_command({command, <<"VERIFY">>, [Account, _Code | Rest], Bytes}) ->
    {command, <<"VERIFY">>, [Account, redacted | Rest], Bytes};
redact_command({command, <<"WEBIRC">>, [_Password | Rest], Bytes, Tags}) ->
    {command, <<"WEBIRC">>, [redacted | Rest], Bytes, Tags};
redact_command({command, <<"WEBIRC">>, [_Password | Rest], Bytes}) ->
    {command, <<"WEBIRC">>, [redacted | Rest], Bytes};
redact_command(Message) ->
    Message.

%% Lines inside a client batch, and the opening BATCH, are answered when the
%% batch closes. The closing BATCH uses the label from the opening line.
command_label(_Pid, <<"BATCH">>, [<<"+", _/binary>> | _], _Tags) ->
    undefined;
command_label(Pid, <<"BATCH">>, [<<"-", _/binary>> | _], _Tags) ->
    case ircd_state_batch:label(Pid) of
        undefined -> undefined;
        Stored -> ircd_cap:label(ircd_cap:state(Pid), [{<<"label">>, Stored}])
    end;
command_label(Pid, Command, _Params, Tags) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>
->
    case lists:keymember(<<"batch">>, 1, Tags) of
        true -> undefined;
        false -> ircd_cap:label(ircd_cap:state(Pid), Tags)
    end;
command_label(Pid, _Command, _Params, Tags) ->
    ircd_cap:label(ircd_cap:state(Pid), Tags).

welcomed_cap_end(Client, <<"CAP">>, [<<"END">> | _]) ->
    ircd_cap:welcomed(Client#client.pid);
welcomed_cap_end(_, _, _) ->
    false.

%% UTF8ONLY: with `utf8_only` set, a command whose parameters are not valid
%% UTF-8 is rejected with `FAIL <command> INVALID_UTF8` and not applied, so
%% no non-UTF-8 text (messages, topics, realnames, reasons) is relayed.
%% Credentials are exempt because they are never relayed.
dispatch(Command, Params, Client, Server, Tags) ->
    case utf8_rejected(Command, Params) of
        true ->
            ircd_state_send:fail(
                Client#client.pid,
                Command,
                <<"INVALID_UTF8">>,
                [],
                <<"Message rejected, your IRC software MUST use UTF-8 encoding on this network">>
            );
        false ->
            dispatch_command(Command, Params, Client, Server, Tags)
    end.

utf8_rejected(Command, _Params) when
    Command =:= <<"PASS">>;
    Command =:= <<"OPER">>;
    Command =:= <<"AUTHENTICATE">>;
    Command =:= <<"REGISTER">>;
    Command =:= <<"WEBIRC">>
->
    false;
utf8_rejected(_Command, Params) ->
    maps:get(utf8_only, persistent_term:get({?MODULE, config}), false) andalso
        not lists:all(fun ircd_state_v3:valid_utf8/1, Params).

%% Route commands accepted before registration and enforce registration for the rest.
dispatch_command(<<"QUIT">>, Params, Client, Server, _Tags) ->
    Reason =
        case Params of
            [Text | _] -> Text;
            [] -> <<"Client quit">>
        end,
    %% RFC 2812 3.1.7: the server acknowledges QUIT with ERROR. The session
    %% flushes it before closing the socket.
    ircd_state_send:send(
        Client#client.pid,
        Server,
        <<"ERROR">>,
        [],
        [<<"Closing Link: ">>, Client#client.host, <<" (Quit: ">>, Reason, <<")">>]
    ),
    ircd_state_client:disconnect(Client, Reason, Server),
    quit;
dispatch_command(<<"PASS">>, Params, Client, Server, _Tags) ->
    ircd_state_client:pass(Params, Client, Server);
dispatch_command(<<"PING">>, [Token | _], Client, Server, _Tags) ->
    ircd_state_send:send(Client#client.pid, Server, <<"PONG">>, [Server], Token);
dispatch_command(<<"PING">>, [], Client, Server, _Tags) ->
    ircd_state_send:numeric(Client, Server, <<"409">>, [], <<"No origin specified">>);
dispatch_command(<<"PONG">>, _, _, _, _Tags) ->
    ok;
dispatch_command(<<"CAP">>, Params, Client, Server, _Tags) ->
    ircd_state_net:cap(Client, Server, Params);
dispatch_command(<<"STARTTLS">>, _Params, Client, Server, _Tags) ->
    ircd_state_v3:starttls(Client, Server);
dispatch_command(<<"AUTHENTICATE">>, Params, Client, Server, _Tags) ->
    ircd_state_v3:authenticate(Params, Client, Server);
dispatch_command(<<"REGISTER">>, Params, Client, Server, _Tags) ->
    ircd_state_v3:register(Params, Client, Server);
dispatch_command(<<"VERIFY">>, Params, Client, Server, _Tags) ->
    ircd_state_v3:verify(Params, Client, Server);
dispatch_command(<<"WEBIRC">>, Params, Client, Server, _Tags) ->
    ircd_state_v3:webirc(Params, Client, Server);
dispatch_command(<<"ISUPPORT">>, Params, Client, Server, _Tags) ->
    ircd_state_v3:isupport(Params, Client, Server);
dispatch_command(<<"AWAY">>, Params, Client, Server, Tags) ->
    case ircd_state_client:ready(Client) of
        true -> registered_command(<<"AWAY">>, Params, Client, Server, Tags);
        false -> ircd_state_v3:pre_away(Params, Client, Server)
    end;
dispatch_command(<<"METADATA">>, [<<"*">> | _] = Params, Client, Server, _Tags) ->
    ircd_state_meta:metadata(Params, Client, Server);
dispatch_command(<<"NICK">>, [Nick | _], Client, Server, _Tags) ->
    case ircd_state_net:nick_blocked(Nick) of
        true ->
            ircd_state_send:numeric(
                Client, Server, <<"437">>, [Nick], <<"Nick/channel is temporarily unavailable">>
            );
        false ->
            change_nick(Nick, Client, Server)
    end;
dispatch_command(<<"NICK">>, [], Client, Server, _Tags) ->
    ircd_state_send:numeric(Client, Server, <<"431">>, [], <<"No nickname given">>);
dispatch_command(<<"USER">>, [_, _, _, <<>>], #client{user = undefined} = Client, Server, _Tags) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"USER">>], <<"Not enough parameters">>);
dispatch_command(
    <<"USER">>, [User, Mode, _, Real], #client{user = undefined} = Client, Server, _Tags
) ->
    case
        {
            re:run(User, <<"^[A-Za-z0-9_.-]{1,32}$">>, [{capture, none}, dollar_endonly]),
            ircd_state_client:initial_user_modes(Mode)
        }
    of
        {match, {ok, Modes}} ->
            mnesia:dirty_write(#user_modes{pid = Client#client.pid, modes = Modes}),
            ircd_state_client:save_identity(
                Client, Client#client{user = User, real = Real}, Server
            );
        {nomatch, _} ->
            %% ERR_INVALIDUSERNAME (468)
            ircd_state_send:numeric(
                Client, Server, <<"468">>, [], <<"Your username is not valid">>
            );
        {_, error} ->
            ircd_state_send:numeric(
                Client, Server, <<"461">>, [<<"USER">>], <<"Invalid user mode mask">>
            )
    end;
dispatch_command(<<"USER">>, _, Client, Server, _Tags) ->
    case Client#client.user of
        undefined ->
            ircd_state_send:numeric(
                Client, Server, <<"461">>, [<<"USER">>], <<"Not enough parameters">>
            );
        _ ->
            ircd_state_send:numeric(Client, Server, <<"462">>, [], <<"You may not reregister">>)
    end;
dispatch_command(Command, Params, Client, Server, Tags) ->
    case ircd_state_client:ready(Client) of
        true ->
            registered_command(Command, Params, Client, Server, Tags);
        false ->
            ircd_state_send:numeric(Client, Server, <<"451">>, [], <<"You have not registered">>)
    end.

%% Implement commands that require a fully registered client.
registered_command(Command, Params, Client, Server, Tags) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>; Command =:= <<"TAGMSG">>
->
    case ircd_state_batch:in_batch({Command, Params, Tags}, Client) of
        true -> ok;
        false -> ircd_state_channel:deliver(Command, Params, Client, Server, Tags)
    end;
registered_command(<<"BATCH">>, Params, Client, Server, Tags) ->
    ircd_state_batch:batch(Params, Tags, Client, Server);
registered_command(Command, Params, Client, Server, _Tags) ->
    registered_command(Command, Params, Client, Server).

registered_command(<<"AWAY">>, [<<>> | _], #client{} = Client, Server) ->
    registered_command(<<"AWAY">>, [], Client, Server);
registered_command(<<"AWAY">>, [], #client{} = Client, Server) ->
    case Client#client.away of
        undefined ->
            ircd_state_send:numeric(
                Client, Server, <<"305">>, [], <<"You are no longer marked as being away">>
            );
        _ ->
            mnesia:dirty_write(Client#client{away = undefined}),
            ircd_state_link:propagate_away(Client, none),
            ircd_state_v3:notify(Client, <<"away-notify">>, <<"AWAY">>, [], none, false),
            ircd_state_send:numeric(
                Client, Server, <<"305">>, [], <<"You are no longer marked as being away">>
            )
    end,
    ok;
registered_command(<<"AWAY">>, [Raw | _], #client{} = Client, Server) ->
    Message =
        case Raw of
            <<"*">> -> <<"Away">>;
            _ -> Raw
        end,
    mnesia:dirty_write(Client#client{away = ircd_wire:retain(Message)}),
    ircd_state_link:propagate_away(Client, Message),
    ircd_state_v3:notify(Client, <<"away-notify">>, <<"AWAY">>, [], Message, false),
    ircd_state_send:numeric(
        Client, Server, <<"306">>, [], <<"You have been marked as being away">>
    ),
    ok;
registered_command(<<"JOIN">>, [<<"0">> | _], Client, _) ->
    lists:foreach(
        fun(Key) -> ircd_state_channel:leave(Key, Client, <<"PART">>, none, true) end,
        Client#client.channels
    );
registered_command(<<"JOIN">>, [Names | Rest], Client, Server) ->
    Keys =
        case Rest of
            [Passwords | _] -> binary:split(Passwords, <<",">>, [global]);
            [] -> []
        end,
    ircd_state_channel:join_channels(
        ircd_state_channel:split(Names), Keys, Client#client.pid, Server
    );
registered_command(<<"PART">>, [Names | Rest], Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    lists:foreach(
        fun(Name) ->
            Key = ircd_wire:fold(Name),
            Current = ircd_state_client:client(Client#client.pid),
            case {mnesia:dirty_read(channel, Key), lists:member(Key, Current#client.channels)} of
                {[], _} ->
                    ircd_state_send:numeric(
                        Current, Server, <<"403">>, [Name], <<"No such channel">>
                    );
                {_, false} ->
                    ircd_state_send:numeric(
                        Current, Server, <<"442">>, [Name], <<"You're not on that channel">>
                    );
                {_, true} ->
                    ircd_state_channel:leave(Key, Current, <<"PART">>, Reason, true)
            end
        end,
        ircd_state_channel:split(Names)
    );
registered_command(<<"KICK">>, [Name, Nicks | Rest], Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> Client#client.nick
        end,
    Channels = ircd_state_channel:split(Name),
    Targets = ircd_state_channel:split(Nicks),
    case {Channels, Targets} of
        {[Channel], [_ | _]} ->
            ircd_state_channel:kick(Channel, Targets, Reason, Client, Server);
        {ChannelList, TargetList} when
            length(ChannelList) =:= length(TargetList),
            length(ChannelList) > 1
        ->
            lists:foreach(
                fun({Channel, Target}) ->
                    ircd_state_channel:kick(Channel, [Target], Reason, Client, Server)
                end,
                lists:zip(ChannelList, TargetList)
            );
        _ ->
            ircd_state_send:numeric(
                Client, Server, <<"461">>, [<<"KICK">>], <<"Invalid channel/user list">>
            )
    end;
registered_command(<<"KICK">>, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"KICK">>], <<"Not enough parameters">>);
registered_command(<<"SETNAME">>, Params, Client, Server) ->
    ircd_state_v3:setname(Params, Client, Server);
registered_command(<<"CHGHOST">>, Params, Client, Server) ->
    ircd_state_v3:chghost(Params, Client, Server);
registered_command(<<"MONITOR">>, Params, Client, Server) ->
    ircd_state_monitor:monitor(Params, Client, Server);
registered_command(<<"CHATHISTORY">>, Params, Client, Server) ->
    ircd_state_history:chathistory(Params, Client, Server);
registered_command(<<"MARKREAD">>, Params, Client, Server) ->
    ircd_state_history:markread(Params, Client, Server);
registered_command(<<"REDACT">>, Params, Client, Server) ->
    ircd_state_history:redact(Params, Client, Server);
registered_command(<<"E2EE">>, Params, Client, Server) ->
    case ircd_e2ee:enabled() of
        true ->
            ircd_e2ee:command(Params, Client, Server);
        false ->
            ircd_state_send:numeric(Client, Server, <<"421">>, [<<"E2EE">>], <<"Unknown command">>)
    end;
registered_command(<<"METADATA">>, Params, Client, Server) ->
    ircd_state_meta:metadata(Params, Client, Server);
registered_command(<<"RENAME">>, Params, Client, Server) ->
    ircd_state_channel:rename(Params, Client, Server);
registered_command(<<"KNOCK">>, [Name | Rest], Client, Server) ->
    ircd_state_channel:knock(Name, Rest, Client, Server);
registered_command(<<"KNOCK">>, [], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"KNOCK">>], <<"Not enough parameters">>);
registered_command(<<"INVITE">>, [<<C, _/binary>> = Name, Nick | _], Client, Server) when
    C =:= $#
->
    %% `INVITE <channel> <nick>` (parameters reversed; a `#` never starts a
    %% nickname, so this is unambiguous). An existing channel is handled as
    %% the RFC order; for a channel that does not exist, which RFC 1459/2812
    %% allow, both users see the INVITE in the order the client used.
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [_] ->
            ircd_state_channel:invite(Nick, Name, Client, Server);
        [] ->
            case ircd_state_client:find_nick(Nick) of
                #client{pid = Target} = Found ->
                    case ircd_state_client:ready(Found) of
                        true ->
                            Prefix = ircd_state_send:prefix(Client),
                            ircd_state_send:send(
                                Client#client.pid, Prefix, <<"INVITE">>, [Name, Nick], none
                            ),
                            ircd_state_send:send(Target, Prefix, <<"INVITE">>, [Name, Nick], none);
                        false ->
                            ircd_state_send:numeric(
                                Client, Server, <<"401">>, [Nick], <<"No such nick">>
                            )
                    end;
                undefined ->
                    ircd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>)
            end
    end;
registered_command(<<"INVITE">>, [Nick, Name | _], Client, Server) ->
    ircd_state_channel:invite(Nick, Name, Client, Server);
registered_command(<<"INVITE">>, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"INVITE">>], <<"Not enough parameters">>);
registered_command(<<"MODE">>, [Target | Rest], Client, Server) ->
    ircd_state_channel:mode_command(Target, Rest, Client, Server);
registered_command(<<"OPER">>, [Name, Password | _], Client, Server) ->
    ircd_state_info:oper(Name, Password, Client, Server);
registered_command(<<"OPER">>, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"OPER">>], <<"Not enough parameters">>);
registered_command(<<"KILL">>, Params, Client, Server) ->
    ircd_state_info:kill(Params, Client, Server);
registered_command(<<"CONNECT">>, Params, Client, Server) ->
    ircd_state_net:oper_command(<<"CONNECT">>, Params, Client, Server);
registered_command(<<"SQUIT">>, Params, Client, Server) ->
    ircd_state_net:oper_command(<<"SQUIT">>, Params, Client, Server);
registered_command(<<"DIE">>, Params, Client, Server) ->
    ircd_state_net:oper_command(<<"DIE">>, Params, Client, Server);
registered_command(<<"RESTART">>, Params, Client, Server) ->
    ircd_state_net:oper_command(<<"RESTART">>, Params, Client, Server);
registered_command(<<"SERVICE">>, Params, Client, Server) ->
    ircd_state_net:oper_command(<<"SERVICE">>, Params, Client, Server);
registered_command(<<"WALLOPS">>, [Text | _], #client{pid = Pid} = Client, Server) ->
    %% RFC 2812 3.7.1: an operator's WALLOPS goes to users with mode +w.
    case maps:is_key($o, ircd_state_client:user_modes(Pid)) of
        true ->
            Recipients = [
                P
             || P <- mnesia:dirty_all_keys(user_modes),
                [#client{} = C] <- [mnesia:dirty_read(client, P)],
                ircd_state_client:ready(C),
                maps:is_key($w, ircd_state_client:user_modes(P))
            ],
            ircd_state_send:broadcast(
                Recipients, ircd_state_send:prefix(Client), <<"WALLOPS">>, [], Text
            ),
            ircd_state_link:server_broadcast(
                ircd_wire:line(ircd_state_send:prefix(Client), <<"WALLOPS">>, [], Text)
            );
        false ->
            ircd_state_send:numeric(
                Client,
                Server,
                <<"481">>,
                [],
                <<"Permission Denied- You're not an IRC operator">>
            )
    end;
registered_command(<<"WALLOPS">>, [], Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"WALLOPS">>], <<"Not enough parameters">>
    );
registered_command(<<"REHASH">>, _, Client, Server) ->
    ircd_state_info:rehash(Client, Server);
registered_command(<<"SUMMON">>, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"445">>, [], <<"SUMMON has been disabled">>);
registered_command(<<"USERS">>, Params, Client, Server) ->
    ircd_state_info:users_disabled(Params, Client, Server);
registered_command(<<"TOPIC">>, [Name | Rest], Client, Server) ->
    ircd_state_channel:topic(Name, Rest, Client, Server);
registered_command(<<"NAMES">>, Params, Client, Server) ->
    case Params of
        [Names | _] ->
            lists:foreach(
                fun(Name) -> ircd_state_channel:names(Name, Client, Server) end,
                ircd_state_channel:split(Names)
            );
        [] ->
            %% Channels oldest first (then by name), so the listing is stable.
            Ordered = lists:sort([
                {Created, Key}
             || Key <- mnesia:dirty_all_keys(channel),
                [#channel{created = Created}] <- [mnesia:dirty_read(channel, Key)]
            ]),
            lists:foreach(
                fun({_, Key}) -> ircd_state_channel:names_listing(Key, Client, Server) end,
                Ordered
            ),
            LocalKeys = mnesia:dirty_all_keys(channel),
            lists:foreach(
                fun(Key) ->
                    case lists:member(Key, LocalKeys) of
                        true -> ok;
                        false -> ircd_state_link:remote_names_listing(Key, Client, Server)
                    end
                end,
                mnesia:dirty_all_keys(remote_channel)
            ),
            ircd_state_channel:names_unattached(Client, Server),
            ircd_state_send:numeric(Client, Server, <<"366">>, [<<"*">>], <<"End of NAMES list">>)
    end;
registered_command(<<"LIST">>, Params, Client, Server) ->
    Keys =
        case Params of
            [Names | _] -> [ircd_wire:fold(Name) || Name <- ircd_state_channel:split(Names)];
            [] -> mnesia:dirty_all_keys(channel)
        end,
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{name = Name, topic = Topic, members = Members, flags = Flags}] ->
                    Visible =
                        maps:is_key(Client#client.pid, Members) orelse
                            not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags)),
                    case Visible of
                        true ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"322">>,
                                [Name, integer_to_binary(map_size(Members))],
                                Topic
                            );
                        false ->
                            ok
                    end;
                [] ->
                    ok
            end
        end,
        Keys
    ),
    ircd_state_send:numeric(Client, Server, <<"323">>, [], <<"End of LIST">>);
registered_command(<<"TIME">>, Params, Client, Server) ->
    case ircd_state_info:query_local_server(Params, Server) of
        true ->
            ircd_state_send:numeric(
                Client,
                Server,
                <<"391">>,
                [Server],
                calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}])
            );
        {false, Target} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end;
registered_command(<<"TRACE">>, Params, Client, Server) ->
    ircd_state_info:trace(Params, Client, Server);
registered_command(<<"STATS">>, Params, Client, Server) ->
    ircd_state_info:stats(Params, Client, Server);
registered_command(<<"SERVLIST">>, Params, Client, Server) ->
    {Mask, Type} =
        case Params of
            [GivenMask, GivenType | _] -> {GivenMask, GivenType};
            [GivenMask] -> {GivenMask, <<"*">>};
            [] -> {<<"*">>, <<"*">>}
        end,
    ircd_state_net:servlist(Mask, Type, Client, Server);
registered_command(<<"SQUERY">>, Params, Client, Server) ->
    ircd_state_net:squery(Params, Client, Server);
registered_command(<<"VERSION">>, Params, Client, Server) ->
    case ircd_state_info:query_local_server(Params, Server) of
        true ->
            ircd_state_send:numeric(
                Client, Server, <<"351">>, [<<"0.1.0">>, Server], <<"Erlang/OTP IRC server">>
            );
        {false, Target} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end;
registered_command(<<"INFO">>, Params, Client, Server) ->
    ircd_state_info:info(Params, Client, Server);
registered_command(<<"ADMIN">>, Params, Client, Server) ->
    ircd_state_info:admin(Params, Client, Server);
registered_command(<<"LINKS">>, Params, Client, Server) ->
    ircd_state_info:links(Params, Client, Server);
registered_command(<<"LUSERS">>, Params, Client, Server) ->
    ircd_state_info:lusers(Params, Client, Server);
registered_command(<<"ISON">>, [], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"ISON">>], <<"Not enough parameters">>);
registered_command(<<"ISON">>, [<<>> | _], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"ISON">>], <<"Not enough parameters">>);
registered_command(<<"ISON">>, Nicks, Client, Server) ->
    ircd_state_queries:ison(Nicks, Client, Server);
registered_command(<<"USERHOST">>, [], Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"USERHOST">>], <<"Not enough parameters">>
    );
registered_command(<<"USERHOST">>, Nicks, Client, Server) ->
    ircd_state_queries:userhost(Nicks, Client, Server);
registered_command(<<"WHO">>, Params, Client, Server) ->
    ircd_state_queries:who(Params, Client, Server);
registered_command(<<"WHOIS">>, [_ | _] = Args, Client, Server) ->
    case Args of
        [NickMasks] ->
            lists:foreach(
                fun(Nick) -> ircd_state_queries:whois(Nick, Client, Server) end,
                ircd_state_channel:split(NickMasks)
            );
        [Target, NickMasks | _] ->
            %% RFC 2812 3.6.2: the target may also be a nickname, meaning the
            %% server that user is on; this server answers for every user it knows.
            KnownNick =
                ircd_state_client:find_nick(Target) =/= undefined orelse
                    mnesia:dirty_read(remote_client, ircd_wire:fold(Target)) =/= [],
            case KnownNick orelse ircd_state_info:query_local_server([Target], Server) of
                true ->
                    lists:foreach(
                        fun(Nick) -> ircd_state_queries:whois(Nick, Client, Server) end,
                        ircd_state_channel:split(NickMasks)
                    );
                {false, Unknown} ->
                    ircd_state_send:numeric(
                        Client, Server, <<"402">>, [Unknown], <<"No such server">>
                    )
            end
    end;
registered_command(<<"WHOWAS">>, [], Client, Server) ->
    %% RFC 1459/2812: RPL_ENDOFWHOWAS ends every reply, even an error.
    ircd_state_send:numeric(Client, Server, <<"431">>, [], <<"No nickname given">>),
    ircd_state_send:numeric(Client, Server, <<"369">>, [<<"*">>], <<"End of WHOWAS">>);
registered_command(<<"WHOWAS">>, [NickMasks | Rest], Client, Server) ->
    {Count, Target} = ircd_state_queries:whowas_options(Rest),
    case
        ircd_state_info:query_local_server(
            case Target of
                undefined -> [];
                _ -> [Target]
            end,
            Server
        )
    of
        {false, Unknown} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Unknown], <<"No such server">>);
        true ->
            Nicks = ircd_state_channel:split(NickMasks),
            Matched = lists:append([
                ircd_state_queries:whowas_reply(Nick, Count, Client, Server)
             || Nick <- Nicks
            ]),
            %% A mask that resolved to exactly one nickname ends with that
            %% nickname; otherwise the query as given.
            EndParam =
                case lists:usort([ircd_wire:fold(N) || N <- Matched]) of
                    [_] when length(Nicks) =:= 1 -> hd(Matched);
                    _ -> NickMasks
                end,
            ircd_state_send:numeric(Client, Server, <<"369">>, [EndParam], <<"End of WHOWAS">>)
    end;
registered_command(<<"MOTD">>, Params, Client, Server) ->
    ircd_state_info:motd(Params, Client, Server);
registered_command(Command, [], Client, Server) when
    Command =:= <<"JOIN">>;
    Command =:= <<"PART">>;
    Command =:= <<"TOPIC">>;
    Command =:= <<"WHOIS">>;
    Command =:= <<"MODE">>;
    Command =:= <<"KICK">>
->
    ircd_state_send:numeric(Client, Server, <<"461">>, [Command], <<"Not enough parameters">>);
registered_command(Command, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"421">>, [Command], <<"Unknown command">>).

change_nick(Nick, Client, Server) ->
    case
        {
            ircd_wire:nickname(Nick, ircd_state:nicklen()),
            ircd_wire:fold(Nick),
            ircd_state_client:find_nick(Nick),
            ircd_state_link:remote_nick_exists(Nick)
        }
    of
        {_, <<"anonymous">>, _, _} ->
            ircd_state_send:numeric(Client, Server, <<"432">>, [Nick], <<"Erroneous nickname">>);
        {false, _, _, _} ->
            ircd_state_send:numeric(Client, Server, <<"432">>, [Nick], <<"Erroneous nickname">>);
        {true, _, #client{pid = Holder} = HolderClient, _} when Holder =/= Client#client.pid ->
            case ircd_state_v3:attachable(Client, HolderClient) of
                true ->
                    ircd_state_v3:prepare_attach(Client, HolderClient, Nick);
                false ->
                    nick_in_use(Client, Nick, Server)
            end;
        {true, _, _, true} ->
            nick_in_use(Client, Nick, Server);
        {true, _, _, false} when Nick =:= Client#client.nick ->
            ok;
        {true, _, _, false} ->
            case ircd_state_client:ready(Client) of
                true ->
                    {NickTags, NickMeta} = ircd_state_history:event_tags(),
                    ircd_state_send:broadcast(
                        ircd_state_channel:nick_recipients(Client),
                        ircd_state_send:prefix(Client),
                        <<"NICK">>,
                        [],
                        Nick,
                        NickTags
                    ),
                    ircd_state_link:propagate_nick_change(Client, Nick),
                    ircd_state_history:note_user_event(
                        Client#client.channels,
                        <<"NICK">>,
                        ircd_state_send:prefix(Client),
                        Nick,
                        NickMeta
                    );
                false ->
                    ok
            end,
            case ircd_state_client:ready(Client) andalso Client#client.nick =/= <<"*">> of
                true -> ircd_state_net:hold_nick(Client#client.nick);
                false -> ok
            end,
            ircd_state_client:save_identity(Client, Client#client{nick = Nick}, Server),
            CaseOnly = ircd_wire:fold(Client#client.nick) =:= ircd_wire:fold(Nick),
            case ircd_state_client:ready(Client) andalso not CaseOnly of
                true ->
                    Renamed = ircd_state_client:client(Client#client.pid),
                    ircd_state_monitor:offline(Client#client.nick),
                    ircd_state_monitor:online(
                        Nick, iolist_to_binary(ircd_state_send:prefix(Renamed))
                    );
                false ->
                    ok
            end
    end.

nick_in_use(Client, Nick, Server) ->
    remember_wanted_nick(Client, Nick),
    ircd_state_send:numeric(
        Client, Server, <<"433">>, [Nick], <<"Nickname is already in use">>
    ).

%% Before registration, a refused NICK is remembered so `REGISTER *` can name
%% the nickname the client asked for (draft/account-registration).
remember_wanted_nick(#client{pid = Pid, nick = <<"*">>}, Nick) ->
    ircd_conn:put(Pid, wanted_nick, ircd_wire:retain(Nick));
remember_wanted_nick(_Client, _Nick) ->
    ok.

count_command(Pid, Command, MessageBytes) ->
    case supported_command(Command) of
        true ->
            _ = ets:update_counter(
                ircd_command_stats,
                Command,
                [{2, 1}, {3, MessageBytes}],
                {Command, 0, 0}
            ),
            ok;
        false ->
            ok
    end,
    ircd_state_client:update_connection_stats(Pid, recv_messages, recv_bytes, MessageBytes).

supported_command(Command) ->
    lists:member(
        Command,
        [
            <<"ADMIN">>,
            <<"AUTHENTICATE">>,
            <<"AWAY">>,
            <<"BATCH">>,
            <<"CAP">>,
            <<"CHATHISTORY">>,
            <<"CHGHOST">>,
            <<"E2EE">>,
            <<"ISUPPORT">>,
            <<"MARKREAD">>,
            <<"METADATA">>,
            <<"MONITOR">>,
            <<"REDACT">>,
            <<"REGISTER">>,
            <<"RENAME">>,
            <<"SETNAME">>,
            <<"STARTTLS">>,
            <<"VERIFY">>,
            <<"WEBIRC">>,
            <<"CONNECT">>,
            <<"DIE">>,
            <<"INVITE">>,
            <<"INFO">>,
            <<"ISON">>,
            <<"JOIN">>,
            <<"KICK">>,
            <<"KILL">>,
            <<"LINKS">>,
            <<"LIST">>,
            <<"LUSERS">>,
            <<"MODE">>,
            <<"MOTD">>,
            <<"NAMES">>,
            <<"NICK">>,
            <<"OPER">>,
            <<"PART">>,
            <<"PING">>,
            <<"PONG">>,
            <<"PRIVMSG">>,
            <<"QUIT">>,
            <<"REHASH">>,
            <<"RESTART">>,
            <<"SERVICE">>,
            <<"SERVLIST">>,
            <<"SQUERY">>,
            <<"SQUIT">>,
            <<"STATS">>,
            <<"SUMMON">>,
            <<"TAGMSG">>,
            <<"TIME">>,
            <<"TOPIC">>,
            <<"TRACE">>,
            <<"USER">>,
            <<"USERHOST">>,
            <<"USERS">>,
            <<"VERSION">>,
            <<"WHO">>,
            <<"WHOIS">>,
            <<"WHOWAS">>,
            <<"WALLOPS">>,
            <<"NOTICE">>,
            <<"PASS">>,
            <<"KNOCK">>
        ]
    ).

%% Public lookups and replies used by query handlers. The implementations
%% live with the state they read.
-doc """
Find a local client by nickname under the RFC 1459 case mapping
(`ircd_wire:fold/1`). Returns `undefined` when no local client has it.
""".
-spec find_nick(binary()) -> undefined | #client{}.
find_nick(A0) -> ircd_state_client:find_nick(A0).

-doc """
True when the client is registered and its welcome has been sent. While
`CAP` negotiation holds the welcome the client is not ready.
""".
-spec ready(#client{}) -> boolean().
ready(A0) -> ircd_state_client:ready(A0).

-doc """
User modes of the local client with pid `Pid`, as a set of mode characters.
""".
-spec user_modes(term()) -> #{char() => true}.
user_modes(A0) -> ircd_state_client:user_modes(A0).

-doc """
True when `Requester` may see `Target` in queries: the target is the
requester, or it is registered and either not `+i` or shares a channel with
the requester.
""".
-spec user_visible(#client{}, #client{}) -> boolean().
user_visible(A0, A1) -> ircd_state_client:user_visible(A0, A1).

-doc """
True when the channel member `Pid` is visible to `Requester`: the requester
is in `Members` (the channel's member map), or `user_visible/2` holds.
""".
-spec visible_member(term(), #client{}, map()) -> boolean().
visible_member(A0, A1, A2) -> ircd_state_channel:visible_member(A0, A1, A2).

-doc """
Match an IRC mask (`*`, `?`) against a value under the RFC 1459 case
mapping. See `ircd_state_channel:wildcard_match/2`.
""".
-spec wildcard_match(binary(), binary()) -> boolean().
wildcard_match(A0, A1) -> ircd_state_channel:wildcard_match(A0, A1).

-doc """
Mode flags of the imported remote channel `Name`, or `#{}` when no peer
reported it.
""".
-spec remote_channel_flags(binary()) -> #{atom() | char() => term()}.
remote_channel_flags(A0) -> ircd_state_link:remote_channel_flags(A0).

-doc """
True when a remote user (folded nick key and user modes) is visible to the
local `Requester`: it is not `+i`, or it shares a channel with the requester.
""".
-spec remote_user_visible_to_requester(term(), map(), term()) -> boolean().
remote_user_visible_to_requester(A0, A1, A2) ->
    ircd_state_link:remote_user_visible_to_requester(A0, A1, A2).

-doc """
Send a numeric reply to a local client. See `ircd_state_send:numeric/5`.
""".
-spec numeric(#client{}, term(), term(), term(), term()) -> ok.
numeric(A0, A1, A2, A3, A4) -> ircd_state_send:numeric(A0, A1, A2, A3, A4).
