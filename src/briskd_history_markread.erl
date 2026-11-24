-module(briskd_history_markread).
-moduledoc """
`MARKREAD` command and account/connection read-marker synchronization
([draft/read-marker](https://ircv3.net/specs/extensions/read-marker)).
""".
-export([
    markread/3,
    markread_on_join/3,
    remote_marker/3,
    rename_markers/2,
    valid_marker_target/1
]).
-include("briskd_client.hrl").
-include("briskd_account.hrl").

-doc """
`MARKREAD <target> [timestamp=...]` (draft/read-marker).

Without a timestamp, replies with the stored marker (`*` when none). A
timestamp later than the stored one is saved and sent to every connection
of the same account with read-marker; an older one gets the stored value
back. Markers are stored per account in Mnesia (and synchronized to peers)
or, without an account, per connection. Errors are `FAIL MARKREAD` with
`NEED_MORE_PARAMS` or `INVALID_PARAMS`.
""".
-spec markread([binary()], #client{}, binary()) -> ok.
markread([], #client{pid = Pid}, _Server) ->
    briskd_state_send:fail(
        Pid, <<"MARKREAD">>, <<"NEED_MORE_PARAMS">>, [], <<"Missing parameters">>
    );
markread([Target | Rest], #client{pid = Pid} = Client, Server) ->
    %% Only a channel or nickname can carry a marker, so a client cannot
    %% create stored rows for arbitrary strings.
    case valid_marker_target(Target) of
        true ->
            markread_valid([Target | Rest], Client, Server);
        false ->
            briskd_state_send:fail(
                Pid, <<"MARKREAD">>, <<"INVALID_PARAMS">>, [Target], <<"Invalid target">>
            )
    end.

-doc """
True when `Target` may carry a read marker: a valid channel name or a valid
nickname (`briskd_wire:channel/1`, `briskd_wire:nickname/2`).
""".
-spec valid_marker_target(binary()) -> boolean().
valid_marker_target(Target) ->
    briskd_wire:channel(Target) orelse briskd_wire:nickname(Target, briskd_state:nicklen()).

markread_valid([Target], #client{pid = Pid}, Server) ->
    send_marker(Pid, Server, Target, get_marker(Pid, Target));
markread_valid([Target, <<"timestamp=", Value/binary>> | _], #client{pid = Pid}, Server) ->
    case briskd_history_query:parse_timestamp(Value) of
        {ok, Time} ->
            Stored = get_marker(Pid, Target),
            case Stored =:= undefined orelse Time > Stored of
                true ->
                    put_marker(Pid, Target, Time),
                    lists:foreach(
                        fun(Other) -> send_marker(Other, Server, Target, Time) end,
                        same_account(Pid)
                    );
                false ->
                    send_marker(Pid, Server, Target, Stored)
            end;
        error ->
            briskd_state_send:fail(
                Pid, <<"MARKREAD">>, <<"INVALID_PARAMS">>, [Value], <<"Invalid parameters">>
            )
    end;
markread_valid([_Target, Other | _], #client{pid = Pid}, _Server) ->
    briskd_state_send:fail(
        Pid, <<"MARKREAD">>, <<"INVALID_PARAMS">>, [Other], <<"Invalid parameters">>
    ).

-doc """
After `JOIN`, send the channel's read marker (`MARKREAD <channel> <value>`)
to a client with draft/read-marker.
""".
-spec markread_on_join(pid(), binary(), binary()) -> ok.
markread_on_join(Pid, Name, Server) ->
    case briskd_cap:enabled(Pid, <<"draft/read-marker">>) of
        true -> send_marker(Pid, Server, Name, get_marker(Pid, Name));
        false -> ok
    end.

send_marker(Pid, Server, Target, Time) ->
    Value =
        case Time of
            undefined -> <<"*">>;
            _ -> <<"timestamp=", (briskd_state_send:time_value(Time))/binary>>
        end,
    briskd_state_send:send(Pid, Server, <<"MARKREAD">>, [Target, Value], none).

get_marker(Pid, Target) ->
    case briskd_state_v3:account(Pid) of
        undefined ->
            maps:get(briskd_wire:fold(Target), briskd_conn:get(Pid, markread, #{}), undefined);
        Account ->
            case
                mnesia:dirty_read(read_marker, {briskd_wire:fold(Account), briskd_wire:fold(Target)})
            of
                [#read_marker{time = Time}] -> Time;
                [] -> undefined
            end
    end.

put_marker(Pid, Target, Time) ->
    FoldedTarget = briskd_wire:fold(Target),
    case briskd_state_v3:account(Pid) of
        undefined ->
            Markers0 = briskd_conn:get(Pid, markread, #{}),
            Markers1 = trim_conn_markers(Markers0, FoldedTarget, max_read_markers()),
            briskd_conn:put(Pid, markread, Markers1#{FoldedTarget => Time});
        Account ->
            Folded = briskd_wire:fold(Account),
            store_account_marker(Folded, FoldedTarget, Time),
            briskd_state_sync:markread(Folded, FoldedTarget, Time)
    end.

max_read_markers() ->
    maps:get(max_read_markers, briskd_config:current_or_empty(), 500).

trim_conn_markers(Markers, Target, Max) ->
    case maps:is_key(Target, Markers) orelse map_size(Markers) < Max of
        true ->
            Markers;
        false ->
            Sorted = lists:sort([{T, K} || K := T <- Markers]),
            DropCount = map_size(Markers) - (Max - 1),
            DropKeys = [K || {_, K} <- lists:sublist(Sorted, DropCount)],
            maps:without(DropKeys, Markers)
    end.

store_account_marker(FoldedAccount, FoldedTarget, Time) ->
    Key = {FoldedAccount, FoldedTarget},
    case mnesia:dirty_read(read_marker, Key) of
        [_] ->
            ok;
        [] ->
            Max = max_read_markers(),
            Existing = mnesia:dirty_select(read_marker, [
                {{read_marker, {FoldedAccount, '$1'}, '$2'}, [], [{{'$2', '$1'}}]}
            ]),
            Excess = length(Existing) - (Max - 1),
            case Excess > 0 of
                true ->
                    Oldest = lists:sublist(lists:sort(Existing), Excess),
                    lists:foreach(
                        fun({_, OldTarget}) ->
                            mnesia:dirty_delete(read_marker, {FoldedAccount, OldTarget})
                        end,
                        Oldest
                    );
                false ->
                    ok
            end
    end,
    mnesia:dirty_write(#read_marker{key = Key, time = Time}).

-doc """
Move every account's read marker from folded channel name `OldKey` to
`NewKey` after a channel rename.
""".
-spec rename_markers(binary(), binary()) -> ok.
rename_markers(OldKey, NewKey) ->
    Rows = mnesia:dirty_select(read_marker, [
        {{read_marker, {'$1', OldKey}, '$2'}, [], [{{'$1', '$2'}}]}
    ]),
    lists:foreach(
        fun
            ({Account, Time}) when is_binary(Account), is_integer(Time) ->
                mnesia:dirty_delete(read_marker, {Account, OldKey}),
                mnesia:dirty_write(#read_marker{key = {Account, NewKey}, time = Time});
            (_) ->
                ok
        end,
        Rows
    ),
    case ets:whereis(briskd_conn) of
        undefined ->
            ok;
        _ ->
            lists:foreach(
                fun({Pid, Map}) ->
                    case maps:get(markread, Map, undefined) of
                        Markers when is_map(Markers), is_map_key(OldKey, Markers) ->
                            Time = maps:get(OldKey, Markers),
                            Updated = (maps:remove(OldKey, Markers))#{NewKey => Time},
                            briskd_conn:put(Pid, markread, Updated);
                        _ ->
                            ok
                    end
                end,
                ets:tab2list(briskd_conn)
            )
    end.

-doc """
Apply a read marker received from another server. Returns `unchanged` when
the stored marker is already at or past `Time`; otherwise stores it, tells
this server's read-marker clients of that account, and returns `updated`.
""".
-spec remote_marker(binary(), binary(), integer()) -> updated | unchanged.
remote_marker(Account, Target, Time) ->
    Key = {briskd_wire:fold(Account), briskd_wire:fold(Target)},
    case mnesia:dirty_read(read_marker, Key) of
        [#read_marker{time = Stored}] when Stored >= Time ->
            unchanged;
        _ ->
            store_account_marker(element(1, Key), element(2, Key), Time),
            Server = maps:get(name, briskd_config:current()),
            lists:foreach(
                fun(Pid) ->
                    case briskd_cap:enabled(Pid, <<"draft/read-marker">>) of
                        true -> send_marker(Pid, Server, Target, Time);
                        false -> ok
                    end
                end,
                briskd_conn:account_pids(element(1, Key))
            ),
            updated
    end.

%% Connections that share the requester's account and negotiated read-marker.
same_account(Pid) ->
    case briskd_state_v3:account(Pid) of
        undefined ->
            [Pid];
        Account ->
            [
                Other
             || Other <- briskd_conn:account_pids(Account),
                Other =:= Pid orelse briskd_cap:enabled(Other, <<"draft/read-marker">>)
            ]
    end.
