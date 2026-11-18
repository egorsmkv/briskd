-module(ircd_wire).
-export([
    parse/1, parse_server/1, line/4, fold/1, nickname/1, channel/1, safe_channel/1, append_pending/2
]).

-include("ircd_wire.hrl").

%% @doc Append one socket delivery to the unfinished line, or reject an oversized buffer.
-spec append_pending(binary(), binary()) -> {ok, binary()} | error.
append_pending(Buffer, Packet) when
    is_binary(Buffer),
    is_binary(Packet),
    byte_size(Buffer) + byte_size(Packet) =< ?MAX_PENDING_BYTES
->
    {ok, <<Buffer/binary, Packet/binary>>};
append_pending(Buffer, Packet) when is_binary(Buffer), is_binary(Packet) ->
    error.

%% @doc Parse one CRLF-terminated IRC line into a command and binary parameters.
%% Returns `empty' for an empty line and `error' for malformed or oversized input.
-spec parse(binary()) -> {ok, binary(), [binary()]} | empty | error.
parse(Packet) when byte_size(Packet) >= 2, byte_size(Packet) =< 512 ->
    case parse_server(Packet) of
        {ok, undefined, Command, Params} -> {ok, Command, Params};
        {ok, _Prefix, _Command, _Params} -> error;
        Other -> Other
    end;
parse(_) ->
    error.

%% @doc Parse an IRC line from a server link, retaining its optional prefix.
%% Server links can carry source prefixes; client input must use parse/1.
-spec parse_server(binary()) -> {ok, undefined | binary(), binary(), [binary()]} | empty | error.
parse_server(Packet) when byte_size(Packet) >= 2, byte_size(Packet) =< 512 ->
    Size = byte_size(Packet) - 2,
    case Packet of
        <<Body:Size/binary, "\r\n">> ->
            case binary:match(Body, [<<0>>, <<"\r">>, <<"\n">>]) of
                nomatch -> parse_server_command(Body);
                _ -> error
            end;
        _ ->
            error
    end;
parse_server(_) ->
    error.

parse_server_command(<<$:, Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [<<>>, _] ->
            error;
        [_Prefix, <<>>] ->
            error;
        [Prefix, CommandLine] ->
            case parse_command(CommandLine) of
                {ok, Command, Params} -> {ok, Prefix, Command, Params};
                Other -> Other
            end
    end;
parse_server_command(Body) ->
    case parse_command(Body) of
        {ok, Command, Params} -> {ok, undefined, Command, Params};
        Other -> Other
    end.

parse_command(<<>>) ->
    empty;
parse_command(Body) ->
    [Command | Rest] = binary:split(Body, <<" ">>),
    case re:run(Command, <<"^(?:[A-Za-z]+|[0-9]{3})$">>, [{capture, none}]) of
        match -> params(Rest, string:uppercase(Command), []);
        nomatch -> error
    end.

params([], Command, Acc) ->
    {ok, Command, lists:reverse(Acc)};
params([<<>>], Command, Acc) ->
    params([], Command, Acc);
params([<<" ", Rest/binary>>], Command, Acc) ->
    params([Rest], Command, Acc);
params([<<":", Rest/binary>>], Command, Acc) when length(Acc) < 15 ->
    params([], Command, [Rest | Acc]);
params([Rest], Command, Acc) when length(Acc) =:= 14 ->
    params([], Command, [Rest | Acc]);
params([Rest], Command, Acc) when length(Acc) < 14 ->
    [Param | Tail] = binary:split(Rest, <<" ">>),
    params(Tail, Command, [Param | Acc]);
params(_, _, _) ->
    error.

%% @doc Encode an IRC message, enforcing the protocol's 512-byte line limit.
-spec line(iodata(), iodata(), [iodata()], none | iodata()) -> iodata().
line(Prefix, Command, Middle, Trailing) ->
    Head = iolist_to_binary([
        <<":">>,
        Prefix,
        <<" ">>,
        Command,
        [[<<" ">>, Item] || Item <- Middle]
    ]),
    case {byte_size(Head), Trailing} of
        {Size, none} when Size =< 510 -> [Head, <<"\r\n">>];
        {Size, Tail} when Size =< 508 ->
            Bytes = iolist_to_binary(Tail),
            [
                Head,
                <<" :">>,
                binary:part(Bytes, 0, min(508 - Size, byte_size(Bytes))),
                <<"\r\n">>
            ];
        _ ->
            []
    end.

%% @doc Fold an IRC identifier according to the RFC1459 case mapping.
-spec fold(binary()) -> binary().
fold(Value) -> <<<<(lower(C))>> || <<C>> <= Value>>.
lower(C) when C >= $A, C =< $Z -> C + 32;
lower($[) -> ${;
lower($]) -> $};
lower(92) -> $|;
lower($^) -> $~;
lower(C) -> C.

%% @doc Check whether a nickname uses the server's supported RFC character set.
-spec nickname(binary()) -> boolean().
nickname(Nick) ->
    re:run(
        Nick,
        <<"^[A-Za-z\\x5b-\\x60\\x7b-\\x7d][A-Za-z0-9\\x5b-\\x60\\x7b-\\x7d-]{0,8}$">>,
        [{capture, none}, dollar_endonly]
    ) =:= match.

%% @doc Validate a regular or safe channel name accepted by this server.
-spec channel(binary()) -> boolean().
channel(<<Type, Rest/binary>>) when Type =:= $#; Type =:= $&; Type =:= $+ ->
    byte_size(Rest) > 0 andalso byte_size(Rest) < 50 andalso
        binary:match(Rest, [<<0>>, <<7>>, <<" ">>, <<",">>, <<":">>]) =:= nomatch;
channel(<<$!, _/binary>> = Name) ->
    safe_channel(Name);
channel(_) ->
    false.

%% @doc Validate the server-generated identifier and short name in a safe channel.
-spec safe_channel(binary()) -> boolean().
safe_channel(<<$!, Id:5/binary, Short/binary>>) when
    byte_size(Short) > 0,
    byte_size(Short) =< 44
->
    safe_id(Id) andalso binary:match(Short, [<<0>>, <<7>>, <<" ">>, <<",">>, <<":">>]) =:= nomatch;
safe_channel(_) ->
    false.

safe_id(<<>>) ->
    true;
safe_id(<<Char, Rest/binary>>) ->
    (Char >= $A andalso Char =< $Z orelse Char >= $1 andalso Char =< $9 orelse Char =:= $0) andalso
        safe_id(Rest).
