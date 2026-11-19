-module(ircd_e2ee).
-export([
    enabled/0,
    cap/0,
    cap_value/0,
    command/3,
    route/4,
    session_down/1,
    expire/0,
    tag/1
]).

-moduledoc """
Blind broker for client-side end-to-end encryption (Signal-style X3DH and
Double Ratchet with OMEMO-style multi-device, and Sender Keys for channels).

All cryptography stays in the clients. The server only stores public keys,
routes opaque ciphertext, and queues it for devices that are offline; it
never parses, logs, or alters message bodies. The feature is off unless the
`e2ee` configuration object is set (see the [E2EE guide](e2ee.html) for the
wire protocol and the [Configuration guide](configuration.html) for limits).

Capability and names. The extension is specific to this server, so it uses a
vendor namespace instead of `draft/` (which belongs to IRCv3 specifications):
the capability `egorsmkv.github.io/e2ee` (value `v=1` and the limits) and the
client-only tags `+egorsmkv.github.io/e2ee-src`, `-dst`, and `-type`.

Identity. Keys are bound to SASL accounts, not nicknames: publishing,
binding, and acknowledging need a logged-in client, and a bundle is fetched
by nickname (resolved to the account of the user who has it now) or by
account name. Clients still verify identity keys themselves (TOFU and safety
numbers); the server cannot.

Commands (`E2EE <subcommand>`; errors are `FAIL E2EE <code>`):

- `PUBLISH <device> <identity> <spk-id>:<spk> <signature>`: store or replace
  a device's identity key and signed prekey.
- `PREKEYS <device> [<id>:<key> ...]`: add one-time prekeys; with no keys,
  report the count.
- `DEVICES <nick|account>` and `FETCH <nick|account> [<device>]`: list devices
  or fetch bundles, consuming one one-time prekey per device.
- `BIND <device>`: this connection is that device; queued envelopes follow.
- `ACK <qid>[,<qid>...]`: drop acknowledged envelopes.
- `REMOVE <device>`: delete a device and its queue.

Offline queue. A `PRIVMSG`, `NOTICE`, or `TAGMSG` to a user that carries the
`dst` tag is also queued for that device when no connection is bound to it
(`route/4`), then delivered on `BIND` with a `qid` tag until acknowledged.
The queue is bounded per device and envelopes expire (`queue_ttl`).

Runs inside the `ircd_state` process; the tables are in
`include/ircd_e2ee.hrl`. Bundles and queues are local to this server; they are
not replicated over server links.
""".

-include("ircd_state.hrl").
-include("ircd_account.hrl").
-include("ircd_e2ee.hrl").

-define(VENDOR, "egorsmkv.github.io").
-define(CAP, <<?VENDOR "/e2ee">>).
-define(BOUND, ircd_e2ee_bound).
%% Base64 text of one public key or signature (raw keys of up to ~150 bytes).
-define(MAX_KEY_CHARS, 200).
-define(MAX_ID, 4294967295).
%% Owners are told when a device has fewer one-time prekeys than this.
-define(PREKEYS_LOW, 10).
%% Seconds between sweeps for expired envelopes.
-define(EXPIRE_EVERY, 60).

-doc "True when the `e2ee` configuration object is set.".
-spec enabled() -> boolean().
enabled() ->
    config() =/= null.

-doc "The capability name, `egorsmkv.github.io/e2ee`.".
-spec cap() -> binary().
cap() ->
    ?CAP.

-doc """
The capability value: protocol version and limits, for example
`v=1,max-devices=8,max-prekeys=100,queue=500`.
""".
-spec cap_value() -> binary().
cap_value() ->
    #{max_devices := Devices, max_prekeys := Prekeys, queue_limit := Queue} = config(),
    iolist_to_binary([
        <<"v=1,max-devices=">>,
        integer_to_binary(Devices),
        <<",max-prekeys=">>,
        integer_to_binary(Prekeys),
        <<",queue=">>,
        integer_to_binary(Queue)
    ]).

-doc """
Full name of one of the extension's tags: `src`, `dst`, `type` (client-only,
`+` prefix) or `qid` (server tag on replayed envelopes).
""".
-spec tag(src | dst | type | qid) -> binary().
tag(src) -> <<"+" ?VENDOR "/e2ee-src">>;
tag(dst) -> <<"+" ?VENDOR "/e2ee-dst">>;
tag(type) -> <<"+" ?VENDOR "/e2ee-type">>;
tag(qid) -> <<?VENDOR "/e2ee-qid">>.

%%% Commands

-doc """
Handle `E2EE <subcommand> ...` from a registered client. Requires the
capability; see the moduledoc for the subcommands and the E2EE guide for
replies and `FAIL` codes.
""".
-spec command([binary()], #client{}, binary()) -> ok.
command(Params, #client{pid = Pid} = Client, Server) ->
    case {ircd_cap:enabled(Pid, ?CAP), Params} of
        {false, _} ->
            fail(Pid, <<"CAP_REQUIRED">>, [], <<"Request the e2ee capability first">>);
        {true, []} ->
            fail(Pid, <<"NEED_MORE_PARAMS">>, [], <<"Missing subcommand">>);
        {true, [Sub | Rest]} ->
            subcommand(string:uppercase(Sub), Rest, Client, Server)
    end.

subcommand(<<"PUBLISH">>, [Dev, Identity, Spk, Signature | _], Client, Server) ->
    with_account(Client, fun(Account) ->
        publish(Account, Dev, Identity, Spk, Signature, Client, Server)
    end);
subcommand(<<"PREKEYS">>, [Dev | Keys], Client, Server) ->
    with_account(Client, fun(Account) -> prekeys(Account, Dev, Keys, Client, Server) end);
subcommand(<<"DEVICES">>, [Target | _], Client, Server) ->
    devices(Target, Client, Server);
subcommand(<<"FETCH">>, [Target | Rest], Client, Server) ->
    fetch(Target, Rest, Client, Server);
subcommand(<<"BIND">>, [Dev | _], Client, Server) ->
    with_account(Client, fun(Account) -> bind(Account, Dev, Client, Server) end);
subcommand(<<"ACK">>, [Ids | _], Client, _Server) ->
    with_account(Client, fun(Account) -> ack(Account, Ids, Client) end);
subcommand(<<"REMOVE">>, [Dev | _], Client, Server) ->
    with_account(Client, fun(Account) -> remove(Account, Dev, Client, Server) end);
subcommand(Sub, _Params, #client{pid = Pid}, _Server) when
    Sub =:= <<"PUBLISH">>;
    Sub =:= <<"PREKEYS">>;
    Sub =:= <<"DEVICES">>;
    Sub =:= <<"FETCH">>;
    Sub =:= <<"BIND">>;
    Sub =:= <<"ACK">>;
    Sub =:= <<"REMOVE">>
->
    fail(Pid, <<"NEED_MORE_PARAMS">>, [Sub], <<"Missing parameters">>);
subcommand(Sub, _Params, #client{pid = Pid}, _Server) ->
    fail(Pid, <<"UNKNOWN_COMMAND">>, [Sub], <<"Unknown E2EE subcommand">>).

%% Key material and acknowledgements belong to an account (SASL), so a
%% nickname taken over after a disconnect cannot publish rogue keys.
with_account(#client{pid = Pid}, Fun) ->
    case ircd_state_v3:account(Pid) of
        undefined -> fail(Pid, <<"ACCOUNT_REQUIRED">>, [], <<"Log in with SASL first">>);
        Account -> Fun(Account)
    end.

publish(Account, DevText, IdentityText, SpkText, SignatureText, #client{pid = Pid}, Server) ->
    #{max_devices := MaxDevices} = config(),
    maybe
        {ok, Dev} ?= device_id(DevText),
        {ok, Identity} ?= key(IdentityText),
        {ok, {SpkId, Spk}} ?= id_key(SpkText),
        {ok, Signature} ?= key(SignatureText),
        Key = {ircd_wire:fold(Account), Dev},
        Existing = mnesia:dirty_read(e2ee_device, Key),
        true ?=
            Existing =/= [] orelse length(account_devices(Account)) < MaxDevices orelse
            too_many_devices,
        Prekeys =
            case Existing of
                [#e2ee_device{prekeys = Old}] -> Old;
                [] -> []
            end,
        ok = mnesia:dirty_write(#e2ee_device{
            key = Key,
            account = Account,
            identity = Identity,
            signed_prekey_id = SpkId,
            signed_prekey = Spk,
            signature = Signature,
            prekeys = Prekeys,
            updated = erlang:system_time(second)
        }),
        logger:info(#{event => e2ee_device_published, account => Account, device => Dev}),
        reply(Pid, Server, [<<"PUBLISHED">>, integer_to_binary(Dev)])
    else
        too_many_devices ->
            fail(Pid, <<"TOO_MANY_DEVICES">>, [DevText], <<"Device limit reached">>);
        {error, Field} ->
            fail(Pid, <<"INVALID_PARAMS">>, [Field], <<"Invalid device id or key">>)
    end.

prekeys(Account, DevText, KeyTexts, #client{pid = Pid}, Server) ->
    #{max_prekeys := Max} = config(),
    maybe
        {ok, Dev} ?= device_id(DevText),
        [#e2ee_device{prekeys = Old} = Device] ?=
            mnesia:dirty_read(e2ee_device, {ircd_wire:fold(Account), Dev}),
        {ok, New} ?= id_keys(KeyTexts),
        Merged = merge_prekeys(Old, New),
        true ?= length(Merged) =< Max orelse too_many,
        ok = mnesia:dirty_write(Device#e2ee_device{prekeys = Merged}),
        reply(Pid, Server, [
            <<"PREKEYS">>, integer_to_binary(Dev), integer_to_binary(length(Merged))
        ])
    else
        [] ->
            fail(Pid, <<"UNKNOWN_DEVICE">>, [DevText], <<"Publish the device first">>);
        too_many ->
            fail(Pid, <<"TOO_MANY_PREKEYS">>, [DevText], <<"One-time prekey limit reached">>);
        {error, Field} ->
            fail(Pid, <<"INVALID_PARAMS">>, [Field], <<"Invalid device id or prekey">>)
    end.

%% New keys replace stored keys with the same id; order stays oldest first.
merge_prekeys(Old, New) ->
    NewIds = [Id || {Id, _} <- New],
    [Entry || {Id, _} = Entry <- Old, not lists:member(Id, NewIds)] ++ lists:ukeysort(1, New).

devices(Target, #client{pid = Pid}, Server) ->
    case resolve(Target) of
        {ok, Account} ->
            Ids = [
                integer_to_binary(Dev)
             || #e2ee_device{key = {_, Dev}} <- account_devices(Account)
            ],
            reply(
                Pid, Server, [<<"DEVICES">>, Account], iolist_to_binary(lists:join(<<" ">>, Ids))
            );
        {error, Code} ->
            fail(Pid, Code, [Target], <<"No such user or account">>)
    end.

fetch(Target, Rest, #client{pid = Pid}, Server) ->
    maybe
        ok ?= fetch_allowed(Pid),
        {ok, Account} ?= resolve(Target),
        {ok, Wanted} ?=
            case Rest of
                [] -> {ok, all};
                [DevText | _] -> device_id(DevText)
            end,
        Devices = [
            D
         || #e2ee_device{key = {_, Dev}} = D <- account_devices(Account),
            Wanted =:= all orelse Wanted =:= Dev
        ],
        true ?= Devices =/= [] orelse no_devices,
        lists:foreach(fun(Device) -> send_bundle(Pid, Server, Device) end, Devices),
        reply(Pid, Server, [<<"FETCHED">>, Account, integer_to_binary(length(Devices))])
    else
        rate_limited ->
            fail(Pid, <<"RATE_LIMITED">>, [Target], <<"Too many bundle requests">>);
        no_devices ->
            fail(Pid, <<"NO_DEVICES">>, [Target], <<"No published devices">>);
        {error, Code} when is_binary(Code) ->
            fail(Pid, Code, [Target], <<"No such user or account">>);
        {error, Field} ->
            fail(Pid, <<"INVALID_PARAMS">>, [Field], <<"Invalid device id">>)
    end.

%% One bundle line per device. A one-time prekey is handed out once
%% (consumed); without any left the bundle has none, as X3DH allows.
send_bundle(Pid, Server, #e2ee_device{key = {_, Dev}, prekeys = Prekeys} = Device) ->
    {Opk, Left} =
        case Prekeys of
            [{Id, Key} | Rest] ->
                {[<<(integer_to_binary(Id))/binary, ":", (b64(Key))/binary>>], Rest};
            [] ->
                {[], []}
        end,
    ok = mnesia:dirty_write(Device#e2ee_device{prekeys = Left}),
    reply(
        Pid,
        Server,
        [
            <<"BUNDLE">>,
            Device#e2ee_device.account,
            integer_to_binary(Dev),
            b64(Device#e2ee_device.identity),
            <<
                (integer_to_binary(Device#e2ee_device.signed_prekey_id))/binary,
                ":",
                (b64(Device#e2ee_device.signed_prekey))/binary
            >>,
            b64(Device#e2ee_device.signature)
            | Opk
        ]
    ),
    case Opk =/= [] andalso length(Left) < ?PREKEYS_LOW of
        true -> prekeys_low(Device#e2ee_device.account, Dev, length(Left), Server);
        false -> ok
    end.

%% Tell the owner's connection bound to that device to upload more prekeys.
prekeys_low(Account, Dev, Count, Server) ->
    case bound(Account, Dev) of
        {ok, Owner} ->
            reply(Owner, Server, [<<"PREKEYS">>, integer_to_binary(Dev), integer_to_binary(Count)]);
        none ->
            ok
    end.

bind(Account, DevText, #client{pid = Pid}, Server) ->
    maybe
        {ok, Dev} ?= device_id(DevText),
        Folded = ircd_wire:fold(Account),
        [_] ?= mnesia:dirty_read(e2ee_device, {Folded, Dev}),
        true = ets:match_delete(?BOUND, {'_', Pid}),
        true = ets:insert(?BOUND, {{Folded, Dev}, Pid}),
        Queued = queued(Folded, Dev),
        reply(Pid, Server, [<<"BOUND">>, integer_to_binary(Dev), integer_to_binary(length(Queued))]),
        lists:foreach(fun(Entry) -> replay(Pid, Entry) end, Queued)
    else
        [] ->
            fail(Pid, <<"UNKNOWN_DEVICE">>, [DevText], <<"Publish the device first">>);
        {error, Field} ->
            fail(Pid, <<"INVALID_PARAMS">>, [Field], <<"Invalid device id">>)
    end.

replay(Pid, #e2ee_queue{key = {_, _, Seq}} = Entry) ->
    #e2ee_queue{prefix = Prefix, command = Command, target = Target, text = Text, tags = Tags} =
        Entry,
    ircd_state_send:send(
        Pid, Prefix, Command, [Target], Text, [{tag(qid), integer_to_binary(Seq)} | Tags]
    ).

ack(Account, Ids, #client{pid = Pid}) ->
    Folded = ircd_wire:fold(Account),
    case bound_device(Pid, Folded) of
        {ok, Dev} ->
            lists:foreach(
                fun(Text) ->
                    case string:to_integer(Text) of
                        {Seq, <<>>} when is_integer(Seq), Seq >= 0 ->
                            mnesia:dirty_delete(e2ee_queue, {Folded, Dev, Seq});
                        _ ->
                            ok
                    end
                end,
                binary:split(Ids, <<",">>, [global, trim_all])
            );
        none ->
            fail(Pid, <<"NOT_BOUND">>, [], <<"BIND a device first">>)
    end.

remove(Account, DevText, #client{pid = Pid}, Server) ->
    maybe
        {ok, Dev} ?= device_id(DevText),
        Folded = ircd_wire:fold(Account),
        [_] ?= mnesia:dirty_read(e2ee_device, {Folded, Dev}),
        ok = mnesia:dirty_delete(e2ee_device, {Folded, Dev}),
        lists:foreach(
            fun(#e2ee_queue{key = Key}) -> mnesia:dirty_delete(e2ee_queue, Key) end,
            queued(Folded, Dev)
        ),
        true = ets:delete(?BOUND, {Folded, Dev}),
        logger:info(#{event => e2ee_device_removed, account => Account, device => Dev}),
        reply(Pid, Server, [<<"REMOVED">>, integer_to_binary(Dev)])
    else
        [] ->
            fail(Pid, <<"UNKNOWN_DEVICE">>, [DevText], <<"No such device">>);
        {error, Field} ->
            fail(Pid, <<"INVALID_PARAMS">>, [Field], <<"Invalid device id">>)
    end.

%%% Delivery

-doc """
Offline queueing hook for a direct `PRIVMSG`, `NOTICE`, or `TAGMSG` from
`Client` to `Target`, called before normal delivery. `ClientTags` are the
sender's client-only tags and `Tags` the full tag list of the delivery
(`msgid`, `time`, client tags).

Returns `pass` (deliver normally; the message may also have been queued for
an offline device of an online user) or `handled` (the target is offline and
the envelope was queued or refused; nothing else to deliver). Messages
without the `dst` tag, multiline bodies, and the feature switched off always
`pass`.
""".
-spec route(binary(), term(), #client{}, {[tuple()], [tuple()], binary()}) -> pass | handled.
route(Target, Body, Client, {ClientTags, Tags, Command}) ->
    case {enabled(), lists:keyfind(tag(dst), 1, ClientTags), Body} of
        {true, {_, DevText}, Text} when is_binary(Text); Text =:= none ->
            case {device_id(DevText), recipient(Target)} of
                {{ok, Dev}, {ok, Account, Online}} ->
                    queue_if_unbound(Account, Dev, Online, Target, Text, Client, {Tags, Command});
                %% A bad device id, a user without an account, or no such
                %% user or account: normal delivery applies (or reports 401).
                _ ->
                    pass
            end;
        _ ->
            pass
    end.

queue_if_unbound(Account, Dev, Online, Target, Text, #client{pid = Pid} = Client, {Tags, Command}) ->
    Folded = ircd_wire:fold(Account),
    Server = server(),
    Result =
        case {bound(Account, Dev), mnesia:dirty_read(e2ee_device, {Folded, Dev})} of
            {{ok, _}, _} ->
                delivered;
            {none, []} ->
                fail(
                    Pid,
                    <<"UNKNOWN_DEVICE">>,
                    [Target, integer_to_binary(Dev)],
                    <<"No such device">>
                ),
                refused;
            {none, [_]} ->
                enqueue(Folded, Dev, Target, Text, Client, {Tags, Command}, Server)
        end,
    case {Online, Result} of
        {online, _} -> pass;
        {offline, _} -> handled
    end.

enqueue(Folded, Dev, Target, Text, #client{pid = Pid} = Client, {Tags, Command}, Server) ->
    #{queue_limit := Limit, queue_ttl := Ttl} = config(),
    case {ircd_state_v3:account(Pid), length(queued(Folded, Dev)) < Limit} of
        {undefined, _} ->
            fail(Pid, <<"ACCOUNT_REQUIRED">>, [Target], <<"Log in to queue encrypted messages">>),
            refused;
        {_, false} ->
            fail(
                Pid, <<"QUEUE_FULL">>, [Target, integer_to_binary(Dev)], <<"Device queue is full">>
            ),
            refused;
        {_, true} ->
            Seq = next_seq(Folded, Dev),
            ok = mnesia:dirty_write(#e2ee_queue{
                key = {Folded, Dev, Seq},
                prefix = iolist_to_binary(ircd_state_send:prefix(Client)),
                command = Command,
                target = ircd_wire:retain(Target),
                text = ircd_wire:retain(Text),
                tags = [{ircd_wire:retain(K), ircd_wire:retain(V)} || {K, V} <- Tags],
                expires = erlang:system_time(second) + Ttl
            }),
            reply(Pid, Server, [
                <<"QUEUED">>, Target, integer_to_binary(Dev), integer_to_binary(Seq)
            ]),
            queued
    end.

%% Unique, increasing per device: nanoseconds, bumped past the newest entry.
next_seq(Folded, Dev) ->
    Now = erlang:system_time(nanosecond),
    case lists:reverse(queued(Folded, Dev)) of
        [#e2ee_queue{key = {_, _, Last}} | _] when Last >= Now -> Last + 1;
        _ -> Now
    end.

-doc "Forget the device binding of a session that ended.".
-spec session_down(pid()) -> ok.
session_down(Pid) ->
    case ets:whereis(?BOUND) of
        undefined ->
            ok;
        _ ->
            true = ets:match_delete(?BOUND, {'_', Pid}),
            ok
    end.

-doc """
Delete expired envelopes. Called from the state's one-second tick; it does
the work at most once every 60 seconds.
""".
-spec expire() -> ok.
expire() ->
    Now = erlang:system_time(second),
    case get(ircd_e2ee_expired_at) of
        Last when is_integer(Last), Now - Last < ?EXPIRE_EVERY ->
            ok;
        _ ->
            put(ircd_e2ee_expired_at, Now),
            case enabled() of
                true ->
                    Expired = mnesia:dirty_select(e2ee_queue, [
                        {{e2ee_queue, '$1', '_', '_', '_', '_', '_', '$2'}, [{'<', '$2', Now}], [
                            '$1'
                        ]}
                    ]),
                    lists:foreach(fun(Key) -> mnesia:dirty_delete(e2ee_queue, Key) end, Expired);
                false ->
                    ok
            end
    end.

%%% Helpers

%% A target's account: the logged-in user who has the nickname now, or else
%% an account of that name.
resolve(Target) ->
    case recipient(Target) of
        {ok, Account, _} -> {ok, Account};
        {error, _} = Error -> Error
    end.

recipient(Target) ->
    case ircd_state_client:find_nick(Target) of
        #client{pid = Other} = Found ->
            case {ircd_state_client:ready(Found), ircd_state_v3:account(Other)} of
                {true, undefined} -> {error, <<"NO_ACCOUNT">>};
                {true, Account} -> {ok, Account, online};
                {false, _} -> {error, <<"NO_SUCH_TARGET">>}
            end;
        undefined ->
            case ircd_account:find(Target) of
                {ok, #account{name = Name}} -> {ok, Name, offline};
                error -> {error, <<"NO_SUCH_TARGET">>}
            end
    end.

account_devices(Account) ->
    Folded = ircd_wire:fold(Account),
    mnesia:dirty_select(e2ee_device, [
        {{e2ee_device, {Folded, '_'}, '_', '_', '_', '_', '_', '_', '_'}, [], ['$_']}
    ]).

queued(Folded, Dev) ->
    mnesia:dirty_select(e2ee_queue, [
        {{e2ee_queue, {Folded, Dev, '_'}, '_', '_', '_', '_', '_', '_'}, [], ['$_']}
    ]).

%% The live connection bound to a device, if it is still logged into that account.
bound(Account, Dev) ->
    Folded = ircd_wire:fold(Account),
    case ets:lookup(?BOUND, {Folded, Dev}) of
        [{_, Pid}] ->
            case ircd_state_v3:account(Pid) of
                Current when is_binary(Current) ->
                    case ircd_wire:fold(Current) of
                        Folded -> {ok, Pid};
                        _ -> none
                    end;
                undefined ->
                    none
            end;
        [] ->
            none
    end.

bound_device(Pid, Folded) ->
    case ets:match_object(?BOUND, {{Folded, '_'}, Pid}) of
        [{{_, Dev}, _} | _] -> {ok, Dev};
        [] -> none
    end.

%% FETCH consumes one-time prekeys, so it is rate limited per connection.
fetch_allowed(Pid) ->
    #{fetch_rate := PerMinute} = config(),
    Now = erlang:monotonic_time(second),
    {Window, Count} = ircd_conn:get(Pid, e2ee_fetch, {Now, 0}),
    case Now - Window >= 60 of
        true ->
            ircd_conn:put(Pid, e2ee_fetch, {Now, 1}),
            ok;
        false when Count < PerMinute ->
            ircd_conn:put(Pid, e2ee_fetch, {Window, Count + 1}),
            ok;
        false ->
            rate_limited
    end.

device_id(Text) when is_binary(Text) ->
    case string:to_integer(Text) of
        {Id, <<>>} when is_integer(Id), Id >= 1, Id =< 2147483647 -> {ok, Id};
        _ -> {error, <<"device">>}
    end;
device_id(_) ->
    {error, <<"device">>}.

key(Text) when byte_size(Text) >= 4, byte_size(Text) =< ?MAX_KEY_CHARS ->
    try base64:decode(Text) of
        Bin -> {ok, Bin}
    catch
        error:_ -> {error, <<"key">>}
    end;
key(_) ->
    {error, <<"key">>}.

id_key(Text) ->
    case binary:split(Text, <<":">>) of
        [IdText, KeyText] ->
            case {string:to_integer(IdText), key(KeyText)} of
                {{Id, <<>>}, {ok, Key}} when is_integer(Id), Id >= 0, Id =< ?MAX_ID ->
                    {ok, {Id, Key}};
                _ ->
                    {error, <<"key">>}
            end;
        _ ->
            {error, <<"key">>}
    end.

id_keys(Texts) ->
    lists:foldr(
        fun
            (Text, {ok, Acc}) ->
                case id_key(Text) of
                    {ok, Entry} -> {ok, [Entry | Acc]};
                    Error -> Error
                end;
            (_, Error) ->
                Error
        end,
        {ok, []},
        Texts
    ).

b64(Bin) ->
    base64:encode(Bin).

reply(Pid, Server, Middle) ->
    ircd_state_send:send(Pid, Server, <<"E2EE">>, Middle, none).

reply(Pid, Server, Middle, Trailing) ->
    ircd_state_send:send(Pid, Server, <<"E2EE">>, Middle, Trailing).

fail(Pid, Code, Context, Text) ->
    ircd_state_send:fail(Pid, <<"E2EE">>, Code, Context, Text).

config() ->
    maps:get(e2ee, persistent_term:get({ircd_state, config}, #{}), null).

server() ->
    maps:get(name, persistent_term:get({ircd_state, config}, #{}), <<"irc.local">>).
