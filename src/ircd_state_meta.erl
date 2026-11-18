-module(ircd_state_meta).
-export([
    disconnect/1,
    drop_channel/1,
    forget_remote/1,
    remote_channel_change/4,
    remote_user_change/4,
    rename_remote/2,
    metadata/3,
    on_join/3,
    on_registered/2,
    rename_channel/2
]).
-include("ircd_state.hrl").

%% @doc draft/metadata-2. User keys live in `ircd_conn` (`metadata`) and are
%% dropped on disconnect. Channel keys live in the `ircd_chan_meta` ETS table
%% and are dropped with the channel. Subscriptions are per connection
%% (`metasubs`). Metadata is local to this server; it is not sent over links.
%% Every key is public (visibility `*`). Limits are advertised in the
%% capability value: max-subs, max-keys, and max-value-bytes.

-define(MAX_KEY_BYTES, 64).

%% @doc `METADATA <target> <subcommand> [params]`.
-spec metadata([binary()], #client{}, binary()) -> ok.
metadata([Target, Sub | Params], #client{pid = Pid} = Client, Server) ->
    case {ircd_cap:enabled(Pid, <<"draft/metadata-2">>), string:uppercase(Sub)} of
        {false, _} ->
            ircd_state_send:numeric(
                Client, Server, <<"421">>, [<<"METADATA">>], <<"Unknown command">>
            );
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

%% @doc After registration, send the client's own metadata in a metadata batch.
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

%% @doc After JOIN: the joiner receives the channel's and members' subscribed
%% values; members receive the joiner's subscribed values.
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

%% @doc Forget a disconnecting client's metadata.
-spec disconnect(pid()) -> ok.
disconnect(_Pid) ->
    ok.

%% @doc Forget a channel's metadata when the channel row is deleted.
-spec drop_channel(binary()) -> ok.
drop_channel(Key) ->
    case ets:whereis(ircd_chan_meta) of
        undefined -> ok;
        _ -> ets:delete(ircd_chan_meta, Key)
    end,
    ok.

%% @doc Move a channel's metadata to its new key after RENAME.
-spec rename_channel(binary(), binary()) -> ok.
rename_channel(OldKey, NewKey) ->
    case ets:lookup(ircd_chan_meta, OldKey) of
        [{_, Map}] ->
            ets:delete(ircd_chan_meta, OldKey),
            ets:insert(ircd_chan_meta, {NewKey, Map});
        [] ->
            ok
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
    ok;
write({channel, Key, _}, Map) ->
    ets:insert(ircd_chan_meta, {Key, Map}),
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
                    [Owner] ->
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

%% @doc Metadata of a remote user changed on its home server.
-spec remote_user_change(binary(), binary(), none | binary(), binary()) -> ok | {error, term()}.
remote_user_change(Nick, Key, Value, Prefix) ->
    NickKey = ircd_wire:fold(Nick),
    case {valid_key(Key), mnesia:dirty_read(remote_client, NickKey)} of
        {true, [#remote_client{nick = Actual}]} ->
            Current = read({remote, NickKey, Actual}),
            Updated =
                case Value of
                    none -> maps:remove(Key, Current);
                    _ -> Current#{ircd_wire:retain(Key) => Value}
                end,
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
        {false, _} ->
            {error, invalid_metadata_key};
        {_, []} ->
            {error, unknown_metadata_target}
    end.

%% @doc Metadata of a shared channel changed on another server.
-spec remote_channel_change(binary(), binary(), none | binary(), binary()) -> ok | {error, term()}.
remote_channel_change(Name, Key, Value, Prefix) ->
    case valid_key(Key) of
        false ->
            {error, invalid_metadata_key};
        true ->
            ChannelKey = ircd_wire:fold(Name),
            Current = read({channel, ChannelKey, Name}),
            Updated =
                case Value of
                    none -> maps:remove(Key, Current);
                    _ -> Current#{ircd_wire:retain(Key) => Value}
                end,
            write({channel, ChannelKey, Name}, Updated),
            Audience =
                case mnesia:dirty_read(channel, ChannelKey) of
                    [#channel{members = Members}] -> maps:keys(Members);
                    [] -> []
                end,
            notify_subscribers(Audience, Prefix, Name, Key, Value),
            ok
    end.

notify_subscribers(Audience, Prefix, Target, Key, Value) ->
    Recipients = [
        P
     || P <- Audience,
        ircd_cap:enabled(P, <<"draft/metadata-2">>),
        lists:member(Key, ircd_conn:get(P, metasubs, []))
    ],
    ircd_state_send:broadcast(Recipients, Prefix, <<"METADATA">>, [Target, Key, <<"*">>], Value).

%% @doc Forget a remote user's metadata when the user leaves the network.
-spec forget_remote(binary()) -> ok.
forget_remote(NickKey) ->
    case ets:whereis(ircd_remote_meta) of
        undefined -> ok;
        _ -> ets:delete(ircd_remote_meta, NickKey)
    end,
    ok.

%% @doc Move a remote user's metadata after a nickname change.
-spec rename_remote(binary(), binary()) -> ok.
rename_remote(OldKey, NewKey) ->
    case ets:lookup(ircd_remote_meta, OldKey) of
        [{_, Map}] ->
            ets:delete(ircd_remote_meta, OldKey),
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
    maps:get(name, persistent_term:get({ircd_state, config})).
