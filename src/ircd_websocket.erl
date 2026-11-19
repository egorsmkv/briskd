-module(ircd_websocket).
-export([decode/2, encode/2, handshake/2, utf8_safe/1]).

%% Pure RFC 6455 handshake and framing for the IRCv3 WebSocket transport.
%% Subprotocols `binary.ircv3.net` and `text.ircv3.net` are supported. Each
%% WebSocket message carries one IRC line without CR LF. Client frames must
%% be masked. A message larger than `MaxMessage` bytes is an error.

-define(GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).
-define(MAX_REQUEST, 8192).

-type mode() :: text | binary.
-type frame() :: {text | binary | close | ping | pong, binary()}.
-export_type([mode/0, frame/0]).

%% @doc Parse an HTTP upgrade request. `Origins` is `null` (any origin) or the
%% list of allowed `Origin` header values.
-spec handshake(binary(), null | [binary()]) ->
    more | {ok, iodata(), mode(), binary()} | {error, iodata()}.
handshake(Data, Origins) ->
    case binary:match(Data, <<"\r\n\r\n">>) of
        nomatch when byte_size(Data) > ?MAX_REQUEST ->
            {error, response(<<"431 Request Header Fields Too Large">>, [])};
        nomatch ->
            more;
        {Offset, 4} ->
            Head = binary:part(Data, 0, Offset),
            Rest = binary:part(Data, Offset + 4, byte_size(Data) - Offset - 4),
            [RequestLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
            Headers = headers(HeaderLines),
            check(RequestLine, Headers, Origins, Rest)
    end.

check(RequestLine, Headers, Origins, Rest) ->
    Upgrade = string:lowercase(maps:get(<<"upgrade">>, Headers, <<>>)),
    Connection = string:lowercase(maps:get(<<"connection">>, Headers, <<>>)),
    Key = maps:get(<<"sec-websocket-key">>, Headers, undefined),
    Version = maps:get(<<"sec-websocket-version">>, Headers, undefined),
    Origin = maps:get(<<"origin">>, Headers, undefined),
    Upgradable =
        binary:match(RequestLine, <<"GET ">>) =:= {0, 4} andalso Upgrade =:= <<"websocket">> andalso
            binary:match(Connection, <<"upgrade">>) =/= nomatch andalso is_binary(Key),
    if
        not Upgradable ->
            {error, response(<<"400 Bad Request">>, [])};
        Version =/= <<"13">> ->
            {error,
                response(<<"426 Upgrade Required">>, [{<<"Sec-WebSocket-Version">>, <<"13">>}])};
        true ->
            case origin_allowed(Origin, Origins) of
                false ->
                    {error, response(<<"403 Forbidden">>, [])};
                true ->
                    Accept = base64:encode(crypto:hash(sha, <<Key/binary, ?GUID/binary>>)),
                    {Mode, ProtocolHeader} = subprotocol(
                        maps:get(<<"sec-websocket-protocol">>, Headers, <<>>)
                    ),
                    {ok,
                        response(
                            <<"101 Switching Protocols">>,
                            [
                                {<<"Upgrade">>, <<"websocket">>},
                                {<<"Connection">>, <<"Upgrade">>},
                                {<<"Sec-WebSocket-Accept">>, Accept}
                                | ProtocolHeader
                            ]
                        ),
                        Mode, Rest}
            end
    end.

origin_allowed(_Origin, null) -> true;
origin_allowed(undefined, _Origins) -> false;
origin_allowed(Origin, Origins) -> lists:member(Origin, Origins).

%% The first offered subprotocol this server supports wins. With none offered,
%% the connection uses text frames and no Sec-WebSocket-Protocol header.
subprotocol(Offered) ->
    Names = [string:trim(Name) || Name <- binary:split(Offered, <<",">>, [global])],
    case
        [
            Name
         || Name <- Names, Name =:= <<"binary.ircv3.net">> orelse Name =:= <<"text.ircv3.net">>
        ]
    of
        [<<"binary.ircv3.net">> = Name | _] -> {binary, [{<<"Sec-WebSocket-Protocol">>, Name}]};
        [<<"text.ircv3.net">> = Name | _] -> {text, [{<<"Sec-WebSocket-Protocol">>, Name}]};
        [] -> {text, []}
    end.

%% Repeated header fields are joined with `,` (RFC 7230), so two
%% Sec-WebSocket-Protocol lines keep the client's order of preference.
headers(Lines) ->
    lists:foldl(
        fun({Name, Value}, Acc) ->
            case Acc of
                #{Name := Existing} -> Acc#{Name => <<Existing/binary, ", ", Value/binary>>};
                _ -> Acc#{Name => Value}
            end
        end,
        #{},
        [
            {string:lowercase(string:trim(Name)), string:trim(Value)}
         || Line <- Lines,
            [Name, Value] <- [binary:split(Line, <<":">>)]
        ]
    ).

response(Status, Headers) ->
    [
        <<"HTTP/1.1 ">>,
        Status,
        <<"\r\n">>,
        [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Headers],
        <<"\r\n">>
    ].

%% @doc Decode complete client frames from Buffer. Fragmented data messages
%% are joined. Returns the frames and the unconsumed bytes.
-spec decode(binary(), pos_integer()) -> {ok, [frame()], binary()} | {error, atom()}.
decode(Buffer, MaxMessage) ->
    decode(Buffer, MaxMessage, undefined, Buffer, []).

%% `Start` is the buffer position where an unfinished fragmented message
%% began; when more bytes are needed the whole message is decoded again later.
decode(Buffer, Max, Partial, Start, Acc) ->
    case frame(Buffer, Max) of
        more when Partial =:= undefined ->
            {ok, lists:reverse(Acc), Buffer};
        more ->
            {ok, lists:reverse(Acc), Start};
        {error, Reason} ->
            {error, Reason};
        {ok, Fin, Opcode, Payload, Rest} ->
            case {Opcode, Fin, Partial} of
                {Control, _, undefined} when Control >= 8 ->
                    decode(Rest, Max, undefined, Rest, [control(Control, Payload) | Acc]);
                {Control, _, _} when Control >= 8 ->
                    %% A control frame between fragments is answered when the
                    %% message completes, so the fragments can be re-read.
                    decode(Rest, Max, Partial, Start, Acc);
                {0, _, undefined} ->
                    {error, unexpected_continuation};
                {0, true, {Type, Data}} ->
                    Whole = <<Data/binary, Payload/binary>>,
                    case byte_size(Whole) > Max of
                        true -> {error, too_large};
                        false -> decode(Rest, Max, undefined, Rest, [{Type, Whole} | Acc])
                    end;
                {0, false, {Type, Data}} ->
                    Whole = <<Data/binary, Payload/binary>>,
                    case byte_size(Whole) > Max of
                        true -> {error, too_large};
                        false -> decode(Rest, Max, {Type, Whole}, Start, Acc)
                    end;
                {Data, _, {_, _}} when Data =:= 1; Data =:= 2 ->
                    {error, interleaved_message};
                {1, true, undefined} ->
                    decode(Rest, Max, undefined, Rest, [{text, Payload} | Acc]);
                {2, true, undefined} ->
                    decode(Rest, Max, undefined, Rest, [{binary, Payload} | Acc]);
                {1, false, undefined} ->
                    decode(Rest, Max, {text, Payload}, Buffer, Acc);
                {2, false, undefined} ->
                    decode(Rest, Max, {binary, Payload}, Buffer, Acc);
                _ ->
                    {error, bad_opcode}
            end
    end.

control(8, Payload) -> {close, Payload};
control(9, Payload) -> {ping, Payload};
control(10, Payload) -> {pong, Payload};
control(_, Payload) -> {close, Payload}.

frame(<<Fin:1, 0:3, Opcode:4, 1:1, Len:7, Rest/binary>>, Max) ->
    case {Len, Rest} of
        {126, <<Ext:16, More/binary>>} -> payload(Fin, Opcode, Ext, More, Max);
        {127, <<Ext:64, More/binary>>} -> payload(Fin, Opcode, Ext, More, Max);
        {126, _} -> more;
        {127, _} -> more;
        _ -> payload(Fin, Opcode, Len, Rest, Max)
    end;
frame(<<_:1, Rsv:3, _:4, _/binary>>, _Max) when Rsv =/= 0 ->
    {error, reserved_bits};
frame(<<_:8, 0:1, _:7, _/binary>>, _Max) ->
    {error, unmasked_frame};
frame(_, _Max) ->
    more.

payload(_Fin, Opcode, Len, _Rest, _Max) when Opcode >= 8, Len > 125 ->
    {error, control_too_large};
payload(_Fin, _Opcode, Len, _Rest, Max) when Len > Max ->
    {error, too_large};
payload(Fin, Opcode, Len, Bytes, _Max) ->
    case Bytes of
        <<Mask:4/binary, Data:Len/binary, Rest/binary>> ->
            {ok, Fin =:= 1, Opcode, unmask(Data, Mask), Rest};
        _ ->
            more
    end.

unmask(Data, <<M:32>>) ->
    unmask(Data, M, <<>>).

unmask(<<Word:32, Rest/binary>>, M, Acc) ->
    unmask(Rest, M, <<Acc/binary, (Word bxor M):32>>);
unmask(<<Tail/binary>>, M, Acc) ->
    Bits = bit_size(Tail),
    <<Key:Bits, _/bitstring>> = <<M:32>>,
    <<T:Bits>> = Tail,
    <<Acc/binary, (T bxor Key):Bits>>.

%% @doc Encode one unmasked server frame.
-spec encode(text | binary | close | ping | pong, iodata()) -> iolist().
encode(Type, Payload) ->
    Data = iolist_to_binary(Payload),
    Opcode =
        case Type of
            text -> 1;
            binary -> 2;
            close -> 8;
            ping -> 9;
            pong -> 10
        end,
    Len = byte_size(Data),
    Header =
        if
            Len < 126 -> <<1:1, 0:3, Opcode:4, 0:1, Len:7>>;
            Len < 65536 -> <<1:1, 0:3, Opcode:4, 0:1, 126:7, Len:16>>;
            true -> <<1:1, 0:3, Opcode:4, 0:1, 127:7, Len:64>>
        end,
    [Header, Data].

%% @doc Make a line valid UTF-8 for a text-mode client by replacing invalid
%% bytes with U+FFFD, as the IRCv3 WebSocket specification allows.
-spec utf8_safe(binary()) -> binary().
utf8_safe(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Valid when is_binary(Valid) -> Valid;
        {_, Good, Bad} -> <<Good/binary, (replace_bad(Bad))/binary>>
    end.

replace_bad(<<>>) ->
    <<>>;
replace_bad(<<_, Rest/binary>>) ->
    <<16#EF, 16#BF, 16#BD, (utf8_safe(Rest))/binary>>.
