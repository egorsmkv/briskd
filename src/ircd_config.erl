-module(ircd_config).
-export([load/1, secret_match/2]).

%% @doc Compare two secrets without leaking their contents through early exit.
%% Both sides are hashed, then the digests are compared in constant time, so a
%% length mismatch does not return before the secret has been fully read.
-spec secret_match(binary(), binary()) -> boolean().
secret_match(Left, Right) when is_binary(Left), is_binary(Right) ->
    crypto:hash_equals(crypto:hash(sha256, Left), crypto:hash(sha256, Right));
secret_match(_, _) ->
    false.

%% @doc Read and validate the JSON configuration file.
%% Returns a normalized map used by the application supervision tree.
-spec load(file:filename()) -> {ok, map()} | {error, term()}.
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
        Retention = retention(maps:get(<<"retention">>, Json, <<"transient">>)),
        HistoryLimit = history_limit(maps:get(<<"history_limit">>, Json, 100)),
        Operators = operators(maps:get(<<"operators">>, Json, [])),
        Administrators = administrators(maps:get(<<"administrators">>, Json, [])),
        ok = distinct_accounts(Operators, Administrators),
        Channels = channels(maps:get(<<"channels">>, Json, [])),
        ServerLinks = server_links(maps:get(<<"server_links">>, Json, []), Name),
        Admin = admin_info(Json),
        Network = network_name(maps:get(<<"network">>, Json, Name)),
        ServerInfo = text_value(Json, <<"server_info">>, <<"Erlang/OTP IRC server">>),
        {ok, #{
            server_info => ServerInfo,
            shutdown_grace => shutdown_grace(maps:get(<<"shutdown_grace">>, Json, 5)),
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
            nicklen => nicklen(maps:get(<<"nicklen">>, Json, 9)),
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
            admin => Admin
        }}
    catch
        error:Reason -> {error, {invalid_config, Path, Reason}}
    end.

port(null) -> null;
port(Port) when is_integer(Port), Port >= 0, Port =< 65535 -> Port.

%% Logger severity. `trace` is more verbose than `debug`. The other atoms are
%% OTP logger levels. An unknown value is rejected before the server starts.
log_level(<<"trace">>) -> trace;
log_level(<<"debug">>) -> debug;
log_level(<<"info">>) -> info;
log_level(<<"notice">>) -> notice;
log_level(<<"warning">>) -> warning;
log_level(<<"error">>) -> error;
log_level(<<"critical">>) -> critical;
log_level(<<"alert">>) -> alert;
log_level(<<"emergency">>) -> emergency;
log_level(Value) -> erlang:error({invalid_log_level, Value}).

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

%% Email verification for draft/account-registration. `command` is the
%% program (absolute path, then arguments) that delivers a code; `ttl` is how
%% long a code stays valid, in seconds.
account_verification(null) ->
    null;
account_verification(Map) when is_map(Map) ->
    [Exe | Args] = Command = maps:get(<<"command">>, Map),
    true = lists:all(fun(Part) -> is_binary(Part) andalso byte_size(Part) > 0 end, Command),
    true = filename:pathtype(Exe) =:= absolute,
    Ttl = maps:get(<<"ttl">>, Map, 900),
    true = is_integer(Ttl) andalso Ttl > 0 andalso Ttl =< 86400,
    #{command => [binary_to_list(Exe) | [binary_to_list(A) || A <- Args]], ttl => Ttl};
account_verification(Value) ->
    erlang:error({invalid_account_verification, Value}).

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
administrators(Entries) when is_list(Entries) ->
    administrators(Entries, [], []);
administrators(Value) ->
    erlang:error({invalid_administrators, Value}).

administrators([], _Seen, Acc) ->
    lists:reverse(Acc);
administrators([Entry | Rest], Seen, Acc) ->
    Account = administrator(Entry),
    {Nick, _Password} = Account,
    case lists:member(Nick, Seen) of
        true -> erlang:error({duplicate_administrator, Nick});
        false -> administrators(Rest, [Nick | Seen], [Account | Acc])
    end.

administrator(Entry) when is_map(Entry) ->
    Nick = maps:get(<<"nick">>, Entry, undefined),
    Password = maps:get(<<"password">>, Entry, undefined),
    case ircd_wire:nickname(Nick) of
        true -> ok;
        false -> erlang:error({invalid_administrator, Nick})
    end,
    case is_binary(Password) andalso byte_size(Password) > 0 andalso byte_size(Password) =< 400 of
        true -> {ircd_wire:fold(Nick), Password};
        false -> erlang:error({invalid_administrator, Nick})
    end;
administrator(_) ->
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
    Name = maps:get(<<"name">>, Entry, undefined),
    case is_binary(Name) andalso ircd_wire:channel(Name) andalso binary:first(Name) =/= $! of
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
