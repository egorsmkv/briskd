-module(ircd_listener).
-behaviour(gen_server).
-export([start_link/3, init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% @doc Start a TCP or TLS listener using the normalized server configuration.
-spec start_link(tcp | tls, inet:port_number(), map()) -> gen_server:start_ret().
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

listen(tcp, Port, Options, _) -> gen_tcp:listen(Port, Options);
listen(tls, Port, Options, TLS) -> ssl:listen(Port, Options ++ TLS).
sockname(tcp, Socket) -> inet:sockname(Socket);
sockname(tls, Socket) -> ssl:sockname(Socket).

accept(Kind, Listener) ->
    case transport_accept(Kind, Listener) of
        {ok, Socket} ->
            handoff(Kind, Socket),
            accept(Kind, Listener);
        {error, Reason} ->
            exit({accept_failed, Reason})
    end.

transport_accept(tcp, Listener) -> gen_tcp:accept(Listener);
transport_accept(tls, Listener) -> ssl:transport_accept(Listener).

handoff(Kind, Socket) ->
    {Module, PeerResult} =
        case Kind of
            tcp -> {gen_tcp, inet:peername(Socket)};
            tls -> {ssl, ssl:peername(Socket)}
        end,
    Peer =
        case PeerResult of
            {ok, {Address, _}} -> list_to_binary(inet:ntoa(Address));
            _ -> <<"unknown">>
        end,
    case ircd_sessions:start_child(Kind, Socket, Peer) of
        {ok, Pid} ->
            case Module:controlling_process(Socket, Pid) of
                ok ->
                    Pid ! activate;
                {error, _} ->
                    exit(Pid, shutdown),
                    Module:close(Socket)
            end;
        {error, _} ->
            Module:close(Socket)
    end.
