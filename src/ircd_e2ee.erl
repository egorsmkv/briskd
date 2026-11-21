-module(ircd_e2ee).
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
    remote_renamed/2
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

Runs inside the `ircd_state` process; the tables are in
`include/ircd_e2ee.hrl`.
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
%% Remembered ids of handed-out one-time prekeys per device.
-define(MAX_USED, 1000).
%% One-time prekeys per PREKEYS line over a link (stays within 512 octets).
-define(PREKEYS_PER_LINE, 6).
%% Decoded size limits for a replicated envelope.
-define(MAX_BODY_BYTES, 8192).
-define(MAX_TAGS_BYTES, 4096).

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
    case {ircd_cap:enabled(Pid, ?CAP), Params} of
        {false, _} ->
            fail(Pid, <<"CAP_REQUIRED">>, [], <<"Request the e2ee capability first">>);
        {true, []} ->
            fail(Pid, <<"NEED_MORE_PARAMS">>, [], <<"Missing subcommand">>);
        {true, [Sub | Rest]} ->
            subcommand(ircd_wire:upper(Sub), Rest, Client, Server)
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
        {Prekeys, Used} =
            case Existing of
                [#e2ee_device{prekeys = Old, used = OldUsed}] -> {Old, OldUsed};
                [] -> {[], []}
            end,
        Device = #e2ee_device{
            key = Key,
            account = ircd_wire:retain(Account),
            identity = Identity,
            signed_prekey_id = SpkId,
            signed_prekey = Spk,
            signature = Signature,
            prekeys = Prekeys,
            updated = erlang:system_time(microsecond),
            used = Used
        },
        ok = mnesia:dirty_write(Device),
        broadcast(device_line(Device)),
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
            mnesia:dirty_read(e2ee_device, {ircd_wire:fold(Account), Dev}),
        {ok, New} ?= id_keys(KeyTexts),
        Merged = merge_prekeys(Old, New, Used),
        true ?= length(Merged) =< Max orelse too_many,
        ok = mnesia:dirty_write(Device#e2ee_device{prekeys = Merged}),
        lists:foreach(fun broadcast/1, prekeys_lines(Account, Dev, New)),
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
%% Ids already handed out are never stored again.
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
                broadcast(use_line(Device#e2ee_device.account, Dev, Id)),
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

%% Remove one prekey, remember its id, and tell a low device's owner.
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
        Folded = ircd_wire:fold(Account),
        [_] ?= mnesia:dirty_read(e2ee_device, {Folded, Dev}),
        true = ets:match_delete(?BOUND, {'_', Pid}),
        true = ets:insert(?BOUND, {{Folded, Dev}, Pid}),
        broadcast(bind_line(Client, Dev)),
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
    ircd_state_send:with_source(replay_source(Prefix), fun() ->
        case Text of
            {multiline, Lines} ->
                ircd_state_batch:deliver_multiline(
                    Pid, Prefix, Command, Target, Lines, Delivery, normal
                );
            _ ->
                ircd_state_send:send(Pid, Prefix, Command, [Target], Text, Delivery)
        end
    end).

replay_source(Prefix) when is_binary(Prefix) ->
    case binary:split(Prefix, <<"!">>) of
        [Nick, _] ->
            case ircd_state_client:find_nick(Nick) of
                #client{} = Client ->
                    case iolist_to_binary(ircd_state_send:prefix(Client)) =:= Prefix of
                        true -> ircd_state_v3:source_info(Client);
                        false -> #{}
                    end;
                undefined ->
                    ircd_state_v3:remote_source_info(Prefix)
            end;
        _ ->
            #{}
    end.

ack(Account, Ids, #client{pid = Pid}) ->
    Folded = ircd_wire:fold(Account),
    case bound_device(Pid, Folded) of
        {ok, Dev} ->
            Seqs = [
                Seq
             || Text <- binary:split(Ids, <<",">>, [global, trim_all]), {ok, Seq} <- [seq(Text)]
            ],
            lists:foreach(
                fun(Seq) -> mnesia:dirty_delete(e2ee_queue, {Folded, Dev, Seq}) end, Seqs
            ),
            lists:foreach(fun broadcast/1, ack_lines(Account, Dev, Seqs));
        none ->
            fail(Pid, <<"NOT_BOUND">>, [], <<"BIND a device first">>)
    end.

remove(Account, DevText, #client{pid = Pid}, Server) ->
    maybe
        {ok, Dev} ?= device_id(DevText),
        Folded = ircd_wire:fold(Account),
        [_] ?= mnesia:dirty_read(e2ee_device, {Folded, Dev}),
        delete_device(Folded, Dev),
        broadcast(delete_line(Account, Dev)),
        logger:info(#{event => e2ee_device_removed, account => Account, device => Dev}),
        reply(Pid, Server, [<<"REMOVED">>, integer_to_binary(Dev)])
    else
        [] ->
            fail(Pid, <<"UNKNOWN_DEVICE">>, [DevText], <<"No such device">>);
        {error, Field} ->
            fail(Pid, <<"INVALID_PARAMS">>, [Field], <<"Invalid device id">>)
    end.

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
route(Target, Body, Client, {ClientTags, Tags, Command}) ->
    case {enabled(), lists:keyfind(tag(dst), 1, ClientTags), queueable(Body)} of
        {true, {_, DevText}, true} ->
            case {device_id(DevText), recipient(Target)} of
                {{ok, Dev}, {ok, Account, Endpoint}} ->
                    queue_if_unbound(Account, Dev, Endpoint, Target, Body, Client, {Tags, Command});
                %% A bad device id, a user without an account, or no such
                %% user or account: normal delivery applies (or reports 401).
                _ ->
                    pass
            end;
        _ ->
            pass
    end.

queueable(Text) when is_binary(Text) -> true;
queueable(none) -> true;
queueable({multiline, Lines}) when is_list(Lines) -> true;
queueable(_) -> false.

queue_if_unbound(
    Account, Dev, Endpoint, Target, Body, #client{pid = Pid} = Client, {Tags, Command}
) ->
    Folded = ircd_wire:fold(Account),
    case {bound(Account, Dev), mnesia:dirty_read(e2ee_device, {Folded, Dev})} of
        {{ok, Holder}, _} ->
            %% The device is online. Its connection may use another nickname
            %% than the target (a second device of the same account): give
            %% it its own copy unless normal delivery already reaches it.
            case reaches(Endpoint, Holder) of
                true -> ok;
                false -> deliver_to(Holder, Target, Body, Client, {Tags, Command})
            end;
        {none, []} ->
            fail(Pid, <<"UNKNOWN_DEVICE">>, [Target, integer_to_binary(Dev)], <<"No such device">>);
        {none, [_]} ->
            enqueue(Account, Dev, Target, Body, Client, {Tags, Command})
    end,
    case Endpoint of
        offline -> handled;
        _ -> pass
    end.

%% Normal delivery to the target reaches the device's connection: it is the
%% target's own connection, or attached to it (multiclient mirrors).
reaches({local, Pid}, Pid) ->
    true;
reaches({local, Primary}, Holder) when is_pid(Holder) ->
    ets:lookup(ircd_attached, Holder) =:= [{Holder, Primary}];
reaches({remote, Key}, {remote, Key}) ->
    true;
reaches(_, _) ->
    false.

%% A copy of the envelope for the bound connection: directly to a local
%% session, or over the link to a remote user (addressed to that nickname).
deliver_to(Holder, Target, Body, Client, {Tags, Command}) when is_pid(Holder) ->
    Prefix = ircd_state_send:prefix(Client),
    case Body of
        {multiline, Lines} ->
            ircd_state_batch:deliver_multiline(
                Holder, Prefix, Command, Target, Lines, Tags, normal
            );
        _ ->
            ircd_state_send:send(Holder, Prefix, Command, [Target], Body, Tags)
    end;
deliver_to({remote, NickKey}, _Target, Body, Client, {Tags, Command}) ->
    case mnesia:dirty_read(remote_client, NickKey) of
        [#remote_client{peer = Peer, nick = Nick}] ->
            Prefix = ircd_state_send:prefix(Client),
            lists:foreach(
                fun(Line) -> _ = ircd_links:send(Peer, iolist_to_binary(Line)) end,
                ircd_state_batch:link_lines(Prefix, Command, Nick, Body, Tags)
            );
        [] ->
            ok
    end.

enqueue(Account, Dev, Target, Body, #client{pid = Pid} = Client, {Tags, Command}) ->
    #{queue_limit := Limit, queue_ttl := Ttl} = config(),
    Folded = ircd_wire:fold(Account),
    Now = erlang:system_time(second),
    LiveCount = length([
        E
     || #e2ee_queue{key = Key, expires = Exp} = E <- queued(Folded, Dev),
        case Exp =< Now of
            true ->
                ok = mnesia:dirty_delete(e2ee_queue, Key),
                false;
            false ->
                true
        end
    ]),
    case {ircd_state_v3:account(Pid), LiveCount < Limit} of
        {undefined, _} ->
            fail(Pid, <<"ACCOUNT_REQUIRED">>, [Target], <<"Log in to queue encrypted messages">>);
        {_, false} ->
            fail(
                Pid, <<"QUEUE_FULL">>, [Target, integer_to_binary(Dev)], <<"Device queue is full">>
            );
        {SenderAccount, true} ->
            Prefix = iolist_to_binary(ircd_state_send:prefix(Client)),
            StoredTags =
                [{ircd_wire:retain(K), ircd_wire:retain(V)} || {K, V} <- Tags] ++
                    [
                        {ircd_wire:retain(K), ircd_wire:retain(V)}
                     || {K, V} <- ircd_state_send:source_tags(Prefix),
                        not lists:keymember(K, 1, Tags)
                    ],
            Seq = next_seq(Folded, Dev),
            Entry = #e2ee_queue{
                key = {Folded, Dev, Seq},
                prefix = Prefix,
                command = Command,
                target = ircd_wire:retain(Target),
                text = retain_body(Body),
                tags = StoredTags,
                expires = Now + Ttl
            },
            ok = mnesia:dirty_write(Entry),
            broadcast(queue_line(Account, Entry)),
            ircd_state_history:note_direct(
                {SenderAccount, Client#client.nick},
                {Account, Target},
                Target,
                ircd_state_history:entry(
                    Command,
                    Prefix,
                    Body,
                    case lists:keyfind(<<"msgid">>, 1, Tags) of
                        {_, Id} -> Id;
                        false -> ircd_state_send:msgid()
                    end,
                    erlang:system_time(millisecond),
                    ircd_cap:client_tags(Tags),
                    SenderAccount
                )
            ),
            reply(Pid, server(), [
                <<"QUEUED">>, Target, integer_to_binary(Dev), integer_to_binary(Seq)
            ])
    end.

retain_body({multiline, Lines}) ->
    {multiline, [{Concat, ircd_wire:retain(Text)} || {Concat, Text} <- Lines]};
retain_body(Body) ->
    ircd_wire:retain(Body).

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
    case get(ircd_e2ee_expired_at) of
        Last when is_integer(Last), Now - Last < ?EXPIRE_EVERY ->
            ok;
        _ ->
            put(ircd_e2ee_expired_at, Now),
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
    Devices = mnesia:dirty_select(e2ee_device, [{pattern(e2ee_device, []), [], ['$_']}]),
    DeviceLines = lists:append([
        [device_line(D) | prekeys_lines(Account, Dev, Prekeys)]
     || #e2ee_device{key = {_, Dev}, account = Account, prekeys = Prekeys} = D <- Devices
    ]),
    Accounts = #{Key => Account || #e2ee_device{key = {Key, _}, account = Account} <- Devices},
    QueueLines = [
        queue_line(maps:get(Folded, Accounts, Folded), Entry)
     || #e2ee_queue{key = {Folded, _, _}} = Entry <- mnesia:dirty_select(e2ee_queue, [
            {pattern(e2ee_queue, []), [], ['$_']}
        ])
    ],
    BindLines = lists:append([
        case Holder of
            Pid when is_pid(Pid) ->
                [
                    bind_line(Client, Dev)
                 || [#client{} = Client] <- [mnesia:dirty_read(client, Pid)]
                ];
            {remote, NickKey} ->
                [
                    ircd_wire:line(
                        <<Nick/binary, "!", User/binary, "@", Host/binary>>,
                        <<"E2EE">>,
                        [<<"BIND">>, integer_to_binary(Dev)],
                        none
                    )
                 || [#remote_client{nick = Nick, user = User, host = Host}] <- [
                        mnesia:dirty_read(remote_client, NickKey)
                    ]
                ]
        end
     || {{_, Dev}, Holder} <- ets:tab2list(?BOUND)
    ]),
    [L || L <- DeviceLines ++ QueueLines ++ BindLines, L =/= []].

-doc """
Apply one `E2EE` line from the peer `Peer` (`Prefix` is the source: a server,
or a user for `BIND`; `Tags` carry a queued envelope) and relay it to the
other peers. Returns `ok` or `{error, Reason}`, which drops the link like
other invalid peer state. A server without `e2ee` configured relays the line
without storing it.
""".
-spec receive_link(binary(), binary(), [binary()], [{binary(), undefined | binary()}]) ->
    ok | {error, term()}.
receive_link(Peer, Prefix, [Sub | Params], Tags) ->
    try link_command(ircd_wire:upper(Sub), Peer, Prefix, Params, Tags) of
        {ok, Line} ->
            ircd_state_link:relay_except(Peer, Line),
            ok;
        {error, _} = Error ->
            Error
    catch
        error:Reason ->
            logger:warning(#{event => e2ee_link_rejected, peer => Peer, reason => Reason}),
            {error, {invalid_e2ee, Sub}}
    end;
receive_link(_Peer, _Prefix, [], _Tags) ->
    {error, invalid_e2ee}.

link_command(
    <<"DEVICE">>, Peer, Prefix, [AccountText, DevText, UpdatedText, Identity, Spk, Sig], _
) ->
    true = ircd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = account_name(AccountText),
    {ok, Dev} = device_id(DevText),
    {ok, Updated} = non_neg(UpdatedText),
    {ok, IdentityKey} = key(Identity),
    {ok, {SpkId, SpkKey}} = id_key(Spk),
    {ok, Signature} = key(Sig),
    Key = {ircd_wire:fold(Account), Dev},
    Device0 = #e2ee_device{
        key = Key,
        account = ircd_wire:retain(Account),
        identity = IdentityKey,
        signed_prekey_id = SpkId,
        signed_prekey = SpkKey,
        signature = Signature,
        updated = Updated
    },
    store(fun() ->
        #{max_devices := MaxDevices} = config(),
        case mnesia:dirty_read(e2ee_device, Key) of
            [#e2ee_device{updated = Mine}] when Mine > Updated ->
                ok;
            [#e2ee_device{prekeys = Prekeys, used = Used}] ->
                ok = mnesia:dirty_write(Device0#e2ee_device{prekeys = Prekeys, used = Used});
            [] ->
                case length(account_devices(Account)) < MaxDevices of
                    true -> ok = mnesia:dirty_write(Device0);
                    false -> ok
                end
        end
    end),
    {ok, device_line(Device0)};
link_command(<<"PREKEYS">>, Peer, Prefix, [AccountText, DevText | KeyTexts], _) ->
    true = ircd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = account_name(AccountText),
    {ok, Dev} = device_id(DevText),
    {ok, New} = id_keys(KeyTexts),
    true = New =/= [] andalso length(New) =< ?PREKEYS_PER_LINE * 2,
    store(fun() ->
        case mnesia:dirty_read(e2ee_device, {ircd_wire:fold(Account), Dev}) of
            [#e2ee_device{prekeys = Old, used = Used} = Device] ->
                #{max_prekeys := Max} = config(),
                Merged = lists:sublist(merge_prekeys(Old, New, Used), Max),
                ok = mnesia:dirty_write(Device#e2ee_device{prekeys = Merged});
            [] ->
                ok
        end
    end),
    {ok, prekeys_line(Account, Dev, New)};
link_command(<<"USE">>, Peer, Prefix, [AccountText, DevText, IdText], _) ->
    true = ircd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = account_name(AccountText),
    {ok, Dev} = device_id(DevText),
    {ok, Id} = non_neg(IdText),
    store(fun() ->
        case mnesia:dirty_read(e2ee_device, {ircd_wire:fold(Account), Dev}) of
            [#e2ee_device{} = Device] -> consume(Device, Id);
            [] -> ok
        end
    end),
    {ok, use_line(Account, Dev, Id)};
link_command(<<"DELETE">>, Peer, Prefix, [AccountText, DevText], _) ->
    true = ircd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = account_name(AccountText),
    {ok, Dev} = device_id(DevText),
    store(fun() -> delete_device(ircd_wire:fold(Account), Dev) end),
    {ok, delete_line(Account, Dev)};
link_command(
    <<"QUEUE">>,
    Peer,
    Prefix,
    [AccountText, DevText, SeqText, ExpiresText, Command, Target, Sender],
    Tags
) ->
    true = ircd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = account_name(AccountText),
    {ok, Dev} = device_id(DevText),
    {ok, Seq} = seq(SeqText),
    {ok, Expires} = non_neg(ExpiresText),
    true = lists:member(Command, [<<"PRIVMSG">>, <<"NOTICE">>, <<"TAGMSG">>]),
    true = byte_size(Target) =< 64 andalso byte_size(Sender) =< 255,
    {_, BodyText} = lists:keyfind(tag(body), 1, Tags),
    {_, TagsText} = lists:keyfind(tag(tags), 1, Tags),
    Folded = ircd_wire:fold(Account),
    Entry = #e2ee_queue{
        key = {Folded, Dev, Seq},
        prefix = ircd_wire:retain(Sender),
        command = Command,
        target = ircd_wire:retain(Target),
        text = decode_body(BodyText),
        tags = decode_tags(TagsText),
        expires = Expires
    },
    store(fun() ->
        #{queue_limit := Limit} = config(),
        Now = erlang:system_time(second),
        Fresh = Expires > Now,
        LiveCount = length([
            E
         || #e2ee_queue{key = K, expires = Exp} = E <- queued(Folded, Dev),
            case Exp =< Now of
                true ->
                    ok = mnesia:dirty_delete(e2ee_queue, K),
                    false;
                false ->
                    true
            end
        ]),
        Room =
            mnesia:dirty_read(e2ee_device, {Folded, Dev}) =/= [] andalso
                (mnesia:dirty_read(e2ee_queue, {Folded, Dev, Seq}) =/= [] orelse
                    LiveCount < Limit),
        case Fresh andalso Room of
            true -> ok = mnesia:dirty_write(Entry);
            false -> ok
        end
    end),
    {ok, queue_line(Account, Entry)};
link_command(<<"ACK">>, Peer, Prefix, [AccountText, DevText, SeqsText], _) ->
    true = ircd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = account_name(AccountText),
    {ok, Dev} = device_id(DevText),
    Seqs = [
        Seq
     || Text <- binary:split(SeqsText, <<",">>, [global, trim_all]), {ok, Seq} <- [seq(Text)]
    ],
    true = Seqs =/= [],
    Folded = ircd_wire:fold(Account),
    store(fun() ->
        lists:foreach(fun(Seq) -> mnesia:dirty_delete(e2ee_queue, {Folded, Dev, Seq}) end, Seqs)
    end),
    {ok, ack_line(Account, Dev, Seqs)};
link_command(<<"BIND">>, Peer, Prefix, [DevText], _) ->
    {ok, Dev} = device_id(DevText),
    %% The source must be a user reached through this link, logged in.
    %% The device row must already exist (a prior DEVICE line). A binding
    %% held by a local session is not replaced.
    case ircd_state_link:remote_source(Peer, Prefix) of
        {ok, #remote_client{key = NickKey, account = Account}} when is_binary(Account) ->
            Folded = ircd_wire:fold(Account),
            case mnesia:dirty_read(e2ee_device, {Folded, Dev}) of
                [] ->
                    {error, e2ee_unknown_device};
                [_] ->
                    case ets:lookup(?BOUND, {Folded, Dev}) of
                        [{_, Owner}] when is_pid(Owner) ->
                            {error, e2ee_device_bound_locally};
                        _ ->
                            store(fun() ->
                                true = ets:match_delete(?BOUND, {'_', {remote, NickKey}}),
                                true = ets:insert(?BOUND, {{Folded, Dev}, {remote, NickKey}})
                            end),
                            {ok,
                                ircd_wire:line(
                                    Prefix, <<"E2EE">>, [<<"BIND">>, integer_to_binary(Dev)], none
                                )}
                    end
            end;
        {ok, #remote_client{}} ->
            {error, e2ee_bind_without_account};
        _ ->
            {error, unknown_remote_source}
    end;
link_command(Sub, _Peer, _Prefix, _Params, _) ->
    {error, {unknown_e2ee_command, Sub}}.

%% Run a storage change only when this server has the feature on.
store(Fun) ->
    case enabled() of
        true ->
            _ = Fun(),
            ok;
        false ->
            ok
    end.

-doc """
A remote user who bound a device changed nickname (`OldKey` and `NewKey` are
folded nicknames): move the binding to the new name.
""".
-spec remote_renamed(binary(), binary()) -> ok.
remote_renamed(OldKey, NewKey) ->
    case ets:whereis(?BOUND) of
        undefined ->
            ok;
        _ ->
            Moved = ets:match_object(?BOUND, {'_', {remote, OldKey}}),
            lists:foreach(
                fun({Key, _}) -> true = ets:insert(?BOUND, {Key, {remote, NewKey}}) end, Moved
            ),
            ok
    end.

device_line(#e2ee_device{key = {_, Dev}, account = Account} = D) ->
    ircd_wire:line(
        server(),
        <<"E2EE">>,
        [
            <<"DEVICE">>,
            Account,
            integer_to_binary(Dev),
            integer_to_binary(D#e2ee_device.updated),
            b64(D#e2ee_device.identity),
            <<
                (integer_to_binary(D#e2ee_device.signed_prekey_id))/binary,
                ":",
                (b64(D#e2ee_device.signed_prekey))/binary
            >>,
            b64(D#e2ee_device.signature)
        ],
        none
    ).

prekeys_lines(Account, Dev, Prekeys) ->
    [prekeys_line(Account, Dev, Chunk) || Chunk <- chunks(Prekeys, ?PREKEYS_PER_LINE)].

prekeys_line(Account, Dev, Prekeys) ->
    ircd_wire:line(
        server(),
        <<"E2EE">>,
        [<<"PREKEYS">>, Account, integer_to_binary(Dev)] ++
            [<<(integer_to_binary(Id))/binary, ":", (b64(Key))/binary>> || {Id, Key} <- Prekeys],
        none
    ).

use_line(Account, Dev, Id) ->
    ircd_wire:line(
        server(),
        <<"E2EE">>,
        [<<"USE">>, Account, integer_to_binary(Dev), integer_to_binary(Id)],
        none
    ).

delete_line(Account, Dev) ->
    ircd_wire:line(server(), <<"E2EE">>, [<<"DELETE">>, Account, integer_to_binary(Dev)], none).

ack_lines(Account, Dev, Seqs) ->
    [ack_line(Account, Dev, Chunk) || Chunk <- chunks(Seqs, 15)].

ack_line(Account, Dev, Seqs) ->
    ircd_wire:line(
        server(),
        <<"E2EE">>,
        [
            <<"ACK">>,
            Account,
            integer_to_binary(Dev),
            binary:join([integer_to_binary(S) || S <- Seqs], <<",">>)
        ],
        none
    ).

bind_line(Client, Dev) ->
    ircd_wire:line(
        ircd_state_send:prefix(Client), <<"E2EE">>, [<<"BIND">>, integer_to_binary(Dev)], none
    ).

%% The envelope body and its delivery tags travel in server tags (base64
%% JSON), so the 512-octet line limit does not apply to them. An envelope
%% too large for the 8191-byte tag section is not replicated (`[]`).
queue_line(Account, #e2ee_queue{key = {_, Dev, Seq}} = Entry) ->
    ircd_wire:message(
        [
            {tag(body), encode_body(Entry#e2ee_queue.text)},
            {tag(tags), encode_tags(Entry#e2ee_queue.tags)}
        ],
        server(),
        <<"E2EE">>,
        [
            <<"QUEUE">>,
            Account,
            integer_to_binary(Dev),
            integer_to_binary(Seq),
            integer_to_binary(Entry#e2ee_queue.expires),
            Entry#e2ee_queue.command,
            Entry#e2ee_queue.target,
            Entry#e2ee_queue.prefix
        ],
        none
    ).

encode_body(none) ->
    json_b64(#{<<"none">> => true});
encode_body({multiline, Lines}) ->
    json_b64(#{<<"ml">> => [[Concat, base64:encode(Text)] || {Concat, Text} <- Lines]});
encode_body(Text) when is_binary(Text) ->
    json_b64(#{<<"t">> => base64:encode(Text)}).

decode_body(Encoded) ->
    Json = base64:decode(Encoded),
    true = byte_size(Json) =< ?MAX_BODY_BYTES * 2,
    case json:decode(Json) of
        #{<<"none">> := true} ->
            none;
        #{<<"t">> := Text} ->
            bounded(base64:decode(Text));
        #{<<"ml">> := Lines} when is_list(Lines), Lines =/= [] ->
            Decoded = [
                {Concat, base64:decode(Text)}
             || [Concat, Text] <- Lines, is_boolean(Concat)
            ],
            true = length(Decoded) =:= length(Lines),
            true = lists:sum([byte_size(T) || {_, T} <- Decoded]) =< ?MAX_BODY_BYTES,
            {multiline, Decoded}
    end.

bounded(Bin) when byte_size(Bin) =< ?MAX_BODY_BYTES -> Bin.

encode_tags(Tags) ->
    json_b64([[base64:encode(K), tag_value(V)] || {K, V} <- Tags]).

tag_value(undefined) -> null;
tag_value(V) -> base64:encode(V).

decode_tags(Encoded) ->
    Json = base64:decode(Encoded),
    true = byte_size(Json) =< ?MAX_TAGS_BYTES * 2,
    Raw = json:decode(Json),
    true = is_list(Raw),
    Tags = [{base64:decode(K), untag_value(V)} || [K, V] <- Raw],
    true = length(Tags) =:= length(Raw),
    true = lists:sum([byte_size(K) + tag_size(V) || {K, V} <- Tags]) =< ?MAX_TAGS_BYTES,
    Tags.

untag_value(null) -> undefined;
untag_value(V) -> base64:decode(V).

tag_size(undefined) -> 0;
tag_size(V) -> byte_size(V).

json_b64(Term) ->
    base64:encode(iolist_to_binary(json:encode(Term))).

chunks([], _N) ->
    [];
chunks(List, N) when length(List) =< N ->
    [List];
chunks(List, N) ->
    {Chunk, Rest} = lists:split(N, List),
    [Chunk | chunks(Rest, N)].

broadcast([]) ->
    ok;
broadcast(Line) ->
    ircd_state_link:server_broadcast(Line).

%%% Helpers

%% A target's account: the logged-in user who has the nickname now, or else
%% an account of that name.
resolve(Target) ->
    case recipient(Target) of
        {ok, Account, _} -> {ok, Account};
        {error, _} = Error -> Error
    end.

%% The endpoint is where normal delivery to Target goes: a local session,
%% a remote user (folded nickname), or `offline` for an account name.
recipient(Target) ->
    case ircd_state_client:find_nick(Target) of
        #client{pid = Other} = Found ->
            case {ircd_state_client:ready(Found), ircd_state_v3:account(Other)} of
                {true, undefined} -> {error, <<"NO_ACCOUNT">>};
                {true, Account} -> {ok, Account, {local, Other}};
                {false, _} -> {error, <<"NO_SUCH_TARGET">>}
            end;
        undefined ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Target)) of
                [#remote_client{key = Key, account = Account}] when is_binary(Account) ->
                    %% A user on another server: normal delivery reaches it.
                    {ok, Account, {remote, Key}};
                [#remote_client{}] ->
                    {error, <<"NO_ACCOUNT">>};
                [] ->
                    case ircd_account:find(Target) of
                        {ok, #account{name = Name}} -> {ok, Name, offline};
                        error -> {error, <<"NO_SUCH_TARGET">>}
                    end
            end
    end.

account_devices(Account) ->
    Folded = ircd_wire:fold(Account),
    mnesia:dirty_select(e2ee_device, [{pattern(e2ee_device, [{2, {Folded, '_'}}]), [], ['$_']}]).

queued(Folded, Dev) ->
    mnesia:dirty_select(e2ee_queue, [{pattern(e2ee_queue, [{2, {Folded, Dev, '_'}}]), [], ['$_']}]).

%% A match-spec head for a record: '_' everywhere except the given positions.
%% Built as a tuple because typed record fields cannot hold '_'.
pattern(e2ee_device, Fields) ->
    erlang:make_tuple(record_info(size, e2ee_device), '_', [{1, e2ee_device} | Fields]);
pattern(e2ee_queue, Fields) ->
    erlang:make_tuple(record_info(size, e2ee_queue), '_', [{1, e2ee_queue} | Fields]).

%% The connection bound to a device: a local pid still logged into that
%% account, or a remote user (folded nickname) who still has that account.
bound(Account, Dev) ->
    Folded = ircd_wire:fold(Account),
    case ets:lookup(?BOUND, {Folded, Dev}) of
        [{_, Pid}] when is_pid(Pid) ->
            case same_account(ircd_state_v3:account(Pid), Folded) of
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
    ircd_wire:fold(Account) =:= Folded;
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

seq(Text) ->
    case string:to_integer(Text) of
        {Seq, <<>>} when is_integer(Seq), Seq >= 0 -> {ok, Seq};
        _ -> error
    end.

non_neg(Text) ->
    case string:to_integer(Text) of
        {N, <<>>} when is_integer(N), N >= 0 -> {ok, N};
        _ -> error
    end.

account_name(Text) ->
    case ircd_account:valid_name(Text) of
        true -> {ok, Text};
        false -> error
    end.

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
    maps:get(e2ee, ircd_config:current_or_empty(), null).

server() ->
    maps:get(name, ircd_config:current_or_empty(), <<"irc.local">>).
