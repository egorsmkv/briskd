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
        Level = binary_to_existing_atom(maps:get(<<"log_level">>, Json, <<"info">>)),
        true = lists:member(Level, [debug, info, notice, warning, error, critical, alert, emergency]),
        Format = maps:get(<<"log_format">>, Json, <<"json">>),
        true = lists:member(Format, [<<"json">>, <<"text">>]),
        MaxClients = positive_limit(maps:get(<<"max_clients">>, Json, 10000)),
        ReopDelay = positive_limit(maps:get(<<"reop_delay">>, Json, 30)),
        MotdFile = optional_path(maps:get(<<"motd_file">>, Json, null)),
        ClientPassword = optional_secret(maps:get(<<"client_password">>, Json, null)),
        MnesiaDir = required_path(maps:get(<<"mnesia_dir">>, Json, <<"data/mnesia">>)),
        Operators = operators(maps:get(<<"operators">>, Json, [])),
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
            operators => Operators,
            server_links => ServerLinks,
            admin => Admin
        }}
    catch
        error:Reason -> {error, {invalid_config, Path, Reason}}
    end.

port(null) -> null;
port(Port) when is_integer(Port), Port >= 0, Port =< 65535 -> Port.

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
