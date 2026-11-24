-module(briskd_e2ee).
-export([
    enabled/0,
    cap/0,
    cap_value/0,
    command/3,
    route/4,
    session_down/1,
    forget_remote/1,
    expire/0,
    tag/1,
    encrypted/1,
    envelope_tags/1,
    burst_lines/0,
    receive_link/4,
    remote_renamed/2,
    account_devices/1,
    account_name/1,
    b64/1,
    bound/2,
    config/0,
    consume/2,
    delete_device/2,
    device_id/1,
    fail/4,
    id_key/1,
    id_keys/1,
    key/1,
    merge_prekeys/3,
    non_neg/1,
    pattern/2,
    queued/2,
    recipient/1,
    reply/3,
    seq/1,
    server/0
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
`dst` tag, including a `draft/multiline` batch, is also queued for that
device when no connection anywhere on the network is bound to it
(`route/4`), then delivered on `BIND` with a `qid` tag until acknowledged.
The queue is bounded per device and envelopes expire (`queue_ttl`).

Server links. Bundles, prekey use, removals, queued envelopes,
acknowledgements, and device bindings are replicated to every server
(`burst_lines/0` and `receive_link/4`), so a device can be fetched from,
queued for, and bound on any server. Lines are applied, then relayed to the
other peers, never back to the link they came from:

```text
:<server> E2EE DEVICE <account> <device> <updated-us> <identity> <spk-id>:<spk> <sig>
:<server> E2EE PREKEYS <account> <device> <id>:<key> ...
:<server> E2EE USE <account> <device> <prekey-id>
:<server> E2EE DELETE <account> <device>
@<vendor>/e2ee-body=<b64 json>;<vendor>/e2ee-tags=<b64 json> :<server> E2EE QUEUE <account> <device> <qid> <expires> <command> <target> <sender>
:<server> E2EE ACK <account> <device> <qid>[,<qid>...]
:<nick!user@host> E2EE BIND <device>
```

Replication is eventually consistent: two servers that hand out the same
one-time prekey while split both deliver it (X3DH then fails for the second
session and the client starts over), and the newer `DEVICE` wins.

Runs inside the `briskd_state` process; the tables are in
`include/briskd_e2ee.hrl`.
""".

-include("briskd_state.hrl").
-include("briskd_account.hrl").
-include("briskd_e2ee.hrl").

-define(VENDOR, "egorsmkv.github.io").
-define(CAP, <<?VENDOR "/e2ee">>).
-define(BOUND, briskd_e2ee_bound).
%% Base64 text of one public key or signature (raw keys of up to ~150 bytes).
-define(MAX_KEY_CHARS, 200).
-define(MAX_ID, 4294967295).
%% Owners are told when a device has fewer one-time prekeys than this.
-define(PREKEYS_LOW, 10).
%% Seconds between sweeps for expired envelopes.
-define(EXPIRE_EVERY, 60).
%% Remembered ids of handed-out one-time prekeys per device.
-define(MAX_USED, 1000).

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
`+` prefix), `qid` (server tag on replayed envelopes), and `body`/`tags`
(server tags of a replicated `E2EE QUEUE` line).
""".
-spec tag(src | dst | type | qid | body | tags) -> binary().
tag(src) -> <<"+" ?VENDOR "/e2ee-src">>;
tag(dst) -> <<"+" ?VENDOR "/e2ee-dst">>;
tag(type) -> <<"+" ?VENDOR "/e2ee-type">>;
tag(qid) -> <<?VENDOR "/e2ee-qid">>;
tag(body) -> <<?VENDOR "/e2ee-body">>;
tag(tags) -> <<?VENDOR "/e2ee-tags">>.

-doc """
Whether a message is an end-to-end encrypted envelope: its tags include one
of the extension's client-only tags (`e2ee-src`, `e2ee-dst`, `e2ee-type`).
Its body is then ciphertext, which must never be treated as text (message
search never indexes it). Decided from the tags alone, whether or not the
`e2ee` feature is configured.
""".
-spec encrypted([{binary(), undefined | binary()}]) -> boolean().
encrypted(Tags) ->
    envelope_tags(Tags) =/= [].

-doc """
The extension's client-only tags in `Tags`, in order. A message from a client
that did not negotiate `message-tags` keeps these (and only these), so an
encrypted body is still stored and relayed as encrypted.
""".
-spec envelope_tags([{binary(), undefined | binary()}]) -> [{binary(), undefined | binary()}].
envelope_tags(Tags) ->
    Names = [tag(src), tag(dst), tag(type)],
    [{K, V} || {K, V} <- Tags, lists:member(K, Names)].

%%% Commands

-doc """
Handle `E2EE <subcommand> ...` from a registered client. Requires the
capability; see the moduledoc for the subcommands and the E2EE guide for
replies and `FAIL` codes.
""".
-spec command([binary()], #client{}, binary()) -> ok.
command(Params, #client{pid = Pid} = Client, Server) ->
    case {briskd_cap:enabled(Pid, ?CAP), Params} of
        {false, _} ->
            fail(Pid, <<"CAP_REQUIRED">>, [], <<"Request the e2ee capability first">>);
        {true, []} ->
            fail(Pid, <<"NEED_MORE_PARAMS">>, [], <<"Missing subcommand">>);
        {true, [Sub | Rest]} ->
            subcommand(briskd_wire:upper(Sub), Rest, Client, Server)
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
    case briskd_state_v3:account(Pid) of
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
        Key = {briskd_wire:fold(Account), Dev},
        Existing = mnesia:dirty_read(e2ee_device, Key),
        true ?=
            Existing =/= [] orelse length(account_devices(Account)) < MaxDevices orelse
            too_many_devices,
        {Prekeys, Used} =
            case Existing of
                [#e2ee_device{prekeys = Old, used = OldUsed}] -> {Old, OldUsed};
                [] -> {[], []}
            end,
        Device = #e2ee_device{
            key = Key,
            account = briskd_wire:retain(Account),
            identity = Identity,
            signed_prekey_id = SpkId,
            signed_prekey = Spk,
            signature = Signature,
            prekeys = Prekeys,
            updated = erlang:system_time(microsecond),
            used = Used
        },
        ok = mnesia:dirty_write(Device),
        briskd_e2ee_sync:broadcast(briskd_e2ee_sync:device_line(Device)),
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
        [#e2ee_device{prekeys = Old, used = Used} = Device] ?=
            mnesia:dirty_read(e2ee_device, {briskd_wire:fold(Account), Dev}),
        {ok, New} ?= id_keys(KeyTexts),
        Merged = merge_prekeys(Old, New, Used),
        true ?= length(Merged) =< Max orelse too_many,
        ok = mnesia:dirty_write(Device#e2ee_device{prekeys = Merged}),
        lists:foreach(
            fun briskd_e2ee_sync:broadcast/1,
            briskd_e2ee_sync:prekeys_lines(Account, Dev, New)
        ),
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

-doc """
Merge newly uploaded one-time prekeys into `Old`, replacing duplicates and
skipping already-used ids in `Used`.
""".
-spec merge_prekeys(
    [{non_neg_integer(), binary()}], [{non_neg_integer(), binary()}], [non_neg_integer()]
) ->
    [{non_neg_integer(), binary()}].
merge_prekeys(Old, New, Used) ->
    Fresh = [Entry || {Id, _} = Entry <- lists:ukeysort(1, New), not lists:member(Id, Used)],
    NewIds = [Id || {Id, _} <- Fresh],
    [Entry || {Id, _} = Entry <- Old, not lists:member(Id, NewIds)] ++ Fresh.

devices(Target, #client{pid = Pid}, Server) ->
    case resolve(Target) of
        {ok, Account} ->
            Ids = [
                integer_to_binary(Dev)
             || #e2ee_device{key = {_, Dev}} <- account_devices(Account)
            ],
            reply(
                Pid, Server, [<<"DEVICES">>, Account], binary:join(Ids, <<" ">>)
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
%% (consumed, here and over links); without any left the bundle has none, as
%% X3DH allows.
send_bundle(Pid, Server, #e2ee_device{key = {_, Dev}, prekeys = Prekeys} = Device) ->
    Opk =
        case Prekeys of
            [{Id, Key} | _] ->
                consume(Device, Id),
                briskd_e2ee_sync:broadcast(
                    briskd_e2ee_sync:use_line(Device#e2ee_device.account, Dev, Id)
                ),
                [<<(integer_to_binary(Id))/binary, ":", (b64(Key))/binary>>];
            [] ->
                []
        end,
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
    ).

-doc "Consume one prekey id from `Device` and notify the device owner when low.".
-spec consume(#e2ee_device{}, non_neg_integer()) -> ok.
consume(
    #e2ee_device{key = {_, Dev}, account = Account, prekeys = Prekeys, used = Used} = Device, Id
) ->
    Left = lists:keydelete(Id, 1, Prekeys),
    ok = mnesia:dirty_write(Device#e2ee_device{
        prekeys = Left, used = lists:sublist([Id | lists:delete(Id, Used)], ?MAX_USED)
    }),
    case length(Left) < ?PREKEYS_LOW of
        true -> prekeys_low(Account, Dev, length(Left));
        false -> ok
    end.

%% Tell the owner's connection bound to that device here to upload more
%% prekeys (a device bound on another server hears it from its own server).
prekeys_low(Account, Dev, Count) ->
    case bound(Account, Dev) of
        {ok, Owner} when is_pid(Owner) ->
            reply(Owner, server(), [<<"PREKEYS">>, integer_to_binary(Dev), integer_to_binary(Count)]);
        _ ->
            ok
    end.

bind(Account, DevText, #client{pid = Pid} = Client, Server) ->
    maybe
        {ok, Dev} ?= device_id(DevText),
        Folded = briskd_wire:fold(Account),
        [_] ?= mnesia:dirty_read(e2ee_device, {Folded, Dev}),
        true = ets:match_delete(?BOUND, {'_', Pid}),
        true = ets:insert(?BOUND, {{Folded, Dev}, Pid}),
        briskd_e2ee_sync:broadcast(briskd_e2ee_sync:bind_line(Client, Dev)),
        Now = erlang:system_time(second),
        Queued = lists:filter(
            fun(#e2ee_queue{key = Key, expires = Expires}) ->
                case Expires =< Now of
                    true ->
                        ok = mnesia:dirty_delete(e2ee_queue, Key),
                        false;
                    false ->
                        true
                end
            end,
            queued(Folded, Dev)
        ),
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
    Delivery = [{tag(qid), integer_to_binary(Seq)} | Tags],
    briskd_state_send:with_source(replay_source(Prefix), fun() ->
        case Text of
            {multiline, Lines} ->
                briskd_state_batch:deliver_multiline(
                    Pid, Prefix, Command, Target, Lines, Delivery, normal
                );
            _ ->
                briskd_state_send:send(Pid, Prefix, Command, [Target], Text, Delivery)
        end
    end).

replay_source(Prefix) when is_binary(Prefix) ->
    case binary:split(Prefix, <<"!">>) of
        [Nick, _] ->
            case briskd_state_client:find_nick(Nick) of
                #client{} = Client ->
                    case iolist_to_binary(briskd_state_send:prefix(Client)) =:= Prefix of
                        true -> briskd_state_v3:source_info(Client);
                        false -> #{}
                    end;
                undefined ->
                    briskd_state_v3:remote_source_info(Prefix)
            end;
        _ ->
            #{}
    end.

ack(Account, Ids, #client{pid = Pid}) ->
    Folded = briskd_wire:fold(Account),
    case bound_device(Pid, Folded) of
        {ok, Dev} ->
            Seqs = [
                Seq
             || Text <- binary:split(Ids, <<",">>, [global, trim_all]), {ok, Seq} <- [seq(Text)]
            ],
            lists:foreach(
                fun(Seq) -> mnesia:dirty_delete(e2ee_queue, {Folded, Dev, Seq}) end, Seqs
            ),
            lists:foreach(
                fun briskd_e2ee_sync:broadcast/1,
                briskd_e2ee_sync:ack_lines(Account, Dev, Seqs)
            );
        none ->
            fail(Pid, <<"NOT_BOUND">>, [], <<"BIND a device first">>)
    end.

remove(Account, DevText, #client{pid = Pid}, Server) ->
    maybe
        {ok, Dev} ?= device_id(DevText),
        Folded = briskd_wire:fold(Account),
        [_] ?= mnesia:dirty_read(e2ee_device, {Folded, Dev}),
        delete_device(Folded, Dev),
        briskd_e2ee_sync:broadcast(briskd_e2ee_sync:delete_line(Account, Dev)),
        logger:info(#{event => e2ee_device_removed, account => Account, device => Dev}),
        reply(Pid, Server, [<<"REMOVED">>, integer_to_binary(Dev)])
    else
        [] ->
            fail(Pid, <<"UNKNOWN_DEVICE">>, [DevText], <<"No such device">>);
        {error, Field} ->
            fail(Pid, <<"INVALID_PARAMS">>, [Field], <<"Invalid device id">>)
    end.

-doc "Delete an E2EE device record and all queued envelopes for it.".
-spec delete_device(binary(), pos_integer()) -> ok.
delete_device(Folded, Dev) ->
    ok = mnesia:dirty_delete(e2ee_device, {Folded, Dev}),
    lists:foreach(
        fun(#e2ee_queue{key = Key}) -> mnesia:dirty_delete(e2ee_queue, Key) end,
        queued(Folded, Dev)
    ),
    true = ets:delete(?BOUND, {Folded, Dev}),
    ok.

%%% Delivery

-doc """
Offline queueing hook for a direct `PRIVMSG`, `NOTICE`, or `TAGMSG` (or a
`draft/multiline` batch) from `Client` to `Target`, called before normal
delivery. The last argument is `{ClientTags, Tags, Command}`: the sender's
client-only tags, the full tag list of the delivery (`msgid`, `time`, client
tags), and the command.

Returns `pass` (deliver normally; the message may also have been queued for
an offline device of an online user) or `handled` (the target is offline and
the envelope was queued or refused; nothing else to deliver). Messages
without the `dst` tag and the feature switched off always `pass`.
""".
-spec route(binary(), term(), #client{}, {[tuple()], [tuple()], binary()}) -> pass | handled.
route(Target, Body, Client, Context) ->
    briskd_e2ee_sync:route(Target, Body, Client, Context).

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

-doc "Forget the device binding of a remote user that left the network or logged out.".
-spec forget_remote(binary()) -> ok.
forget_remote(NickKey) ->
    case ets:whereis(?BOUND) of
        undefined ->
            ok;
        _ ->
            true = ets:match_delete(?BOUND, {'_', {remote, NickKey}}),
            ok
    end.

-doc """
Delete expired envelopes. Called from the state's one-second tick; it does
the work at most once every 60 seconds. Every server expires its own copies.
""".
-spec expire() -> ok.
expire() ->
    Now = erlang:system_time(second),
    case get(briskd_e2ee_expired_at) of
        Last when is_integer(Last), Now - Last < ?EXPIRE_EVERY ->
            ok;
        _ ->
            put(briskd_e2ee_expired_at, Now),
            Pattern = pattern(e2ee_queue, [{2, '$1'}, {#e2ee_queue.expires, '$2'}]),
            Expired = mnesia:dirty_select(e2ee_queue, [{Pattern, [{'<', '$2', Now}], ['$1']}]),
            lists:foreach(fun(Key) -> mnesia:dirty_delete(e2ee_queue, Key) end, Expired)
    end.

%%% Server links

-doc """
Lines for a new peer's burst: every device bundle with its unused one-time
prekeys, every queued envelope, and the device bound by each local
connection. Sent after the users, so `BIND` prefixes name known users.
""".
-spec burst_lines() -> [iodata()].
burst_lines() ->
    briskd_e2ee_sync:burst_lines().

-doc """
Apply one `E2EE` line from the peer `Peer` (`Prefix` is the source: a server,
or a user for `BIND`; `Tags` carry a queued envelope) and relay it to the
other peers. Returns `ok` or `{error, Reason}`, which drops the link like
other invalid peer state. A server without `e2ee` configured relays the line
without storing it.
""".
-spec receive_link(binary(), binary(), [binary()], [{binary(), undefined | binary()}]) ->
    ok | {error, term()}.
receive_link(Peer, Prefix, Params, Tags) ->
    briskd_e2ee_sync:receive_link(Peer, Prefix, Params, Tags).

-doc """
A remote user who bound a device changed nickname (`OldKey` and `NewKey` are
folded nicknames): move the binding to the new name.
""".
-spec remote_renamed(binary(), binary()) -> ok.
remote_renamed(OldKey, NewKey) ->
    briskd_e2ee_sync:remote_renamed(OldKey, NewKey).

%%% Helpers

resolve(Target) ->
    case recipient(Target) of
        {ok, Account, _} -> {ok, Account};
        {error, _} = Error -> Error
    end.

%% A target's account: the logged-in user who has the nickname now, or else
%% an account of that name.
-doc "Resolve `Target` (nick or account) to `{ok, Account, Endpoint}` or `{error, Code}`.".
-spec recipient(binary()) ->
    {ok, binary(), {local, pid()} | {remote, binary()} | offline} | {error, binary()}.
recipient(Target) ->
    case briskd_state_client:find_nick(Target) of
        #client{pid = Other} = Found ->
            case {briskd_state_client:ready(Found), briskd_state_v3:account(Other)} of
                {true, undefined} -> {error, <<"NO_ACCOUNT">>};
                {true, Account} -> {ok, Account, {local, Other}};
                {false, _} -> {error, <<"NO_SUCH_TARGET">>}
            end;
        undefined ->
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Target)) of
                [#remote_client{key = Key, account = Account}] when is_binary(Account) ->
                    %% A user on another server: normal delivery reaches it.
                    {ok, Account, {remote, Key}};
                [#remote_client{}] ->
                    {error, <<"NO_ACCOUNT">>};
                [] ->
                    case briskd_account:find(Target) of
                        {ok, #account{name = Name}} -> {ok, Name, offline};
                        error -> {error, <<"NO_SUCH_TARGET">>}
                    end
            end
    end.

-doc "Return all published `#e2ee_device{}` records for `Account`.".
-spec account_devices(binary()) -> [#e2ee_device{}].
account_devices(Account) ->
    Folded = briskd_wire:fold(Account),
    [
        D
     || #e2ee_device{} = D <- mnesia:dirty_select(
            e2ee_device, [{pattern(e2ee_device, [{2, {Folded, '_'}}]), [], ['$_']}]
        )
    ].

-doc "Return all queued `#e2ee_queue{}` records for `{Folded, Dev}`.".
-spec queued(binary(), pos_integer()) -> [#e2ee_queue{}].
queued(Folded, Dev) ->
    [
        Q
     || #e2ee_queue{} = Q <- mnesia:dirty_select(
            e2ee_queue, [{pattern(e2ee_queue, [{2, {Folded, Dev, '_'}}]), [], ['$_']}]
        )
    ].

%% A match-spec head for a record: '_' everywhere except the given positions.
%% Built as a tuple because typed record fields cannot hold '_'.
-doc "Build a Mnesia match-spec head tuple for `e2ee_device` or `e2ee_queue`.".
-spec pattern(e2ee_device | e2ee_queue, [{pos_integer(), term()}]) -> tuple().
pattern(e2ee_device, Fields) ->
    erlang:make_tuple(record_info(size, e2ee_device), '_', [{1, e2ee_device} | Fields]);
pattern(e2ee_queue, Fields) ->
    erlang:make_tuple(record_info(size, e2ee_queue), '_', [{1, e2ee_queue} | Fields]).

-doc "Look up the active local or remote connection bound to `{Account, Dev}`.".
-spec bound(binary(), pos_integer()) -> {ok, pid() | {remote, binary()}} | none.
bound(Account, Dev) ->
    Folded = briskd_wire:fold(Account),
    case ets:lookup(?BOUND, {Folded, Dev}) of
        [{_, Pid}] when is_pid(Pid) ->
            case same_account(briskd_state_v3:account(Pid), Folded) of
                true -> {ok, Pid};
                false -> none
            end;
        [{_, {remote, NickKey}}] ->
            case mnesia:dirty_read(remote_client, NickKey) of
                [#remote_client{account = Theirs}] ->
                    case same_account(Theirs, Folded) of
                        true -> {ok, {remote, NickKey}};
                        false -> none
                    end;
                [] ->
                    none
            end;
        [] ->
            none
    end.

same_account(Account, Folded) when is_binary(Account) ->
    briskd_wire:fold(Account) =:= Folded;
same_account(_, _) ->
    false.

bound_device(Pid, Folded) ->
    case ets:match_object(?BOUND, {{Folded, '_'}, Pid}) of
        [{{_, Dev}, _} | _] -> {ok, Dev};
        [] -> none
    end.

%% FETCH consumes one-time prekeys, so it is rate limited per connection.
fetch_allowed(Pid) ->
    #{fetch_rate := PerMinute} = config(),
    Now = erlang:monotonic_time(second),
    {Window, Count} = briskd_conn:get(Pid, e2ee_fetch, {Now, 0}),
    case Now - Window >= 60 of
        true ->
            briskd_conn:put(Pid, e2ee_fetch, {Now, 1}),
            ok;
        false when Count < PerMinute ->
            briskd_conn:put(Pid, e2ee_fetch, {Window, Count + 1}),
            ok;
        false ->
            rate_limited
    end.

-doc "Parse a 1..2147483647 device id.".
-spec device_id(term()) -> {ok, pos_integer()} | {error, binary()}.
device_id(Text) when is_binary(Text) ->
    case string:to_integer(Text) of
        {Id, <<>>} when is_integer(Id), Id >= 1, Id =< 2147483647 -> {ok, Id};
        _ -> {error, <<"device">>}
    end;
device_id(_) ->
    {error, <<"device">>}.

-doc "Parse a non-negative queue sequence number.".
-spec seq(binary()) -> {ok, non_neg_integer()} | error.
seq(Text) ->
    case string:to_integer(Text) of
        {Seq, <<>>} when is_integer(Seq), Seq >= 0 -> {ok, Seq};
        _ -> error
    end.

-doc "Parse a non-negative integer timestamp or id.".
-spec non_neg(binary()) -> {ok, non_neg_integer()} | error.
non_neg(Text) ->
    case string:to_integer(Text) of
        {N, <<>>} when is_integer(N), N >= 0 -> {ok, N};
        _ -> error
    end.

-doc "Validate an account name.".
-spec account_name(binary()) -> {ok, binary()} | error.
account_name(Text) ->
    case briskd_account:valid_name(Text) of
        true -> {ok, Text};
        false -> error
    end.

-doc "Decode a base64 E2EE public key or signature.".
-spec key(binary()) -> {ok, binary()} | {error, binary()}.
key(Text) when byte_size(Text) >= 4, byte_size(Text) =< ?MAX_KEY_CHARS ->
    try base64:decode(Text) of
        Bin -> {ok, Bin}
    catch
        error:_ -> {error, <<"key">>}
    end;
key(_) ->
    {error, <<"key">>}.

-doc "Parse an `<id>:<base64-key>` prekey entry.".
-spec id_key(binary()) -> {ok, {non_neg_integer(), binary()}} | {error, binary()}.
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

-doc "Parse a list of `<id>:<base64-key>` prekey entries.".
-spec id_keys([binary()]) -> {ok, [{non_neg_integer(), binary()}]} | {error, binary()}.
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

-doc "Base64-encode raw E2EE key bytes.".
-spec b64(binary()) -> binary().
b64(Bin) ->
    base64:encode(Bin).

-doc "Send an `E2EE` reply line to `Pid`.".
-spec reply(pid(), binary(), [binary()]) -> ok.
reply(Pid, Server, Middle) ->
    briskd_state_send:send(Pid, Server, <<"E2EE">>, Middle, none).

reply(Pid, Server, Middle, Trailing) ->
    briskd_state_send:send(Pid, Server, <<"E2EE">>, Middle, Trailing).

-doc "Send a `FAIL E2EE` reply to `Pid`.".
-spec fail(pid(), binary(), [binary()], binary()) -> ok.
fail(Pid, Code, Context, Text) ->
    briskd_state_send:fail(Pid, <<"E2EE">>, Code, Context, Text).

-doc "Return the current `e2ee` configuration map or `null`.".
-spec config() -> map() | null.
config() ->
    maps:get(e2ee, briskd_config:current_or_empty(), null).

-doc "Return the configured local server name.".
-spec server() -> binary().
server() ->
    maps:get(name, briskd_config:current_or_empty(), <<"irc.local">>).
