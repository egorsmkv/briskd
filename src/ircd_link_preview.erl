-module(ircd_link_preview).
-moduledoc """
SSRF-protected OpenGraph link preview fetcher (`GET /api/link-preview?url=...`).

Fetches up to 64 KiB of HTML from public `http://` or `https://` URLs (ports
80/443 only), extracts OpenGraph / HTML metadata (`title`, `description`,
`site_name`), and caches results in a bounded ETS table (10-minute TTL, max 500
entries).

SSRF defenses:
- Rejects non-HTTP(S) schemes, credentials in URLs, and non-80/443 ports.
- Resolves DNS before connecting and blocks loopback, RFC 1918 private,
  link-local / cloud metadata (`169.254.0.0/16`), CGNAT (`100.64.0.0/10`),
  multicast, IPv6 ULA/link-local, and IPv4-mapped private addresses.
- Disables automatic redirects and caps response size and timeout (5s).
""".

-export([
    enabled/0,
    fetch/1,
    validate_url/1,
    is_private_ip/1,
    extract_metadata/2
]).

-define(MAX_URL_BYTES, 1024).
-define(MAX_HTML_BYTES, 65536).
-define(TIMEOUT_MS, 5000).
-define(CACHE_TTL_SEC, 600).
-define(MAX_CACHE_ENTRIES, 500).
-define(CACHE_TABLE, ircd_link_preview_cache).

-doc """
Whether link previews are enabled in the active server configuration.
""".
-spec enabled() -> boolean().
enabled() ->
    Features = maps:get(features, persistent_term:get({ircd_state, config}, #{}), #{}),
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
                        miss ->
                            case fetch_uncached(Url, Parsed) of
                                {ok, Meta} ->
                                    cache_put(Url, Meta),
                                    {ok, Meta};
                                {error, Reason} ->
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

fetch_uncached(Url, #{host := Host}) ->
    case check_public_host(Host) of
        ok ->
            do_http_get(Url, Host);
        {error, Reason} ->
            {error, Reason}
    end.

check_public_host(Host) ->
    HostStr = binary_to_list(Host),
    case inet:parse_address(HostStr) of
        {ok, IP} ->
            case is_private_ip(IP) of
                true -> {error, private_address};
                false -> ok
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
                    case lists:any(fun is_private_ip/1, Addrs) of
                        true -> {error, private_address};
                        false -> ok
                    end
            end
    end.

do_http_get(Url, Host) ->
    Headers = [
        {<<"user-agent">>, <<"ircd-link-preview/1.0">>},
        {<<"accept">>, <<"text/html,application/xhtml+xml;q=0.9,*/*;q=0.1">>}
    ],
    Opts = [
        {recv_timeout, ?TIMEOUT_MS},
        {connect_timeout, ?TIMEOUT_MS},
        {follow_redirect, false},
        {max_body, ?MAX_HTML_BYTES},
        with_body
    ],
    case hackney:request(get, Url, Headers, <<>>, Opts) of
        {ok, Status, RespHeaders, Body} when Status >= 200, Status < 300, is_binary(Body) ->
            case is_html_content_type(RespHeaders) of
                true ->
                    Slice =
                        case byte_size(Body) > ?MAX_HTML_BYTES of
                            true -> binary:part(Body, 0, ?MAX_HTML_BYTES);
                            false -> Body
                        end,
                    Meta = extract_metadata(Slice, Host),
                    case maps:get(title, Meta) of
                        <<>> -> {error, no_metadata};
                        _ -> {ok, Meta#{url => Url}}
                    end;
                false ->
                    {error, not_html}
            end;
        {ok, _Status, _RespHeaders, _Body} ->
            {error, upstream_status};
        {error, Reason} ->
            {error, Reason}
    end.

is_html_content_type([]) ->
    false;
is_html_content_type([{K, V} | Rest]) ->
    case string:lowercase(K) of
        <<"content-type">> ->
            Lower = string:lowercase(V),
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

clean_text(Bin, MaxLen) ->
    Unesc = unescape_html(Bin),
    NoCtrl = <<<<C>> || <<C>> <= Unesc, C >= 32, C =/= 127>>,
    Collapsed = re:replace(NoCtrl, <<"\\s+">>, <<" ">>, [global, {return, binary}]),
    Trimmed = string:trim(Collapsed),
    case byte_size(Trimmed) > MaxLen of
        true -> binary:part(Trimmed, 0, MaxLen);
        false -> Trimmed
    end.

unescape_html(Bin) ->
    B1 = binary:replace(Bin, <<"&amp;">>, <<"&">>, [global]),
    B2 = binary:replace(B1, <<"&lt;">>, <<"<">>, [global]),
    B3 = binary:replace(B2, <<"&gt;">>, <<">">>, [global]),
    B4 = binary:replace(B3, <<"&quot;">>, <<"\"">>, [global]),
    B5 = binary:replace(B4, <<"&#39;">>, <<"'">>, [global]),
    binary:replace(B5, <<"&#x27;">>, <<"'">>, [global]).

cache_get(Url) ->
    Tab = ensure_cache_table(),
    Now = erlang:monotonic_time(second),
    case ets:lookup(Tab, Url) of
        [{Url, Exp, Meta}] when Exp > Now -> {ok, Meta};
        _ -> miss
    end.

cache_put(Url, Meta) ->
    Tab = ensure_cache_table(),
    case ets:info(Tab, size) >= ?MAX_CACHE_ENTRIES of
        true -> ets:delete_all_objects(Tab);
        false -> ok
    end,
    Exp = erlang:monotonic_time(second) + ?CACHE_TTL_SEC,
    ets:insert(Tab, {Url, Exp, Meta}),
    ok.

ensure_cache_table() ->
    case ets:whereis(?CACHE_TABLE) of
        undefined ->
            try
                ets:new(?CACHE_TABLE, [named_table, public, set])
            catch
                error:badarg -> ?CACHE_TABLE
            end;
        Tab ->
            Tab
    end.
