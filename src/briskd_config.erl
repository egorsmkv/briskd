-module(briskd_config).
-moduledoc """
Loads and validates the JSON server configuration.

`load/1` reads one JSON file, fills in defaults, validates every key, and
returns one normalized map. `m:briskd_app` loads the file named by the
`BRISKD_CONFIG` environment variable (default `config/briskd.json`) at startup,
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
  unique under `briskd_wire:fold/1`.
- Operator and administrator account names must be distinct.

The module also provides `secret_match/2` for comparing configured passwords.
""".
-export([
    boolean_setting/2,
    current/0,
    current_or_empty/0,
    load/1,
    parse_log_level/1,
    retain_secret/1,
    secret_match/2,
    store/1,
    base/0,
    store_base/1,
    text_value/3
]).

%% Listener port, or `null` when that listener is off.
-type port_or_null() :: null | inet:port_number().

-doc """
Normalized configuration `load/1` returns. Every key is present. Optional
sections are `null` when unset. A predefined channel's password and limit
use `undefined`.
""".
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
    search := search(),
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

-doc """
One entry of the configured `channels` list: folded key, wire name, topic,
optional key and limit (`undefined` when the JSON value was `null`), and
mode flags.
""".
-type channel_entry() :: #{
    key := binary(),
    name := binary(),
    topic := binary(),
    %% NB: channel_key/channel_limit map JSON null to `undefined`, not `null`.
    password := undefined | binary(),
    limit := undefined | 1..2147483647,
    flags := #{char() => true}
}.

-doc """
One direct server peer (RFC 2813): name, host, port, link password, and
whether that hop uses TLS.
""".
-type server_link() :: #{
    name := binary(),
    host := binary(),
    port := 1..65535,
    password := binary(),
    tls := boolean()
}.

-doc """
`ADMIN` reply fields (RFC 2812): server name, two location lines, and an
email address.
""".
-type admin_info() :: #{
    name := binary(),
    location1 := binary(),
    location2 := binary(),
    email := binary()
}.

-doc """
Command and message flood limits. `null` turns flood control off. An omitted
`flood` key uses the default limits.
""".
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

-doc """
DroneBL DNSBL settings. JSON `false` and `true` are the shorthands
`#{enabled => false}` and `#{enabled => true}` with the other defaults filled in.
""".
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

-doc "Admin WebUI listener, or `null` when `webui` is `false` or absent.".
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

-doc "End-to-end encryption broker limits, or `null` when E2EE is off.".
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

-doc """
Voice-message object storage, or `null` when `voice` is `false` or absent.
The same fields as an S3 bucket, plus `max_duration` in seconds.
""".
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

-doc "File-upload object storage, or `null` when file uploads are off.".
-type files() :: null | s3_bucket().

-doc """
briskd-search client settings, or `null` when message search is off.
See `m:briskd_search`.
""".
-type search() ::
    null
    | #{
        url := binary(),
        token := undefined | binary(),
        timeout := 100..60000,
        max_results := 1..200
    }.

-doc """
Voice and video call settings, or `null` when calls are off: the rtpengine
address, ring and duration limits, and whether an account is required.
""".
-type calls() ::
    null
    | #{
        rtpengine := {binary(), 1..65535},
        ring_timeout := 5..300,
        max_duration := 0..86400,
        max_calls := 1..10000,
        calls_per_minute := 1..120,
        require_account := boolean(),
        video := boolean()
    }.

-doc """
Chat feature switches: reactions, replies, typing notifications, editing,
redaction, and link previews.
""".
-type features() :: #{
    reactions := boolean(),
    replies := boolean(),
    typing := boolean(),
    editing := boolean(),
    redaction := boolean(),
    link_previews := boolean()
}.

-doc """
How a new account proves its email address, or `null` when verification is
off. `ttl` is the code lifetime in seconds. At least one of `command` and
`smtp` delivers the code; `verify_url` is the page the message links to.
""".
-type account_verification() ::
    null
    | #{
        ttl := 1..86400,
        %% present when `command` was configured: absolute exe + args as strings
        command => [string(), ...],
        smtp => smtp(),
        verify_url => binary()
    }.

-doc "SMTP relay used to send account-verification and password-reset mail.".
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

-doc """
OpenAI-compatible chat provider for assistant bots. `timeout` is milliseconds.
`missing_key_env` names an empty `api_key_env` variable, otherwise
`undefined`.
""".
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

-doc """
One AI assistant bot: its identity, provider, the channels it joins, and when
it answers.
""".
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
    credential/0,
    webirc_gateway/0,
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
    search/0,
    features/0,
    account_verification/0,
    smtp/0,
    ai_provider/0,
    bot/0
]).

-doc """
The running server's configuration, as `load/1` returned it (with the log
level and feature switches an operator may have changed since). Raises
`badarg` before `m:briskd_state` has stored it.
""".
-spec current() -> config().
current() ->
    stored(persistent_term:get({briskd_state, config})).

-doc """
Like `current/0`, but an empty map before the server has stored its
configuration. For code that also runs without `m:briskd_state` (some unit
tests) and reads every key with a default.
""".
-spec current_or_empty() -> config() | #{}.
current_or_empty() ->
    stored(persistent_term:get({briskd_state, config}, #{})).

-doc """
Store `Config` as the running configuration. Called by `m:briskd_state` at
startup and on `REHASH`, and when an operator changes the log level or a
feature switch.
""".
-spec store(config()) -> ok.
store(Config) ->
    persistent_term:put({briskd_state, config}, Config).

-doc """
The configuration as the file says (the last `load/1` that startup or
`REHASH` accepted), before admin overrides (`m:briskd_overrides`). Falls back
to `current/0` before one is stored.
""".
-spec base() -> config().
base() ->
    stored(
        persistent_term:get(
            {briskd_state, base_config}, persistent_term:get({briskd_state, config})
        )
    ).

-doc "Store `Config` as the file's configuration (see `base/0`).".
-spec store_base(config()) -> ok.
store_base(Config) ->
    persistent_term:put({briskd_state, base_config}, Config).

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
        Operators = briskd_config_subsystems:operators(maps:get(<<"operators">>, Json, [])),
        Administrators = briskd_config_subsystems:administrators(
            maps:get(<<"administrators">>, Json, []), NickLen
        ),
        ok = briskd_config_subsystems:distinct_accounts(Operators, Administrators),
        Channels = briskd_config_subsystems:channels(maps:get(<<"channels">>, Json, [])),
        ServerLinks = briskd_config_subsystems:server_links(
            maps:get(<<"server_links">>, Json, []), Name
        ),
        Providers = briskd_config_subsystems:ai_providers(maps:get(<<"ai_providers">>, Json, #{})),
        Bots = briskd_config_subsystems:bots(maps:get(<<"bots">>, Json, []), Providers, NickLen),
        Admin = briskd_config_subsystems:admin_info(Json),
        Network = network_name(maps:get(<<"network">>, Json, Name)),
        ServerInfo = text_value(Json, <<"server_info">>, <<"Erlang/OTP IRC server">>),
        {ok, #{
            server_info => ServerInfo,
            shutdown_grace => shutdown_grace(maps:get(<<"shutdown_grace">>, Json, 5)),
            max_sendq => max_sendq(maps:get(<<"max_sendq">>, Json, 10000)),
            flood => flood(maps:get(<<"flood">>, Json, #{})),
            dronebl => briskd_config_subsystems:dronebl(maps:get(<<"dronebl">>, Json, false)),
            webui => briskd_config_subsystems:webui(maps:get(<<"webui">>, Json, null)),
            e2ee => e2ee(maps:get(<<"e2ee">>, Json, null)),
            voice => briskd_config_subsystems:voice(maps:get(<<"voice">>, Json, null)),
            files => briskd_config_subsystems:files(maps:get(<<"files">>, Json, null)),
            calls => briskd_config_subsystems:calls(maps:get(<<"calls">>, Json, null)),
            search => briskd_config_subsystems:search(maps:get(<<"search">>, Json, null)),
            features => briskd_config_subsystems:features(maps:get(<<"features">>, Json, #{})),
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
            webirc => briskd_config_subsystems:webirc(maps:get(<<"webirc">>, Json, [])),
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

%% Client flood and spam control (briskd_flood). `null` turns it off.
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

%% End-to-end encryption broker (briskd_e2ee). `null` (the default) turns it
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

%% Seconds between TLS certificate file checks (briskd_certs); 0 disables.
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

-doc "Validate a boolean configuration value under `Key`.".
-spec boolean_setting(atom(), term()) -> boolean().
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
        relay => briskd_wire:retain(Relay),
        port => Port,
        from => briskd_wire:retain(From),
        tls => Tls,
        ssl => Ssl,
        subject => briskd_wire:retain(Subject),
        username =>
            case User of
                null -> null;
                _ -> briskd_wire:retain(User)
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
        <<"https://", Rest/binary>> when byte_size(Rest) > 0 -> briskd_wire:retain(Url);
        <<"http://", Rest/binary>> when byte_size(Rest) > 0 -> briskd_wire:retain(Url);
        _ -> erlang:error({invalid_verify_url, Url})
    end;
verify_url(Value) ->
    erlang:error({invalid_verify_url, Value}).

-doc "Copy a configured binary secret onto the process heap so it does not pin a file buffer.".
-spec retain_secret(undefined | binary()) -> undefined | binary().
retain_secret(undefined) -> undefined;
retain_secret(Secret) -> briskd_wire:retain(Secret).

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

-doc "Read a non-empty binary text field from `Json` with a fallback default.".
-spec text_value(map(), binary(), binary()) -> binary().
text_value(Json, Key, Default) ->
    case maps:get(Key, Json, Default) of
        Value when is_binary(Value), byte_size(Value) > 0 -> Value;
        _ -> erlang:error({invalid_text_setting, Key})
    end.
