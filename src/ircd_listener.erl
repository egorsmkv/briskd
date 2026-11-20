-module(ircd_listener).
-moduledoc """
Owns one listen socket and accepts connections on it.

There is one listener per configured transport: `tcp`, `tls` (direct TLS,
TLS 1.2 and 1.3), `ws` (WebSocket over TCP), and `wss` (WebSocket over TLS).
The `gen_server` opens the socket on the configured `bind` address and logs
the bound port, which matters when the configured port is `0`. A linked accept
loop then admits each connection through `ircd_sessions:start_child/3`, makes
the new `m:ircd_session` the socket's controlling process, and sends it
`activate`. The TLS handshake runs in the session, so a slow handshake does not
block the accept loop.

A connection refused by `max_clients` is logged as `session_rejected` and
closed. An accept error ends the accept loop and, through the link, the
listener, which `m:ircd_sup` restarts. Sockets use `{active, false}` until the
session takes over, `nodelay` (Nagle's algorithm delays multi-line replies),
and a 5-second send timeout.
""".
-behaviour(gen_server).
-export([start_link/3, port/1, init/1, handle_call/3, handle_cast/2, handle_info/2]).

-doc """
Start a listener for one transport on `Port`.

`Kind` is `tcp`, `tls`, `ws` (WebSocket), or `wss` (WebSocket over TLS).
`Config` is the normalized map from `ircd_config:load/1`; its `ip` is the bind
address and, for `tls` and `wss`, its `tls_options` configure the TLS listener.
Starting fails when the socket cannot be opened, for example when the port is
in use.
""".
-spec start_link(tcp | tls | ws | wss, inet:port_number(), map()) -> gen_server:start_ret().
start_link(Kind, Port, Config) ->
    gen_server:start_link(?MODULE, {Kind, Port, Config}, [{hibernate_after, 15000}]).

-doc """
The local port the listener `Listener` is bound to, or `error` when it does
not answer within one second. Used by `ircdctl status`.
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
        %% measured median p50 41.98 ms without it and 0.85 ms with it
        %% (bench/results/2026-11-19-commands.md).
        {nodelay, true},
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
    case transport_accept(Kind, Listener) of
        {ok, Socket} ->
            handoff(Kind, Socket),
            accept(Kind, Listener);
        {error, Reason} ->
            logger:error(#{event => accept_failed, transport => Kind, reason => Reason}),
            exit({accept_failed, Reason})
    end.

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
                case ircd_wire:ip_text(Address) of
                    <<$:, _/binary>> = Text -> <<$0, Text/binary>>;
                    Text -> Text
                end;
            _ ->
                <<"unknown">>
        end,
    case ircd_sessions:start_child(Kind, Socket, Peer) of
        {ok, Pid} when is_pid(Pid) ->
            case Module:controlling_process(Socket, Pid) of
                ok ->
                    Pid ! activate;
                {error, Reason} ->
                    logger:warning(#{
                        event => session_handoff_failed, peer => Peer, reason => Reason
                    }),
                    exit(Pid, shutdown),
                    Module:close(Socket)
            end;
        {error, max_clients} ->
            logger:warning(#{event => session_rejected, peer => Peer, reason => max_clients}),
            Module:close(Socket);
        {error, Reason} ->
            logger:warning(#{event => session_rejected, peer => Peer, reason => Reason}),
            Module:close(Socket)
    end.
