-module(briskd_listener).
-moduledoc """
Owns one listen socket and accepts connections on it.

There is one listener per configured transport: `tcp`, `tls` (direct TLS,
TLS 1.2 and 1.3), `ws` (WebSocket over TCP), and `wss` (WebSocket over TLS).
The `gen_server` opens the socket on the configured `bind` address and logs
the bound port, which matters when the configured port is `0`. A linked accept
loop then admits each connection through `briskd_sessions:start_child/3`, makes
the new `m:briskd_session` the socket's controlling process, and sends it
`activate`. The TLS handshake runs in the session, so a slow handshake does not
block the accept loop.

A connection refused by `max_clients` is logged as `session_rejected` and
closed. When the process runs out of file descriptors or ports (`emfile`,
`enfile`, `system_limit`, `enobufs`, `enomem`), or a peer aborts before the
accept completes (`econnaborted`), the loop waits 100 milliseconds and accepts
again: pending connections stay in the kernel backlog and are taken once
sessions close. This is logged as `accept_exhausted` at `warning`, at most once
every 10 seconds with the number of failures since. Exiting instead made
`m:briskd_sup` restart a listener that failed the same way at once, and the
restart intensity then stopped the whole application. Any other accept error
ends the accept loop and, through the link, the listener, which `m:briskd_sup`
restarts. Sockets use `{active, false}` until the
session takes over, `nodelay` (Nagle's algorithm delays multi-line replies),
and a 5-second send timeout.
""".
-behaviour(gen_server).
%% Per-socket driver read buffer, bytes (see the listen options).
-define(RECV_BUFFER, 2048).
%% Pending connections queued by the kernel (see the listen options).
-define(LISTEN_BACKLOG, 1024).
%% Wait before accepting again after a resource-exhaustion error, ms.
-define(EXHAUSTED_BACKOFF_MS, 100).
%% Minimum interval between `accept_exhausted` warnings, ms (monotonic).
-define(EXHAUSTED_LOG_MS, 10000).
-export([start_link/3, port/1, init/1, handle_call/3, handle_cast/2, handle_info/2]).

-doc """
Start a listener for one transport on `Port`.

`Kind` is `tcp`, `tls`, `ws` (WebSocket), or `wss` (WebSocket over TLS).
`Config` is the normalized map from `briskd_config:load/1`; its `ip` is the bind
address and, for `tls` and `wss`, its `tls_options` configure the TLS listener.
Starting fails when the socket cannot be opened, for example when the port is
in use.
""".
-spec start_link(tcp | tls | ws | wss, inet:port_number(), map()) -> gen_server:start_ret().
start_link(Kind, Port, Config) ->
    gen_server:start_link(?MODULE, {Kind, Port, Config}, [{hibernate_after, 15000}]).

-doc """
The local port the listener `Listener` is bound to, or `error` when it does
not answer within one second. Used by `briskdctl status`.
""".
-spec port(pid()) -> {ok, inet:port_number()} | error.
port(Listener) ->
    try gen_server:call(Listener, port, 1000) of
        {ok, Port} when is_integer(Port), Port >= 0, Port =< 65535 -> {ok, Port};
        _ -> error
    catch
        exit:_ -> error
    end.

-doc false.
init({Kind, Port, #{ip := IP, tls_options := TLSOptions}}) ->
    Family =
        case tuple_size(IP) of
            4 -> inet;
            8 -> inet6
        end,
    Options = [
        Family,
        binary,
        {ip, IP},
        {active, false},
        {packet, raw},
        {reuseaddr, true},
        %% Interactive sessions: a reply usually spans several small sends
        %% (numerics, then the next line). Without nodelay, Nagle holds each
        %% later send until the client ACKs the first, and delayed ACK makes
        %% that ~40 ms per multi-line reply. bench/traffic.py's command matrix
        %% measured median p50 41.98 ms without it and 0.85 ms with it.
        {nodelay, true},
        %% The driver keeps a read buffer of this size for every socket.
        %% The default (9216 bytes here) was over half of each idle
        %% client's memory (16.6 KiB per client, ~9 KiB of it this buffer).
        %% An IRC line is at most
        %% 512 bytes plus an optional tag section, and longer input is read
        %% in several pieces and joined by the session's line buffer.
        {buffer, ?RECV_BUFFER},
        %% Connections the kernel queues before accept/1 takes them. The
        %% gen_tcp default is 5: with hundreds of clients connecting at once
        %% the queue overflowed, the kernel dropped the attempts, and the
        %% clients' retries (1 s, 3 s, 7 s, ...) made registration take tens of
        %% seconds or fail (bench/traffic.py high-load phase). The kernel caps it at
        %% net.core.somaxconn.
        {backlog, ?LISTEN_BACKLOG},
        {send_timeout, 5000}
    ],
    case listen(Kind, Port, Options, TLSOptions) of
        {ok, Socket} ->
            {ok, {_, ActualPort}} = sockname(Kind, Socket),
            logger:notice(#{event => listening, transport => Kind, port => ActualPort, ip => IP}),
            spawn_link(fun() -> accept(Kind, Socket) end),
            {ok, Socket};
        Error ->
            {stop, Error}
    end.

-doc false.
handle_call(port, _From, Socket) ->
    %% The state is the listen socket: a port for tcp and ws, an sslsocket for
    %% tls and wss (inet:port/1 does not accept the latter).
    Name =
        case is_port(Socket) of
            true -> inet:sockname(Socket);
            false -> ssl:sockname(Socket)
        end,
    Reply =
        case Name of
            {ok, {_, Port}} -> {ok, Port};
            _ -> error
        end,
    {reply, Reply, Socket};
handle_call(_, _, State) ->
    {reply, {error, unsupported}, State}.
-doc false.
handle_cast(_, State) -> {noreply, State}.
-doc false.
handle_info(_, State) -> {noreply, State}.

base(tcp) -> tcp;
base(ws) -> tcp;
base(tls) -> tls;
base(wss) -> tls.

listen(Kind, Port, Options, TLS) ->
    case base(Kind) of
        tcp -> gen_tcp:listen(Port, Options);
        tls -> ssl:listen(Port, Options ++ TLS)
    end.

sockname(Kind, Socket) ->
    case base(Kind) of
        tcp -> inet:sockname(Socket);
        tls -> ssl:sockname(Socket)
    end.

accept(Kind, Listener) ->
    accept(Kind, Listener, undefined).

%% Exhausted is undefined, or {LastLogMs, FailuresSinceLog} while accept
%% keeps failing for lack of descriptors or memory.
accept(Kind, Listener, Exhausted) ->
    case transport_accept(Kind, Listener) of
        {ok, Socket} ->
            handoff(Kind, Socket),
            accept(Kind, Listener, Exhausted);
        {error, Reason} when
            Reason =:= emfile;
            Reason =:= enfile;
            Reason =:= system_limit;
            Reason =:= enobufs;
            Reason =:= enomem;
            Reason =:= econnaborted
        ->
            Next = note_exhausted(Kind, Reason, Exhausted, erlang:monotonic_time(millisecond)),
            receive
            after ?EXHAUSTED_BACKOFF_MS -> ok
            end,
            accept(Kind, Listener, Next);
        {error, Reason} ->
            logger:error(#{event => accept_failed, transport => Kind, reason => Reason}),
            exit({accept_failed, Reason})
    end.

note_exhausted(Kind, Reason, undefined, Now) ->
    log_exhausted(Kind, Reason, 1),
    {Now, 0};
note_exhausted(Kind, Reason, {Last, Count}, Now) when Now - Last >= ?EXHAUSTED_LOG_MS ->
    log_exhausted(Kind, Reason, Count + 1),
    {Now, 0};
note_exhausted(_Kind, _Reason, {Last, Count}, _Now) ->
    {Last, Count + 1}.

log_exhausted(Kind, Reason, Failures) ->
    logger:warning(#{
        event => accept_exhausted, transport => Kind, reason => Reason, failures => Failures
    }).

transport_accept(Kind, Listener) ->
    case base(Kind) of
        tcp -> gen_tcp:accept(Listener);
        tls -> ssl:transport_accept(Listener)
    end.

handoff(Kind, Socket) ->
    {Module, PeerResult} =
        case base(Kind) of
            tcp -> {gen_tcp, inet:peername(Socket)};
            tls -> {ssl, ssl:peername(Socket)}
        end,
    Peer =
        case PeerResult of
            %% A host beginning with ':' (IPv6 such as ::1) would be read
            %% as a trailing parameter in WHO replies; prefix it with 0.
            {ok, {Address, _}} when is_tuple(Address) ->
                case briskd_wire:ip_text(Address) of
                    <<$:, _/binary>> = Text -> <<$0, Text/binary>>;
                    Text -> Text
                end;
            _ ->
                <<"unknown">>
        end,
    case briskd_sessions:start_child(Kind, Socket, Peer) of
        {ok, Pid} when is_pid(Pid) ->
            case Module:controlling_process(Socket, Pid) of
                ok ->
                    ok = briskd_stats:count_connection(),
                    Pid ! activate;
                {error, Reason} ->
                    logger:warning(#{
                        event => session_handoff_failed, peer => Peer, reason => Reason
                    }),
                    exit(Pid, shutdown),
                    Module:close(Socket)
            end;
        {error, max_clients} ->
            ok = briskd_stats:count_rejected(),
            logger:warning(#{event => session_rejected, peer => Peer, reason => max_clients}),
            Module:close(Socket);
        {error, Reason} ->
            logger:warning(#{event => session_rejected, peer => Peer, reason => Reason}),
            Module:close(Socket)
    end.
