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
- `set-email <name> [<email>]`: set or clear an account's email address.
- `add-certfp <name> <sha256>` / `remove-certfp <name> <sha256>`: manage the
  client certificate fingerprints an account accepts for SASL EXTERNAL.
- `create-channel <name> [<topic>]`: create an empty `#`, `&`, or `+` channel.
- `delete-channel <name> [<reason>]`: kick every local member (as the server)
  and delete the channel, its history, and its metadata. Configured channels
  are refused.
- `set-channel-modes <name> <modes> [<args>...]`: apply channel modes as the
  server (including list modes `b`/`e`/`I` and server-only `q`), announced to
  members and peers.
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

-define(MAX_CTL_BYTES, 65536).

%% A state-changing control action, run inside ircd_state (ircd_state:ctl/1).
%% Every binary comes from a control-socket argument.
-type state_action() ::
    rehash
    | {set_log_level, binary()}
    | {kick_client, binary(), binary()}
    | {squit, binary(), binary()}
    | {create_account, binary(), binary(), undefined | binary()}
    | {notice_all, binary()}
    | {set_topic, binary(), binary()}
    | {notice_channel, binary(), binary()}
    | {reset_password, binary(), binary()}
    | {verify_account, binary()}
    | {delete_account, binary()}
    | {erase_account, binary()}
    | {create_channel, binary(), binary()}
    | {delete_channel, binary(), binary()}
    | {set_channel_modes, binary(), binary(), [binary()]}
    | {set_email, binary(), binary() | undefined}
    | {add_certfp, binary(), binary()}
    | {remove_certfp, binary(), binary()}.
-export_type([state_action/0]).

-doc """
Start the local Unix-domain control socket server under `m:ircd_sup`.

Listens on `socket_path/1` (`IRCD_CTL_SOCKET` or `<mnesia_dir>/ircdctl.sock`)
with mode `0600` so only the OS user running `ircd` may connect. If the path
exceeds the OS Unix socket path limit or cannot be bound, the server starts
without a socket while `run/1` and `cli/1` remain usable in-process.
""".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, [
        {hibernate_after, 15000},
        {spawn_opt, [{fullsweep_after, 20}]}
    ]).

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
    Bins = [Bin || A <- RawArgs, Bin <- [to_bin(A)], is_binary(Bin)],
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
                    {ok, Reply} when is_binary(Reply) ->
                        case json:decode(Reply) of
                            #{<<"ok">> := true, <<"output">> := Output} when is_binary(Output) ->
                                {ok, Output};
                            #{<<"ok">> := false, <<"output">> := Output} when is_binary(Output) ->
                                {error, Output};
                            _ ->
                                {error, <<"Invalid response from ircd control socket">>}
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
    case socket_path_fits(Path) of
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
            {ok, Payload} when is_binary(Payload), byte_size(Payload) =< ?MAX_CTL_BYTES ->
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
-spec run([term()]) -> {ok, binary()} | {error, binary()}.
run(RawArgs) ->
    case text_args(RawArgs, []) of
        {ok, Bins} ->
            Format =
                case lists:member(<<"--json">>, Bins) of
                    true -> json;
                    false -> text
                end,
            Args = [A || A <- Bins, A =/= <<"--json">>],
            dispatch(Args, Format);
        error ->
            {error, <<"Invalid control request">>}
    end.

%% Every argument of a control request must be text (a JSON string).
text_args([], Acc) ->
    {ok, lists:reverse(Acc)};
text_args([Arg | Rest], Acc) ->
    case to_bin(Arg) of
        error -> error;
        Bin -> text_args(Rest, [Bin | Acc])
    end.

-doc """
Execute a state-mutating control action inside the `m:ircd_state` process.
Called only from `ircd_state:handle_call({ctl, Action}, ...)`.
""".
-spec handle_state_action(state_action(), binary()) -> {ok, map()} | {error, term()}.
handle_state_action(rehash, Server) ->
    case ircd_state_info:rehash_server(Server) of
        {ok, Path} -> {ok, #{status => <<"rehashed">>, config_path => Path}};
        {error, Reason} -> {error, Reason}
    end;
handle_state_action({set_log_level, LevelBin}, _Server) ->
    case ircd_config:parse_log_level(LevelBin) of
        {ok, Level} ->
            Config = ircd_config:current(),
            ircd_config:store(Config#{level => Level}),
            %% Kept by a later override change, which rebuilds the
            %% effective configuration from the file's.
            ircd_config:store_base((ircd_config:base())#{level => Level}),
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
            ircd_state_net:drop_server(Name, Reason, undefined),
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
     || Pid <- ircd_state_client:pids(),
        [#client{} = Client] <- [mnesia:dirty_read(client, Pid)],
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
handle_state_action({notice_channel, ChannelName, Text}, Server) ->
    Key = ircd_wire:fold(ChannelName),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            {error, {no_such_channel, ChannelName}};
        [#channel{name = Actual, members = Members}] ->
            Pids = maps:keys(Members),
            ircd_state_send:broadcast(Pids, Server, <<"NOTICE">>, [Actual], Text),
            logger:notice(#{
                event => ctl_notice_channel, channel => Actual, recipients => length(Pids)
            }),
            {ok, #{status => <<"sent">>, channel => Actual, recipients => length(Pids)}}
    end;
handle_state_action({reset_password, Name, Password}, _Server) ->
    case ircd_account:set_password(Name, Password) of
        {ok, #account{name = Actual} = Updated} ->
            logger:notice(#{event => ctl_password_reset, account => Actual}),
            ircd_state_sync:account_created(Updated),
            {ok, #{status => <<"password_updated">>, account => Actual}};
        {error, Reason} ->
            {error, Reason}
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
                                        [#client{} = Client] ->
                                            ircd_state_v3:logout(Client, Server);
                                        [] ->
                                            ok
                                    end;
                                false ->
                                    ok
                            end;
                        _ ->
                            ok
                    end
                end,
                ircd_state_client:pids()
            ),
            lists:foreach(
                fun
                    ({Acct, _} = MarkerKey) when Acct =:= Key ->
                        mnesia:dirty_delete(read_marker, MarkerKey);
                    (_) ->
                        ok
                end,
                ircd_state:table_keys(read_marker)
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
            %% Channels saved for rejoin at its next login (account_rejoin).
            case ets:whereis(ircd_account_channels) of
                undefined -> ok;
                _ -> ets:delete(ircd_account_channels, Key)
            end,
            logger:notice(#{event => ctl_account_deleted, account => Actual}),
            {ok, #{status => <<"deleted">>, account => Actual}}
    end;
handle_state_action({erase_account, Name}, Server) ->
    %% "Delete my data" (WebIRC settings): the account as delete_account
    %% removes it, then what it wrote from stored history.
    case handle_state_action({delete_account, Name}, Server) of
        {ok, #{account := Actual} = Reply} ->
            #{channel := C, direct := D} = ircd_state_history:erase_account(
                ircd_wire:fold(Actual)
            ),
            logger:notice(#{event => account_erased, channel_messages => C, direct_messages => D}),
            {ok, Reply#{channel_messages => C, direct_messages => D}};
        Other ->
            Other
    end;
handle_state_action({create_channel, Name, Topic}, Server) ->
    case ircd_state_channel:admin_create(Name, Topic, Server) of
        {ok, Actual} ->
            logger:notice(#{event => ctl_channel_created, channel => Actual}),
            {ok, #{status => <<"created">>, channel => Actual}};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({delete_channel, Name, Reason}, Server) ->
    case ircd_state_channel:admin_destroy(Name, Reason, Server) of
        {ok, Actual, Kicked} ->
            logger:notice(#{event => ctl_channel_deleted, channel => Actual, kicked => Kicked}),
            {ok, #{status => <<"deleted">>, channel => Actual, kicked => Kicked}};
        {error, Why} ->
            {error, Why}
    end;
handle_state_action({set_channel_modes, Name, Modes, Args}, Server) ->
    case ircd_state_channel:admin_mode(Name, Modes, Args, Server) of
        {ok, _Actual, <<>>, _Shown, [First | _]} ->
            %% Nothing applied: report why (the first refusal).
            {error, {mode_refused, First}};
        {ok, Actual, Applied, Shown, Errors} ->
            %% The mode string only: parameters may include a channel key.
            logger:notice(#{event => ctl_channel_modes, channel => Actual, modes => Applied}),
            {ok, #{
                status => <<"updated">>,
                channel => Actual,
                applied => Applied,
                params => Shown,
                errors => Errors
            }};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({set_email, Name, Email}, _Server) ->
    case Email =:= undefined orelse ircd_state_v3:valid_email(Email) of
        false ->
            {error, invalid_email};
        true ->
            case ircd_account:set_email(Name, Email) of
                {ok, #account{name = Actual}} ->
                    logger:notice(#{event => ctl_account_email_set, account => Actual}),
                    {ok, #{status => <<"updated">>, account => Actual}};
                {error, Reason} ->
                    {error, Reason}
            end
    end;
handle_state_action({add_certfp, Name, Fp}, _Server) ->
    case ircd_account:add_certfp(Name, Fp) of
        {ok, #account{name = Actual, certfps = Fps}} ->
            logger:notice(#{event => ctl_account_certfp_added, account => Actual}),
            {ok, #{status => <<"updated">>, account => Actual, certfps => Fps}};
        {error, Reason} ->
            {error, Reason}
    end;
handle_state_action({remove_certfp, Name, Fp}, _Server) ->
    case ircd_account:remove_certfp(Name, Fp) of
        {ok, #account{name = Actual, certfps = Fps}} ->
            logger:notice(#{event => ctl_account_certfp_removed, account => Actual}),
            {ok, #{status => <<"updated">>, account => Actual, certfps => Fps}};
        {error, Reason} ->
            {error, Reason}
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
dispatch([<<"search">> | _], Format) ->
    cmd_search(Format);
dispatch([<<"search-rebuild">> | _], Format) ->
    case ircd_search:rebuild_now() of
        ok ->
            reply_ok(
                Format,
                #{status => <<"rebuilding">>},
                <<"Message search index rebuild started">>
            );
        {error, not_configured} ->
            reply_error(
                Format,
                #{status => <<"error">>, reason => <<"not_configured">>},
                <<"Message search is not configured">>
            )
    end;
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
dispatch([<<"notice-channel">>, Channel, Text | _], Format) when
    byte_size(Text) > 0, byte_size(Text) =< 400
->
    cmd_state_call({notice_channel, Channel, Text}, Format, fun(#{channel := C, recipients := N}) ->
        <<"Sent notice to ", C/binary, " (", (integer_to_binary(N))/binary, " users)">>
    end);
dispatch([<<"reset-password">>, Name, Password | _], Format) ->
    cmd_state_call({reset_password, Name, Password}, Format, fun(#{account := A}) ->
        <<"Updated password for ", A/binary>>
    end);
dispatch([<<"verify-account">>, Name | _], Format) ->
    cmd_state_call({verify_account, Name}, Format, fun(#{account := A}) ->
        <<"Verified account ", A/binary>>
    end);
dispatch([<<"delete-account">>, Name | _], Format) ->
    cmd_state_call({delete_account, Name}, Format, fun(#{account := A}) ->
        <<"Deleted account ", A/binary>>
    end);
dispatch([<<"create-channel">>, Name | Rest], Format) ->
    Topic =
        case Rest of
            [T | _] when byte_size(T) =< 390 -> T;
            _ -> <<>>
        end,
    cmd_state_call({create_channel, Name, Topic}, Format, fun(#{channel := C}) ->
        <<"Created channel ", C/binary>>
    end);
dispatch([<<"delete-channel">>, Name | Rest], Format) ->
    Reason =
        case Rest of
            [R | _] when R =/= <<>>, byte_size(R) =< 300 -> R;
            _ -> <<"Channel closed by administrator">>
        end,
    cmd_state_call({delete_channel, Name, Reason}, Format, fun(#{channel := C, kicked := N}) ->
        <<"Deleted channel ", C/binary, " (", (integer_to_binary(N))/binary, " members removed)">>
    end);
dispatch([<<"set-channel-modes">>, Name, Modes | Args], Format) when
    byte_size(Modes) =< 32, length(Args) =< 12
->
    case valid_mode_args(Modes, Args) of
        true ->
            cmd_state_call(
                {set_channel_modes, Name, Modes, Args},
                Format,
                fun(#{channel := C, applied := A, errors := E}) ->
                    iolist_to_binary([
                        <<"Modes of ">>,
                        C,
                        <<": ">>,
                        case A of
                            <<>> -> <<"no change">>;
                            _ -> A
                        end,
                        [[<<"\n">>, Err] || Err <- E]
                    ])
                end
            );
        false ->
            reply_error(Format, #{error => <<"invalid_modes">>}, <<"Invalid mode string">>)
    end;
dispatch([<<"set-email">>, Name | Rest], Format) ->
    Email =
        case Rest of
            [E | _] when E =/= <<>>, E =/= <<"*">> -> E;
            _ -> undefined
        end,
    cmd_state_call({set_email, Name, Email}, Format, fun(#{account := A}) ->
        <<"Updated email of ", A/binary>>
    end);
dispatch([<<"add-certfp">>, Name, Fp | _], Format) ->
    cmd_state_call({add_certfp, Name, Fp}, Format, fun(#{account := A}) ->
        <<"Added a certificate fingerprint to ", A/binary>>
    end);
dispatch([<<"remove-certfp">>, Name, Fp | _], Format) ->
    cmd_state_call({remove_certfp, Name, Fp}, Format, fun(#{account := A}) ->
        <<"Removed a certificate fingerprint from ", A/binary>>
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
            Config = ircd_config:current_or_empty(),
            StartedAt = persistent_term:get(
                {ircd_state, started_at}, erlang:monotonic_time(second)
            ),
            Uptime = max(0, erlang:monotonic_time(second) - StartedAt),
            StartedIso = list_to_binary(
                persistent_term:get({ircd_state, started}, "unknown")
            ),
            Clients = [
                C
             || Pid <- ircd_state_client:pids(),
                [#client{} = C] <- [mnesia:dirty_read(client, Pid)]
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
                remote_users => table_size(remote_client),
                channels => table_size(channel),
                remote_channels => table_size(remote_channel),
                known_servers => table_size(known_server),
                services => table_size(service),
                accounts => length(ircd_account:list()),
                db_disk_bytes => mnesia_disk_bytes(),
                db_memory_bytes => mnesia_memory_bytes(),
                db_tables => length(mnesia_tables()),
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
                <<"Database:         ">>,
                integer_to_binary(maps:get(db_disk_bytes, Map) div 1024),
                <<" KiB disk, ">>,
                integer_to_binary(maps:get(db_memory_bytes, Map) div 1024),
                <<" KiB RAM (">>,
                integer_to_binary(maps:get(db_tables, Map)),
                <<" tables)\n">>,
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

cmd_search(Format) ->
    Info = ircd_search:info(),
    Service = maps:get(service, Info, #{}),
    Text =
        case Info of
            #{status := not_configured} ->
                <<"Message search: not configured">>;
            _ ->
                iolist_to_binary(
                    io_lib:format(
                        "Message search: ~ts (~ts), ~b queued, ~b rebuilds~n"
                        "Service: ~ts",
                        [
                            maps:get(status, Info),
                            case maps:get(enabled, Info) of
                                true -> "on";
                                false -> "switched off"
                            end,
                            maps:get(queued, Info, 0),
                            maps:get(rebuilds, Info, 0),
                            case Service of
                                #{reachable := true, docs := Docs, bytes := Bytes} ->
                                    io_lib:format("~b messages, ~p bytes", [Docs, Bytes]);
                                #{error := Error} ->
                                    io_lib:format("unreachable (~ts)", [Error]);
                                _ ->
                                    "unknown"
                            end
                        ]
                    )
                )
        end,
    reply_ok(Format, Info, Text).

cmd_get_log_level(Format) ->
    Config = ircd_config:current_or_empty(),
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
     || Pid <- ircd_state_client:pids(),
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
            _ -> binary:join(Lines, <<"\n">>)
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
                predefined => ircd_state:predefined_channel(Key),
                %% Whether a key is set; the key itself is not shown.
                has_key => Password =/= undefined,
                limit =>
                    case Limit of
                        undefined -> null;
                        _ -> Limit
                    end,
                bans => maps:get(ban, Lists, []),
                exceptions => maps:get(exception, Lists, []),
                invites => maps:get(invite, Lists, [])
            }
        end
     || Key <- ircd_state:table_keys(channel),
        [
            #channel{
                name = Name,
                members = Members,
                flags = Flags,
                topic = Topic,
                password = Password,
                limit = Limit,
                lists = Lists
            }
        ] <- [
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
            _ -> binary:join(Lines, <<"\n">>)
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
     || Key <- ircd_state:table_keys(known_server),
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
                binary:join(Lines, <<"\n">>)
        end,
    reply_ok(
        Format,
        #{configured => Configured, connected => Known, count => length(Known)},
        Text
    ).

cmd_connect(Peer, Format) ->
    case ircd_state_net:configured_peer(Peer) of
        {ok, Name} ->
            _ = ircd_links:connect_peer(Name),
            reply_ok(
                Format,
                #{status => <<"connecting">>, peer => Name},
                <<"Triggered connection attempt for ", Name/binary>>
            );
        error ->
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
            certfp_list => Fps,
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
            _ -> binary:join(Lines, <<"\n">>)
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
    erlang:spawn(fun init:stop/0),
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

%% A mode string of `+`, `-`, and letters, and parameters that are each one
%% non-empty IRC middle parameter (no space, not starting with `:`, no
%% CR/LF/NUL), as MODE would carry them.
valid_mode_args(Modes, Args) ->
    Modes =/= <<>> andalso
        lists:all(
            fun(C) ->
                C =:= $+ orelse C =:= $- orelse (C >= $a andalso C =< $z) orelse
                    (C >= $A andalso C =< $Z)
            end,
            binary_to_list(Modes)
        ) andalso
        lists:all(
            fun(A) ->
                A =/= <<>> andalso byte_size(A) =< 200 andalso binary:first(A) =/= $: andalso
                    binary:match(A, [<<" ">>, <<"\r">>, <<"\n">>, <<0>>]) =:= nomatch
            end,
            Args
        ).

%% A Unix socket path is at most 100 bytes here (sun_path is 104 or 108); the
%% path may hold any Unicode characters, so count its UTF-8 bytes.
socket_path_fits(Path) ->
    case unicode:characters_to_binary(Path) of
        Bin when is_binary(Bin) -> byte_size(Bin) =< 100;
        _ -> false
    end.

%% mnesia:system_info/1 and mnesia:table_info/2 return term(); these narrow
%% the results this module uses.
-spec mnesia_tables() -> [atom()].
mnesia_tables() ->
    case mnesia:system_info(tables) of
        Tables when is_list(Tables) -> [T || T <- Tables, is_atom(T)];
        _ -> []
    end.

-spec table_size(atom()) -> non_neg_integer().
table_size(Table) ->
    case mnesia:table_info(Table, size) of
        Size when is_integer(Size), Size >= 0 -> Size;
        _ -> 0
    end.

mnesia_disk_bytes() ->
    case mnesia:system_info(directory) of
        Dir when is_list(Dir) -> dir_bytes(Dir);
        _ -> 0
    end.

dir_bytes(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:foldl(
                fun(Name, Acc) ->
                    Path = filename:join(Dir, Name),
                    case filelib:is_regular(Path) of
                        true -> Acc + filelib:file_size(Path);
                        false -> Acc
                    end
                end,
                0,
                Files
            );
        {error, _} ->
            0
    end.

mnesia_memory_bytes() ->
    WordSize = erlang:system_info(wordsize),
    lists:foldl(
        fun(Table, Acc) ->
            try mnesia:table_info(Table, memory) of
                Words when is_integer(Words) -> Acc + Words * WordSize;
                _ -> Acc
            catch
                _:_ -> Acc
            end
        end,
        0,
        mnesia_tables()
    ).

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
                                case ircd_listener:port(Pid) of
                                    {ok, P} -> P;
                                    error -> 0
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

null_star(null) -> <<"*">>;
null_star(Bin) -> Bin.

-spec to_bin(term()) -> binary() | error.
to_bin(Bin) when is_binary(Bin) ->
    Bin;
to_bin(List) when is_list(List) ->
    case code_points(List, []) of
        {ok, Chars} ->
            case unicode:characters_to_binary(Chars) of
                Bin when is_binary(Bin) -> Bin;
                _ -> error
            end;
        error ->
            error
    end;
to_bin(_) ->
    error.

%% A list argument must be a flat list of Unicode code points.
code_points([], Acc) ->
    {ok, lists:reverse(Acc)};
code_points([C | Rest], Acc) when is_integer(C), C >= 0, C =< 16#10FFFF ->
    code_points(Rest, [C | Acc]);
code_points(_, _) ->
    error.

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
                <<"search">>,
                <<"search-rebuild">>,
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
                <<"set-email <name> [<email>]">>,
                <<"add-certfp <name> <sha256>">>,
                <<"remove-certfp <name> <sha256>">>,
                <<"create-channel <name> [<topic>]">>,
                <<"delete-channel <name> [<reason>]">>,
                <<"set-channel-modes <name> <modes> [<args>...]">>,
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
        "  search                                    Message search status and index size\n"
        "  search-rebuild                            Rebuild the message search index now\n"
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
        "  set-email <name> [<email>]                Set or clear an account's email address\n"
        "  add-certfp <name> <sha256>                Allow a client certificate for SASL EXTERNAL\n"
        "  remove-certfp <name> <sha256>             Remove an allowed client certificate\n"
        "  create-channel <name> [<topic>]           Create an empty channel (#, &, or +)\n"
        "  delete-channel <name> [<reason>]          Remove all members and delete a channel\n"
        "  set-channel-modes <name> <modes> [args]   Change channel modes as the server\n"
        "  backup <file>                             Write a consistent online Mnesia backup to <file>\n"
        "  drain [<reason>]                          Gracefully drain listeners, links, and sessions\n"
        "  stop [<reason>]                           Gracefully drain and stop the server node\n"
        "  help                                      Show this help message"
    >>.
