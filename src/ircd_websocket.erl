-module(ircd_websocket).
-moduledoc """
Pure RFC 6455 handshake and framing for the IRCv3 WebSocket transport.

The `ws` and `wss` listeners hand each connection to `m:ircd_session`, which
keeps the socket and calls this module: `handshake/2` for the HTTP upgrade,
`decode/2` for incoming frames, and `encode/2` for outgoing ones. This module
makes no process calls and keeps no state.

Following the IRCv3 WebSocket specification, the subprotocols
`binary.ircv3.net` and `text.ircv3.net` are supported, and each WebSocket
message carries exactly one IRC line without CR LF. A text-mode client only
receives valid UTF-8 (`utf8_safe/1`).

Bounds: the upgrade request is at most 8192 bytes, client frames must be
masked (RFC 6455 section 5.1), control frames carry at most 125 bytes and are
never fragmented (section 5.5), reserved opcodes are refused, and a frame or
reassembled message larger than the caller's `MaxMessage` is an error (the
session passes `MAX_WIRE_LINE`, 8703 bytes).
""".
-export([decode/2, encode/2, handshake/2, utf8_safe/1]).

-define(GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).
-define(MAX_REQUEST, 8192).

-doc "Frame type for IRC lines, chosen by the negotiated subprotocol.".
-type mode() :: text | binary.
-doc "One decoded data message or control frame and its unmasked payload.".
-type frame() :: {text | binary | close | ping | pong, binary()}.
-export_type([mode/0, frame/0]).

-doc """
Parse a client's HTTP/1.1 WebSocket upgrade request (RFC 6455 section 4.2).

`Data` is everything read so far. `Origins` is `null` to accept any origin, or
the list of allowed `Origin` header values (configuration key `ws_origins`);
with a list, a request without `Origin` is refused. Results:

- `more`: the header block is not complete and is at most 8192 bytes; read
  more and call again with all the data.
- `{ok, Response, Mode, Rest}`: send `Response` (101 Switching Protocols
  with `Sec-WebSocket-Accept`) and use `Mode` (`text` or `binary`) for data
  frames. `Rest` holds any bytes after the request, which are frame data.
- `{error, Response}`: send the HTTP error `Response` and close: 400 for a
  request that is not a `GET` upgrade with a `Sec-WebSocket-Key`, 426 for a
  `Sec-WebSocket-Version` other than 13, 403 for a refused origin, and 431 when
  more than 8192 bytes arrive without the end of the headers.

The first offered subprotocol that this server supports is selected and
echoed. With none offered, the connection uses text frames and the response
has no `Sec-WebSocket-Protocol` header.
""".
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

-doc """
Decode the complete client frames at the start of `Buffer` (RFC 6455 section 5).

Returns `{ok, Frames, Rest}`. `Frames` lists, in arrival order, data messages
as `{text | binary, Message}` with fragments already joined, and control
frames as `{close | ping | pong, Payload}`. `Rest` is the input to keep for the
next read. Control frames may arrive between the fragments of a message
(RFC 6455 section 5.4); they are returned at once so the caller can answer a
`ping` or handle a `close`, and the message keeps assembling. While a
fragmented message is incomplete, `Rest` starts with the fragments received so
far, re-encoded as one unfinished masked frame, followed by the unread bytes,
so a control frame that was already returned is not returned again.

`MaxMessage` caps both a single frame's payload and a reassembled message.
`{error, Reason}` means the connection should be closed (the session sends
close code 1002). `Reason` is one of `unmasked_frame`, `reserved_bits`,
`control_too_large` (over 125 bytes), `fragmented_control` (a control frame
without FIN, RFC 6455 section 5.5), `too_large`, `unexpected_continuation`,
`interleaved_message` (a new data frame before the previous message ended), or
`bad_opcode` (a reserved opcode, 3 to 7 or 11 to 15).
""".
-spec decode(binary(), pos_integer()) -> {ok, [frame()], binary()} | {error, atom()}.
decode(Buffer, MaxMessage) ->
    decode(Buffer, MaxMessage, undefined, []).

%% `Partial` is `{Type, Data}` for a fragmented message that has not ended.
decode(Buffer, Max, Partial, Acc) ->
    case frame(Buffer, Max) of
        more when Partial =:= undefined ->
            {ok, lists:reverse(Acc), Buffer};
        more ->
            {ok, lists:reverse(Acc), <<(unfinished(Partial))/binary, Buffer/binary>>};
        {error, Reason} ->
            {error, Reason};
        {ok, Fin, Opcode, Payload, Rest} ->
            case {Opcode, Fin, Partial} of
                {Control, false, _} when Control >= 8, Control =< 10 ->
                    {error, fragmented_control};
                {Control, true, _} when Control >= 8, Control =< 10 ->
                    %% RFC 6455 section 5.4: a control frame may arrive between
                    %% fragments; return it now and keep assembling.
                    decode(Rest, Max, Partial, [control(Control, Payload) | Acc]);
                {0, _, undefined} ->
                    {error, unexpected_continuation};
                {0, true, {Type, Data}} ->
                    Whole = <<Data/binary, Payload/binary>>,
                    case byte_size(Whole) > Max of
                        true -> {error, too_large};
                        false -> decode(Rest, Max, undefined, [{Type, Whole} | Acc])
                    end;
                {0, false, {Type, Data}} ->
                    Whole = <<Data/binary, Payload/binary>>,
                    case byte_size(Whole) > Max of
                        true -> {error, too_large};
                        false -> decode(Rest, Max, {Type, Whole}, Acc)
                    end;
                {Data, _, {_, _}} when Data =:= 1; Data =:= 2 ->
                    {error, interleaved_message};
                {1, true, undefined} ->
                    decode(Rest, Max, undefined, [{text, Payload} | Acc]);
                {2, true, undefined} ->
                    decode(Rest, Max, undefined, [{binary, Payload} | Acc]);
                {1, false, undefined} ->
                    decode(Rest, Max, {text, Payload}, Acc);
                {2, false, undefined} ->
                    decode(Rest, Max, {binary, Payload}, Acc);
                _ ->
                    %% Reserved opcodes 3-7 and 11-15 (RFC 6455 section 5.2).
                    {error, bad_opcode}
            end
    end.

control(8, Payload) -> {close, Payload};
control(9, Payload) -> {ping, Payload};
control(10, Payload) -> {pong, Payload}.

%% The fragments of an unfinished message as one masked frame without FIN,
%% with an all-zero mask so the payload bytes stay as they are. The payload is
%% at most `MaxMessage`, so it decodes again under the same limit.
unfinished({Type, Data}) ->
    Opcode =
        case Type of
            text -> 1;
            binary -> 2
        end,
    Len = byte_size(Data),
    Header =
        if
            Len < 126 -> <<0:1, 0:3, Opcode:4, 1:1, Len:7>>;
            Len < 65536 -> <<0:1, 0:3, Opcode:4, 1:1, 126:7, Len:16>>;
            true -> <<0:1, 0:3, Opcode:4, 1:1, 127:7, Len:64>>
        end,
    <<Header/binary, 0:32, Data/binary>>.

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

-doc """
Encode one unfragmented, unmasked server-to-client frame (RFC 6455 section 5.2).

`Type` selects the opcode and `Payload` is the whole message; the 7-, 16-, or
64-bit length form is chosen from its size. Server frames are never masked.
The caller keeps control payloads within 125 bytes; a `close` payload starts
with a 2-byte status code such as `<<1000:16>>`.
""".
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

-doc """
Make a line valid UTF-8 by replacing each invalid byte with U+FFFD.

Valid input is returned unchanged. The session uses it for lines sent to a
text-mode client, as the IRCv3 WebSocket specification allows, and to reject
an incoming text frame that is not valid UTF-8.
""".
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
