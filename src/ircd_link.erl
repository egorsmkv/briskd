-module(ircd_link).
-behaviour(gen_server).
-export([
    start_link/2,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_continue/2,
    handle_info/2,
    format_status/1
]).

%% @doc Start an outbound RFC 2813 peer connection worker.
-spec start_link(map(), map()) -> gen_server:start_ret().
start_link(Config, Peer) -> gen_server:start_link(?MODULE, {Config, Peer}, []).

init({Config, Peer}) ->
    {ok,
        #{
            config => Config,
            peer => Peer,
            socket => undefined,
            buffer => <<>>,
            timer_gen => 0,
            liveness_timer => undefined,
            ping_timer => undefined
        },
        {continue, connect}}.

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

handle_call(_, _, State) -> {reply, {error, unsupported}, State}.
handle_cast({send, Line}, #{phase := authenticated, kind := Kind, socket := Socket} = State) ->
    case send(Kind, Socket, Line) of
        ok -> {noreply, State};
        {error, Reason} -> retry(State, {send_failed, Reason})
    end;
handle_cast(connect_now, #{phase := disconnected, timer_gen := Gen} = State) ->
    cancel_timer(maps:get(reconnect_timer, State, undefined)),
    self() ! {reconnect, Gen},
    {noreply, State#{reconnect_timer => undefined}};
handle_cast(_, State) ->
    {noreply, State}.

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
            Ref = erlang:send_after(30000, self(), {ping_timeout, Gen, Token}),
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
    case ircd_wire:append_pending(maps:get(buffer, State), Packet) of
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

%% @doc Remove the configured link password and any password received during handshake.
-spec format_status(map()) -> map().
format_status(#{state := State} = Status) ->
    Status#{state := redact_state(State)};
format_status(Status) ->
    Status.

redact_state(#{peer := Peer} = State) ->
    State#{peer := maps:remove(password, Peer), peer_password => redacted};
redact_state(State) ->
    State.

connect(#{peer := #{host := Host, port := Port, tls := true}} = State) ->
    HostName = binary_to_list(Host),
    Options = [
        binary,
        {packet, raw},
        {active, false},
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
    Options = [binary, {packet, raw}, {active, false}, {nodelay, true}, {keepalive, true}],
    case gen_tcp:connect(binary_to_list(Host), Port, Options, 10000) of
        {ok, Socket} -> {ok, State#{kind => tcp, socket => Socket}};
        {error, Reason} -> {error, Reason}
    end.

send_handshake(#{kind := Kind, socket := Socket, peer := #{password := Password}, config := Config}) ->
    Server = maps:get(name, Config),
    PassLine = raw_line(<<"PASS">>, [Password, <<"0210">>, <<"|">>], none),
    ServerLine = raw_line(<<"SERVER">>, [Server, <<"1">>, <<"1">>], <<"Erlang/OTP IRC server">>),
    send(Kind, Socket, <<PassLine/binary, ServerLine/binary>>).

consume(Data, State) ->
    case binary:match(Data, <<"\r\n">>) of
        {Offset, 2} ->
            Line = binary:part(Data, 0, Offset + 2),
            Rest = binary:part(Data, Offset + 2, byte_size(Data) - Offset - 2),
            case ircd_wire:parse_server(Line) of
                {ok, Prefix, Command, Params} ->
                    case handle_server_line(Prefix, Command, Params, State) of
                        {ok, Updated} -> consume(Rest, Updated);
                        {error, Reason, Updated} -> {error, Reason, Updated}
                    end;
                empty ->
                    consume(Rest, State);
                error ->
                    {error, malformed_server_message, State}
            end;
        nomatch when byte_size(Data) =< 511 ->
            case
                binary:match(Data, <<"\n">>) =:= nomatch andalso
                    (binary:match(Data, <<"\r">>) =:= nomatch orelse
                        binary:match(Data, <<"\r">>) =:= {byte_size(Data) - 1, 1})
            of
                true -> {ok, State#{buffer := Data}};
                false -> {error, malformed_server_frame, State}
            end;
        nomatch ->
            {error, oversized_server_frame, State}
    end.

handle_server_line(
    undefined,
    <<"PASS">>,
    [Password, Version, _Flags | _],
    #{phase := await_pass, peer := #{password := Expected}} = State
) ->
    case valid_version(Version) andalso ircd_config:secret_match(Password, Expected) of
        true -> {ok, State#{peer_password := Password, phase := await_server}};
        false -> {error, peer_authentication_failed, State}
    end;
handle_server_line(
    undefined,
    <<"SERVER">>,
    [Name, Hop, Token, _Info],
    #{phase := await_server, peer := #{name := Expected}, peer_password := Password} = State
) when
    Password =/= undefined
->
    case
        ircd_wire:fold(Name) =:= ircd_wire:fold(Expected) andalso valid_number(Hop) andalso
            valid_number(Token)
    of
        true ->
            Authenticated = State#{
                phase := authenticated,
                peer_hopcount => binary_to_integer(Hop),
                peer_token => binary_to_integer(Token)
            },
            case send_burst(ircd_state:server_burst(), Authenticated) of
                ok ->
                    ok = ircd_state:register_adjacent(Name, Token, outbound),
                    logger:notice(#{event => server_link_authenticated, peer => Name}),
                    {ok, arm_liveness(Authenticated#{ping_pending => undefined})};
                {error, Reason} ->
                    {error, {state_burst_failed, Reason}, Authenticated}
            end;
        false ->
            {error, peer_server_identity_mismatch, State}
    end;
handle_server_line(_Prefix, <<"PING">>, [Origin | _], #{phase := authenticated} = State) ->
    Config = maps:get(config, State),
    Reply = raw_line(<<"PONG">>, [maps:get(name, Config), Origin], none),
    case send(maps:get(kind, State), maps:get(socket, State), Reply) of
        ok -> {ok, State};
        {error, Reason} -> {error, {pong_send_failed, Reason}, State}
    end;
handle_server_line(
    Prefix,
    Command,
    Params,
    #{phase := authenticated, peer := #{name := PeerName}} = State
) when
    Command =:= <<"NICK">>;
    Command =:= <<"QUIT">>;
    Command =:= <<"AWAY">>;
    Command =:= <<"NJOIN">>;
    Command =:= <<"JOIN">>;
    Command =:= <<"PART">>;
    Command =:= <<"TOPIC">>;
    Command =:= <<"KICK">>;
    Command =:= <<"MODE">>;
    Command =:= <<"PRIVMSG">>;
    Command =:= <<"NOTICE">>;
    Command =:= <<"SERVER">>;
    Command =:= <<"SQUIT">>;
    Command =:= <<"INVITE">>;
    Command =:= <<"SERVICE">>;
    Command =:= <<"SQUERY">>
->
    case ircd_state:server_command(PeerName, Prefix, Command, Params) of
        ok -> {ok, State};
        {error, Reason} -> {error, {invalid_remote_state, Reason}, State}
    end;
handle_server_line(
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
handle_server_line(_Prefix, <<"ERROR">>, [Reason | _], #{phase := authenticated} = State) ->
    {error, {peer_fatal_error, Reason}, State};
handle_server_line(_Prefix, _Command, _Params, #{phase := authenticated} = State) ->
    %% Incoming state bursts and routed commands are not synchronized yet.
    {ok, State};
handle_server_line(_, _, _, State) ->
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
    logger:warning(#{event => server_link_retry, peer => peer_name(State), reason => Reason}),
    %% A connector that never authenticated must not clear an inbound session
    %% that is using the same peer name.
    case maps:get(phase, State, disconnected) of
        authenticated -> ok = ircd_state:server_disconnect(peer_name(State));
        _ -> ok
    end,
    cancel_timers(State),
    close(State),
    Gen = maps:get(timer_gen, State) + 1,
    Reconnect = erlang:send_after(5000, self(), {reconnect, Gen}),
    {noreply, State#{
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

arm_liveness(State) ->
    cancel_timer(maps:get(liveness_timer, State, undefined)),
    cancel_timer(maps:get(ping_timer, State, undefined)),
    Gen = maps:get(timer_gen, State),
    Ref = erlang:send_after(60000, self(), {liveness_ping, Gen}),
    State#{liveness_timer => Ref, ping_timer => undefined, ping_pending => undefined}.

cancel_timers(State) ->
    cancel_timer(maps:get(reconnect_timer, State, undefined)),
    cancel_timer(maps:get(liveness_timer, State, undefined)),
    cancel_timer(maps:get(ping_timer, State, undefined)).

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) when is_reference(Ref) ->
    erlang:cancel_timer(Ref),
    ok.

peer_name(#{peer := Peer}) -> maps:get(name, Peer, <<"unknown">>).

raw_line(Command, Params, none) ->
    iolist_to_binary([Command, [[<<" ">>, Param] || Param <- Params], <<"\r\n">>]);
raw_line(Command, Params, Trailing) ->
    iolist_to_binary([
        Command, [[<<" ">>, Param] || Param <- Params], <<" :">>, Trailing, <<"\r\n">>
    ]).
