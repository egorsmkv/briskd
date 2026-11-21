-module(briskd_link_preview_tests).
-include_lib("eunit/include/eunit.hrl").

validate_url_test() ->
    ?assertMatch(
        {ok, #{host := <<"example.com">>, port := 443}},
        briskd_link_preview:validate_url(<<"https://example.com/path">>)
    ),
    ?assertMatch(
        {ok, #{host := <<"example.com">>, port := 80}},
        briskd_link_preview:validate_url(<<"http://example.com">>)
    ),
    ?assertEqual({error, invalid_url}, briskd_link_preview:validate_url(<<"javascript:alert(1)">>)),
    ?assertEqual({error, invalid_url}, briskd_link_preview:validate_url(<<"file:///etc/passwd">>)),
    ?assertEqual(
        {error, invalid_url}, briskd_link_preview:validate_url(<<"https://user:pass@example.com">>)
    ),
    ?assertEqual(
        {error, disallowed_port}, briskd_link_preview:validate_url(<<"http://example.com:8080/x">>)
    ).

private_ip_ssrf_test() ->
    ?assert(briskd_link_preview:is_private_ip({127, 0, 0, 1})),
    ?assert(briskd_link_preview:is_private_ip({10, 0, 0, 1})),
    ?assert(briskd_link_preview:is_private_ip({172, 16, 5, 1})),
    ?assert(briskd_link_preview:is_private_ip({192, 168, 1, 1})),
    ?assert(briskd_link_preview:is_private_ip({169, 254, 169, 254})),
    ?assert(briskd_link_preview:is_private_ip({100, 64, 0, 1})),
    ?assert(briskd_link_preview:is_private_ip({0, 0, 0, 0, 0, 0, 0, 1})),
    ?assert(briskd_link_preview:is_private_ip({16#FC00, 0, 0, 0, 0, 0, 0, 1})),
    ?assert(briskd_link_preview:is_private_ip({16#FE80, 0, 0, 0, 0, 0, 0, 1})),
    %% IPv4-mapped loopback ::ffff:127.0.0.1
    ?assert(briskd_link_preview:is_private_ip({0, 0, 0, 0, 0, 16#FFFF, 16#7F00, 16#0001})),
    %% Public IPs allowed
    ?assertNot(briskd_link_preview:is_private_ip({1, 1, 1, 1})),
    ?assertNot(briskd_link_preview:is_private_ip({93, 184, 216, 34})),
    ?assertNot(briskd_link_preview:is_private_ip({16#2606, 16#4700, 0, 0, 0, 0, 0, 16#1111})).

extract_metadata_test() ->
    Html = <<
        "<html><head>"
        "<title>Fallback Title</title>"
        "<meta property=\"og:title\" content=\"Hello &amp; Welcome\">"
        "<meta property=\"og:description\" content=\"A clean &lt;fast&gt; IRC server.\">"
        "<meta property=\"og:site_name\" content=\"ExampleNet\">"
        "</head><body>hi</body></html>"
    >>,
    Meta = briskd_link_preview:extract_metadata(Html, <<"example.com">>),
    ?assertEqual(<<"Hello & Welcome">>, maps:get(title, Meta)),
    ?assertEqual(<<"A clean <fast> IRC server.">>, maps:get(description, Meta)),
    ?assertEqual(<<"ExampleNet">>, maps:get(site_name, Meta)),
    ?assertEqual(<<"example.com">>, maps:get(domain, Meta)).

%% Pages are read up to the cap; a larger page is cut, not an error (hackney
%% 4 fails a whole request whose body passes max_body_size, which made large
%% pages such as GitHub repositories return no preview).
read_capped_test() ->
    Far = erlang:monotonic_time(millisecond) + 60000,
    Stream = fun(Chunks) ->
        Ref = make_ref(),
        put(Ref, Chunks),
        fun() ->
            case get(Ref) of
                [] ->
                    done;
                [{error, _} = E | Rest] ->
                    put(Ref, Rest),
                    E;
                [C | Rest] ->
                    put(Ref, Rest),
                    {ok, C}
            end
        end
    end,
    Big = [binary:copy(<<"a">>, 1000) || _ <- lists:seq(1, 100)],
    {ok, Cut} = briskd_link_preview:read_capped(Stream(Big), 4096, Far, none),
    ?assertEqual(4096, byte_size(Cut)),
    ?assertEqual(
        {ok, <<"head body">>},
        briskd_link_preview:read_capped(Stream([<<"head ">>, <<"body">>]), 4096, Far, none)
    ),
    %% An error after some data keeps what was read; before any, it fails.
    ?assertEqual(
        {ok, <<"<head>">>},
        briskd_link_preview:read_capped(Stream([<<"<head>">>, {error, closed}]), 4096, Far, none)
    ),
    ?assertEqual(
        {error, closed},
        briskd_link_preview:read_capped(Stream([{error, closed}]), 4096, Far, none)
    ),
    %% Past the deadline: what was read so far, or a timeout.
    Past = erlang:monotonic_time(millisecond) - 1,
    ?assertEqual({error, timeout}, briskd_link_preview:read_capped(Stream(Big), 4096, Past, none)),
    %% The end of <head> stops the read, also when split across chunks and in
    %% any case; nothing after the chunk that completes it is requested.
    Marker = <<"</head">>,
    ?assertEqual(
        {ok, <<"<title>t</title></HE", "AD><body>">>},
        briskd_link_preview:read_capped(
            Stream([<<"<title>t</title></HE">>, <<"AD><body>">>, {error, not_read}]),
            4096,
            Far,
            Marker
        )
    ).

%% Page text is untrusted bytes: invalid UTF-8 becomes U+FFFD, and long text
%% is cut at a character boundary, so the JSON reply can always be encoded.
extract_metadata_utf8_test() ->
    Long = binary:copy(<<"ж"/utf8>>, 400),
    Html =
        <<"<html><head><title>Bad ", 255, " byte</title>",
            "<meta property=\"og:description\" content=\"", Long/binary, "\"></head>">>,
    Meta = briskd_link_preview:extract_metadata(Html, <<"example.com">>),
    #{title := Title, description := Desc} = Meta,
    ?assertEqual(<<"Bad ", 16#EF, 16#BF, 16#BD, " byte">>, Title),
    ?assertEqual(280, string:length(Desc)),
    ?assert(is_binary(unicode:characters_to_binary(Desc))),
    ?assert(is_binary(iolist_to_binary(json:encode(Meta)))).
