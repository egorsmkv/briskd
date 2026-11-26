-module(briskd_config_subsystems).
-moduledoc """
JSON section parsers and validators for `m:briskd_config` covering operators,
predefined channels, server links, WebIRC, DroneBL, WebUI, voice/file object
storage, feature switches, AI providers/bots, message search, and calls.
""".
-export([
    admin_info/1,
    administrators/2,
    ai_providers/1,
    bots/3,
    calls/1,
    channels/1,
    distinct_accounts/2,
    dronebl/1,
    features/1,
    files/1,
    operators/1,
    search/1,
    server_links/2,
    voice/1,
    webirc/1,
    webui/1
]).

%% Trusted WebIRC gateways. `hosts` lists gateway IP addresses that may send
%% WEBIRC with `password`. A missing `hosts` list does not trust any address.
-doc """
Parse the `webirc` gateway list.
""".
-spec webirc(term()) -> [briskd_config:webirc_gateway()].
webirc(Entries) when is_list(Entries) ->
    [webirc_entry(Entry) || Entry <- Entries];
webirc(Value) ->
    erlang:error({invalid_webirc, Value}).

webirc_entry(Entry) when is_map(Entry) ->
    Password = maps:get(<<"password">>, Entry),
    true = is_binary(Password) andalso byte_size(Password) > 0,
    Hosts = maps:get(<<"hosts">>, Entry),
    true = is_list(Hosts) andalso Hosts =/= [],
    Parsed = [
        begin
            true = is_binary(Host),
            {ok, Address} = inet:parse_address(binary_to_list(Host)),
            Address
        end
     || Host <- Hosts
    ],
    #{password => retain_binary(Password), hosts => Parsed}.

-doc """
Parse and validate direct `server_links`, rejecting duplicate folded names
or links named after `LocalName`.
""".
-spec server_links(term(), binary()) -> [briskd_config:server_link()].
server_links(Entries, LocalName) when is_list(Entries) ->
    Parsed = [server_link_entry(Entry, LocalName) || Entry <- Entries],
    Names = [briskd_wire:fold(maps:get(name, Link)) || Link <- Parsed],
    true = length(Names) =:= length(lists:usort(Names)),
    Parsed.

server_link_entry(Entry, LocalName) when is_map(Entry) ->
    Name = maps:get(<<"name">>, Entry),
    Host = maps:get(<<"host">>, Entry),
    Port = maps:get(<<"port">>, Entry),
    Password = maps:get(<<"password">>, Entry),
    TLS = maps:get(<<"tls">>, Entry, false),
    true = is_binary(Name),
    match = re:run(Name, <<"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$">>, [
        {capture, none}, dollar_endonly
    ]),
    false = briskd_wire:fold(Name) =:= briskd_wire:fold(LocalName),
    true =
        is_binary(Host) andalso byte_size(Host) > 0 andalso byte_size(Host) =< 253 andalso
            binary:match(Host, [<<0>>, <<" ">>, <<"\r">>, <<"\n">>]) =:= nomatch,
    true = is_integer(Port) andalso Port > 0 andalso Port =< 65535,
    true = is_binary(Password) andalso byte_size(Password) > 0 andalso byte_size(Password) =< 400,
    true = is_boolean(TLS),
    #{
        name => retain_binary(Name),
        host => retain_binary(Host),
        port => retain_port(Port),
        password => retain_binary(Password),
        tls => retain_boolean(TLS)
    }.

retain_binary(Bin) when is_binary(Bin) -> Bin.

retain_port(Port) when is_integer(Port), Port >= 1, Port =< 65535 -> Port.

retain_boolean(Bool) when is_boolean(Bool) -> Bool.

-doc """
Extract `ADMIN` reply fields from the root JSON configuration map.
""".
-spec admin_info(map()) -> briskd_config:admin_info().
admin_info(Json) ->
    #{
        name => briskd_config:text_value(Json, <<"admin_name">>, <<"IRC server administrator">>),
        location1 => briskd_config:text_value(Json, <<"admin_location1">>, <<"Not configured">>),
        location2 => briskd_config:text_value(Json, <<"admin_location2">>, <<"Not configured">>),
        email => briskd_config:text_value(Json, <<"admin_email">>, <<"Not configured">>)
    }.

-doc """
Parse the `operators` credential list with RFC 1459 folded usernames.
""".
-spec operators(term()) -> [briskd_config:credential()].
operators(Entries) when is_list(Entries) ->
    Parsed = [operator_entry(Entry) || Entry <- Entries],
    Keys = [Name || {Name, _} <- Parsed],
    true = length(Keys) =:= length(lists:usort(Keys)),
    Parsed.

operator_entry(Entry) when is_map(Entry) ->
    Name = maps:get(<<"name">>, Entry),
    Password = maps:get(<<"password">>, Entry),
    true = is_binary(Name) andalso byte_size(Name) > 0 andalso byte_size(Name) =< 32,
    true = is_binary(Password) andalso byte_size(Password) > 0,
    {briskd_wire:fold(Name), retain_binary(Password)}.

-doc """
Parse `administrators` credentials validated against `NickLen`.
""".
-spec administrators(term(), pos_integer()) -> [briskd_config:credential()].
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
    case briskd_wire:nickname(Nick, NickLen) of
        true -> ok;
        false -> erlang:error({invalid_administrator, Nick})
    end,
    case is_binary(Password) andalso byte_size(Password) > 0 andalso byte_size(Password) =< 400 of
        true -> {briskd_wire:fold(Nick), Password};
        false -> erlang:error({invalid_administrator, Nick})
    end;
administrator(_, _NickLen) ->
    erlang:error({invalid_administrator, invalid}).

-doc """
Verify no administrator name collides with an operator account.
""".
-spec distinct_accounts([briskd_config:credential()], [briskd_config:credential()]) -> ok.
distinct_accounts(Operators, Administrators) ->
    OperatorNames = [Name || {Name, _} <- Operators],
    case [Nick || {Nick, _} <- Administrators, lists:member(Nick, OperatorNames)] of
        [] -> ok;
        [Nick | _] -> erlang:error({duplicate_administrator, Nick})
    end.

%% Predefined channels are created when no row exists. Safe `!` names are
%% rejected because their identifier is assigned by the server.
-doc """
Parse and validate predefined `channels`.
""".
-spec channels(term()) -> [briskd_config:channel_entry()].
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
    case briskd_wire:channel(Name) andalso binary:first(Name) =/= $! of
        true -> ok;
        false -> erlang:error({invalid_channel, channel_label(Name)})
    end,
    Topic = channel_topic(maps:get(<<"topic">>, Entry, <<>>)),
    Password = channel_key(maps:get(<<"key">>, Entry, null)),
    Limit = channel_limit(maps:get(<<"limit">>, Entry, null)),
    Flags = channel_flags(Name, maps:get(<<"modes">>, Entry, <<>>)),
    #{
        key => briskd_wire:fold(Name),
        name => briskd_wire:retain(Name),
        topic => briskd_wire:retain(Topic),
        password => briskd_config:retain_secret(Password),
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

-doc """
Parse DroneBL DNSBL lookup settings (`boolean()` or object).
""".
-spec dronebl(term()) -> briskd_config:dronebl().
dronebl(false) ->
    dronebl(#{<<"enabled">> => false});
dronebl(true) ->
    dronebl(#{<<"enabled">> => true});
dronebl(Map) when is_map(Map) ->
    Enabled = briskd_config:boolean_setting(
        dronebl_enabled, maps:get(<<"enabled">>, Map, false)
    ),
    Zone = dronebl_zone(maps:get(<<"zone">>, Map, <<"dnsbl.dronebl.org">>)),
    TimeoutMs = dronebl_int(timeout_ms, maps:get(<<"timeout_ms">>, Map, 3000), 100, 30000),
    BanTtl = dronebl_int(ban_ttl, maps:get(<<"ban_ttl">>, Map, 3600), 60, 604800),
    CacheTtl = dronebl_int(cache_ttl, maps:get(<<"cache_ttl">>, Map, 300), 0, 86400),
    Types = dronebl_types(maps:get(<<"types">>, Map, <<"all">>)),
    SkipPrivate = briskd_config:boolean_setting(
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

-doc """
Parse WebUI HTTP listener settings (`null` or `false` disables it).
""".
-spec webui(term()) -> briskd_config:webui().
webui(null) ->
    null;
webui(false) ->
    null;
webui(#{<<"port">> := Port, <<"password">> := Password} = Map) when
    is_integer(Port),
    Port >= 0,
    Port =< 65535,
    is_binary(Password),
    byte_size(Password) > 0,
    byte_size(Password) =< 256
->
    Bind =
        case maps:get(<<"bind">>, Map, <<"127.0.0.1">>) of
            B when is_binary(B) -> B;
            OtherBind -> erlang:error({invalid_webui_bind, OtherBind})
        end,
    {ok, IP} = inet:parse_address(binary_to_list(Bind)),
    Username =
        case maps:get(<<"username">>, Map, <<"admin">>) of
            U when is_binary(U), byte_size(U) > 0, byte_size(U) =< 128 -> U;
            OtherUser -> erlang:error({invalid_webui_username, OtherUser})
        end,
    nomatch = binary:match(Username, [<<0>>, <<":">>, <<"\r">>, <<"\n">>]),
    nomatch = binary:match(Password, [<<0>>, <<"\r">>, <<"\n">>]),
    RetainedPassword =
        case briskd_config:retain_secret(Password) of
            PwBin when is_binary(PwBin) -> PwBin;
            OtherPw -> erlang:error({invalid_webui_password, OtherPw})
        end,
    TermsUrl = webui_url(
        terms_url, maps:get(<<"terms_url">>, Map, <<"https://example.com/terms">>)
    ),
    PrivacyUrl = webui_url(
        privacy_url, maps:get(<<"privacy_url">>, Map, <<"https://example.com/privacy">>)
    ),
    #{
        ip => IP,
        port => Port,
        username => briskd_wire:retain(Username),
        password => RetainedPassword,
        terms_url => TermsUrl,
        privacy_url => PrivacyUrl
    };
webui(Value) ->
    erlang:error({invalid_webui, Value}).

-spec webui_url(atom(), term()) -> binary().
webui_url(_Key, Url) when is_binary(Url), byte_size(Url) =< 2048 ->
    nomatch = binary:match(Url, [
        <<0>>, <<" ">>, <<"\r">>, <<"\n">>, <<"\"">>, <<"'">>, <<"<">>, <<">">>
    ]),
    case Url of
        <<"https://", Rest/binary>> when byte_size(Rest) > 0 -> briskd_wire:retain(Url);
        <<"http://", Rest/binary>> when byte_size(Rest) > 0 -> briskd_wire:retain(Url);
        _ -> erlang:error({invalid_webui_url, Url})
    end;
webui_url(Key, Value) ->
    erlang:error({invalid_webui_url, Key, Value}).

-doc """
Parse voice-message S3 storage settings.
""".
-spec voice(term()) -> briskd_config:voice().
voice(null) ->
    null;
voice(false) ->
    null;
voice(Map) when is_map(Map) ->
    Endpoint = webui_url(endpoint, maps:get(<<"endpoint">>, Map)),
    Region = voice_token(region, maps:get(<<"region">>, Map, <<"us-east-1">>), 1, 64),
    Bucket = voice_bucket(maps:get(<<"bucket">>, Map, <<"briskd-voice">>)),
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
        match -> briskd_wire:retain(Val);
        nomatch -> erlang:error({invalid_voice_token, Val})
    end;
voice_token(Key, Val, _Min, _Max) ->
    erlang:error({invalid_voice, Key, Val}).

voice_bucket(Bucket) when is_binary(Bucket), byte_size(Bucket) >= 3, byte_size(Bucket) =< 63 ->
    case re:run(Bucket, <<"^[a-z0-9][a-z0-9.-]*[a-z0-9]$">>, [{capture, none}]) of
        match -> briskd_wire:retain(Bucket);
        nomatch -> erlang:error({invalid_voice_bucket, Bucket})
    end;
voice_bucket(Bucket) ->
    erlang:error({invalid_voice_bucket, Bucket}).

voice_secret(_Key, Val) when is_binary(Val), byte_size(Val) > 0, byte_size(Val) =< 256 ->
    nomatch = binary:match(Val, [<<0>>, <<"\r">>, <<"\n">>]),
    briskd_config:retain_secret(Val);
voice_secret(Key, _Val) ->
    erlang:error({invalid_voice, Key}).

voice_int(_Key, Val, Min, Max) when is_integer(Val, Min, Max) ->
    Val;
voice_int(Key, Val, _Min, _Max) ->
    erlang:error({invalid_voice, Key, Val}).

-doc """
Parse file-sharing S3 storage settings.
""".
-spec files(term()) -> briskd_config:files().
files(null) ->
    null;
files(false) ->
    null;
files(Map) when is_map(Map) ->
    Endpoint = webui_url(endpoint, maps:get(<<"endpoint">>, Map)),
    Region = voice_token(region, maps:get(<<"region">>, Map, <<"us-east-1">>), 1, 64),
    Bucket = voice_bucket(maps:get(<<"bucket">>, Map, <<"briskd-files">>)),
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

-doc """
Parse optional messenger feature toggle booleans.
""".
-spec features(term()) -> briskd_config:features().
features(Map) when is_map(Map) ->
    #{
        reactions => briskd_config:boolean_setting(reactions, maps:get(<<"reactions">>, Map, true)),
        replies => briskd_config:boolean_setting(replies, maps:get(<<"replies">>, Map, true)),
        typing => briskd_config:boolean_setting(typing, maps:get(<<"typing">>, Map, true)),
        editing => briskd_config:boolean_setting(editing, maps:get(<<"editing">>, Map, true)),
        redaction => briskd_config:boolean_setting(redaction, maps:get(<<"redaction">>, Map, true)),
        link_previews => briskd_config:boolean_setting(
            link_previews, maps:get(<<"link_previews">>, Map, true)
        )
    };
features(Value) ->
    erlang:error({invalid_features, Value}).

%%% AI assistant bots (`ai_providers` and `bots`)

-define(MAX_BOTS, 50).
-define(MAX_BOT_CHANNELS, 50).
-define(MAX_SYSTEM_PROMPT_BYTES, 16384).

-doc """
Parse OpenAI-compatible `ai_providers` definitions.
""".
-spec ai_providers(term()) -> #{binary() => briskd_config:ai_provider()}.
ai_providers(Map) when is_map(Map), map_size(Map) =< 20 ->
    maps:fold(
        fun
            (Name, Entry, Acc) when is_binary(Name) ->
                case re:run(Name, <<"^[A-Za-z0-9_-]{1,32}$">>, [{capture, none}]) of
                    match -> Acc#{Name => ai_provider(Name, Entry)};
                    nomatch -> erlang:error({invalid_ai_provider_name, Name})
                end;
            (Name, _, _) ->
                erlang:error({invalid_ai_provider_name, Name})
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

provider_key(Name, Entry) ->
    case {maps:get(<<"api_key">>, Entry, null), maps:get(<<"api_key_env">>, Entry, null)} of
        {null, null} ->
            {undefined, undefined};
        {Key, null} when is_binary(Key), byte_size(Key) > 0, byte_size(Key) =< 512 ->
            case binary:match(Key, [<<0>>, <<"\r">>, <<"\n">>, <<" ">>]) of
                nomatch -> {briskd_config:retain_secret(Key), undefined};
                _ -> erlang:error({invalid_ai_provider, Name, api_key})
            end;
        {null, Var} when is_binary(Var) ->
            case re:run(Var, <<"^[A-Za-z_][A-Za-z0-9_]{0,63}$">>, [{capture, none}]) of
                match -> ok;
                nomatch -> erlang:error({invalid_ai_provider, Name, api_key_env})
            end,
            case os:getenv(binary_to_list(Var)) of
                Value when is_list(Value), Value =/= [], length(Value) =< 512 ->
                    case unicode:characters_to_binary(Value) of
                        Bin when is_binary(Bin) ->
                            {briskd_config:retain_secret(Bin), undefined};
                        _ ->
                            erlang:error({invalid_ai_provider, Name, api_key_env})
                    end;
                false ->
                    {undefined, briskd_wire:retain(Var)};
                [] ->
                    {undefined, briskd_wire:retain(Var)};
                _ ->
                    erlang:error({invalid_ai_provider, Name, api_key_env})
            end;
        _ ->
            erlang:error({invalid_ai_provider, Name, api_key})
    end.

model_name(Owner, Model) when is_binary(Model), byte_size(Model) > 0, byte_size(Model) =< 200 ->
    case re:run(Model, <<"^[A-Za-z0-9._:/@+-]+$">>, [{capture, none}]) of
        match -> briskd_wire:retain(Model);
        nomatch -> erlang:error({invalid_model, Owner, Model})
    end;
model_name(Owner, Model) ->
    erlang:error({invalid_model, Owner, Model}).

-doc """
Parse AI assistant `bots` definitions against `Providers` and `NickLen`.
""".
-spec bots(term(), #{binary() => briskd_config:ai_provider()}, pos_integer()) ->
    [briskd_config:bot()].
bots(Entries, Providers, NickLen) when is_list(Entries), length(Entries) =< ?MAX_BOTS ->
    Bots = [bot(Entry, Providers, NickLen) || Entry <- Entries],
    Folded = [briskd_wire:fold(maps:get(nick, B)) || B <- Bots],
    case length(lists:usort(Folded)) =:= length(Folded) of
        true -> Bots;
        false -> erlang:error(duplicate_bot_nick)
    end;
bots(Value, _Providers, _NickLen) ->
    erlang:error({invalid_bots, Value}).

bot(Entry, Providers, NickLen) when is_map(Entry) ->
    Nick = maps:get(<<"nick">>, Entry, undefined),
    case is_binary(Nick) andalso briskd_wire:nickname(Nick, NickLen) of
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
        nick => briskd_wire:retain(Nick),
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
        direct_messages => briskd_config:boolean_setting(
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
        match -> briskd_wire:retain(User);
        nomatch -> erlang:error({invalid_bot_user, User})
    end;
bot_user(Nick, User) ->
    erlang:error({invalid_bot, Nick, user, User}).

bot_text(Nick, Key, Text) when is_binary(Text), byte_size(Text) > 0, byte_size(Text) =< 200 ->
    case binary:match(Text, [<<0>>, <<"\r">>, <<"\n">>]) of
        nomatch -> briskd_wire:retain(Text);
        _ -> erlang:error({invalid_bot, Nick, Key})
    end;
bot_text(Nick, Key, _Text) ->
    erlang:error({invalid_bot, Nick, Key}).

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
        case is_binary(Channel) andalso briskd_wire:channel(Channel) of
            true -> briskd_wire:retain(Channel);
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

bot_int(_Owner, _Key, Value, Min, Max) when is_integer(Value, Min, Max) ->
    Value;
bot_int(Owner, Key, Value, _Min, _Max) ->
    erlang:error({invalid_bot, Owner, Key, Value}).

bot_temperature(_Nick, Value) when is_number(Value), Value >= 0, Value =< 2 ->
    float(Value);
bot_temperature(Nick, Value) ->
    erlang:error({invalid_bot, Nick, temperature, Value}).

-doc """
Parse `search` (briskd-search service) configuration.
""".
-spec search(term()) -> briskd_config:search().
search(null) ->
    null;
search(false) ->
    null;
search(Map) when is_map(Map) ->
    #{
        url => strip_slash(webui_url(url, maps:get(<<"url">>, Map, undefined))),
        token => search_token(Map),
        timeout => search_int(timeout, maps:get(<<"timeout">>, Map, 3000), 100, 60000),
        max_results => search_int(max_results, maps:get(<<"max_results">>, Map, 50), 1, 200)
    };
search(Value) ->
    erlang:error({invalid_search, Value}).

strip_slash(Url) ->
    case binary:last(Url) of
        $/ -> strip_slash(binary:part(Url, 0, byte_size(Url) - 1));
        _ -> Url
    end.

search_token(Map) ->
    case {maps:get(<<"token">>, Map, null), maps:get(<<"token_env">>, Map, null)} of
        {null, null} ->
            undefined;
        {Token, null} when is_binary(Token) ->
            search_token_value(Token);
        {null, Var} when is_binary(Var) ->
            case re:run(Var, <<"^[A-Za-z_][A-Za-z0-9_]{0,63}$">>, [{capture, none}]) of
                match -> ok;
                nomatch -> erlang:error({invalid_search, token_env})
            end,
            case os:getenv(binary_to_list(Var)) of
                Value when is_list(Value), Value =/= [] ->
                    search_token_value(unicode:characters_to_binary(Value));
                _ ->
                    erlang:error({invalid_search, token_env, unset})
            end;
        _ ->
            erlang:error({invalid_search, token})
    end.

search_token_value(Token) when byte_size(Token) > 0, byte_size(Token) =< 512 ->
    case binary:match(Token, [<<0>>, <<"\r">>, <<"\n">>, <<" ">>]) of
        nomatch -> briskd_config:retain_secret(Token);
        _ -> erlang:error({invalid_search, token})
    end;
search_token_value(_) ->
    erlang:error({invalid_search, token}).

search_int(_Key, Value, Min, Max) when is_integer(Value, Min, Max) ->
    Value;
search_int(Key, Value, _Min, _Max) ->
    erlang:error({invalid_search, Key, Value}).

-doc """
Parse voice/video `calls` configuration. `rtpflux` is the `host:port` of the
media relay's NG control socket (rtpflux, or any relay that speaks rtpengine's
NG protocol). `rtpengine` is the deprecated name of the same key; a config
that sets both is rejected.
""".
-spec calls(term()) -> briskd_config:calls().
calls(null) ->
    null;
calls(false) ->
    null;
calls(Map) when is_map(Map) ->
    #{
        rtpflux => ng_address(ng_setting(Map)),
        ring_timeout => calls_int(ring_timeout, maps:get(<<"ring_timeout">>, Map, 45), 5, 300),
        max_duration => calls_int(max_duration, maps:get(<<"max_duration">>, Map, 7200), 0, 86400),
        max_calls => calls_int(max_calls, maps:get(<<"max_calls">>, Map, 100), 1, 10000),
        calls_per_minute => calls_int(
            calls_per_minute, maps:get(<<"calls_per_minute">>, Map, 6), 1, 120
        ),
        require_account => briskd_config:boolean_setting(
            require_account, maps:get(<<"require_account">>, Map, false)
        ),
        video => briskd_config:boolean_setting(video, maps:get(<<"video">>, Map, true))
    };
calls(Value) ->
    erlang:error({invalid_calls, Value}).

ng_setting(#{<<"rtpflux">> := _, <<"rtpengine">> := _}) ->
    erlang:error({invalid_calls, rtpflux, both_rtpflux_and_rtpengine});
ng_setting(#{<<"rtpengine">> := Value}) ->
    Value;
ng_setting(Map) ->
    maps:get(<<"rtpflux">>, Map, undefined).

ng_address(Value) when is_binary(Value) ->
    case
        re:run(Value, <<"^([A-Za-z0-9.-]{1,253}):([0-9]{1,5})$">>, [
            {capture, all_but_first, binary}
        ])
    of
        {match, [Host, PortBin]} ->
            case binary_to_integer(PortBin) of
                Port when is_integer(Port, 1, 65535) -> {briskd_wire:retain(Host), Port};
                _ -> erlang:error({invalid_calls, rtpflux, Value})
            end;
        nomatch ->
            erlang:error({invalid_calls, rtpflux, Value})
    end;
ng_address(Value) ->
    erlang:error({invalid_calls, rtpflux, Value}).

calls_int(_Key, Value, Min, Max) when is_integer(Value, Min, Max) ->
    Value;
calls_int(Key, Value, _Min, _Max) ->
    erlang:error({invalid_calls, Key, Value}).
