-module(ircd_altcha).
-moduledoc """
Server-side [ALTCHA](https://altcha.org/) SHA-256 challenge generation and
verification for the public WebUI `/signup` and `/verify` pages.

Implements the standard ALTCHA v1/v2 challenge-response format using OTP's
built-in `crypto` module:

- `create_challenge/0` generates a signed SHA-256 challenge JSON map with a
  5-minute expiration embedded in `salt` (`<random-hex>?expires=<unix>`).
- `verify_payload/1` validates a base64-encoded JSON payload submitted by the
  browser: checks algorithm, HMAC-SHA-256 signature (constant-time),
  expiration, SHA-256 digest (constant-time), and single-use replay protection
  via a bounded ETS table (`ircd_altcha_used`).

`init/0` is called by `m:ircd_webui` on startup to create the replay ETS table
and generate a fresh 256-bit HMAC secret in `persistent_term`.
""".

-export([
    init/0,
    create_challenge/0,
    build_challenge/3,
    verify_payload/1,
    verify_payload/2
]).

-define(TABLE, ircd_altcha_used).
-define(KEY_PT, {ircd_altcha, hmac_key}).
-define(MAX_NUMBER, 50000).
-define(TTL_SECONDS, 300).
-define(MAX_USED, 10000).

-doc """
Initialize the ALTCHA HMAC key and single-use replay ETS table.
Safe to call multiple times; intended to be called when `m:ircd_webui` starts.
""".
-spec init() -> ok.
init() ->
    case ets:whereis(?TABLE) of
        undefined ->
            _ = ets:new(?TABLE, [named_table, set, public, {write_concurrency, true}]),
            ok;
        _ ->
            ok
    end,
    case persistent_term:get(?KEY_PT, undefined) of
        undefined ->
            persistent_term:put(?KEY_PT, crypto:strong_rand_bytes(32));
        _ ->
            ok
    end,
    ok.

-doc """
Generate a fresh ALTCHA SHA-256 challenge map ready to be JSON-encoded for
`GET /api/altcha`.
""".
-spec create_challenge() -> map().
create_challenge() ->
    Key = hmac_key(),
    Number = rand:uniform(?MAX_NUMBER + 1) - 1,
    Expires = erlang:system_time(second) + ?TTL_SECONDS,
    build_challenge(Key, Number, Expires).

-doc """
Build a signed ALTCHA challenge map for a specific `Key`, `Number`, and Unix
`Expires` timestamp (seconds). Pure except for random salt generation.
""".
-spec build_challenge(binary(), non_neg_integer(), integer()) -> map().
build_challenge(Key, Number, Expires) when
    is_binary(Key), is_integer(Number), Number >= 0, is_integer(Expires)
->
    SaltHex = hex_lower(crypto:strong_rand_bytes(12)),
    Salt = <<SaltHex/binary, "?expires=", (integer_to_binary(Expires))/binary>>,
    Challenge = sha256_hex(<<Salt/binary, (integer_to_binary(Number))/binary>>),
    Signature = hmac_hex(Key, Challenge),
    #{
        algorithm => <<"SHA-256">>,
        challenge => Challenge,
        maxnumber => ?MAX_NUMBER,
        salt => Salt,
        signature => Signature
    }.

-doc """
Verify a base64-encoded ALTCHA JSON payload against the active server HMAC key
and enforce single-use replay protection.
""".
-spec verify_payload(binary()) -> ok | {error, invalid | expired | replayed}.
verify_payload(PayloadBin) when is_binary(PayloadBin) ->
    verify_payload(PayloadBin, hmac_key());
verify_payload(_) ->
    {error, invalid}.

-doc """
Verify a base64-encoded ALTCHA JSON payload against an explicit `Key`.
""".
-spec verify_payload(binary(), binary()) -> ok | {error, invalid | expired | replayed}.
verify_payload(PayloadBin, Key) when
    is_binary(PayloadBin), byte_size(PayloadBin) =< 4096, is_binary(Key)
->
    try json:decode(base64:decode(PayloadBin)) of
        #{
            <<"algorithm">> := <<"SHA-256">>,
            <<"challenge">> := Challenge,
            <<"number">> := Number,
            <<"salt">> := Salt,
            <<"signature">> := Signature
        } when
            is_binary(Challenge),
            byte_size(Challenge) =:= 64,
            is_integer(Number, 0, ?MAX_NUMBER),
            is_binary(Salt),
            byte_size(Salt) =< 256,
            is_binary(Signature),
            byte_size(Signature) =:= 64
        ->
            verify_fields(Key, Challenge, Number, Salt, Signature);
        _ ->
            {error, invalid}
    catch
        _:_ ->
            {error, invalid}
    end;
verify_payload(_, _) ->
    {error, invalid}.

verify_fields(Key, Challenge, Number, Salt, Signature) ->
    case parse_expires(Salt) of
        {ok, Expires} ->
            Now = erlang:system_time(second),
            case Now =< Expires of
                false ->
                    {error, expired};
                true ->
                    ExpectedSig = hmac_hex(Key, Challenge),
                    ExpectedChallenge = sha256_hex(
                        <<Salt/binary, (integer_to_binary(Number))/binary>>
                    ),
                    %% ASCII-only lowercasing keeps the 64-byte length that
                    %% crypto:hash_equals/2 requires; Unicode case mapping can
                    %% change it (and raise outside the caller's try).
                    SigOk = crypto:hash_equals(ExpectedSig, ircd_wire:lower(Signature)),
                    DigestOk = crypto:hash_equals(ExpectedChallenge, ircd_wire:lower(Challenge)),
                    case SigOk andalso DigestOk of
                        true -> claim_once(Challenge, Expires);
                        false -> {error, invalid}
                    end
            end;
        error ->
            {error, invalid}
    end.

parse_expires(Salt) ->
    case binary:split(Salt, <<"?">>) of
        [_, Query] ->
            try uri_string:dissect_query(Query) of
                Pairs when is_list(Pairs) ->
                    case lists:keyfind(<<"expires">>, 1, Pairs) of
                        {_, ExpBin} when is_binary(ExpBin) ->
                            {ok, binary_to_integer(ExpBin)};
                        _ ->
                            error
                    end;
                _ ->
                    error
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

claim_once(Challenge, Expires) ->
    case ets:whereis(?TABLE) of
        undefined ->
            ok;
        _ ->
            maybe_prune(),
            case ets:insert_new(?TABLE, {Challenge, Expires}) of
                true -> ok;
                false -> {error, replayed}
            end
    end.

maybe_prune() ->
    case ets:info(?TABLE, size) >= ?MAX_USED of
        true ->
            Now = erlang:system_time(second),
            _ = ets:select_delete(?TABLE, [{{'_', '$1'}, [{'<', '$1', Now}], [true]}]),
            ok;
        false ->
            ok
    end.

hmac_key() ->
    case persistent_term:get(?KEY_PT, undefined) of
        undefined ->
            ok = init(),
            persistent_term:get(?KEY_PT);
        Key ->
            Key
    end.

sha256_hex(Data) ->
    hex_lower(crypto:hash(sha256, Data)).

hmac_hex(Key, Data) ->
    hex_lower(crypto:mac(hmac, sha256, Key, Data)).

hex_lower(Bin) ->
    binary:encode_hex(Bin, lowercase).
