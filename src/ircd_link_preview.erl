-module(ircd_link_preview).
-moduledoc """
SSRF-protected OpenGraph link preview fetcher (`GET /api/link-preview?url=...`).

Reads the first 64 KiB of HTML from public `http://` or `https://` URLs
(ports 80/443 only), where the `<head>` metadata is, and stops there: pages
are often far larger (a GitHub repository page is several hundred KiB).
Extracts OpenGraph / HTML metadata (`title`, `description`, `site_name`) and
caches results in a bounded ETS table (10-minute TTL, max 500 entries); a page
with no preview is remembered for one minute so it is not fetched again on
every request.

SSRF defenses:
- Rejects non-HTTP(S) schemes, credentials in URLs, and non-80/443 ports.
- Resolves DNS before connecting and blocks loopback, RFC 1918 private,
  link-local / cloud metadata (`169.254.0.0/16`), CGNAT (`100.64.0.0/10`),
  multicast, IPv6 ULA/link-local, and IPv4-mapped private addresses.
- Connects to one of those addresses. The original name is sent only as the
  `Host` header and, for HTTPS, as the TLS server name, so a later DNS
  answer cannot move the connection onto a private address.
- Disables automatic redirects, reads at most 64 KiB, and bounds the whole
  download (connect, headers, and body) to 5 seconds.
""".

-export([
    enabled/0,
    fetch/1,
    init_cache/0,
    validate_url/1,
    is_private_ip/1,
    extract_metadata/2,
    read_capped/4
]).

-define(MAX_URL_BYTES, 1024).
-define(MAX_HTML_BYTES, 65536).
-define(TIMEOUT_MS, 5000).
-define(CACHE_TTL_SEC, 600).
-define(NEGATIVE_TTL_SEC, 60).
-define(MAX_CACHE_ENTRIES, 500).
-define(CACHE_TABLE, ircd_link_preview_cache).

-doc """
Whether link previews are enabled in the active server configuration.
""".
-spec enabled() -> boolean().
enabled() ->
    Features = maps:get(features, ircd_config:current_or_empty(), #{}),
    maps:get(link_previews, Features, true).

-doc """
Fetch and cache OpenGraph metadata for a public HTTP(S) URL.
""".
-spec fetch(binary()) -> {ok, map()} | {error, term()}.
fetch(Url) when is_binary(Url) ->
    case enabled() of
        false ->
            {error, disabled};
        true ->
            case validate_url(Url) of
                {ok, Parsed} ->
                    case cache_get(Url) of
                        {ok, Meta} ->
                            {ok, Meta};
                        {error, Reason} ->
                            {error, Reason};
                        miss ->
                            case fetch_uncached(Url, Parsed) of
                                {ok, Meta} ->
                                    cache_put(Url, {ok, Meta}, ?CACHE_TTL_SEC),
                                    {ok, Meta};
                                {error, Reason} ->
                                    cache_put(Url, {error, Reason}, ?NEGATIVE_TTL_SEC),
                                    {error, Reason}
                            end
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end;
fetch(_) ->
    {error, invalid_url}.

-doc """
Validate a URL for scheme, host, port, and absence of credentials.
""".
-spec validate_url(binary()) -> {ok, map()} | {error, term()}.
validate_url(Url) when is_binary(Url), byte_size(Url) > 0, byte_size(Url) =< ?MAX_URL_BYTES ->
    case binary:match(Url, [<<0>>, <<"\r">>, <<"\n">>, <<" ">>]) of
        nomatch ->
            case uri_string:parse(Url) of
                #{scheme := Scheme, host := Host} = Parsed when
                    (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>),
                    byte_size(Host) > 0,
                    byte_size(Host) =< 253
                ->
                    HasUserinfo = maps:is_key(userinfo, Parsed),
                    Port = maps:get(port, Parsed, default_port(Scheme)),
                    case HasUserinfo of
                        true ->
                            {error, invalid_url};
                        false when Port =:= 80; Port =:= 443 ->
                            {ok, Parsed#{port => Port}};
                        false ->
                            {error, disallowed_port}
                    end;
                _ ->
                    {error, invalid_url}
            end;
        _ ->
            {error, invalid_url}
    end;
validate_url(_) ->
    {error, invalid_url}.

-doc """
Return `true` when an IPv4 or IPv6 tuple falls in a loopback, private,
link-local, CGNAT, multicast, or reserved range that must never be fetched.
""".
-spec is_private_ip(inet:ip_address()) -> boolean().
is_private_ip({0, _, _, _}) ->
    true;
is_private_ip({10, _, _, _}) ->
    true;
is_private_ip({127, _, _, _}) ->
    true;
is_private_ip({169, 254, _, _}) ->
    true;
is_private_ip({172, B, _, _}) when B >= 16, B =< 31 -> true;
is_private_ip({192, 168, _, _}) ->
    true;
is_private_ip({100, B, _, _}) when B >= 64, B =< 127 -> true;
is_private_ip({192, 0, 0, _}) ->
    true;
is_private_ip({192, 0, 2, _}) ->
    true;
is_private_ip({198, 18, _, _}) ->
    true;
is_private_ip({198, 19, _, _}) ->
    true;
is_private_ip({198, 51, 100, _}) ->
    true;
is_private_ip({203, 0, 113, _}) ->
    true;
is_private_ip({A, _, _, _}) when A >= 224 -> true;
is_private_ip({_, _, _, _}) ->
    false;
is_private_ip({0, 0, 0, 0, 0, 0, 0, 0}) ->
    true;
is_private_ip({0, 0, 0, 0, 0, 0, 0, 1}) ->
    true;
is_private_ip({0, 0, 0, 0, 0, 16#FFFF, Hi, Lo}) ->
    is_private_ip({Hi bsr 8, Hi band 255, Lo bsr 8, Lo band 255});
is_private_ip({A, _, _, _, _, _, _, _}) when (A band 16#FE00) =:= 16#FC00 -> true;
is_private_ip({A, _, _, _, _, _, _, _}) when (A band 16#FFC0) =:= 16#FE80 -> true;
is_private_ip({A, _, _, _, _, _, _, _}) when (A band 16#FF00) =:= 16#FF00 -> true;
is_private_ip({_, _, _, _, _, _, _, _}) ->
    false;
is_private_ip(_) ->
    true.

-doc """
Extract sanitized OpenGraph / HTML metadata (`title`, `description`, `site_name`)
from an HTML binary.
""".
-spec extract_metadata(binary(), binary()) -> map().
extract_metadata(Html, Host) when is_binary(Html), is_binary(Host) ->
    Title = first_non_empty([
        meta_content(Html, <<"property">>, <<"og:title">>),
        meta_content(Html, <<"name">>, <<"twitter:title">>),
        html_title(Html)
    ]),
    Desc = first_non_empty([
        meta_content(Html, <<"property">>, <<"og:description">>),
        meta_content(Html, <<"name">>, <<"description">>),
        meta_content(Html, <<"name">>, <<"twitter:description">>)
    ]),
    Site = first_non_empty([
        meta_content(Html, <<"property">>, <<"og:site_name">>),
        Host
    ]),
    #{
        domain => Host,
        site_name => clean_text(Site, 80),
        title => clean_text(Title, 160),
        description => clean_text(Desc, 280)
    }.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

default_port(<<"https">>) -> 443;
default_port(_) -> 80.

fetch_uncached(_Url, #{host := Host} = Parsed) ->
    case public_addresses(Host) of
        {ok, Addrs} ->
            connect_public(Parsed, Addrs, dns_failed);
        {error, Reason} ->
            {error, Reason}
    end.

%% Every answer must be public. A name that resolves to both a public and a
%% private address is rejected, and the connect uses one of the addresses
%% returned here rather than the name.
public_addresses(Host) ->
    HostStr = binary_to_list(Host),
    case inet:parse_address(HostStr) of
        {ok, IP} ->
            case is_private_ip(IP) of
                true -> {error, private_address};
                false -> {ok, [IP]}
            end;
        {error, _} ->
            V4 =
                case inet:getaddrs(HostStr, inet) of
                    {ok, Addrs4} -> Addrs4;
                    {error, _} -> []
                end,
            V6 =
                case inet:getaddrs(HostStr, inet6) of
                    {ok, Addrs6} -> Addrs6;
                    {error, _} -> []
                end,
            case V4 ++ V6 of
                [] ->
                    {error, dns_failed};
                Addrs ->
                    case lists:all(fun(Addr) -> not is_private_ip(Addr) end, Addrs) of
                        true -> {ok, Addrs};
                        false -> {error, private_address}
                    end
            end
    end.

%% hackney 4 has no "read at most N bytes" option: `max_body_size` fails the
%% whole request with `body_too_large` when the page is bigger. So the body is
%% streamed on a dedicated connection and the read stops at ?MAX_HTML_BYTES.
%% `Address` is the checked IP; `Host` is only the HTTP Host header and the
%% TLS server name.
connect_public(_Parsed, [], Reason) ->
    {error, Reason};
connect_public(#{host := Host, scheme := Scheme, port := Port} = Parsed, [IP | Rest], _) ->
    Deadline = erlang:monotonic_time(millisecond) + ?TIMEOUT_MS,
    Headers = [
        {<<"Host">>, host_header(Host)},
        {<<"user-agent">>, <<"ircd-link-preview/1.0">>},
        {<<"accept">>, <<"text/html,application/xhtml+xml;q=0.9,*/*;q=0.1">>}
    ],
    Transport =
        case Scheme of
            <<"https">> -> hackney_ssl;
            _ -> hackney_tcp
        end,
    case inet:ntoa(IP) of
        {error, einval} ->
            connect_public(Parsed, Rest, einval);
        Address ->
            case hackney:connect(Transport, Address, Port, connect_opts(Scheme, Host)) of
                {ok, Conn} ->
                    try
                        get_head(Conn, request_path(Parsed), Headers, Host, Deadline)
                    after
                        hackney:close(Conn)
                    end;
                {error, Reason} ->
                    connect_public(Parsed, Rest, Reason)
            end
    end.

connect_opts(Scheme, Host) ->
    Base = [
        {connect_timeout, ?TIMEOUT_MS},
        {recv_timeout, ?TIMEOUT_MS},
        {pool, false}
    ],
    case Scheme of
        <<"https">> ->
            Sni =
                case inet:parse_address(binary_to_list(Host)) of
                    {ok, _} -> disable;
                    {error, _} -> binary_to_list(Host)
                end,
            Base ++
                [
                    {ssl_options, [
                        {verify, verify_peer},
                        {depth, 5},
                        {cacerts, public_key:cacerts_get()},
                        {server_name_indication, Sni},
                        {customize_hostname_check, [
                            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
                        ]}
                    ]}
                ];
        _ ->
            Base
    end.

%% An IPv6 literal in the Host header is bracketed. The allowed ports are the
%% scheme defaults, so the port is omitted.
host_header(Host) ->
    case binary:match(Host, <<":">>) of
        nomatch -> Host;
        _ -> <<"[", Host/binary, "]">>
    end.

get_head(Conn, Path, Headers, Host, Deadline) ->
    case hackney:send_request(Conn, {get, Path, Headers, <<>>}) of
        {ok, Status, RespHeaders, Conn} when Status >= 200, Status < 300 ->
            case is_html_content_type(RespHeaders) of
                true ->
                    Next = fun() -> hackney:stream_body(Conn) end,
                    %% The metadata is in <head>; pages often stream the rest
                    %% of the document slowly, so stop at its end.
                    case read_capped(Next, ?MAX_HTML_BYTES, Deadline, <<"</head">>) of
                        {ok, Html} -> metadata(Html, Host);
                        {error, Reason} -> {error, Reason}
                    end;
                false ->
                    {error, not_html}
            end;
        {ok, _Status, _RespHeaders, _Conn} ->
            {error, upstream_status};
        {ok, _Status, _RespHeaders} ->
            {error, upstream_status};
        {error, Reason} ->
            {error, Reason}
    end.

metadata(Html, Host) ->
    Meta = extract_metadata(Html, Host),
    case maps:get(title, Meta) of
        <<>> -> {error, no_metadata};
        _ -> {ok, Meta}
    end.

%% Path and query of the URL, as sent in the request line.
request_path(Parsed) ->
    Path =
        case maps:get(path, Parsed, <<>>) of
            <<>> -> <<"/">>;
            P -> P
        end,
    case maps:get(query, Parsed, undefined) of
        undefined -> Path;
        Q -> <<Path/binary, "?", Q/binary>>
    end.

-doc """
Read a response body through `Next` (returning `{ok, Chunk}`, `done`, or
`{error, Reason}`) until `Max` bytes, the end of the body, `Marker` (matched
without regard to ASCII case, and kept in the result; `none` disables it), or
`Deadline` (monotonic milliseconds). Returns at most `Max` bytes; a body cut
at `Max` is not an error. A body that has not ended by `Deadline`, or fails
after some data, returns what was read; with nothing read it is an error.
""".
-spec read_capped(
    fun(() -> {ok, binary()} | done | {error, term()}),
    pos_integer(),
    integer(),
    binary() | none
) -> {ok, binary()} | {error, term()}.
read_capped(Next, Max, Deadline, Marker) ->
    read_capped(Next, Max, Deadline, Marker, [], 0, <<>>).

read_capped(_Next, Max, _Deadline, _Marker, Acc, Size, _Tail) when Size >= Max ->
    {ok, binary:part(joined(Acc), 0, Max)};
read_capped(Next, Max, Deadline, Marker, Acc, Size, Tail) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true when Size > 0 ->
            {ok, joined(Acc)};
        true ->
            {error, timeout};
        false ->
            case Next() of
                {ok, Chunk} ->
                    Acc1 = [Chunk | Acc],
                    Size1 = Size + byte_size(Chunk),
                    %% Search the new chunk plus the end of the previous one,
                    %% so a marker split across chunks is still found.
                    Window = ircd_wire:lower(<<Tail/binary, Chunk/binary>>),
                    case Marker =/= none andalso binary:match(Window, Marker) =/= nomatch of
                        true ->
                            Body = joined(Acc1),
                            {ok, binary:part(Body, 0, min(Max, byte_size(Body)))};
                        false ->
                            read_capped(
                                Next, Max, Deadline, Marker, Acc1, Size1, tail(Window, Marker)
                            )
                    end;
                done ->
                    {ok, joined(Acc)};
                {error, _} when Size > 0 ->
                    {ok, joined(Acc)};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

joined(Acc) -> iolist_to_binary(lists:reverse(Acc)).

tail(_Window, none) ->
    <<>>;
tail(Window, Marker) ->
    Keep = min(byte_size(Window), byte_size(Marker) - 1),
    binary:part(Window, byte_size(Window) - Keep, Keep).

is_html_content_type([]) ->
    false;
is_html_content_type([{K, V} | Rest]) ->
    %% Header bytes come from the network: ASCII lowercasing, which does not
    %% raise on invalid UTF-8 the way string:lowercase/1 does.
    case ircd_wire:lower(iolist_to_binary(K)) of
        <<"content-type">> ->
            Lower = ircd_wire:lower(iolist_to_binary(V)),
            binary:match(Lower, <<"text/html">>) =/= nomatch orelse
                binary:match(Lower, <<"application/xhtml+xml">>) =/= nomatch;
        _ ->
            is_html_content_type(Rest)
    end.

meta_content(Html, Attr, Key) ->
    P1 =
        <<"<meta[^>]*", Attr/binary, "\\s*=\\s*[\"']", Key/binary,
            "[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"']">>,
    P2 =
        <<"<meta[^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*", Attr/binary, "\\s*=\\s*[\"']",
            Key/binary, "[\"']">>,
    case re:run(Html, P1, [caseless, {capture, [1], binary}]) of
        {match, [Val]} ->
            Val;
        nomatch ->
            case re:run(Html, P2, [caseless, {capture, [1], binary}]) of
                {match, [Val]} -> Val;
                nomatch -> <<>>
            end
    end.

html_title(Html) ->
    case
        re:run(Html, <<"<title[^>]*>([^<]+)</title>">>, [caseless, dotall, {capture, [1], binary}])
    of
        {match, [Val]} -> Val;
        nomatch -> <<>>
    end.

first_non_empty([]) -> <<>>;
first_non_empty([<<>> | Rest]) -> first_non_empty(Rest);
first_non_empty([V | _]) -> V.

%% Page text is untrusted bytes in any encoding. It is made valid UTF-8
%% (invalid bytes become U+FFFD) before anything Unicode-aware touches it, and
%% cut at `MaxLen` characters, not bytes, so the JSON reply never carries a
%% split character (json:encode/1 raises on invalid UTF-8).
clean_text(Bin, MaxLen) ->
    Unesc = ircd_websocket:utf8_safe(unescape_html(Bin)),
    NoCtrl = <<<<C>> || <<C>> <= Unesc, C >= 32, C =/= 127>>,
    Collapsed = re:replace(NoCtrl, <<"\\s+">>, <<" ">>, [global, unicode, {return, binary}]),
    Trimmed = string:trim(Collapsed),
    case string:length(Trimmed) > MaxLen of
        true -> string:trim(string:slice(Trimmed, 0, MaxLen), trailing);
        false -> Trimmed
    end.

unescape_html(Bin) ->
    B1 = binary:replace(Bin, <<"&amp;">>, <<"&">>, [global]),
    B2 = binary:replace(B1, <<"&lt;">>, <<"<">>, [global]),
    B3 = binary:replace(B2, <<"&gt;">>, <<">">>, [global]),
    B4 = binary:replace(B3, <<"&quot;">>, <<"\"">>, [global]),
    B5 = binary:replace(B4, <<"&#39;">>, <<"'">>, [global]),
    binary:replace(B5, <<"&#x27;">>, <<"'">>, [global]).

-doc """
Create the preview cache table. Call from the long-lived process that owns
it (`ircd_webui`'s `init/1`): a table created by a request handler would be
deleted when that handler exits. Without the table, previews are fetched
uncached. A second call is a no-op.
""".
-spec init_cache() -> ok.
init_cache() ->
    _ =
        case ets:whereis(?CACHE_TABLE) of
            undefined -> ets:new(?CACHE_TABLE, [named_table, public, set]);
            Tab -> Tab
        end,
    ok.

cache_get(Url) ->
    Now = erlang:monotonic_time(second),
    case ets:whereis(?CACHE_TABLE) =/= undefined andalso ets:lookup(?CACHE_TABLE, Url) of
        [{Url, Exp, Result}] when Exp > Now -> Result;
        _ -> miss
    end.

cache_put(Url, Result, Ttl) ->
    case ets:info(?CACHE_TABLE, size) of
        undefined ->
            ok;
        Size ->
            case Size >= ?MAX_CACHE_ENTRIES of
                true -> ets:delete_all_objects(?CACHE_TABLE);
                false -> ok
            end,
            Exp = erlang:monotonic_time(second) + Ttl,
            ets:insert(?CACHE_TABLE, {Url, Exp, Result}),
            ok
    end.
