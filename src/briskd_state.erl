-module(briskd_state).
-behaviour(gen_server).
%% Interval of the `sweep_tick` that removes state nothing else removes
%% (memberless `remote_channel` rows), in milliseconds.
-define(SWEEP_MS, 60000).
%% How long a session waits for its command to be applied, in milliseconds.
%% A session sends one command at a time and stops reading its socket until
%% the reply, so a slow state process slows clients down (TCP backpressure)
%% instead of queueing their input. The gen_server default of 5 seconds was
%% shorter than the queueing delay of a large burst (bench/traffic.py high
%% load), and every session that waited longer crashed, disconnecting its
%% client and adding cleanup work to the overloaded process. Past this
%% deadline the session closes with "Server overloaded" (briskd_session).
%% Server links use the same deadline, so a busy moment does not split them.
-define(COMMAND_TIMEOUT, 60000).
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
    server_commands/2,
    peer_command/1,
    server_disconnect/1,
    start_link/1,
    user_modes/1,
    user_visible/2,
    history_limit/0,
    nicklen/0,
    retention/0,
    administrator/1,
    predefined_channel/1,
    set_control/2,
    reset_control/1,
    controls/0,
    table_keys/1,
    store_accounts/1,
    seed_channels/0,
    signup_account/4,
    verify_account/2,
    verify_account_by_email/2,
    request_password_reset/3,
    complete_password_reset/4,
    visible_member/3,
    wildcard_match/2
]).
-include("briskd_state.hrl").
-include("briskd_account.hrl").

-moduledoc """
Single-writer owner of this server's IRC protocol state, and the entry point
that sessions and links call to apply commands.

`briskd_state` is a registered `gen_server`. Sessions (`m:briskd_session`) and
links (`m:briskd_link`) parse lines and call `command/4` or `server_command/5`;
this process serializes mutations and delegates implementation details to
focused helper modules:

- `m:briskd_state_schema`: Mnesia schema bootstrap, migrations, ETS setup, and
  channel seeding.
- `m:briskd_state_dispatch`: client command admission, flood limits,
  labeled-response wrapping, and command routing.
- `m:briskd_state_peer`: RFC 2813 server-link routing, line batches, and peer
  disconnect/DOWN handling.
- `m:briskd_state_redact`: OTP `format_status/1` secret redaction.
- `m:briskd_state_client`, `m:briskd_state_channel`, `m:briskd_state_link`,
  `m:briskd_state_net`, `m:briskd_state_v3`, `m:briskd_state_history`, and
  `m:briskd_state_queries`: protocol domain state libraries.

## Timers and lifecycle

A `reop_tick` message every second reopens operatorless safe channels after
`reop_delay`, expires empty non-predefined channels after `empty_channel_ttl`,
and expires nick/channel holds, E2EE queues, `REGISTER` rate-limit windows,
and stale open peer batches. Each session is monitored when it connects; its
`'DOWN'` removes the client, its memberships, and its IRCv3, E2EE, and flood
state. `format_status/1` delegates to `m:briskd_state_redact`.
""".

-doc """
Start and register the `briskd_state` process with the validated configuration
map from `m:briskd_config`. Called by `m:briskd_sup`.
""".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, [
        {spawn_opt, [{message_queue_data, off_heap}, {fullsweep_after, 200}]}
    ]).

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
connect(Host, Info) -> gen_server:call(?MODULE, {connect, Host, Info}, command_timeout()).

%% COMMAND_TIMEOUT, or the `command_timeout` application environment value
%% (milliseconds; for tests that need the overload path without waiting a
%% minute). Not a configuration-file setting.
command_timeout() ->
    case application:get_env(briskd, command_timeout) of
        {ok, Ms} when is_integer(Ms), Ms > 0 -> Ms;
        _ -> ?COMMAND_TIMEOUT
    end.

-doc """
Record that the calling session finished a `STARTTLS` handshake.

The `Info` keys update the connection facts. Because the offered capability
set changes (`tls` disappears, `sts` switches to its persistence value),
clients with `cap-notify` receive `CAP DEL` / `CAP NEW`.
""".
-spec tls_upgraded(map()) -> ok.
tls_upgraded(Info) -> gen_server:call(?MODULE, {tls_upgraded, Info}, command_timeout()).

-doc """
Apply an untagged client command on behalf of the calling session.

Same as `command(Command, Params, Bytes, [])`.
""".
-spec command(binary(), [binary()], non_neg_integer()) -> ok | quit | starttls.
command(Command, Params, Bytes) -> command(Command, Params, Bytes, []).

-doc """
Apply a client command, with its IRCv3 message tags, on behalf of the calling
session.
""".
-spec command(binary(), [binary()], non_neg_integer(), [{binary(), undefined | binary()}]) ->
    ok | quit | starttls.
command(Command, Params, Bytes, Tags) ->
    gen_server:call(?MODULE, {command, Command, Params, Bytes, Tags}, command_timeout()).

-doc """
Apply a command from a secondary connection attached to `Primary`
(the opt-in multiclient feature).
""".
-spec command_as(pid(), binary(), [binary()], non_neg_integer(), list()) -> ok | quit.
command_as(Primary, Command, Params, Bytes, Tags) ->
    gen_server:call(
        ?MODULE, {command_as, Primary, Command, Params, Bytes, Tags}, command_timeout()
    ).

-doc """
Run an administrative control action from `m:briskd_ctl` inside the `briskd_state`
process so state writes stay serialized.
""".
-spec ctl(briskd_ctl:state_action()) -> {ok, map()} | {error, term()}.
ctl(Action) ->
    gen_server:call(?MODULE, {ctl, Action}, 15000).

-doc """
Set the admin override of the feature control `Key` (`m:briskd_overrides`) to
the value `Text` names, and apply it as `REHASH` would.
""".
-spec set_control(binary(), binary()) -> {ok, [map()]} | {error, atom()}.
set_control(Key, Text) ->
    gen_server:call(?MODULE, {set_control, Key, Text}, 15000).

-doc "Remove the admin override of `Key`, so the file's value applies again.".
-spec reset_control(binary()) -> {ok, [map()]} | {error, unknown_control}.
reset_control(Key) ->
    gen_server:call(?MODULE, {reset_control, Key}, 15000).

-doc "The feature controls for the admin panel (`briskd_overrides:describe/3`).".
-spec controls() -> [map()].
controls() ->
    briskd_overrides:describe(
        briskd_config:current(), briskd_config:base(), briskd_overrides:all()
    ).

-doc """
Answer an over-long tagged line from the calling session with
`417 ERR_INPUTTOOLONG`, honouring its `label` tag. The line is not applied.
""".
-spec input_too_long([{binary(), undefined | binary()}]) -> ok | quit.
input_too_long(Tags) -> gen_server:call(?MODULE, {input_too_long, Tags}, command_timeout()).

-doc """
Return whether the calling session is registered: `NICK`, `USER`, and any
required `PASS` are accepted and the welcome has been sent.
""".
-spec registered() -> boolean().
registered() -> gen_server:call(?MODULE, registered, command_timeout()).

-doc """
Return the RFC 2813 burst lines for a newly authenticated link.
""".
-spec server_burst() -> [binary()].
server_burst() -> gen_server:call(?MODULE, server_burst, command_timeout()).

-doc """
Record a directly connected peer after its `PASS`/`SERVER` handshake
succeeds.
""".
-spec register_adjacent(binary(), binary(), inbound | outbound) ->
    ok | {error, duplicate_peer}.
register_adjacent(Name, Token, Kind) ->
    gen_server:call(?MODULE, {register_adjacent, Name, Token, Kind}).

-doc """
Apply an untagged message received from the authenticated peer `Peer`.
""".
-spec server_command(binary(), undefined | binary(), binary(), [binary()]) -> ok | {error, term()}.
server_command(Peer, Prefix, Command, Params) ->
    server_command(Peer, Prefix, Command, Params, []).

-doc """
Apply a message received from the authenticated peer `Peer` (RFC 2813).
""".
-spec server_command(
    binary(), undefined | binary(), binary(), [binary()], [{binary(), undefined | binary()}]
) ->
    ok | {error, term()}.
server_command(Peer, Prefix, Command, Params, Tags) ->
    briskd_log:server_command(Peer, Command, Params),
    gen_server:call(
        ?MODULE, {server_command, Peer, Prefix, Command, Params, Tags}, command_timeout()
    ).

-doc """
Apply consecutive messages from the authenticated peer `Peer` in one
priority request (EEP 76), in order.
""".
-spec server_commands(
    binary(),
    [{undefined | binary(), binary(), [binary()], [{binary(), undefined | binary()}]}]
) -> ok | {error, term()}.
server_commands(Peer, Lines) ->
    lists:foreach(
        fun({_Prefix, Command, Params, _Tags}) ->
            briskd_log:server_command(Peer, Command, Params)
        end,
        Lines
    ),
    Alias = peer_alias(),
    Mref = erlang:monitor(process, ?MODULE),
    erlang:send(Alias, {peer_lines, {self(), Mref}, Peer, Lines}, [priority]),
    receive
        {Mref, Reply} ->
            erlang:demonitor(Mref, [flush]),
            Reply;
        {'DOWN', Mref, process, _, Reason} ->
            exit({Reason, {?MODULE, server_commands, [Peer]}})
    after command_timeout() ->
        erlang:demonitor(Mref, [flush]),
        exit({timeout, {?MODULE, server_commands, [Peer]}})
    end.

%% The state process's priority alias (EEP 76, OTP 28+), cached by the
%% caller together with the state pid it belongs to.
peer_alias() ->
    State = whereis(?MODULE),
    case get(briskd_peer_alias) of
        {State, Alias} when is_pid(State), is_reference(Alias) ->
            Alias;
        _ ->
            Alias = gen_server:call(?MODULE, peer_alias, command_timeout()),
            true = is_reference(Alias),
            put(briskd_peer_alias, {whereis(?MODULE), Alias}),
            Alias
    end.

-doc """
Whether a command from an authenticated peer is applied by this process.
""".
-spec peer_command(binary()) -> boolean().
peer_command(Command) ->
    briskd_state_peer:peer_command(Command).

-doc """
Treat the loss of the link to `Peer` as a netsplit.
""".
-spec server_disconnect(binary()) -> ok.
server_disconnect(Peer) ->
    try gen_server:call(?MODULE, {server_disconnect, Peer}, command_timeout()) of
        ok -> ok
    catch
        exit:{noproc, _} -> ok;
        exit:shutdown -> ok;
        exit:{shutdown, _} -> ok
    end.

-doc """
Register a new IRC account from the public WebUI sign-up page.
""".
-spec signup_account(binary(), undefined | binary(), binary(), binary()) ->
    {ok, created | verification_required, binary()} | {error, atom()}.
signup_account(Name, Email, Password, PeerIP) when
    is_binary(Name), is_binary(Password), is_binary(PeerIP)
->
    gen_server:call(?MODULE, {signup_account, Name, Email, Password, PeerIP}, 10000).

-doc """
Verify a pending account registration via the web verification link.
""".
-spec verify_account(binary(), binary()) -> {ok, binary()} | error.
verify_account(Name, Code) when is_binary(Name), is_binary(Code) ->
    gen_server:call(?MODULE, {verify_account, Name, Code}, 5000).

-doc """
Verify a pending account registration via email address and verification code.
""".
-spec verify_account_by_email(binary(), binary()) -> {ok, binary()} | error.
verify_account_by_email(Email, Code) when is_binary(Email), is_binary(Code) ->
    gen_server:call(?MODULE, {verify_account_by_email, Email, Code}, 5000).

-doc """
Request an email password recovery code for a verified account.
""".
-spec request_password_reset(binary(), binary() | null, binary()) ->
    ok | {error, disabled | rate_limited | bad_email}.
request_password_reset(Email, RecoveryUrl, PeerIP) when is_binary(Email), is_binary(PeerIP) ->
    gen_server:call(?MODULE, {request_password_reset, Email, RecoveryUrl, PeerIP}, 5000).

-doc """
Complete email password recovery using the single-use recovery code and a new password.
""".
-spec complete_password_reset(binary(), binary(), binary(), binary()) ->
    {ok, binary()} | {error, disabled | rate_limited | invalid_code | bad_password}.
complete_password_reset(Email, Code, NewPassword, PeerIP) when
    is_binary(Email), is_binary(Code), is_binary(NewPassword), is_binary(PeerIP)
->
    gen_server:call(?MODULE, {complete_password_reset, Email, Code, NewPassword, PeerIP}, 10000).

-doc """
Check an inbound server's name (RFC 1459 folded) and shared password against
the configured `server_links`. Runs in the caller's process.
""".
-spec authenticate_server_link(binary(), binary()) -> boolean().
authenticate_server_link(Name, Password) ->
    briskd_state_peer:authenticate_server_link(Name, Password).

-doc false.
-spec init(map()) -> {ok, binary()}.
init(#{name := Name} = Config) ->
    %% Priority alias for batches of server-link input (server_commands/2).
    put(briskd_peer_alias, erlang:alias([priority])),
    ok = briskd_state_schema:init_storage(Config),
    erlang:send_after(1000, self(), reop_tick),
    erlang:send_after(?SWEEP_MS, self(), sweep_tick),
    {ok, Name}.

-doc """
Publish `OPER` credentials and the configured channel keys from `Config`
in `persistent_term`.
""".
-spec store_accounts(map()) -> ok.
store_accounts(Config) ->
    briskd_state_schema:store_accounts(Config).

-doc """
Create each channel from the JSON `channels` setting that has no row.
""".
-spec seed_channels() -> ok.
seed_channels() ->
    briskd_state_schema:seed_channels().

-doc """
True after the session `Pid` used `OPER` with an `administrators` entry.
""".
-spec administrator(pid()) -> boolean().
administrator(Pid) when is_pid(Pid) ->
    briskd_oper:administrator(Pid).

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
    briskd_state_schema:table_keys(Table).

-doc """
True when the folded channel key `Key` names a channel from the JSON
`channels` setting.
""".
-spec predefined_channel(binary()) -> boolean().
predefined_channel(Key) when is_binary(Key) ->
    briskd_state_schema:predefined_channel(Key).

-doc """
Configured `retention` policy.
""".
-spec retention() -> transient | channels.
retention() ->
    briskd_state_schema:retention().

-doc """
Longest accepted nickname in bytes: the `nicklen` setting, default 9 from
RFC 1459.
""".
-spec nicklen() -> pos_integer().
nicklen() ->
    briskd_state_schema:nicklen().

-doc """
The `history_limit` setting (default 100): how many messages, and separately
how many events, are kept per channel or direct conversation.
""".
-spec history_limit() -> pos_integer().
history_limit() ->
    briskd_state_schema:history_limit().

-doc false.
handle_call({connect, Host}, From, Server) ->
    handle_call({connect, Host, #{}}, From, Server);
handle_call({connect, Host, Info}, {Pid, _}, Server) ->
    monitor(process, Pid),
    mnesia:dirty_write(#client{pid = Pid, host = briskd_wire:retain(Host)}),
    briskd_cap:connect(Pid, Info),
    briskd_state_client:touch_activity(Pid),
    briskd_state_client:put_connection_stats(Pid, #{}),
    mnesia:dirty_write(#user_modes{pid = Pid}),
    briskd_population:on_client_connect(Pid),
    logger:info(#{event => client_connected, peer => Host}),
    {reply, ok, Server};
handle_call({tls_upgraded, Info}, {Pid, _}, Server) ->
    %% STARTTLS changes what is offered (`tls` goes away, `sts` switches to
    %% its persistence value): cap-notify clients get CAP DEL and CAP NEW.
    Before = #{Pid => briskd_cap:advertised(Pid)},
    maps:foreach(fun(Key, Value) -> briskd_cap:set_info(Pid, Key, Value) end, Info),
    briskd_state_net:notify_cap_changes(Before, Server),
    {reply, ok, Server};
handle_call(registered, {Pid, _}, Server) ->
    {reply, briskd_state_client:ready(briskd_state_client:client(Pid)), Server};
handle_call(server_burst, _, Server) ->
    {reply, briskd_state_link:server_burst_lines(Server), Server};
handle_call({register_adjacent, Name, Token, Kind}, {Pid, _}, Server) ->
    Result = briskd_state_net:register_adjacent(Name, Token, Kind, Pid),
    case Result of
        ok -> erlang:monitor(process, Pid);
        {error, duplicate_peer} -> ok
    end,
    {reply, Result, Server};
handle_call({ctl, Action}, _From, Server) ->
    {reply, briskd_ctl:handle_state_action(Action, Server), Server};
handle_call({set_control, Key, Text}, _From, Server) ->
    Reply =
        case briskd_overrides:validate(Key, Text) of
            {ok, Value} ->
                case briskd_overrides:available(Key, briskd_config:base()) of
                    false ->
                        {error, not_configured};
                    true ->
                        ok = briskd_overrides:put(Key, Value),
                        apply_overrides(Key, Value, Server),
                        {ok, controls()}
                end;
            {error, Reason} ->
                {error, Reason}
        end,
    {reply, Reply, Server};
handle_call({reset_control, Key}, _From, Server) ->
    Reply =
        case briskd_overrides:find(Key) of
            {ok, _} ->
                ok = briskd_overrides:delete(Key),
                apply_overrides(Key, default, Server),
                {ok, controls()};
            error ->
                {error, unknown_control}
        end,
    {reply, Reply, Server};
handle_call(peer_alias, _From, Server) ->
    {reply, get(briskd_peer_alias), Server};
handle_call({server_command, Peer, Prefix, Command, Params, Tags}, _From, Server) ->
    {reply, briskd_state_peer:handle_server_command(Peer, Prefix, Command, Params, Tags), Server};
handle_call({signup_account, Name, Email, Password, PeerIP}, _, Server) ->
    {reply, briskd_state_v3:signup_account_web(Name, Email, Password, PeerIP), Server};
handle_call({verify_account, Name, Code}, _, Server) ->
    {reply, briskd_state_v3:verify_account_web(Name, Code), Server};
handle_call({verify_account_by_email, Email, Code}, _, Server) ->
    {reply, briskd_state_v3:verify_account_email_web(Email, Code), Server};
handle_call({request_password_reset, Email, RecoveryUrl, PeerIP}, _, Server) ->
    {reply, briskd_state_v3:request_password_reset_web(Email, RecoveryUrl, PeerIP), Server};
handle_call({complete_password_reset, Email, Code, NewPassword, PeerIP}, _, Server) ->
    {reply, briskd_state_v3:complete_password_reset_web(Email, Code, NewPassword, PeerIP), Server};
handle_call({server_disconnect, Peer}, {Pid, _}, Server) ->
    briskd_state_peer:disconnect_peer(Peer, Pid),
    {reply, ok, Server};
handle_call({input_too_long, Tags}, {Pid, _}, Server) ->
    briskd_state_dispatch:handle_input_too_long(Tags, Pid, Server);
handle_call({command_as, Primary, Command, Params, Bytes, Tags}, From, Server) ->
    briskd_state_dispatch:handle_command_as(Primary, Command, Params, Bytes, Tags, From, Server);
handle_call({command, Command, Params, Bytes, Tags}, From, Server) ->
    briskd_state_dispatch:handle_command(Command, Params, Bytes, Tags, From, Server).

%% Rebuild the effective configuration from the file's and the stored
%% overrides after one changed, and apply it as REHASH does.
apply_overrides(Key, Value, Server) ->
    Effective = briskd_overrides:effective(
        briskd_config:current(), briskd_config:base(), briskd_overrides:all()
    ),
    Shown =
        case Value of
            default -> <<"the configuration file's value">>;
            true -> <<"on">>;
            false -> <<"off">>;
            N when is_integer(N) -> integer_to_binary(N)
        end,
    briskd_rehash:apply_effective(
        Effective,
        #{event => admin_feature_changed, control => Key, value => Value},
        [<<"Admin panel set ">>, Key, <<" to ">>, Shown],
        Server
    ).

-doc false.
handle_cast(_, State) -> {noreply, State}.

-doc false.
handle_info({'DOWN', Ref, process, Pid, Reason}, State) ->
    case briskd_deferred:resume(Ref, Reason, State) of
        handled -> {noreply, State};
        not_ours -> session_down(Pid, State)
    end;
handle_info({peer_lines, {Pid, Ref}, Peer, Lines}, Server) when
    is_pid(Pid), is_reference(Ref), is_binary(Peer), is_list(Lines)
->
    Reply = briskd_state_peer:apply_server_lines(Peer, Lines, Server),
    Pid ! {Ref, Reply},
    {noreply, Server};
handle_info({flush_netjoin, Peer}, Server) ->
    briskd_state_link:flush_netjoin(Peer),
    {noreply, Server};
handle_info(reop_tick, Server) ->
    briskd_state_channel:reop_channels(Server),
    ok = briskd_state_net:expire_holds(),
    ok = briskd_e2ee:expire(),
    ok = briskd_flood:expire(),
    ok = briskd_state_link:expire_peer_batches(),
    erlang:send_after(1000, self(), reop_tick),
    {noreply, Server};
handle_info(sweep_tick, Server) ->
    %% State nothing else removes, swept once a minute.
    _ = briskd_state_link:sweep_remote_channels(),
    ok = briskd_state_v3:expire_password_resets(),
    erlang:send_after(?SWEEP_MS, self(), sweep_tick),
    {noreply, Server};
%% Ignore unknown messages. Session and worker DOWN, `reop_tick`, `sweep_tick`, and
%% `flush_netjoin` are the only expected info events.
handle_info(_, State) ->
    {noreply, State}.

%% A session process ended: drop its attachment and client state.
session_down(Pid, State) ->
    briskd_state_peer:peer_down(Pid),
    ets:delete(briskd_attached, Pid),
    ok = briskd_e2ee:session_down(Pid),
    case mnesia:dirty_read(client, Pid) of
        [#client{} = Client] ->
            briskd_state_client:disconnect(Client, <<"Connection closed">>, State);
        [] ->
            ok
    end,
    {noreply, State}.

-doc """
Redact secrets from status and crash reports.
""".
-spec format_status(map()) -> map().
format_status(Status) ->
    briskd_state_redact:format_status(Status).

%% Public lookups and replies used by query handlers. The implementations
%% live with the state they read.
-doc """
Find a local client by nickname under the RFC 1459 case mapping
(`briskd_wire:fold/1`). Returns `undefined` when no local client has it.
""".
-spec find_nick(binary()) -> undefined | #client{}.
find_nick(A0) -> briskd_state_client:find_nick(A0).

-doc """
True when the client is registered and its welcome has been sent.
""".
-spec ready(#client{}) -> boolean().
ready(A0) -> briskd_state_client:ready(A0).

-doc """
User modes of the local client with pid `Pid`, as a set of mode characters.
""".
-spec user_modes(pid()) -> #{char() => true}.
user_modes(A0) -> briskd_state_client:user_modes(A0).

-doc """
True when `Requester` may see `Target` in queries.
""".
-spec user_visible(#client{}, #client{}) -> boolean().
user_visible(A0, A1) -> briskd_state_client:user_visible(A0, A1).

-doc """
True when the channel member `Pid` is visible to `Requester`.
""".
-spec visible_member(pid(), #client{}, #{pid() => [channel_role()]}) -> boolean().
visible_member(A0, A1, A2) -> briskd_state_channel:visible_member(A0, A1, A2).

-doc """
Match an IRC mask (`*`, `?`) against a value under the RFC 1459 case mapping.
""".
-spec wildcard_match(binary(), binary()) -> boolean().
wildcard_match(A0, A1) -> briskd_state_channel:wildcard_match(A0, A1).

-doc """
Mode flags of the imported remote channel `Name`, or `#{}` when no peer
reported it.
""".
-spec remote_channel_flags(binary()) -> remote_flags().
remote_channel_flags(A0) -> briskd_state_link:remote_channel_flags(A0).

-doc """
True when a remote user (folded nick key and user modes) is visible to `Requester`.
""".
-spec remote_user_visible_to_requester(binary(), #{char() => true}, #client{}) -> boolean().
remote_user_visible_to_requester(A0, A1, A2) ->
    briskd_state_link:remote_user_visible_to_requester(A0, A1, A2).

-doc """
Send a numeric reply to a local client. See `briskd_state_send:numeric/5`.
""".
-spec numeric(#client{}, binary(), binary(), [binary()], none | iodata()) -> ok.
numeric(A0, A1, A2, A3, A4) -> briskd_state_send:numeric(A0, A1, A2, A3, A4).
