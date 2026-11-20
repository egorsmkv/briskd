-module(ircd_state_meta).
-export([
    disconnect/1,
    drop_channel/1,
    forget_remote/1,
    remote_channel_change/4,
    remote_user_change/4,
    rename_remote/2,
    restore_channels/0,
    metadata/3,
    on_join/3,
    on_registered/2,
    rename_channel/2
]).
-include("ircd_state.hrl").

-moduledoc """
User and channel metadata:
[draft/metadata-2](https://ircv3.net/specs/extensions/metadata), with a
fallback to the deprecated metadata 3.2 numerics for clients that did not
negotiate the capability.

Runs inside `m:ircd_state`. Local user keys live in `m:ircd_conn`
(`metadata`) and are dropped on disconnect. Channel keys live in the
`ircd_chan_meta` ETS table and are persisted in the Mnesia `channel_meta`
table so they survive restarts for channels kept by the active `retention`
policy (safe `!` channels under `transient` retention, and all channels under
`channels` retention) and are dropped with the channel. Keys of remote users
live in `ircd_remote_meta`. Subscriptions are per connection (`metasubs`).
Changes are sent to peers through `m:ircd_state_sync`, and changes from peers
arrive through `remote_user_change/4` and `remote_channel_change/4`.

Every key is public (visibility `*`). A key is 1 to 64 bytes of
`[a-z0-9_./-]`; a value must be valid UTF-8. Users may change only their own
keys and channel operators the channel's keys. Limits come from
`ircd_cap:metadata_limits/0` and are advertised in the capability value:
`max-subs`, `max-keys`, and `max-value-bytes`.
""".

-define(MAX_KEY_BYTES, 64).

-doc """
`METADATA <target> <subcommand> [params]`.

With draft/metadata-2 the subcommands are `GET`, `LIST`, `SET`, `CLEAR`,
`SYNC`, `SUB`, `UNSUB`, and `SUBS`; `*` as the target is the client itself.
Values come back as 761 / 766 in a `metadata` batch, subscriptions as
770 / 771 / 772. Errors are `FAIL METADATA` with `INVALID_TARGET`,
`SUBCOMMAND_INVALID`, `KEY_INVALID`, `KEY_NO_PERMISSION`, `KEY_NOT_SET`,
`VALUE_INVALID`, `LIMIT_REACHED`, or `TOO_MANY_SUBS`. A `SET` or `CLEAR` is
announced to subscribed clients that share the target and sent to peers.

Without the capability, `GET`, `LIST`, `SET`, and `CLEAR` use the metadata
3.2 numerics (761, 762, 764, 765, 766, 767, 769). Too few parameters gets 461.
""".
-spec metadata([binary()], #client{}, binary()) -> ok.
metadata([Target, Sub | Params], #client{pid = Pid} = Client, Server) ->
    case {ircd_cap:enabled(Pid, <<"draft/metadata-2">>), ircd_wire:upper(Sub)} of
        {false, Upper} ->
            legacy(Upper, Target, Params, Client, Server);
        {true, <<"SUB">>} ->
            sub(Params, Client, Server);
        {true, <<"UNSUB">>} ->
            unsub(Params, Client, Server);
        {true, <<"SUBS">>} ->
            subs(Client, Server);
        {true, Upper} when
            Upper =:= <<"GET">>;
            Upper =:= <<"LIST">>;
            Upper =:= <<"SET">>;
            Upper =:= <<"CLEAR">>;
            Upper =:= <<"SYNC">>
        ->
            case resolve(Target, Client) of
                {ok, Resolved} -> target_command(Upper, Resolved, Params, Client, Server);
                error -> fail(Pid, <<"INVALID_TARGET">>, [Target], <<"invalid metadata target">>)
            end;
        {true, _} ->
            fail(Pid, <<"SUBCOMMAND_INVALID">>, [Sub], <<"invalid subcommand">>)
    end;
metadata(_, Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"METADATA">>], <<"Not enough parameters">>
    ).

%% Deprecated IRCv3 metadata 3.2, for clients that did not negotiate
%% draft/metadata-2: the same stored keys, no batches, replies with the
%% target first (761 RPL_KEYVALUE, 766 ERR_NOMATCHINGKEY, 762 RPL_METADATAEND,
%% 765 ERR_TARGETINVALID, 767 ERR_KEYINVALID, 769 ERR_KEYNOPERMISSION).
legacy(Sub, Target, Params, #client{pid = Pid} = Client, Server) ->
    case resolve(Target, Client) of
        error ->
            ircd_state_send:send(Pid, Server, <<"765">>, [Target], <<"invalid metadata target">>);
        {ok, Resolved} ->
            legacy_command(Sub, Resolved, Params, Client, Server)
    end.

legacy_command(<<"GET">>, Resolved, Keys, #client{pid = Pid}, Server) ->
    Name = target_name(Resolved),
    Values = read(Resolved),
    lists:foreach(
        fun(Key) ->
            case {valid_key(Key), maps:find(Key, Values)} of
                {false, _} ->
                    ircd_state_send:send(Pid, Server, <<"767">>, [Key], <<"invalid metadata key">>);
                {true, {ok, Value}} ->
                    ircd_state_send:send(Pid, Server, <<"761">>, [Name, Key, <<"*">>], Value);
                {true, error} ->
                    ircd_state_send:send(Pid, Server, <<"766">>, [Name, Key], <<"no matching key">>)
            end
        end,
        Keys
    );
legacy_command(<<"LIST">>, Resolved, _, #client{pid = Pid}, Server) ->
    Name = target_name(Resolved),
    maps:foreach(
        fun(Key, Value) ->
            ircd_state_send:send(Pid, Server, <<"761">>, [Name, Key, <<"*">>], Value)
        end,
        maps:iterator(read(Resolved), ordered)
    ),
    ircd_state_send:send(Pid, Server, <<"762">>, [], <<"end of metadata">>);
legacy_command(<<"SET">>, Resolved, [Key | Value], #client{pid = Pid} = Client, Server) ->
    {_, MaxKeys, MaxBytes} = ircd_cap:metadata_limits(),
    Name = target_name(Resolved),
    Current = read(Resolved),
    case {valid_key(Key), writable(Resolved, Client), Value} of
        {false, _, _} ->
            ircd_state_send:send(Pid, Server, <<"767">>, [Key], <<"invalid metadata key">>);
        {_, false, _} ->
            ircd_state_send:send(Pid, Server, <<"769">>, [Name, Key], <<"permission denied">>);
        {true, true, []} ->
            write(Resolved, maps:remove(Key, Current)),
            ircd_state_send:send(Pid, Server, <<"762">>, [], <<"end of metadata">>);
        {true, true, [Text | _]} ->
            Acceptable =
                byte_size(Text) =< MaxBytes andalso ircd_state_v3:valid_utf8(Text) andalso
                    (maps:is_key(Key, Current) orelse map_size(Current) < MaxKeys),
            case Acceptable of
                true ->
                    Stored = ircd_wire:retain(Text),
                    write(Resolved, Current#{ircd_wire:retain(Key) => Stored}),
                    ircd_state_send:send(Pid, Server, <<"761">>, [Name, Key, <<"*">>], Stored),
                    ircd_state_send:send(Pid, Server, <<"762">>, [], <<"end of metadata">>),
                    announce(Resolved, Key, Stored, Client);
                false ->
                    ircd_state_send:send(
                        Pid, Server, <<"764">>, [Name], <<"metadata limit reached">>
                    )
            end
    end;
legacy_command(<<"CLEAR">>, Resolved, _, #client{pid = Pid} = Client, Server) ->
    case writable(Resolved, Client) of
        true ->
            write(Resolved, #{}),
            ircd_state_send:send(Pid, Server, <<"762">>, [], <<"end of metadata">>);
        false ->
            ircd_state_send:send(
                Pid, Server, <<"769">>, [target_name(Resolved), <<"*">>], <<"permission denied">>
            )
    end;
legacy_command(_Sub, _Resolved, _Params, Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"METADATA">>], <<"Not enough parameters">>
    ).

%% A resolved target is `{user, Pid, Nick}` or `{channel, Key, Name}`.
resolve(<<"*">>, #client{pid = Pid, nick = Nick}) ->
    {ok, {user, Pid, Nick}};
resolve(Target, #client{} = Client) ->
    case ircd_wire:channel(Target) of
        true ->
            case mnesia:dirty_read(channel, ircd_wire:fold(Target)) of
                [#channel{key = Key, name = Name}] -> {ok, {channel, Key, Name}};
                [] -> error
            end;
        false ->
            case ircd_state_client:ready(Client) andalso ircd_state_client:find_nick(Target) of
                #client{pid = Other, nick = Nick} ->
                    {ok, {user, Other, Nick}};
                undefined ->
                    case mnesia:dirty_read(remote_client, ircd_wire:fold(Target)) of
                        [#remote_client{key = Key, nick = Nick}] -> {ok, {remote, Key, Nick}};
                        [] -> error
                    end;
                _ ->
                    error
            end
    end.

target_name({user, _, Nick}) -> Nick;
target_name({remote, _, Nick}) -> Nick;
target_name({channel, _, Name}) -> Name.

target_command(<<"GET">>, Target, Keys, #client{pid = Pid} = Client, Server) ->
    case readable(Target, Client) of
        false ->
            fail(
                Pid,
                <<"KEY_NO_PERMISSION">>,
                [target_name(Target), <<"*">>],
                <<"permission denied">>
            );
        true ->
            Values = read(Target),
            in_batch(Pid, target_name(Target), fun() ->
                lists:foreach(
                    fun(Key) ->
                        case {valid_key(Key), maps:find(Key, Values)} of
                            {false, _} -> fail(Pid, <<"KEY_INVALID">>, [Key], <<"invalid key">>);
                            {true, {ok, Value}} -> key_value(Client, Server, Target, Key, Value);
                            {true, error} -> key_not_set(Client, Server, Target, Key)
                        end
                    end,
                    Keys
                )
            end)
    end;
target_command(<<"LIST">>, Target, _, #client{pid = Pid} = Client, Server) ->
    case readable(Target, Client) of
        false ->
            fail(
                Pid,
                <<"KEY_NO_PERMISSION">>,
                [target_name(Target), <<"*">>],
                <<"permission denied">>
            );
        true ->
            in_batch(Pid, target_name(Target), fun() ->
                maps:foreach(
                    fun(Key, Value) -> key_value(Client, Server, Target, Key, Value) end,
                    maps:iterator(read(Target), ordered)
                )
            end)
    end;
target_command(<<"SET">>, Target, [Key | Value], #client{pid = Pid} = Client, Server) ->
    {_MaxSubs, MaxKeys, MaxBytes} = ircd_cap:metadata_limits(),
    Name = target_name(Target),
    Current = read(Target),
    case {valid_key(Key), writable(Target, Client), Value} of
        {false, _, _} ->
            fail(Pid, <<"KEY_INVALID">>, [Key], <<"invalid key">>);
        {_, false, _} ->
            fail(Pid, <<"KEY_NO_PERMISSION">>, [Name, Key], <<"permission denied">>);
        {true, true, []} ->
            case maps:is_key(Key, Current) of
                false ->
                    fail(Pid, <<"KEY_NOT_SET">>, [Name, Key], <<"key not set">>);
                true ->
                    write(Target, maps:remove(Key, Current)),
                    key_not_set(Client, Server, Target, Key),
                    announce(Target, Key, none, Client)
            end;
        {true, true, [Text | _]} ->
            case
                {
                    byte_size(Text) =< MaxBytes andalso ircd_state_v3:valid_utf8(Text),
                    maps:is_key(Key, Current) orelse map_size(Current) < MaxKeys
                }
            of
                {false, _} ->
                    fail(Pid, <<"VALUE_INVALID">>, [], <<"value is too long or not UTF8">>);
                {_, false} ->
                    fail(Pid, <<"LIMIT_REACHED">>, [Name], <<"metadata limit reached">>);
                {true, true} ->
                    Stored = ircd_wire:retain(Text),
                    write(Target, Current#{ircd_wire:retain(Key) => Stored}),
                    key_value(Client, Server, Target, Key, Stored),
                    announce(Target, Key, Stored, Client)
            end
    end;
target_command(<<"SET">>, _Target, [], Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"METADATA">>], <<"Not enough parameters">>
    );
target_command(<<"CLEAR">>, Target, _, #client{pid = Pid} = Client, Server) ->
    case writable(Target, Client) of
        false ->
            fail(
                Pid,
                <<"KEY_NO_PERMISSION">>,
                [target_name(Target), <<"*">>],
                <<"permission denied">>
            );
        true ->
            Current = read(Target),
            write(Target, #{}),
            in_batch(Pid, target_name(Target), fun() ->
                lists:foreach(
                    fun(Key) ->
                        key_not_set(Client, Server, Target, Key),
                        announce(Target, Key, none, Client)
                    end,
                    lists:sort(maps:keys(Current))
                )
            end)
    end;
target_command(<<"SYNC">>, Target, _, #client{pid = Pid} = Client, Server) ->
    case readable(Target, Client) of
        false ->
            fail(
                Pid,
                <<"KEY_NO_PERMISSION">>,
                [target_name(Target), <<"*">>],
                <<"permission denied">>
            );
        true ->
            in_batch(Pid, target_name(Target), fun() -> sync(Pid, Target, Server) end)
    end.

%% Send subscribed values of a target (and, for a channel, of its members).
sync(Pid, {channel, Key, Name} = Target, Server) ->
    send_subscribed(Pid, Target, Server),
    case mnesia:dirty_read(channel, Key) of
        [#channel{members = Members, flags = Flags}] ->
            case maps:is_key($a, Flags) of
                true ->
                    ok;
                false ->
                    lists:foreach(
                        fun(Member) ->
                            case mnesia:dirty_read(client, Member) of
                                [#client{nick = Nick}] ->
                                    send_subscribed(Pid, {user, Member, Nick}, Server);
                                [] ->
                                    ok
                            end
                        end,
                        maps:keys(Members)
                    )
            end;
        [] ->
            ok
    end,
    _ = Name,
    ok;
sync(Pid, Target, Server) ->
    send_subscribed(Pid, Target, Server).

send_subscribed(Pid, Target, Server) ->
    Subs = ircd_conn:get(Pid, metasubs, []),
    maps:foreach(
        fun(Key, Value) ->
            case lists:member(Key, Subs) of
                true ->
                    ircd_state_send:send(
                        Pid, Server, <<"METADATA">>, [target_name(Target), Key, <<"*">>], Value
                    );
                false ->
                    ok
            end
        end,
        maps:iterator(read(Target), ordered)
    ).

sub(Keys, #client{pid = Pid} = Client, Server) ->
    {MaxSubs, _, _} = ircd_cap:metadata_limits(),
    {Added, Stopped} = sub_keys(Keys, Pid, MaxSubs, []),
    case Added of
        [] -> ok;
        _ -> ircd_state_send:numeric(Client, Server, <<"770">>, lists:reverse(Added), none)
    end,
    case Stopped of
        undefined -> ok;
        Key -> fail(Pid, <<"TOO_MANY_SUBS">>, [Key], <<"too many subscriptions">>)
    end.

sub_keys([], _Pid, _Max, Added) ->
    {Added, undefined};
sub_keys([Key | Rest], Pid, Max, Added) ->
    Subs = ircd_conn:get(Pid, metasubs, []),
    case {valid_key(Key), lists:member(Key, Subs)} of
        {false, _} ->
            fail(Pid, <<"KEY_INVALID">>, [Key], <<"invalid key">>),
            sub_keys(Rest, Pid, Max, Added);
        {true, true} ->
            sub_keys(Rest, Pid, Max, [Key | Added]);
        {true, false} when length(Subs) >= Max ->
            {Added, Key};
        {true, false} ->
            ircd_conn:put(Pid, metasubs, lists:usort([ircd_wire:retain(Key) | Subs])),
            sub_keys(Rest, Pid, Max, [Key | Added])
    end.

unsub(Keys, #client{pid = Pid} = Client, Server) ->
    Valid = lists:filter(
        fun(Key) ->
            case valid_key(Key) of
                true ->
                    true;
                false ->
                    fail(Pid, <<"KEY_INVALID">>, [Key], <<"invalid key">>),
                    false
            end
        end,
        Keys
    ),
    ircd_conn:put(Pid, metasubs, ircd_conn:get(Pid, metasubs, []) -- Valid),
    case Valid of
        [] -> ok;
        _ -> ircd_state_send:numeric(Client, Server, <<"771">>, Valid, none)
    end.

subs(#client{pid = Pid} = Client, Server) ->
    ircd_state_send:with_batch(Pid, <<"metadata-subs">>, [], [], fun() ->
        %% At most 13 keys per 772, so the line keeps within 15 parameters
        %% and 512 bytes (keys are at most 64 bytes, but usually short).
        lists:foreach(
            fun(Chunk) -> ircd_state_send:numeric(Client, Server, <<"772">>, Chunk, none) end,
            key_chunks(ircd_conn:get(Pid, metasubs, []))
        )
    end).

key_chunks([]) ->
    [];
key_chunks(Keys) ->
    key_chunks(Keys, [], 0, []).

key_chunks([], [], _, Acc) ->
    lists:reverse(Acc);
key_chunks([], Current, _, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
key_chunks([Key | Rest], Current, Size, Acc) when
    Current =/= [], (length(Current) >= 6 orelse Size + byte_size(Key) + 1 > 380)
->
    key_chunks([Key | Rest], [], 0, [lists:reverse(Current) | Acc]);
key_chunks([Key | Rest], Current, Size, Acc) ->
    key_chunks(Rest, [Key | Current], Size + byte_size(Key) + 1, Acc).

-doc """
After registration, send a draft/metadata-2 client its own metadata (set
before registration) as `METADATA` lines in a `metadata` batch.
""".
-spec on_registered(#client{}, binary()) -> ok.
on_registered(#client{pid = Pid, nick = Nick}, Server) ->
    case ircd_cap:enabled(Pid, <<"draft/metadata-2">>) of
        true ->
            %% The registration burst is METADATA messages, not 761 numerics.
            in_batch(Pid, Nick, fun() ->
                maps:foreach(
                    fun(Key, Value) ->
                        ircd_state_send:send(
                            Pid, Server, <<"METADATA">>, [Nick, Key, <<"*">>], Value
                        )
                    end,
                    maps:iterator(read({user, Pid, Nick}), ordered)
                )
            end);
        false ->
            ok
    end.

-doc """
After `JOIN` of the channel with folded name `Key`: a draft/metadata-2
joiner receives the channel's and members' subscribed values; subscribed
members receive the joiner's values. Member values are not exchanged on an
anonymous (`+a`) channel.
""".
-spec on_join(binary(), #client{}, binary()) -> ok.
on_join(Key, #client{pid = Pid, nick = Nick}, Server) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Name, members = Members, flags = Flags}] ->
            case ircd_cap:enabled(Pid, <<"draft/metadata-2">>) of
                true ->
                    in_batch(Pid, Name, fun() -> sync(Pid, {channel, Key, Name}, Server) end);
                false ->
                    ok
            end,
            Mine = read({user, Pid, Nick}),
            case map_size(Mine) =:= 0 orelse maps:is_key($a, Flags) of
                true ->
                    ok;
                false ->
                    lists:foreach(
                        fun(Member) ->
                            case
                                Member =/= Pid andalso
                                    ircd_cap:enabled(Member, <<"draft/metadata-2">>)
                            of
                                true -> send_subscribed(Member, {user, Pid, Nick}, Server);
                                false -> ok
                            end
                        end,
                        maps:keys(Members)
                    )
            end;
        [] ->
            ok
    end.

-doc """
Hook for a disconnecting client. Currently a no-op: the client's keys and
subscriptions are removed with its `m:ircd_conn` row.
""".
-spec disconnect(pid()) -> ok.
disconnect(_Pid) ->
    ok.

-doc """
Restore `ircd_chan_meta` ETS entries from the durable `channel_meta` Mnesia
table for every channel kept by the startup retention policy, and drop
`channel_meta` rows whose channel no longer exists.
""".
-spec restore_channels() -> ok.
restore_channels() ->
    lists:foreach(
        fun(Key) ->
            case {mnesia:dirty_read(channel, Key), mnesia:dirty_read(channel_meta, Key)} of
                {[_], [#channel_meta{entries = Map}]} when is_map(Map), map_size(Map) > 0 ->
                    ets:insert(ircd_chan_meta, {Key, Map});
                _ ->
                    mnesia:dirty_delete(channel_meta, Key)
            end
        end,
        ircd_state:table_keys(channel_meta)
    ).

-doc """
Forget the metadata of the channel with folded name `Key` when the channel
row is deleted.
""".
-spec drop_channel(binary()) -> ok.
drop_channel(Key) ->
    case ets:whereis(ircd_chan_meta) of
        undefined -> ok;
        _ -> ets:delete(ircd_chan_meta, Key)
    end,
    try mnesia:dirty_delete(channel_meta, Key) of
        ok -> ok
    catch
        _:_ -> ok
    end.

-doc """
Move a channel's metadata from folded name `OldKey` to `NewKey` after
`RENAME`.
""".
-spec rename_channel(binary(), binary()) -> ok.
rename_channel(OldKey, NewKey) ->
    case ets:take(ircd_chan_meta, OldKey) of
        [{_, Map}] ->
            ets:insert(ircd_chan_meta, {NewKey, Map}),
            mnesia:dirty_delete(channel_meta, OldKey),
            mnesia:dirty_write(#channel_meta{channel = NewKey, entries = Map});
        [] ->
            mnesia:dirty_delete(channel_meta, OldKey)
    end,
    ok.

read({remote, Key, _}) ->
    case ets:lookup(ircd_remote_meta, Key) of
        [{_, Map}] -> Map;
        [] -> #{}
    end;
read({user, Pid, _}) ->
    ircd_conn:get(Pid, metadata, #{});
read({channel, Key, _}) ->
    case ets:lookup(ircd_chan_meta, Key) of
        [{_, Map}] -> Map;
        [] -> #{}
    end.

write({user, Pid, _}, Map) ->
    ircd_conn:put(Pid, metadata, Map);
write({channel, Key, _}, Map) when map_size(Map) =:= 0 ->
    ets:delete(ircd_chan_meta, Key),
    mnesia:dirty_delete(channel_meta, Key),
    ok;
write({channel, Key, _}, Map) ->
    ets:insert(ircd_chan_meta, {Key, Map}),
    mnesia:dirty_write(#channel_meta{channel = Key, entries = Map}),
    ok.

%% Users may change only their own keys; channel operators change channel keys.
writable({user, Pid, _}, #client{pid = Pid}) ->
    true;
writable({remote, _, _}, _) ->
    false;
writable({user, _, _}, _) ->
    false;
writable({channel, Key, _}, #client{pid = Pid}) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{members = Members}] -> lists:member(operator, maps:get(Pid, Members, []));
        [] -> false
    end.

%% User keys are public. Channel keys are visible to members, and to others
%% unless the channel is private or secret.
readable({remote, _, _}, _) ->
    true;
readable({user, _, _}, _) ->
    true;
readable({channel, Key, _}, #client{pid = Pid}) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{members = Members, flags = Flags}] ->
            maps:is_key(Pid, Members) orelse
                not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags));
        [] ->
            false
    end.

%% Notify subscribers that share the target (or monitor a user target).
announce(Target, Key, Value, #client{pid = Setter} = Client) ->
    Audience =
        case Target of
            {user, Pid, Nick} ->
                case mnesia:dirty_read(client, Pid) of
                    [#client{} = Owner] ->
                        lists:usort(
                            ircd_state_channel:nick_recipients(Owner) ++
                                ircd_state_monitor:watchers(Nick)
                        );
                    [] ->
                        []
                end;
            {channel, ChannelKey, _} ->
                case mnesia:dirty_read(channel, ChannelKey) of
                    [#channel{members = Members}] -> maps:keys(Members);
                    [] -> []
                end
        end,
    Recipients = [
        P
     || P <- Audience,
        P =/= Setter,
        ircd_cap:enabled(P, <<"draft/metadata-2">>),
        lists:member(Key, ircd_conn:get(P, metasubs, []))
    ],
    Prefix =
        case ircd_state_client:ready(Client) of
            true -> ircd_state_send:prefix(Client);
            false -> server()
        end,
    ircd_state_send:broadcast(
        Recipients, Prefix, <<"METADATA">>, [target_name(Target), Key, <<"*">>], Value
    ),
    case Target of
        {user, _, _} -> ircd_state_sync:user_metadata(Client, Key, Value);
        {channel, _, Name} -> ircd_state_sync:channel_metadata(Name, Key, Value)
    end.

-doc """
Apply a metadata change for the remote user `Nick` received from a peer.
`Value` `none` deletes the key. Subscribed local clients that share a
channel with the user or monitor it get `METADATA` with `Prefix` as source.

Returns `{error, invalid_metadata_key}` or `{error, unknown_metadata_target}`.
""".
-spec remote_user_change(binary(), binary(), none | binary(), binary()) -> ok | {error, term()}.
remote_user_change(Nick, Key, Value, Prefix) ->
    NickKey = ircd_wire:fold(Nick),
    case {valid_key(Key), mnesia:dirty_read(remote_client, NickKey)} of
        {true, [#remote_client{nick = Actual}]} ->
            Current = read({remote, NickKey, Actual}),
            case apply_remote_value(Key, Value, Current) of
                {ok, Updated} ->
                    case map_size(Updated) of
                        0 -> ets:delete(ircd_remote_meta, NickKey);
                        _ -> ets:insert(ircd_remote_meta, {NickKey, Updated})
                    end,
                    Audience = lists:usort(
                        ircd_state_link:remote_user_local_recipients(NickKey) ++
                            ircd_state_monitor:watchers(Actual)
                    ),
                    notify_subscribers(Audience, Prefix, Actual, Key, Value),
                    ok;
                {error, _} = Error ->
                    Error
            end;
        {false, _} ->
            {error, invalid_metadata_key};
        {_, []} ->
            {error, unknown_metadata_target}
    end.

-doc """
Apply a metadata change for channel `Name` received from a peer. `Value`
`none` deletes the key. Subscribed local members get `METADATA` with
`Prefix` as source.

Returns `{error, invalid_metadata_key}` for a malformed key, and
`{error, invalid_metadata_value}` or `{error, metadata_limit_reached}` when
the value or key count exceeds the configured metadata limits.
""".
-spec remote_channel_change(binary(), binary(), none | binary(), binary()) -> ok | {error, term()}.
remote_channel_change(Name, Key, Value, Prefix) ->
    case valid_key(Key) of
        false ->
            {error, invalid_metadata_key};
        true ->
            ChannelKey = ircd_wire:fold(Name),
            Current = read({channel, ChannelKey, Name}),
            case apply_remote_value(Key, Value, Current) of
                {ok, Updated} ->
                    write({channel, ChannelKey, Name}, Updated),
                    Audience =
                        case mnesia:dirty_read(channel, ChannelKey) of
                            [#channel{members = Members}] -> maps:keys(Members);
                            [] -> []
                        end,
                    notify_subscribers(Audience, Prefix, Name, Key, Value),
                    ok;
                {error, _} = Error ->
                    Error
            end
    end.

apply_remote_value(Key, none, Current) ->
    {ok, maps:remove(Key, Current)};
apply_remote_value(Key, Value, Current) ->
    {_MaxSubs, MaxKeys, MaxBytes} = ircd_cap:metadata_limits(),
    case
        {
            byte_size(Value) =< MaxBytes andalso ircd_state_v3:valid_utf8(Value),
            maps:is_key(Key, Current) orelse map_size(Current) < MaxKeys
        }
    of
        {false, _} -> {error, invalid_metadata_value};
        {_, false} -> {error, metadata_limit_reached};
        {true, true} -> {ok, Current#{ircd_wire:retain(Key) => ircd_wire:retain(Value)}}
    end.

notify_subscribers(Audience, Prefix, Target, Key, Value) ->
    Recipients = [
        P
     || P <- Audience,
        ircd_cap:enabled(P, <<"draft/metadata-2">>),
        lists:member(Key, ircd_conn:get(P, metasubs, []))
    ],
    ircd_state_send:broadcast(Recipients, Prefix, <<"METADATA">>, [Target, Key, <<"*">>], Value).

-doc """
Forget the metadata of the remote user with folded nick `NickKey` when the
user leaves the network.
""".
-spec forget_remote(binary()) -> ok.
forget_remote(NickKey) ->
    case ets:whereis(ircd_remote_meta) of
        undefined -> ok;
        _ -> ets:delete(ircd_remote_meta, NickKey)
    end,
    ok.

-doc """
Move a remote user's metadata from folded nick `OldKey` to `NewKey` after a
nickname change.
""".
-spec rename_remote(binary(), binary()) -> ok.
rename_remote(OldKey, NewKey) ->
    case ets:take(ircd_remote_meta, OldKey) of
        [{_, Map}] ->
            ets:insert(ircd_remote_meta, {NewKey, Map});
        [] ->
            ok
    end,
    ok.

key_value(Client, Server, Target, Key, Value) ->
    ircd_state_send:numeric(
        Client, Server, <<"761">>, [target_name(Target), Key, <<"*">>], Value
    ).

key_not_set(Client, Server, Target, Key) ->
    ircd_state_send:numeric(
        Client, Server, <<"766">>, [target_name(Target), Key], <<"key not set">>
    ).

in_batch(Pid, Name, Fun) ->
    ircd_state_send:with_batch(Pid, <<"metadata">>, [Name], [], Fun),
    ok.

valid_key(Key) ->
    byte_size(Key) > 0 andalso byte_size(Key) =< ?MAX_KEY_BYTES andalso
        re:run(Key, <<"^[a-z0-9_./-]+$">>, [{capture, none}, dollar_endonly]) =:= match.

fail(Pid, Code, Context, Text) ->
    ircd_state_send:fail(Pid, <<"METADATA">>, Code, Context, Text).

server() ->
    maps:get(name, ircd_config:current()).
