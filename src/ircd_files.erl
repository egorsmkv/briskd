-module(ircd_files).
-moduledoc """
File sharing extension (`egorsmkv.github.io/files`) backed by S3-compatible
object storage via `livery_s3` (e.g., RustFS).

Clients negotiate the vendor capability `egorsmkv.github.io/files`, upload
files through the WebUI HTTP API (`POST /api/files`), and reference the
resulting object ID in IRC `PRIVMSG` client-only tags
(`+egorsmkv.github.io/file=<id>`, `+egorsmkv.github.io/file-name=<name>`,
`+egorsmkv.github.io/file-size=<bytes>`). Downloads read from `GET /api/files/<id>`.

To prevent stored XSS, active web formats (`.html`, `.svg`, `.js`, `.xml`) are
never stored or served with executable MIME types: unrecognized or unsafe
extensions are normalized to `.bin` (`application/octet-stream`), and only safe
raster images (`png`, `jpg`, `jpeg`, `gif`, `webp`) are marked inline-previewable.
All responses are served with `X-Content-Type-Options: nosniff` and a strict
sandbox `Content-Security-Policy`.
""".

-export([
    enabled/0,
    cap/0,
    cap_value/0,
    max_bytes/0,
    valid_id/1,
    mime_for_id/1,
    is_inline_preview/1,
    sanitize_filename/1,
    store/2,
    fetch/1,
    list/0,
    delete/1
]).

-define(CAP, <<"egorsmkv.github.io/files">>).
-define(DEFAULT_MAX_BYTES, 10485760).
-define(S3_TIMEOUT_MS, 30000).
-define(MAX_FILENAME_BYTES, 120).

-doc """
Whether file sharing is enabled in the active server configuration.
""".
-spec enabled() -> boolean().
enabled() ->
    config() =/= null.

-doc """
Vendor capability name advertised in `CAP LS`: `egorsmkv.github.io/files`.
""".
-spec cap() -> binary().
cap() ->
    ?CAP.

-doc """
Capability value advertised in `CAP LS 302`, encoding the protocol version and
maximum file size in bytes (`v=1,max-bytes=<N>`).
""".
-spec cap_value() -> binary().
cap_value() ->
    <<"v=1,max-bytes=", (integer_to_binary(max_bytes()))/binary>>.

-doc """
Maximum allowed file upload size in bytes.
""".
-spec max_bytes() -> pos_integer().
max_bytes() ->
    case config() of
        #{max_bytes := Max} -> Max;
        null -> ?DEFAULT_MAX_BYTES
    end.

-doc """
Check whether `Id` is a valid file object identifier (`<32 lowercase hex>.<ext>`
with an allowlisted safe extension). Prevents path traversal and arbitrary key access.
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
Map a validated file ID to its safe MIME type.
""".
-spec mime_for_id(binary()) -> {ok, binary()} | error.
mime_for_id(<<Hex:32/binary, ".", Ext/binary>>) ->
    case is_lower_hex(Hex) of
        true -> ext_to_mime(Ext);
        false -> error
    end;
mime_for_id(_) ->
    error.

-doc """
Whether a validated file ID is a safe raster image that may be previewed inline
(`png`, `jpg`, `jpeg`, `gif`, `webp`). All other files are served as attachments.
""".
-spec is_inline_preview(binary()) -> boolean().
is_inline_preview(<<_Hex:32/binary, ".", Ext/binary>>) ->
    lists:member(Ext, [<<"png">>, <<"jpg">>, <<"jpeg">>, <<"gif">>, <<"webp">>]);
is_inline_preview(_) ->
    false.

-doc """
Sanitize a user-supplied filename for display and HTTP headers.

Strips directory paths, control characters, quotes, and length beyond 120 bytes.
Falls back to `<<"file.bin">>` when empty.
""".
-spec sanitize_filename(term()) -> binary().
sanitize_filename(Name) when is_binary(Name) ->
    Base = strip_path(Name),
    Clean = <<<<C>> || <<C>> <= Base, is_safe_name_byte(C)>>,
    Trimmed = iolist_to_binary(string:trim(Clean, both, " .")),
    case Trimmed of
        <<>> ->
            <<"file.bin">>;
        _ when byte_size(Trimmed) > ?MAX_FILENAME_BYTES ->
            binary:part(Trimmed, 0, ?MAX_FILENAME_BYTES);
        _ ->
            Trimmed
    end;
sanitize_filename(_) ->
    <<"file.bin">>.

-doc """
Validate and store a file in the configured S3 bucket.

Automatically creates the bucket on `NoSuchBucket` / `not_found` and retries
once. Returns `{ok, #{id, url, name, bytes, mime, preview}}` on success.
""".
-spec store(binary(), binary() | undefined) -> {ok, map()} | {error, term()}.
store(Bytes, RawName) when is_binary(Bytes) ->
    case config() of
        null ->
            {error, disabled};
        #{max_bytes := MaxBytes} = Cfg ->
            Size = byte_size(Bytes),
            case validate_size(Size, MaxBytes) of
                ok ->
                    Name = sanitize_filename(RawName),
                    Ext = verified_ext(safe_ext(Name), Bytes),
                    {ok, Mime} = ext_to_mime(Ext),
                    Id = new_id(Ext),
                    case put_object_with_bucket(Cfg, Id, Bytes, Mime) of
                        ok ->
                            {ok, #{
                                id => Id,
                                url => <<"/api/files/", Id/binary>>,
                                name => Name,
                                bytes => Size,
                                mime => Mime,
                                preview => is_inline_preview(Id)
                            }};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-doc """
Fetch a stored file by its validated ID from S3.

Returns `{ok, Bytes, Mime, InlinePreview}` or `{error, disabled | invalid_id | not_found | term()}`.
""".
-spec fetch(binary()) -> {ok, binary(), binary(), boolean()} | {error, term()}.
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
                    Preview = is_inline_preview(Id),
                    case livery_s3:get_object(Client, Bucket, Id) of
                        {ok, #{body := Bytes}} when is_binary(Bytes) ->
                            {ok, Bytes, Mime, Preview};
                        {ok, #{body := Body}} ->
                            {ok, iolist_to_binary(Body), Mime, Preview};
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
List stored files in the configured S3 bucket for admin inspection.
""".
-spec list() -> map().
list() ->
    case config() of
        null ->
            #{enabled => false, objects => []};
        #{bucket := Bucket, max_bytes := MaxBytes} = Cfg ->
            Base = #{
                enabled => true,
                bucket => Bucket,
                max_bytes => MaxBytes
            },
            case livery_s3:list_objects(client(Cfg), Bucket, #{max_keys => 500}) of
                {ok, #{objects := Objs}} ->
                    Items = [
                        #{
                            id => Key,
                            size => maps:get(size, O, 0),
                            last_modified => maps:get(last_modified, O, <<>>),
                            preview => is_inline_preview(Key)
                        }
                     || O <- Objs,
                        Key <- [maps:get(key, O, <<>>)],
                        valid_id(Key)
                    ],
                    Base#{objects => Items};
                {error, not_found} ->
                    Base#{objects => []};
                {error, {s3, <<"NoSuchBucket">>, _, _}} ->
                    Base#{objects => []};
                {error, Reason} ->
                    logger:warning(#{event => files_list_failed, reason => Reason}),
                    Base#{objects => [], error => <<"storage_error">>}
            end
    end.

-doc """
Delete a stored file by its validated ID from S3.
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
    maps:get(files, ircd_config:current_or_empty(), null).

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

validate_size(0, _MaxBytes) -> {error, empty};
validate_size(Size, MaxBytes) when Size > MaxBytes -> {error, too_large};
validate_size(_, _) -> ok.

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
    Hex = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    <<Hex/binary, ".", Ext/binary>>.

strip_path(Bin) ->
    Parts = binary:split(Bin, [<<"/">>, <<"\\">>], [global]),
    lists:last(Parts).

is_safe_name_byte(C) when C < 32; C =:= 127 -> false;
is_safe_name_byte($") -> false;
is_safe_name_byte($') -> false;
is_safe_name_byte($<) -> false;
is_safe_name_byte($>) -> false;
is_safe_name_byte($;) -> false;
is_safe_name_byte(_) -> true.

safe_ext(Name) ->
    case binary:split(Name, <<".">>, [global]) of
        [_Only] ->
            <<"bin">>;
        Parts ->
            Raw = ircd_wire:lower(lists:last(Parts)),
            case ext_to_mime(Raw) of
                {ok, _} -> Raw;
                error -> <<"bin">>
            end
    end.

%% Verify leading magic bytes for inline-previewable raster images so a
%% non-image payload (e.g. HTML disguised as photo.png) is downgraded to .bin
%% and served as an attachment.
verified_ext(<<"png">>, <<16#89, "PNG\r\n", 16#1A, "\n", _/binary>>) ->
    <<"png">>;
verified_ext(<<"jpg">>, <<16#FF, 16#D8, 16#FF, _/binary>>) ->
    <<"jpg">>;
verified_ext(<<"jpeg">>, <<16#FF, 16#D8, 16#FF, _/binary>>) ->
    <<"jpeg">>;
verified_ext(<<"gif">>, <<"GIF87a", _/binary>>) ->
    <<"gif">>;
verified_ext(<<"gif">>, <<"GIF89a", _/binary>>) ->
    <<"gif">>;
verified_ext(<<"webp">>, <<"RIFF", _Size:32, "WEBP", _/binary>>) ->
    <<"webp">>;
verified_ext(Ext, _Bytes) when
    Ext =:= <<"png">>;
    Ext =:= <<"jpg">>;
    Ext =:= <<"jpeg">>;
    Ext =:= <<"gif">>;
    Ext =:= <<"webp">>
->
    <<"bin">>;
verified_ext(Ext, _Bytes) ->
    Ext.

ext_to_mime(<<"png">>) -> {ok, <<"image/png">>};
ext_to_mime(<<"jpg">>) -> {ok, <<"image/jpeg">>};
ext_to_mime(<<"jpeg">>) -> {ok, <<"image/jpeg">>};
ext_to_mime(<<"gif">>) -> {ok, <<"image/gif">>};
ext_to_mime(<<"webp">>) -> {ok, <<"image/webp">>};
ext_to_mime(<<"pdf">>) -> {ok, <<"application/pdf">>};
ext_to_mime(<<"txt">>) -> {ok, <<"text/plain; charset=utf-8">>};
ext_to_mime(<<"md">>) -> {ok, <<"text/plain; charset=utf-8">>};
ext_to_mime(<<"csv">>) -> {ok, <<"text/csv; charset=utf-8">>};
ext_to_mime(<<"json">>) -> {ok, <<"application/json">>};
ext_to_mime(<<"zip">>) -> {ok, <<"application/zip">>};
ext_to_mime(<<"tar">>) -> {ok, <<"application/x-tar">>};
ext_to_mime(<<"gz">>) -> {ok, <<"application/gzip">>};
ext_to_mime(<<"mp4">>) -> {ok, <<"video/mp4">>};
ext_to_mime(<<"webm">>) -> {ok, <<"video/webm">>};
ext_to_mime(<<"mp3">>) -> {ok, <<"audio/mpeg">>};
ext_to_mime(<<"ogg">>) -> {ok, <<"audio/ogg">>};
ext_to_mime(<<"wav">>) -> {ok, <<"audio/wav">>};
ext_to_mime(<<"bin">>) -> {ok, <<"application/octet-stream">>};
ext_to_mime(_) -> error.

is_lower_hex(<<>>) ->
    true;
is_lower_hex(<<C, Rest/binary>>) when (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) ->
    is_lower_hex(Rest);
is_lower_hex(_) ->
    false.
