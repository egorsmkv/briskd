-module(briskd_cov_core_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("briskd/include/briskd_state.hrl").
-include_lib("briskd/include/briskd_wire.hrl").

%% Pure coverage for configuration validation (briskd_config), the wire codec
%% (briskd_wire, RFC 1459 / RFC 2812 2.3 line grammar and IRCv3 message-tags),
%% log redaction (briskd_log), capability values (briskd_cap), and ISUPPORT chunks.

%%% briskd_config

load(Map) ->
    Dir = filename:join(
        "/tmp", "briskd-cov-core-cfg-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "briskd.json"),
    ok = file:write_file(Path, json:encode(Map)),
    try
        briskd_config:load(Path)
    after
        _ = file:delete(Path),
        _ = file:del_dir(Dir)
    end.

reason(Map) ->
    {error, {invalid_config, _, Reason}} = load(Map),
    Reason.

secret_match_test() ->
    ?assert(briskd_config:secret_match(<<>>, <<>>)),
    ?assertNot(briskd_config:secret_match(<<"x">>, "x")),
    ?assertNot(briskd_config:secret_match(1, <<"x">>)).

missing_file_test() ->
    ?assertMatch(
        {error, {invalid_config, "/nonexistent/briskd-cov.json", _}},
        briskd_config:load("/nonexistent/briskd-cov.json")
    ).

all_log_levels_test() ->
    lists:foreach(
        fun(Level) ->
            {ok, Config} = load(#{<<"log_level">> => atom_to_binary(Level)}),
            ?assertEqual(Level, maps:get(level, Config))
        end,
        [trace, debug, info, notice, warning, error, critical, alert, emergency]
    ),
    ?assertEqual({invalid_log_level, 3}, reason(#{<<"log_level">> => 3})).

defaults_test() ->
    {ok, Config} = load(#{}),
    ?assertEqual(<<"irc.local">>, maps:get(name, Config)),
    ?assertEqual({127, 0, 0, 1}, maps:get(ip, Config)),
    ?assertEqual(6667, maps:get(tcp, Config)),
    ?assertEqual(null, maps:get(tls, Config)),
    ?assertEqual([], maps:get(tls_options, Config)),
    ?assertEqual(null, maps:get(sts, Config)),
    ?assertEqual(null, maps:get(ws_origins, Config)),
    ?assertEqual(null, maps:get(network_icon, Config)),
    ?assertEqual(null, maps:get(account_verification, Config)),
    ?assertEqual(<<"irc.local">>, maps:get(network, Config)),
    ?assertEqual(9, maps:get(nicklen, Config)),
    ?assertEqual(5, maps:get(shutdown_grace, Config)),
    ?assertEqual(<<"json">>, maps:get(log_format, Config)).

name_bind_and_ports_test() ->
    ?assertMatch({badmatch, nomatch}, reason(#{<<"name">> => <<"-bad">>})),
    ?assertMatch({badmatch, nomatch}, reason(#{<<"name">> => <<"a b">>})),
    ?assertMatch({badmatch, {error, einval}}, reason(#{<<"bind">> => <<"not-an-ip">>})),
    {ok, V6} = load(#{<<"bind">> => <<"::1">>}),
    ?assertEqual({0, 0, 0, 0, 0, 0, 0, 1}, maps:get(ip, V6)),
    %% Port bounds are inclusive: 0 (ephemeral) and 65535 are accepted.
    {ok, Edge} = load(#{<<"tcp_port">> => 65535, <<"ws_port">> => 0}),
    ?assertEqual(65535, maps:get(tcp, Edge)),
    ?assertEqual(0, maps:get(ws, Edge)),
    ?assertMatch(function_clause, reason(#{<<"tcp_port">> => 65536})),
    ?assertMatch(function_clause, reason(#{<<"tcp_port">> => -1})),
    ?assertMatch(function_clause, reason(#{<<"ws_port">> => <<"80">>})),
    ?assertMatch(
        {badmatch, false},
        reason(#{
            <<"tcp_port">> => null,
            <<"tls_port">> => null,
            <<"ws_port">> => null,
            <<"wss_port">> => null
        })
    ),
    {ok, OnlyWs} = load(#{<<"tcp_port">> => null, <<"ws_port">> => 8080}),
    ?assertEqual(null, maps:get(tcp, OnlyWs)).

tls_options_test() ->
    %% TLS without certfile is rejected; wss_port alone also requires it.
    ?assertMatch({badkey, <<"certfile">>}, reason(#{<<"tls_port">> => 6697})),
    ?assertMatch({badkey, <<"certfile">>}, reason(#{<<"wss_port">> => 0})),
    Base = #{
        <<"tls_port">> => 6697,
        <<"certfile">> => <<"/etc/c.pem">>,
        <<"keyfile">> => <<"/etc/k.pem">>
    },
    {ok, Config} = load(Base),
    Options = maps:get(tls_options, Config),
    ?assertEqual("/etc/c.pem", proplists:get_value(certfile, Options)),
    ?assertEqual(['tlsv1.3', 'tlsv1.2'], proplists:get_value(versions, Options)),
    ?assertEqual(verify_peer, proplists:get_value(verify, Options)),
    ?assertEqual(false, proplists:get_value(fail_if_no_peer_cert, Options)),
    ?assertEqual(undefined, proplists:get_value(sni_hosts, Options)),
    {Verify, St} = proplists:get_value(verify_fun, Options),
    ?assertEqual({valid, St}, Verify(cert, {bad_cert, unknown_ca}, St)),
    ?assertEqual({unknown, St}, Verify(cert, {extension, ext}, St)),
    ?assertEqual({valid, St}, Verify(cert, valid, St)),
    ?assertEqual({valid, St}, Verify(cert, valid_peer, St)),
    Sni = Base#{
        <<"sni">> => [
            #{
                <<"hostname">> => <<"alt.example">>,
                <<"certfile">> => <<"/a.pem">>,
                <<"keyfile">> => <<"/a.key">>
            }
        ]
    },
    {ok, WithSni} = load(Sni),
    ?assertEqual(
        [{"alt.example", [{certfile, "/a.pem"}, {keyfile, "/a.key"}]}],
        proplists:get_value(sni_hosts, maps:get(tls_options, WithSni))
    ),
    ?assertMatch(
        {badmatch, false},
        reason(Base#{
            <<"sni">> => [
                #{<<"hostname">> => <<>>, <<"certfile">> => <<"/a">>, <<"keyfile">> => <<"/b">>}
            ]
        })
    ),
    ?assertMatch(function_clause, reason(Base#{<<"sni">> => <<"bad">>})).

log_format_and_limits_test() ->
    {ok, Text} = load(#{<<"log_format">> => <<"text">>}),
    ?assertEqual(<<"text">>, maps:get(log_format, Text)),
    ?assertMatch({badmatch, false}, reason(#{<<"log_format">> => <<"xml">>})),
    ?assertMatch(function_clause, reason(#{<<"max_clients">> => 0})),
    ?assertMatch(function_clause, reason(#{<<"max_clients">> => 1000001})),
    {ok, Max} = load(#{<<"max_clients">> => 1000000, <<"reop_delay">> => 1}),
    ?assertEqual(1000000, maps:get(max_clients, Max)),
    ?assertMatch(function_clause, reason(#{<<"reop_delay">> => <<"30">>})),
    ?assertMatch(function_clause, reason(#{<<"monitor_limit">> => -5})),
    ?assertEqual({invalid_history_limit, 10001}, reason(#{<<"history_limit">> => 10001})),
    ?assertEqual({invalid_retention, 7}, reason(#{<<"retention">> => 7})).

paths_and_secrets_test() ->
    {ok, Config} = load(#{
        <<"motd_file">> => <<"motd.txt">>,
        <<"client_password">> => <<"letmein">>,
        <<"mnesia_dir">> => <<"/var/db">>
    }),
    ?assertEqual("motd.txt", maps:get(motd_file, Config)),
    ?assertEqual(<<"letmein">>, maps:get(client_password, Config)),
    ?assertEqual("/var/db", maps:get(mnesia_dir, Config)),
    ?assertMatch(function_clause, reason(#{<<"motd_file">> => <<>>})),
    ?assertMatch(function_clause, reason(#{<<"motd_file">> => 3})),
    ?assertMatch(function_clause, reason(#{<<"client_password">> => <<>>})),
    ?assertMatch(function_clause, reason(#{<<"mnesia_dir">> => <<>>})),
    ?assertMatch(function_clause, reason(#{<<"mnesia_dir">> => null})).

numeric_settings_test() ->
    {ok, Edges} = load(#{
        <<"shutdown_grace">> => 300,
        <<"nicklen">> => 30,
        <<"resource_delay">> => 0,
        <<"account_password_min">> => 1
    }),
    ?assertEqual(300, maps:get(shutdown_grace, Edges)),
    ?assertEqual(30, maps:get(nicklen, Edges)),
    ?assertEqual(0, maps:get(resource_delay, Edges)),
    ?assertEqual(1, maps:get(account_password_min, Edges)),
    ?assertEqual({invalid_shutdown_grace, 301}, reason(#{<<"shutdown_grace">> => 301})),
    ?assertEqual({invalid_shutdown_grace, -1}, reason(#{<<"shutdown_grace">> => -1})),
    ?assertEqual({invalid_nicklen, 8}, reason(#{<<"nicklen">> => 8})),
    ?assertEqual({invalid_nicklen, 31}, reason(#{<<"nicklen">> => 31})),
    ?assertEqual({invalid_resource_delay, 86401}, reason(#{<<"resource_delay">> => 86401})),
    ?assertEqual(
        {invalid_account_password_min, 0}, reason(#{<<"account_password_min">> => 0})
    ),
    ?assertEqual(
        {invalid_account_password_min, 301}, reason(#{<<"account_password_min">> => 301})
    ).

boolean_settings_test() ->
    lists:foreach(
        fun(Key) ->
            Bin = atom_to_binary(Key),
            ?assertEqual({invalid_boolean, Key, <<"yes">>}, reason(#{Bin => <<"yes">>})),
            {ok, Config} = load(#{Bin => true}),
            ?assertEqual(true, maps:get(Key, Config))
        end,
        [
            multiclient,
            account_rejoin,
            account_registration_before_connect,
            account_registration_email_required,
            account_registration,
            utf8_only,
            chathistory
        ]
    ).

network_test() ->
    {ok, Config} = load(#{
        <<"network">> => <<"ExampleNet">>, <<"network_icon">> => <<"https://x/i.png">>
    }),
    ?assertEqual(<<"ExampleNet">>, maps:get(network, Config)),
    ?assertEqual(<<"https://x/i.png">>, maps:get(network_icon, Config)),
    ?assertEqual({invalid_network, <<"a b">>}, reason(#{<<"network">> => <<"a b">>})),
    ?assertEqual({invalid_network, <<"a,b">>}, reason(#{<<"network">> => <<"a,b">>})),
    ?assertEqual({invalid_network, <<>>}, reason(#{<<"network">> => <<>>})),
    ?assertEqual({invalid_network, 5}, reason(#{<<"network">> => 5})),
    ?assertEqual(
        {invalid_network_icon, invalid}, reason(#{<<"network_icon">> => <<"http://x y">>})
    ),
    ?assertEqual({invalid_network_icon, invalid}, reason(#{<<"network_icon">> => <<>>})),
    ?assertEqual({invalid_network_icon, invalid}, reason(#{<<"network_icon">> => 1})).

ws_origins_test() ->
    {ok, Config} = load(#{<<"ws_origins">> => [<<"https://a">>]}),
    ?assertEqual([<<"https://a">>], maps:get(ws_origins, Config)),
    ?assertEqual({invalid_ws_origin, 1}, reason(#{<<"ws_origins">> => [<<"https://a">>, 1]})),
    ?assertMatch(function_clause, reason(#{<<"ws_origins">> => <<"https://a">>})).

sts_test() ->
    {ok, Config} = load(#{<<"sts">> => #{<<"port">> => 6697, <<"preload">> => true}}),
    ?assertEqual(
        #{port => 6697, duration => 2592000, preload => true}, maps:get(sts, Config)
    ),
    ?assertEqual({invalid_sts, <<"on">>}, reason(#{<<"sts">> => <<"on">>})),
    ?assertMatch({badkey, <<"port">>}, reason(#{<<"sts">> => #{}})),
    ?assertMatch({badmatch, false}, reason(#{<<"sts">> => #{<<"port">> => 0}})),
    ?assertMatch(
        {badmatch, false}, reason(#{<<"sts">> => #{<<"port">> => 1, <<"duration">> => -1}})
    ),
    ?assertMatch(
        {badmatch, false}, reason(#{<<"sts">> => #{<<"port">> => 1, <<"preload">> => 1}})
    ).

account_verification_test() ->
    {ok, Config} = load(#{
        <<"account_verification">> => #{
            <<"command">> => [<<"/bin/echo">>, <<"-n">>], <<"ttl">> => 60
        }
    }),
    ?assertEqual(
        #{command => ["/bin/echo", "-n"], ttl => 60}, maps:get(account_verification, Config)
    ),
    ?assertEqual(
        {invalid_account_verification, 1}, reason(#{<<"account_verification">> => 1})
    ),
    ?assertMatch(
        {badmatch, false},
        reason(#{<<"account_verification">> => #{<<"command">> => [<<"relative">>]}})
    ),
    ?assertMatch(
        {badmatch, false},
        reason(#{<<"account_verification">> => #{<<"command">> => [<<"/bin/x">>, <<>>]}})
    ),
    ?assertMatch(
        {badmatch, false},
        reason(#{
            <<"account_verification">> => #{<<"command">> => [<<"/bin/x">>], <<"ttl">> => 0}
        })
    ),
    ?assertMatch(
        {badmatch, []},
        reason(#{<<"account_verification">> => #{<<"command">> => []}})
    ).

webirc_test() ->
    {ok, Config} = load(#{
        <<"webirc">> => [
            #{<<"password">> => <<"gw">>, <<"hosts">> => [<<"10.0.0.1">>, <<"::1">>]}
        ]
    }),
    ?assertEqual(
        [#{password => <<"gw">>, hosts => [{10, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]}],
        maps:get(webirc, Config)
    ),
    ?assertEqual({invalid_webirc, #{}}, reason(#{<<"webirc">> => #{}})),
    ?assertMatch(
        {badmatch, false},
        reason(#{<<"webirc">> => [#{<<"password">> => <<>>, <<"hosts">> => [<<"1.2.3.4">>]}]})
    ),
    ?assertMatch(
        {badmatch, false},
        reason(#{<<"webirc">> => [#{<<"password">> => <<"p">>, <<"hosts">> => []}]})
    ),
    ?assertMatch(
        {badmatch, {error, einval}},
        reason(#{<<"webirc">> => [#{<<"password">> => <<"p">>, <<"hosts">> => [<<"nohost">>]}]})
    ),
    ?assertMatch({badkey, <<"hosts">>}, reason(#{<<"webirc">> => [#{<<"password">> => <<"p">>}]})).

admin_text_test() ->
    {ok, Config} = load(#{
        <<"admin_name">> => <<"Root">>,
        <<"admin_email">> => <<"r@example.org">>,
        <<"server_info">> => <<"Info">>
    }),
    ?assertMatch(#{name := <<"Root">>, email := <<"r@example.org">>}, maps:get(admin, Config)),
    ?assertEqual(<<"Info">>, maps:get(server_info, Config)),
    ?assertEqual(
        {invalid_text_setting, <<"admin_location1">>}, reason(#{<<"admin_location1">> => <<>>})
    ),
    ?assertEqual({invalid_text_setting, <<"server_info">>}, reason(#{<<"server_info">> => 1})).

operators_test() ->
    ?assertMatch(
        {badmatch, false},
        reason(#{<<"operators">> => [#{<<"name">> => <<>>, <<"password">> => <<"p">>}]})
    ),
    ?assertMatch(
        {badmatch, false},
        reason(#{<<"operators">> => [#{<<"name">> => <<"o">>, <<"password">> => <<>>}]})
    ),
    ?assertMatch(
        {badmatch, false},
        reason(#{
            <<"operators">> => [
                #{<<"name">> => <<"Op">>, <<"password">> => <<"a">>},
                #{<<"name">> => <<"op">>, <<"password">> => <<"b">>}
            ]
        })
    ),
    ?assertMatch(function_clause, reason(#{<<"operators">> => #{}})),
    ?assertEqual(
        {duplicate_administrator, <<"same">>},
        reason(#{
            <<"operators">> => [#{<<"name">> => <<"Same">>, <<"password">> => <<"a">>}],
            <<"administrators">> => [#{<<"nick">> => <<"same">>, <<"password">> => <<"b">>}]
        })
    ).

administrators_test() ->
    ?assertEqual({invalid_administrators, 1}, reason(#{<<"administrators">> => 1})),
    ?assertEqual({invalid_administrator, invalid}, reason(#{<<"administrators">> => [1]})),
    ?assertEqual(
        {invalid_administrator, <<"9bad">>},
        reason(#{<<"administrators">> => [#{<<"nick">> => <<"9bad">>, <<"password">> => <<"p">>}]})
    ),
    ?assertEqual(
        {invalid_administrator, undefined},
        reason(#{<<"administrators">> => [#{<<"password">> => <<"p">>}]})
    ),
    ?assertEqual(
        {invalid_administrator, <<"adm">>},
        reason(#{<<"administrators">> => [#{<<"nick">> => <<"adm">>, <<"password">> => <<>>}]})
    ),
    ?assertEqual(
        {invalid_administrator, <<"adm">>},
        reason(#{<<"administrators">> => [#{<<"nick">> => <<"adm">>}]})
    ).

channels_test() ->
    ?assertEqual({invalid_channels, <<"#a">>}, reason(#{<<"channels">> => <<"#a">>})),
    ?assertEqual({invalid_channel, invalid}, reason(#{<<"channels">> => [<<"#a">>]})),
    ?assertEqual({invalid_channel, <<"nohash">>}, chan(#{<<"name">> => <<"nohash">>})),
    ?assertEqual({invalid_channel, <<"!ABCDEroom">>}, chan(#{<<"name">> => <<"!ABCDEroom">>})),
    ?assertEqual({invalid_channel, invalid}, chan(#{})),
    ?assertEqual({invalid_channel, invalid}, chan(#{<<"name">> => binary:copy(<<"#">>, 60)})),
    ?assertEqual({invalid_channel, invalid}, chan(#{<<"name">> => 5})),
    ?assertEqual(
        {duplicate_channel, <<"#B">>},
        reason(#{<<"channels">> => [#{<<"name">> => <<"#b">>}, #{<<"name">> => <<"#B">>}]})
    ),
    Name = #{<<"name">> => <<"#c">>},
    ?assertEqual({invalid_channel_topic, invalid}, chan(Name#{<<"topic">> => <<"a\nb">>})),
    ?assertEqual(
        {invalid_channel_topic, invalid}, chan(Name#{<<"topic">> => binary:copy(<<"t">>, 391)})
    ),
    ?assertEqual({invalid_channel_topic, invalid}, chan(Name#{<<"topic">> => 1})),
    ?assertEqual({invalid_channel_key, invalid}, chan(Name#{<<"key">> => <<"a b">>})),
    ?assertEqual({invalid_channel_key, invalid}, chan(Name#{<<"key">> => <<>>})),
    ?assertEqual({invalid_channel_key, invalid}, chan(Name#{<<"key">> => 1})),
    ?assertEqual({invalid_channel_limit, 0}, chan(Name#{<<"limit">> => 0})),
    ?assertEqual({invalid_channel_limit, <<"5">>}, chan(Name#{<<"limit">> => <<"5">>})),
    ?assertEqual({invalid_channel_modes, <<"-n">>}, chan(Name#{<<"modes">> => <<"-n">>})),
    ?assertEqual({invalid_channel_modes, invalid}, chan(Name#{<<"modes">> => 1})),
    ?assertEqual(
        {invalid_channel_modes, invalid}, chan(Name#{<<"modes">> => binary:copy(<<"n">>, 17)})
    ),
    %% `a` (anonymous) is defined only for local `&` channels (RFC 2811 4.2.1).
    ?assertEqual({invalid_channel_modes, $a}, chan(Name#{<<"modes">> => <<"a">>})),
    ?assertEqual({invalid_channel_modes, $z}, chan(Name#{<<"modes">> => <<"z">>})),
    ?assertEqual({invalid_channel_modes, $n}, chan(Name#{<<"modes">> => <<"nn">>})),
    %% Private and secret are mutually exclusive (RFC 2811 4.2.6).
    ?assertEqual({invalid_channel_modes, $s}, chan(Name#{<<"modes">> => <<"ps">>})),
    ?assertEqual({invalid_channel_modes, $p}, chan(Name#{<<"modes">> => <<"sp">>})),
    {ok, Config} = load(#{
        <<"channels">> => [
            Name#{<<"modes">> => <<"+imqK">>, <<"limit">> => 2147483647, <<"key">> => <<"k">>}
        ]
    }),
    [Entry] = maps:get(channels, Config),
    ?assertEqual(#{$i => true, $m => true, $q => true, $K => true}, maps:get(flags, Entry)),
    ?assertEqual(2147483647, maps:get(limit, Entry)).

chan(Entry) ->
    reason(#{<<"channels">> => [Entry]}).

server_links_test() ->
    Link = #{
        <<"name">> => <<"peer.example">>,
        <<"host">> => <<"127.0.0.1">>,
        <<"port">> => 6667,
        <<"password">> => <<"secret">>
    },
    {ok, Config} = load(#{<<"server_links">> => [Link#{<<"tls">> => true}]}),
    ?assertMatch([#{name := <<"peer.example">>, tls := true}], maps:get(server_links, Config)),
    ?assertMatch({badmatch, nomatch}, link_reason(Link#{<<"name">> => <<"bad name">>})),
    ?assertMatch({badmatch, true}, link_reason(Link#{<<"name">> => <<"IRC.LOCAL">>})),
    ?assertMatch({badmatch, false}, link_reason(Link#{<<"host">> => <<"a b">>})),
    ?assertMatch({badmatch, false}, link_reason(Link#{<<"host">> => <<>>})),
    ?assertMatch({badmatch, false}, link_reason(Link#{<<"port">> => 0})),
    ?assertMatch({badmatch, false}, link_reason(Link#{<<"port">> => 65536})),
    ?assertMatch({badmatch, false}, link_reason(Link#{<<"password">> => <<>>})),
    ?assertMatch(
        {badmatch, false}, link_reason(Link#{<<"password">> => binary:copy(<<"p">>, 401)})
    ),
    ?assertMatch({badmatch, false}, link_reason(Link#{<<"tls">> => <<"yes">>})),
    ?assertMatch({badkey, <<"host">>}, link_reason(maps:remove(<<"host">>, Link))),
    ?assertMatch(
        {badmatch, false},
        reason(#{<<"server_links">> => [Link, Link#{<<"name">> => <<"PEER.example">>}]})
    ),
    ?assertMatch(function_clause, reason(#{<<"server_links">> => #{}})).

link_reason(Entry) ->
    reason(#{<<"server_links">> => [Entry]}).

%%% briskd_wire

parse_test() ->
    ?assertEqual({ok, <<"PING">>, [<<"x">>]}, briskd_wire:parse(<<"PING x\r\n">>)),
    ?assertEqual(error, briskd_wire:parse(<<"@a=b PING x\r\n">>)),
    ?assertEqual(
        error, briskd_wire:parse(<<"PRIVMSG x :", (binary:copy(<<"a">>, 520))/binary, "\r\n">>)
    ),
    ?assertEqual(empty, briskd_wire:parse(<<"\r\n">>)),
    ?assertEqual(error, briskd_wire:parse(<<":nick PRIVMSG x :hi\r\n">>)).

frame_test() ->
    %% Missing CRLF, bare CR/LF, NUL, too short and beyond the read cap.
    ?assertEqual(error, briskd_wire:parse_client(<<"PING x">>)),
    ?assertEqual(error, briskd_wire:parse_client(<<"PING x\n">>)),
    ?assertEqual(error, briskd_wire:parse_client(<<"PI\rNG\r\n">>)),
    ?assertEqual(error, briskd_wire:parse_client(<<"PI\nNG\r\n">>)),
    ?assertEqual(error, briskd_wire:parse_client(<<"PI", 0, "NG\r\n">>)),
    ?assertEqual(error, briskd_wire:parse_client(<<"\n">>)),
    ?assertEqual(error, briskd_wire:parse_client(<<>>)),
    ?assertEqual(error, briskd_wire:parse_client(binary:copy(<<"a">>, 9000))),
    ?assertEqual(error, briskd_wire:parse_client(not_binary)),
    ?assertEqual(empty, briskd_wire:parse_client(<<"\r\n">>)),
    ?assertEqual(error, briskd_wire:parse_client(<<"PR!V x\r\n">>)),
    ?assertEqual(error, briskd_wire:parse_client(<<" PING\r\n">>)).

line_length_test() ->
    %% 512 octets including CRLF is accepted; 513 is numeric 417 for clients.
    Fill = fun(N) -> binary:copy(<<"a">>, N) end,
    Ok = <<"PRIVMSG x :", (Fill(510 - 11))/binary, "\r\n">>,
    ?assertEqual(512, byte_size(Ok)),
    ?assertMatch({ok, [], <<"PRIVMSG">>, [<<"x">>, _]}, briskd_wire:parse_client(Ok)),
    Long = <<"PRIVMSG x :", (Fill(511 - 11))/binary, "\r\n">>,
    ?assertEqual({error, input_too_long, []}, briskd_wire:parse_client(Long)),
    ?assertEqual(error, briskd_wire:parse_server(Long)).

tags_test() ->
    Tag = fun(N) -> <<"@k=", (binary:copy(<<"v">>, N))/binary>> end,
    %% Tag data (without '@') of exactly ?MAX_TAG_DATA bytes is allowed.
    Max = <<(Tag(?MAX_TAG_DATA - 2))/binary, " PING x\r\n">>,
    ?assertMatch({ok, [{<<"k">>, _}], <<"PING">>, [<<"x">>]}, briskd_wire:parse_client(Max)),
    Over = <<(Tag(?MAX_TAG_DATA - 1))/binary, " PING x\r\n">>,
    ?assertMatch({error, input_too_long, [{<<"k">>, _}]}, briskd_wire:parse_client(Over)),
    ?assertEqual(error, briskd_wire:parse_server(Over)),
    %% Tags alone without a command: oversize is 417, short is malformed.
    ?assertEqual(
        {error, input_too_long, []}, briskd_wire:parse_client(<<(Tag(5000))/binary, "\r\n">>)
    ),
    ?assertEqual(error, briskd_wire:parse_client(<<"@a=b\r\n">>)),
    %% Tagged line with a body over 512 octets.
    Body = <<"PRIVMSG x :", (binary:copy(<<"a">>, 510))/binary>>,
    ?assertMatch(
        {error, input_too_long, _}, briskd_wire:parse_client(<<"@a ", Body/binary, "\r\n">>)
    ),
    %% Client prefix after tags is spoofing and rejected.
    ?assertEqual(error, briskd_wire:parse_client(<<"@a=b :evil PING x\r\n">>)),
    %% Empty tags, duplicate keys (last wins, first position), escapes.
    ?assertEqual(
        {ok, [{<<"a">>, <<"2">>}, {<<"b">>, undefined}, {<<"c">>, <<"; \\\r\nzq">>}], <<"PING">>,
            []},
        briskd_wire:parse_client(<<"@a=1;;b=;a=2;c=\\:\\s\\\\\\r\\n\\zq\\ PING\r\n">>)
    ),
    %% A tagged line whose command part is empty.
    ?assertEqual(empty, briskd_wire:parse_client(<<"@a \r\n">>)).

parse_server_test() ->
    ?assertEqual(
        {ok, [], <<"peer">>, <<"NICK">>, [<<"n">>]},
        briskd_wire:parse_server(<<":peer NICK n\r\n">>)
    ),
    ?assertEqual(
        {ok, [{<<"t">>, undefined}], undefined, <<"PING">>, [<<"x">>]},
        briskd_wire:parse_server(<<"@t PING x\r\n">>)
    ),
    ?assertEqual(error, briskd_wire:parse_server(<<": NICK n\r\n">>)),
    ?assertEqual(error, briskd_wire:parse_server(<<":peer \r\n">>)),
    ?assertEqual(error, briskd_wire:parse_server(<<":peer N!CK\r\n">>)),
    ?assertEqual(empty, briskd_wire:parse_server(<<"\r\n">>)),
    ?assertEqual(error, briskd_wire:parse_server(<<"N!CK\r\n">>)),
    ?assertEqual(error, briskd_wire:parse_server(<<"PING">>)).

params_test() ->
    %% Trailing space, multiple spaces, empty trailing parameter.
    ?assertEqual({ok, [], <<"MODE">>, [<<"a">>]}, briskd_wire:parse_client(<<"mode a \r\n">>)),
    ?assertEqual(
        {ok, [], <<"MODE">>, [<<"a">>, <<"b">>]}, briskd_wire:parse_client(<<"MODE a  b\r\n">>)
    ),
    ?assertEqual(
        {ok, [], <<"TOPIC">>, [<<"#a">>, <<>>]}, briskd_wire:parse_client(<<"TOPIC #a :\r\n">>)
    ),
    ?assertEqual(
        {ok, [], <<"PRIVMSG">>, [<<"#a">>, <<"hi : there">>]},
        briskd_wire:parse_client(<<"PRIVMSG #a :hi : there\r\n">>)
    ),
    Words = fun(N) -> lists:join(<<" ">>, [integer_to_binary(I) || I <- lists:seq(1, N)]) end,
    {ok, [], <<"X">>, Fifteen} = briskd_wire:parse_client(
        iolist_to_binary([<<"X ">>, Words(15), <<"\r\n">>])
    ),
    ?assertEqual(15, length(Fifteen)),
    %% A 16th parameter is folded into the 15th (RFC 2812 2.3.1).
    {ok, [], <<"X">>, Sixteen} = briskd_wire:parse_client(
        iolist_to_binary([<<"X ">>, Words(16), <<"\r\n">>])
    ),
    ?assertEqual(15, length(Sixteen)),
    ?assertEqual(<<"15 16">>, lists:last(Sixteen)),
    {ok, [], <<"X">>, Colon} = briskd_wire:parse_client(
        iolist_to_binary([<<"X ">>, Words(14), <<" :a b\r\n">>])
    ),
    ?assertEqual(<<"a b">>, lists:last(Colon)).

partial_and_pending_test() ->
    ?assertEqual(ok, briskd_wire:partial(<<"PING">>)),
    ?assertEqual(ok, briskd_wire:partial(<<"PING\r">>)),
    ?assertEqual(error, briskd_wire:partial(<<"PI\rNG">>)),
    ?assertEqual(error, briskd_wire:partial(<<"PING\n">>)),
    ?assertEqual(error, briskd_wire:partial(binary:copy(<<"a">>, ?MAX_WIRE_LINE))),
    ?assertEqual({ok, <<"ab">>}, briskd_wire:append_pending(<<"a">>, <<"b">>)),
    ?assertEqual(
        error, briskd_wire:append_pending(binary:copy(<<"a">>, ?MAX_PENDING_BYTES), <<"b">>)
    ).

encode_test() ->
    ?assertEqual(
        <<":srv PRIVMSG #a :hi\r\n">>,
        iolist_to_binary(briskd_wire:line(<<"srv">>, <<"PRIVMSG">>, [<<"#a">>], <<"hi">>))
    ),
    ?assertEqual(
        <<":srv PING x\r\n">>,
        iolist_to_binary(briskd_wire:line(<<"srv">>, <<"PING">>, [<<"x">>], none))
    ),
    %% Oversized head: the line is dropped rather than split.
    Big = binary:copy(<<"m">>, 520),
    ?assertEqual([], briskd_wire:line(<<"srv">>, <<"X">>, [Big], none)),
    ?assertEqual([], briskd_wire:line(<<"srv">>, <<"X">>, [binary:copy(<<"m">>, 503)], <<"t">>)),
    %% A long trailing parameter is truncated to fit 512 octets.
    Cut = iolist_to_binary(briskd_wire:line(<<"srv">>, <<"X">>, [], Big)),
    ?assertEqual(512, byte_size(Cut)),
    ?assertEqual(
        <<"@a=x\\:\\s\\\\\\r\\n;b :srv X\r\n">>,
        iolist_to_binary(
            briskd_wire:message(
                [{<<"a">>, <<"x; \\\r\n">>}, {<<"b">>, undefined}], <<"srv">>, <<"X">>, [], none
            )
        )
    ),
    ?assertEqual(
        <<":srv X\r\n">>, iolist_to_binary(briskd_wire:message([], <<"srv">>, <<"X">>, [], none))
    ).

fold_and_names_test() ->
    ?assertEqual(<<"{}|~abc">>, briskd_wire:fold(<<"[]\\^ABC">>)),
    ?assertEqual(<<"{}|~">>, briskd_wire:fold(<<"{}|~">>)),
    ?assert(briskd_wire:nickname(<<"[a]\\^_`{|}-1">>, 30)),
    ?assert(briskd_wire:nickname(<<"[a]\\^_`{|">>)),
    ?assertNot(briskd_wire:nickname(<<"1abc">>)),
    ?assertNot(briskd_wire:nickname(<<"-abc">>)),
    ?assertNot(briskd_wire:nickname(<<"abcdefghij">>)),
    ?assert(briskd_wire:nickname(<<"abcdefghij">>, 10)),
    ?assertNot(briskd_wire:nickname(<<"a b">>)),
    ?assertNot(briskd_wire:nickname(undefined)),
    ?assertEqual(<<"x">>, briskd_wire:retain(<<"x">>)),
    ?assertEqual(5, briskd_wire:retain(5)),
    lists:foreach(fun(Name) -> ?assert(briskd_wire:channel(Name)) end, [
        <<"#a">>,
        <<"&local">>,
        <<"+modeless">>,
        <<"!ABC12safe">>,
        <<"#", (binary:copy(<<"x">>, 49))/binary>>
    ]),
    lists:foreach(fun(Name) -> ?assertNot(briskd_wire:channel(Name)) end, [
        <<"#">>,
        <<"#", (binary:copy(<<"x">>, 50))/binary>>,
        <<"#a b">>,
        <<"#a,b">>,
        <<"#a:b">>,
        <<"#a", 7>>,
        <<"a">>,
        <<>>,
        <<"!abcdeX">>,
        <<"!ABCDE">>,
        <<"!AB">>,
        <<"!ABCDE", (binary:copy(<<"x">>, 45))/binary>>,
        <<"!ABCDEa b">>
    ]),
    ?assertNot(briskd_wire:safe_channel(<<"#ABCDEx">>)).

%%% briskd_log

log_detail_test() ->
    ?assertEqual(ok, briskd_log:server_command(<<"peer">>, <<"PONG">>, [])),
    ?assertEqual(ok, briskd_log:server_command(<<"peer">>, <<"PING">>, [])),
    ?assertEqual(ok, briskd_log:server_command(<<"peer">>, <<"NICK">>, [<<"n">>])),
    ?assertEqual(ok, briskd_log:client_command(<<"n">>, <<"PONG">>, [])),
    ?assertEqual(<<>>, briskd_log:command_detail(<<"OPER">>, [])),
    ?assertEqual(<<"name">>, briskd_log:command_detail(<<"OPER">>, [<<"name">>, <<"pw">>])),
    ?assertEqual(<<>>, briskd_log:command_detail(<<"KICK">>, [])),
    ?assertEqual(<<"#c">>, briskd_log:command_detail(<<"KICK">>, [<<"#c">>])),
    ?assertEqual(<<"redacted">>, briskd_log:command_detail(<<"PASS">>, [<<"pw">>])),
    ?assertEqual(
        <<"#c +k">>, briskd_log:command_detail(<<"MODE">>, [<<"#c">>, <<"+k">>, <<"key">>])
    ),
    ?assertEqual(<<>>, briskd_log:command_detail(<<"AWAY">>, [<<"gone">>])),
    ?assertEqual(<<>>, briskd_log:command_detail(<<"OTHER">>, [<<"x">>])).

log_format_test() ->
    Event = #{
        level => info,
        meta => #{time => 7},
        msg =>
            {report, #{
                event => test,
                <<"bin">> => <<"v">>,
                {tuple, key} => 1,
                nested => #{<<"k">> => [1, 2], inner => #{x => self()}},
                bad => <<255>>,
                list => "text",
                improper => improper(a, b),
                float => 1.5
            }}
    },
    Decoded = json:decode(iolist_to_binary(briskd_log:format(Event, #{}))),
    ?assertEqual(<<"v">>, maps:get(<<"bin">>, Decoded)),
    ?assertEqual(1, maps:get(<<"{tuple,key}">>, Decoded)),
    ?assertMatch(
        #{<<"k">> := [1, 2], <<"inner">> := #{<<"x">> := _}}, maps:get(<<"nested">>, Decoded)
    ),
    ?assertMatch(<<"<<", _/binary>>, maps:get(<<"bad">>, Decoded)),
    ?assertEqual(<<"text">>, maps:get(<<"list">>, Decoded)),
    ?assertEqual(<<"[a|b]">>, maps:get(<<"improper">>, Decoded)),
    ?assertEqual(7, maps:get(<<"time">>, Decoded)),
    Plain = json:decode(
        iolist_to_binary(
            briskd_log:format(#{level => info, meta => #{time => 1}, msg => {"x=~p", [1]}}, #{})
        )
    ),
    ?assertEqual(<<"x=1">>, maps:get(<<"message">>, Plain)),
    ?assertMatch({logger_formatter, #{single_line := true}}, briskd_log:formatter(<<"text">>)),
    ?assertEqual({briskd_log, #{}}, briskd_log:formatter(<<"json">>)).

%%% briskd_cap

with_cap(Config, Fun) ->
    case ets:whereis(briskd_caps) of
        undefined -> ets:new(briskd_caps, [named_table, public, set]);
        _ -> ok
    end,
    Previous = persistent_term:get({briskd_state, config}, undefined),
    persistent_term:put({briskd_state, config}, Config),
    Pid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    try
        Fun(Pid)
    after
        briskd_cap:disconnect(Pid),
        Pid ! stop,
        case Previous of
            undefined -> persistent_term:erase({briskd_state, config});
            _ -> persistent_term:put({briskd_state, config}, Previous)
        end
    end.

cap_unknown_connection_test() ->
    with_cap(#{}, fun(Pid) ->
        %% No row: the initial state is returned, nothing is enabled.
        ?assertMatch(#{version := 0, welcomed := false}, briskd_cap:state(Pid)),
        ?assertNot(briskd_cap:enabled(Pid, <<"batch">>)),
        ?assertEqual(#{}, briskd_cap:info(Pid))
    end).

cap_versions_and_requests_test() ->
    with_cap(#{}, fun(Pid) ->
        true = briskd_cap:connect(Pid),
        ok = briskd_cap:note_ls(Pid, [<<"LS">>, <<"0">>]),
        ok = briskd_cap:note_ls(Pid, [<<"LS">>, <<"abc">>]),
        ok = briskd_cap:note_ls(Pid, [<<"LS">>, <<"301">>]),
        ok = briskd_cap:note_ls(Pid, [<<"LS">>]),
        ?assertMatch(#{version := 0}, briskd_cap:state(Pid)),
        %% A bare `-` names no capability: the whole request is NAKed.
        ?assertEqual({nak, <<"-">>}, briskd_cap:request(Pid, [<<"-">>])),
        ?assertEqual({ack, <<"batch">>}, briskd_cap:request(Pid, [<<"batch">>])),
        ?assertEqual({ack, <<"-batch">>}, briskd_cap:request(Pid, [<<"-batch">>])),
        ok = briskd_cap:note_ls(Pid, [<<"LS">>, <<"302">>]),
        ?assertEqual({nak, <<"-cap-notify">>}, briskd_cap:request(Pid, [<<"-cap-notify">>]))
    end).

cap_values_test() ->
    Config = #{
        sts => #{port => 6697, duration => 60, preload => true},
        account_registration_before_connect => false,
        account_registration_email_required => true
    },
    with_cap(Config, fun(Pid) ->
        true = briskd_cap:connect(Pid, #{secure => true}),
        Advertised = briskd_cap:advertised(Pid),
        ?assertEqual(
            {<<"sts">>, <<"duration=60,preload">>}, lists:keyfind(<<"sts">>, 1, Advertised)
        ),
        {_, <<_/binary>> = Registration} =
            lists:keyfind(<<"draft/account-registration">>, 1, Advertised),
        ?assertEqual(nomatch, binary:match(Registration, <<"before-connect">>)),
        ?assertNotEqual(nomatch, binary:match(Registration, <<"email-required">>))
    end).

%%% briskd_isupport

isupport_empty_tokens_test() ->
    Client = #client{pid = self(), host = <<"h">>},
    ?assertEqual(ok, briskd_isupport:send_tokens(Client, <<"srv">>, [], false)),
    receive
        Unexpected -> ?assertEqual(nothing, Unexpected)
    after 0 -> ok
    end.

%% An improper list ([a | b]); the log formatter must render it. Built here
%% because a typed literal cannot be improper.
improper(Head, Tail) ->
    [Head | Tail].
