-module(briskd_e2ee_sync).
-moduledoc """
Offline envelope routing and server-link burst/replication for `m:briskd_e2ee`.
""".

-include("briskd_client.hrl").
-include("briskd_remote.hrl").
-include("briskd_e2ee.hrl").

-export([
    route/4,
    burst_lines/0,
    receive_link/4,
    remote_renamed/2,
    ack_lines/3,
    bind_line/2,
    broadcast/1,
    delete_line/2,
    device_line/1,
    prekeys_lines/3,
    use_line/3
]).

-define(BOUND, briskd_e2ee_bound).
%% One-time prekeys per PREKEYS line over a link (stays within 512 octets).
-define(PREKEYS_PER_LINE, 6).
%% Decoded size limits for a replicated envelope.
-define(MAX_BODY_BYTES, 8192).
-define(MAX_TAGS_BYTES, 4096).

%%% Delivery

-doc """
Offline queueing hook for a direct `PRIVMSG`, `NOTICE`, or `TAGMSG` (or a
`draft/multiline` batch) from `Client` to `Target`, called before normal
delivery.
""".
-spec route(binary(), term(), #client{}, {[tuple()], [tuple()], binary()}) -> pass | handled.
route(Target, Body, Client, {ClientTags, Tags, Command}) ->
    case
        {briskd_e2ee:enabled(), lists:keyfind(briskd_e2ee:tag(dst), 1, ClientTags), queueable(Body)}
    of
        {true, {_, DevText}, true} ->
            case {briskd_e2ee:device_id(DevText), briskd_e2ee:recipient(Target)} of
                {{ok, Dev}, {ok, Account, Endpoint}} ->
                    queue_if_unbound(
                        Account, Dev, Endpoint, Target, Body, Client, {Tags, Command}
                    );
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
    Folded = briskd_wire:fold(Account),
    case {briskd_e2ee:bound(Account, Dev), mnesia:dirty_read(e2ee_device, {Folded, Dev})} of
        {{ok, Holder}, _} ->
            %% The device is online. Its connection may use another nickname
            %% than the target (a second device of the same account): give
            %% it its own copy unless normal delivery already reaches it.
            case reaches(Endpoint, Holder) of
                true -> ok;
                false -> deliver_to(Holder, Target, Body, Client, {Tags, Command})
            end;
        {none, []} ->
            briskd_e2ee:fail(
                Pid, <<"UNKNOWN_DEVICE">>, [Target, integer_to_binary(Dev)], <<"No such device">>
            );
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
    ets:lookup(briskd_attached, Holder) =:= [{Holder, Primary}];
reaches({remote, Key}, {remote, Key}) ->
    true;
reaches(_, _) ->
    false.

%% A copy of the envelope for the bound connection: directly to a local
%% session, or over the link to a remote user (addressed to that nickname).
deliver_to(Holder, Target, Body, Client, {Tags, Command}) when is_pid(Holder) ->
    Prefix = briskd_state_send:prefix(Client),
    case Body of
        {multiline, Lines} ->
            briskd_state_batch:deliver_multiline(
                Holder, Prefix, Command, Target, Lines, Tags, normal
            );
        _ ->
            briskd_state_send:send(Holder, Prefix, Command, [Target], Body, Tags)
    end;
deliver_to({remote, NickKey}, _Target, Body, Client, {Tags, Command}) ->
    case mnesia:dirty_read(remote_client, NickKey) of
        [#remote_client{peer = Peer, nick = Nick}] ->
            Prefix = briskd_state_send:prefix(Client),
            lists:foreach(
                fun(Line) -> _ = briskd_links:send(Peer, iolist_to_binary(Line)) end,
                briskd_state_batch:link_lines(Prefix, Command, Nick, Body, Tags)
            );
        [] ->
            ok
    end.

enqueue(Account, Dev, Target, Body, #client{pid = Pid} = Client, {Tags, Command}) ->
    #{queue_limit := Limit, queue_ttl := Ttl} = briskd_e2ee:config(),
    Folded = briskd_wire:fold(Account),
    Now = erlang:system_time(second),
    LiveCount = length([
        E
     || #e2ee_queue{key = Key, expires = Exp} = E <- briskd_e2ee:queued(Folded, Dev),
        case Exp =< Now of
            true ->
                ok = mnesia:dirty_delete(e2ee_queue, Key),
                false;
            false ->
                true
        end
    ]),
    case {briskd_state_v3:account(Pid), LiveCount < Limit} of
        {undefined, _} ->
            briskd_e2ee:fail(
                Pid, <<"ACCOUNT_REQUIRED">>, [Target], <<"Log in to queue encrypted messages">>
            );
        {_, false} ->
            briskd_e2ee:fail(
                Pid,
                <<"QUEUE_FULL">>,
                [Target, integer_to_binary(Dev)],
                <<"Device queue is full">>
            );
        {SenderAccount, true} ->
            Prefix = iolist_to_binary(briskd_state_send:prefix(Client)),
            StoredTags =
                [{briskd_wire:retain(K), briskd_wire:retain(V)} || {K, V} <- Tags] ++
                    [
                        {briskd_wire:retain(K), briskd_wire:retain(V)}
                     || {K, V} <- briskd_state_send:source_tags(Prefix),
                        not lists:keymember(K, 1, Tags)
                    ],
            Seq = next_seq(Folded, Dev),
            Entry = #e2ee_queue{
                key = {Folded, Dev, Seq},
                prefix = Prefix,
                command = Command,
                target = briskd_wire:retain(Target),
                text = retain_body(Body),
                tags = StoredTags,
                expires = Now + Ttl
            },
            ok = mnesia:dirty_write(Entry),
            broadcast(queue_line(Account, Entry)),
            briskd_state_history:note_direct(
                {SenderAccount, Client#client.nick},
                {Account, Target},
                Target,
                briskd_state_history:entry(
                    Command,
                    Prefix,
                    Body,
                    case lists:keyfind(<<"msgid">>, 1, Tags) of
                        {_, Id} -> Id;
                        false -> briskd_state_send:msgid()
                    end,
                    erlang:system_time(millisecond),
                    briskd_cap:client_tags(Tags),
                    SenderAccount
                )
            ),
            briskd_e2ee:reply(Pid, briskd_e2ee:server(), [
                <<"QUEUED">>, Target, integer_to_binary(Dev), integer_to_binary(Seq)
            ])
    end.

retain_body({multiline, Lines}) ->
    {multiline, [{Concat, briskd_wire:retain(Text)} || {Concat, Text} <- Lines]};
retain_body(Body) ->
    briskd_wire:retain(Body).

%% Unique, increasing per device: nanoseconds, bumped past the newest entry.
next_seq(Folded, Dev) ->
    Now = erlang:system_time(nanosecond),
    case lists:reverse(briskd_e2ee:queued(Folded, Dev)) of
        [#e2ee_queue{key = {_, _, Last}} | _] when Last >= Now -> Last + 1;
        _ -> Now
    end.

%%% Server links

-doc """
Lines for a new peer's burst: every device bundle with its unused one-time
prekeys, every queued envelope, and the device bound by each local
connection.
""".
-spec burst_lines() -> [iodata()].
burst_lines() ->
    Devices = mnesia:dirty_select(
        e2ee_device, [{briskd_e2ee:pattern(e2ee_device, []), [], ['$_']}]
    ),
    DeviceLines = lists:append([
        [device_line(D) | prekeys_lines(Account, Dev, Prekeys)]
     || #e2ee_device{key = {_, Dev}, account = Account, prekeys = Prekeys} = D <- Devices
    ]),
    Accounts = #{Key => Account || #e2ee_device{key = {Key, _}, account = Account} <- Devices},
    QueueLines = [
        queue_line(maps:get(Folded, Accounts, Folded), Entry)
     || #e2ee_queue{key = {Folded, _, _}} = Entry <- mnesia:dirty_select(e2ee_queue, [
            {briskd_e2ee:pattern(e2ee_queue, []), [], ['$_']}
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
                    briskd_wire:line(
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

-doc "Apply one `E2EE` line from `Peer` and relay it to the other peers.".
-spec receive_link(binary(), binary(), [binary()], [{binary(), undefined | binary()}]) ->
    ok | {error, term()}.
receive_link(Peer, Prefix, [Sub | Params], Tags) ->
    try link_command(briskd_wire:upper(Sub), Peer, Prefix, Params, Tags) of
        {ok, Line} ->
            briskd_state_link:relay_except(Peer, Line),
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
    true = briskd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = briskd_e2ee:account_name(AccountText),
    {ok, Dev} = briskd_e2ee:device_id(DevText),
    {ok, Updated} = briskd_e2ee:non_neg(UpdatedText),
    {ok, IdentityKey} = briskd_e2ee:key(Identity),
    {ok, {SpkId, SpkKey}} = briskd_e2ee:id_key(Spk),
    {ok, Signature} = briskd_e2ee:key(Sig),
    Key = {briskd_wire:fold(Account), Dev},
    Device0 = #e2ee_device{
        key = Key,
        account = briskd_wire:retain(Account),
        identity = IdentityKey,
        signed_prekey_id = SpkId,
        signed_prekey = SpkKey,
        signature = Signature,
        updated = Updated
    },
    store(fun() ->
        #{max_devices := MaxDevices} = briskd_e2ee:config(),
        case mnesia:dirty_read(e2ee_device, Key) of
            [#e2ee_device{updated = Mine}] when Mine > Updated ->
                ok;
            [#e2ee_device{prekeys = Prekeys, used = Used}] ->
                ok = mnesia:dirty_write(Device0#e2ee_device{prekeys = Prekeys, used = Used});
            [] ->
                case length(briskd_e2ee:account_devices(Account)) < MaxDevices of
                    true -> ok = mnesia:dirty_write(Device0);
                    false -> ok
                end
        end
    end),
    {ok, device_line(Device0)};
link_command(<<"PREKEYS">>, Peer, Prefix, [AccountText, DevText | KeyTexts], _) ->
    true = briskd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = briskd_e2ee:account_name(AccountText),
    {ok, Dev} = briskd_e2ee:device_id(DevText),
    {ok, New} = briskd_e2ee:id_keys(KeyTexts),
    true = New =/= [] andalso length(New) =< ?PREKEYS_PER_LINE * 2,
    store(fun() ->
        case mnesia:dirty_read(e2ee_device, {briskd_wire:fold(Account), Dev}) of
            [#e2ee_device{prekeys = Old, used = Used} = Device] ->
                #{max_prekeys := Max} = briskd_e2ee:config(),
                Merged = lists:sublist(briskd_e2ee:merge_prekeys(Old, New, Used), Max),
                ok = mnesia:dirty_write(Device#e2ee_device{prekeys = Merged});
            [] ->
                ok
        end
    end),
    {ok, prekeys_line(Account, Dev, New)};
link_command(<<"USE">>, Peer, Prefix, [AccountText, DevText, IdText], _) ->
    true = briskd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = briskd_e2ee:account_name(AccountText),
    {ok, Dev} = briskd_e2ee:device_id(DevText),
    {ok, Id} = briskd_e2ee:non_neg(IdText),
    store(fun() ->
        case mnesia:dirty_read(e2ee_device, {briskd_wire:fold(Account), Dev}) of
            [#e2ee_device{} = Device] -> briskd_e2ee:consume(Device, Id);
            [] -> ok
        end
    end),
    {ok, use_line(Account, Dev, Id)};
link_command(<<"DELETE">>, Peer, Prefix, [AccountText, DevText], _) ->
    true = briskd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = briskd_e2ee:account_name(AccountText),
    {ok, Dev} = briskd_e2ee:device_id(DevText),
    store(fun() -> briskd_e2ee:delete_device(briskd_wire:fold(Account), Dev) end),
    {ok, delete_line(Account, Dev)};
link_command(
    <<"QUEUE">>,
    Peer,
    Prefix,
    [AccountText, DevText, SeqText, ExpiresText, Command, Target, Sender],
    Tags
) ->
    true = briskd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = briskd_e2ee:account_name(AccountText),
    {ok, Dev} = briskd_e2ee:device_id(DevText),
    {ok, Seq} = briskd_e2ee:seq(SeqText),
    {ok, Expires} = briskd_e2ee:non_neg(ExpiresText),
    true = lists:member(Command, [<<"PRIVMSG">>, <<"NOTICE">>, <<"TAGMSG">>]),
    true = byte_size(Target) =< 64 andalso byte_size(Sender) =< 255,
    {_, BodyText} = lists:keyfind(briskd_e2ee:tag(body), 1, Tags),
    {_, TagsText} = lists:keyfind(briskd_e2ee:tag(tags), 1, Tags),
    Folded = briskd_wire:fold(Account),
    Entry = #e2ee_queue{
        key = {Folded, Dev, Seq},
        prefix = briskd_wire:retain(Sender),
        command = Command,
        target = briskd_wire:retain(Target),
        text = decode_body(BodyText),
        tags = decode_tags(TagsText),
        expires = Expires
    },
    store(fun() ->
        #{queue_limit := Limit} = briskd_e2ee:config(),
        Now = erlang:system_time(second),
        Fresh = Expires > Now,
        LiveCount = length([
            E
         || #e2ee_queue{key = K, expires = Exp} = E <- briskd_e2ee:queued(Folded, Dev),
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
    true = briskd_state_link:trusted_server(Peer, Prefix),
    {ok, Account} = briskd_e2ee:account_name(AccountText),
    {ok, Dev} = briskd_e2ee:device_id(DevText),
    Seqs = [
        Seq
     || Text <- binary:split(SeqsText, <<",">>, [global, trim_all]),
        {ok, Seq} <- [briskd_e2ee:seq(Text)]
    ],
    true = Seqs =/= [],
    Folded = briskd_wire:fold(Account),
    store(fun() ->
        lists:foreach(fun(Seq) -> mnesia:dirty_delete(e2ee_queue, {Folded, Dev, Seq}) end, Seqs)
    end),
    {ok, ack_line(Account, Dev, Seqs)};
link_command(<<"BIND">>, Peer, Prefix, [DevText], _) ->
    {ok, Dev} = briskd_e2ee:device_id(DevText),
    %% The source must be a user reached through this link, logged in.
    %% The device row must already exist (a prior DEVICE line). A binding
    %% held by a local session is not replaced.
    case briskd_state_link:remote_source(Peer, Prefix) of
        {ok, #remote_client{key = NickKey, account = Account}} when is_binary(Account) ->
            Folded = briskd_wire:fold(Account),
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
                                briskd_wire:line(
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
    case briskd_e2ee:enabled() of
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

-doc "Encode an `E2EE DEVICE` server-link replication line.".
-spec device_line(#e2ee_device{}) -> iodata().
device_line(#e2ee_device{key = {_, Dev}, account = Account} = D) ->
    briskd_wire:line(
        briskd_e2ee:server(),
        <<"E2EE">>,
        [
            <<"DEVICE">>,
            Account,
            integer_to_binary(Dev),
            integer_to_binary(D#e2ee_device.updated),
            briskd_e2ee:b64(D#e2ee_device.identity),
            <<
                (integer_to_binary(D#e2ee_device.signed_prekey_id))/binary,
                ":",
                (briskd_e2ee:b64(D#e2ee_device.signed_prekey))/binary
            >>,
            briskd_e2ee:b64(D#e2ee_device.signature)
        ],
        none
    ).

-doc "Encode chunked `E2EE PREKEYS` replication lines.".
-spec prekeys_lines(binary(), pos_integer(), [{non_neg_integer(), binary()}]) -> [iodata()].
prekeys_lines(Account, Dev, Prekeys) ->
    [prekeys_line(Account, Dev, Chunk) || Chunk <- chunks(Prekeys, ?PREKEYS_PER_LINE)].

prekeys_line(Account, Dev, Prekeys) ->
    briskd_wire:line(
        briskd_e2ee:server(),
        <<"E2EE">>,
        [<<"PREKEYS">>, Account, integer_to_binary(Dev)] ++
            [
                <<(integer_to_binary(Id))/binary, ":", (briskd_e2ee:b64(Key))/binary>>
             || {Id, Key} <- Prekeys
            ],
        none
    ).

-doc "Encode an `E2EE USE` replication line.".
-spec use_line(binary(), pos_integer(), non_neg_integer()) -> iodata().
use_line(Account, Dev, Id) ->
    briskd_wire:line(
        briskd_e2ee:server(),
        <<"E2EE">>,
        [<<"USE">>, Account, integer_to_binary(Dev), integer_to_binary(Id)],
        none
    ).

-doc "Encode an `E2EE DELETE` replication line.".
-spec delete_line(binary(), pos_integer()) -> iodata().
delete_line(Account, Dev) ->
    briskd_wire:line(
        briskd_e2ee:server(), <<"E2EE">>, [<<"DELETE">>, Account, integer_to_binary(Dev)], none
    ).

-doc "Encode chunked `E2EE ACK` replication lines.".
-spec ack_lines(binary(), pos_integer(), [non_neg_integer()]) -> [iodata()].
ack_lines(Account, Dev, Seqs) ->
    [ack_line(Account, Dev, Chunk) || Chunk <- chunks(Seqs, 15)].

ack_line(Account, Dev, Seqs) ->
    briskd_wire:line(
        briskd_e2ee:server(),
        <<"E2EE">>,
        [
            <<"ACK">>,
            Account,
            integer_to_binary(Dev),
            binary:join([integer_to_binary(S) || S <- Seqs], <<",">>)
        ],
        none
    ).

-doc "Encode an `E2EE BIND` replication line for a local client.".
-spec bind_line(#client{}, pos_integer()) -> iodata().
bind_line(Client, Dev) ->
    briskd_wire:line(
        briskd_state_send:prefix(Client), <<"E2EE">>, [<<"BIND">>, integer_to_binary(Dev)], none
    ).

%% The envelope body and its delivery tags travel in server tags (base64
%% JSON), so the 512-octet line limit does not apply to them. An envelope
%% too large for the 8191-byte tag section is not replicated (`[]`).
queue_line(Account, #e2ee_queue{key = {_, Dev, Seq}} = Entry) ->
    briskd_wire:message(
        [
            {briskd_e2ee:tag(body), encode_body(Entry#e2ee_queue.text)},
            {briskd_e2ee:tag(tags), encode_tags(Entry#e2ee_queue.tags)}
        ],
        briskd_e2ee:server(),
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

-doc "Broadcast a non-empty replicated E2EE line to connected peers.".
-spec broadcast(iodata()) -> ok.
broadcast([]) ->
    ok;
broadcast(Line) ->
    briskd_state_link:server_broadcast(Line).
