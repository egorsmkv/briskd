-module(ircd_session).
-behaviour(gen_server).
-export([
    start_link/3,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    format_status/1,
    terminate/2
]).

%% @doc Start a temporary process for one accepted TCP or TLS client socket.
-spec start_link(tcp | tls, port(), binary()) -> gen_server:start_ret().
start_link(Kind, Socket, Peer) -> gen_server:start_link(?MODULE, {Kind, Socket, Peer}, []).

%% @doc Initialize the session before socket ownership is transferred to it.
init(State) -> {ok, State}.
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.
handle_cast(_, State) -> {noreply, State}.

%% Perform the TLS handshake if needed, register the client, then read IRC lines.
handle_info(activate, {Kind, Socket, Peer} = State) ->
    case handshake(Kind, Socket) of
        ok ->
            erlang:send_after(30000, self(), registration_timeout),
            active({Kind, Socket, Peer, <<>>, awaiting});
        {error, _} ->
            {stop, normal, State}
    end;
handle_info({irc, Line}, {Kind, Socket, _, _, _} = State) ->
    Module = transport(Kind),
    case Module:send(Socket, Line) of
        ok -> {noreply, State};
        {error, _} -> {stop, normal, State}
    end;
handle_info({irc_close, Line}, {Kind, Socket, _, _, _} = State) ->
    Module = transport(Kind),
    _ = Module:send(Socket, Line),
    {stop, normal, State};
handle_info({Tag, Socket, Packet}, {Kind, Socket, Peer, Buffer, Role}) when
    Tag =:= tcp; Tag =:= ssl
->
    case ircd_wire:append_pending(Buffer, Packet) of
        {ok, Data} ->
            case consume(Data, {Kind, Socket, Peer, <<>>, Role}) of
                {ok, State} -> active(State);
                quit -> {stop, normal, {Kind, Socket, Peer, <<>>}};
                error -> {stop, normal, {Kind, Socket, Peer, <<>>}}
            end;
        error ->
            {stop, normal, {Kind, Socket, Peer, <<>>}}
    end;
handle_info(registration_timeout, {_, _, _, _, Role} = State) ->
    case Role of
        {server, _} ->
            {noreply, State};
        {server_pass, _} ->
            {stop, normal, State};
        client ->
            case ircd_state:registered() of
                true -> {noreply, State};
                false -> {stop, normal, State}
            end;
        awaiting ->
            {stop, normal, State}
    end;
handle_info(liveness_ping, {Kind, Socket, _, _, {server, undefined}} = State) ->
    Config = persistent_term:get({ircd_state, config}),
    Token = make_ref(),
    Module = transport(Kind),
    Ping = raw_line(<<"PING">>, [maps:get(name, Config)], none),
    case Module:send(Socket, Ping) of
        ok ->
            erlang:send_after(30000, self(), {link_ping_timeout, Token}),
            {noreply, set_role(State, {server, Token})};
        {error, _} ->
            {stop, normal, State}
    end;
handle_info({link_ping_timeout, Token}, {_, _, _, _, {server, Token}} = State) ->
    {stop, normal, State};
handle_info({link_ping_timeout, _}, State) ->
    {noreply, State};
handle_info({Tag, Socket}, {_, Socket, _, _, _} = State) when
    Tag =:= tcp_closed; Tag =:= ssl_closed
->
    {stop, normal, State};
handle_info({Tag, Socket, _}, {_, Socket, _, _, _} = State) when
    Tag =:= tcp_error; Tag =:= ssl_error
->
    {stop, normal, State};
%% Ignore socket traffic and timers that belong to a previous connection state.
handle_info(_, State) ->
    {noreply, State}.

%% @doc Redact an inbound server link password held during the handshake.
-spec format_status(map()) -> map().
format_status(#{state := State} = Status) ->
    Status#{state := redact_state(State)};
format_status(Status) ->
    Status.

redact_state({Kind, Socket, Peer, Buffer, {server_pass, _Password}}) ->
    {Kind, Socket, Peer, Buffer, {server_pass, redacted}};
redact_state(State) ->
    State.

terminate(_, {_, _, Peer, _, {server, _}}) ->
    ok = ircd_state:server_disconnect(Peer);
terminate(_, _) ->
    ok.

transport(tcp) -> gen_tcp;
transport(tls) -> ssl.

handshake(tcp, _) ->
    ok;
handshake(tls, Socket) ->
    case ssl:handshake(Socket, 5000) of
        {ok, Socket} -> ok;
        Error -> Error
    end.

consume(Data, State) ->
    case binary:match(Data, <<"\r\n">>) of
        {Offset, 2} ->
            Line = binary:part(Data, 0, Offset + 2),
            Rest = binary:part(Data, Offset + 2, byte_size(Data) - Offset - 2),
            case parse_line(Line, State) of
                {ok, Prefix, Command, Params} ->
                    Result =
                        case element(5, State) of
                            {server, _} ->
                                process_server_line(
                                    Prefix, Command, Params, byte_size(Line), State
                                );
                            _ ->
                                process_line(Command, Params, byte_size(Line), State)
                        end,
                    case Result of
                        {ok, Updated} -> consume(Rest, Updated);
                        quit -> quit;
                        error -> error
                    end;
                empty ->
                    consume(Rest, State);
                error ->
                    error
            end;
        nomatch ->
            case valid_partial(Data) of
                true -> {ok, set_buffer(State, Data)};
                false -> error
            end
    end.

parse_line(Line, {_, _, _, _, {server, _}}) ->
    case ircd_wire:parse_server(Line) of
        {ok, Prefix, Command, Params} -> {ok, Prefix, Command, Params};
        Other -> Other
    end;
parse_line(Line, _) ->
    case ircd_wire:parse(Line) of
        {ok, Command, Params} -> {ok, undefined, Command, Params};
        Other -> Other
    end.

valid_partial(Data) when byte_size(Data) =< 511 ->
    case {binary:match(Data, <<"\n">>), binary:match(Data, <<"\r">>)} of
        {nomatch, nomatch} -> true;
        {nomatch, {Offset, 1}} -> Offset =:= byte_size(Data) - 1;
        _ -> false
    end;
valid_partial(_) ->
    false.

set_buffer({Kind, Socket, Peer, _, Role}, Buffer) ->
    {Kind, Socket, Peer, Buffer, Role}.

active({Kind, Socket, _, _, _} = State) ->
    Result =
        case Kind of
            tcp -> inet:setopts(Socket, [{active, once}]);
            tls -> ssl:setopts(Socket, [{active, once}])
        end,
    case Result of
        ok -> {noreply, State};
        {error, _} -> {stop, normal, State}
    end.

process_line(<<"PASS">>, [Password, Version, _Flags | _], _Bytes, {_, _, _, _, awaiting} = State) ->
    case valid_server_version(Version) of
        true -> {ok, set_link_password(State, Password)};
        false -> error
    end;
process_line(<<"SERVER">>, [Name, Hop, Token, _Info], _Bytes, State) ->
    case State of
        {Kind, Socket, _Peer, _Buffer, {server_pass, Password}} ->
            case
                ircd_state:authenticate_server_link(Name, Password) andalso
                    valid_server_number(Hop) andalso valid_server_number(Token)
            of
                true ->
                    Config = persistent_term:get({ircd_state, config}),
                    LocalName = maps:get(name, Config),
                    Reply = [
                        raw_line(<<"PASS">>, [Password, <<"0210">>, <<"|">>], none),
                        raw_line(
                            <<"SERVER">>,
                            [LocalName, <<"1">>, <<"1">>],
                            <<"Erlang/OTP IRC server">>
                        )
                    ],
                    Burst = [iolist_to_binary(Line) || Line <- ircd_state:server_burst()],
                    ok = ircd_state:register_adjacent(Name, Token, inbound),
                    Module = transport(Kind),
                    case Module:send(Socket, [Reply, Burst]) of
                        ok ->
                            logger:notice(#{
                                event => inbound_server_link_authenticated, peer => Name
                            }),
                            erlang:send_after(60000, self(), liveness_ping),
                            {ok, set_peer_and_role(State, Name, {server, undefined})};
                        {error, _} ->
                            error
                    end;
                false ->
                    error
            end;
        _ ->
            error
    end;
process_line(Command, Params, Bytes, {_, _, _, _, awaiting} = State) ->
    case promote_client(State) of
        {ok, ClientState} ->
            process_client_line(Command, Params, Bytes, ClientState);
        error ->
            error
    end;
process_line(_Command, _Params, _Bytes, {_, _, _, _, {server_pass, _}}) ->
    error;
process_line(Command, Params, Bytes, {_, _, _, _, client} = State) ->
    process_client_line(Command, Params, Bytes, State).

process_server_line(_Prefix, <<"PING">>, [Origin | _], _Bytes, {Kind, Socket, _, _, _} = State) ->
    Config = persistent_term:get({ircd_state, config}),
    Reply = raw_line(<<"PONG">>, [maps:get(name, Config), Origin], none),
    Module = transport(Kind),
    case Module:send(Socket, Reply) of
        ok -> {ok, State};
        {error, _} -> error
    end;
process_server_line(
    _Prefix,
    <<"PONG">>,
    [Responder, Origin | _],
    _Bytes,
    {_, _, PeerName, _, {server, Token}} = State
) when Token =/= undefined ->
    Config = persistent_term:get({ircd_state, config}),
    case Responder =:= PeerName andalso Origin =:= maps:get(name, Config) of
        true ->
            erlang:send_after(60000, self(), liveness_ping),
            {ok, set_role(State, {server, undefined})};
        false ->
            {ok, State}
    end;
process_server_line(_Prefix, <<"ERROR">>, [Reason | _], _Bytes, _State) ->
    logger:warning(#{event => inbound_server_link_error, reason => Reason}),
    quit;
process_server_line(Prefix, Command, Params, _Bytes, {_, _, Peer, _, _} = State) when
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
    case ircd_state:server_command(Peer, Prefix, Command, Params) of
        ok ->
            {ok, State};
        {error, Reason} ->
            logger:warning(#{event => invalid_remote_state, peer => Peer, reason => Reason}),
            error
    end;
process_server_line(_Prefix, _Command, _Params, _Bytes, State) ->
    {ok, State}.

process_client_line(Command, Params, Bytes, {_, _, _, _, client} = State) ->
    case ircd_state:command(Command, Params, Bytes) of
        quit -> quit;
        ok -> {ok, State}
    end.

promote_client({Kind, Socket, Peer, Buffer, awaiting}) ->
    ok = ircd_state:connect(Peer),
    {ok, {Kind, Socket, Peer, Buffer, client}};
promote_client(_) ->
    error.

set_link_password({Kind, Socket, Peer, Buffer, awaiting}, Password) ->
    {Kind, Socket, Peer, Buffer, {server_pass, Password}}.

set_role({Kind, Socket, Peer, Buffer, _}, Role) ->
    {Kind, Socket, Peer, Buffer, Role}.

set_peer_and_role({Kind, Socket, _Peer, Buffer, _}, Peer, Role) ->
    {Kind, Socket, Peer, Buffer, Role}.

valid_server_version(<<A, B, C, D, _/binary>> = Version) ->
    byte_size(Version) =< 14 andalso A >= $0 andalso A =< $9 andalso B >= $0 andalso B =< $9 andalso
        C >= $0 andalso C =< $9 andalso D >= $0 andalso D =< $9;
valid_server_version(_) ->
    false.

valid_server_number(Value) ->
    try binary_to_integer(Value) of
        Number -> Number >= 0
    catch
        error:badarg -> false
    end.

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
