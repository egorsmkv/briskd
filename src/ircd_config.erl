-module(ircd_config).
-moduledoc """
Loads and validates the JSON server configuration.

`load/1` reads one JSON file, fills in defaults, validates every key, and
returns one normalized map. `m:ircd_app` loads the file named by the
`IRCD_CONFIG` environment variable (default `config/ircd.json`) at startup,
and `REHASH` reloads the same path. Any missing required value, wrong type,
or out-of-range value rejects the whole file: the server does not start, and
a rejected `REHASH` keeps the running configuration. Paths are relative to the
process working directory unless absolute.

The keys, their defaults, and their meaning are listed in the configuration
table in the [Configuration guide](configuration.html). Notable checks:

- At least one of `tcp_port`, `tls_port`, `ws_port`, and `wss_port` is set.
  Ports are 0 to 65535, and `0` binds an ephemeral port.
- With `tls_port` or `wss_port`, `certfile` and `keyfile` are required. The
  TLS listeners allow TLS 1.2 and 1.3 and request an optional client
  certificate, which is not verified against any CA and serves only as a
  SHA-256 fingerprint for SASL EXTERNAL.
- `name` and each `server_links` name are host-like tokens of at most 63
  characters; a link may not use this server's name, and link names are
  unique under `ircd_wire:fold/1`.
- Operator and administrator account names must be distinct.

The module also provides `secret_match/2` for comparing configured passwords.
""".
-export([
    current/0,
    current_or_empty/0,
    load/1,
    parse_log_level/1,
    secret_match/2,
    store/1,
    base/0,
    store_base/1
]).

%% The configuration load/1 returns. Every key is always present; optional
%% sections are `null` when unset (a predefined channel's password and limit
%% use `undefined`).
-type port_or_null() :: null | inet:port_number().

-type config() :: #{
    %% identity and listeners
    config_path := file:filename_all(),
    name := binary(),
    network := binary(),
    network_icon := null | binary(),
    server_info := binary(),
    ip := inet:ip_address(),
    tcp := port_or_null(),
    tls := port_or_null(),
    ws := port_or_null(),
    wss := port_or_null(),
    %% [] when neither tls nor wss is set (tls_options(null, _)). Only TLS
    %% options, no socket options: STARTTLS hands them to ssl:handshake/3.
    tls_options := [ssl:tls_server_option()],
    tls_reload_interval := non_neg_integer(),
    ws_origins := null | [binary()],
    sts := sts(),
    %% logging
    level := logger:level() | trace,
    log_format := binary(),
    %% limits
    max_clients := pos_integer(),
    reop_delay := pos_integer(),
    shutdown_grace := 0..300,
    max_sendq := 100..1000000,
    max_accounts := pos_integer(),
    max_empty_channels := pos_integer(),
    empty_channel_ttl := 0..2592000,
    max_read_markers := pos_integer(),
    max_direct_conversations := pos_integer(),
    max_peer_users := pos_integer(),
    max_peer_servers := pos_integer(),
    max_peer_services := pos_integer(),
    monitor_limit := pos_integer(),
    nicklen := 9..30,
    resource_delay := 0..86400,
    history_limit := 1..10000,
    %% files and storage
    motd_file := null | string(),
    mnesia_dir := string(),
    retention := retention(),
    %% access
    client_password := null | binary(),
    operators := [credential()],
    administrators := [credential()],
    webirc := [webirc_gateway()],
    %% accounts
    account_password_min := 1..300,
    account_registration := boolean(),
    account_registration_before_connect := boolean(),
    account_registration_email_required := boolean(),
    account_verification := account_verification(),
    multiclient := boolean(),
    account_rejoin := boolean(),
    utf8_only := boolean(),
    chathistory := boolean(),
    %% channels, links, admin
    channels := [channel_entry()],
    server_links := [server_link()],
    admin := admin_info(),
    %% optional subsystems
    flood := flood(),
    dronebl := dronebl(),
    webui := webui(),
    e2ee := e2ee(),
    voice := voice(),
    files := files(),
    calls := calls(),
    features := features(),
    bots := [bot()]
}.

-type retention() :: transient | channels.

%% {Folded name or nick, Password}; operators fold `name`, administrators `nick`.
-type credential() :: {binary(), binary()}.

-type sts() ::
    null
    | #{port := 1..65535, duration := non_neg_integer(), preload := boolean()}.

-type webirc_gateway() :: #{password := binary(), hosts := [inet:ip_address(), ...]}.

-type channel_entry() :: #{
    key := binary(),
    name := binary(),
    topic := binary(),
    %% NB: channel_key/channel_limit map JSON null to `undefined`, not `null`.
    password := undefined | binary(),
    limit := undefined | 1..2147483647,
    flags := #{char() => true}
}.

-type server_link() :: #{
    name := binary(),
    host := binary(),
    port := 1..65535,
    password := binary(),
    tls := boolean()
}.

-type admin_info() :: #{
    name := binary(),
    location1 := binary(),
    location2 := binary(),
    email := binary()
}.

-type flood() ::
    null
    | #{
        lines_burst := pos_integer(),
        lines_per_second := pos_integer(),
        messages_burst := pos_integer(),
        messages_per_second := pos_integer(),
        join_burst := pos_integer(),
        join_per_minute := pos_integer(),
        nick_burst := pos_integer(),
        nick_per_minute := pos_integer(),
        register_per_minute := pos_integer()
    }.

%% Always a map: `false`/`true` are shorthands for enabled => false/true.
-type dronebl() :: #{
    enabled := boolean(),
    zone := binary(),
    timeout_ms := 100..30000,
    ban_ttl := 60..604800,
    cache_ttl := 0..86400,
    types := all | [2..255],
    skip_private := boolean(),
    max_entries := 100..1000000,
    max_in_flight := 1..1024
}.

%% `false` in JSON also becomes null.
-type webui() ::
    null
    | #{
        ip := inet:ip_address(),
        port := inet:port_number(),
        username := binary(),
        password := binary(),
        terms_url := binary(),
        privacy_url := binary()
    }.

-type e2ee() ::
    null
    | #{
        max_devices := 1..32,
        max_prekeys := 1..1000,
        queue_limit := 0..10000,
        queue_ttl := 60..7776000,
        fetch_rate := 1..1000
    }.

-type s3_bucket() :: #{
    endpoint := binary(),
    region := binary(),
    bucket := binary(),
    access_key_id := binary(),
    secret_access_key := binary(),
    max_bytes := pos_integer()
}.

%% `false` in JSON also becomes null. s3_bucket() plus max_duration.
-type voice() ::
    null
    | #{
        endpoint := binary(),
        region := binary(),
        bucket := binary(),
        access_key_id := binary(),
        secret_access_key := binary(),
        max_bytes := 1024..20971520,
        max_duration := 1..600
    }.

-type files() :: null | s3_bucket().

-type calls() ::
    null
    | #{
        rtpengine := {binary(), 1..65535},
        ring_timeout := 5..300,
        max_duration := 0..86400,
        max_calls := 1..10000,
        calls_per_minute := 1..120,
        require_account := boolean()
    }.

-type features() :: #{
    reactions := boolean(),
    replies := boolean(),
    typing := boolean(),
    editing := boolean(),
    redaction := boolean(),
    link_previews := boolean()
}.

-type account_verification() ::
    null
    | #{
        ttl := 1..86400,
        %% present when `command` was configured: absolute exe + args as strings
        command => [string(), ...],
        smtp => smtp(),
        verify_url => binary()
    }.

-type smtp() :: #{
    relay := binary(),
    port := 1..65535,
    from := binary(),
    tls := always | if_available | never,
    ssl := boolean(),
    subject := binary(),
    username := null | binary(),
    password := null | binary()
}.

-type ai_provider() :: #{
    name := binary(),
    base_url := binary(),
    api_key := undefined | binary(),
    %% name of an unset/empty api_key_env variable, else undefined
    missing_key_env := undefined | binary(),
    model := binary(),
    %% milliseconds
    timeout := pos_integer()
}.

-type bot() :: #{
    nick := binary(),
    user := binary(),
    realname := binary(),
    provider := ai_provider(),
    model := binary(),
    system_prompt := binary(),
    channels := [binary()],
    respond_to := mention | all,
    direct_messages := boolean(),
    context := conversation | channel,
    history_lines := 0..100,
    max_tokens := 1..32768,
    temperature := float(),
    max_reply_lines := 1..30,
    requests_per_minute := 1..600
}.

-export_type([
    config/0,
    channel_entry/0,
    server_link/0,
    admin_info/0,
    flood/0,
    dronebl/0,
    webui/0,
    e2ee/0,
    voice/0,
    files/0,
    calls/0,
    features/0,
    account_verification/0,
    smtp/0,
    ai_provider/0,
    bot/0
]).

-doc """
The running server's configuration, as `load/1` returned it (with the log
level and feature switches an operator may have changed since). Raises
`badarg` before `m:ircd_state` has stored it.
""".
-spec current() -> config().
current() ->
    stored(persistent_term:get({ircd_state, config})).

-doc """
Like `current/0`, but an empty map before the server has stored its
configuration. For code that also runs without `m:ircd_state` (some unit
tests) and reads every key with a default.
""".
-spec current_or_empty() -> config() | #{}.
current_or_empty() ->
    stored(persistent_term:get({ircd_state, config}, #{})).

-doc """
Store `Config` as the running configuration. Called by `m:ircd_state` at
startup and on `REHASH`, and when an operator changes the log level or a
feature switch.
""".
-spec store(config()) -> ok.
store(Config) ->
    persistent_term:put({ircd_state, config}, Config).

-doc """
The configuration as the file says (the last `load/1` that startup or
`REHASH` accepted), before admin overrides (`m:ircd_overrides`). Falls back
to `current/0` before one is stored.
""".
-spec base() -> config().
base() ->
    stored(
        persistent_term:get({ircd_state, base_config}, persistent_term:get({ircd_state, config}))
    ).

-doc "Store `Config` as the file's configuration (see `base/0`).".
-spec store_base(config()) -> ok.
store_base(Config) ->
    persistent_term:put({ircd_state, base_config}, Config).

%% Only store/1 writes the term, always with a config(); unit tests may store
%% a partial map.
-spec stored(term()) -> dynamic().
stored(Config) ->
    Config.

-doc """
Parse a `log_level` name (`trace`, `debug`, `info`, `notice`, `warning`,
`error`, `critical`, `alert`, or `emergency`) into its atom from a fixed list;
any other value returns `error`. `trace` is more verbose than `debug`.
""".
-spec parse_log_level(term()) -> {ok, logger:level() | trace} | error.
parse_log_level(<<"trace">>) -> {ok, trace};
parse_log_level(<<"debug">>) -> {ok, debug};
parse_log_level(<<"info">>) -> {ok, info};
parse_log_level(<<"notice">>) -> {ok, notice};
parse_log_level(<<"warning">>) -> {ok, warning};
parse_log_level(<<"error">>) -> {ok, error};
parse_log_level(<<"critical">>) -> {ok, critical};
parse_log_level(<<"alert">>) -> {ok, alert};
parse_log_level(<<"emergency">>) -> {ok, emergency};
parse_log_level(_) -> error.

-doc """
Compare two secrets without leaking their contents through early exit.

Both sides are hashed with SHA-256 and the digests are compared with
`crypto:hash_equals/2`, so the time taken does not depend on where the inputs
first differ, and a length mismatch does not return early. Returns `false`
when either argument is not a binary. Use it for `PASS`, `OPER`, and server
link passwords.
""".
%% Any non-binary (an unset `null` secret, for example) never matches.
-spec secret_match(term(), term()) -> boolean().
secret_match(Left, Right) when is_binary(Left), is_binary(Right) ->
    crypto:hash_equals(crypto:hash(sha256, Left), crypto:hash(sha256, Right));
secret_match(_, _) ->
    false.

-doc """
Read and validate the JSON configuration file at `Path`.

Returns `{ok, Config}`, a map with atom keys and every default filled in (for
example `tcp`, `tls`, `ws`, `wss` ports, `ip`, `tls_options`, `level`,
`max_clients`, `server_links`, and `config_path`, the absolute path of the
file). Returns `{error, {invalid_config, Path, Reason}}` when the file cannot
be read, is not valid JSON, or fails any check; `Reason` names the failed
check where one exists, for example `{invalid_log_level, Value}`.
""".
-spec load(file:filename()) -> {ok, config()} | {error, term()}.
load(Path) ->
    try
        {ok, Bytes} = file:read_file(Path),
        Json = json:decode(Bytes),
        Name = maps:get(<<"name">>, Json, <<"irc.local">>),
        match = re:run(Name, <<"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$">>, [
            {capture, none}, dollar_endonly
        ]),
        Bind = maps:get(<<"bind">>, Json, <<"127.0.0.1">>),
        {ok, IP} = inet:parse_address(binary_to_list(Bind)),
        TCP = port(maps:get(<<"tcp_port">>, Json, 6667)),
        TLS = port(maps:get(<<"tls_port">>, Json, null)),
        WS = port(maps:get(<<"ws_port">>, Json, null)),
        WSS = port(maps:get(<<"wss_port">>, Json, null)),
        true = TCP =/= null orelse TLS =/= null orelse WS =/= null orelse WSS =/= null,
        TLSOptions = tls_options(first_port([TLS, WSS]), Json),
        Level = log_level(maps:get(<<"log_level">>, Json, <<"info">>)),
        Format = maps:get(<<"log_format">>, Json, <<"json">>),
        true = lists:member(Format, [<<"json">>, <<"text">>]),
        MaxClients = positive_limit(maps:get(<<"max_clients">>, Json, 10000)),
        ReopDelay = positive_limit(maps:get(<<"reop_delay">>, Json, 30)),
        MotdFile = optional_path(maps:get(<<"motd_file">>, Json, null)),
        ClientPassword = optional_secret(maps:get(<<"client_password">>, Json, null)),
        MnesiaDir = required_path(maps:get(<<"mnesia_dir">>, Json, <<"data/mnesia">>)),
        Retention = retention(maps:get(<<"retention">>, Json, <<"channels">>)),
        HistoryLimit = history_limit(maps:get(<<"history_limit">>, Json, 100)),
        NickLen = nicklen(maps:get(<<"nicklen">>, Json, 9)),
        Operators = operators(maps:get(<<"operators">>, Json, [])),
        Administrators = administrators(maps:get(<<"administrators">>, Json, []), NickLen),
        ok = distinct_accounts(Operators, Administrators),
        Channels = channels(maps:get(<<"channels">>, Json, [])),
        ServerLinks = server_links(maps:get(<<"server_links">>, Json, []), Name),
        Providers = ai_providers(maps:get(<<"ai_providers">>, Json, #{})),
        Bots = bots(maps:get(<<"bots">>, Json, []), Providers, NickLen),
        Admin = admin_info(Json),
        Network = network_name(maps:get(<<"network">>, Json, Name)),
        ServerInfo = text_value(Json, <<"server_info">>, <<"Erlang/OTP IRC server">>),
        {ok, #{
            server_info => ServerInfo,
            shutdown_grace => shutdown_grace(maps:get(<<"shutdown_grace">>, Json, 5)),
            max_sendq => max_sendq(maps:get(<<"max_sendq">>, Json, 10000)),
            flood => flood(maps:get(<<"flood">>, Json, #{})),
            dronebl => dronebl(maps:get(<<"dronebl">>, Json, false)),
            webui => webui(maps:get(<<"webui">>, Json, null)),
            e2ee => e2ee(maps:get(<<"e2ee">>, Json, null)),
            voice => voice(maps:get(<<"voice">>, Json, null)),
            files => files(maps:get(<<"files">>, Json, null)),
            calls => calls(maps:get(<<"calls">>, Json, null)),
            features => features(maps:get(<<"features">>, Json, #{})),
            max_accounts => positive_limit(maps:get(<<"max_accounts">>, Json, 100000)),
            max_empty_channels => positive_limit(maps:get(<<"max_empty_channels">>, Json, 1000)),
            empty_channel_ttl => empty_channel_ttl(maps:get(<<"empty_channel_ttl">>, Json, 86400)),
            max_read_markers => positive_limit(maps:get(<<"max_read_markers">>, Json, 500)),
            max_direct_conversations => positive_limit(
                maps:get(<<"max_direct_conversations">>, Json, 200)
            ),
            max_peer_users => positive_limit(maps:get(<<"max_peer_users">>, Json, 10000)),
            max_peer_servers => positive_limit(maps:get(<<"max_peer_servers">>, Json, 100)),
            max_peer_services => positive_limit(maps:get(<<"max_peer_services">>, Json, 100)),
            tls_reload_interval => tls_reload_interval(
                maps:get(<<"tls_reload_interval">>, Json, 60)
            ),
            multiclient => boolean_setting(multiclient, maps:get(<<"multiclient">>, Json, false)),
            account_rejoin => boolean_setting(
                account_rejoin, maps:get(<<"account_rejoin">>, Json, false)
            ),
            ws => WS,
            wss => WSS,
            ws_origins => ws_origins(maps:get(<<"ws_origins">>, Json, null)),
            network => Network,
            network_icon => network_icon(maps:get(<<"network_icon">>, Json, null)),
            sts => sts(maps:get(<<"sts">>, Json, null)),
            nicklen => NickLen,
            resource_delay => resource_delay(maps:get(<<"resource_delay">>, Json, 60)),
            account_password_min => password_min(maps:get(<<"account_password_min">>, Json, 8)),
            account_registration_before_connect => boolean_setting(
                account_registration_before_connect,
                maps:get(<<"account_registration_before_connect">>, Json, true)
            ),
            account_registration_email_required => boolean_setting(
                account_registration_email_required,
                maps:get(<<"account_registration_email_required">>, Json, false)
            ),
            account_registration => boolean_setting(
                account_registration, maps:get(<<"account_registration">>, Json, true)
            ),
            utf8_only => boolean_setting(utf8_only, maps:get(<<"utf8_only">>, Json, false)),
            chathistory => boolean_setting(chathistory, maps:get(<<"chathistory">>, Json, true)),
            monitor_limit => positive_limit(maps:get(<<"monitor_limit">>, Json, 100)),
            webirc => webirc(maps:get(<<"webirc">>, Json, [])),
            account_verification => account_verification(
                maps:get(<<"account_verification">>, Json, null)
            ),
            config_path => filename:absname(Path),
            name => Name,
            ip => IP,
            tcp => TCP,
            tls => TLS,
            tls_options => TLSOptions,
            level => Level,
            log_format => Format,
            max_clients => MaxClients,
            reop_delay => ReopDelay,
            motd_file => MotdFile,
            client_password => ClientPassword,
            mnesia_dir => MnesiaDir,
            retention => Retention,
            history_limit => HistoryLimit,
            operators => Operators,
            administrators => Administrators,
            channels => Channels,
            server_links => ServerLinks,
            bots => Bots,
            admin => Admin
        }}
    catch
        error:Reason -> {error, {invalid_config, Path, Reason}}
    end.

port(null) -> null;
port(Port) when is_integer(Port), Port >= 0, Port =< 65535 -> Port.

%% Logger severity. `trace` is more verbose than `debug`. The other atoms are
%% OTP logger levels. An unknown value is rejected before the server starts.
log_level(Value) ->
    case parse_log_level(Value) of
        {ok, Level} -> Level;
        error -> erlang:error({invalid_log_level, Value})
    end.

first_port(Ports) ->
    case [Port || Port <- Ports, Port =/= null] of
        [Port | _] -> Port;
        [] -> null
    end.

%% Server certificate verification is unchanged. The listener asks for an
%% optional client certificate so SASL EXTERNAL can use its SHA-256 fingerprint
%% (CertFP). A missing or self-signed client certificate does not fail the
%% handshake; it only means EXTERNAL has no identity to offer. `sni` entries
%% select a different certificate by requested host name.
tls_options(null, _) ->
    [];
tls_options(_, Json) ->
    [
        {certfile, binary_to_list(maps:get(<<"certfile">>, Json))},
        {keyfile, binary_to_list(maps:get(<<"keyfile">>, Json))},
        {versions, ['tlsv1.3', 'tlsv1.2']},
        {verify, verify_peer},
        %% No CA is trusted for client certificates: they are only matched by
        %% fingerprint, so verify_fun accepts an unknown issuer.
        {cacerts, []},
        {fail_if_no_peer_cert, false},
        {verify_fun, {fun accept_client_certificate/3, []}}
        | sni_hosts(maps:get(<<"sni">>, Json, []))
    ].

%% Client certificates are identities for SASL EXTERNAL, not chains to trust,
%% so any well-formed certificate is accepted here and matched by fingerprint.
accept_client_certificate(_Cert, {bad_cert, _Reason}, State) -> {valid, State};
accept_client_certificate(_Cert, {extension, _}, State) -> {unknown, State};
accept_client_certificate(_Cert, valid, State) -> {valid, State};
accept_client_certificate(_Cert, valid_peer, State) -> {valid, State}.

sni_hosts([]) ->
    [];
sni_hosts(Entries) when is_list(Entries) ->
    [
        {sni_hosts, [
            begin
                Host = maps:get(<<"hostname">>, Entry),
                true = is_binary(Host) andalso byte_size(Host) > 0 andalso byte_size(Host) =< 253,
                {binary_to_list(Host), [
                    {certfile, binary_to_list(maps:get(<<"certfile">>, Entry))},
                    {keyfile, binary_to_list(maps:get(<<"keyfile">>, Entry))}
                ]}
            end
         || Entry <- Entries
        ]}
    ].

%% Seconds to wait for sessions to close during a graceful shutdown.
shutdown_grace(Value) when is_integer(Value), Value >= 0, Value =< 300 -> Value;
shutdown_grace(Value) -> erlang:error({invalid_shutdown_grace, Value}).

%% Lines queued for one client before it is disconnected (Max SendQ exceeded).
max_sendq(Value) when is_integer(Value, 100, 1000000) -> Value;
max_sendq(Value) -> erlang:error({invalid_max_sendq, Value}).

%%Seconds before an empty non-predefined channel is expired; 0 disables TTL expiry.
empty_channel_ttl(Value) when is_integer(Value, 0, 2592000) -> Value;
empty_channel_ttl(Value) -> erlang:error({invalid_empty_channel_ttl, Value}).

%% Client flood and spam control (ircd_flood). `null` turns it off.
-define(FLOOD_KEYS, [
    <<"lines_burst">>,
    <<"lines_per_second">>,
    <<"messages_burst">>,
    <<"messages_per_second">>,
    <<"join_burst">>,
    <<"join_per_minute">>,
    <<"nick_burst">>,
    <<"nick_per_minute">>,
    <<"register_per_minute">>
]).
flood(null) ->
    null;
flood(Map) when is_map(Map) ->
    case maps:keys(Map) -- ?FLOOD_KEYS of
        [] -> ok;
        Unknown -> erlang:error({invalid_flood, {unknown_keys, Unknown}})
    end,
    #{
        lines_burst => flood_int(Map, <<"lines_burst">>, 500, 1, 100000),
        lines_per_second => flood_int(Map, <<"lines_per_second">>, 50, 1, 10000),
        messages_burst => flood_int(Map, <<"messages_burst">>, 200, 1, 100000),
        messages_per_second => flood_int(Map, <<"messages_per_second">>, 20, 1, 10000),
        join_burst => flood_int(Map, <<"join_burst">>, 50, 1, 10000),
        join_per_minute => flood_int(Map, <<"join_per_minute">>, 60, 1, 100000),
        nick_burst => flood_int(Map, <<"nick_burst">>, 50, 1, 10000),
        nick_per_minute => flood_int(Map, <<"nick_per_minute">>, 60, 1, 100000),
        register_per_minute => flood_int(Map, <<"register_per_minute">>, 30, 1, 10000)
    };
flood(Value) ->
    erlang:error({invalid_flood, Value}).

flood_int(Map, Key, Default, Min, Max) ->
    case maps:get(Key, Map, Default) of
        Value when is_integer(Value, Min, Max) -> Value;
        Value -> erlang:error({invalid_flood, {Key, Value}})
    end.

%% End-to-end encryption broker (ircd_e2ee). `null` (the default) turns it
%% off. Unknown keys are rejected so a typo does not silently drop a limit.
-define(E2EE_KEYS, [
    <<"max_devices">>, <<"max_prekeys">>, <<"queue_limit">>, <<"queue_ttl">>, <<"fetch_rate">>
]).
e2ee(null) ->
    null;
e2ee(Map) when is_map(Map) ->
    case maps:keys(Map) -- ?E2EE_KEYS of
        [] -> ok;
        Unknown -> erlang:error({invalid_e2ee, {unknown_keys, Unknown}})
    end,
    #{
        max_devices => e2ee_int(Map, <<"max_devices">>, 8, 1, 32),
        max_prekeys => e2ee_int(Map, <<"max_prekeys">>, 100, 1, 1000),
        queue_limit => e2ee_int(Map, <<"queue_limit">>, 500, 0, 10000),
        queue_ttl => e2ee_int(Map, <<"queue_ttl">>, 1209600, 60, 7776000),
        fetch_rate => e2ee_int(Map, <<"fetch_rate">>, 30, 1, 1000)
    };
e2ee(Value) ->
    erlang:error({invalid_e2ee, Value}).

e2ee_int(Map, Key, Default, Min, Max) ->
    case maps:get(Key, Map, Default) of
        Value when is_integer(Value, Min, Max) -> Value;
        Value -> erlang:error({invalid_e2ee, {Key, Value}})
    end.

%% Seconds between TLS certificate file checks (ircd_certs); 0 disables.
tls_reload_interval(0) -> 0;
tls_reload_interval(Value) when is_integer(Value, 5, 86400) -> Value;
tls_reload_interval(Value) -> erlang:error({invalid_tls_reload_interval, Value}).

%% Longest nickname. RFC 1459 uses 9; larger values are an operator choice
%% and must match every linked server.
nicklen(Value) when is_integer(Value), Value >= 9, Value =< 30 -> Value;
nicklen(Value) -> erlang:error({invalid_nicklen, Value}).

%% Seconds a released nickname or channel name stays unavailable (437).
resource_delay(Value) when is_integer(Value), Value >= 0, Value =< 86400 -> Value;
resource_delay(Value) -> erlang:error({invalid_resource_delay, Value}).

password_min(Value) when is_integer(Value), Value >= 1, Value =< 300 -> Value;
password_min(Value) -> erlang:error({invalid_account_password_min, Value}).

boolean_setting(_Key, Value) when is_boolean(Value) -> Value;
boolean_setting(Key, Value) -> erlang:error({invalid_boolean, Key, Value}).

network_name(Name) when is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< 64 ->
    case binary:match(Name, [<<" ">>, <<0>>, <<"\r">>, <<"\n">>, <<",">>]) of
        nomatch -> Name;
        _ -> erlang:error({invalid_network, Name})
    end;
network_name(Name) ->
    erlang:error({invalid_network, Name}).

network_icon(null) ->
    null;
network_icon(Url) when is_binary(Url), byte_size(Url) > 0, byte_size(Url) =< 300 ->
    case binary:match(Url, [<<" ">>, <<0>>, <<"\r">>, <<"\n">>]) of
        nomatch -> Url;
        _ -> erlang:error({invalid_network_icon, invalid})
    end;
network_icon(_) ->
    erlang:error({invalid_network_icon, invalid}).

ws_origins(null) ->
    null;
ws_origins(List) when is_list(List) ->
    [Origin || Origin <- List, is_binary(Origin) orelse erlang:error({invalid_ws_origin, Origin})].

%% STS policy. `port` is the TLS port advertised to plaintext clients and
%% `duration` (seconds) is the persistence policy advertised to TLS clients.
sts(null) ->
    null;
sts(Map) when is_map(Map) ->
    Port = maps:get(<<"port">>, Map),
    true = is_integer(Port) andalso Port > 0 andalso Port =< 65535,
    Duration = maps:get(<<"duration">>, Map, 2592000),
    true = is_integer(Duration) andalso Duration >= 0,
    Preload = maps:get(<<"preload">>, Map, false),
    true = is_boolean(Preload),
    #{port => Port, duration => Duration, preload => Preload};
sts(Value) ->
    erlang:error({invalid_sts, Value}).

%% Email verification for draft/account-registration. Supports either an
%% external `command` (absolute path + args), an `smtp` relay (via gen_smtp),
%% or both, with an optional `verify_url` web link and `ttl` in seconds.
account_verification(null) ->
    null;
account_verification(Map) when is_map(Map) ->
    Ttl = maps:get(<<"ttl">>, Map, 900),
    true = is_integer(Ttl) andalso Ttl > 0 andalso Ttl =< 86400,
    HasCmd = maps:is_key(<<"command">>, Map),
    HasSmtp = maps:is_key(<<"smtp">>, Map) andalso maps:get(<<"smtp">>, Map) =/= null,
    true = HasCmd orelse HasSmtp,
    Base0 = #{ttl => Ttl},
    Base1 =
        case HasCmd of
            true ->
                [Exe | Args] = Command = maps:get(<<"command">>, Map),
                true = lists:all(
                    fun(Part) -> is_binary(Part) andalso byte_size(Part) > 0 end, Command
                ),
                true = filename:pathtype(Exe) =:= absolute,
                Base0#{command => [binary_to_list(Exe) | [binary_to_list(A) || A <- Args]]};
            false ->
                Base0
        end,
    Base2 =
        case HasSmtp of
            true -> Base1#{smtp => smtp_config(maps:get(<<"smtp">>, Map))};
            false -> Base1
        end,
    case maps:get(<<"verify_url">>, Map, null) of
        null ->
            Base2;
        Url ->
            Base2#{verify_url => verify_url(Url)}
    end;
account_verification(Value) ->
    erlang:error({invalid_account_verification, Value}).

smtp_config(Map) when is_map(Map) ->
    Relay = maps:get(<<"relay">>, Map),
    true =
        is_binary(Relay) andalso byte_size(Relay) > 0 andalso byte_size(Relay) =< 253 andalso
            binary:match(Relay, [<<0>>, <<" ">>, <<"\r">>, <<"\n">>]) =:= nomatch,
    Port = maps:get(<<"port">>, Map, 587),
    true = is_integer(Port, 1, 65535),
    From = maps:get(<<"from">>, Map),
    true =
        is_binary(From) andalso byte_size(From) > 0 andalso byte_size(From) =< 254 andalso
            binary:match(From, [<<0>>, <<"\r">>, <<"\n">>]) =:= nomatch andalso
            binary:match(From, <<"@">>) =/= nomatch,
    Tls = smtp_tls(maps:get(<<"tls">>, Map, <<"if_available">>)),
    Ssl = boolean_setting(smtp_ssl, maps:get(<<"ssl">>, Map, false)),
    Subject = text_value(Map, <<"subject">>, <<"Verify your IRC account">>),
    User = optional_smtp_cred(maps:get(<<"username">>, Map, null)),
    Pass = optional_smtp_cred(maps:get(<<"password">>, Map, null)),
    true = (User =:= null andalso Pass =:= null) orelse (is_binary(User) andalso is_binary(Pass)),
    #{
        relay => ircd_wire:retain(Relay),
        port => Port,
        from => ircd_wire:retain(From),
        tls => Tls,
        ssl => Ssl,
        subject => ircd_wire:retain(Subject),
        username =>
            case User of
                null -> null;
                _ -> ircd_wire:retain(User)
            end,
        password =>
            case Pass of
                null -> null;
                _ -> retain_secret(Pass)
            end
    };
smtp_config(Value) ->
    erlang:error({invalid_smtp_config, Value}).

smtp_tls(<<"always">>) -> always;
smtp_tls(<<"if_available">>) -> if_available;
smtp_tls(<<"never">>) -> never;
smtp_tls(Value) -> erlang:error({invalid_smtp_tls, Value}).

optional_smtp_cred(null) ->
    null;
optional_smtp_cred(Bin) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 256 ->
    nomatch = binary:match(Bin, [<<0>>, <<"\r">>, <<"\n">>]),
    Bin;
optional_smtp_cred(Value) ->
    erlang:error({invalid_smtp_credential, Value}).

verify_url(Url) when is_binary(Url), byte_size(Url) =< 2048 ->
    nomatch = binary:match(Url, [<<0>>, <<" ">>, <<"\r">>, <<"\n">>]),
    case Url of
        <<"https://", Rest/binary>> when byte_size(Rest) > 0 -> ircd_wire:retain(Url);
        <<"http://", Rest/binary>> when byte_size(Rest) > 0 -> ircd_wire:retain(Url);
        _ -> erlang:error({invalid_verify_url, Url})
    end;
verify_url(Value) ->
    erlang:error({invalid_verify_url, Value}).

%% Trusted WebIRC gateways. `hosts` lists gateway IP addresses that may send
%% WEBIRC with `password`. A missing `hosts` list does not trust any address.
webirc(Entries) when is_list(Entries) ->
    [
        begin
            Password = maps:get(<<"password">>, Entry),
            true = is_binary(Password) andalso byte_size(Password) > 0,
            Hosts = maps:get(<<"hosts">>, Entry),
            true = is_list(Hosts) andalso Hosts =/= [],
            Parsed = [
                begin
                    {ok, Address} = inet:parse_address(binary_to_list(Host)),
                    Address
                end
             || Host <- Hosts
            ],
            #{password => Password, hosts => Parsed}
        end
     || Entry <- Entries
    ];
webirc(Value) ->
    erlang:error({invalid_webirc, Value}).

positive_limit(Value) when is_integer(Value), Value > 0, Value =< 1000000 -> Value.

optional_path(null) -> null;
optional_path(Path) when is_binary(Path), byte_size(Path) > 0 -> binary_to_list(Path).

required_path(Path) when is_binary(Path), byte_size(Path) > 0 -> binary_to_list(Path).

%% `transient` is today's restart policy. `channels` also keeps ordinary channel
%% rows and a bounded channel message history.
retention(<<"transient">>) ->
    transient;
retention(<<"channels">>) ->
    channels;
retention(Value) ->
    erlang:error({invalid_retention, Value}).

%% Newest channel PRIVMSG/NOTICE lines kept per channel when retention is `channels`.
history_limit(Value) when is_integer(Value), Value >= 1, Value =< 10000 ->
    Value;
history_limit(Value) ->
    erlang:error({invalid_history_limit, Value}).

optional_secret(null) -> null;
optional_secret(Secret) when is_binary(Secret), byte_size(Secret) > 0 -> Secret.

server_links(Entries, LocalName) when is_list(Entries) ->
    Parsed =
        [
            begin
                Name = maps:get(<<"name">>, Entry),
                Host = maps:get(<<"host">>, Entry),
                Port = maps:get(<<"port">>, Entry),
                Password = maps:get(<<"password">>, Entry),
                TLS = maps:get(<<"tls">>, Entry, false),
                match = re:run(Name, <<"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$">>, [
                    {capture, none}, dollar_endonly
                ]),
                false = ircd_wire:fold(Name) =:= ircd_wire:fold(LocalName),
                true =
                    is_binary(Host) andalso byte_size(Host) > 0 andalso byte_size(Host) =< 253 andalso
                        binary:match(Host, [<<0>>, <<" ">>, <<"\r">>, <<"\n">>]) =:= nomatch,
                true = is_integer(Port) andalso Port > 0 andalso Port =< 65535,
                true =
                    is_binary(Password) andalso byte_size(Password) > 0 andalso
                        byte_size(Password) =< 400,
                true = is_boolean(TLS),
                #{name => Name, host => Host, port => Port, password => Password, tls => TLS}
            end
         || Entry <- Entries
        ],
    Names = [ircd_wire:fold(maps:get(name, Link)) || Link <- Parsed],
    true = length(Names) =:= length(lists:usort(Names)),
    Parsed.

admin_info(Json) ->
    #{
        name => text_value(Json, <<"admin_name">>, <<"IRC server administrator">>),
        location1 => text_value(Json, <<"admin_location1">>, <<"Not configured">>),
        location2 => text_value(Json, <<"admin_location2">>, <<"Not configured">>),
        email => text_value(Json, <<"admin_email">>, <<"Not configured">>)
    }.

text_value(Json, Key, Default) ->
    case maps:get(Key, Json, Default) of
        Value when is_binary(Value), byte_size(Value) > 0 -> Value;
        _ -> erlang:error({invalid_text_setting, Key})
    end.

operators(Entries) when is_list(Entries) ->
    Parsed =
        [
            begin
                Name = maps:get(<<"name">>, Entry),
                Password = maps:get(<<"password">>, Entry),
                true = byte_size(Name) > 0 andalso byte_size(Name) =< 32,
                true = byte_size(Password) > 0,
                {ircd_wire:fold(Name), Password}
            end
         || Entry <- Entries
        ],
    Keys = [Name || {Name, _} <- Parsed],
    true = length(Keys) =:= length(lists:usort(Keys)),
    Parsed.

%% Administrator accounts use OPER. `nick` is the OPER parameter, folded with
%% RFC 1459 rules. It does not have to equal the client's current nickname.
%% The same folded name cannot appear twice or also appear in `operators`.
administrators(Entries, NickLen) when is_list(Entries) ->
    administrators(Entries, NickLen, [], []);
administrators(Value, _NickLen) ->
    erlang:error({invalid_administrators, Value}).

administrators([], _NickLen, _Seen, Acc) ->
    lists:reverse(Acc);
administrators([Entry | Rest], NickLen, Seen, Acc) ->
    Account = administrator(Entry, NickLen),
    {Nick, _Password} = Account,
    case lists:member(Nick, Seen) of
        true -> erlang:error({duplicate_administrator, Nick});
        false -> administrators(Rest, NickLen, [Nick | Seen], [Account | Acc])
    end.

administrator(Entry, NickLen) when is_map(Entry) ->
    Nick =
        case maps:get(<<"nick">>, Entry, undefined) of
            Given when is_binary(Given) -> Given;
            Other -> erlang:error({invalid_administrator, Other})
        end,
    Password = maps:get(<<"password">>, Entry, undefined),
    case ircd_wire:nickname(Nick, NickLen) of
        true -> ok;
        false -> erlang:error({invalid_administrator, Nick})
    end,
    case is_binary(Password) andalso byte_size(Password) > 0 andalso byte_size(Password) =< 400 of
        true -> {ircd_wire:fold(Nick), Password};
        false -> erlang:error({invalid_administrator, Nick})
    end;
administrator(_, _NickLen) ->
    erlang:error({invalid_administrator, invalid}).

distinct_accounts(Operators, Administrators) ->
    OperatorNames = [Name || {Name, _} <- Operators],
    case [Nick || {Nick, _} <- Administrators, lists:member(Nick, OperatorNames)] of
        [] -> ok;
        [Nick | _] -> erlang:error({duplicate_administrator, Nick})
    end.

%% Predefined channels are created when no row exists. Safe `!` names are
%% rejected because their identifier is assigned by the server.
channels(Entries) when is_list(Entries) ->
    channels(Entries, [], []);
channels(Value) ->
    erlang:error({invalid_channels, Value}).

channels([], _Seen, Acc) ->
    lists:reverse(Acc);
channels([Entry | Rest], Seen, Acc) ->
    Channel = channel_entry(Entry),
    Key = maps:get(key, Channel),
    case lists:member(Key, Seen) of
        true -> erlang:error({duplicate_channel, maps:get(name, Channel)});
        false -> channels(Rest, [Key | Seen], [Channel | Acc])
    end.

channel_entry(Entry) when is_map(Entry) ->
    Name =
        case maps:get(<<"name">>, Entry, undefined) of
            Given when is_binary(Given) -> Given;
            Other -> erlang:error({invalid_channel, channel_label(Other)})
        end,
    case ircd_wire:channel(Name) andalso binary:first(Name) =/= $! of
        true -> ok;
        false -> erlang:error({invalid_channel, channel_label(Name)})
    end,
    Topic = channel_topic(maps:get(<<"topic">>, Entry, <<>>)),
    Password = channel_key(maps:get(<<"key">>, Entry, null)),
    Limit = channel_limit(maps:get(<<"limit">>, Entry, null)),
    Flags = channel_flags(Name, maps:get(<<"modes">>, Entry, <<>>)),
    #{
        key => ircd_wire:fold(Name),
        name => ircd_wire:retain(Name),
        topic => ircd_wire:retain(Topic),
        password => retain_secret(Password),
        limit => Limit,
        flags => Flags
    };
channel_entry(_) ->
    erlang:error({invalid_channel, invalid}).

channel_label(Name) when is_binary(Name), byte_size(Name) =< 50 -> Name;
channel_label(_) -> invalid.

channel_topic(<<>>) ->
    <<>>;
channel_topic(Topic) when is_binary(Topic), byte_size(Topic) =< 390 ->
    case binary:match(Topic, [<<0>>, <<"\r">>, <<"\n">>]) of
        nomatch -> Topic;
        _ -> erlang:error({invalid_channel_topic, invalid})
    end;
channel_topic(_) ->
    erlang:error({invalid_channel_topic, invalid}).

channel_key(null) ->
    undefined;
channel_key(Key) when is_binary(Key), byte_size(Key) > 0, byte_size(Key) =< 64 ->
    case binary:match(Key, [<<0>>, <<" ">>, <<",">>, <<":">>, <<"\r">>, <<"\n">>]) of
        nomatch -> Key;
        _ -> erlang:error({invalid_channel_key, invalid})
    end;
channel_key(_) ->
    erlang:error({invalid_channel_key, invalid}).

channel_limit(null) ->
    undefined;
channel_limit(Limit) when is_integer(Limit), Limit >= 1, Limit =< 2147483647 ->
    Limit;
channel_limit(Limit) ->
    erlang:error({invalid_channel_limit, Limit}).

channel_flags(Name, <<$+, Modes/binary>>) ->
    channel_flags(Name, Modes);
channel_flags(_Name, <<$-, _/binary>> = Modes) ->
    erlang:error({invalid_channel_modes, Modes});
channel_flags(Name, Modes) when is_binary(Modes), byte_size(Modes) =< 16 ->
    Flags = mode_letters(Modes, binary:first(Name), #{}),
    case binary:first(Name) of
        $+ -> Flags#{$t => true};
        _ -> Flags
    end;
channel_flags(_Name, _Modes) ->
    erlang:error({invalid_channel_modes, invalid}).

mode_letters(<<>>, _Type, Flags) ->
    Flags;
mode_letters(<<Letter, Rest/binary>>, Type, Flags) ->
    case allowed_channel_mode(Letter, Type) andalso not is_map_key(Letter, Flags) of
        true ->
            case exclusive_mode(Letter, Flags) of
                true -> mode_letters(Rest, Type, Flags#{Letter => true});
                false -> erlang:error({invalid_channel_modes, Letter})
            end;
        false ->
            erlang:error({invalid_channel_modes, Letter})
    end.

allowed_channel_mode($a, $&) ->
    true;
allowed_channel_mode($a, _) ->
    false;
allowed_channel_mode(Letter, Type) when
    Type =:= $# orelse Type =:= $& orelse Type =:= $+,
    Letter =:= $i orelse Letter =:= $m orelse Letter =:= $n orelse Letter =:= $p orelse
        Letter =:= $s orelse Letter =:= $t orelse Letter =:= $q orelse Letter =:= $K
->
    true;
allowed_channel_mode(_, _) ->
    false.

exclusive_mode($p, Flags) ->
    not is_map_key($s, Flags);
exclusive_mode($s, Flags) ->
    not is_map_key($p, Flags);
exclusive_mode(_, _) ->
    true.

retain_secret(undefined) -> undefined;
retain_secret(Secret) -> ircd_wire:retain(Secret).

%% DroneBL DNSBL lookup and temporary IP banning. Accepts a boolean shorthand
%% (`false` / `true`) or an object with fine-grained options.
dronebl(false) ->
    dronebl(#{<<"enabled">> => false});
dronebl(true) ->
    dronebl(#{<<"enabled">> => true});
dronebl(Map) when is_map(Map) ->
    Enabled = boolean_setting(dronebl_enabled, maps:get(<<"enabled">>, Map, false)),
    Zone = dronebl_zone(maps:get(<<"zone">>, Map, <<"dnsbl.dronebl.org">>)),
    TimeoutMs = dronebl_int(timeout_ms, maps:get(<<"timeout_ms">>, Map, 3000), 100, 30000),
    BanTtl = dronebl_int(ban_ttl, maps:get(<<"ban_ttl">>, Map, 3600), 60, 604800),
    CacheTtl = dronebl_int(cache_ttl, maps:get(<<"cache_ttl">>, Map, 300), 0, 86400),
    Types = dronebl_types(maps:get(<<"types">>, Map, <<"all">>)),
    SkipPrivate = boolean_setting(
        dronebl_skip_private, maps:get(<<"skip_private">>, Map, true)
    ),
    MaxEntries = dronebl_int(max_entries, maps:get(<<"max_entries">>, Map, 10000), 100, 1000000),
    MaxInFlight = dronebl_int(max_in_flight, maps:get(<<"max_in_flight">>, Map, 64), 1, 1024),
    #{
        enabled => Enabled,
        zone => Zone,
        timeout_ms => TimeoutMs,
        ban_ttl => BanTtl,
        cache_ttl => CacheTtl,
        types => Types,
        skip_private => SkipPrivate,
        max_entries => MaxEntries,
        max_in_flight => MaxInFlight
    };
dronebl(Value) ->
    erlang:error({invalid_dronebl, Value}).

dronebl_zone(Zone) when is_binary(Zone), byte_size(Zone) > 0, byte_size(Zone) =< 253 ->
    case re:run(Zone, <<"^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$">>, [{capture, none}]) of
        match -> Zone;
        nomatch -> erlang:error({invalid_dronebl_zone, Zone})
    end;
dronebl_zone(Zone) ->
    erlang:error({invalid_dronebl_zone, Zone}).

dronebl_int(_Key, Value, Min, Max) when is_integer(Value, Min, Max) ->
    Value;
dronebl_int(Key, Value, _Min, _Max) ->
    erlang:error({invalid_dronebl, Key, Value}).

dronebl_types(<<"all">>) ->
    all;
dronebl_types(List) when is_list(List), List =/= [] ->
    true = lists:all(fun(Code) -> is_integer(Code, 2, 255) end, List),
    lists:usort(List);
dronebl_types(Value) ->
    erlang:error({invalid_dronebl_types, Value}).

%% Admin WebUI HTTP listener. Disabled when `null` or `false`. Requires an
%% explicit `port` and non-empty `password`; binds to loopback by default.
webui(null) ->
    null;
webui(false) ->
    null;
webui(Map) when is_map(Map) ->
    Bind = maps:get(<<"bind">>, Map, <<"127.0.0.1">>),
    true = is_binary(Bind),
    {ok, IP} = inet:parse_address(binary_to_list(Bind)),
    Port = maps:get(<<"port">>, Map),
    true = is_integer(Port, 0, 65535),
    Username = maps:get(<<"username">>, Map, <<"admin">>),
    true =
        is_binary(Username) andalso byte_size(Username) > 0 andalso byte_size(Username) =< 128 andalso
            binary:match(Username, [<<0>>, <<":">>, <<"\r">>, <<"\n">>]) =:= nomatch,
    Password = maps:get(<<"password">>, Map),
    true =
        is_binary(Password) andalso byte_size(Password) > 0 andalso byte_size(Password) =< 256 andalso
            binary:match(Password, [<<0>>, <<"\r">>, <<"\n">>]) =:= nomatch,
    TermsUrl = webui_url(
        terms_url, maps:get(<<"terms_url">>, Map, <<"https://example.com/terms">>)
    ),
    PrivacyUrl = webui_url(
        privacy_url, maps:get(<<"privacy_url">>, Map, <<"https://example.com/privacy">>)
    ),
    #{
        ip => IP,
        port => Port,
        username => ircd_wire:retain(Username),
        password => retain_secret(Password),
        terms_url => TermsUrl,
        privacy_url => PrivacyUrl
    };
webui(Value) ->
    erlang:error({invalid_webui, Value}).

webui_url(_Key, Url) when is_binary(Url), byte_size(Url) =< 2048 ->
    nomatch = binary:match(Url, [
        <<0>>, <<" ">>, <<"\r">>, <<"\n">>, <<"\"">>, <<"'">>, <<"<">>, <<">">>
    ]),
    case Url of
        <<"https://", Rest/binary>> when byte_size(Rest) > 0 -> ircd_wire:retain(Url);
        <<"http://", Rest/binary>> when byte_size(Rest) > 0 -> ircd_wire:retain(Url);
        _ -> erlang:error({invalid_webui_url, Url})
    end;
webui_url(Key, Value) ->
    erlang:error({invalid_webui_url, Key, Value}).

%% Voice messages (OPUS) stored in S3-compatible object storage (e.g. RustFS).
%% Disabled when `null` or `false`.
voice(null) ->
    null;
voice(false) ->
    null;
voice(Map) when is_map(Map) ->
    Endpoint = webui_url(endpoint, maps:get(<<"endpoint">>, Map)),
    Region = voice_token(region, maps:get(<<"region">>, Map, <<"us-east-1">>), 1, 64),
    Bucket = voice_bucket(maps:get(<<"bucket">>, Map, <<"ircd-voice">>)),
    AccessKey = voice_secret(access_key_id, maps:get(<<"access_key_id">>, Map)),
    SecretKey = voice_secret(secret_access_key, maps:get(<<"secret_access_key">>, Map)),
    MaxBytes = voice_int(max_bytes, maps:get(<<"max_bytes">>, Map, 1048576), 1024, 20971520),
    MaxDuration = voice_int(max_duration, maps:get(<<"max_duration">>, Map, 120), 1, 600),
    #{
        endpoint => Endpoint,
        region => Region,
        bucket => Bucket,
        access_key_id => AccessKey,
        secret_access_key => SecretKey,
        max_bytes => MaxBytes,
        max_duration => MaxDuration
    };
voice(Value) ->
    erlang:error({invalid_voice, Value}).

voice_token(_Key, Val, Min, Max) when
    is_binary(Val), byte_size(Val) >= Min, byte_size(Val) =< Max
->
    case re:run(Val, <<"^[A-Za-z0-9._-]+$">>, [{capture, none}]) of
        match -> ircd_wire:retain(Val);
        nomatch -> erlang:error({invalid_voice_token, Val})
    end;
voice_token(Key, Val, _Min, _Max) ->
    erlang:error({invalid_voice, Key, Val}).

voice_bucket(Bucket) when is_binary(Bucket), byte_size(Bucket) >= 3, byte_size(Bucket) =< 63 ->
    case re:run(Bucket, <<"^[a-z0-9][a-z0-9.-]*[a-z0-9]$">>, [{capture, none}]) of
        match -> ircd_wire:retain(Bucket);
        nomatch -> erlang:error({invalid_voice_bucket, Bucket})
    end;
voice_bucket(Bucket) ->
    erlang:error({invalid_voice_bucket, Bucket}).

voice_secret(_Key, Val) when is_binary(Val), byte_size(Val) > 0, byte_size(Val) =< 256 ->
    nomatch = binary:match(Val, [<<0>>, <<"\r">>, <<"\n">>]),
    retain_secret(Val);
voice_secret(Key, _Val) ->
    erlang:error({invalid_voice, Key}).

voice_int(_Key, Val, Min, Max) when is_integer(Val, Min, Max) ->
    Val;
voice_int(Key, Val, _Min, _Max) ->
    erlang:error({invalid_voice, Key, Val}).

%% File sharing stored in S3-compatible object storage (e.g. RustFS).
%% Disabled when `null` or `false`.
files(null) ->
    null;
files(false) ->
    null;
files(Map) when is_map(Map) ->
    Endpoint = webui_url(endpoint, maps:get(<<"endpoint">>, Map)),
    Region = voice_token(region, maps:get(<<"region">>, Map, <<"us-east-1">>), 1, 64),
    Bucket = voice_bucket(maps:get(<<"bucket">>, Map, <<"ircd-files">>)),
    AccessKey = voice_secret(access_key_id, maps:get(<<"access_key_id">>, Map)),
    SecretKey = voice_secret(secret_access_key, maps:get(<<"secret_access_key">>, Map)),
    MaxBytes = files_int(max_bytes, maps:get(<<"max_bytes">>, Map, 10485760), 1024, 104857600),
    #{
        endpoint => Endpoint,
        region => Region,
        bucket => Bucket,
        access_key_id => AccessKey,
        secret_access_key => SecretKey,
        max_bytes => MaxBytes
    };
files(Value) ->
    erlang:error({invalid_files, Value}).

files_int(_Key, Val, Min, Max) when is_integer(Val, Min, Max) ->
    Val;
files_int(Key, Val, _Min, _Max) ->
    erlang:error({invalid_files, Key, Val}).

%% Optional messenger feature toggles. All default to true; set any to false
%% to disable it server-wide.
features(Map) when is_map(Map) ->
    #{
        reactions => boolean_setting(reactions, maps:get(<<"reactions">>, Map, true)),
        replies => boolean_setting(replies, maps:get(<<"replies">>, Map, true)),
        typing => boolean_setting(typing, maps:get(<<"typing">>, Map, true)),
        editing => boolean_setting(editing, maps:get(<<"editing">>, Map, true)),
        redaction => boolean_setting(redaction, maps:get(<<"redaction">>, Map, true)),
        link_previews => boolean_setting(link_previews, maps:get(<<"link_previews">>, Map, true))
    };
features(Value) ->
    erlang:error({invalid_features, Value}).

%%% AI assistant bots (`ai_providers` and `bots`)

-define(MAX_BOTS, 50).
-define(MAX_BOT_CHANNELS, 50).
-define(MAX_SYSTEM_PROMPT_BYTES, 16384).

%% `ai_providers` maps a name to an OpenAI-compatible endpoint. Errors name
%% the provider and field but never carry the API key.
ai_providers(Map) when is_map(Map), map_size(Map) =< 20 ->
    maps:fold(
        fun(Name, Entry, Acc) ->
            case re:run(Name, <<"^[A-Za-z0-9_-]{1,32}$">>, [{capture, none}]) of
                match -> Acc#{Name => ai_provider(Name, Entry)};
                nomatch -> erlang:error({invalid_ai_provider_name, Name})
            end
        end,
        #{},
        Map
    );
ai_providers(Value) ->
    erlang:error({invalid_ai_providers, Value}).

ai_provider(Name, Entry) when is_map(Entry) ->
    BaseUrl = webui_url(base_url, maps:get(<<"base_url">>, Entry, undefined)),
    Trimmed = string:trim(BaseUrl, trailing, "/"),
    {ApiKey, MissingEnv} = provider_key(Name, Entry),
    #{
        name => Name,
        base_url => iolist_to_binary(Trimmed),
        api_key => ApiKey,
        missing_key_env => MissingEnv,
        model => model_name(Name, maps:get(<<"model">>, Entry, undefined)),
        timeout => bot_int(Name, timeout, maps:get(<<"timeout">>, Entry, 60), 1, 600) * 1000
    };
ai_provider(Name, _) ->
    erlang:error({invalid_ai_provider, Name}).

%% Either `api_key` or `api_key_env` (an environment variable read at load);
%% neither means the endpoint needs no key (e.g. a local server). Returns
%% `{Key, MissingEnv}`: an unset or empty `api_key_env` is not a configuration
%% error, so the server still starts; `ircd_bots` skips the provider's bots
%% and logs `bot_disabled` naming the variable.
provider_key(Name, Entry) ->
    case {maps:get(<<"api_key">>, Entry, null), maps:get(<<"api_key_env">>, Entry, null)} of
        {null, null} ->
            {undefined, undefined};
        {Key, null} when is_binary(Key), byte_size(Key) > 0, byte_size(Key) =< 512 ->
            case binary:match(Key, [<<0>>, <<"\r">>, <<"\n">>, <<" ">>]) of
                nomatch -> {retain_secret(Key), undefined};
                _ -> erlang:error({invalid_ai_provider, Name, api_key})
            end;
        {null, Var} when is_binary(Var) ->
            case re:run(Var, <<"^[A-Za-z_][A-Za-z0-9_]{0,63}$">>, [{capture, none}]) of
                match -> ok;
                nomatch -> erlang:error({invalid_ai_provider, Name, api_key_env})
            end,
            case os:getenv(binary_to_list(Var)) of
                Value when is_list(Value), Value =/= [], length(Value) =< 512 ->
                    {retain_secret(unicode:characters_to_binary(Value)), undefined};
                false ->
                    {undefined, ircd_wire:retain(Var)};
                [] ->
                    {undefined, ircd_wire:retain(Var)};
                _ ->
                    erlang:error({invalid_ai_provider, Name, api_key_env})
            end;
        _ ->
            erlang:error({invalid_ai_provider, Name, api_key})
    end.

model_name(Owner, Model) when is_binary(Model), byte_size(Model) > 0, byte_size(Model) =< 200 ->
    case re:run(Model, <<"^[A-Za-z0-9._:/@+-]+$">>, [{capture, none}]) of
        match -> ircd_wire:retain(Model);
        nomatch -> erlang:error({invalid_model, Owner, Model})
    end;
model_name(Owner, Model) ->
    erlang:error({invalid_model, Owner, Model}).

bots(Entries, Providers, NickLen) when is_list(Entries), length(Entries) =< ?MAX_BOTS ->
    Bots = [bot(Entry, Providers, NickLen) || Entry <- Entries],
    Folded = [ircd_wire:fold(maps:get(nick, B)) || B <- Bots],
    case length(lists:usort(Folded)) =:= length(Folded) of
        true -> Bots;
        false -> erlang:error(duplicate_bot_nick)
    end;
bots(Value, _Providers, _NickLen) ->
    erlang:error({invalid_bots, Value}).

bot(Entry, Providers, NickLen) when is_map(Entry) ->
    Nick = maps:get(<<"nick">>, Entry, undefined),
    case is_binary(Nick) andalso ircd_wire:nickname(Nick, NickLen) of
        true -> ok;
        false -> erlang:error({invalid_bot_nick, Nick})
    end,
    ProviderName = maps:get(<<"provider">>, Entry, undefined),
    Provider =
        case Providers of
            #{ProviderName := P} -> P;
            #{} -> erlang:error({unknown_ai_provider, Nick, ProviderName})
        end,
    Model =
        case maps:get(<<"model">>, Entry, null) of
            null -> maps:get(model, Provider);
            M -> model_name(Nick, M)
        end,
    #{
        nick => ircd_wire:retain(Nick),
        user => bot_user(Nick, maps:get(<<"user">>, Entry, <<"bot">>)),
        realname => bot_text(Nick, realname, maps:get(<<"realname">>, Entry, <<"AI assistant">>)),
        provider => Provider,
        model => Model,
        system_prompt => system_prompt(Nick, Entry),
        channels => bot_channels(Nick, maps:get(<<"channels">>, Entry, [])),
        respond_to => bot_choice(
            Nick, respond_to, maps:get(<<"respond_to">>, Entry, <<"mention">>), [
                mention, all
            ]
        ),
        direct_messages => boolean_setting(
            direct_messages, maps:get(<<"direct_messages">>, Entry, true)
        ),
        context => bot_choice(Nick, context, maps:get(<<"context">>, Entry, <<"conversation">>), [
            conversation, channel
        ]),
        history_lines => bot_int(
            Nick, history_lines, maps:get(<<"history_lines">>, Entry, 20), 0, 100
        ),
        max_tokens => bot_int(Nick, max_tokens, maps:get(<<"max_tokens">>, Entry, 512), 1, 32768),
        temperature => bot_temperature(Nick, maps:get(<<"temperature">>, Entry, 0.7)),
        max_reply_lines => bot_int(
            Nick, max_reply_lines, maps:get(<<"max_reply_lines">>, Entry, 6), 1, 30
        ),
        requests_per_minute => bot_int(
            Nick, requests_per_minute, maps:get(<<"requests_per_minute">>, Entry, 10), 1, 600
        )
    };
bot(Entry, _Providers, _NickLen) ->
    erlang:error({invalid_bot, Entry}).

bot_user(_Nick, User) when is_binary(User) ->
    case re:run(User, <<"^[A-Za-z0-9._-]{1,32}$">>, [{capture, none}]) of
        match -> ircd_wire:retain(User);
        nomatch -> erlang:error({invalid_bot_user, User})
    end;
bot_user(Nick, User) ->
    erlang:error({invalid_bot, Nick, user, User}).

bot_text(Nick, Key, Text) when is_binary(Text), byte_size(Text) > 0, byte_size(Text) =< 200 ->
    case binary:match(Text, [<<0>>, <<"\r">>, <<"\n">>]) of
        nomatch -> ircd_wire:retain(Text);
        _ -> erlang:error({invalid_bot, Nick, Key})
    end;
bot_text(Nick, Key, _Text) ->
    erlang:error({invalid_bot, Nick, Key}).

%% `system_prompt` inline, or `system_prompt_file` read at load (relative
%% paths resolve against the working directory); not both.
system_prompt(Nick, Entry) ->
    Prompt =
        case
            {
                maps:get(<<"system_prompt">>, Entry, null),
                maps:get(<<"system_prompt_file">>, Entry, null)
            }
        of
            {null, null} ->
                <<>>;
            {Text, null} when is_binary(Text) ->
                Text;
            {null, Path} when is_binary(Path), byte_size(Path) > 0 ->
                case file:read_file(Path) of
                    {ok, Bytes} ->
                        string:trim(Bytes);
                    {error, Reason} ->
                        erlang:error({invalid_system_prompt_file, Nick, Path, Reason})
                end;
            _ ->
                erlang:error({invalid_bot, Nick, system_prompt})
        end,
    Bin = iolist_to_binary(Prompt),
    case
        byte_size(Bin) =< ?MAX_SYSTEM_PROMPT_BYTES andalso
            is_binary(unicode:characters_to_binary(Bin))
    of
        true -> Bin;
        false -> erlang:error({invalid_bot, Nick, system_prompt})
    end.

bot_channels(Nick, Channels) when is_list(Channels), length(Channels) =< ?MAX_BOT_CHANNELS ->
    [
        case is_binary(Channel) andalso ircd_wire:channel(Channel) of
            true -> ircd_wire:retain(Channel);
            false -> erlang:error({invalid_bot_channel, Nick, Channel})
        end
     || Channel <- Channels
    ];
bot_channels(Nick, Channels) ->
    erlang:error({invalid_bot, Nick, channels, Channels}).

bot_choice(Nick, Key, Value, Allowed) when is_binary(Value) ->
    case [A || A <- Allowed, atom_to_binary(A) =:= Value] of
        [Choice] -> Choice;
        [] -> erlang:error({invalid_bot, Nick, Key, Value})
    end;
bot_choice(Nick, Key, Value, _Allowed) ->
    erlang:error({invalid_bot, Nick, Key, Value}).

%% Bounds are inclusive.
bot_int(_Owner, _Key, Value, Min, Max) when is_integer(Value, Min, Max) ->
    Value;
bot_int(Owner, Key, Value, _Min, _Max) ->
    erlang:error({invalid_bot, Owner, Key, Value}).

bot_temperature(_Nick, Value) when is_number(Value), Value >= 0, Value =< 2 ->
    float(Value);
bot_temperature(Nick, Value) ->
    erlang:error({invalid_bot, Nick, temperature, Value}).

%%% Voice calls relayed through rtpengine (`calls`). Disabled when `null` or
%%% `false`. Bounds are inclusive.

calls(null) ->
    null;
calls(false) ->
    null;
calls(Map) when is_map(Map) ->
    #{
        rtpengine => rtpengine_address(maps:get(<<"rtpengine">>, Map, undefined)),
        ring_timeout => calls_int(ring_timeout, maps:get(<<"ring_timeout">>, Map, 45), 5, 300),
        max_duration => calls_int(max_duration, maps:get(<<"max_duration">>, Map, 7200), 0, 86400),
        max_calls => calls_int(max_calls, maps:get(<<"max_calls">>, Map, 100), 1, 10000),
        calls_per_minute => calls_int(
            calls_per_minute, maps:get(<<"calls_per_minute">>, Map, 6), 1, 120
        ),
        require_account => boolean_setting(
            require_account, maps:get(<<"require_account">>, Map, false)
        )
    };
calls(Value) ->
    erlang:error({invalid_calls, Value}).

%% `host:port` of rtpengine's NG control socket (UDP); the host is a name or
%% an IPv4 address.
rtpengine_address(Value) when is_binary(Value) ->
    case
        re:run(Value, <<"^([A-Za-z0-9.-]{1,253}):([0-9]{1,5})$">>, [
            {capture, all_but_first, binary}
        ])
    of
        {match, [Host, PortBin]} ->
            case binary_to_integer(PortBin) of
                Port when is_integer(Port, 1, 65535) -> {ircd_wire:retain(Host), Port};
                _ -> erlang:error({invalid_calls, rtpengine, Value})
            end;
        nomatch ->
            erlang:error({invalid_calls, rtpengine, Value})
    end;
rtpengine_address(Value) ->
    erlang:error({invalid_calls, rtpengine, Value}).

calls_int(_Key, Value, Min, Max) when is_integer(Value, Min, Max) ->
    Value;
calls_int(Key, Value, _Min, _Max) ->
    erlang:error({invalid_calls, Key, Value}).
