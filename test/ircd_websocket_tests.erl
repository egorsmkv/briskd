-module(ircd_websocket_tests).
-include_lib("eunit/include/eunit.hrl").

%% RFC 6455 handshake and framing used by the IRCv3 WebSocket transport.

request(Extra) ->
    iolist_to_binary([
        <<"GET /irc HTTP/1.1\r\nHost: example\r\nUpgrade: websocket\r\n">>,
        <<"Connection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\n">>,
        <<"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n">>,
        Extra,
        <<"\r\n">>
    ]).

rfc_example_accept_key_test() ->
    {ok, Response, text, <<>>} = ircd_websocket:handshake(request(<<>>), null),
    Bin = iolist_to_binary(Response),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=">>)),
    ?assertEqual(nomatch, binary:match(Bin, <<"Sec-WebSocket-Protocol">>)).

subprotocol_preference_test() ->
    {ok, _, text, _} = ircd_websocket:handshake(
        request(<<"Sec-WebSocket-Protocol: text.ircv3.net, binary.ircv3.net\r\n">>), null
    ),
    {ok, _, binary, _} = ircd_websocket:handshake(
        request(<<"Sec-WebSocket-Protocol: foo, binary.ircv3.net\r\n">>), null
    ).

repeated_protocol_headers_test() ->
    {ok, _, binary, _} = ircd_websocket:handshake(
        request(
            <<"Sec-WebSocket-Protocol: binary.ircv3.net\r\nSec-WebSocket-Protocol: text.ircv3.net\r\n">>
        ),
        null
    ).

origin_and_partial_request_test() ->
    ?assertEqual(more, ircd_websocket:handshake(<<"GET / HTTP/1.1\r\n">>, null)),
    ?assertMatch({error, _}, ircd_websocket:handshake(request(<<>>), [<<"https://ok">>])),
    ?assertMatch(
        {ok, _, _, _},
        ircd_websocket:handshake(request(<<"Origin: https://ok\r\n">>), [<<"https://ok">>])
    ),
    ?assertMatch({error, _}, ircd_websocket:handshake(<<"GET / HTTP/1.1\r\n\r\n">>, null)).

masked(Opcode, Fin, Payload) ->
    Mask = <<1, 2, 3, 4>>,
    Masked = list_to_binary([
        B bxor binary:at(Mask, I rem 4)
     || {B, I} <- lists:zip(binary_to_list(Payload), lists:seq(0, byte_size(Payload) - 1))
    ]),
    <<Fin:1, 0:3, Opcode:4, 1:1, (byte_size(Payload)):7, Mask/binary, Masked/binary>>.

decode_and_fragmentation_test() ->
    Two = <<(masked(1, 1, <<"PING a">>))/binary, (masked(2, 1, <<"PING b">>))/binary>>,
    ?assertEqual(
        {ok, [{text, <<"PING a">>}, {binary, <<"PING b">>}], <<>>}, ircd_websocket:decode(Two, 8703)
    ),
    First = masked(1, 0, <<"PRIV">>),
    Last = masked(0, 1, <<"MSG x :y">>),
    %% The unfinished message is kept as one frame and completes on a later read.
    {ok, [], Kept} = ircd_websocket:decode(First, 8703),
    ?assertEqual(
        {ok, [{text, <<"PRIVMSG x :y">>}], <<>>},
        ircd_websocket:decode(<<Kept/binary, Last/binary>>, 8703)
    ),
    ?assertEqual(
        {ok, [{text, <<"PRIVMSG x :y">>}], <<>>},
        ircd_websocket:decode(<<First/binary, Last/binary>>, 8703)
    ),
    Partial = binary:part(Last, 0, 3),
    {ok, [], Kept2} = ircd_websocket:decode(<<First/binary, Partial/binary>>, 8703),
    ?assertEqual(
        {ok, [{text, <<"PRIVMSG x :y">>}], <<>>},
        ircd_websocket:decode(
            <<Kept2/binary, (binary:part(Last, 3, byte_size(Last) - 3))/binary>>, 8703
        )
    ),
    ?assertEqual({error, unmasked_frame}, ircd_websocket:decode(<<16#81, 1, $a>>, 8703)),
    ?assertEqual({error, too_large}, ircd_websocket:decode(masked(2, 1, <<"abcdef">>), 4)).

encode_and_utf8_test() ->
    ?assertEqual(<<16#81, 2, "hi">>, iolist_to_binary(ircd_websocket:encode(text, <<"hi">>))),
    Long = binary:copy(<<"a">>, 300),
    <<16#82, 126, 300:16, Long/binary>> = iolist_to_binary(ircd_websocket:encode(binary, Long)),
    ?assertEqual(<<"a", 16#EF, 16#BF, 16#BD, "b">>, ircd_websocket:utf8_safe(<<"a", 16#ff, "b">>)),
    ?assertEqual(<<"ok">>, ircd_websocket:utf8_safe(<<"ok">>)).

sasl_chunks_test() ->
    ?assertEqual([<<"+">>], ircd_sasl:encode_chunks(<<>>)),
    Exact = binary:copy(<<"a">>, 300),
    ?assertEqual(2, length(ircd_sasl:encode_chunks(Exact))),
    ?assertEqual(
        {more, binary:copy(<<"A">>, 400)}, ircd_sasl:decode_chunk(<<>>, binary:copy(<<"A">>, 400))
    ),
    ?assertEqual({done, <<"hi">>}, ircd_sasl:decode_chunk(<<>>, base64:encode(<<"hi">>))),
    ?assertEqual({done, <<>>}, ircd_sasl:decode_chunk(<<>>, <<"+">>)),
    ?assertEqual({error, too_long}, ircd_sasl:decode_chunk(<<>>, binary:copy(<<"A">>, 401))),
    ?assertMatch({error, unknown_mechanism}, ircd_sasl:start(<<"NOPE">>, #{})).
