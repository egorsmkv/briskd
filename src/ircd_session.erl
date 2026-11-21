-module(ircd_session).
-moduledoc """
One accepted connection: a client, or an inbound server link.

Each session is a `gen_server` started as a `temporary` child of
`m:ircd_sessions` by `m:ircd_listener`. It owns the socket (TCP, TLS,
WebSocket `ws`, or WebSocket over TLS `wss`), the read buffer, and its
timers. It frames input into IRC lines with `m:ircd_wire` and turns each line
into a call on `m:ircd_state`, which owns all nickname, channel, and peer
state. Lines for the client arrive as `{irc, Line}` messages and are written to
the socket in order.

Lifecycle and bounds:

- The listener transfers socket ownership and then sends `activate`. For TLS
  the handshake runs here, with a 5-second timeout. The socket is read with
  `{active, once}`, re-armed after each read has been processed.
- A connection that has not completed registration (RFC 2812 section 3.1)
  within 30 seconds is closed. The timeout is fixed server policy.
- Buffered input without a line end is capped by `ircd_wire:append_pending/2`
  and `ircd_wire:partial/1`. An over-long tagged client line gets numeric 417
  and the rest of it is discarded; other malformed input closes the
  connection.
- When more than `max_sendq` lines (configuration, default 10000) are queued
  for a slow reader, the session sends `ERROR :Closing Link` with
  `Max SendQ exceeded` and closes. An authenticated server link allows 50000,
  as `m:ircd_link` does for outbound links.
- `STARTTLS` (IRCv3 `tls`) sends the queued 670 reply in plaintext, then
  upgrades the same TCP socket with the listener's TLS options.
- WebSocket connections run the RFC 6455 upgrade with `m:ircd_websocket`
  first, then carry one IRC line per message; they are always clients.

A connection whose first line is an RFC 2813 `PASS` with a version becomes an
inbound server link once `SERVER` authenticates against `server_links`. It
then sends its own `PASS`/`SERVER` and the burst, forwards link commands to
`m:ircd_state`, and checks liveness with a `PING` 60 seconds after
authentication and after each answered `PING`, closing the link when no
matching `PONG` arrives within 30 seconds. With `multiclient`, a further connection for the same account can be
attached to the primary session: its commands run as that client, and it
receives a copy of every line the primary session receives.
""".
-behaviour(gen_server).
%% Most lines of an authenticated peer sent to ircd_state in one call.
-define(MAX_PEER_BATCH, 2000).
%% Driver read buffer once a connection authenticates as a server link,
%% bytes (the listener's is sized for clients): one read carries a whole
%% batch, which matters while ircd_state is slow to answer.
-define(PEER_BUFFER, 262144).
%% Lines queued for an authenticated server link before it is dropped, as
%% ircd_link's limit for outbound links.
-define(PEER_SENDQ, 50000).
-include("ircd_wire.hrl").
-export([
    start_link/3,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    format_status/1,
    terminate/2
]).

-doc """
Start the session process for one accepted socket.

`Kind` is the listener transport: `tcp`, `tls`, or the WebSocket transports
`ws` and `wss` (over TCP and TLS). `Socket` is the accepted socket and `Peer`
the client's address as text. The process does nothing until the caller has
made it the socket's controlling process and sent it `activate`. Called by
`ircd_sessions:start_child/3`, which enforces `max_clients`.
""".
-spec start_link(tcp | tls | ws | wss, port() | ssl:sslsocket(), binary()) ->
    gen_server:start_ret().
start_link(Kind, Socket, Peer) ->
    gen_server:start_link(?MODULE, {Kind, Socket, Peer}, [
        {hibernate_after, 15000},
        {spawn_opt, [{fullsweep_after, 20}]}
    ]).

-doc false.
init(State) -> {ok, State}.
-doc false.
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.
-doc false.
handle_cast(_, State) -> {noreply, State}.

-doc false.
%% Perform the TLS handshake if needed, register the client, then read IRC lines.
handle_info(activate, {Kind, Socket, Peer} = State) ->
    case handshake(Kind, Socket) of
        ok ->
            case ircd_dronebl:check_sync(Peer) of
                {banned, Reason} ->
                    logger:warning(#{event => dronebl_banned, peer => Peer, reason => Reason}),
                    send_ban_close(Kind, Socket, Reason),
                    {stop, normal, State};
                Check ->
                    case Check of
                        lookup -> ircd_dronebl:check_async(Peer, self());
                        clean -> ok
                    end,
                    erlang:send_after(30000, self(), registration_timeout),
                    case Kind of
                        ws -> put(ircd_ws, #{phase => handshake, buffer => <<>>});
                        wss -> put(ircd_ws, #{phase => handshake, buffer => <<>>});
                        _ -> ok
                    end,
                    active({Kind, Socket, Peer, <<>>, awaiting})
            end;
        {error, Reason} ->
            logger:warning(#{event => tls_handshake_failed, peer => Peer, reason => Reason}),
            {stop, normal, State}
    end;
handle_info({dronebl_banned, _Reason}, {_, _, _, _, {server, _}} = State) ->
    {noreply, State};
handle_info({dronebl_banned, Reason}, {Kind, Socket, Peer, _, _} = State) ->
    logger:warning(#{event => dronebl_banned, peer => Peer, reason => Reason}),
    send_ban_close(Kind, Socket, Reason),
    {stop, normal, State};
handle_info({irc, Line}, {Kind, Socket, _, _, _} = State) ->
    Module = transport(Kind),
    case sendq_exceeded(State) of
        {true, Queued} ->
            logger:warning(#{event => sendq_exceeded, peer => peer_of(State), queued => Queued}),
            _ = Module:send(Socket, closing_link(<<"Max SendQ exceeded">>)),
            {stop, normal, State};
        false ->
            deliver(Module, Socket, Line, State)
    end;
handle_info(registered, State) ->
    put(ircd_registered, true),
    {noreply, State};
handle_info({irc_safelist, Lines}, State) ->
    put(ircd_safelist, Lines),
    drain_safelist(State);
handle_info(safelist_step, State) ->
    drain_safelist(State);
handle_info({irc_close, Line}, {Kind, Socket, _, _, _} = State) ->
    Module = transport(Kind),
    _ = Module:send(Socket, outgoing(Line)),
    {stop, normal, State};
handle_info({Tag, Socket, Packet}, {Kind, Socket, Peer, _Buffer, _Role} = State) when
    (Tag =:= tcp orelse Tag =:= ssl), (Kind =:= ws orelse Kind =:= wss)
->
    websocket_data(Packet, State, Peer);
handle_info({Tag, Socket, Packet0}, {Kind, Socket, Peer, Buffer, Role} = State0) when
    Tag =:= tcp; Tag =:= ssl
->
    case discard(Packet0) of
        more -> active(State0);
        {ok, Packet} -> receive_data(Packet, Kind, Socket, Peer, Buffer, Role)
    end;
handle_info(registration_timeout, {_, _, _, _, Role} = State) ->
    case Role of
        {server, _} ->
            {noreply, State};
        {server_pass, _} ->
            {stop, normal, State};
        client ->
            %% The state process sends `registered` with the welcome, so a
            %% registered session does not ask: asking queued a call behind
            %% whatever the state process was busy with (a message burst),
            %% and its timeout crashed sessions registered long before.
            case get(ircd_registered) =:= true orelse ask_registered(State) of
                true ->
                    {noreply, State};
                overloaded ->
                    {Kind, Socket, _, _, _} = State,
                    _ = overloaded(Kind, Socket, State),
                    {stop, normal, State};
                false ->
                    logger:info(#{event => registration_timeout, peer => peer_of(State)}),
                    {stop, normal, State}
            end;
        awaiting ->
            logger:info(#{event => registration_timeout, peer => peer_of(State)}),
            {stop, normal, State};
        {attached, _} ->
            {noreply, State}
    end;
handle_info(liveness_ping, {Kind, Socket, _, _, {server, undefined}} = State) ->
    Config = ircd_config:current(),
    Token = make_ref(),
    Module = transport(Kind),
    Ping = raw_line(<<"PING">>, [maps:get(name, Config)], none),
    case Module:send(Socket, Ping) of
        ok ->
            erlang:send_after(30000, self(), {link_ping_timeout, Token}),
            {noreply, set_role(State, {server, Token})};
        {error, Reason} ->
            logger:warning(#{event => link_ping_failed, peer => peer_of(State), reason => Reason}),
            {stop, normal, State}
    end;
handle_info({link_ping_timeout, Token}, {_, _, _, _, {server, Token}} = State) ->
    logger:warning(#{event => link_ping_timeout, peer => peer_of(State)}),
    {stop, normal, State};
handle_info({link_ping_timeout, _}, State) ->
    {noreply, State};
handle_info({Tag, Socket}, {_, Socket, _, _, _} = State) when
    Tag =:= tcp_closed; Tag =:= ssl_closed
->
    logger:debug(#{event => socket_closed, peer => peer_of(State), reason => Tag}),
    {stop, normal, State};
handle_info({Tag, Socket, Reason}, {_, Socket, _, _, _} = State) when
    Tag =:= tcp_error; Tag =:= ssl_error
->
    logger:warning(#{event => socket_error, peer => peer_of(State), reason => Reason}),
    {stop, normal, State};
%% multiclient: this connection was attached to the session that holds the
%% same account's nickname. Its commands now run as that client and every
%% line the primary session receives is mirrored here.
handle_info({attach, Primary}, {Kind, Socket, Peer, Buffer, client}) ->
    %% ircd_state already sent {attached_session, self()} to Primary.
    monitor(process, Primary),
    {noreply, {Kind, Socket, Peer, Buffer, {attached, Primary}}};
handle_info({attached_session, Pid}, State) ->
    monitor(process, Pid),
    put(ircd_attached, [Pid | attached()]),
    {noreply, State};
handle_info({irc_mirror, Line}, {Kind, Socket, _, _, _} = State) ->
    Module = transport(Kind),
    case sendq_exceeded(State) of
        {true, Queued} ->
            logger:warning(#{
                event => sendq_exceeded, peer => peer_of(State), queued => Queued
            }),
            _ = Module:send(Socket, closing_link(<<"Max SendQ exceeded">>)),
            {stop, normal, State};
        false ->
            case Module:send(Socket, outgoing(Line)) of
                ok -> {noreply, State};
                {error, _} -> {stop, normal, State}
            end
    end;
handle_info({'DOWN', _, process, Primary, _}, {Kind, Socket, _, _, {attached, Primary}} = State) ->
    Module = transport(Kind),
    _ = Module:send(Socket, outgoing(<<"ERROR :Primary session closed\r\n">>)),
    {stop, normal, State};
handle_info({'DOWN', _, process, Pid, _}, State) ->
    put(ircd_attached, lists:delete(Pid, attached())),
    {noreply, State};
%% Ignore socket traffic and timers that belong to a previous connection state.
handle_info(_, State) ->
    {noreply, State}.

attached() ->
    case get(ircd_attached) of
        undefined -> [];
        List -> List
    end.

mirror(Line) ->
    lists:foreach(fun(Pid) -> Pid ! {irc_mirror, Line} end, attached()).

-doc """
Redact secrets from the state shown by `sys:get_status/1` and crash reports.

Between an inbound peer's `PASS` and `SERVER`, the state holds the link
password; it is replaced by `redacted`. The read buffer is cleared on every
connection state: it can hold a partial `PASS` line. Other shapes are
returned unchanged.
""".
-spec format_status(map()) -> map().
format_status(#{state := State} = Status) ->
    Status#{state := redact_state(State)};
format_status(Status) ->
    Status.

redact_state({Kind, Socket, Peer, _Buffer, {server_pass, _Password}}) ->
    {Kind, Socket, Peer, <<>>, {server_pass, redacted}};
redact_state({Kind, Socket, Peer, _Buffer, Role}) ->
    {Kind, Socket, Peer, <<>>, Role};
redact_state(State) ->
    State.

%% A client that reads slower than lines arrive builds up this mailbox; past
%% `max_sendq` queued lines it is disconnected, as IRC servers do for SendQ.
%% An authenticated server link carries the traffic of every user behind it
%% and gets ?PEER_SENDQ, the limit m:ircd_link applies to outbound links.
sendq_exceeded({_, _, _, _, {server, _}}) ->
    queued_over(?PEER_SENDQ);
sendq_exceeded(_State) ->
    queued_over(maps:get(max_sendq, ircd_config:current_or_empty(), 10000)).

queued_over(Limit) ->
    case process_info(self(), message_queue_len) of
        {message_queue_len, Queued} when Queued > Limit -> {true, Queued};
        _ -> false
    end.

deliver(Module, Socket, Line, State) ->
    mirror(Line),
    case Module:send(Socket, outgoing(Line)) of
        ok ->
            %% Counted here, by the session that writes the line, rather than
            %% by the state process once per recipient of every fan-out
            %% (STATS l; ircd_connection_stats has write_concurrency).
            ircd_state_client:update_connection_stats(
                self(), sent_messages, sent_bytes, iolist_size(Line)
            ),
            {noreply, State};
        {error, Reason} ->
            logger:debug(#{event => send_failed, peer => peer_of(State), reason => Reason}),
            {stop, normal, State}
    end.

%% Drain a SAFELIST response in bounded chunks so large LIST replies do not
%% overflow max_sendq or block interactive commands.
drain_safelist({Kind, Socket, _, _, _} = State) ->
    case get(ircd_safelist) of
        undefined ->
            {noreply, State};
        [] ->
            erase(ircd_safelist),
            {noreply, State};
        Lines ->
            {Chunk, Rest} = split_safelist(Lines, 32, []),
            Module = transport(Kind),
            case send_safelist_chunk(Module, Socket, Chunk) of
                ok ->
                    case Rest of
                        [] ->
                            erase(ircd_safelist),
                            {noreply, State};
                        _ ->
                            put(ircd_safelist, Rest),
                            self() ! safelist_step,
                            {noreply, State}
                    end;
                {error, Reason} ->
                    erase(ircd_safelist),
                    logger:debug(#{event => send_failed, peer => peer_of(State), reason => Reason}),
                    {stop, normal, State}
            end
    end.

split_safelist([], _N, Acc) ->
    {lists:reverse(Acc), []};
split_safelist(Rest, 0, Acc) ->
    {lists:reverse(Acc), Rest};
split_safelist([H | T], N, Acc) ->
    split_safelist(T, N - 1, [H | Acc]).

send_safelist_chunk(_Module, _Socket, []) ->
    ok;
send_safelist_chunk(Module, Socket, [Line | Rest]) ->
    mirror(Line),
    case Module:send(Socket, outgoing(Line)) of
        ok -> send_safelist_chunk(Module, Socket, Rest);
        {error, Reason} -> {error, Reason}
    end.

closing_link(Reason) ->
    Server = maps:get(name, ircd_config:current_or_empty(), <<"irc.local">>),
    outgoing(
        iolist_to_binary(
            ircd_wire:line(Server, <<"ERROR">>, [], [
                <<"Closing Link: ">>, Server, <<" (">>, Reason, <<")">>
            ])
        )
    ).

send_ban_close(Kind, Socket, Reason) ->
    Module = transport(Kind),
    case {Kind, get(ircd_ws)} of
        {K, #{phase := open}} when K =:= ws; K =:= wss ->
            _ = Module:send(Socket, closing_link(Reason)),
            ok;
        {K, _} when K =:= ws; K =:= wss ->
            _ = Module:send(Socket, <<"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n">>),
            ok;
        _ ->
            _ = Module:send(Socket, closing_link(Reason)),
            ok
    end.

-doc false.
terminate(_, {_, _, Peer, _, {server, _}}) ->
    ok = ircd_state:server_disconnect(Peer);
terminate(_, _) ->
    ok.

transport(Kind) ->
    case base(Kind) of
        tcp -> gen_tcp;
        tls -> ssl
    end.

base(tcp) -> tcp;
base(ws) -> tcp;
base(tls) -> tls;
base(wss) -> tls.

handshake(Kind, Socket) ->
    case base(Kind) of
        tcp ->
            ok;
        tls ->
            case ssl:handshake(Socket, 5000) of
                {ok, Socket} -> ok;
                Error -> Error
            end
    end.

%% IRC lines to a WebSocket client become one frame each, without CR LF.
%% A text-mode client only receives valid UTF-8.
outgoing(Line) ->
    case get(ircd_ws) of
        #{phase := open, mode := Mode} ->
            Body = strip_crlf(iolist_to_binary(Line)),
            case Mode of
                text -> ircd_websocket:encode(text, ircd_websocket:utf8_safe(Body));
                binary -> ircd_websocket:encode(binary, Body)
            end;
        _ ->
            Line
    end.

%% Handle bytes from a WebSocket connection: the HTTP upgrade, then frames.
websocket_data(Packet, {Kind, Socket, _, _, _} = State, Peer) ->
    Module = transport(Kind),
    case get(ircd_ws) of
        #{phase := handshake, buffer := Pending} ->
            Config = ircd_config:current(),
            case
                ircd_websocket:handshake(
                    <<Pending/binary, Packet/binary>>, maps:get(ws_origins, Config, null)
                )
            of
                more ->
                    put(ircd_ws, #{phase => handshake, buffer => <<Pending/binary, Packet/binary>>}),
                    active(State);
                {error, Response} ->
                    _ = Module:send(Socket, Response),
                    logger:info(#{event => websocket_rejected, peer => Peer}),
                    {stop, normal, State};
                {ok, Response, Mode, Rest} ->
                    case Module:send(Socket, Response) of
                        ok ->
                            put(ircd_ws, #{phase => open, mode => Mode, buffer => <<>>}),
                            websocket_frames(Rest, State);
                        {error, _} ->
                            {stop, normal, State}
                    end
            end;
        #{phase := open, buffer := Pending} ->
            websocket_frames(<<Pending/binary, Packet/binary>>, State)
    end.

websocket_frames(Data, {Kind, Socket, Peer, _, Role} = State) ->
    Module = transport(Kind),
    case byte_size(Data) > ?MAX_PENDING_BYTES of
        true ->
            {stop, normal, State};
        false ->
            case ircd_websocket:decode(Data, ?MAX_WIRE_LINE) of
                {error, Reason} ->
                    logger:debug(#{event => websocket_error, peer => Peer, reason => Reason}),
                    _ = Module:send(Socket, ircd_websocket:encode(close, <<1002:16>>)),
                    {stop, normal, State};
                {ok, [], Rest} ->
                    Ws = get(ircd_ws),
                    put(ircd_ws, Ws#{buffer => Rest}),
                    active(State);
                {ok, Frames, Rest} ->
                    Ws = get(ircd_ws),
                    put(ircd_ws, Ws#{buffer => Rest}),
                    %% WebSocket connections are always clients, never server links.
                    case Role of
                        awaiting ->
                            Client = promote_client({Kind, Socket, Peer, <<>>, awaiting}),
                            websocket_messages(Frames, Client);
                        _ ->
                            websocket_messages(Frames, {Kind, Socket, Peer, <<>>, Role})
                    end
            end
    end.

websocket_messages([], State) ->
    active(State);
websocket_messages([{ping, Payload} | Rest], {Kind, Socket, _, _, _} = State) ->
    Module = transport(Kind),
    _ = Module:send(Socket, ircd_websocket:encode(pong, Payload)),
    websocket_messages(Rest, State);
websocket_messages([{pong, _} | Rest], State) ->
    websocket_messages(Rest, State);
websocket_messages([{close, _} | _], {Kind, Socket, _, _, _} = State) ->
    Module = transport(Kind),
    _ = Module:send(Socket, ircd_websocket:encode(close, <<1000:16>>)),
    {stop, normal, State};
websocket_messages([{Type, Payload} | Rest], {Kind, Socket, Peer, _, Role} = State) ->
    Valid = Type =:= binary orelse ircd_websocket:utf8_safe(Payload) =:= Payload,
    Line = strip_crlf(Payload),
    case Valid of
        false ->
            {stop, normal, State};
        true ->
            case consume(<<Line/binary, "\r\n">>, {Kind, Socket, Peer, <<>>, Role}) of
                {ok, Updated} -> websocket_messages(Rest, Updated);
                {starttls, _} -> {stop, normal, State};
                quit -> {stop, normal, State};
                error -> {stop, normal, State}
            end
    end.

strip_crlf(Payload) ->
    case binary:longest_common_suffix([Payload, <<"\r\n">>]) of
        2 -> binary:part(Payload, 0, byte_size(Payload) - 2);
        _ -> Payload
    end.

%% STARTTLS (IRCv3 `tls`, deprecated in favor of implicit TLS): send the
%% queued 670 reply in plaintext, then run the server-side TLS handshake on the
%% same TCP socket with the listener's TLS options.
starttls({tcp, Socket, Peer, _, Role} = State) ->
    ok = flush_plain(Socket),
    Options = maps:get(tls_options, ircd_config:current()),
    case inet:setopts(Socket, [{active, false}]) of
        ok ->
            %% ssl does not export the narrower option types its handshake/3
            %% spec names; the configured list holds TLS options only.
            % elp:ignore W0074 (ssl:handshake/3 option types are not exported)
            % eqwalizer:ignore incompatible_types
            case ssl:handshake(Socket, Options, 5000) of
                {ok, Tls} ->
                    ok = ircd_state:tls_upgraded(connection_info(tls, Tls)),
                    logger:info(#{event => starttls_completed, peer => Peer}),
                    active({tls, Tls, Peer, <<>>, Role});
                {error, Reason} ->
                    logger:warning(#{event => starttls_failed, peer => Peer, reason => Reason}),
                    {stop, normal, State}
            end;
        {error, _} ->
            {stop, normal, State}
    end;
starttls(State) ->
    {stop, normal, State}.

%% Lines the state process queued before the upgrade go out unencrypted.
flush_plain(Socket) ->
    receive
        {irc, Line} ->
            _ = gen_tcp:send(Socket, Line),
            flush_plain(Socket)
    after 0 ->
        ok
    end.

%% Connection facts for capability values and SASL EXTERNAL: whether the
%% transport is TLS and the SHA-256 fingerprint of a client certificate.
connection_info(Kind, Socket) ->
    case base(Kind) of
        tcp ->
            #{secure => false, transport => Kind};
        tls ->
            Fingerprint =
                case ssl:peercert(Socket) of
                    {ok, Der} -> binary:encode_hex(crypto:hash(sha256, Der), lowercase);
                    _ -> undefined
                end,
            #{secure => true, certfp => Fingerprint, transport => Kind}
    end.

consume(Data, State) ->
    consume(Data, [], 0, State).

%% On an authenticated server link, Pending holds the state-bound lines of
%% this read, newest first, applied as one ircd_state:server_commands/2
%% batch before any other line, when the read has no more complete lines, or
%% at ?MAX_PEER_BATCH lines. It stays empty for clients.
consume(Data, Pending, Count, State) ->
    case binary:match(Data, <<"\r\n">>) of
        {Offset, 2} ->
            Line = binary:part(Data, 0, Offset + 2),
            Rest = binary:part(Data, Offset + 2, byte_size(Data) - Offset - 2),
            case parse_line(Line, State) of
                {ok, Tags, Prefix, Command, Params} ->
                    Batched =
                        case element(5, State) of
                            {server, _} -> ircd_state:peer_command(Command);
                            _ -> false
                        end,
                    Result =
                        case Batched of
                            true when Count + 1 < ?MAX_PEER_BATCH ->
                                {batched, [{Prefix, Command, Params, Tags} | Pending]};
                            true ->
                                flush_peer([{Prefix, Command, Params, Tags} | Pending], State);
                            false ->
                                case flush_peer(Pending, State) of
                                    {ok, Flushed} ->
                                        line_result(
                                            Tags, Prefix, Command, Params, byte_size(Line), Flushed
                                        );
                                    error ->
                                        error
                                end
                        end,
                    case Result of
                        {batched, More} -> consume(Rest, More, Count + 1, State);
                        {ok, Updated} -> consume(Rest, [], 0, Updated);
                        %% The client must wait for 670 before the handshake,
                        %% so nothing may follow STARTTLS in the same read.
                        {starttls, Updated} when Rest =:= <<>> -> {starttls, Updated};
                        {starttls, _} -> error;
                        quit -> quit;
                        error -> error
                    end;
                {error, input_too_long, Tags} ->
                    case reject_long_line(Tags, State) of
                        {ok, Updated} -> consume(Rest, Pending, Count, Updated);
                        quit -> quit;
                        error -> error
                    end;
                empty ->
                    consume(Rest, Pending, Count, State);
                error ->
                    error
            end;
        nomatch ->
            case flush_peer(Pending, State) of
                {ok, Flushed} ->
                    case ircd_wire:partial(Data) of
                        ok -> {ok, set_buffer(Flushed, Data)};
                        error -> overlong(Data, Flushed)
                    end;
                error ->
                    error
            end
    end.

line_result(Tags, Prefix, Command, Params, Bytes, State) ->
    case element(5, State) of
        {server, _} -> process_server_line(Tags, Prefix, Command, Params, Bytes, State);
        _ -> process_line(Tags, Command, Params, Bytes, State)
    end.

peer_buffer(Module, Socket, Name) ->
    Set =
        case Module of
            gen_tcp -> inet:setopts(Socket, [{buffer, ?PEER_BUFFER}]);
            ssl -> ssl:setopts(Socket, [{buffer, ?PEER_BUFFER}])
        end,
    case Set of
        ok ->
            ok;
        {error, Reason} ->
            logger:warning(#{event => peer_buffer_failed, peer => Name, reason => Reason})
    end.

flush_peer([], State) ->
    {ok, State};
flush_peer(Pending, {_, _, Peer, _, _} = State) ->
    case ircd_state:server_commands(Peer, lists:reverse(Pending)) of
        ok ->
            {ok, State};
        {error, Reason} ->
            logger:warning(#{event => invalid_remote_state, peer => Peer, reason => Reason}),
            error
    end.

parse_line(Line, {_, _, _, _, {server, _}}) ->
    ircd_wire:parse_server(Line);
parse_line(Line, _) ->
    case ircd_wire:parse_client(Line) of
        {ok, Tags, Command, Params} -> {ok, Tags, undefined, Command, Params};
        Other -> Other
    end.

%% A client's tagged line that outgrows the wire cap before its CR LF gets
%% numeric 417 (IRCv3 message-tags); the rest of that line is discarded.
%% Other malformed input still closes the connection.
overlong(<<"@", _/binary>> = Data, {_, _, _, _, Role} = State) when
    Role =:= client; Role =:= awaiting
->
    case binary:match(Data, [<<"\r">>, <<"\n">>]) of
        nomatch ->
            case reject_long_line([], State) of
                {ok, Updated} ->
                    put(ircd_discard, true),
                    {ok, set_buffer(Updated, <<>>)};
                quit ->
                    quit;
                error ->
                    error
            end;
        _ ->
            error
    end;
overlong(_Data, _State) ->
    error.

reject_long_line(_Tags, {_, _, _, _, {server, _}}) ->
    error;
reject_long_line(_Tags, {_, _, _, _, {server_pass, _}}) ->
    error;
reject_long_line(Tags, {_, _, _, _, awaiting} = State) ->
    ClientState = promote_client(State),
    case ircd_state:input_too_long(Tags) of
        ok -> {ok, ClientState};
        quit -> quit
    end;
reject_long_line(Tags, {_, _, _, _, client} = State) ->
    case ircd_state:input_too_long(Tags) of
        ok -> {ok, State};
        quit -> quit
    end.

set_buffer({Kind, Socket, Peer, _, Role}, Buffer) ->
    {Kind, Socket, Peer, Buffer, Role}.

active({Kind, Socket, _, _, _} = State) ->
    Result =
        case base(Kind) of
            tcp -> inet:setopts(Socket, [{active, once}]);
            tls -> ssl:setopts(Socket, [{active, once}])
        end,
    case Result of
        ok -> {noreply, State};
        {error, _} -> {stop, normal, State}
    end.

process_line(
    Tags, <<"PASS">>, [Password, Version, _Flags | _], _Bytes, {_, _, _, _, awaiting} = State
) ->
    case Tags of
        [] -> process_server_pass(Password, Version, State);
        _ -> error
    end;
process_line(Tags, <<"SERVER">>, [Name, Hop, Token, _Info], _Bytes, State) ->
    case Tags of
        [] -> process_server_intro(Name, Hop, Token, State);
        _ -> error
    end;
process_line(Tags, Command, Params, Bytes, {Kind, Socket, _, _, awaiting} = State) ->
    try promote_client(State) of
        Client -> process_client_line(Tags, Command, Params, Bytes, Client)
    catch
        exit:{timeout, _} -> overloaded(Kind, Socket, State)
    end;
process_line(_Tags, _Command, _Params, _Bytes, {_, _, _, _, {server_pass, _}}) ->
    error;
process_line(_Tags, <<"QUIT">>, _Params, _Bytes, {_, _, _, _, {attached, _}}) ->
    %% QUIT on an attached connection closes only that connection.
    quit;
process_line(Tags, Command, Params, Bytes, {Kind, Socket, _, _, {attached, Primary}} = State) ->
    try ircd_state:command_as(Primary, Command, Params, Bytes, Tags) of
        quit -> quit;
        _ -> {ok, State}
    catch
        exit:{timeout, _} -> overloaded(Kind, Socket, State)
    end;
process_line(Tags, Command, Params, Bytes, {_, _, _, _, client} = State) ->
    process_client_line(Tags, Command, Params, Bytes, State).

process_server_pass(Password, Version, State) ->
    case valid_server_version(Version) of
        true -> {ok, set_link_password(State, Password)};
        false -> error
    end.

process_server_intro(Name, Hop, Token, State) ->
    case State of
        {Kind, Socket, _Peer, _Buffer, {server_pass, Password}} ->
            case
                ircd_state:authenticate_server_link(Name, Password) andalso
                    ircd_route:valid_decimal(Hop) andalso ircd_route:valid_decimal(Token)
            of
                true ->
                    Config = ircd_config:current(),
                    LocalName = maps:get(name, Config),
                    Info = maps:get(server_info, Config, <<"Erlang/OTP IRC server">>),
                    Reply = [
                        raw_line(<<"PASS">>, [Password, <<"0210">>, <<"|">>], none),
                        raw_line(
                            <<"SERVER">>,
                            [LocalName, <<"1">>, <<"1">>],
                            Info
                        )
                    ],
                    Burst = [iolist_to_binary(Line) || Line <- ircd_state:server_burst()],
                    %% Register before the burst so a second session for the
                    %% same peer is refused without receiving it. The role is
                    %% still `server_pass` until the send succeeds, and
                    %% terminate/2 only splits a `{server, _}` role, so a
                    %% refusal must not call server_disconnect.
                    case ircd_state:register_adjacent(Name, Token, inbound) of
                        {error, duplicate_peer} ->
                            error;
                        ok ->
                            Module = transport(Kind),
                            case Module:send(Socket, [Reply, Burst]) of
                                ok ->
                                    logger:notice(#{
                                        event => inbound_server_link_authenticated, peer => Name
                                    }),
                                    erlang:send_after(60000, self(), liveness_ping),
                                    peer_buffer(Module, Socket, Name),
                                    {ok, set_peer_and_role(State, Name, {server, undefined})};
                                {error, _} ->
                                    ok = ircd_state:server_disconnect(Name),
                                    error
                            end
                    end;
                false ->
                    error
            end;
        _ ->
            error
    end.

process_server_line(
    _Tags, _Prefix, <<"PING">>, [Origin | _], _Bytes, {Kind, Socket, _, _, _} = State
) ->
    Config = ircd_config:current(),
    Reply = raw_line(<<"PONG">>, [maps:get(name, Config), Origin], none),
    Module = transport(Kind),
    case Module:send(Socket, Reply) of
        ok -> {ok, State};
        {error, _} -> error
    end;
process_server_line(
    _Tags,
    _Prefix,
    <<"PONG">>,
    [Responder, Origin | _],
    _Bytes,
    {_, _, PeerName, _, {server, Token}} = State
) when Token =/= undefined ->
    Config = ircd_config:current(),
    case Responder =:= PeerName andalso Origin =:= maps:get(name, Config) of
        true ->
            erlang:send_after(60000, self(), liveness_ping),
            {ok, set_role(State, {server, undefined})};
        false ->
            {ok, State}
    end;
process_server_line(_Tags, _Prefix, <<"ERROR">>, [Reason | _], _Bytes, _State) ->
    logger:warning(#{event => inbound_server_link_error, reason => Reason}),
    quit;
process_server_line(_Tags, _Prefix, _Command, _Params, _Bytes, State) ->
    {ok, State}.

process_client_line(Tags, Command, Params, Bytes, {Kind, Socket, _, _, client} = State) ->
    try ircd_state:command(Command, Params, Bytes, Tags) of
        quit -> quit;
        starttls -> {starttls, State};
        ok -> {ok, State}
    catch
        exit:{timeout, _} -> overloaded(Kind, Socket, State)
    end.

%% Whether the state process has registered this session (only asked when
%% its `registered` message has not arrived), or `overloaded` past the
%% command deadline.
ask_registered(_State) ->
    try ircd_state:registered() of
        Registered -> Registered
    catch
        exit:{timeout, _} -> overloaded
    end.

%% The state process did not apply this client's command within its deadline
%% (ircd_state's COMMAND_TIMEOUT): the server is overloaded. The client is
%% told and the session ends normally, rather than crashing; the command may
%% still be applied later, and its late reply is discarded.
overloaded(Kind, Socket, State) ->
    logger:warning(#{event => command_timeout, peer => peer_of(State)}),
    _ = (transport(Kind)):send(Socket, closing_link(<<"Server overloaded">>)),
    quit.

%% The first client command turns an awaiting connection into a client.
promote_client({Kind, Socket, Peer, Buffer, awaiting}) ->
    ok = ircd_state:connect(Peer, connection_info(Kind, Socket)),
    {Kind, Socket, Peer, Buffer, client}.

set_link_password({Kind, Socket, Peer, Buffer, awaiting}, Password) ->
    {Kind, Socket, Peer, Buffer, {server_pass, Password}}.

set_role({Kind, Socket, Peer, Buffer, _}, Role) ->
    {Kind, Socket, Peer, Buffer, Role}.

set_peer_and_role({Kind, Socket, _Peer, Buffer, _}, Peer, Role) ->
    {Kind, Socket, Peer, Buffer, Role}.

peer_of({_, _, Peer, _, _}) -> Peer.

valid_server_version(<<A, B, C, D, _/binary>> = Version) ->
    byte_size(Version) =< 14 andalso A >= $0 andalso A =< $9 andalso B >= $0 andalso B =< $9 andalso
        C >= $0 andalso C =< $9 andalso D >= $0 andalso D =< $9;
valid_server_version(_) ->
    false.

raw_line(Command, Params, none) ->
    iolist_to_binary([Command, [[<<" ">>, Param] || Param <- Params], <<"\r\n">>]);
raw_line(Command, Params, Trailing) ->
    iolist_to_binary([
        Command,
        [[<<" ">>, Param] || Param <- Params],
        <<" :">>,
        Trailing,
        <<"\r\n">>
    ]).

receive_data(Packet, Kind, Socket, Peer, Buffer, Role) ->
    case ircd_wire:append_pending(Buffer, Packet) of
        {ok, Data} ->
            case consume(Data, {Kind, Socket, Peer, <<>>, Role}) of
                {ok, State} -> active(State);
                {starttls, State} -> starttls(State);
                quit -> flush_and_stop({Kind, Socket, Peer, <<>>, Role});
                error -> {stop, normal, {Kind, Socket, Peer, <<>>, Role}}
            end;
        error ->
            {stop, normal, {Kind, Socket, Peer, <<>>, Role}}
    end.

%% While skipping the rest of an over-long tagged line, drop bytes up to and
%% including the next LF.
discard(Packet) ->
    case get(ircd_discard) of
        true ->
            case binary:split(Packet, <<"\n">>) of
                [_] ->
                    more;
                [_, Rest] ->
                    erase(ircd_discard),
                    {ok, Rest}
            end;
        _ ->
            {ok, Packet}
    end.

%% Replies the state process queued before a QUIT (including ERROR) reach the
%% socket before it closes, so a client that pipelines commands with QUIT
%% still gets every answer.
flush_and_stop({Kind, Socket, Peer, _, Role}) ->
    Module = transport(Kind),
    flush_outgoing(Module, Socket),
    {stop, normal, {Kind, Socket, Peer, <<>>, Role}}.

flush_outgoing(Module, Socket) ->
    receive
        {irc, Line} ->
            _ = Module:send(Socket, outgoing(Line)),
            flush_outgoing(Module, Socket);
        {irc_close, Line} ->
            _ = Module:send(Socket, outgoing(Line)),
            ok
    after 0 ->
        ok
    end.
