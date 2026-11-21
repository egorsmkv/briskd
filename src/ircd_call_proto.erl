-module(ircd_call_proto).
-moduledoc """
Pure helpers for user-to-user voice calls (`m:ircd_calls`): validation of
`CALL` parameters, SDP transport over IRC lines, and rtpengine NG messages.

SDP does not fit one IRC line (RFC 1459: 512 octets) and contains CRLF, so
it travels base64-encoded in numbered chunks:
`CALL OFFER <nick> <token> <part> <total> :<chunk>`. A chunk is at most
`?CHUNK_BYTES` base64 characters, a description at most `?MAX_PARTS` chunks
and `?MAX_SDP_BYTES` decoded bytes (a browser's video offer lists many
codecs). A description has one or more audio media sections and, when video
calls are allowed, at most one video section; no other media.

NG messages are `<cookie> <bencoded dictionary>` UDP datagrams. `offer/3` and
`answer/4` carry the flags that make rtpengine the ICE and DTLS-SRTP
endpoint on both legs (WebRTC to WebRTC): `ICE=force`, `UDP/TLS/RTP/SAVPF`,
`rtcp-mux` required, SDES off, and the origin replaced; rtpengine also
substitutes its own connection address and candidates, so neither browser
learns the other's address. The DTLS role is left to rtpengine: it starts
ICE and DTLS with the caller as soon as it sees the offer, so forcing
`passive` would make both ends act as DTLS client on the caller's leg.
""".
-export([
    valid_token/1,
    parse_part/2,
    valid_chunk/1,
    decode_sdp/1,
    decode_sdp/2,
    has_video/1,
    chunks/1,
    offer/3,
    answer/4,
    delete/1,
    frame/2,
    parse_reply/1,
    reason/1
]).

-define(CHUNK_BYTES, 400).
%% 24 KiB of SDP as base64 in 400-character chunks: 82 chunks.
-define(MAX_PARTS, 82).
-define(MAX_SDP_BYTES, 24576).

-doc "A call token: 8 to 32 ASCII letters and digits, chosen by the caller.".
-spec valid_token(binary()) -> boolean().
valid_token(Token) when is_binary(Token), byte_size(Token) >= 8, byte_size(Token) =< 32 ->
    lists:all(fun alnum/1, binary_to_list(Token));
valid_token(_) ->
    false.

alnum(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9).

-doc """
Parse `<part> <total>`: decimal integers with `1 =< Part =< Total =< 82`
(both bounds inclusive).
""".
-spec parse_part(binary(), binary()) -> {ok, pos_integer(), pos_integer()} | error.
parse_part(PartBin, TotalBin) ->
    try {binary_to_integer(PartBin), binary_to_integer(TotalBin)} of
        {Part, Total} when is_integer(Total, 1, ?MAX_PARTS), is_integer(Part, 1, Total) ->
            {ok, Part, Total};
        _ ->
            error
    catch
        error:badarg -> error
    end.

-doc "A base64 chunk of at most 400 characters from the base64 alphabet.".
-spec valid_chunk(binary()) -> boolean().
valid_chunk(Chunk) when byte_size(Chunk) >= 1, byte_size(Chunk) =< ?CHUNK_BYTES ->
    lists:all(
        fun(C) -> alnum(C) orelse C =:= $+ orelse C =:= $/ orelse C =:= $= end,
        binary_to_list(Chunk)
    );
valid_chunk(_) ->
    false.

-doc "Same as `decode_sdp(Base64, false)`: audio only.".
-spec decode_sdp(binary()) -> {ok, binary()} | {error, atom()}.
decode_sdp(Base64) ->
    decode_sdp(Base64, false).

-doc """
Decode the joined chunks and check the description: valid base64, at most
24 KiB, starting with `v=0`, lines ending in CRLF or LF with no other CR
or NUL, at least one `m=audio` section, and no other media type except, when
`Video` is true, one `m=video` section. Errors: `invalid_base64`,
`too_large`, `invalid_sdp`, `not_audio` (no audio, or a media type that is
not allowed), and `too_many_video`.
""".
-spec decode_sdp(binary(), boolean()) -> {ok, binary()} | {error, atom()}.
decode_sdp(Base64, Video) ->
    try base64:decode(Base64) of
        Sdp when byte_size(Sdp) > ?MAX_SDP_BYTES ->
            {error, too_large};
        <<"v=0", _/binary>> = Sdp ->
            Lines = binary:split(Sdp, [<<"\r\n">>, <<"\n">>], [global]),
            %% A NUL or a CR that does not end a line could hide an `m=` line
            %% from this check while another parser still sees it.
            case lists:any(fun(L) -> binary:match(L, [<<"\r">>, <<0>>]) =/= nomatch end, Lines) of
                true -> {error, invalid_sdp};
                false -> check_media(Sdp, media(Sdp), Video)
            end;
        _ ->
            {error, invalid_sdp}
    catch
        error:_ -> {error, invalid_base64}
    end.

%% The `m=` lines of a description, without the `m=`.
media(Sdp) ->
    [M || <<"m=", M/binary>> <- binary:split(Sdp, [<<"\r\n">>, <<"\n">>], [global])].

check_media(Sdp, Media, Video) ->
    Audio = [M || <<"audio ", _/binary>> = M <- Media],
    Videos = [M || <<"video ", _/binary>> = M <- Media],
    Other = length(Media) - length(Audio) - length(Videos),
    if
        Audio =:= []; Other > 0 -> {error, not_audio};
        Videos =/= [], not Video -> {error, not_audio};
        length(Videos) > 1 -> {error, too_many_video};
        true -> {ok, Sdp}
    end.

-doc "Whether a description has a video media section (a video call).".
-spec has_video(binary()) -> boolean().
has_video(Sdp) ->
    lists:any(fun(M) -> binary:part(M, 0, min(6, byte_size(M))) =:= <<"video ">> end, media(Sdp)).

-doc "Base64-encode `Sdp` and split it into chunks of at most 400 characters.".
-spec chunks(binary()) -> [binary()].
chunks(Sdp) ->
    split(base64:encode(Sdp), []).

split(Bin, Acc) when byte_size(Bin) =< ?CHUNK_BYTES ->
    lists:reverse([Bin | Acc]);
split(Bin, Acc) ->
    <<Chunk:?CHUNK_BYTES/binary, Rest/binary>> = Bin,
    split(Rest, [Chunk | Acc]).

webrtc_flags() ->
    #{
        'ICE' => force,
        'transport-protocol' => <<"UDP/TLS/RTP/SAVPF">>,
        'rtcp-mux' => [require],
        'SDES' => [off],
        replace => [origin],
        flags => ['generate-mid']
    }.

-doc "NG `offer` for the caller's description.".
-spec offer(binary(), binary(), binary()) -> map().
offer(CallId, FromTag, Sdp) ->
    (webrtc_flags())#{command => offer, 'call-id' => CallId, 'from-tag' => FromTag, sdp => Sdp}.

-doc "NG `answer` for the callee's description.".
-spec answer(binary(), binary(), binary(), binary()) -> map().
answer(CallId, FromTag, ToTag, Sdp) ->
    (webrtc_flags())#{
        command => answer,
        'call-id' => CallId,
        'from-tag' => FromTag,
        'to-tag' => ToTag,
        sdp => Sdp
    }.

-doc "NG `delete` for a whole call.".
-spec delete(binary()) -> map().
delete(CallId) ->
    #{command => delete, 'call-id' => CallId}.

-doc "Frame an NG request: the cookie, a space, and the bencoded dictionary.".
-spec frame(binary(), map()) -> iolist().
frame(Cookie, Message) ->
    [Cookie, $\s, ircd_bencode:encode(Message)].

-doc """
Parse an NG reply datagram. Returns `{ok, Cookie, {ok, Sdp | undefined}}` for
`result: ok` (or `pong`), `{ok, Cookie, {error, Reason}}` for an error reply,
and `error` for a datagram that is not an NG reply.
""".
-spec parse_reply(binary()) ->
    {ok, binary(), {ok, binary() | undefined} | {error, binary()}} | error.
parse_reply(Packet) ->
    case binary:split(Packet, <<" ">>) of
        [Cookie, Body] when byte_size(Cookie) > 0, byte_size(Cookie) =< 64 ->
            case ircd_bencode:decode(Body) of
                {ok, #{<<"result">> := Result} = Reply} when
                    Result =:= <<"ok">>; Result =:= <<"pong">>
                ->
                    Sdp =
                        case maps:get(<<"sdp">>, Reply, undefined) of
                            S when is_binary(S) -> S;
                            _ -> undefined
                        end,
                    {ok, Cookie, {ok, Sdp}};
                {ok, #{<<"result">> := _} = Reply} ->
                    Why =
                        case maps:get(<<"error-reason">>, Reply, <<"error">>) of
                            W when is_binary(W) -> binary:part(W, 0, min(byte_size(W), 120));
                            _ -> <<"error">>
                        end,
                    {ok, Cookie, {error, Why}};
                _ ->
                    error
            end;
        _ ->
            error
    end.

-doc """
Normalize a client-supplied `REJECT`/`HANGUP` reason to a short token:
lowercase letters, digits, and `-`, at most 32 bytes; anything else becomes
`<<"normal">>`.
""".
-spec reason(binary() | none) -> binary().
reason(Reason) when is_binary(Reason), byte_size(Reason) >= 1, byte_size(Reason) =< 32 ->
    case
        lists:all(
            fun(C) ->
                (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9) orelse C =:= $-
            end,
            binary_to_list(Reason)
        )
    of
        true -> Reason;
        false -> <<"normal">>
    end;
reason(_) ->
    <<"normal">>.
