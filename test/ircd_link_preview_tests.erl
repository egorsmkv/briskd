-module(ircd_link_preview_tests).
-include_lib("eunit/include/eunit.hrl").

validate_url_test() ->
    ?assertMatch(
        {ok, #{host := <<"example.com">>, port := 443}},
        ircd_link_preview:validate_url(<<"https://example.com/path">>)
    ),
    ?assertMatch(
        {ok, #{host := <<"example.com">>, port := 80}},
        ircd_link_preview:validate_url(<<"http://example.com">>)
    ),
    ?assertEqual({error, invalid_url}, ircd_link_preview:validate_url(<<"javascript:alert(1)">>)),
    ?assertEqual({error, invalid_url}, ircd_link_preview:validate_url(<<"file:///etc/passwd">>)),
    ?assertEqual(
        {error, invalid_url}, ircd_link_preview:validate_url(<<"https://user:pass@example.com">>)
    ),
    ?assertEqual(
        {error, disallowed_port}, ircd_link_preview:validate_url(<<"http://example.com:8080/x">>)
    ).

private_ip_ssrf_test() ->
    ?assert(ircd_link_preview:is_private_ip({127, 0, 0, 1})),
    ?assert(ircd_link_preview:is_private_ip({10, 0, 0, 1})),
    ?assert(ircd_link_preview:is_private_ip({172, 16, 5, 1})),
    ?assert(ircd_link_preview:is_private_ip({192, 168, 1, 1})),
    ?assert(ircd_link_preview:is_private_ip({169, 254, 169, 254})),
    ?assert(ircd_link_preview:is_private_ip({100, 64, 0, 1})),
    ?assert(ircd_link_preview:is_private_ip({0, 0, 0, 0, 0, 0, 0, 1})),
    ?assert(ircd_link_preview:is_private_ip({16#FC00, 0, 0, 0, 0, 0, 0, 1})),
    ?assert(ircd_link_preview:is_private_ip({16#FE80, 0, 0, 0, 0, 0, 0, 1})),
    %% IPv4-mapped loopback ::ffff:127.0.0.1
    ?assert(ircd_link_preview:is_private_ip({0, 0, 0, 0, 0, 16#FFFF, 16#7F00, 16#0001})),
    %% Public IPs allowed
    ?assertNot(ircd_link_preview:is_private_ip({1, 1, 1, 1})),
    ?assertNot(ircd_link_preview:is_private_ip({93, 184, 216, 34})),
    ?assertNot(ircd_link_preview:is_private_ip({16#2606, 16#4700, 0, 0, 0, 0, 0, 16#1111})).

extract_metadata_test() ->
    Html = <<
        "<html><head>"
        "<title>Fallback Title</title>"
        "<meta property=\"og:title\" content=\"Hello &amp; Welcome\">"
        "<meta property=\"og:description\" content=\"A clean &lt;fast&gt; IRC server.\">"
        "<meta property=\"og:site_name\" content=\"ExampleNet\">"
        "</head><body>hi</body></html>"
    >>,
    Meta = ircd_link_preview:extract_metadata(Html, <<"example.com">>),
    ?assertEqual(<<"Hello & Welcome">>, maps:get(title, Meta)),
    ?assertEqual(<<"A clean <fast> IRC server.">>, maps:get(description, Meta)),
    ?assertEqual(<<"ExampleNet">>, maps:get(site_name, Meta)),
    ?assertEqual(<<"example.com">>, maps:get(domain, Meta)).
