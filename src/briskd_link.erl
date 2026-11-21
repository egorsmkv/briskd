-module(briskd_link).
-moduledoc """
Outbound connection worker for one configured RFC 2813 server peer.

A `gen_server` started by `m:briskd_links`, one per `server_links` entry. It owns
the TCP or TLS socket, the read buffer, and the link timers. With the entry's
`tls` flag it connects over TLS with peer verification against the OS CA
store, SNI, and a host name check. It sends `PASS <password> 0210 |` and
`SERVER <name> 1 1`, then requires the peer's `PASS` (password compared with
`briskd_config:secret_match/2`, version starting with four digits) and a
`SERVER` line naming the configured peer (RFC 2813 sections 4.1.1 and 4.1.2).
Only then does it send the local burst from `briskd_state:server_burst/0` and
register the link with `briskd_state:register_adjacent/3`. A failed handshake
imports nothing. Inbound links from peers are handled by `m:briskd_session`, not
by this module.

After authentication, input is framed on CRLF with `{active, once}` and parsed
by `briskd_wire:parse_server/1`. Nick, channel, message, server, and IRCv3
synchronisation commands go to `briskd_state:server_commands/2`, every complete
line of a read in one call (at most 2000, with a 256 KiB read buffer), so a busy state process drains a
link as fast as it carries traffic; an error reply drops the link. `PING` is answered with `PONG`, and other commands are
ignored. Liveness follows RFC 2813 section 5.1: 60 seconds after
authentication or after the last matching `PONG` the worker sends `PING`, and
it drops the link if no `PONG` arrives within 30 seconds.

Any socket error or close, malformed or oversized input, peer `ERROR`, failed
send (30-second send timeout), missed `PONG`, or a backlog of more than 50000
queued messages closes the socket. If the link had authenticated,
`briskd_state:server_disconnect/1` then removes everything behind it.

The worker then reconnects with a bounded exponential backoff: the base
delay starts at 5 seconds and doubles after each failed attempt up to 300
seconds, and each wait is the base delay less up to
10% of random jitter so peers do not reconnect in lockstep. A link that
authenticates resets the backoff. A retry is logged at `warning` on the first
failure, whenever the base delay changes, and on every 10th attempt; other
retries are logged at `debug`. Timer messages carry a connection generation,
so a timer from an earlier connection is ignored.
""".
-behaviour(gen_server).
-include("briskd_link.hrl").
-export([
    start_link/2,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_continue/2,
    handle_info/2,
    format_status/1
]).

%% A blocked send to the peer fails after this many milliseconds and closes
%% the socket; the worker then reconnects with its backoff.
-define(SEND_TIMEOUT_MS, 30000).
%% Reconnect backoff in milliseconds: first delay and cap. The delay doubles
%% after each failed attempt.
-define(BACKOFF_MIN_MS, 5000).
-define(BACKOFF_MAX_MS, 300000).
%% With an unchanged delay, a retry is logged at warning every this many attempts.
-define(RETRY_LOG_EVERY, 10).

-doc """
Start the worker for one configured peer, linked to the caller.

`Config` is the server configuration and `Peer` one `server_links` entry
(`name`, `host`, `port`, `password`, `tls`). The connection is made after
start-up, so this returns before the peer is reached; a failed
connection is retried rather than failing the start.
""".
-spec start_link(map(), map()) -> gen_server:start_ret().
start_link(Config, Peer) ->
    gen_server:start_link(?MODULE, {Config, Peer}, [
        {hibernate_after, 30000},
        {spawn_opt, [{fullsweep_after, 20}]}
    ]).

-doc false.
init({Config, Peer}) ->
    {ok,
        #{
            config => Config,
            peer => Peer,
            socket => undefined,
            buffer => <<>>,
            timer_gen => 0,
            attempts => 0,
            backoff => undefined,
            liveness_timer => undefined,
            ping_timer => undefined
        },
        {continue, connect}}.

-doc false.
handle_continue(connect, State) ->
    case connect(State) of
        {ok, Connected} ->
            case send_handshake(Connected) of
                ok ->
                    case active_once(Connected) of
                        ok ->
                            {noreply, Connected#{phase => await_pass, peer_password => undefined}};
                        {error, Reason} ->
                            retry(Connected, {active_once, Reason})
                    end;
                {error, Reason} ->
                    retry(Connected, {send_handshake, Reason})
            end;
        {error, Reason} ->
            retry(State, {connect, Reason})
    end.

-doc false.
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.
-doc false.
handle_cast({send, Line}, #{phase := authenticated, kind := Kind, socket := Socket} = State) ->
    %% A peer that stops reading must not let relayed lines pile up here.
    case process_info(self(), message_queue_len) of
        {message_queue_len, Queued} when Queued > ?LINK_MAX_SENDQ ->
            retry(State, {sendq_exceeded, Queued});
        _ ->
            case send(Kind, Socket, Line) of
                ok -> {noreply, State};
                {error, Reason} -> retry(State, {send_failed, Reason})
            end
    end;
handle_cast(connect_now, #{phase := disconnected, timer_gen := Gen} = State) ->
    cancel_timer(maps:get(reconnect_timer, State, undefined)),
    self() ! {reconnect, Gen},
    {noreply, State#{reconnect_timer => undefined}};
handle_cast(_, State) ->
    {noreply, State}.

-doc false.
handle_info({reconnect, Gen}, #{timer_gen := Gen} = State) ->
    {noreply, State, {continue, connect}};
handle_info({reconnect, _Gen}, State) ->
    {noreply, State};
handle_info(
    {liveness_ping, Gen},
    #{phase := authenticated, ping_pending := undefined, timer_gen := Gen} = State
) ->
    Config = maps:get(config, State),
    Token = make_ref(),
    Ping = raw_line(<<"PING">>, [maps:get(name, Config)], none),
    case send(maps:get(kind, State), maps:get(socket, State), Ping) of
        ok ->
            cancel_timer(maps:get(ping_timer, State)),
            Ref = erlang:send_after(?LINK_PONG_TIMEOUT_MS, self(), {ping_timeout, Gen, Token}),
            {noreply, State#{ping_pending := Token, ping_timer => Ref}};
        {error, Reason} ->
            retry(State, {ping_send_failed, Reason})
    end;
handle_info({liveness_ping, _Gen}, State) ->
    {noreply, State};
handle_info(
    {ping_timeout, Gen, Token},
    #{phase := authenticated, ping_pending := Token, timer_gen := Gen} = State
) ->
    retry(State, ping_timeout);
handle_info({ping_timeout, _Gen, _Token}, State) ->
    {noreply, State};
handle_info({Tag, Socket, Packet}, #{socket := Socket} = State) when
    Tag =:= tcp; Tag =:= ssl
->
    case briskd_wire:append_pending(maps:get(buffer, State), Packet) of
        {ok, Data} ->
            case consume(Data, State#{buffer := <<>>}) of
                {ok, Updated} ->
                    case active_once(Updated) of
                        ok -> {noreply, Updated};
                        {error, Reason} -> retry(Updated, {active_once, Reason})
                    end;
                {error, Reason, Updated} ->
                    retry(Updated, Reason)
            end;
        error ->
            retry(State, oversized_input)
    end;
handle_info({Tag, Socket}, #{socket := Socket} = State) when
    Tag =:= tcp_closed; Tag =:= ssl_closed
->
    retry(State, peer_closed);
handle_info({Tag, Socket, Reason}, #{socket := Socket} = State) when
    Tag =:= tcp_error; Tag =:= ssl_error
->
    retry(State, {peer_error, Reason});
%% Ignore stale timers and socket events from a previous connection generation.
handle_info(_, State) ->
    {noreply, State}.

-doc """
Redact secrets from the worker state shown by `sys:get_status/1` and crash
reports.

Removes the configured link password, any password received during the
handshake, and the server configuration (which holds every link and operator
password); only the local server name is kept from it.
""".
-spec format_status(map()) -> map().
format_status(#{state := State} = Status) ->
    Status#{state := redact_state(State)};
format_status(Status) ->
    Status.

redact_state(#{peer := Peer} = State) ->
    %% The read buffer can hold a partial PASS line.
    Cleared = State#{buffer => <<>>},
    redact_config(Cleared#{peer := maps:remove(password, Peer), peer_password => redacted});
redact_state(State) when is_map(State) ->
    State#{buffer => <<>>};
redact_state(State) ->
    State.

redact_config(#{config := Config} = State) when is_map(Config) ->
    State#{config := maps:with([name], Config)};
redact_config(State) ->
    State.

connect(#{peer := #{host := Host, port := Port, tls := true}} = State) ->
    logger:debug(#{
        event => server_link_connecting,
        peer => peer_name(State),
        host => Host,
        port => Port,
        tls => true
    }),
    HostName = binary_to_list(Host),
    Options = [
        binary,
        {packet, raw},
        {active, false},
        {send_timeout, ?SEND_TIMEOUT_MS},
        {send_timeout_close, true},
        {buffer, ?LINK_READ_BUFFER},
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, HostName},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ],
    case ssl:connect(HostName, Port, Options, 10000) of
        {ok, Socket} -> {ok, State#{kind => tls, socket => Socket}};
        {error, Reason} -> {error, Reason}
    end;
connect(#{peer := #{host := Host, port := Port}} = State) ->
    logger:debug(#{
        event => server_link_connecting,
        peer => peer_name(State),
        host => Host,
        port => Port,
        tls => false
    }),
    Options = [
        binary,
        {packet, raw},
        {active, false},
        {nodelay, true},
        {buffer, ?LINK_READ_BUFFER},
        {keepalive, true},
        {send_timeout, ?SEND_TIMEOUT_MS},
        {send_timeout_close, true}
    ],
    case gen_tcp:connect(binary_to_list(Host), Port, Options, 10000) of
        {ok, Socket} -> {ok, State#{kind => tcp, socket => Socket}};
        {error, Reason} -> {error, Reason}
    end.

send_handshake(#{kind := Kind, socket := Socket, peer := #{password := Password}, config := Config}) ->
    Server = maps:get(name, Config),
    Info = maps:get(server_info, Config, <<"Erlang/OTP IRC server">>),
    PassLine = raw_line(<<"PASS">>, [Password, <<"0210">>, <<"|">>], none),
    ServerLine = raw_line(<<"SERVER">>, [Server, <<"1">>, <<"1">>], Info),
    send(Kind, Socket, <<PassLine/binary, ServerLine/binary>>).

consume(Data, State) ->
    consume(Data, [], 0, State).

%% Pending holds the state-bound lines of this read, newest first, sent to
%% briskd_state as one batch (briskd_state:server_commands/2) when a line the
%% worker handles itself arrives, when the read has no more complete lines,
%% or at ?LINK_MAX_BATCH lines.
consume(Data, Pending, Count, State) ->
    case binary:match(Data, <<"\r\n">>) of
        {Offset, 2} ->
            Line = binary:part(Data, 0, Offset + 2),
            Rest = binary:part(Data, Offset + 2, byte_size(Data) - Offset - 2),
            case briskd_wire:parse_server(Line) of
                {ok, Tags, Prefix, Command, Params} ->
                    case batched(Command, State) of
                        true when Count + 1 < ?LINK_MAX_BATCH ->
                            consume(
                                Rest, [{Prefix, Command, Params, Tags} | Pending], Count + 1, State
                            );
                        true ->
                            case flush([{Prefix, Command, Params, Tags} | Pending], State) of
                                {ok, Updated} -> consume(Rest, [], 0, Updated);
                                {error, Reason, Updated} -> {error, Reason, Updated}
                            end;
                        false ->
                            case flush(Pending, State) of
                                {ok, Flushed} ->
                                    case
                                        handle_server_line(Tags, Prefix, Command, Params, Flushed)
                                    of
                                        {ok, Updated} -> consume(Rest, [], 0, Updated);
                                        {error, Reason, Updated} -> {error, Reason, Updated}
                                    end;
                                {error, Reason, Updated} ->
                                    {error, Reason, Updated}
                            end
                    end;
                empty ->
                    consume(Rest, Pending, Count, State);
                error ->
                    {error, malformed_server_message, State}
            end;
        nomatch ->
            case briskd_wire:partial(Data) of
                ok ->
                    case flush(Pending, State) of
                        {ok, Updated} -> {ok, Updated#{buffer := Data}};
                        {error, Reason, Updated} -> {error, Reason, Updated}
                    end;
                error ->
                    {error, malformed_server_frame, State}
            end
    end.

batched(Command, #{phase := authenticated}) -> briskd_state:peer_command(Command);
batched(_Command, _State) -> false.

flush([], State) ->
    {ok, State};
flush(Pending, #{peer := #{name := PeerName}} = State) ->
    case briskd_state:server_commands(PeerName, lists:reverse(Pending)) of
        ok -> {ok, State};
        {error, Reason} -> {error, {invalid_remote_state, Reason}, State}
    end.

handle_server_line(
    _Tags,
    undefined,
    <<"PASS">>,
    [Password, Version, _Flags | _],
    #{phase := await_pass, peer := #{password := Expected}} = State
) ->
    case valid_version(Version) andalso briskd_config:secret_match(Password, Expected) of
        true -> {ok, State#{peer_password := Password, phase := await_server}};
        false -> {error, peer_authentication_failed, State}
    end;
handle_server_line(
    _Tags,
    undefined,
    <<"SERVER">>,
    [Name, Hop, Token, _Info],
    #{phase := await_server, peer := #{name := Expected}, peer_password := Password} = State
) when
    Password =/= undefined
->
    case
        briskd_wire:fold(Name) =:= briskd_wire:fold(Expected) andalso valid_number(Hop) andalso
            valid_number(Token)
    of
        true ->
            %% An authenticated link resets the reconnect backoff.
            Authenticated = State#{
                phase := authenticated,
                peer_hopcount => binary_to_integer(Hop),
                peer_token => binary_to_integer(Token),
                attempts => 0,
                backoff => undefined
            },
            %% Take the burst before registration. Registering first would
            %% put this peer into known_servers, and the burst would
            %% introduce the peer to itself (`SERVER` of its own name),
            %% which the other side rejects as a loop. A duplicate is still
            %% rejected before anything is sent, with the pre-authentication
            %% state, so retry/2 does not split the link that already owns
            %% the name. A burst that fails after registration is
            %% disconnected here, then retried from that same state.
            Burst = briskd_state:server_burst(),
            case briskd_state:register_adjacent(Name, Token, outbound) of
                {error, duplicate_peer} ->
                    {error, duplicate_peer, State};
                ok ->
                    case send_burst(Burst, Authenticated) of
                        ok ->
                            logger:notice(#{event => server_link_authenticated, peer => Name}),
                            {ok, arm_liveness(Authenticated#{ping_pending => undefined})};
                        {error, Reason} ->
                            ok = briskd_state:server_disconnect(Name),
                            {error, {state_burst_failed, Reason}, State}
                    end
            end;
        false ->
            {error, peer_server_identity_mismatch, State}
    end;
handle_server_line(_Tags, _Prefix, <<"PING">>, [Origin | _], #{phase := authenticated} = State) ->
    Config = maps:get(config, State),
    Reply = raw_line(<<"PONG">>, [maps:get(name, Config), Origin], none),
    case send(maps:get(kind, State), maps:get(socket, State), Reply) of
        ok -> {ok, State};
        {error, Reason} -> {error, {pong_send_failed, Reason}, State}
    end;
handle_server_line(
    _Tags,
    _Prefix,
    <<"PONG">>,
    [PeerName, LocalName | _],
    #{
        phase := authenticated,
        ping_pending := Token,
        peer := #{name := ExpectedPeer},
        config := #{name := ExpectedLocal}
    } = State
) when Token =/= undefined, PeerName =:= ExpectedPeer, LocalName =:= ExpectedLocal ->
    {ok, arm_liveness(State#{ping_pending := undefined})};
handle_server_line(_Tags, _Prefix, <<"ERROR">>, [Reason | _], #{phase := authenticated} = State) ->
    {error, {peer_fatal_error, Reason}, State};
handle_server_line(_Tags, _Prefix, _Command, _Params, #{phase := authenticated} = State) ->
    %% Commands outside the handled set above are ignored.
    {ok, State};
handle_server_line(_, _, _, _, State) ->
    {error, unexpected_handshake_message, State}.

valid_version(<<A, B, C, D, _/binary>> = Version) when
    byte_size(Version) >= 4, byte_size(Version) =< 14
->
    A >= $0 andalso A =< $9 andalso B >= $0 andalso B =< $9 andalso
        C >= $0 andalso C =< $9 andalso D >= $0 andalso D =< $9;
valid_version(_) ->
    false.

valid_number(Value) ->
    try binary_to_integer(Value) of
        Number -> Number >= 0
    catch
        error:badarg -> false
    end.

active_once(#{kind := tcp, socket := Socket}) -> inet:setopts(Socket, [{active, once}]);
active_once(#{kind := tls, socket := Socket}) -> ssl:setopts(Socket, [{active, once}]).

send(tcp, Socket, Data) -> gen_tcp:send(Socket, Data);
send(tls, Socket, Data) -> ssl:send(Socket, Data).

send_burst([], _State) ->
    ok;
send_burst([Line | Rest], #{kind := Kind, socket := Socket} = State) ->
    case send(Kind, Socket, Line) of
        ok -> send_burst(Rest, State);
        Error -> Error
    end.

close(#{kind := tcp, socket := Socket}) -> gen_tcp:close(Socket);
close(#{kind := tls, socket := Socket}) -> ssl:close(Socket);
close(_) -> ok.

retry(State, Reason) ->
    Attempt = maps:get(attempts, State, 0) + 1,
    Previous = maps:get(backoff, State, undefined),
    Backoff = next_backoff(Previous),
    Delay = jitter(Backoff),
    Event = #{
        event => server_link_retry,
        peer => peer_name(State),
        reason => Reason,
        attempt => Attempt,
        delay_ms => Delay
    },
    case Attempt =:= 1 orelse Backoff =/= Previous orelse Attempt rem ?RETRY_LOG_EVERY =:= 0 of
        true -> logger:warning(Event);
        false -> logger:debug(Event)
    end,
    %% A connector that never authenticated must not clear an inbound session
    %% that is using the same peer name.
    case maps:get(phase, State, disconnected) of
        authenticated -> ok = briskd_state:server_disconnect(peer_name(State));
        _ -> ok
    end,
    cancel_timers(State),
    _ = close(State),
    Gen = maps:get(timer_gen, State) + 1,
    Reconnect = erlang:send_after(Delay, self(), {reconnect, Gen}),
    {noreply, State#{
        attempts => Attempt,
        backoff => Backoff,
        socket := undefined,
        kind => undefined,
        phase => disconnected,
        buffer := <<>>,
        peer_password => undefined,
        ping_pending => undefined,
        timer_gen => Gen,
        liveness_timer => undefined,
        ping_timer => undefined,
        reconnect_timer => Reconnect
    }}.

%% Base reconnect delay in milliseconds after the previous one.
next_backoff(undefined) -> ?BACKOFF_MIN_MS;
next_backoff(Previous) -> min(Previous * 2, ?BACKOFF_MAX_MS).

%% The base delay less up to 10% random jitter, so the wait never exceeds the cap.
jitter(Backoff) ->
    Backoff - (rand:uniform(Backoff div 10) - 1).

arm_liveness(State) ->
    cancel_timer(maps:get(liveness_timer, State, undefined)),
    cancel_timer(maps:get(ping_timer, State, undefined)),
    Gen = maps:get(timer_gen, State),
    Ref = erlang:send_after(?LINK_PING_AFTER_MS, self(), {liveness_ping, Gen}),
    State#{liveness_timer => Ref, ping_timer => undefined, ping_pending => undefined}.

cancel_timers(State) ->
    cancel_timer(maps:get(reconnect_timer, State, undefined)),
    cancel_timer(maps:get(liveness_timer, State, undefined)),
    cancel_timer(maps:get(ping_timer, State, undefined)).

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

peer_name(#{peer := Peer}) -> maps:get(name, Peer, <<"unknown">>).

raw_line(Command, Params, none) ->
    iolist_to_binary([Command, [[<<" ">>, Param] || Param <- Params], <<"\r\n">>]);
raw_line(Command, Params, Trailing) ->
    iolist_to_binary([
        Command, [[<<" ">>, Param] || Param <- Params], <<" :">>, Trailing, <<"\r\n">>
    ]).
