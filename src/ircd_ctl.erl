-module(ircd_ctl).
-moduledoc """
Administrative control and inspection backend for the `bin/ircdctl` DevOps
CLI.

`run/1` accepts a list of command-line arguments (strings or binaries),
supports `--json` output on every subcommand for monitoring and automation,
and returns `{ok, Output}` or `{error, Output}`. `cli/1` prints the output and
returns exit status `0` or `1`. State-mutating operations (`rehash`,
`log-level <level>`, `kick-client`, `squit`, `create-account`,
`delete-account`) execute inside `m:ircd_state` via `ircd_state:ctl/1`
(`handle_state_action/2`) so protocol state retains its single-writer
invariant.

Subcommands:

- `status`: server summary, listeners, client/user/channel/link/account
  counts, retention, log level, and VM memory/process metrics.
- `ping`: health probe checking `ircd_state`, `ircd_sessions`, `ircd_links`,
  and Mnesia.
- `check-config [<path>]`: offline or online validation of a JSON config file
  (`m:ircd_config`) and its TLS certificate/key pairs (`m:ircd_certs`).
- `rehash`: live reload of the configuration file (`ircd_state_info:rehash_server/1`).
- `reload-certs`: synchronous TLS certificate reload (`ircd_certs:check_now/0`).
- `log-level [<level>]`: read or update the live log level.
- `clients`: list connected local clients.
- `kick-client <nick> [<reason>]`: disconnect a local client.
- `channels`: list active and retained local channels.
- `links`: list configured and connected server links and known remote servers.
- `connect <peer>`: trigger an immediate connection attempt to a configured peer.
- `squit <server> [<reason>]`: split a known remote server.
- `accounts`: list registered SASL accounts.
- `create-account <name> <password> [<email>]`: provision a verified account
  and propagate `ACCOUNTSYNC` to peers.
- `delete-account <name>`: log out local sessions of the account and delete
  its account, read markers, and E2EE device/queue rows.
- `backup <file>`: write a consistent online Mnesia backup (`mnesia:backup/1`).
- `drain [<reason>]`: gracefully drain listeners, peers, and clients (`m:ircd_shutdown`).
- `stop`: gracefully drain and stop the Erlang node (`init:stop/0`).
- `help`: print usage summary.
""".
-behaviour(gen_server).
-export([
    cli/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_state_action/2,
    init/1,
    remote_cli/1,
    run/1,
    socket_path/1,
    start_link/1,
    terminate/2
]).
-include("ircd_state.hrl").
-include("ircd_account.hrl").
-include("ircd_e2ee.hrl").

-define(MAX_CTL_BYTES, 65536).

-doc """
Start the local Unix-domain control socket server under `m:ircd_sup`.

Listens on `socket_path/1` (`IRCD_CTL_SOCKET` or `<mnesia_dir>/ircdctl.sock`)
with mode `0600` so only the OS user running `ircd` may connect. If the path
exceeds the OS Unix socket path limit or cannot be bound, the server starts
without a socket while `run/1` and `cli/1` remain usable in-process.
""".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

-doc """
Return the Unix domain socket path used by `bin/ircdctl` for `Config`.
Honors `IRCD_CTL_SOCKET` when set; otherwise `<mnesia_dir>/ircdctl.sock`.
""".
-spec socket_path(map()) -> file:filename_all().
socket_path(Config) ->
    case os:getenv("IRCD_CTL_SOCKET") of
        false -> default_socket_path(Config);
        "" -> default_socket_path(Config);
        Custom -> Custom
    end.

default_socket_path(Config) ->
    Dir =
        case maps:get(mnesia_dir, Config, "data/mnesia") of
            B when is_binary(B) -> binary_to_list(B);
            L when is_list(L) -> L
        end,
    filename:join(Dir, "ircdctl.sock").

-doc """
Client entry point invoked by `bin/ircdctl`.

Runs `help` and offline `check-config` locally when no running server socket
is reachable; sends all other commands as JSON over the local Unix domain
socket, prints the server's output, and returns exit code `0` or `1`.
""".
-spec remote_cli([binary() | string()]) -> 0 | 1.
remote_cli(RawArgs) ->
    Bins = [to_bin(A) || A <- RawArgs],
    NonFlags = [A || A <- Bins, A =/= <<"--json">>],
    case NonFlags of
        [] ->
            cli(Bins);
        [Cmd | _] when Cmd =:= <<"help">>; Cmd =:= <<"--help">>; Cmd =:= <<"-h">> ->
            cli(Bins);
        [<<"check-config">>, _Path | _] ->
            cli(Bins);
        _ ->
            Path = resolve_client_socket_path(),
            case send_remote(Path, Bins) of
                {ok, Output} ->
                    io:put_chars([Output, "\n"]),
                    0;
                {error, Output} ->
                    io:put_chars(standard_error, [Output, "\n"]),
                    1;
                {connect_error, Reason} ->
                    case NonFlags of
                        [<<"check-config">>] ->
                            cli(Bins);
                        _ ->
                            Msg = iolist_to_binary(
                                io_lib:format(
                                    "Failed to connect to ircd control socket ~s: ~p",
                                    [Path, Reason]
                                )
                            ),
                            io:put_chars(standard_error, [Msg, "\n"]),
                            1
                    end
            end
    end.

resolve_client_socket_path() ->
    case os:getenv("IRCD_CTL_SOCKET") of
        false ->
            CfgPath = os:getenv("IRCD_CONFIG", "config/ircd.json"),
            case ircd_config:load(CfgPath) of
                {ok, Config} -> socket_path(Config);
                {error, _} -> "data/mnesia/ircdctl.sock"
            end;
        "" ->
            "data/mnesia/ircdctl.sock";
        Custom ->
            Custom
    end.

send_remote(Path, Args) ->
    case
        gen_tcp:connect(
            {local, Path},
            0,
            [binary, {packet, 4}, {active, false}, {send_timeout, 5000}],
            5000
        )
    of
        {ok, Socket} ->
            try
                Payload = iolist_to_binary(json:encode(Args)),
                ok = gen_tcp:send(Socket, Payload),
                case gen_tcp:recv(Socket, 0, 20000) of
                    {ok, Reply} ->
                        case json:decode(Reply) of
                            #{<<"ok">> := true, <<"output">> := Output} -> {ok, Output};
                            #{<<"ok">> := false, <<"output">> := Output} -> {error, Output};
                            _ -> {error, <<"Invalid response from ircd control socket">>}
                        end;
                    {error, Reason} ->
                        {error,
                            iolist_to_binary(
                                io_lib:format("Control socket recv error: ~p", [Reason])
                            )}
                end
            after
                gen_tcp:close(Socket)
            end;
        {error, Reason} ->
            {connect_error, Reason}
    end.

%%% gen_server callbacks

-doc false.
init(Config) ->
    process_flag(trap_exit, true),
    Path = socket_path(Config),
    case byte_size(list_to_binary(Path)) =< 100 of
        false ->
            {ok, #{socket => undefined, path => undefined}};
        true ->
            _ = filelib:ensure_dir(Path),
            _ = file:delete(Path),
            case
                gen_tcp:listen(0, [
                    {ifaddr, {local, Path}},
                    binary,
                    {packet, 4},
                    {active, false},
                    {send_timeout, 5000}
                ])
            of
                {ok, Listen} ->
                    _ = file:change_mode(Path, 8#0600),
                    Acceptor = spawn_link(fun() -> accept_loop(Listen) end),
                    {ok, #{socket => Listen, path => Path, acceptor => Acceptor}};
                {error, Reason} ->
                    logger:warning(#{
                        event => ctl_socket_failed,
                        path => unicode:characters_to_binary(Path),
                        reason => Reason
                    }),
                    {ok, #{socket => undefined, path => undefined}}
            end
    end.

-doc false.
handle_call(_, _, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
handle_cast(_, State) ->
    {noreply, State}.

-doc false.
handle_info({'EXIT', Pid, _Reason}, #{acceptor := Pid, socket := Listen} = State) when
    Listen =/= undefined
->
    Next = spawn_link(fun() -> accept_loop(Listen) end),
    {noreply, State#{acceptor := Next}};
handle_info(_, State) ->
    {noreply, State}.

-doc false.
terminate(_, #{socket := Listen, path := Path}) ->
    case Listen of
        undefined -> ok;
        _ -> gen_tcp:close(Listen)
    end,
    case Path of
        undefined ->
            ok;
        _ ->
            _ = file:delete(Path),
            ok
    end,
    ok.

accept_loop(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Client} ->
            spawn(fun() -> serve_client(Client) end),
            accept_loop(Listen);
        {error, closed} ->
            ok;
        {error, _} ->
            timer:sleep(100),
            accept_loop(Listen)
    end.

serve_client(Socket) ->
    try
        case gen_tcp:recv(Socket, 0, 5000) of
            {ok, Payload} when byte_size(Payload) =< ?MAX_CTL_BYTES ->
                Response =
                    try json:decode(Payload) of
                        Args when is_list(Args) ->
                            case run(Args) of
                                {ok, Out} -> #{<<"ok">> => true, <<"output">> => Out};
                                {error, Out} -> #{<<"ok">> => false, <<"output">> => Out}
                            end;
                        _ ->
                            #{<<"ok">> => false, <<"output">> => <<"Invalid control request">>}
                    catch
                        _:_ ->
                            #{
                                <<"ok">> => false,
                                <<"output">> => <<"Malformed JSON control request">>
                            }
                    end,
                _ = gen_tcp:send(Socket, iolist_to_binary(json:encode(Response))),
                ok;
            _ ->
                ok
        end
    after
        gen_tcp:close(Socket)
    end.

-doc """
Run a CLI subcommand and print its output to stdout (or stderr on error).
Returns `0` on success and `1` on error.
""".
-spec cli([binary() | string()]) -> 0 | 1.
cli(RawArgs) ->
    case run(RawArgs) of
        {ok, Output} ->
            io:put_chars([Output, "\n"]),
            0;
        {error, Output} ->
            io:put_chars(standard_error, [Output, "\n"]),
            1
    end.

-doc """
Execute an `ircdctl` command given its argument list.

Pass `--json` anywhere in `RawArgs` to receive single-line JSON output instead
of human-readable text. Returns `{ok, Binary}` or `{error, Binary}`.
""".
-spec run([binary() | string()]) -> {ok, binary()} | {error, binary()}.
run(RawArgs) ->
    Bins = [to_bin(A) || A <- RawArgs],
    Format =
        case lists:member(<<"--json">>, Bins) of
            true -> json;
            false -> text
        end,
    Args = [A || A <- Bins, A =/= <<"--json">>],
    dispatch(Args, Format).

-doc """
Execute a state-mutating control action inside the `m:ircd_state` process.
Called only from `ircd_state:handle_call({ctl, Action}, ...)`.
""".
-spec handle_state_action(term(), binary()) -> {ok, map()} | {error, term()}.
handle_state_action(rehash, Server) ->
    case ircd_state_info:rehash_server(Server) of
        {ok, Path} -> {ok, #{status => <<"rehashed">>, config_path => Path}};
        {error, Reason} -> {error, Reason}
    end;
handle_state_action({set_log_level, LevelBin}, _Server) ->
    case parse_log_level(LevelBin) of
        {ok, Level} ->
            Config = persistent_term:get({ircd_state, config}, #{}),
            persistent_term:put({ircd_state, config}, Config#{level => Level}),
            ok = ircd_log:apply_level(Level),
            logger:notice(#{event => ctl_log_level, level => Level}),
            {ok, #{status => <<"updated">>, log_level => LevelBin}};
        error ->
            {error, {invalid_log_level, LevelBin}}
    end;
handle_state_action({kick_client, Nick, Reason}, Server) ->
    case ircd_state_client:find_nick(Nick) of
        undefined ->
            {error, {no_such_nick, Nick}};
        #client{pid = Pid, nick = Actual} = Target ->
            Line = ircd_wire:line(Server, <<"KILL">>, [Actual], Reason),
            Pid ! {irc_close, Line},
            logger:notice(#{event => ctl_kill, target => Actual}),
            ircd_state_client:disconnect(Target, Reason, Server),
            {ok, #{status => <<"kicked">>, nick => Actual, reason => Reason}}
    end;
handle_state_action({squit, Target, Reason}, _Server) ->
    case mnesia:dirty_read(known_server, ircd_wire:fold(Target)) of
        [] ->
            {error, {no_such_server, Target}};
        [#known_server{name = Name}] ->
            logger:notice(#{event => ctl_squit, target => Name}),
            ircd_state_net:split(Name, Reason, undefined),
            {ok, #{status => <<"split">>, server => Name, reason => Reason}}
    end;
handle_state_action({create_account, Name, Password, Email}, _Server) ->
    case ircd_account:create(Name, Email, Password, [], undefined) of
        {ok, Account} ->
            logger:notice(#{event => ctl_account_created, account => Account#account.name}),
            ircd_state_sync:account_created(Account),
            {ok, #{status => <<"created">>, account => Account#account.name}};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({notice_all, Text}, Server) ->
    Pids = [
        Pid
     || Pid <- mnesia:dirty_all_keys(client),
        [Client] <- [mnesia:dirty_read(client, Pid)],
        ircd_state_client:ready(Client)
    ],
    lists:foreach(
        fun(Pid) ->
            ircd_state_send:send(Pid, Server, <<"NOTICE">>, [<<"*">>], Text)
        end,
        Pids
    ),
    logger:notice(#{event => ctl_notice_all, recipients => length(Pids)}),
    {ok, #{status => <<"sent">>, recipients => length(Pids)}};
handle_state_action({set_topic, ChannelName, Topic}, Server) ->
    Key = ircd_wire:fold(ChannelName),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            {error, {no_such_channel, ChannelName}};
        [#channel{name = Actual, members = Members} = Channel] ->
            Now = erlang:system_time(second),
            Updated = Channel#channel{
                topic = ircd_wire:retain(Topic),
                topic_by = Server,
                topic_at = Now
            },
            mnesia:dirty_write(Updated),
            ircd_state_send:broadcast(maps:keys(Members), Server, <<"TOPIC">>, [Actual], Topic),
            logger:notice(#{event => ctl_set_topic, channel => Actual}),
            {ok, #{status => <<"updated">>, channel => Actual, topic => Topic}}
    end;
handle_state_action({verify_account, Name}, _Server) ->
    case ircd_account:force_verify(Name) of
        {ok, #account{name = Actual} = Account} ->
            logger:notice(#{event => ctl_account_verified, account => Actual}),
            ircd_state_sync:account_created(Account),
            {ok, #{status => <<"verified">>, account => Actual}};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({delete_account, Name}, Server) ->
    Key = ircd_wire:fold(Name),
    case mnesia:dirty_read(account, Key) of
        [] ->
            {error, {no_such_account, Name}};
        [#account{name = Actual}] ->
            lists:foreach(
                fun(Pid) ->
                    case ircd_state_v3:account(Pid) of
                        Logged when is_binary(Logged) ->
                            case ircd_wire:fold(Logged) =:= Key of
                                true ->
                                    case mnesia:dirty_read(client, Pid) of
                                        [Client] -> ircd_state_v3:logout(Client, Server);
                                        [] -> ok
                                    end;
                                false ->
                                    ok
                            end;
                        _ ->
                            ok
                    end
                end,
                mnesia:dirty_all_keys(client)
            ),
            lists:foreach(
                fun
                    ({Acct, _} = MarkerKey) when Acct =:= Key ->
                        mnesia:dirty_delete(read_marker, MarkerKey);
                    (_) ->
                        ok
                end,
                mnesia:dirty_all_keys(read_marker)
            ),
            lists:foreach(
                fun
                    ({Acct, _} = DevKey) when Acct =:= Key ->
                        mnesia:dirty_delete(e2ee_device, DevKey);
                    (_) ->
                        ok
                end,
                mnesia:dirty_all_keys(e2ee_device)
            ),
            lists:foreach(
                fun
                    ({Acct, _, _} = QKey) when Acct =:= Key ->
                        mnesia:dirty_delete(e2ee_queue, QKey);
                    (_) ->
                        ok
                end,
                mnesia:dirty_all_keys(e2ee_queue)
            ),
            mnesia:dirty_delete(account, Key),
            logger:notice(#{event => ctl_account_deleted, account => Actual}),
            {ok, #{status => <<"deleted">>, account => Actual}}
    end;
handle_state_action(Unknown, _Server) ->
    {error, {unknown_action, Unknown}}.

%%% Dispatch

dispatch([], Format) ->
    dispatch([<<"help">>], Format);
dispatch([<<"help">> | _], Format) ->
    {ok, format_help(Format)};
dispatch([<<"--help">> | _], Format) ->
    {ok, format_help(Format)};
dispatch([<<"-h">> | _], Format) ->
    {ok, format_help(Format)};
dispatch([<<"ping">> | _], Format) ->
    cmd_ping(Format);
dispatch([<<"health">> | _], Format) ->
    cmd_ping(Format);
dispatch([<<"status">> | _], Format) ->
    cmd_status(Format);
dispatch([<<"check-config">> | Rest], Format) ->
    cmd_check_config(Rest, Format);
dispatch([<<"rehash">> | _], Format) ->
    cmd_state_call(rehash, Format, fun(#{config_path := Path}) ->
        <<"Rehashed configuration from ", Path/binary>>
    end);
dispatch([<<"reload-certs">> | _], Format) ->
    cmd_reload_certs(Format);
dispatch([<<"log-level">>], Format) ->
    cmd_get_log_level(Format);
dispatch([<<"log-level">>, Level | _], Format) ->
    cmd_state_call({set_log_level, Level}, Format, fun(#{log_level := L}) ->
        <<"Log level set to ", L/binary>>
    end);
dispatch([<<"clients">> | _], Format) ->
    cmd_clients(Format);
dispatch([<<"kick-client">>, Nick | Rest], Format) ->
    Reason =
        case Rest of
            [R | _] -> R;
            [] -> <<"Disconnected by administrator (ircdctl)">>
        end,
    cmd_state_call({kick_client, Nick, Reason}, Format, fun(#{nick := N}) ->
        <<"Disconnected client ", N/binary>>
    end);
dispatch([<<"channels">> | _], Format) ->
    cmd_channels(Format);
dispatch([<<"links">> | _], Format) ->
    cmd_links(Format);
dispatch([<<"connect">>, Peer | _], Format) ->
    cmd_connect(Peer, Format);
dispatch([<<"squit">>, Target | Rest], Format) ->
    Reason =
        case Rest of
            [R | _] -> R;
            [] -> <<"SQUIT by administrator (ircdctl)">>
        end,
    cmd_state_call({squit, Target, Reason}, Format, fun(#{server := S}) ->
        <<"Split server ", S/binary>>
    end);
dispatch([<<"accounts">> | _], Format) ->
    cmd_accounts(Format);
dispatch([<<"create-account">>, Name, Password | Rest], Format) ->
    Email =
        case Rest of
            [E | _] when E =/= <<"*">>, E =/= <<>> -> E;
            _ -> undefined
        end,
    cmd_state_call({create_account, Name, Password, Email}, Format, fun(#{account := A}) ->
        <<"Created account ", A/binary>>
    end);
dispatch([<<"notice-all">>, Text | _], Format) when byte_size(Text) > 0, byte_size(Text) =< 400 ->
    cmd_state_call({notice_all, Text}, Format, fun(#{recipients := N}) ->
        <<"Sent notice to ", (integer_to_binary(N))/binary, " users">>
    end);
dispatch([<<"set-topic">>, Channel, Topic | _], Format) when byte_size(Topic) =< 390 ->
    cmd_state_call({set_topic, Channel, Topic}, Format, fun(#{channel := C}) ->
        <<"Updated topic for ", C/binary>>
    end);
dispatch([<<"verify-account">>, Name | _], Format) ->
    cmd_state_call({verify_account, Name}, Format, fun(#{account := A}) ->
        <<"Verified account ", A/binary>>
    end);
dispatch([<<"delete-account">>, Name | _], Format) ->
    cmd_state_call({delete_account, Name}, Format, fun(#{account := A}) ->
        <<"Deleted account ", A/binary>>
    end);
dispatch([<<"backup">>, File | _], Format) ->
    cmd_backup(File, Format);
dispatch([<<"drain">> | Rest], Format) ->
    Reason =
        case Rest of
            [R | _] -> R;
            [] -> <<"Server maintenance">>
        end,
    cmd_drain(Reason, Format);
dispatch([<<"stop">> | Rest], Format) ->
    Reason =
        case Rest of
            [R | _] -> R;
            [] -> <<"Server shutting down">>
        end,
    cmd_stop(Reason, Format);
dispatch([Unknown | _], Format) ->
    reply_error(Format, #{error => <<"unknown_command">>, command => Unknown}, [
        <<"Unknown command or missing arguments: ">>,
        Unknown,
        <<" (run 'ircdctl help')">>
    ]).

%%% Subcommand implementations

cmd_ping(Format) ->
    Alive =
        is_pid(whereis(ircd_state)) andalso is_pid(whereis(ircd_sessions)) andalso
            is_pid(whereis(ircd_links)) andalso mnesia:system_info(is_running) =:= yes,
    case Alive of
        true ->
            reply_ok(Format, #{status => <<"ok">>, reply => <<"pong">>}, <<"pong">>);
        false ->
            reply_error(
                Format, #{status => <<"error">>, reason => <<"not_running">>}, <<"not running">>
            )
    end.

cmd_status(Format) ->
    case whereis(ircd_state) of
        undefined ->
            reply_error(
                Format,
                #{status => <<"error">>, reason => <<"not_running">>},
                <<"ircd is not running">>
            );
        _ ->
            Config = persistent_term:get({ircd_state, config}, #{}),
            StartedAt = persistent_term:get(
                {ircd_state, started_at}, erlang:monotonic_time(second)
            ),
            Uptime = max(0, erlang:monotonic_time(second) - StartedAt),
            StartedIso = list_to_binary(
                persistent_term:get({ircd_state, started}, "unknown")
            ),
            Clients = [
                C
             || Pid <- mnesia:dirty_all_keys(client), [C] <- [mnesia:dirty_read(client, Pid)]
            ],
            Registered = [C || C <- Clients, ircd_state_client:ready(C)],
            Operators = [
                C
             || #client{pid = P} = C <- Registered,
                maps:is_key($o, ircd_state_client:user_modes(P))
            ],
            Map = #{
                status => <<"running">>,
                name => maps:get(name, Config, <<"irc.local">>),
                network => maps:get(network, Config, <<"irc.local">>),
                version => <<"0.1.0">>,
                started_at => StartedIso,
                uptime_seconds => Uptime,
                retention => atom_to_binary(maps:get(retention, Config, channels)),
                log_level => atom_to_binary(maps:get(level, Config, info)),
                log_format => maps:get(log_format, Config, <<"json">>),
                listeners => active_listeners(),
                sessions => length(Clients),
                max_clients => maps:get(max_clients, Config, 10000),
                registered_users => length(Registered),
                operators_online => length(Operators),
                remote_users => mnesia:table_info(remote_client, size),
                channels => mnesia:table_info(channel, size),
                remote_channels => mnesia:table_info(remote_channel, size),
                known_servers => mnesia:table_info(known_server, size),
                services => mnesia:table_info(service, size),
                accounts => length(ircd_account:list()),
                memory_bytes => erlang:memory(total),
                erlang_processes => erlang:system_info(process_count)
            },
            Text = iolist_to_binary([
                <<"Server:           ">>,
                maps:get(name, Map),
                <<" (network: ">>,
                maps:get(network, Map),
                <<")\n">>,
                <<"Status:           running (up ">>,
                integer_to_binary(Uptime),
                <<"s since ">>,
                StartedIso,
                <<")\n">>,
                <<"Retention:        ">>,
                maps:get(retention, Map),
                <<" | Log: ">>,
                maps:get(log_level, Map),
                <<" (">>,
                maps:get(log_format, Map),
                <<")\n">>,
                <<"Listeners:        ">>,
                format_listeners_text(maps:get(listeners, Map)),
                <<"\n">>,
                <<"Local sessions:   ">>,
                integer_to_binary(maps:get(sessions, Map)),
                <<" / ">>,
                integer_to_binary(maps:get(max_clients, Map)),
                <<" (registered: ">>,
                integer_to_binary(maps:get(registered_users, Map)),
                <<", operators: ">>,
                integer_to_binary(maps:get(operators_online, Map)),
                <<")\n">>,
                <<"Channels:         ">>,
                integer_to_binary(maps:get(channels, Map)),
                <<" local, ">>,
                integer_to_binary(maps:get(remote_channels, Map)),
                <<" remote\n">>,
                <<"Network:          ">>,
                integer_to_binary(maps:get(known_servers, Map)),
                <<" remote servers, ">>,
                integer_to_binary(maps:get(remote_users, Map)),
                <<" remote users, ">>,
                integer_to_binary(maps:get(services, Map)),
                <<" services\n">>,
                <<"Accounts:         ">>,
                integer_to_binary(maps:get(accounts, Map)),
                <<"\n">>,
                <<"VM Memory / Pids: ">>,
                integer_to_binary(maps:get(memory_bytes, Map) div 1024),
                <<" KiB / ">>,
                integer_to_binary(maps:get(erlang_processes, Map)),
                <<" processes">>
            ]),
            reply_ok(Format, Map, Text)
    end.

cmd_check_config(Rest, Format) ->
    Path =
        case Rest of
            [Given | _] ->
                binary_to_list(Given);
            [] ->
                case persistent_term:get({ircd_state, config_path}, undefined) of
                    undefined -> os:getenv("IRCD_CONFIG", "config/ircd.json");
                    RunningPath -> RunningPath
                end
        end,
    PathBin = unicode:characters_to_binary(Path),
    case ircd_config:load(Path) of
        {error, Reason} ->
            ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
            reply_error(
                Format,
                #{status => <<"invalid">>, path => PathBin, reason => ReasonBin},
                [<<"Configuration invalid (">>, PathBin, <<"): ">>, ReasonBin]
            );
        {ok, Config} ->
            case check_tls_pairs(maps:get(tls_options, Config, [])) of
                {ok, Certs} ->
                    reply_ok(
                        Format,
                        #{
                            status => <<"valid">>,
                            path => PathBin,
                            name => maps:get(name, Config),
                            certificates => Certs
                        },
                        [
                            <<"Configuration valid: ">>,
                            PathBin,
                            <<" (server: ">>,
                            maps:get(name, Config),
                            <<", certificates checked: ">>,
                            integer_to_binary(length(Certs)),
                            <<")">>
                        ]
                    );
                {error, CertReason} ->
                    ReasonBin = iolist_to_binary(io_lib:format("~p", [CertReason])),
                    reply_error(
                        Format,
                        #{status => <<"invalid_tls">>, path => PathBin, reason => ReasonBin},
                        [<<"TLS certificate check failed: ">>, ReasonBin]
                    )
            end
    end.

check_tls_pairs([]) ->
    {ok, []};
check_tls_pairs(Options) ->
    Main =
        case {proplists:get_value(certfile, Options), proplists:get_value(keyfile, Options)} of
            {Cert, Key} when is_list(Cert), is_list(Key) -> [{Cert, Key}];
            _ -> []
        end,
    Sni = [
        {proplists:get_value(certfile, SOpts), proplists:get_value(keyfile, SOpts)}
     || {_Host, SOpts} <- proplists:get_value(sni_hosts, Options, [])
    ],
    validate_pairs(Main ++ Sni, []).

validate_pairs([], Acc) ->
    {ok, lists:reverse(Acc)};
validate_pairs([{Cert, Key} | Rest], Acc) ->
    case ircd_certs:validate_pair(Cert, Key) of
        {ok, Info} ->
            validate_pairs(Rest, [Info#{certfile => unicode:characters_to_binary(Cert)} | Acc]);
        {error, Reason} ->
            {error, Reason}
    end.

cmd_reload_certs(Format) ->
    case whereis(ircd_certs) of
        undefined ->
            reply_ok(
                Format,
                #{status => <<"disabled">>},
                <<"TLS certificate watcher is not active (no TLS listener configured)">>
            );
        _ ->
            case ircd_certs:check_now() of
                reloaded ->
                    reply_ok(
                        Format, #{status => <<"reloaded">>}, <<"TLS certificates reloaded">>
                    );
                unchanged ->
                    reply_ok(
                        Format,
                        #{status => <<"unchanged">>},
                        <<"TLS certificates unchanged">>
                    );
                {error, Reason} ->
                    ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
                    reply_error(
                        Format,
                        #{status => <<"error">>, reason => ReasonBin},
                        [<<"TLS certificate reload rejected: ">>, ReasonBin]
                    )
            end
    end.

cmd_get_log_level(Format) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    Level = atom_to_binary(maps:get(level, Config, info)),
    reply_ok(Format, #{log_level => Level}, Level).

cmd_clients(Format) ->
    Now = erlang:system_time(second),
    Entries = lists:sort([
        begin
            Modes = ircd_state_client:user_modes(Pid),
            Account =
                case ircd_state_v3:account(Pid) of
                    undefined -> null;
                    A -> A
                end,
            Idle =
                case mnesia:dirty_read(activity, Pid) of
                    [#activity{last = Last}] -> max(0, Now - Last);
                    [] -> 0
                end,
            Info = ircd_cap:info(Pid),
            #{
                nick => Nick,
                user =>
                    case User of
                        undefined -> <<"*">>;
                        _ -> User
                    end,
                host => Host,
                account => Account,
                registered => ircd_state_client:ready(Client),
                operator => maps:is_key($o, Modes),
                secure => maps:get(secure, Info, false),
                channels => length(Channels),
                idle_seconds => Idle
            }
        end
     || Pid <- mnesia:dirty_all_keys(client),
        [#client{nick = Nick, user = User, host = Host, channels = Channels} = Client] <- [
            mnesia:dirty_read(client, Pid)
        ]
    ]),
    Lines = [
        iolist_to_binary([
            maps:get(nick, E),
            <<"!">>,
            maps:get(user, E),
            <<"@">>,
            maps:get(host, E),
            <<" | account=">>,
            null_star(maps:get(account, E)),
            <<" | oper=">>,
            atom_to_binary(maps:get(operator, E)),
            <<" | tls=">>,
            atom_to_binary(maps:get(secure, E)),
            <<" | channels=">>,
            integer_to_binary(maps:get(channels, E)),
            <<" | idle=">>,
            integer_to_binary(maps:get(idle_seconds, E)),
            <<"s">>
        ])
     || E <- Entries
    ],
    Text =
        case Lines of
            [] -> <<"No local clients connected">>;
            _ -> iolist_to_binary(lists:join(<<"\n">>, Lines))
        end,
    reply_ok(Format, #{count => length(Entries), clients => Entries}, Text).

cmd_channels(Format) ->
    Entries = lists:sort([
        begin
            RemoteCount =
                case mnesia:dirty_read(remote_channel, Key) of
                    [#remote_channel{members = RM}] -> map_size(RM);
                    [] -> 0
                end,
            Modes = list_to_binary([
                $+
                | lists:sort([M || M <- maps:keys(Flags), is_integer(M)])
            ]),
            #{
                name => Name,
                local_members => map_size(Members),
                remote_members => RemoteCount,
                modes => Modes,
                topic => Topic,
                predefined => ircd_state:predefined_channel(Key)
            }
        end
     || Key <- mnesia:dirty_all_keys(channel),
        [#channel{name = Name, members = Members, flags = Flags, topic = Topic}] <- [
            mnesia:dirty_read(channel, Key)
        ]
    ]),
    Lines = [
        iolist_to_binary([
            maps:get(name, E),
            <<" (local=">>,
            integer_to_binary(maps:get(local_members, E)),
            <<", remote=">>,
            integer_to_binary(maps:get(remote_members, E)),
            <<", modes=">>,
            maps:get(modes, E),
            <<") :">>,
            maps:get(topic, E)
        ])
     || E <- Entries
    ],
    Text =
        case Lines of
            [] -> <<"No channels">>;
            _ -> iolist_to_binary(lists:join(<<"\n">>, Lines))
        end,
    reply_ok(Format, #{count => length(Entries), channels => Entries}, Text).

cmd_links(Format) ->
    Configured = [
        maps:without([password], Link)
     || Link <- persistent_term:get({ircd_state, server_links}, [])
    ],
    Known = [
        #{
            name => Name,
            hop => Hop,
            adjacent => Adjacent,
            parent => Parent,
            info => Info
        }
     || Key <- mnesia:dirty_all_keys(known_server),
        [
            #known_server{
                name = Name, hop = Hop, adjacent = Adjacent, parent = Parent, info = Info
            }
        ] <- [mnesia:dirty_read(known_server, Key)]
    ],
    Lines = [
        iolist_to_binary([
            maps:get(name, S),
            <<" (hop=">>,
            integer_to_binary(maps:get(hop, S)),
            <<", via=">>,
            maps:get(adjacent, S),
            <<") :">>,
            maps:get(info, S)
        ])
     || S <- Known
    ],
    Text =
        case Lines of
            [] ->
                iolist_to_binary([
                    <<"No connected server links (configured peers: ">>,
                    integer_to_binary(length(Configured)),
                    <<")">>
                ]);
            _ ->
                iolist_to_binary(lists:join(<<"\n">>, Lines))
        end,
    reply_ok(
        Format,
        #{configured => Configured, connected => Known, count => length(Known)},
        Text
    ).

cmd_connect(Peer, Format) ->
    Links = persistent_term:get({ircd_state, server_links}, []),
    case
        [
            maps:get(name, L)
         || L <- Links, ircd_wire:fold(maps:get(name, L)) =:= ircd_wire:fold(Peer)
        ]
    of
        [Name | _] ->
            _ = ircd_links:connect_peer(Name),
            reply_ok(
                Format,
                #{status => <<"connecting">>, peer => Name},
                <<"Triggered connection attempt for ", Name/binary>>
            );
        [] ->
            reply_error(
                Format,
                #{error => <<"no_such_peer">>, peer => Peer},
                <<"No configured server link named ", Peer/binary>>
            )
    end.

cmd_accounts(Format) ->
    Entries = lists:sort([
        #{
            name => Name,
            verified => Pending =:= undefined,
            email =>
                case Email of
                    undefined -> null;
                    _ -> Email
                end,
            certfps => length(Fps),
            created_us => Created
        }
     || #account{
            name = Name, email = Email, certfps = Fps, created = Created, pending = Pending
        } <-
            ircd_account:list_all()
    ]),
    Lines = [
        iolist_to_binary([
            maps:get(name, E),
            <<" | verified=">>,
            atom_to_binary(maps:get(verified, E)),
            <<" | email=">>,
            null_star(maps:get(email, E)),
            <<" | certfps=">>,
            integer_to_binary(maps:get(certfps, E))
        ])
     || E <- Entries
    ],
    Text =
        case Lines of
            [] -> <<"No registered accounts">>;
            _ -> iolist_to_binary(lists:join(<<"\n">>, Lines))
        end,
    reply_ok(Format, #{count => length(Entries), accounts => Entries}, Text).

cmd_backup(FileBin, Format) ->
    Path = binary_to_list(FileBin),
    ok = filelib:ensure_dir(Path),
    case mnesia:backup(Path) of
        ok ->
            logger:notice(#{event => ctl_backup, path => FileBin}),
            reply_ok(
                Format,
                #{status => <<"backed_up">>, path => FileBin},
                <<"Mnesia backup written to ", FileBin/binary>>
            );
        {error, Reason} ->
            ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
            reply_error(
                Format,
                #{error => <<"backup_failed">>, path => FileBin, reason => ReasonBin},
                [<<"Backup failed: ">>, ReasonBin]
            )
    end.

cmd_drain(Reason, Format) ->
    ok = ircd_shutdown:drain(Reason),
    reply_ok(
        Format,
        #{status => <<"drained">>, reason => Reason},
        <<"Drained listeners, links, and client sessions">>
    ).

cmd_stop(Reason, Format) ->
    ok = ircd_shutdown:drain(Reason),
    erlang:spawn(fun() -> init:stop() end),
    reply_ok(
        Format,
        #{status => <<"stopping">>, reason => Reason},
        <<"Server drained and stopping">>
    ).

cmd_state_call(Action, Format, TextFun) ->
    case whereis(ircd_state) of
        undefined ->
            reply_error(
                Format,
                #{error => <<"not_running">>},
                <<"ircd_state is not running">>
            );
        _ ->
            case ircd_state:ctl(Action) of
                {ok, Map} ->
                    reply_ok(Format, Map, TextFun(Map));
                {error, Reason} ->
                    ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
                    reply_error(
                        Format,
                        #{error => ReasonBin},
                        [<<"Operation failed: ">>, ReasonBin]
                    )
            end
    end.

%%% Helpers

active_listeners() ->
    case whereis(ircd_sup) of
        undefined ->
            [];
        _ ->
            lists:foldl(
                fun(Kind, Acc) ->
                    case lists:keyfind(Kind, 1, supervisor:which_children(ircd_sup)) of
                        {Kind, Pid, _, _} when is_pid(Pid) ->
                            Port =
                                try inet:port(sys:get_state(Pid, 1000)) of
                                    {ok, P} -> P;
                                    _ -> 0
                                catch
                                    _:_ -> 0
                                end,
                            [#{transport => atom_to_binary(Kind), port => Port} | Acc];
                        _ ->
                            Acc
                    end
                end,
                [],
                [wss, ws, tls, tcp]
            )
    end.

format_listeners_text([]) ->
    <<"none">>;
format_listeners_text(List) ->
    iolist_to_binary(
        lists:join(
            <<", ">>,
            [
                [maps:get(transport, L), <<":">>, integer_to_binary(maps:get(port, L))]
             || L <- List
            ]
        )
    ).

parse_log_level(<<"trace">>) -> {ok, trace};
parse_log_level(<<"debug">>) -> {ok, debug};
parse_log_level(<<"info">>) -> {ok, info};
parse_log_level(<<"notice">>) -> {ok, notice};
parse_log_level(<<"warning">>) -> {ok, warning};
parse_log_level(<<"error">>) -> {ok, error};
parse_log_level(<<"critical">>) -> {ok, critical};
parse_log_level(<<"alert">>) -> {ok, alert};
parse_log_level(<<"emergency">>) -> {ok, emergency};
parse_log_level(_) -> error.

null_star(null) -> <<"*">>;
null_star(Bin) -> Bin.

to_bin(Bin) when is_binary(Bin) -> Bin;
to_bin(List) when is_list(List) -> unicode:characters_to_binary(List).

reply_ok(json, Map, _Text) ->
    {ok, iolist_to_binary(json:encode(Map))};
reply_ok(text, _Map, Text) ->
    {ok, iolist_to_binary(Text)}.

reply_error(json, Map, _Text) ->
    {error, iolist_to_binary(json:encode(Map))};
reply_error(text, _Map, Text) ->
    {error, iolist_to_binary(Text)}.

format_help(json) ->
    iolist_to_binary(
        json:encode(#{
            commands => [
                <<"status">>,
                <<"ping">>,
                <<"check-config [<path>]">>,
                <<"rehash">>,
                <<"reload-certs">>,
                <<"log-level [<level>]">>,
                <<"clients">>,
                <<"kick-client <nick> [<reason>]">>,
                <<"channels">>,
                <<"links">>,
                <<"connect <peer>">>,
                <<"squit <server> [<reason>]">>,
                <<"accounts">>,
                <<"create-account <name> <password> [<email>]">>,
                <<"delete-account <name>">>,
                <<"backup <file>">>,
                <<"drain [<reason>]">>,
                <<"stop [<reason>]">>,
                <<"help">>
            ],
            flags => [<<"--json">>]
        })
    );
format_help(text) ->
    <<
        "Usage: ircdctl [--json] <command> [args...]\n\n"
        "Commands:\n"
        "  status                                    Show server status, counts, listeners, and VM metrics\n"
        "  ping | health                             Check that ircd and Mnesia are alive\n"
        "  check-config [<path>]                     Validate JSON configuration and TLS certificate pairs\n"
        "  rehash                                    Reload configuration file live (no restart)\n"
        "  reload-certs                              Check and reload TLS certificates immediately\n"
        "  log-level [<level>]                       Show or change live log level (trace..emergency)\n"
        "  clients                                   List connected local clients\n"
        "  kick-client <nick> [<reason>]             Disconnect a local client\n"
        "  channels                                  List active and retained channels\n"
        "  links                                     List configured and active server links\n"
        "  connect <peer>                            Trigger connection attempt to a configured peer\n"
        "  squit <server> [<reason>]                 Split a known remote server\n"
        "  accounts                                  List registered SASL accounts\n"
        "  create-account <name> <password> [email]  Provision a verified SASL account\n"
        "  delete-account <name>                     Delete an account, its E2EE devices, and read markers\n"
        "  backup <file>                             Write a consistent online Mnesia backup to <file>\n"
        "  drain [<reason>]                          Gracefully drain listeners, links, and sessions\n"
        "  stop [<reason>]                           Gracefully drain and stop the server node\n"
        "  help                                      Show this help message"
    >>.
