-module(briskd_history_query).
-moduledoc """
History retrieval, replay on `JOIN`, `CHATHISTORY` queries, timestamp parsing,
and message-search history helpers.
""".
-export([
    access/2,
    chathistory/3,
    find/2,
    fold_messages/2,
    parse_timestamp/1,
    remove/2,
    replay_entries/4,
    replay_on_join/3,
    search_entry/2,
    search_scope/2
]).
-include("briskd_client.hrl").
-include("briskd_channel.hrl").
-include("briskd_account.hrl").

-doc """
Find a `PRIVMSG`, `NOTICE`, or `TAGMSG` entry by `msgid` in a channel
(`{channel, FoldedName}`) or direct-message (`{direct, PairKey}`) history.
""".
-spec find({channel, binary()} | {direct, tuple()}, binary()) -> {ok, map()} | error.
find(Source, MsgId) ->
    case
        [
            E
         || #{msgid := Id, cmd := Cmd} = E <- entries(Source),
            Id =:= MsgId,
            Cmd =:= <<"PRIVMSG">> orelse Cmd =:= <<"NOTICE">> orelse Cmd =:= <<"TAGMSG">>
        ]
    of
        [Entry | _] -> {ok, Entry};
        [] -> error
    end.

entries({channel, Key}) -> briskd_state_history:channel_history(Key);
entries({direct, Key}) -> briskd_state_history:direct_history(Key).

-doc """
Remove every history entry matching `MsgId` from `{channel, Key}` or
`{direct, PairKey}`.
""".
-spec remove({channel, binary()} | {direct, {dm_party(), dm_party()}}, binary()) -> ok.
remove(Source, MsgId) ->
    Kept = [E || E <- entries(Source), maps:get(msgid, E) =/= MsgId],
    case Source of
        {channel, Key} -> briskd_state_history:replace_channel(Key, Kept);
        {direct, Key} -> briskd_state_history:replace_direct(Key, Kept)
    end,
    ok.

%%% Replay

-doc """
Replay stored channel history, oldest first, to a joining client under
`channels` retention, in a `chathistory` batch when the client has `batch`.
Without draft/event-playback only `PRIVMSG` and `NOTICE` are replayed.
Clients with draft/chathistory fetch history themselves and get nothing.
""".
-spec replay_on_join(binary(), binary(), pid()) -> ok.
replay_on_join(Key, Name, Pid) ->
    case
        briskd_state:retention() =:= channels andalso
            not briskd_cap:enabled(Pid, <<"draft/chathistory">>)
    of
        true ->
            case
                briskd_state_history:playable(
                    Pid, lists:reverse(briskd_state_history:channel_history(Key))
                )
            of
                [] ->
                    ok;
                Entries ->
                    briskd_state_send:with_batch(Pid, <<"chathistory">>, [Name], [], fun() ->
                        replay_entries(Pid, Name, Entries, server())
                    end)
            end;
        false ->
            ok
    end.

-doc """
Send entries (oldest first) to `Pid` with their stored `msgid`, `time`,
`account`, and client-only tags. `Name` is the channel, or `undefined` to
use each entry's stored target. Multiline entries are sent as
draft/multiline batches. `_Server` is unused.
""".
-spec replay_entries(pid(), undefined | binary(), [map()], binary()) -> ok.
replay_entries(Pid, Name, Entries, _Server) ->
    lists:foreach(fun(Entry) -> replay(Pid, Name, Entry) end, Entries).

replay(Pid, Name, #{cmd := Command, prefix := Prefix, text := Text} = Entry) ->
    Target =
        case Name of
            undefined -> maps:get(target, Entry);
            _ -> Name
        end,
    Tags = entry_tags(Entry),
    Middle =
        case maps:get(notarget, Entry, false) of
            true -> [];
            false -> [Target | maps:get(params, Entry, [])]
        end,
    case Text of
        {multiline, Lines} ->
            briskd_state_batch:deliver_multiline(Pid, Prefix, Command, Target, Lines, Tags, replay);
        _ ->
            briskd_state_send:send(Pid, Prefix, Command, Middle, Text, Tags)
    end.

entry_tags(#{msgid := MsgId, time := Time, tags := Tags} = Entry) ->
    Id =
        case MsgId of
            undefined -> [];
            _ -> [{<<"msgid">>, MsgId}]
        end,
    Stamp =
        case Time of
            0 -> [];
            _ -> [{<<"time">>, briskd_state_send:time_value(Time)}]
        end,
    Account =
        case maps:get(account, Entry, undefined) of
            undefined -> [];
            Name -> [{<<"account">>, Name}]
        end,
    Tags ++ Id ++ Stamp ++ Account.

%%% CHATHISTORY

-doc """
`CHATHISTORY <subcommand> ...` (draft/chathistory).

Supports `BEFORE`, `AFTER`, `LATEST`, `AROUND`, and `BETWEEN` with
`timestamp=` or `msgid=` references, and `TARGETS` with two timestamps. The
limit is capped by `history_limit`. Results go in a `chathistory` batch
(`draft/chathistory-targets` for `TARGETS`); a batch with fewer entries
than the limit carries `draft/chathistory-end`. Channel history is readable
only by current members, direct history only by a logged-in client.

Errors are `FAIL CHATHISTORY` with `INVALID_PARAMS`, `INVALID_TARGET`, or
`INVALID_MSGREFTYPE`; no parameters gets 461.
""".
-spec chathistory([binary()], #client{}, binary()) -> ok.
chathistory([Sub | Rest], #client{pid = Pid} = Client, Server) ->
    Upper = briskd_wire:upper(Sub),
    Max = briskd_state:history_limit(),
    case {Upper, Rest} of
        {<<"TARGETS">>, [A, B, Limit]} ->
            case {parse_selector(A), parse_selector(B), parse_limit(Limit, Max)} of
                {{time, T1}, {time, T2}, {ok, N}} ->
                    targets(Client, T1, T2, N);
                _ ->
                    invalid(Pid, Upper)
            end;
        {_, [Target, Sel, Limit]} when
            Upper =:= <<"BEFORE">>;
            Upper =:= <<"AFTER">>;
            Upper =:= <<"LATEST">>;
            Upper =:= <<"AROUND">>
        ->
            with_target(Client, Upper, Target, fun(Name, Entries) ->
                case {selector(Upper, Sel, Entries), parse_limit(Limit, Max)} of
                    {{ok, Position}, {ok, N}} ->
                        send_history(Pid, Name, select(Upper, Position, Entries, N), N);
                    {msgreftype, _} ->
                        msgreftype(Pid, Upper, Target);
                    {error, _} ->
                        invalid(Pid, Upper);
                    {_, error} ->
                        invalid(Pid, Upper)
                end
            end);
        {<<"BETWEEN">>, [Target, SelA, SelB, Limit]} ->
            with_target(Client, Upper, Target, fun(Name, Entries) ->
                case
                    {
                        selector(Upper, SelA, Entries),
                        selector(Upper, SelB, Entries),
                        parse_limit(Limit, Max)
                    }
                of
                    {{ok, PA}, {ok, PB}, {ok, N}} ->
                        send_history(Pid, Name, between(PA, PB, Entries, N), N);
                    {msgreftype, _, _} ->
                        msgreftype(Pid, Upper, Target);
                    {_, msgreftype, _} ->
                        msgreftype(Pid, Upper, Target);
                    _ ->
                        invalid(Pid, Upper)
                end
            end);
        {Known, _} when
            Known =:= <<"BEFORE">>;
            Known =:= <<"AFTER">>;
            Known =:= <<"LATEST">>;
            Known =:= <<"AROUND">>;
            Known =:= <<"BETWEEN">>;
            Known =:= <<"TARGETS">>
        ->
            briskd_state_send:fail(
                Pid, <<"CHATHISTORY">>, <<"INVALID_PARAMS">>, [Known], <<"Insufficient parameters">>
            );
        _ ->
            briskd_state_send:fail(
                Pid, <<"CHATHISTORY">>, <<"INVALID_PARAMS">>, [Sub], <<"Unknown command">>
            )
    end,
    _ = Server,
    ok;
chathistory([], Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"CHATHISTORY">>], <<"Not enough parameters">>
    ).

msgreftype(Pid, Sub, Target) ->
    briskd_state_send:fail(
        Pid,
        <<"CHATHISTORY">>,
        <<"INVALID_MSGREFTYPE">>,
        [Sub, Target],
        <<"Unknown message reference type">>
    ).

invalid(Pid, Sub) ->
    briskd_state_send:fail(
        Pid, <<"CHATHISTORY">>, <<"INVALID_PARAMS">>, [Sub], <<"Invalid parameters">>
    ).

%% Resolve a target the client may read, then call Fun with oldest-first entries.
with_target(#client{pid = Pid} = Client, Sub, Target, Fun) ->
    case access(Client, Target) of
        {ok, Name, Source} ->
            Fun(Name, briskd_state_history:playable(Pid, lists:reverse(entries(Source))));
        error ->
            briskd_state_send:fail(
                Pid,
                <<"CHATHISTORY">>,
                <<"INVALID_TARGET">>,
                [Sub, Target],
                <<"Messages could not be retrieved">>
            )
    end.

-doc """
Check whether `Client` may read history for `Target` (`{ok, Name, Source}` or `error`).
Channel history requires current membership; direct history requires login.
""".
-spec access(#client{}, binary()) ->
    {ok, binary(), {channel, binary()} | {direct, {dm_party(), dm_party()}}} | error.
access(#client{pid = Pid}, Target) ->
    case briskd_wire:channel(Target) of
        true ->
            case mnesia:dirty_read(channel, briskd_wire:fold(Target)) of
                [#channel{key = Key, name = Name, members = Members}] when
                    is_map_key(Pid, Members)
                ->
                    {ok, Name, {channel, Key}};
                _ ->
                    error
            end;
        false ->
            case briskd_state_v3:account(Pid) of
                undefined ->
                    error;
                Mine ->
                    Theirs = briskd_state_history:party({peer_account(Target), Target}),
                    Key = briskd_state_history:dm_key(
                        briskd_state_history:party({Mine, <<>>}), Theirs
                    ),
                    {ok, Target, {direct, Key}}
            end
    end.

peer_account(Nick) ->
    case briskd_state_client:find_nick(Nick) of
        #client{pid = Pid} ->
            briskd_state_v3:account(Pid);
        undefined ->
            case briskd_state_v3:remote_account(briskd_wire:fold(Nick)) of
                undefined ->
                    case briskd_account:find(Nick) of
                        {ok, #account{name = Name}} -> Name;
                        error -> undefined
                    end;
                Account ->
                    Account
            end
    end.

%% A selector resolves to a position: `{before_index, I}` style is avoided by
%% returning a time and, for msgid, the entry's index so equal times work.
selector(<<"LATEST">>, <<"*">>, _Entries) ->
    {ok, latest};
selector(Sub, Sel, Entries) ->
    case parse_selector(Sel) of
        {time, T} ->
            {ok, {time, T}};
        {msgid, Id} ->
            case index_of(Id, Entries, 1) of
                {ok, I} ->
                    {ok, {index, I}};
                error when Sub =:= <<"LATEST">> ->
                    %% Per IRCv3 draft/chathistory, an unknown msgid in LATEST
                    %% falls back to `*` (return the latest messages).
                    {ok, latest};
                error ->
                    error
            end;
        msgreftype ->
            msgreftype;
        error ->
            error
    end.

index_of(_Id, [], _I) -> error;
index_of(Id, [#{msgid := Id} | _], I) -> {ok, I};
index_of(Id, [_ | Rest], I) -> index_of(Id, Rest, I + 1).

parse_selector(<<"timestamp=", Value/binary>>) ->
    case parse_timestamp(Value) of
        {ok, T} -> {time, T};
        error -> error
    end;
parse_selector(<<"msgid=", Id/binary>>) when Id =/= <<>> ->
    {msgid, Id};
parse_selector(Other) ->
    %% A well-formed `key=value` with an unsupported key is a reference type
    %% this server does not offer (MSGREFTYPES=timestamp,msgid).
    case binary:split(Other, <<"=">>) of
        [Key, _] when Key =/= <<>> -> msgreftype;
        _ -> error
    end.

-doc """
Parse an RFC 3339 timestamp such as `YYYY-MM-DDThh:mm:ss[.sss]Z` to
milliseconds since the epoch. Returns `error` for anything else.
""".
-spec parse_timestamp(binary()) -> {ok, integer()} | error.
parse_timestamp(Value) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Value), [{unit, millisecond}]) of
        Millis -> {ok, Millis}
    catch
        error:_ -> error
    end.

parse_limit(Raw, Max) ->
    try binary_to_integer(Raw) of
        N when N > 0 -> {ok, min(N, Max)};
        _ -> error
    catch
        error:badarg -> error
    end.

%% Entries are oldest first. Each list element is tagged with its index.
indexed(Entries) ->
    lists:enumerate(Entries).

before_pos({index, I}, {J, _}) -> J < I;
before_pos({time, T}, {_, #{time := Time}}) -> Time < T.

after_pos({index, I}, {J, _}) -> J > I;
after_pos({time, T}, {_, #{time := Time}}) -> Time > T.

select(<<"LATEST">>, latest, Entries, N) ->
    last_n(Entries, N);
select(<<"LATEST">>, Pos, Entries, N) ->
    last_n([E || {_, E} = X <- indexed(Entries), after_pos(Pos, X)], N);
select(<<"BEFORE">>, Pos, Entries, N) ->
    last_n([E || {_, E} = X <- indexed(Entries), before_pos(Pos, X)], N);
select(<<"AFTER">>, Pos, Entries, N) ->
    lists:sublist([E || {_, E} = X <- indexed(Entries), after_pos(Pos, X)], N);
select(<<"AROUND">>, Pos, Entries, N) ->
    %% The reference message is included: up to (N-1) div 2 before it, then
    %% the reference and the messages after it.
    Before = last_n([E || {_, E} = X <- indexed(Entries), before_pos(Pos, X)], (N - 1) div 2),
    After = lists:sublist(
        [E || {_, E} = X <- indexed(Entries), not before_pos(Pos, X)], N - length(Before)
    ),
    Before ++ After.

between(PA, PB, Entries, N) ->
    Indexed = indexed(Entries),
    case position_order(PA, PB, Indexed) of
        forward ->
            lists:sublist(
                [E || {_, E} = X <- Indexed, after_pos(PA, X), before_pos(PB, X)], N
            );
        backward ->
            last_n([E || {_, E} = X <- Indexed, after_pos(PB, X), before_pos(PA, X)], N)
    end.

position_order(PA, PB, Indexed) ->
    case {key(PA, Indexed), key(PB, Indexed)} of
        {A, B} when A =< B -> forward;
        _ -> backward
    end.

key({index, I}, Indexed) ->
    {_, #{time := T}} = lists:keyfind(I, 1, Indexed),
    {T, I};
key({time, T}, _Indexed) ->
    {T, 0}.

last_n(List, N) ->
    lists:nthtail(max(0, length(List) - N), List).

send_history(Pid, Name, Selected, Limit) ->
    Server = server(),
    End =
        case length(Selected) < Limit of
            true -> [{<<"draft/chathistory-end">>, undefined}];
            false -> []
        end,
    ReplayName =
        case briskd_wire:channel(Name) of
            true -> Name;
            false -> undefined
        end,
    briskd_state_send:with_batch(Pid, <<"chathistory">>, [Name], End, fun() ->
        replay_entries(Pid, ReplayName, Selected, Server)
    end),
    ok.

targets(#client{pid = Pid, channels = Keys}, From, To, N) ->
    Channels = [
        {Name, latest_time(briskd_state_history:channel_history(Key))}
     || Key <- Keys,
        [#channel{name = Name}] <- [mnesia:dirty_read(channel, Key)]
    ],
    Direct =
        case briskd_state_v3:account(Pid) of
            undefined ->
                [];
            Account ->
                Mine = briskd_wire:fold(Account),
                Me = {account, Mine},
                [
                    {other_party(Mine, Entries), latest_time(Entries)}
                 || {A, B} = Pair <- briskd_state_history:direct_conversations(),
                    A =:= Me orelse B =:= Me,
                    Entries <- [briskd_state_history:direct_history(Pair)],
                    Entries =/= []
                ]
        end,
    %% Bounds are exclusive. A later first timestamp selects backwards in
    %% time, keeping the newest matches.
    Candidates = lists:keysort(2, [{T, Time} || {T, Time} <- Channels ++ Direct, Time > 0]),
    Matches =
        case From =< To of
            true ->
                lists:sublist([C || {_, Time} = C <- Candidates, Time > From, Time < To], N);
            false ->
                last_n([C || {_, Time} = C <- Candidates, Time < From, Time > To], N)
        end,
    briskd_state_send:with_batch(Pid, <<"draft/chathistory-targets">>, [], [], fun() ->
        lists:foreach(
            fun({Target, Time}) ->
                briskd_state_send:send(
                    Pid,
                    server(),
                    <<"CHATHISTORY">>,
                    [<<"TARGETS">>, Target, briskd_state_send:time_value(Time)],
                    none
                )
            end,
            Matches
        )
    end),
    ok.

%% Time of the newest PRIVMSG or NOTICE; events do not make a target active.
latest_time([#{cmd := Cmd, time := T} | _]) when Cmd =:= <<"PRIVMSG">>; Cmd =:= <<"NOTICE">> -> T;
latest_time([_ | Rest]) -> latest_time(Rest);
latest_time([]) -> 0.

%% The conversation partner is the latest entry's sender or recipient that is
%% not the requester's own account.
other_party(Mine, [#{account := Sender, target := Target, prefix := Prefix} | _]) ->
    case Sender =/= undefined andalso briskd_wire:fold(Sender) =:= Mine of
        true -> Target;
        false -> hd(binary:split(Prefix, <<"!">>))
    end.

%%% Message search (m:briskd_search, m:briskd_state_search)

-doc """
Fold `Fun(Table, Conversation, Seq, Entry, Acc)` over every stored message
(the `msg` class: `PRIVMSG`, `NOTICE`, `TAGMSG`) of every channel and direct
conversation. `m:briskd_search` rebuilds its index with it; it reads one
conversation at a time.
""".
-spec fold_messages(
    fun((channel_message | direct_message, term(), pos_integer(), map(), Acc) -> Acc), Acc
) -> Acc.
fold_messages(Fun, Acc0) ->
    lists:foldl(
        fun(Tab, Acc1) ->
            lists:foldl(
                fun(Conv, Acc2) ->
                    Rows = mnesia:dirty_select(Tab, [
                        {{Tab, {Conv, msg, '$1'}, '$2'}, [], [{{'$1', '$2'}}]}
                    ]),
                    lists:foldl(
                        fun
                            ({Seq, Entry}, Acc3) when is_integer(Seq), Seq > 0 ->
                                Fun(Tab, Conv, Seq, briskd_state_history:normalize(Entry), Acc3);
                            (_, Acc3) ->
                                Acc3
                        end,
                        Acc2,
                        Rows
                    )
                end,
                Acc1,
                briskd_state_history:conversations(Tab)
            )
        end,
        Acc0,
        [channel_message, direct_message]
    ).

-doc """
The conversations `Client` may search for `Target`, as
`{IndexName, {Table, Conversation}, ReplayName}`: a channel the client is a
member of; a nickname or account, for the direct conversation with it (the
client must be logged in); or `*`, for every channel the client is in and
every direct conversation of its account. `ReplayName` is the channel name
to deliver a result to, or `undefined` for a direct message (delivered to its
stored target). The same rules as `CHATHISTORY` (`access/2`).
""".
-spec search_scope(#client{}, binary()) ->
    {ok, [{binary(), {channel_message | direct_message, term()}, binary() | undefined}]}
    | error.
search_scope(#client{pid = Pid, channels = Keys}, <<"*">>) ->
    Channels = [
        {briskd_search:conv_id(channel_message, Key), {channel_message, Key}, Name}
     || Key <- Keys,
        [#channel{name = Name}] <- [mnesia:dirty_read(channel, Key)]
    ],
    Direct =
        case briskd_state_v3:account(Pid) of
            undefined ->
                [];
            Account ->
                Me = {account, briskd_wire:fold(Account)},
                [
                    {briskd_search:conv_id(direct_message, Pair), {direct_message, Pair}, undefined}
                 || {A, B} = Pair <- briskd_state_history:direct_conversations(),
                    A =:= Me orelse B =:= Me
                ]
        end,
    {ok, Channels ++ Direct};
search_scope(Client, Target) ->
    case access(Client, Target) of
        {ok, Name, {channel, Key}} ->
            {ok, [{briskd_search:conv_id(channel_message, Key), {channel_message, Key}, Name}]};
        {ok, _Name, {direct, Pair}} ->
            {ok, [{briskd_search:conv_id(direct_message, Pair), {direct_message, Pair}, undefined}]};
        error ->
            error
    end.

-doc """
The stored message `Seq` of conversation `{Table, Conversation}`, if it is
still in history.
""".
-spec search_entry({channel_message | direct_message, term()}, pos_integer()) ->
    {ok, map()} | error.
search_entry({Tab, Conv}, Seq) ->
    case mnesia:dirty_read(Tab, {Conv, msg, Seq}) of
        [{_, _, Entry}] -> {ok, briskd_state_history:normalize(Entry)};
        [] -> error
    end.

server() ->
    maps:get(name, briskd_config:current()).
