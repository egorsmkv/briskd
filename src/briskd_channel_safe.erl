-module(briskd_channel_safe).
-moduledoc """
Safe channel (`!`) short-name indexing, `+r` reop timer handling, and
empty-channel TTL/cap pruning (RFC 2811 section 3.2).

Runs inside the `m:briskd_state` process and owns updates to the
`briskd_safe_channels` and `briskd_empty_channels` ETS indexes alongside the
Mnesia `channel` table.
""".
-export([
    clear_channel_empty/1,
    drop_channel_row/1,
    index_safe_channel/1,
    index_safe_channels/0,
    note_channel_empty/1,
    prune_empty_channels/0,
    release_if_empty/2,
    reop_channels/1,
    resolve_channel/1,
    track_opless/2,
    unindex_safe_channel/1
]).
-include("briskd_state.hrl").

-doc """
Store or delete a channel whose last local member has left.

`Remaining` is the empty member map to store. Safe `!` channels and channels
kept by retention (`channels` or predefined) are marked empty and pruned if the
`max_empty_channels` cap is exceeded; other channels are dropped immediately.
""".
-spec release_if_empty(#channel{}, #{pid() => [channel_role()]}) -> ok.
release_if_empty(#channel{key = Key, name = <<$!, _/binary>>} = Channel, Remaining) ->
    note_channel_empty(Key),
    mnesia:dirty_write(track_opless(Channel, Remaining)),
    prune_empty_channels();
release_if_empty(#channel{key = Key} = Channel, Remaining) ->
    case briskd_state:retention() =:= channels orelse briskd_state:predefined_channel(Key) of
        true ->
            note_channel_empty(Key),
            mnesia:dirty_write(Channel#channel{members = Remaining}),
            prune_empty_channels();
        false ->
            drop_channel_row(Channel)
    end.

-doc """
Delete a channel row along with its safe-channel index, empty-channel index,
metadata, population count, and stored history.
""".
-spec drop_channel_row(#channel{}) -> ok.
drop_channel_row(#channel{key = Key, name = Name}) ->
    unindex_safe_channel(Name),
    clear_channel_empty(Key),
    briskd_state_meta:drop_channel(Key),
    mnesia:dirty_delete(channel, Key),
    briskd_population:on_channel_delete(Key),
    briskd_state_history:delete_channel_history(Key).

-doc """
Record the current system second as the time channel `Key` became empty in
`briskd_empty_channels`.
""".
-spec note_channel_empty(binary()) -> ok.
note_channel_empty(Key) ->
    case ets:whereis(briskd_empty_channels) of
        undefined -> ok;
        _ -> ets:insert(briskd_empty_channels, {Key, erlang:system_time(second)})
    end,
    ok.

-doc """
Remove channel `Key` from `briskd_empty_channels`.
""".
-spec clear_channel_empty(binary()) -> ok.
clear_channel_empty(Key) ->
    case ets:whereis(briskd_empty_channels) of
        undefined -> ok;
        _ -> ets:delete(briskd_empty_channels, Key)
    end,
    ok.

empty_since(Key, Created) ->
    case ets:whereis(briskd_empty_channels) of
        undefined ->
            channel_age_key(Created);
        _ ->
            case ets:lookup(briskd_empty_channels, Key) of
                [{Key, Since}] -> Since;
                [] -> channel_age_key(Created)
            end
    end.

-doc """
Populate the `briskd_safe_channels` and `briskd_empty_channels` ETS indexes
from the stored `channel` table at startup.
""".
-spec index_safe_channels() -> ok.
index_safe_channels() ->
    Now = erlang:system_time(second),
    case ets:whereis(briskd_safe_channels) of
        undefined ->
            ok;
        _ ->
            true = ets:delete_all_objects(briskd_safe_channels),
            lists:foreach(
                fun(Key) ->
                    case mnesia:dirty_read(channel, Key) of
                        [#channel{name = Name, members = Members}] ->
                            index_safe_channel(Name),
                            case map_size(Members) of
                                0 ->
                                    case ets:whereis(briskd_empty_channels) of
                                        undefined -> ok;
                                        _ -> ets:insert(briskd_empty_channels, {Key, Now})
                                    end;
                                _ ->
                                    ok
                            end;
                        [] ->
                            ok
                    end
                end,
                briskd_state:table_keys(channel)
            )
    end.

-doc """
Add a safe `!` channel's short name to `briskd_safe_channels`.
""".
-spec index_safe_channel(binary()) -> ok.
index_safe_channel(<<$!, _Id:5/binary, Short/binary>> = Name) when Short =/= <<>> ->
    case ets:whereis(briskd_safe_channels) of
        undefined ->
            ok;
        _ ->
            ets:insert(briskd_safe_channels, {briskd_wire:fold(Short), briskd_wire:retain(Name)}),
            ok
    end;
index_safe_channel(_) ->
    ok.

-doc """
Remove a safe `!` channel's short name from `briskd_safe_channels` if it
still points to `Name`.
""".
-spec unindex_safe_channel(binary()) -> ok.
unindex_safe_channel(<<$!, _Id:5/binary, Short/binary>> = Name) when Short =/= <<>> ->
    case ets:whereis(briskd_safe_channels) of
        undefined ->
            ok;
        _ ->
            Folded = briskd_wire:fold(Short),
            case ets:lookup(briskd_safe_channels, Folded) of
                [{Folded, Stored}] ->
                    case briskd_wire:fold(Stored) =:= briskd_wire:fold(Name) of
                        true -> ets:delete(briskd_safe_channels, Folded);
                        false -> ok
                    end;
                [] ->
                    ok
            end,
            ok
    end;
unindex_safe_channel(_) ->
    ok.

-doc """
Evict the oldest empty non-predefined channels (without remote members) when
their count exceeds `max_empty_channels` (default 1000).
""".
-spec prune_empty_channels() -> ok.
prune_empty_channels() ->
    Max = maps:get(max_empty_channels, briskd_config:current_or_empty(), 1000),
    case ets:whereis(briskd_empty_channels) of
        undefined ->
            prune_empty_keys(briskd_state:table_keys(channel), Max);
        _ ->
            case ets:info(briskd_empty_channels, size) > Max of
                false ->
                    ok;
                true ->
                    prune_empty_keys([Key || {Key, _} <- ets:tab2list(briskd_empty_channels)], Max)
            end
    end.

prune_empty_keys(Keys, Max) ->
    Empty = [
        {has_retained_state(Channel), empty_since(Key, Created), Key, Channel}
     || Key <- Keys,
        [#channel{members = Members, created = Created} = Channel] <- [
            mnesia:dirty_read(channel, Key)
        ],
        map_size(Members) =:= 0,
        not briskd_state:predefined_channel(Key),
        mnesia:dirty_read(remote_channel, Key) =:= []
    ],
    Excess = length(Empty) - Max,
    case Excess > 0 of
        true ->
            Oldest = lists:sublist(lists:sort(Empty), Excess),
            lists:foreach(fun({_, _, _, C}) -> drop_channel_row(C) end, Oldest);
        false ->
            ok
    end.

has_retained_state(#channel{
    key = Key, topic = Topic, flags = Flags, lists = Lists, password = Password, limit = Limit
}) ->
    Topic =/= <<>> orelse map_size(Flags) > 0 orelse map_size(Lists) > 0 orelse
        Password =/= undefined orelse Limit =/= undefined orelse
        briskd_state_history:has_channel_history(Key) orelse
        mnesia:dirty_read(channel_meta, Key) =/= [].

channel_age_key(Created) when is_integer(Created) -> Created;
channel_age_key(_) -> 0.

-doc """
Set a channel's member map and maintain its operatorless reop deadline.
""".
-spec track_opless(#channel{}, #{pid() => [creator | member | operator | voice]}) -> #channel{}.
track_opless(#channel{} = Channel, Remaining) ->
    HasOperator = lists:any(
        fun(Roles) -> lists:member(operator, Roles) end,
        maps:values(Remaining)
    ),
    ReopAt =
        case {HasOperator, Channel#channel.opless_since} of
            {true, _} -> undefined;
            {false, undefined} -> next_reop_time();
            {false, Existing} -> Existing
        end,
    Channel#channel{members = Remaining, opless_since = ReopAt}.

next_reop_time() ->
    Delay = persistent_term:get({briskd_state, reop_delay}, 30),
    erlang:monotonic_time(second) + Delay + rand:uniform(Delay).

-doc """
Reop safe channels whose operatorless deadline has passed (RFC 2811 section 3.2.3)
and expire empty non-predefined channels past `empty_channel_ttl`.
""".
-spec reop_channels(binary()) -> ok.
reop_channels(Server) ->
    Now = erlang:system_time(second),
    Ttl = maps:get(empty_channel_ttl, briskd_config:current_or_empty(), 86400),
    case {ets:whereis(briskd_safe_channels), ets:whereis(briskd_empty_channels)} of
        {undefined, _} ->
            reop_scan_all(Server, Now, Ttl);
        {_, undefined} ->
            reop_scan_all(Server, Now, Ttl);
        {_, _} ->
            reop_indexed(Server, Now, Ttl)
    end.

reop_indexed(Server, Now, Ttl) ->
    lists:foreach(
        fun({_Short, SafeName}) ->
            case mnesia:dirty_read(channel, briskd_wire:fold(SafeName)) of
                [#channel{flags = Flags, members = Members} = Channel] when
                    map_size(Members) > 0, is_map_key($r, Flags)
                ->
                    maybe_reop(Channel, Server);
                _ ->
                    ok
            end
        end,
        ets:tab2list(briskd_safe_channels)
    ),
    case Ttl > 0 of
        true ->
            lists:foreach(
                fun({Key, _Since}) ->
                    case mnesia:dirty_read(channel, Key) of
                        [#channel{members = Members} = Channel] when map_size(Members) =:= 0 ->
                            maybe_expire_empty(Channel, Now, Ttl);
                        _ ->
                            clear_channel_empty(Key)
                    end
                end,
                ets:tab2list(briskd_empty_channels)
            );
        false ->
            ok
    end.

reop_scan_all(Server, Now, Ttl) ->
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{flags = Flags, members = Members} = Channel] when
                    map_size(Members) > 0
                ->
                    case maps:is_key($r, Flags) of
                        true -> maybe_reop(Channel, Server);
                        false -> ok
                    end;
                [#channel{members = Members} = Channel] when map_size(Members) =:= 0 ->
                    maybe_expire_empty(Channel, Now, Ttl);
                [] ->
                    ok
            end
        end,
        briskd_state:table_keys(channel)
    ).

maybe_expire_empty(_Channel, _Now, 0) ->
    ok;
maybe_expire_empty(#channel{key = Key, created = Created} = Channel, Now, Ttl) ->
    Eligible =
        briskd_state:retention() =:= transient orelse not has_retained_state(Channel),
    Since = empty_since(Key, Created),
    case
        Eligible andalso Since > 0 andalso Now - Since >= Ttl andalso
            not briskd_state:predefined_channel(Key) andalso
            mnesia:dirty_read(remote_channel, Key) =:= []
    of
        true -> drop_channel_row(Channel);
        false -> ok
    end.

maybe_reop(#channel{members = Members} = Channel, Server) ->
    HasOperator = lists:any(
        fun(Roles) -> lists:member(operator, Roles) end,
        maps:values(Members)
    ),
    case HasOperator of
        true ->
            case Channel#channel.opless_since of
                undefined -> ok;
                _ -> mnesia:dirty_write(Channel#channel{opless_since = undefined})
            end;
        false ->
            maybe_reop_opless(Channel, Server)
    end.

maybe_reop_opless(#channel{opless_since = undefined} = Channel, _Server) ->
    mnesia:dirty_write(Channel#channel{opless_since = next_reop_time()});
maybe_reop_opless(#channel{opless_since = ReopAt, members = Members} = Channel, Server) ->
    case erlang:monotonic_time(second) >= ReopAt of
        false ->
            ok;
        true ->
            case pick_member(Members) of
                none ->
                    ok;
                {Pid, Pids} ->
                    Nick =
                        case mnesia:dirty_read(client, Pid) of
                            [#client{nick = CurrentNick}] -> CurrentNick;
                            [] -> <<"*">>
                        end,
                    NewMembers = Members#{
                        Pid := lists:usort([operator | maps:get(Pid, Members)])
                    },
                    mnesia:dirty_write(Channel#channel{
                        members = NewMembers, opless_since = undefined
                    }),
                    briskd_state_send:broadcast(
                        Pids, Server, <<"MODE">>, [Channel#channel.name, <<"+o">>, Nick], none
                    ),
                    briskd_state_link:server_broadcast(
                        briskd_wire:line(
                            Server, <<"MODE">>, [Channel#channel.name, <<"+o">>, Nick], none
                        )
                    )
            end
    end.

pick_member(Members) ->
    case maps:keys(Members) of
        [] -> none;
        Pids -> {lists:nth(rand:uniform(length(Pids)), Pids), Pids}
    end.

-doc """
Validate `Requested` as a channel name and resolve `!short` safe-channel
names using `briskd_safe_channels`, generating a fresh 5-character id when
none exists yet.
""".
-spec resolve_channel(binary()) -> {ok, binary()} | error.
resolve_channel(<<$!, Short/binary>> = Requested) ->
    Key = briskd_wire:fold(Requested),
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Existing}] ->
            {ok, Existing};
        [] ->
            case {byte_size(Short) =< 44, briskd_wire:channel(<<$#, Short/binary>>)} of
                {false, _} ->
                    error;
                {_, false} ->
                    error;
                {true, true} ->
                    case find_safe_short(Short) of
                        {ok, Existing} -> {ok, Existing};
                        none -> {ok, <<$!, (safe_channel_id())/binary, Short/binary>>}
                    end
            end
    end;
resolve_channel(Name) ->
    case briskd_wire:channel(Name) of
        true -> {ok, Name};
        false -> error
    end.

find_safe_short(Short) ->
    Wanted = briskd_wire:fold(Short),
    case ets:whereis(briskd_safe_channels) of
        undefined ->
            scan_safe_short(Wanted);
        _ ->
            case ets:lookup(briskd_safe_channels, Wanted) of
                [{Wanted, Indexed}] ->
                    case mnesia:dirty_read(channel, briskd_wire:fold(Indexed)) of
                        [#channel{name = Existing}] ->
                            {ok, Existing};
                        [] ->
                            ets:delete(briskd_safe_channels, Wanted),
                            none
                    end;
                [] ->
                    none
            end
    end.

scan_safe_short(Wanted) ->
    case
        [
            Name
         || Key <- briskd_state:table_keys(channel),
            [#channel{name = <<$!, _Id:5/binary, ExistingShort/binary>> = Name}] <-
                [mnesia:dirty_read(channel, Key)],
            briskd_wire:fold(ExistingShort) =:= Wanted
        ]
    of
        [Name | _] ->
            index_safe_channel(Name),
            {ok, Name};
        [] ->
            none
    end.

safe_channel_id() ->
    Alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890">>,
    safe_channel_id(erlang:system_time(second) rem 60466176, Alphabet, <<>>).

safe_channel_id(_, _, <<_:(5 * 8)/bitstring>> = Id) ->
    Id;
safe_channel_id(Value, Alphabet, Acc) ->
    Digit = Value rem 36,
    Char = binary:at(Alphabet, Digit),
    safe_channel_id(Value div 36, Alphabet, <<Char, Acc/binary>>).
