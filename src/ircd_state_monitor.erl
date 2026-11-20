-module(ircd_state_monitor).
-export([clear/1, monitor/3, offline/1, online/2, watchers/1]).
-include("ircd_state.hrl").

-moduledoc """
IRCv3 [MONITOR](https://ircv3.net/specs/extensions/monitor): online and
offline notifications for nicknames, local or remote.

Runs inside `m:ircd_state`. Each client's targets live in `m:ircd_conn`
(`monitor`, folded nick => given spelling) and in the `ircd_monitor` ETS bag
(folded nick, watcher pid) used to find watchers on nick events. Both are
transient and dropped on disconnect. The list length is capped by
`monitor_limit` (default 100, advertised as ISUPPORT `MONITOR`). Nicknames
compare under the RFC 1459 case mapping (`ircd_wire:fold/1`). Replies are
split so each 730/731/732 line carries at most about 400 bytes of targets.
`m:ircd_state_v3` also uses `watchers/1` for extended-monitor.
""".

%% Bytes of targets per 730/731/732 line, leaving room for prefix and nick.
-define(LINE_BUDGET, 400).

-doc """
Pids of the local clients monitoring `Nick` (compared folded).
""".
-spec watchers(binary()) -> [pid()].
watchers(Nick) ->
    case ets:whereis(ircd_monitor) of
        undefined -> [];
        _ -> [Pid || {_, Pid} <- ets:lookup(ircd_monitor, ircd_wire:fold(Nick))]
    end.

-doc """
A nickname became reachable: send `730 RPL_MONONLINE` with `Mask`
(`nick!user@host`) to its watchers.
""".
-spec online(binary(), binary()) -> ok.
online(Nick, Mask) ->
    Server = server(),
    lists:foreach(
        fun(Pid) -> reply(Pid, Server, <<"730">>, Mask) end,
        watchers(Nick)
    ).

-doc """
A nickname went away: send `731 RPL_MONOFFLINE` to its watchers.
""".
-spec offline(binary()) -> ok.
offline(Nick) ->
    Server = server(),
    lists:foreach(fun(Pid) -> reply(Pid, Server, <<"731">>, Nick) end, watchers(Nick)).

-doc """
Drop every target of the client `Pid` (on `MONITOR C` and on disconnect).
""".
-spec clear(pid()) -> ok.
clear(Pid) ->
    lists:foreach(
        fun(Key) -> ets:delete_object(ircd_monitor, {Key, Pid}) end,
        maps:keys(ircd_conn:get(Pid, monitor, #{}))
    ),
    ircd_conn:remove(Pid, monitor).

-doc """
`MONITOR <+|-|C|L|S> [targets]`.

`+` adds comma-separated nicknames (invalid ones are skipped) and replies
730 / 731 for each new target; targets past the limit get
`734 ERR_MONLISTFULL`. `-` removes targets, `C` clears the list, `L` lists
it (732, then 733), and `S` reports the status of every target (730 / 731).
A missing target list gets 461 and an unknown modifier 421.
""".
-spec monitor([binary()], #client{}, binary()) -> ok.
monitor([<<"+">>, Targets | _], #client{pid = Pid} = Client, Server) ->
    Limit = maps:get(monitor_limit, persistent_term:get({ircd_state, config}), 100),
    Wanted = [T || T <- binary:split(Targets, <<",">>, [global, trim_all])],
    {Online, Offline, Rejected} = add(Wanted, Pid, Limit, [], [], []),
    lines(Client, Server, <<"730">>, lists:reverse(Online)),
    lines(Client, Server, <<"731">>, lists:reverse(Offline)),
    case Rejected of
        [] ->
            ok;
        _ ->
            ircd_state_send:numeric(
                Client,
                Server,
                <<"734">>,
                [integer_to_binary(Limit), binary:join(Rejected, <<",">>)],
                <<"Monitor list is full.">>
            )
    end;
monitor([<<"-">>, Targets | _], #client{pid = Pid}, _Server) ->
    Current = ircd_conn:get(Pid, monitor, #{}),
    Keys = [ircd_wire:fold(T) || T <- binary:split(Targets, <<",">>, [global, trim_all])],
    lists:foreach(fun(Key) -> ets:delete_object(ircd_monitor, {Key, Pid}) end, Keys),
    ircd_conn:put(Pid, monitor, maps:without(Keys, Current));
monitor([<<"C">> | _], #client{pid = Pid}, _Server) ->
    clear(Pid);
monitor([<<"L">> | _], #client{pid = Pid} = Client, Server) ->
    lines(Client, Server, <<"732">>, lists:sort(maps:values(ircd_conn:get(Pid, monitor, #{})))),
    ircd_state_send:numeric(Client, Server, <<"733">>, [], <<"End of MONITOR list">>);
monitor([<<"S">> | _], #client{pid = Pid} = Client, Server) ->
    {Online, Offline} = lists:foldl(
        fun(Given, {On, Off}) ->
            case lookup(Given) of
                {online, Mask} -> {[Mask | On], Off};
                offline -> {On, [Given | Off]}
            end
        end,
        {[], []},
        lists:sort(maps:values(ircd_conn:get(Pid, monitor, #{})))
    ),
    lines(Client, Server, <<"730">>, lists:reverse(Online)),
    lines(Client, Server, <<"731">>, lists:reverse(Offline));
monitor([Modifier | _], Client, Server) when
    Modifier =:= <<"+">>; Modifier =:= <<"-">>
->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"MONITOR">>], <<"Not enough parameters">>
    );
monitor([], Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"MONITOR">>], <<"Not enough parameters">>
    );
monitor([_Unknown | _], Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"421">>, [<<"MONITOR">>], <<"Unknown MONITOR modifier">>
    ).

add([], _Pid, _Limit, On, Off, Rejected) ->
    {On, Off, lists:reverse(Rejected)};
add([Target | Rest], Pid, Limit, On, Off, Rejected) ->
    Current = ircd_conn:get(Pid, monitor, #{}),
    Key = ircd_wire:fold(Target),
    case {ircd_wire:nickname(Target, ircd_state:nicklen()), maps:is_key(Key, Current)} of
        {false, _} ->
            add(Rest, Pid, Limit, On, Off, Rejected);
        {true, true} ->
            add(Rest, Pid, Limit, On, Off, Rejected);
        {true, false} when map_size(Current) >= Limit ->
            {On, Off, lists:reverse(Rejected, [Target | Rest])};
        {true, false} ->
            ircd_conn:put(Pid, monitor, Current#{Key => ircd_wire:retain(Target)}),
            ets:insert(ircd_monitor, {Key, Pid}),
            case lookup(Target) of
                {online, Mask} -> add(Rest, Pid, Limit, [Mask | On], Off, Rejected);
                offline -> add(Rest, Pid, Limit, On, [Target | Off], Rejected)
            end
    end.

lookup(Nick) ->
    case ircd_state_client:find_nick(Nick) of
        #client{} = Client ->
            case ircd_state_client:ready(Client) of
                true -> {online, iolist_to_binary(ircd_state_send:prefix(Client))};
                false -> offline
            end;
        undefined ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [#remote_client{nick = N, user = U, host = H}] ->
                    {online, <<N/binary, "!", U/binary, "@", H/binary>>};
                [] ->
                    offline
            end
    end.

lines(_Client, _Server, _Numeric, []) ->
    ok;
lines(Client, Server, Numeric, Items) ->
    lists:foreach(
        fun(Chunk) ->
            ircd_state_send:numeric(Client, Server, Numeric, [], lists:join(<<",">>, Chunk))
        end,
        chunk(Items, 0, [], [])
    ).

chunk([], _Size, [], Acc) ->
    lists:reverse(Acc);
chunk([], _Size, Current, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
chunk([Item | Rest], Size, Current, Acc) when
    Current =/= [], Size + byte_size(Item) + 1 > ?LINE_BUDGET
->
    chunk([Item | Rest], 0, [], [lists:reverse(Current) | Acc]);
chunk([Item | Rest], Size, Current, Acc) ->
    chunk(Rest, Size + byte_size(Item) + 1, [Item | Current], Acc).

reply(Pid, Server, Numeric, Target) ->
    Nick =
        case mnesia:dirty_read(client, Pid) of
            [#client{nick = N}] -> N;
            [] -> <<"*">>
        end,
    ircd_state_send:send(Pid, Server, Numeric, [Nick], Target).

server() ->
    maps:get(name, persistent_term:get({ircd_state, config})).
