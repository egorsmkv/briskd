-module(briskd_ctl).
-moduledoc """
Administrative control and inspection backend for the `bin/briskdctl` DevOps
CLI.

`run/1` accepts a list of command-line arguments (strings or binaries),
supports `--json` output on every subcommand for monitoring and automation,
and returns `{ok, Output}` or `{error, Output}`. `cli/1` prints the output and
returns exit status `0` or `1`. State-mutating operations (`rehash`,
`log-level <level>`, `kick-client`, `squit`, `create-account`,
`delete-account`) execute inside `m:briskd_state` via `briskd_state:ctl/1`
(`handle_state_action/2`) so protocol state retains its single-writer
invariant.

Subcommands:

- `status`: server summary, listeners, client/user/channel/link/account
  counts, retention, log level, and VM memory/process metrics.
- `ping`: health probe checking `briskd_state`, `briskd_sessions`, `briskd_links`,
  and Mnesia.
- `check-config [<path>]`: offline or online validation of a JSON config file
  (`m:briskd_config`) and its TLS certificate/key pairs (`m:briskd_certs`).
- `rehash`: live reload of the configuration file (`briskd_rehash:rehash_server/1`).
- `reload-certs`: synchronous TLS certificate reload (`briskd_certs:check_now/0`).
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
- `drain [<reason>]`: gracefully drain listeners, peers, and clients (`m:briskd_shutdown`).
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
    reply_error/3,
    reply_ok/3,
    run/1,
    socket_path/1,
    start_link/1,
    terminate/2
]).

-define(MAX_CTL_BYTES, 65536).

-doc """
State-changing control action, applied inside `briskd_state`
(`briskd_state:ctl/1`). Every binary is taken from a control-socket argument.
""".
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
Start the local Unix-domain control socket server under `m:briskd_sup`.

Listens on `socket_path/1` (`BRISKD_CTL_SOCKET` or `<mnesia_dir>/briskdctl.sock`)
with mode `0600` so only the OS user running `briskd` may connect. If the path
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
Return the Unix domain socket path used by `bin/briskdctl` for `Config`.
Honors `BRISKD_CTL_SOCKET` when set; otherwise `<mnesia_dir>/briskdctl.sock`.
""".
-spec socket_path(map()) -> file:filename_all().
socket_path(Config) ->
    case os:getenv("BRISKD_CTL_SOCKET") of
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
    filename:join(Dir, "briskdctl.sock").

-doc """
Client entry point invoked by `bin/briskdctl`.

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
                                    "Failed to connect to briskd control socket ~s: ~p",
                                    [Path, Reason]
                                )
                            ),
                            io:put_chars(standard_error, [Msg, "\n"]),
                            1
                    end
            end
    end.

resolve_client_socket_path() ->
    case os:getenv("BRISKD_CTL_SOCKET") of
        false ->
            CfgPath = os:getenv("BRISKD_CONFIG", "config/briskd.json"),
            case briskd_config:load(CfgPath) of
                {ok, Config} -> socket_path(Config);
                {error, _} -> "data/mnesia/briskdctl.sock"
            end;
        "" ->
            "data/mnesia/briskdctl.sock";
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
                                {error, <<"Invalid response from briskd control socket">>}
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
Execute an `briskdctl` command given its argument list.

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
Execute a state-mutating control action inside the `m:briskd_state` process.
Called only from `briskd_state:handle_call({ctl, Action}, ...)`.
""".
-spec handle_state_action(state_action(), binary()) -> {ok, map()} | {error, term()}.
handle_state_action(Action, Server) ->
    briskd_ctl_actions:handle_state_action(Action, Server).

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
    briskd_ctl_actions:cmd_ping(Format);
dispatch([<<"health">> | _], Format) ->
    briskd_ctl_actions:cmd_ping(Format);
dispatch([<<"status">> | _], Format) ->
    briskd_ctl_actions:cmd_status(Format);
dispatch([<<"check-config">> | Rest], Format) ->
    briskd_ctl_actions:cmd_check_config(Rest, Format);
dispatch([<<"rehash">> | _], Format) ->
    cmd_state_call(rehash, Format, fun(#{config_path := Path}) ->
        <<"Rehashed configuration from ", Path/binary>>
    end);
dispatch([<<"reload-certs">> | _], Format) ->
    briskd_ctl_actions:cmd_reload_certs(Format);
dispatch([<<"search">> | _], Format) ->
    briskd_ctl_actions:cmd_search(Format);
dispatch([<<"search-rebuild">> | _], Format) ->
    case briskd_search:rebuild_now() of
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
    briskd_ctl_actions:cmd_get_log_level(Format);
dispatch([<<"log-level">>, Level | _], Format) ->
    cmd_state_call({set_log_level, Level}, Format, fun(#{log_level := L}) ->
        <<"Log level set to ", L/binary>>
    end);
dispatch([<<"clients">> | _], Format) ->
    briskd_ctl_actions:cmd_clients(Format);
dispatch([<<"kick-client">>, Nick | Rest], Format) ->
    Reason =
        case Rest of
            [R | _] -> R;
            [] -> <<"Disconnected by administrator (briskdctl)">>
        end,
    cmd_state_call({kick_client, Nick, Reason}, Format, fun(#{nick := N}) ->
        <<"Disconnected client ", N/binary>>
    end);
dispatch([<<"channels">> | _], Format) ->
    briskd_ctl_actions:cmd_channels(Format);
dispatch([<<"links">> | _], Format) ->
    briskd_ctl_actions:cmd_links(Format);
dispatch([<<"connect">>, Peer | _], Format) ->
    briskd_ctl_actions:cmd_connect(Peer, Format);
dispatch([<<"squit">>, Target | Rest], Format) ->
    Reason =
        case Rest of
            [R | _] -> R;
            [] -> <<"SQUIT by administrator (briskdctl)">>
        end,
    cmd_state_call({squit, Target, Reason}, Format, fun(#{server := S}) ->
        <<"Split server ", S/binary>>
    end);
dispatch([<<"accounts">> | _], Format) ->
    briskd_ctl_actions:cmd_accounts(Format);
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
    briskd_ctl_actions:cmd_backup(File, Format);
dispatch([<<"drain">> | Rest], Format) ->
    Reason =
        case Rest of
            [R | _] -> R;
            [] -> <<"Server maintenance">>
        end,
    briskd_ctl_actions:cmd_drain(Reason, Format);
dispatch([<<"stop">> | Rest], Format) ->
    Reason =
        case Rest of
            [R | _] -> R;
            [] -> <<"Server shutting down">>
        end,
    briskd_ctl_actions:cmd_stop(Reason, Format);
dispatch([Unknown | _], Format) ->
    reply_error(Format, #{error => <<"unknown_command">>, command => Unknown}, [
        <<"Unknown command or missing arguments: ">>,
        Unknown,
        <<" (run 'briskdctl help')">>
    ]).

cmd_state_call(Action, Format, TextFun) ->
    case whereis(briskd_state) of
        undefined ->
            reply_error(
                Format,
                #{error => <<"not_running">>},
                <<"briskd_state is not running">>
            );
        _ ->
            case briskd_state:ctl(Action) of
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

-doc "Encode a successful `briskdctl` response as JSON or text.".
-spec reply_ok(json | text, map(), iodata()) -> {ok, binary()}.
reply_ok(json, Map, _Text) ->
    {ok, iolist_to_binary(json:encode(Map))};
reply_ok(text, _Map, Text) ->
    {ok, iolist_to_binary(Text)}.

-doc "Encode an error `briskdctl` response as JSON or text.".
-spec reply_error(json | text, map(), iodata()) -> {error, binary()}.
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
        "Usage: briskdctl [--json] <command> [args...]\n\n"
        "Commands:\n"
        "  status                                    Show server status, counts, listeners, and VM metrics\n"
        "  ping | health                             Check that briskd and Mnesia are alive\n"
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
