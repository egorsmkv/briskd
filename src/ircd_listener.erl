-module(ircd_listener).
-behaviour(gen_server).
-export([start_link/3, init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% @doc Start a TCP, TLS, WebSocket (`ws`), or WebSocket-over-TLS (`wss`)
%% listener using the normalized server configuration.
-spec start_link(tcp | tls | ws | wss, inet:port_number(), map()) -> gen_server:start_ret().
start_link(Kind, Port, Config) -> gen_server:start_link(?MODULE, {Kind, Port, Config}, []).

%% @doc Open the listening socket and start accepting client connections.
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

handle_call(_, _, State) -> {reply, {error, unsupported}, State}.
handle_cast(_, State) -> {noreply, State}.
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
            {ok, {Address, _}} ->
                case inet:ntoa(Address) of
                    [$: | _] = Text -> list_to_binary([$0 | Text]);
                    Text -> list_to_binary(Text)
                end;
            _ ->
                <<"unknown">>
        end,
    case ircd_sessions:start_child(Kind, Socket, Peer) of
        {ok, Pid} ->
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
