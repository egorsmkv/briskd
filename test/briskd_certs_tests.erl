-module(briskd_certs_tests).
-include_lib("eunit/include/eunit.hrl").

%% TLS certificate reload (briskd_certs): pair validation, live reload of the
%% tls listener and STARTTLS after a renewal, rejection of a bad pair, and the
%% tls_reload_interval configuration range.

%%% Pair validation

validate_pair_test_() ->
    {timeout, 60, fun validate_pair/0}.

validate_pair() ->
    Dir = tmp_dir("briskd-certs-pair"),
    {RsaCert, RsaKey} = write_pair(Dir, "rsa", {rsa, 2048, 65537}),
    {EcCert, EcKey} = write_pair(Dir, "ec", {namedCurve, secp256r1}),
    {ok, #{names := Names, not_after := NotAfter}} = briskd_certs:validate_pair(RsaCert, RsaKey),
    ?assert(byte_size(Names) > 0),
    %% ISO 8601 UTC, e.g. 2027-01-31T12:00:00Z.
    ?assertMatch(<<_:4/binary, "-", _:2/binary, "-", _:2/binary, "T", _:8/binary, "Z">>, NotAfter),
    ?assertMatch({ok, _}, briskd_certs:validate_pair(EcCert, EcKey)),
    %% A certificate with another key's private key is refused.
    {_, OtherRsaKey} = write_pair(Dir, "rsa2", {rsa, 2048, 65537}),
    ?assertEqual({error, key_mismatch}, briskd_certs:validate_pair(RsaCert, OtherRsaKey)),
    {_, OtherEcKey} = write_pair(Dir, "ec2", {namedCurve, secp256r1}),
    ?assertEqual({error, key_mismatch}, briskd_certs:validate_pair(EcCert, OtherEcKey)),
    %% A key of the other type is a mismatch too.
    ?assertEqual({error, key_mismatch}, briskd_certs:validate_pair(EcCert, RsaKey)),
    ?assertEqual({error, key_mismatch}, briskd_certs:validate_pair(RsaCert, EcKey)),
    %% Missing, empty, and key-only files.
    ?assertMatch(
        {error, {unreadable, _, enoent}},
        briskd_certs:validate_pair(filename:join(Dir, "missing.pem"), RsaKey)
    ),
    Empty = filename:join(Dir, "empty.pem"),
    ok = file:write_file(Empty, <<>>),
    ?assertMatch({error, {no_certificate, _}}, briskd_certs:validate_pair(Empty, RsaKey)),
    ?assertMatch({error, {no_key, _}}, briskd_certs:validate_pair(RsaCert, RsaCert)).

%%% Live reload

reload_test_() ->
    {timeout, 120, fun reload/0}.

reload() ->
    Dir = tmp_dir("briskd-certs-live"),
    CertFile = filename:join(Dir, "fullchain.pem"),
    KeyFile = filename:join(Dir, "privkey.pem"),
    {CertA, KeyA} = make_pair({rsa, 2048, 65537}),
    {CertB, KeyB} = make_pair({namedCurve, secp256r1}),
    install(CertFile, KeyFile, CertA, KeyA),
    ok = filelib:ensure_dir(filename:join(Dir, "db/x")),
    Config = filename:join(Dir, "briskd.json"),
    ok = file:write_file(Config, config(Dir, CertFile, KeyFile)),
    application:stop(briskd),
    os:putenv("BRISKD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(briskd),
    try
        ?assertEqual(CertA, server_cert(listener_port(tls))),
        ?assertEqual(unchanged, briskd_certs:check_now()),
        %% An established TLS session outlives the reload.
        Kept = tls_client(listener_port(tls), <<"keeper">>),
        %% A renewal written halfway (new certificate, old key) is refused and
        %% the old certificate stays in use.
        install(CertFile, KeyFile, CertB, KeyA),
        ?assertEqual({error, key_mismatch}, briskd_certs:check_now()),
        ?assertEqual(CertA, server_cert(listener_port(tls))),
        %% The complete renewal is loaded: new handshakes see it.
        install(CertFile, KeyFile, CertB, KeyB),
        ?assertEqual(reloaded, briskd_certs:check_now()),
        ?assertEqual(CertB, server_cert(listener_port(tls))),
        ?assertEqual(CertB, starttls_cert(listener_port(tcp))),
        ?assertEqual(unchanged, briskd_certs:check_now()),
        ok = ssl:send(Kept, <<"PING :still-here\r\n">>),
        ?assert(has(ssl_recv_until(Kept, <<"still-here">>), <<"PONG">>)),
        ssl:close(Kept)
    after
        _ = application:stop(briskd),
        os:unsetenv("BRISKD_CONFIG")
    end.

config(Dir, CertFile, KeyFile) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":0,">>,
        <<"\"certfile\":\"">>,
        CertFile,
        <<"\",\"keyfile\":\"">>,
        KeyFile,
        <<"\",\"tls_reload_interval\":3600,\"log_level\":\"error\",\"log_format\":\"text\",">>,
        <<"\"mnesia_dir\":\"">>,
        filename:join(Dir, "db"),
        <<"\"}">>
    ]).

%%% Configuration

tls_reload_interval_config_test() ->
    Load = fun(Value) ->
        Path = filename:join(
            "/tmp", "briskd-tlsint-" ++ integer_to_list(erlang:system_time(nanosecond)) ++ ".json"
        ),
        ok = file:write_file(Path, [<<"{\"tcp_port\":6667">>, Value, <<"}">>]),
        try
            briskd_config:load(Path)
        after
            file:delete(Path)
        end
    end,
    ?assertMatch({ok, #{tls_reload_interval := 60}}, Load(<<>>)),
    ?assertMatch({ok, #{tls_reload_interval := 0}}, Load(<<",\"tls_reload_interval\":0">>)),
    ?assertMatch({ok, #{tls_reload_interval := 5}}, Load(<<",\"tls_reload_interval\":5">>)),
    ?assertMatch(
        {ok, #{tls_reload_interval := 86400}}, Load(<<",\"tls_reload_interval\":86400">>)
    ),
    ?assertMatch({error, _}, Load(<<",\"tls_reload_interval\":4">>)),
    ?assertMatch({error, _}, Load(<<",\"tls_reload_interval\":86401">>)),
    ?assertMatch({error, _}, Load(<<",\"tls_reload_interval\":\"60\"">>)).

watcher_only_with_tls_test_() ->
    {timeout, 60, fun watcher_only_with_tls/0}.

watcher_only_with_tls() ->
    Dir = tmp_dir("briskd-certs-notls"),
    ok = filelib:ensure_dir(filename:join(Dir, "db/x")),
    Config = filename:join(Dir, "briskd.json"),
    ok = file:write_file(
        Config,
        iolist_to_binary([
            <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,">>,
            <<"\"log_level\":\"error\",\"mnesia_dir\":\"">>,
            filename:join(Dir, "db"),
            <<"\"}">>
        ])
    ),
    application:stop(briskd),
    os:putenv("BRISKD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(briskd),
    try
        ?assertEqual(undefined, whereis(briskd_certs)),
        %% REHASH's hook is a no-op without the watcher.
        ?assertEqual(ok, briskd_certs:check_async())
    after
        _ = application:stop(briskd),
        os:unsetenv("BRISKD_CONFIG")
    end.

%%% Helpers

tmp_dir(Prefix) ->
    Dir = filename:join("/tmp", Prefix ++ "-" ++ integer_to_list(erlang:system_time(nanosecond))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

make_pair(Key) ->
    #{server_config := Conf} = public_key:pkix_test_data(#{
        server_chain => #{
            root => [{digest, sha256}, {key, Key}],
            peer => [{digest, sha256}, {key, Key}]
        },
        client_chain => #{
            root => [{digest, sha256}, {key, {rsa, 2048, 65537}}],
            peer => [{digest, sha256}, {key, {rsa, 2048, 65537}}]
        }
    }),
    {_, Cert} = lists:keyfind(cert, 1, Conf),
    {_, {KeyType, KeyDer}} = lists:keyfind(key, 1, Conf),
    {Cert, {KeyType, KeyDer}}.

write_pair(Dir, Name, Key) ->
    {Cert, KeyEntry} = make_pair(Key),
    CertFile = filename:join(Dir, Name ++ ".crt"),
    KeyFile = filename:join(Dir, Name ++ ".key"),
    install(CertFile, KeyFile, Cert, KeyEntry),
    {CertFile, KeyFile}.

%% Write both files the way the lego deploy script does: a temporary file,
%% then rename, so a reader never sees half a file.
install(CertFile, KeyFile, Cert, {KeyType, KeyDer}) ->
    atomic_write(CertFile, public_key:pem_encode([{'Certificate', Cert, not_encrypted}])),
    atomic_write(KeyFile, public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])).

atomic_write(File, Data) ->
    Tmp = File ++ ".tmp",
    ok = file:write_file(Tmp, Data),
    ok = file:rename(Tmp, File).

server_cert(Port) ->
    {ok, S} = ssl:connect("127.0.0.1", Port, client_options(), 5000),
    {ok, Der} = ssl:peercert(S),
    ssl:close(S),
    Der.

starttls_cert(Port) ->
    {ok, Tcp} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Tcp, <<"STARTTLS\r\n">>),
    _ = tcp_recv_until(Tcp, <<" 670 ">>, <<>>),
    {ok, S} = ssl:connect(Tcp, client_options(), 5000),
    {ok, Der} = ssl:peercert(S),
    ssl:close(S),
    Der.

tls_client(Port, Nick) ->
    {ok, S} = ssl:connect("127.0.0.1", Port, client_options(), 5000),
    ok = ssl:send(S, [<<"NICK ">>, Nick, <<"\r\nUSER ">>, Nick, <<" 0 * :T\r\n">>]),
    _ = ssl_recv_until(S, <<" 001 ">>),
    S.

client_options() ->
    [binary, {active, false}, {verify, verify_none}, {versions, ['tlsv1.3', 'tlsv1.2']}].

ssl_recv_until(S, Needle) ->
    ssl_recv_until(S, Needle, <<>>).

ssl_recv_until(S, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            {ok, <<_/binary>> = Data} = ssl:recv(S, 0, 5000),
            ssl_recv_until(S, Needle, <<Acc/binary, Data/binary>>);
        _ ->
            Acc
    end.

tcp_recv_until(S, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            {ok, <<_/binary>> = Data} = gen_tcp:recv(S, 0, 5000),
            tcp_recv_until(S, Needle, <<Acc/binary, Data/binary>>);
        _ ->
            Acc
    end.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

listener_port(Kind) ->
    {_, Pid, _, _} = lists:keyfind(Kind, 1, supervisor:which_children(briskd_sup)),
    {ok, {_, Port}} =
        case Kind of
            tcp -> inet:sockname(sys:get_state(Pid));
            tls -> ssl:sockname(sys:get_state(Pid))
        end,
    Port.
