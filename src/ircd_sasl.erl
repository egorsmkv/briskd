-module(ircd_sasl).
-export([start/2, step/2, decode_chunk/2, encode_chunks/1]).
-include("ircd_account.hrl").

-moduledoc """
SASL mechanisms and `AUTHENTICATE` payload framing for IRCv3
[SASL 3.1 / 3.2](https://ircv3.net/specs/extensions/sasl-3.2).

Mechanisms: PLAIN (RFC 4616), EXTERNAL (RFC 4422 appendix A, matched against
the client certificate's SHA-256 fingerprint), and SCRAM-SHA-256 (RFC 5802,
RFC 7677, without channel binding). An authorization identity, when given,
must equal the authenticated account under RFC 1459 folding.

The module holds no process state: `m:ircd_state_v3` keeps the `t:state/0`
in `m:ircd_conn` between steps. Apart from account lookups through
`m:ircd_account` (read-only Mnesia access, in the `m:ircd_state` process),
the functions are pure. Payloads travel base64-encoded in 400-byte
`AUTHENTICATE` chunks; a reassembled response is capped at 8192 encoded
bytes. Passwords and proofs are never logged or kept after the step.
""".

-define(CHUNK, 400).
%% Upper bound on one reassembled client response, before base64 decoding.
-define(MAX_RESPONSE, 8192).

-doc """
Progress of one SASL exchange: the mechanism and, for SCRAM, the session
data between the server-first and server-final messages.
""".
-type state() ::
    plain
    | {external, undefined | binary()}
    | {scram_first, undefined}
    | {scram_final, map()}
    | {scram_done, binary()}.
-export_type([state/0]).

-doc """
Begin a mechanism named case-insensitively (`PLAIN`, `EXTERNAL`,
`SCRAM-SHA-256`).

`Context` may carry `certfp`, the client certificate fingerprint used by
EXTERNAL. Every mechanism starts with the empty challenge `<<>>`, sent as
`AUTHENTICATE +`.
""".
-spec start(binary(), map()) -> {continue, binary(), state()} | {error, unknown_mechanism}.
start(Mechanism, Context) ->
    case ircd_wire:upper(Mechanism) of
        <<"PLAIN">> -> {continue, <<>>, plain};
        <<"EXTERNAL">> -> {continue, <<>>, {external, maps:get(certfp, Context, undefined)}};
        <<"SCRAM-SHA-256">> -> {continue, <<>>, {scram_first, undefined}};
        _ -> {error, unknown_mechanism}
    end.

-doc """
Apply one decoded client response to `State`.

Returns `{continue, Challenge, Next}` to send another challenge,
`{success, AccountName}` with the stored spelling of the account,
`{check_password, AccountName, Password}` for PLAIN once the message is
well formed (the caller verifies the password, see
`ircd_account:check_password/2`; this keeps the module free of the costly
PBKDF2 step), or
`{error, failed}` for a bad credential, malformed message, or mismatched
authorization identity. SCRAM ends with the server signature
(`v=...`) as a challenge, and succeeds on the client's empty reply.
""".
-spec step(state(), binary()) ->
    {continue, binary(), state()}
    | {success, binary()}
    | {check_password, binary(), binary()}
    | {error, failed}.
step(plain, Data) ->
    case binary:split(Data, <<0>>, [global]) of
        [Authz, Authc, Password] when Authc =/= <<>> ->
            case authz_ok(Authz, Authc) of
                %% The PBKDF2 check is the caller's: `ircd_state` runs it in
                %% a worker so it never blocks the state process.
                true -> {check_password, Authc, Password};
                false -> {error, failed}
            end;
        _ ->
            {error, failed}
    end;
step({external, undefined}, _Data) ->
    {error, failed};
step({external, Fingerprint}, Authz) ->
    case ircd_account:by_certfp(Fingerprint) of
        {ok, #account{name = Name}} ->
            case authz_ok(Authz, Name) of
                true -> {success, Name};
                false -> {error, failed}
            end;
        error ->
            {error, failed}
    end;
step({scram_first, undefined}, ClientFirst) ->
    scram_first(ClientFirst);
step({scram_final, Session}, ClientFinal) ->
    scram_final(Session, ClientFinal);
step({scram_done, Name}, <<>>) ->
    {success, Name};
step(_State, _Data) ->
    {error, failed}.

-doc """
Add one `AUTHENTICATE` parameter to the pending base64 response `Buffer`.

`+` alone is an empty chunk and ends the response. A chunk of exactly 400
bytes means more follows (`{more, Buffer}`); a shorter one ends it
(`{done, Decoded}`). Errors: `too_long` for a chunk over 400 bytes (905
ERR_SASLTOOLONG), `overflow` when the response would exceed 8192 bytes, and
`invalid` for bad base64 (both 904).
""".
-spec decode_chunk(binary(), binary()) ->
    {more, binary()} | {done, binary()} | {error, too_long | overflow | invalid}.
decode_chunk(Buffer, <<"+">>) ->
    finish(Buffer);
decode_chunk(Buffer, Chunk) when byte_size(Chunk) > ?CHUNK ->
    _ = Buffer,
    {error, too_long};
decode_chunk(Buffer, Chunk) when byte_size(Buffer) + byte_size(Chunk) > ?MAX_RESPONSE ->
    %% A correctly chunked but oversized response is a failed authentication
    %% (904); only a single chunk over 400 bytes is ERR_SASLTOOLONG (905).
    {error, overflow};
decode_chunk(Buffer, Chunk) when byte_size(Chunk) =:= ?CHUNK ->
    {more, <<Buffer/binary, Chunk/binary>>};
decode_chunk(Buffer, Chunk) ->
    finish(<<Buffer/binary, Chunk/binary>>).

finish(Encoded) ->
    try base64:decode(Encoded) of
        Decoded -> {done, Decoded}
    catch
        error:_ -> {error, invalid}
    end.

-doc """
Base64-encode an outgoing challenge and split it into `AUTHENTICATE`
parameters of at most 400 bytes. An empty challenge, or one whose encoding
ends exactly on a 400-byte boundary, ends with `+`.
""".
-spec encode_chunks(binary()) -> [binary()].
encode_chunks(<<>>) ->
    [<<"+">>];
encode_chunks(Data) ->
    split_chunks(base64:encode(Data)).

split_chunks(Encoded) when byte_size(Encoded) < ?CHUNK ->
    [Encoded];
split_chunks(Encoded) when byte_size(Encoded) =:= ?CHUNK ->
    [Encoded, <<"+">>];
split_chunks(<<Chunk:?CHUNK/binary, Rest/binary>>) ->
    [Chunk | split_chunks(Rest)].

authz_ok(<<>>, _Authc) -> true;
authz_ok(Authz, Authc) -> ircd_wire:fold(Authz) =:= ircd_wire:fold(Authc).

%% client-first-message = gs2-header client-first-message-bare
%% gs2-header = "n," / "y," then [ "a=" authzid ] ","
scram_first(ClientFirst) ->
    case binary:split(ClientFirst, <<",">>, [global]) of
        [Flag, AuthzPart | BareParts] when (Flag =:= <<"n">> orelse Flag =:= <<"y">>) ->
            Bare = binary:join(BareParts, <<",">>),
            Attrs = attributes(BareParts),
            case
                {
                    maps:is_key($m, Attrs),
                    authzid(AuthzPart),
                    maps:find($n, Attrs),
                    maps:find($r, Attrs)
                }
            of
                {false, {ok, Authz}, {ok, RawUser}, {ok, ClientNonce}} when ClientNonce =/= <<>> ->
                    User = scram_unescape(RawUser),
                    case authz_ok(Authz, User) andalso ircd_account:scram_credentials(User) of
                        {ok, Credentials} ->
                            ServerNonce = base64:encode(crypto:strong_rand_bytes(18)),
                            Nonce = <<ClientNonce/binary, ServerNonce/binary>>,
                            ServerFirst = iolist_to_binary([
                                <<"r=">>,
                                Nonce,
                                <<",s=">>,
                                base64:encode(maps:get(salt, Credentials)),
                                <<",i=">>,
                                integer_to_binary(maps:get(iterations, Credentials))
                            ]),
                            Gs2 = <<Flag/binary, ",", AuthzPart/binary, ",">>,
                            {continue, ServerFirst,
                                {scram_final, Credentials#{
                                    nonce => Nonce,
                                    gs2 => Gs2,
                                    first_bare => Bare,
                                    server_first => ServerFirst
                                }}};
                        _ ->
                            {error, failed}
                    end;
                _ ->
                    {error, failed}
            end;
        _ ->
            {error, failed}
    end.

scram_final(Session, ClientFinal) ->
    Parts = binary:split(ClientFinal, <<",">>, [global]),
    case lists:reverse(Parts) of
        [<<"p=", Proof64/binary>> | RevWithout] ->
            Without = binary:join(lists:reverse(RevWithout), <<",">>),
            Attrs = attributes(lists:reverse(RevWithout)),
            #{
                nonce := Nonce,
                gs2 := Gs2,
                first_bare := Bare,
                server_first := ServerFirst,
                stored_key := Stored,
                server_key := ServerKey,
                name := Name
            } = Session,
            Binding = base64:encode(Gs2),
            case
                {
                    maps:is_key($m, Attrs),
                    maps:find($c, Attrs),
                    maps:find($r, Attrs),
                    decode64(Proof64)
                }
            of
                {false, {ok, Binding}, {ok, Nonce}, {ok, Proof}} when byte_size(Proof) =:= 32 ->
                    AuthMessage = <<Bare/binary, ",", ServerFirst/binary, ",", Without/binary>>,
                    Signature = crypto:mac(hmac, sha256, Stored, AuthMessage),
                    ClientKey = crypto:exor(Proof, Signature),
                    case crypto:hash_equals(crypto:hash(sha256, ClientKey), Stored) of
                        true ->
                            ServerSignature = crypto:mac(hmac, sha256, ServerKey, AuthMessage),
                            {continue, <<"v=", (base64:encode(ServerSignature))/binary>>,
                                {scram_done, Name}};
                        false ->
                            {error, failed}
                    end;
                _ ->
                    {error, failed}
            end;
        _ ->
            {error, failed}
    end.

authzid(<<>>) -> {ok, <<>>};
authzid(<<"a=", Authz/binary>>) -> {ok, scram_unescape(Authz)};
authzid(_) -> error.

attributes(Parts) ->
    maps:from_list([{Key, Value} || <<Key, $=, Value/binary>> <- Parts]).

scram_unescape(Value) ->
    binary:replace(binary:replace(Value, <<"=2C">>, <<",">>, [global]), <<"=3D">>, <<"=">>, [
        global
    ]).

decode64(Value) ->
    try
        {ok, base64:decode(Value)}
    catch
        error:_ -> error
    end.
