-module(ircd_cap).
-export([
    advertised/1,
    client_tags/1,
    connect/1,
    connect/2,
    disable/2,
    disconnect/1,
    enabled/2,
    enabled_set/1,
    finish/2,
    hold/1,
    info/1,
    label/2,
    list_names/1,
    multiline_limits/0,
    metadata_limits/0,
    note_ls/2,
    offered/0,
    pack/2,
    request/2,
    restore/2,
    sasl_mechanisms/0,
    set_info/3,
    state/1,
    welcomed/1
]).

-moduledoc """
Per-connection capability negotiation state
([IRCv3 capability negotiation](https://ircv3.net/specs/extensions/capability-negotiation),
version 302 with [cap-notify](https://ircv3.net/specs/extensions/capability-negotiation#cap-notify)),
and the capability values this server advertises.

State lives in the `ircd_caps` ETS table, one map per client pid, created by
`m:ircd_state` and written only from that process; it is transient and
dropped on disconnect. The `CAP` command itself is handled by
`m:ircd_state_net`, which uses this module for the state transitions. Each
connection also records connection facts (`info/1`: `secure`, `certfp`,
`transport`, `webirc`, `ip`).

The offered set (`advertised/1`) depends on configuration and transport:
`sts` advertises an upgrade port on plaintext connections and a persistence
policy on TLS connections, `tls` (STARTTLS) is offered only on plaintext TCP
with TLS configured, and `draft/account-registration` disappears when
registration is disabled. `CAP REQ` is atomic: one unknown, unoffered, or
unrequestable (`sts`) name rejects the whole list. Version 302 is the
highest negotiation version; at that version `cap-notify` is implicit and
cannot be removed.
""".

-define(CAPS, [
    <<"account-notify">>,
    <<"account-tag">>,
    <<"away-notify">>,
    <<"batch">>,
    <<"cap-notify">>,
    <<"chghost">>,
    <<"draft/account-registration">>,
    <<"draft/channel-rename">>,
    <<"draft/chathistory">>,
    <<"draft/event-playback">>,
    <<"draft/extended-isupport">>,
    <<"draft/message-redaction">>,
    <<"draft/metadata-2">>,
    <<"draft/multiline">>,
    <<"draft/oper-tag">>,
    <<"draft/pre-away">>,
    <<"draft/read-marker">>,
    <<"echo-message">>,
    <<"egorsmkv.github.io/e2ee">>,
    <<"egorsmkv.github.io/features">>,
    <<"egorsmkv.github.io/files">>,
    <<"egorsmkv.github.io/voice">>,
    <<"extended-join">>,
    <<"extended-monitor">>,
    <<"invite-notify">>,
    <<"labeled-response">>,
    <<"message-tags">>,
    <<"multi-prefix">>,
    <<"no-implicit-names">>,
    <<"sasl">>,
    <<"server-time">>,
    <<"setname">>,
    <<"standard-replies">>,
    <<"sts">>,
    <<"tls">>,
    <<"userhost-in-names">>
]).

%% Capabilities that are advertised but cannot be enabled with CAP REQ.
%% STS: clients MUST NOT request it and servers MAY NAK the request.
-define(UNREQUESTABLE, [<<"sts">>]).

%% draft/multiline limits. max-bytes counts the combined message body.
-define(MULTILINE_MAX_BYTES, 4096).
-define(MULTILINE_MAX_LINES, 100).
%% draft/metadata-2 limits.
-define(METADATA_MAX_SUBS, 50).
-define(METADATA_MAX_KEYS, 50).
-define(METADATA_MAX_VALUE_BYTES, 300).

-doc """
Every capability name this server knows, in a stable (advertisement)
order. Some are offered only under conditions; see `advertised/1`.
""".
-spec offered() -> [binary()].
offered() -> ?CAPS.

-doc """
SASL mechanisms advertised in the `sasl` capability value and in 908
RPL_SASLMECHS. Implemented in `m:ircd_sasl`.
""".
-spec sasl_mechanisms() -> [binary()].
sasl_mechanisms() -> [<<"EXTERNAL">>, <<"PLAIN">>, <<"SCRAM-SHA-256">>].

-doc """
`{MaxBytes, MaxLines}` for draft/multiline batches (4096 bytes of combined
body, 100 lines), as advertised in the capability value.
""".
-spec multiline_limits() -> {pos_integer(), pos_integer()}.
multiline_limits() -> {?MULTILINE_MAX_BYTES, ?MULTILINE_MAX_LINES}.

-doc """
`{MaxSubs, MaxKeys, MaxValueBytes}` for draft/metadata-2 (50, 50, 300), as
advertised in the capability value.
""".
-spec metadata_limits() -> {pos_integer(), pos_integer(), pos_integer()}.
metadata_limits() -> {?METADATA_MAX_SUBS, ?METADATA_MAX_KEYS, ?METADATA_MAX_VALUE_BYTES}.

-doc """
Create negotiation state for a new connection with no connection facts.
Same as `connect(Pid, #{})`.
""".
-spec connect(pid()) -> true.
connect(Pid) ->
    connect(Pid, #{}).

-doc """
Create negotiation state for a new connection, replacing any old row.

`Info` carries connection facts such as `transport`, `secure` (TLS or a
trusted secure WebIRC gateway), and `certfp` (lowercase hex SHA-256 client
certificate fingerprint).
""".
-spec connect(pid(), map()) -> true.
connect(Pid, Info) ->
    ets:insert(ircd_caps, {Pid, (initial())#{info => Info}}).

-doc """
Drop the connection's capability state when it closes or attaches to
another session.
""".
-spec disconnect(pid()) -> true.
disconnect(Pid) ->
    ets:delete(ircd_caps, Pid).

-doc """
Connection facts recorded at connect time, by `STARTTLS`, or by `WEBIRC`.
""".
-spec info(pid()) -> map().
info(Pid) ->
    maps:get(info, state(Pid), #{}).

-doc """
Set one connection fact, for example `secure` after `STARTTLS` or `WEBIRC`.
""".
-spec set_info(pid(), atom(), term()) -> ok.
set_info(Pid, Key, Value) ->
    State = state(Pid),
    Info = maps:get(info, State, #{}),
    store(Pid, State#{info => Info#{Key => Value}}).

-doc """
Return whether the connection has the named capability enabled, counting
the implicit `cap-notify` at version 302. Unknown pids have none.
""".
-spec enabled(pid(), binary()) -> boolean().
enabled(Pid, Name) ->
    maps:is_key(Name, effective(state(Pid))).

-doc """
The set of enabled capability names, including implicit `cap-notify`. Used
for per-recipient tag filtering in `m:ircd_state_send`.
""".
-spec enabled_set(pid()) -> #{binary() => true}.
enabled_set(Pid) ->
    effective(state(Pid)).

-doc """
Read the connection's negotiation state map (`version`, `enabled`,
`negotiating`, `welcomed`, `info`). A missing row reads as unnegotiated.
""".
-spec state(pid()) -> map().
state(Pid) ->
    case ets:lookup(ircd_caps, Pid) of
        [{_, State}] -> State;
        [] -> initial()
    end.

-doc """
True after the registration welcome (001) has been sent.
""".
-spec welcomed(pid()) -> boolean().
welcomed(Pid) ->
    maps:get(welcomed, state(Pid)).

-doc """
Suspend registration until `CAP END` when the client is not yet welcomed
(on `CAP LS` or `CAP REQ`, as the specification requires).
""".
-spec hold(pid()) -> ok.
hold(Pid) ->
    State = state(Pid),
    case maps:get(welcomed, State) of
        true -> ok;
        false -> store(Pid, State#{negotiating => true})
    end.

-doc """
Record a `CAP LS <version>`: any version of 302 or higher is stored as 302,
the highest version this server supports. A later unversioned or lower
`CAP LS` does not reduce the stored version.
""".
-spec note_ls(pid(), [binary()]) -> ok.
note_ls(Pid, Params) ->
    State = state(Pid),
    case requested_version(Params) of
        Version when is_integer(Version), Version >= 302 ->
            store(Pid, State#{version => 302});
        _ ->
            ok
    end.

-doc """
Capabilities offered to this connection with their values, in
advertisement order. `undefined` means the capability has no value.
""".
-spec advertised(pid()) -> [{binary(), undefined | binary()}].
advertised(Pid) ->
    Info = info(Pid),
    [{Name, Value} || Name <- ?CAPS, {ok, Value} <- [value(Name, Info)]].

-doc """
Enabled capability names in advertisement order, for `CAP LIST`.
""".
-spec list_names(pid()) -> [binary()].
list_names(Pid) ->
    Enabled = effective(state(Pid)),
    [Name || Name <- ?CAPS, maps:is_key(Name, Enabled)].

-doc """
Apply one atomic `CAP REQ` with space-separated tokens (`name` enables,
`-name` disables).

Returns `{ack, Tokens}` after applying every token, or `{nak, Tokens}`
without changing anything when a name is unknown, not offered to this
connection, unrequestable (`sts`), empty, or is `-cap-notify` at version 302.
""".
-spec request(pid(), [binary()]) -> {ack | nak, binary()}.
request(Pid, Params) ->
    State = state(Pid),
    Tokens = tokens(Params),
    Offered = [Name || {Name, _} <- advertised(Pid)],
    case apply_tokens(Tokens, effective(State), maps:get(version, State), Offered) of
        {ok, Enabled} ->
            store(Pid, State#{enabled => without_implicit(Enabled, State)}),
            {ack, join(Tokens)};
        error ->
            {nak, join(Tokens)}
    end.

-doc """
Put back a negotiation state read earlier with `state/1`.
""".
-spec restore(pid(), map()) -> ok.
restore(Pid, State) ->
    store(Pid, State).

-doc """
Disable capabilities that the server no longer offers to the connection
(after `CAP DEL`).
""".
-spec disable(pid(), [binary()]) -> ok.
disable(Pid, Names) ->
    State = state(Pid),
    store(Pid, State#{enabled => maps:without(Names, maps:get(enabled, State))}).

-doc """
End negotiation (`CAP END`). `Ready` says whether `NICK`/`USER` are done.

Returns `welcome` when the held registration reply is now due (and marks the
connection welcomed), `pending` when registration is still incomplete, and
`ignore` when the client was already welcomed.
""".
-spec finish(pid(), boolean()) -> welcome | ignore | pending.
finish(Pid, Ready) ->
    State = state(Pid),
    case maps:get(welcomed, State) of
        true ->
            ignore;
        false when Ready ->
            store(Pid, State#{negotiating => false, welcomed => true}),
            welcome;
        false ->
            store(Pid, State#{negotiating => false}),
            pending
    end.

-doc """
The client-only (`+`-prefixed) tags of a tag list, in order. The parser
already applied last-key-wins.
""".
-spec client_tags([{binary(), undefined | binary()}]) -> [{binary(), undefined | binary()}].
client_tags(Tags) ->
    [{Key, Value} || {<<$+, _/binary>> = Key, Value} <- Tags].

-doc """
The `label` tag value when labeled responses are active for the
negotiation `State` (both `labeled-response` and `batch` enabled).
Returns `undefined` otherwise, or when the label is empty or longer than 64
bytes.
""".
-spec label(map(), [{binary(), undefined | binary()}]) -> undefined | binary().
label(State, Tags) ->
    Enabled = effective(State),
    %% labeled-response depends on `batch`, not on `message-tags`.
    Active =
        maps:is_key(<<"batch">>, Enabled) andalso
            maps:is_key(<<"labeled-response">>, Enabled),
    case Active of
        true ->
            case lists:keyfind(<<"label">>, 1, Tags) of
                {_, Value} when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 64 ->
                    Value;
                _ ->
                    undefined
            end;
        false ->
            undefined
    end.

-doc """
Pack capability tokens, space-separated, into trailing parameters of at
most `Max` bytes each, for multi-line `CAP LS` / `CAP LIST` replies. A
single token longer than `Max` gets its own parameter. An empty list gives
one empty parameter.
""".
-spec pack([binary()], pos_integer()) -> [binary()].
pack([], _Max) ->
    [<<>>];
pack(Names, Max) ->
    pack_names(Names, Max, <<>>, []).

initial() ->
    #{version => 0, enabled => #{}, negotiating => false, welcomed => false, info => #{}}.

store(Pid, State) ->
    ets:insert(ircd_caps, {Pid, State}),
    ok.

effective(#{version := Version, enabled := Enabled}) when Version >= 302 ->
    Enabled#{<<"cap-notify">> => true};
effective(#{enabled := Enabled}) ->
    Enabled.

%% `cap-notify` is implicit at version 302, so it is not stored as a REQ bit.
without_implicit(Enabled, #{version := Version}) when Version >= 302 ->
    maps:remove(<<"cap-notify">>, Enabled);
without_implicit(Enabled, _) ->
    Enabled.

%% Capability values. `error` means the capability is not offered.
value(<<"sasl">>, _Info) ->
    {ok, iolist_to_binary(lists:join(<<",">>, sasl_mechanisms()))};
value(<<"sts">>, Info) ->
    sts_value(config(sts, null), maps:get(secure, Info, false));
value(<<"tls">>, Info) ->
    Configured = config(tls_options, []) =/= [],
    case
        Configured andalso maps:get(transport, Info, undefined) =:= tcp andalso
            not maps:get(secure, Info, false)
    of
        true -> {ok, undefined};
        false -> error
    end;
value(<<"draft/multiline">>, _Info) ->
    {ok,
        iolist_to_binary([
            <<"max-bytes=">>,
            integer_to_binary(?MULTILINE_MAX_BYTES),
            <<",max-lines=">>,
            integer_to_binary(?MULTILINE_MAX_LINES)
        ])};
value(<<"draft/metadata-2">>, _Info) ->
    {ok,
        iolist_to_binary([
            <<"before-connect,max-subs=">>,
            integer_to_binary(?METADATA_MAX_SUBS),
            <<",max-keys=">>,
            integer_to_binary(?METADATA_MAX_KEYS),
            <<",max-value-bytes=">>,
            integer_to_binary(?METADATA_MAX_VALUE_BYTES)
        ])};
value(<<"draft/account-registration">>, _Info) ->
    case config(account_registration, true) of
        true ->
            Email =
                case
                    config(account_verification, null) =/= null orelse
                        config(account_registration_email_required, false)
                of
                    true -> <<",email-required">>;
                    false -> <<>>
                end,
            Before =
                case config(account_registration_before_connect, true) of
                    true -> <<"before-connect,">>;
                    false -> <<>>
                end,
            {ok,
                <<Before/binary, "custom-account-name", Email/binary, ",min-password-length=",
                    (integer_to_binary(ircd_account:min_password()))/binary,
                    ",max-password-length=300">>};
        false ->
            error
    end;
%% End-to-end encryption broker (ircd_e2ee): offered only when configured.
value(<<"egorsmkv.github.io/e2ee">>, _Info) ->
    case ircd_e2ee:enabled() of
        true -> {ok, ircd_e2ee:cap_value()};
        false -> error
    end;
%% Voice messages (ircd_voice): offered only when S3 storage is configured.
value(<<"egorsmkv.github.io/voice">>, _Info) ->
    case ircd_voice:enabled() of
        true -> {ok, ircd_voice:cap_value()};
        false -> error
    end;
%% Message redaction: offered unless disabled in `features.redaction`.
value(<<"draft/message-redaction">>, _Info) ->
    case maps:get(redaction, config(features, #{}), true) of
        true -> {ok, undefined};
        false -> error
    end;
%% Server-wide messenger feature flags for WebIRC and compatible clients.
value(<<"egorsmkv.github.io/features">>, _Info) ->
    Features = config(features, #{}),
    Enabled = [
        Name
     || {Key, Name} <- [
            {reactions, <<"reactions">>},
            {replies, <<"replies">>},
            {typing, <<"typing">>},
            {editing, <<"editing">>},
            {redaction, <<"redaction">>},
            {link_previews, <<"link_previews">>}
        ],
        maps:get(Key, Features, true)
    ],
    case Enabled of
        [] -> {ok, <<"none">>};
        _ -> {ok, iolist_to_binary(lists:join(<<",">>, Enabled))}
    end;
%% File sharing (ircd_files): offered only when S3 storage is configured.
value(<<"egorsmkv.github.io/files">>, _Info) ->
    case ircd_files:enabled() of
        true -> {ok, ircd_files:cap_value()};
        false -> error
    end;
value(_Name, _Info) ->
    {ok, undefined}.

%% A plaintext connection gets the upgrade port. A secure connection gets the
%% persistence policy. No `sts` key in configuration disables the capability.
sts_value(null, _Secure) ->
    error;
sts_value(#{port := Port}, false) ->
    {ok, <<"port=", (integer_to_binary(Port))/binary>>};
sts_value(#{duration := Duration, preload := Preload}, true) ->
    Base = <<"duration=", (integer_to_binary(Duration))/binary>>,
    case Preload of
        true -> {ok, <<Base/binary, ",preload">>};
        false -> {ok, Base}
    end.

config(Key, Default) ->
    maps:get(Key, persistent_term:get({ircd_state, config}, #{}), Default).

requested_version([<<"LS">>, Raw | _]) ->
    try binary_to_integer(Raw) of
        Version when Version > 0 -> Version;
        _ -> undefined
    catch
        error:badarg -> undefined
    end;
requested_version(_) ->
    undefined.

tokens(Params) ->
    [Token || Param <- Params, Token <- binary:split(Param, <<" ">>, [global, trim_all])].

join([]) ->
    <<>>;
join(Tokens) ->
    iolist_to_binary(lists:join(<<" ">>, Tokens)).

apply_tokens([], Enabled, _Version, _Offered) ->
    {ok, Enabled};
apply_tokens([Token | Rest], Enabled, Version, Offered) ->
    case token(Token) of
        {disable, <<"cap-notify">>} when Version >= 302 ->
            error;
        {_, <<>>} ->
            error;
        {Action, Name} ->
            case requestable(Name, Offered) of
                true when Action =:= disable ->
                    apply_tokens(Rest, maps:remove(Name, Enabled), Version, Offered);
                true ->
                    apply_tokens(Rest, Enabled#{Name => true}, Version, Offered);
                false ->
                    error
            end
    end.

token(<<$-, Name/binary>>) -> {disable, Name};
token(Name) -> {enable, Name}.

requestable(Name, Offered) ->
    lists:member(Name, Offered) andalso not lists:member(Name, ?UNREQUESTABLE).

pack_names([], _Max, <<>>, Acc) ->
    lists:reverse(Acc);
pack_names([], _Max, Current, Acc) ->
    lists:reverse([Current | Acc]);
pack_names([Name | Rest], Max, <<>>, Acc) ->
    pack_names(Rest, Max, Name, Acc);
pack_names([Name | Rest], Max, Current, Acc) ->
    Next = <<Current/binary, " ", Name/binary>>,
    case byte_size(Next) =< Max of
        true -> pack_names(Rest, Max, Next, Acc);
        false -> pack_names(Rest, Max, Name, [Current | Acc])
    end.
