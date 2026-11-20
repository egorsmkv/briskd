-module(ircd_voice).
-moduledoc """
Voice message extension (`egorsmkv.github.io/voice`) backed by S3-compatible
object storage via `livery_s3` (e.g., RustFS).

Clients negotiate the vendor capability `egorsmkv.github.io/voice`, upload
OPUS-encoded audio (`audio/ogg` or `audio/webm`) through the WebUI HTTP API
(`POST /api/voice`), and reference the resulting voice ID in IRC `PRIVMSG`
client-only tags (`+egorsmkv.github.io/voice=<id>`,
`+egorsmkv.github.io/voice-dur=<seconds>`). Playback reads the stored object
through `GET /api/voice/<id>`.

The extension is disabled unless the `voice` configuration object is set.
Uploaded payloads are validated by size and container magic bytes (`OggS` for
Ogg/Opus, `1A 45 DF A3` for WebM/EBML) before being written to object storage.
""".

-export([
    enabled/0,
    cap/0,
    cap_value/0,
    max_bytes/0,
    max_duration/0,
    valid_id/1,
    detect_opus/1,
    mime_for_id/1,
    store/2,
    fetch/1,
    list/0,
    delete/1
]).

-define(CAP, <<"egorsmkv.github.io/voice">>).
-define(DEFAULT_MAX_BYTES, 1048576).
-define(DEFAULT_MAX_DURATION, 120).
-define(S3_TIMEOUT_MS, 15000).

-doc """
Whether voice messages are enabled in the active server configuration.
""".
-spec enabled() -> boolean().
enabled() ->
    config() =/= null.

-doc """
Vendor capability name advertised in `CAP LS`: `egorsmkv.github.io/voice`.
""".
-spec cap() -> binary().
cap() ->
    ?CAP.

-doc """
Capability value advertised in `CAP LS 302`, encoding the protocol version,
codec (`opus`), maximum payload size in bytes, and maximum duration in seconds.
""".
-spec cap_value() -> binary().
cap_value() ->
    iolist_to_binary([
        <<"v=1,codec=opus,max-bytes=">>,
        integer_to_binary(max_bytes()),
        <<",max-duration=">>,
        integer_to_binary(max_duration())
    ]).

-doc """
Maximum allowed voice message upload size in bytes.
""".
-spec max_bytes() -> pos_integer().
max_bytes() ->
    case config() of
        #{max_bytes := Max} -> Max;
        null -> ?DEFAULT_MAX_BYTES
    end.

-doc """
Maximum allowed voice message duration in seconds.
""".
-spec max_duration() -> pos_integer().
max_duration() ->
    case config() of
        #{max_duration := Max} -> Max;
        null -> ?DEFAULT_MAX_DURATION
    end.

-doc """
Check whether `Id` is a valid voice object identifier (`<32 lowercase hex>.ogg`
or `<32 lowercase hex>.webm`). Prevents path traversal and arbitrary S3 key access.
""".
-spec valid_id(term()) -> boolean().
valid_id(Id) when is_binary(Id) ->
    case mime_for_id(Id) of
        {ok, _} -> true;
        error -> false
    end;
valid_id(_) ->
    false.

-doc """
Map a validated voice ID to its audio MIME type (`audio/ogg` or `audio/webm`).
""".
-spec mime_for_id(binary()) -> {ok, binary()} | error.
mime_for_id(<<Hex:32/binary, ".ogg">>) ->
    case is_lower_hex(Hex) of
        true -> {ok, <<"audio/ogg">>};
        false -> error
    end;
mime_for_id(<<Hex:32/binary, ".webm">>) ->
    case is_lower_hex(Hex) of
        true -> {ok, <<"audio/webm">>};
        false -> error
    end;
mime_for_id(_) ->
    error.

-doc """
Inspect the leading container magic bytes of an uploaded OPUS voice recording.

Accepts Ogg (`OggS`) and WebM/EBML (`1A 45 DF A3`) containers and rejects all
other payloads.
""".
-spec detect_opus(binary()) -> {ok, binary(), binary()} | {error, unsupported_format}.
detect_opus(<<"OggS", _/binary>>) ->
    {ok, <<"audio/ogg">>, <<"ogg">>};
detect_opus(<<16#1A, 16#45, 16#DF, 16#A3, _/binary>>) ->
    {ok, <<"audio/webm">>, <<"webm">>};
detect_opus(_) ->
    {error, unsupported_format}.

-doc """
Validate and store an OPUS voice recording in the configured S3 bucket.

Automatically creates the configured bucket if the S3 store reports
`NoSuchBucket` or `not_found`, then retries the upload once. Returns
`{ok, #{id, url, bytes, mime, duration}}` on success.
""".
-spec store(binary(), non_neg_integer() | undefined) ->
    {ok, map()} | {error, term()}.
store(Bytes, Duration) when is_binary(Bytes) ->
    case config() of
        null ->
            {error, disabled};
        #{max_bytes := MaxBytes, max_duration := MaxDur} = Cfg ->
            Size = byte_size(Bytes),
            case validate_upload(Size, MaxBytes, Duration, MaxDur, Bytes) of
                {ok, Mime, Ext, CleanDur} ->
                    Id = new_id(Ext),
                    case put_object_with_bucket(Cfg, Id, Bytes, Mime) of
                        ok ->
                            {ok, #{
                                id => Id,
                                url => <<"/api/voice/", Id/binary>>,
                                bytes => Size,
                                mime => Mime,
                                duration => CleanDur
                            }};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-doc """
Fetch a stored voice message by its validated ID from S3.

Returns `{ok, Bytes, Mime}` or `{error, disabled | invalid_id | not_found | term()}`.
""".
-spec fetch(binary()) -> {ok, binary(), binary()} | {error, term()}.
fetch(Id) when is_binary(Id) ->
    case config() of
        null ->
            {error, disabled};
        Cfg ->
            case mime_for_id(Id) of
                error ->
                    {error, invalid_id};
                {ok, Mime} ->
                    #{bucket := Bucket} = Cfg,
                    Client = client(Cfg),
                    case livery_s3:get_object(Client, Bucket, Id) of
                        {ok, #{body := Bytes}} when is_binary(Bytes) ->
                            {ok, Bytes, Mime};
                        {ok, #{body := Body}} ->
                            {ok, iolist_to_binary(Body), Mime};
                        {error, not_found} ->
                            {error, not_found};
                        {error, {s3, <<"NoSuchKey">>, _, _}} ->
                            {error, not_found};
                        {error, {s3, <<"NoSuchBucket">>, _, _}} ->
                            {error, not_found};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
    end;
fetch(_) ->
    {error, invalid_id}.

-doc """
List stored voice objects in the configured S3 bucket for admin inspection.
""".
-spec list() -> map().
list() ->
    case config() of
        null ->
            #{enabled => false, objects => []};
        #{bucket := Bucket, max_bytes := MaxBytes, max_duration := MaxDur} = Cfg ->
            Base = #{
                enabled => true,
                bucket => Bucket,
                max_bytes => MaxBytes,
                max_duration => MaxDur
            },
            case livery_s3:list_objects(client(Cfg), Bucket, #{max_keys => 500}) of
                {ok, #{objects := Objs}} ->
                    Items = [
                        #{
                            id => maps:get(key, O, <<>>),
                            size => maps:get(size, O, 0),
                            last_modified => maps:get(last_modified, O, <<>>)
                        }
                     || O <- Objs, valid_id(maps:get(key, O, <<>>))
                    ],
                    Base#{objects => Items};
                {error, not_found} ->
                    Base#{objects => []};
                {error, {s3, <<"NoSuchBucket">>, _, _}} ->
                    Base#{objects => []};
                {error, Reason} ->
                    logger:warning(#{event => voice_list_failed, reason => Reason}),
                    Base#{objects => [], error => <<"storage_error">>}
            end
    end.

-doc """
Delete a stored voice message by its validated ID from S3.
""".
-spec delete(binary()) -> ok | {error, term()}.
delete(Id) when is_binary(Id) ->
    case config() of
        null ->
            {error, disabled};
        #{bucket := Bucket} = Cfg ->
            case valid_id(Id) of
                false ->
                    {error, invalid_id};
                true ->
                    case livery_s3:delete_object(client(Cfg), Bucket, Id) of
                        ok -> ok;
                        {error, not_found} -> ok;
                        {error, Reason} -> {error, Reason}
                    end
            end
    end;
delete(_) ->
    {error, invalid_id}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

config() ->
    maps:get(voice, persistent_term:get({ircd_state, config}, #{}), null).

client(#{
    endpoint := Endpoint,
    region := Region,
    access_key_id := AccessKey,
    secret_access_key := SecretKey
}) ->
    livery_s3:new(#{
        endpoint => Endpoint,
        region => Region,
        access_key_id => AccessKey,
        secret_access_key => SecretKey,
        addressing => path,
        timeout => ?S3_TIMEOUT_MS
    }).

validate_upload(0, _MaxBytes, _Dur, _MaxDur, _Bytes) ->
    {error, empty};
validate_upload(Size, MaxBytes, _Dur, _MaxDur, _Bytes) when Size > MaxBytes ->
    {error, too_large};
validate_upload(_Size, _MaxBytes, Dur, MaxDur, _Bytes) when is_integer(Dur), Dur > MaxDur ->
    {error, too_long};
validate_upload(_Size, _MaxBytes, Dur, _MaxDur, Bytes) ->
    CleanDur =
        case Dur of
            N when is_integer(N), N >= 0 -> N;
            _ -> 0
        end,
    case detect_opus(Bytes) of
        {ok, Mime, Ext} -> {ok, Mime, Ext, CleanDur};
        {error, Reason} -> {error, Reason}
    end.

put_object_with_bucket(#{bucket := Bucket} = Cfg, Id, Bytes, Mime) ->
    Client = client(Cfg),
    Opts = #{content_type => Mime},
    case livery_s3:put_object(Client, Bucket, Id, Bytes, Opts) of
        {ok, _} ->
            ok;
        {error, not_found} ->
            ensure_bucket_and_put(Client, Bucket, Id, Bytes, Opts);
        {error, {s3, <<"NoSuchBucket">>, _, _}} ->
            ensure_bucket_and_put(Client, Bucket, Id, Bytes, Opts);
        {error, Reason} ->
            {error, Reason}
    end.

ensure_bucket_and_put(Client, Bucket, Id, Bytes, Opts) ->
    _ = livery_s3:create_bucket(Client, Bucket),
    case livery_s3:put_object(Client, Bucket, Id, Bytes, Opts) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

new_id(Ext) ->
    Hex = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(16))),
    <<Hex/binary, ".", Ext/binary>>.

is_lower_hex(<<>>) ->
    true;
is_lower_hex(<<C, Rest/binary>>) when (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) ->
    is_lower_hex(Rest);
is_lower_hex(_) ->
    false.
