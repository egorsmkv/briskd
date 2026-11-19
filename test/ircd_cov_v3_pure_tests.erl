-module(ircd_cov_v3_pure_tests).
-include_lib("eunit/include/eunit.hrl").

%% Pure-function coverage for the IRCv3 WebSocket transport (RFC 6455
%% handshake and framing) and the SASL chunk codec (IRCv3 SASL 3.1/3.2).

%%% WebSocket handshake

request(Extra) ->
    request(<<"GET /irc HTTP/1.1">>, Extra).

request(RequestLine, Extra) ->
    iolist_to_binary([
        RequestLine,
        <<"\r\nHost: example\r\nUpgrade: WebSocket\r\n">>,
        <<"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n">>,
        <<"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n">>,
        Extra,
        <<"\r\n">>
    ]).

status(Response) ->
    [Line | _] = binary:split(iolist_to_binary(Response), <<"\r\n">>),
    Line.

handshake_rejections_test() ->
    %% Not GET.
    {error, R1} = ircd_websocket:handshake(request(<<"POST /irc HTTP/1.1">>, <<>>), null),
    ?assertEqual(<<"HTTP/1.1 400 Bad Request">>, status(R1)),
    %% Missing Upgrade header.
    NoUpgrade = <<"GET / HTTP/1.1\r\nConnection: Upgrade\r\nSec-WebSocket-Key: a\r\n\r\n">>,
    {error, R2} = ircd_websocket:handshake(NoUpgrade, null),
    ?assertEqual(<<"HTTP/1.1 400 Bad Request">>, status(R2)),
    %% Missing key.
    NoKey =
        <<"GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
            "Sec-WebSocket-Version: 13\r\n\r\n">>,
    {error, R3} = ircd_websocket:handshake(NoKey, null),
    ?assertEqual(<<"HTTP/1.1 400 Bad Request">>, status(R3)),
    %% Wrong version: 426 with the supported version.
    BadVersion =
        <<"GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
            "Sec-WebSocket-Key: abc\r\nSec-WebSocket-Version: 8\r\n\r\n">>,
    {error, R4} = ircd_websocket:handshake(BadVersion, null),
    Bin4 = iolist_to_binary(R4),
    ?assertEqual(<<"HTTP/1.1 426 Upgrade Required">>, status(R4)),
    ?assertNotEqual(nomatch, binary:match(Bin4, <<"Sec-WebSocket-Version: 13">>)),
    %% Origin not in the allow list.
    {error, R5} = ircd_websocket:handshake(
        request(<<"Origin: https://evil\r\n">>), [<<"https://ok">>]
    ),
    ?assertEqual(<<"HTTP/1.1 403 Forbidden">>, status(R5)),
    %% Oversized header without a terminator.
    Huge = <<"GET / HTTP/1.1\r\nX: ", (binary:copy(<<"a">>, 9000))/binary>>,
    {error, R6} = ircd_websocket:handshake(Huge, null),
    ?assertEqual(<<"HTTP/1.1 431 Request Header Fields Too Large">>, status(R6)).

handshake_subprotocols_and_rest_test() ->
    %% Text subprotocol is echoed; bytes after the request are returned.
    Req = request(<<"Sec-WebSocket-Protocol: text.ircv3.net\r\n">>),
    {ok, Resp, text, <<"extra">>} = ircd_websocket:handshake(<<Req/binary, "extra">>, null),
    Bin = iolist_to_binary(Resp),
    ?assertEqual(<<"HTTP/1.1 101 Switching Protocols">>, status(Resp)),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"Sec-WebSocket-Protocol: text.ircv3.net">>)),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"Sec-WebSocket-Accept: ">>)),
    %% Unsupported subprotocols only: text mode, no protocol header.
    {ok, Resp2, text, <<>>} = ircd_websocket:handshake(
        request(<<"Sec-WebSocket-Protocol: chat, superchat\r\n">>), null
    ),
    ?assertEqual(
        nomatch, binary:match(iolist_to_binary(Resp2), <<"Sec-WebSocket-Protocol">>)
    ),
    %% Binary first.
    {ok, Resp3, binary, <<>>} = ircd_websocket:handshake(
        request(<<"Sec-WebSocket-Protocol: binary.ircv3.net, text.ircv3.net\r\n">>), null
    ),
    ?assertNotEqual(
        nomatch, binary:match(iolist_to_binary(Resp3), <<"Protocol: binary.ircv3.net">>)
    ),
    %% Header lines without a colon are ignored.
    {ok, _, text, <<>>} = ircd_websocket:handshake(request(<<"garbage line\r\n">>), null).

%%% WebSocket framing

mask_bytes(Payload, Mask) ->
    Masked = [
        B bxor binary:at(Mask, I rem 4)
     || {B, I} <- lists:zip(binary_to_list(Payload), lists:seq(0, byte_size(Payload) - 1))
    ],
    list_to_binary(Masked).

%% A masked client frame with the right length encoding.
frame(Opcode, Fin, Payload) ->
    Mask = <<16#37, 16#fa, 16#21, 16#3d>>,
    Len = byte_size(Payload),
    LenBits =
        if
            Len < 126 -> <<Len:7>>;
            Len < 65536 -> <<126:7, Len:16>>;
            true -> <<127:7, Len:64>>
        end,
    <<Fin:1, 0:3, Opcode:4, 1:1, LenBits/bitstring, Mask/binary,
        (mask_bytes(Payload, Mask))/binary>>.

control_frames_test() ->
    Frames = <<
        (frame(9, 1, <<"pi">>))/binary,
        (frame(10, 1, <<"po">>))/binary,
        (frame(8, 1, <<3, 232, "bye">>))/binary,
        (frame(11, 1, <<"x">>))/binary
    >>,
    ?assertEqual(
        {ok,
            [
                {ping, <<"pi">>},
                {pong, <<"po">>},
                {close, <<3, 232, "bye">>},
                {close, <<"x">>}
            ],
            <<>>},
        ircd_websocket:decode(Frames, 1000)
    ),
    %% Control frames over 125 bytes are rejected.
    ?assertEqual(
        {error, control_too_large},
        ircd_websocket:decode(frame(9, 1, binary:copy(<<"p">>, 126)), 1000)
    ).

extended_lengths_test() ->
    Medium = binary:copy(<<"m">>, 300),
    ?assertEqual(
        {ok, [{binary, Medium}], <<>>}, ircd_websocket:decode(frame(2, 1, Medium), 1000)
    ),
    Large = binary:copy(<<"L">>, 70000),
    ?assertEqual({ok, [{text, Large}], <<>>}, ircd_websocket:decode(frame(1, 1, Large), 100000)),
    ?assertEqual({error, too_large}, ircd_websocket:decode(frame(1, 1, Large), 1000)),
    %% Extended length not yet received.
    ?assertEqual({ok, [], <<16#81, 16#FE, 1>>}, ircd_websocket:decode(<<16#81, 16#FE, 1>>, 1000)),
    ?assertEqual({ok, [], <<16#81, 16#FF, 0>>}, ircd_websocket:decode(<<16#81, 16#FF, 0>>, 1000)),
    %% Lone first byte.
    ?assertEqual({ok, [], <<16#81>>}, ircd_websocket:decode(<<16#81>>, 1000)),
    ?assertEqual({ok, [], <<>>}, ircd_websocket:decode(<<>>, 1000)).

frame_errors_test() ->
    ?assertEqual({error, reserved_bits}, ircd_websocket:decode(<<16#C1, 16#80, 0, 0, 0, 0>>, 100)),
    ?assertEqual({error, bad_opcode}, ircd_websocket:decode(frame(3, 1, <<"x">>), 100)),
    ?assertEqual(
        {error, unexpected_continuation}, ircd_websocket:decode(frame(0, 1, <<"x">>), 100)
    ),
    %% A new data frame while a fragmented message is open.
    Interleaved = <<(frame(1, 0, <<"a">>))/binary, (frame(2, 1, <<"b">>))/binary>>,
    ?assertEqual({error, interleaved_message}, ircd_websocket:decode(Interleaved, 100)),
    %% Fragments whose joined size exceeds the limit (final and middle).
    TooBig = <<(frame(1, 0, <<"abc">>))/binary, (frame(0, 1, <<"def">>))/binary>>,
    ?assertEqual({error, too_large}, ircd_websocket:decode(TooBig, 5)),
    TooBigMiddle = <<(frame(2, 0, <<"abc">>))/binary, (frame(0, 0, <<"def">>))/binary>>,
    ?assertEqual({error, too_large}, ircd_websocket:decode(TooBigMiddle, 5)).

fragmentation_with_control_test() ->
    %% binary message in three fragments with a ping between them.
    Msg = <<
        (frame(2, 0, <<"PRIV">>))/binary,
        (frame(9, 1, <<"hb">>))/binary,
        (frame(0, 0, <<"MSG ">>))/binary,
        (frame(0, 1, <<"x :y">>))/binary
    >>,
    ?assertEqual(
        {ok, [{binary, <<"PRIVMSG x :y">>}], <<>>}, ircd_websocket:decode(Msg, 100)
    ),
    %% Incomplete fragmented message keeps the whole message buffered.
    Open = <<(frame(2, 0, <<"ab">>))/binary, (frame(0, 0, <<"cd">>))/binary>>,
    ?assertEqual({ok, [], Open}, ircd_websocket:decode(Open, 100)),
    %% Odd payload lengths unmask the tail correctly.
    lists:foreach(
        fun(N) ->
            P = binary:copy(<<"z">>, N),
            ?assertEqual({ok, [{text, P}], <<>>}, ircd_websocket:decode(frame(1, 1, P), 100))
        end,
        lists:seq(0, 9)
    ).

encode_frames_test() ->
    ?assertEqual(<<16#88, 0>>, iolist_to_binary(ircd_websocket:encode(close, <<>>))),
    ?assertEqual(<<16#89, 1, "a">>, iolist_to_binary(ircd_websocket:encode(ping, [<<"a">>]))),
    ?assertEqual(<<16#8A, 1, "b">>, iolist_to_binary(ircd_websocket:encode(pong, "b"))),
    Big = binary:copy(<<"q">>, 70000),
    <<16#81, 127, 70000:64, Big/binary>> = iolist_to_binary(ircd_websocket:encode(text, Big)),
    %% Truncated multi-byte sequence at the end and in the middle.
    ?assertEqual(
        <<"a", 16#EF, 16#BF, 16#BD>>, ircd_websocket:utf8_safe(<<"a", 16#C3>>)
    ),
    ?assertEqual(
        <<16#EF, 16#BF, 16#BD, 16#EF, 16#BF, 16#BD, "ok">>,
        ircd_websocket:utf8_safe(<<16#80, 16#FF, "ok">>)
    ),
    ?assertEqual(<<"é"/utf8>>, ircd_websocket:utf8_safe(<<"é"/utf8>>)).

%%% SASL codec

sasl_decode_chunk_test() ->
    A400 = binary:copy(<<"A">>, 400),
    %% 400 then a shorter chunk completes the response.
    {more, Buf} = ircd_sasl:decode_chunk(<<>>, A400),
    ?assertMatch({done, _}, ircd_sasl:decode_chunk(Buf, <<"QQ==">>)),
    %% 400 then "+" ends exactly at the chunk boundary.
    {done, Decoded} = ircd_sasl:decode_chunk(Buf, <<"+">>),
    ?assertEqual(300, byte_size(Decoded)),
    %% Invalid base64.
    ?assertEqual({error, invalid}, ircd_sasl:decode_chunk(<<>>, <<"!!!">>)),
    %% A correctly chunked response that grows over 8192 bytes.
    Full = binary:copy(<<"A">>, 8000),
    ?assertEqual({error, overflow}, ircd_sasl:decode_chunk(Full, A400)).

sasl_encode_chunks_test() ->
    %% 600 bytes encode to 800 base64 chars: two full chunks and "+".
    Chunks = ircd_sasl:encode_chunks(binary:copy(<<"x">>, 600)),
    ?assertEqual(3, length(Chunks)),
    ?assertEqual(<<"+">>, lists:last(Chunks)),
    %% 400 bytes encode to 536 chars: one full chunk and a remainder.
    [First, Second] = ircd_sasl:encode_chunks(binary:copy(<<"x">>, 400)),
    ?assertEqual(400, byte_size(First)),
    ?assertEqual(136, byte_size(Second)),
    ?assertEqual([base64:encode(<<"hi">>)], ircd_sasl:encode_chunks(<<"hi">>)).

sasl_start_and_trivial_steps_test() ->
    ?assertEqual({continue, <<>>, plain}, ircd_sasl:start(<<"plain">>, #{})),
    ?assertEqual(
        {continue, <<>>, {external, <<"ab">>}},
        ircd_sasl:start(<<"EXTERNAL">>, #{certfp => <<"ab">>})
    ),
    ?assertEqual(
        {continue, <<>>, {scram_first, undefined}}, ircd_sasl:start(<<"scram-sha-256">>, #{})
    ),
    %% Steps that fail before any account lookup.
    ?assertEqual({error, failed}, ircd_sasl:step(plain, <<"no-nul-separators">>)),
    ?assertEqual({error, failed}, ircd_sasl:step(plain, <<0, 0, "pw">>)),
    ?assertEqual({error, failed}, ircd_sasl:step({external, undefined}, <<>>)),
    ?assertEqual({error, failed}, ircd_sasl:step({scram_done, <<"n">>}, <<"junk">>)),
    ?assertEqual({success, <<"n">>}, ircd_sasl:step({scram_done, <<"n">>}, <<>>)),
    ?assertEqual({error, failed}, ircd_sasl:step(bogus, <<>>)),
    %% Malformed SCRAM client-first messages.
    ?assertEqual({error, failed}, ircd_sasl:step({scram_first, undefined}, <<"p=x,,n=a,r=b">>)),
    ?assertEqual({error, failed}, ircd_sasl:step({scram_first, undefined}, <<"n">>)),
    ?assertEqual({error, failed}, ircd_sasl:step({scram_first, undefined}, <<"n,x=y,n=a,r=b">>)),
    ?assertEqual({error, failed}, ircd_sasl:step({scram_first, undefined}, <<"n,,n=a">>)),
    ?assertEqual({error, failed}, ircd_sasl:step({scram_first, undefined}, <<"n,,n=a,r=">>)).

sasl_plain_authz_mismatch_test() ->
    ?assertEqual({error, failed}, ircd_sasl:step(plain, <<"other", 0, "user", 0, "pw">>)),
    ?assertEqual(
        {error, failed}, ircd_sasl:step({scram_first, undefined}, <<"n,a=other,n=user,r=abc">>)
    ).

%% A SCRAM server session as scram_first/1 would build it, for a known password.
scram_session(Password) ->
    Salt = <<"saltsaltsaltsalt">>,
    {Stored, ServerKey} = ircd_account:verifier(Password, {Salt, 4096}),
    Bare = <<"n=user,r=cnonce">>,
    Nonce = <<"cnoncesnonce">>,
    ServerFirst = <<"r=", Nonce/binary, ",s=", (base64:encode(Salt))/binary, ",i=4096">>,
    {
        #{
            name => <<"User">>,
            salt => Salt,
            iterations => 4096,
            stored_key => Stored,
            server_key => ServerKey,
            nonce => Nonce,
            gs2 => <<"n,,">>,
            first_bare => Bare,
            server_first => ServerFirst
        },
        Salt
    }.

scram_final_test() ->
    {Session, Salt} = scram_session(<<"correct horse">>),
    #{first_bare := Bare, server_first := ServerFirst, nonce := Nonce} = Session,
    Without = <<"c=biws,r=", Nonce/binary>>,
    Auth = <<Bare/binary, ",", ServerFirst/binary, ",", Without/binary>>,
    Proof = fun(Password) ->
        Salted = crypto:pbkdf2_hmac(sha256, Password, Salt, 4096, 32),
        ClientKey = crypto:mac(hmac, sha256, Salted, <<"Client Key">>),
        StoredKey = crypto:hash(sha256, ClientKey),
        base64:encode(crypto:exor(ClientKey, crypto:mac(hmac, sha256, StoredKey, Auth)))
    end,
    State = {scram_final, Session},
    {continue, <<"v=", Sig/binary>>, {scram_done, <<"User">>}} =
        ircd_sasl:step(State, <<Without/binary, ",p=", (Proof(<<"correct horse">>))/binary>>),
    ?assertEqual(32, byte_size(base64:decode(Sig))),
    %% Wrong password.
    ?assertEqual(
        {error, failed},
        ircd_sasl:step(State, <<Without/binary, ",p=", (Proof(<<"wrong">>))/binary>>)
    ),
    %% Wrong channel binding, wrong nonce, short proof, bad base64, no proof.
    Good = Proof(<<"correct horse">>),
    ?assertEqual(
        {error, failed},
        ircd_sasl:step(State, <<"c=eSws,r=", Nonce/binary, ",p=", Good/binary>>)
    ),
    ?assertEqual(
        {error, failed}, ircd_sasl:step(State, <<"c=biws,r=other,p=", Good/binary>>)
    ),
    ?assertEqual(
        {error, failed},
        ircd_sasl:step(State, <<Without/binary, ",p=", (base64:encode(<<"short">>))/binary>>)
    ),
    ?assertEqual({error, failed}, ircd_sasl:step(State, <<Without/binary, ",p=!!!">>)),
    ?assertEqual({error, failed}, ircd_sasl:step(State, Without)).
