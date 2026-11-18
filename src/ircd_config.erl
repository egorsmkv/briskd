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
        true = TCP =/= null orelse TLS =/= null,
        TLSOptions = tls_options(TLS, Json),
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
        {ok, #{
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

tls_options(null, _) ->
    [];
tls_options(_, Json) ->
    [
        {certfile, binary_to_list(maps:get(<<"certfile">>, Json))},
        {keyfile, binary_to_list(maps:get(<<"keyfile">>, Json))},
        {versions, ['tlsv1.3', 'tlsv1.2']}
    ].

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
