-module(briskd_websocket_tests).
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
    {ok, Response, text, <<>>} = briskd_websocket:handshake(request(<<>>), null),
    Bin = iolist_to_binary(Response),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=">>)),
    ?assertEqual(nomatch, binary:match(Bin, <<"Sec-WebSocket-Protocol">>)).

subprotocol_preference_test() ->
    {ok, _, text, _} = briskd_websocket:handshake(
        request(<<"Sec-WebSocket-Protocol: text.ircv3.net, binary.ircv3.net\r\n">>), null
    ),
    {ok, _, binary, _} = briskd_websocket:handshake(
        request(<<"Sec-WebSocket-Protocol: foo, binary.ircv3.net\r\n">>), null
    ).

repeated_protocol_headers_test() ->
    {ok, _, binary, _} = briskd_websocket:handshake(
        request(
            <<"Sec-WebSocket-Protocol: binary.ircv3.net\r\nSec-WebSocket-Protocol: text.ircv3.net\r\n">>
        ),
        null
    ).

origin_and_partial_request_test() ->
    ?assertEqual(more, briskd_websocket:handshake(<<"GET / HTTP/1.1\r\n">>, null)),
    ?assertMatch({error, _}, briskd_websocket:handshake(request(<<>>), [<<"https://ok">>])),
    ?assertMatch(
        {ok, _, _, _},
        briskd_websocket:handshake(request(<<"Origin: https://ok\r\n">>), [<<"https://ok">>])
    ),
    ?assertMatch({error, _}, briskd_websocket:handshake(<<"GET / HTTP/1.1\r\n\r\n">>, null)),
    Oversized = request(<<(binary:copy(<<"X-Pad: aaaaaaaaaaaaaaaa\r\n">>, 400))/binary>>),
    {error, Err431} = briskd_websocket:handshake(Oversized, null),
    ?assertNotEqual(nomatch, binary:match(iolist_to_binary(Err431), <<"431">>)),
    BigKey = iolist_to_binary([
        <<"GET /irc HTTP/1.1\r\nHost: example\r\nUpgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n">>,
        <<"Sec-WebSocket-Key: ">>,
        binary:copy(<<"A">>, 65),
        <<"\r\n\r\n">>
    ]),
    ?assertMatch({error, _}, briskd_websocket:handshake(BigKey, null)).

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
        {ok, [{text, <<"PING a">>}, {binary, <<"PING b">>}], <<>>},
        briskd_websocket:decode(Two, 8703)
    ),
    First = masked(1, 0, <<"PRIV">>),
    Last = masked(0, 1, <<"MSG x :y">>),
    %% The unfinished message is kept as one frame and completes on a later read.
    {ok, [], Kept} = briskd_websocket:decode(First, 8703),
    ?assertEqual(
        {ok, [{text, <<"PRIVMSG x :y">>}], <<>>},
        briskd_websocket:decode(<<Kept/binary, Last/binary>>, 8703)
    ),
    ?assertEqual(
        {ok, [{text, <<"PRIVMSG x :y">>}], <<>>},
        briskd_websocket:decode(<<First/binary, Last/binary>>, 8703)
    ),
    Partial = binary:part(Last, 0, 3),
    {ok, [], Kept2} = briskd_websocket:decode(<<First/binary, Partial/binary>>, 8703),
    ?assertEqual(
        {ok, [{text, <<"PRIVMSG x :y">>}], <<>>},
        briskd_websocket:decode(
            <<Kept2/binary, (binary:part(Last, 3, byte_size(Last) - 3))/binary>>, 8703
        )
    ),
    ?assertEqual({error, unmasked_frame}, briskd_websocket:decode(<<16#81, 1, $a>>, 8703)),
    ?assertEqual({error, too_large}, briskd_websocket:decode(masked(2, 1, <<"abcdef">>), 4)).

encode_and_utf8_test() ->
    ?assertEqual(<<16#81, 2, "hi">>, iolist_to_binary(briskd_websocket:encode(text, <<"hi">>))),
    Long = binary:copy(<<"a">>, 300),
    <<16#82, 126, 300:16, Long/binary>> = iolist_to_binary(briskd_websocket:encode(binary, Long)),
    ?assertEqual(
        <<"a", 16#EF, 16#BF, 16#BD, "b">>, briskd_websocket:utf8_safe(<<"a", 16#ff, "b">>)
    ),
    ?assertEqual(<<"ok">>, briskd_websocket:utf8_safe(<<"ok">>)).

sasl_chunks_test() ->
    ?assertEqual([<<"+">>], briskd_sasl:encode_chunks(<<>>)),
    Exact = binary:copy(<<"a">>, 300),
    ?assertEqual(2, length(briskd_sasl:encode_chunks(Exact))),
    ?assertEqual(
        {more, binary:copy(<<"A">>, 400)}, briskd_sasl:decode_chunk(<<>>, binary:copy(<<"A">>, 400))
    ),
    ?assertEqual({done, <<"hi">>}, briskd_sasl:decode_chunk(<<>>, base64:encode(<<"hi">>))),
    ?assertEqual({done, <<>>}, briskd_sasl:decode_chunk(<<>>, <<"+">>)),
    ?assertEqual({error, too_long}, briskd_sasl:decode_chunk(<<>>, binary:copy(<<"A">>, 401))),
    ?assertMatch({error, unknown_mechanism}, briskd_sasl:start(<<"NOPE">>, #{})),
    {continue, <<>>, Scram} = briskd_sasl:start(<<"SCRAM-SHA-256">>, #{}),
    ?assertEqual({error, failed}, briskd_sasl:step(Scram, <<"n,,m=ext,n=alice,r=nonce">>)).
