-module(ircd_state_history).
-export([
    valid_marker_target/1,
    chathistory/3,
    entry/7,
    find/2,
    markread/3,
    markread_on_join/3,
    note_channel/2,
    note_direct/4,
    note_event/5,
    note_event/6,
    note_user_event/5,
    event_tags/0,
    rename_markers/2,
    remote_marker/3,
    note_user_event/4,
    receive_remote_redact/3,
    redact/3,
    replay_entries/4,
    replay_on_join/3,
    parse_timestamp/1
]).
-include("ircd_state.hrl").
-include("ircd_account.hrl").

%% @doc Message history for draft/chathistory, draft/read-marker, and
%% draft/message-redaction.
%%
%% Channel history is the Mnesia `channel_history` table: newest-first entries
%% capped by `history_limit`. It survives restart only under `channels`
%% retention; `transient` retention clears it on startup. Direct-message
%% history is kept only between two logged-in accounts, in the Mnesia
%% `direct_history` table, with the same retention as channel history. Recording is
%% disabled with `"chathistory": false`. Bodies are never logged.
%%
%% An entry is a map: `cmd`, `prefix`, `text` (binary, or `{multiline, Lines}`
%% where each line is `{Concat, Text}`), `msgid`, `time` (ms since epoch),
%% `tags` (client-only tags), `account`, and `target` (wire spelling).
%% Entries written before this format are `{Command, Prefix, Text}` tuples.

%% @doc Build a history entry.
-spec entry(binary(), iodata(), term(), binary(), integer(), list(), undefined | binary()) -> map().
entry(Command, Prefix, Text, MsgId, Time, Tags, Account) ->
    #{
        cmd => Command,
        prefix => ircd_wire:retain(iolist_to_binary(Prefix)),
        text => retain_text(Text),
        msgid => MsgId,
        time => Time,
        tags => [{ircd_wire:retain(K), ircd_wire:retain(V)} || {K, V} <- Tags],
        account => Account
    }.

retain_text({multiline, Lines}) -> {multiline, [{C, ircd_wire:retain(T)} || {C, T} <- Lines]};
retain_text(Text) -> ircd_wire:retain(Text).

enabled() ->
    maps:get(chathistory, persistent_term:get({ircd_state, config}), true).

limit() ->
    ircd_state:history_limit().

%% @doc Record an accepted channel PRIVMSG or NOTICE.
-spec note_channel(binary(), map()) -> ok.
note_channel(Key, #{cmd := Command} = Entry) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>; Command =:= <<"TAGMSG">>
->
    case enabled() of
        true ->
            Existing = channel_entries(Key),
            mnesia:dirty_write(#channel_history{
                channel = Key, entries = trim([Entry | Existing])
            }),
            ok;
        false ->
            ok
    end;
note_channel(_Key, _Entry) ->
    ok.

%% @doc Record a channel event (JOIN, PART, KICK, TOPIC, MODE) for
%% draft/event-playback. `Params` are the parameters after the channel name.
-spec note_event(binary(), binary(), iodata(), [binary()], none | binary()) -> ok.
note_event(Key, Command, Prefix, Params, Text) ->
    {_, Meta} = event_tags(),
    store_event(Key, Command, Prefix, Params, Text, Meta).

%% @doc Like note_event/5 with the `msgid` and `time` already sent on the live
%% line (from event_tags/0), so history replays the same identifiers.
-spec note_event(binary(), binary(), iodata(), [binary()], none | binary(), {binary(), integer()}) ->
    ok.
note_event(Key, Command, Prefix, Params, Text, Meta) ->
    store_event(Key, Command, Prefix, Params, Text, Meta).

%% @doc Tags for a live channel event plus the metadata to store with it.
%% Events carry a `msgid` (message-tags) and `time` (server-time) so
%% draft/event-playback replays them with the identifiers clients saw.
-spec event_tags() -> {list(), {binary(), integer()}}.
event_tags() ->
    MsgId = ircd_state_send:msgid(),
    Now = erlang:system_time(millisecond),
    {[{<<"msgid">>, MsgId}, {<<"time">>, ircd_state_send:time_value(Now)}], {MsgId, Now}}.

%% @doc Record a QUIT or NICK in the history of every channel the user is on.
%% These lines have no channel parameter when replayed.
-spec note_user_event([binary()], binary(), iodata(), binary()) -> ok.
note_user_event(Keys, Command, Prefix, Text) ->
    {_, Meta} = event_tags(),
    note_user_event(Keys, Command, Prefix, Text, Meta).

-spec note_user_event([binary()], binary(), iodata(), binary(), {binary(), integer()}) -> ok.
note_user_event(Keys, Command, Prefix, Text, Meta) ->
    lists:foreach(fun(Key) -> store_event(Key, Command, Prefix, notarget, Text, Meta) end, Keys).

store_event(Key, Command, Prefix, Params, Text, {MsgId, Time}) ->
    case enabled() of
        true ->
            Account =
                case lists:keyfind(<<"account">>, 1, ircd_state_send:source_tags(Prefix)) of
                    {_, Name} -> Name;
                    false -> undefined
                end,
            Entry = (entry(
                Command,
                Prefix,
                Text,
                MsgId,
                Time,
                [],
                Account
            ))#{
                params => [ircd_wire:retain(P) || P <- params_list(Params)],
                notarget => Params =:= notarget
            },
            case mnesia:dirty_read(channel_history, Key) of
                [#channel_history{entries = Entries}] ->
                    mnesia:dirty_write(#channel_history{
                        channel = Key, entries = trim([Entry | Entries])
                    });
                [] ->
                    mnesia:dirty_write(#channel_history{channel = Key, entries = [Entry]})
            end,
            ok;
        false ->
            ok
    end.

%% Keep the newest `history_limit` messages (PRIVMSG, NOTICE, TAGMSG) and,
%% separately, the newest `history_limit` events, so draft/event-playback
%% entries never push messages out of history.
trim(Entries) ->
    trim(Entries, limit(), limit(), []).

trim([], _Messages, _Events, Acc) ->
    lists:reverse(Acc);
trim([#{cmd := Cmd} = Entry | Rest], Messages, Events, Acc) when
    Cmd =:= <<"PRIVMSG">>; Cmd =:= <<"NOTICE">>; Cmd =:= <<"TAGMSG">>
->
    case Messages of
        0 -> trim(Rest, 0, Events, Acc);
        _ -> trim(Rest, Messages - 1, Events, [Entry | Acc])
    end;
trim([Entry | Rest], Messages, Events, Acc) when is_map(Entry) ->
    case Events of
        0 -> trim(Rest, Messages, 0, Acc);
        _ -> trim(Rest, Messages, Events - 1, [Entry | Acc])
    end;
trim([Legacy | Rest], Messages, Events, Acc) ->
    trim([normalize(Legacy) | Rest], Messages, Events, Acc).

params_list(notarget) -> [];
params_list(Params) -> Params.

%% Messages a client may receive from history. Without draft/event-playback
%% only PRIVMSG and NOTICE are replayed (IRCv3 chathistory).
playable(Pid, Entries) ->
    case ircd_cap:enabled(Pid, <<"draft/event-playback">>) of
        true -> Entries;
        false -> [E || #{cmd := C} = E <- Entries, C =:= <<"PRIVMSG">> orelse C =:= <<"NOTICE">>]
    end.

%% @doc Record a direct message when at least one side is logged in. Each
%% side is `{Account | undefined, Nick}`: a logged-in participant is keyed by
%% account, the other by nickname. Only logged-in users can read history, so a
%% nickname-keyed side never reads it, even if someone else takes the nick.
-spec note_direct(
    {undefined | binary(), binary()}, {undefined | binary(), binary()}, binary(), map()
) ->
    ok.
note_direct({FromAccount, _} = From, {ToAccount, _} = To, Target, #{cmd := Command} = Entry) when
    (is_binary(FromAccount) orelse is_binary(ToAccount)),
    (Command =:= <<"PRIVMSG">> orelse Command =:= <<"NOTICE">> orelse Command =:= <<"TAGMSG">>)
->
    case enabled() of
        true ->
            Key = dm_key(party(From), party(To)),
            Existing = dm_entries(Key),
            Stored = Entry#{target => ircd_wire:retain(Target)},
            mnesia:dirty_write(#direct_history{
                key = Key, entries = trim([Stored | Existing])
            }),
            ok;
        false ->
            ok
    end;
note_direct(_, _, _, _) ->
    ok.

%% A conversation participant: `{account, Folded}` or `{nick, Folded}`.
party({undefined, Nick}) -> {nick, ircd_wire:fold(Nick)};
party({Account, _Nick}) -> {account, ircd_wire:fold(Account)}.

dm_key(A, B) ->
    list_to_tuple(lists:sort([A, B])).

channel_entries(Key) ->
    case mnesia:dirty_read(channel_history, Key) of
        [#channel_history{entries = Entries}] -> [normalize(E) || E <- Entries];
        [] -> []
    end.

dm_entries(Key) ->
    case mnesia:dirty_read(direct_history, Key) of
        [#direct_history{entries = Entries}] -> Entries;
        [] -> []
    end.

normalize({Command, Prefix, Text}) ->
    #{
        cmd => Command,
        prefix => Prefix,
        text => Text,
        msgid => undefined,
        time => 0,
        tags => [],
        account => undefined
    };
normalize(Entry) when is_map(Entry) ->
    Entry.

%% @doc Find an entry by msgid in a channel or direct-message history.
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

entries({channel, Key}) -> channel_entries(Key);
entries({direct, Key}) -> dm_entries(Key).

remove(Source, MsgId) ->
    Kept = [E || E <- entries(Source), maps:get(msgid, E) =/= MsgId],
    case Source of
        {channel, Key} -> mnesia:dirty_write(#channel_history{channel = Key, entries = Kept});
        {direct, Key} -> mnesia:dirty_write(#direct_history{key = Key, entries = Kept})
    end,
    ok.

%%% Replay

%% @doc Replay stored channel history to a joining client under `channels`
%% retention. Clients with draft/chathistory fetch history themselves.
-spec replay_on_join(binary(), binary(), pid()) -> ok.
replay_on_join(Key, Name, Pid) ->
    case
        ircd_state:retention() =:= channels andalso
            not ircd_cap:enabled(Pid, <<"draft/chathistory">>)
    of
        true ->
            case playable(Pid, lists:reverse(channel_entries(Key))) of
                [] ->
                    ok;
                Entries ->
                    ircd_state_send:with_batch(Pid, <<"chathistory">>, [Name], [], fun() ->
                        replay_entries(Pid, Name, Entries, server())
                    end)
            end;
        false ->
            ok
    end.

%% @doc Send entries (oldest first) to Pid. `Name` is the channel, or
%% `undefined` to use each entry's stored target.
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
            ircd_state_batch:deliver_multiline(Pid, Prefix, Command, Target, Lines, Tags, replay);
        _ ->
            ircd_state_send:send(Pid, Prefix, Command, Middle, Text, Tags)
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
            _ -> [{<<"time">>, ircd_state_send:time_value(Time)}]
        end,
    Account =
        case maps:get(account, Entry, undefined) of
            undefined -> [];
            Name -> [{<<"account">>, Name}]
        end,
    Tags ++ Id ++ Stamp ++ Account.

%%% CHATHISTORY

%% @doc `CHATHISTORY <subcommand> ...` (draft/chathistory).
-spec chathistory([binary()], #client{}, binary()) -> ok.
chathistory([Sub | Rest], #client{pid = Pid} = Client, Server) ->
    Upper = string:uppercase(Sub),
    Max = limit(),
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
            ircd_state_send:fail(
                Pid, <<"CHATHISTORY">>, <<"INVALID_PARAMS">>, [Known], <<"Insufficient parameters">>
            );
        _ ->
            ircd_state_send:fail(
                Pid, <<"CHATHISTORY">>, <<"INVALID_PARAMS">>, [Sub], <<"Unknown command">>
            )
    end,
    _ = Server,
    ok;
chathistory([], Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"CHATHISTORY">>], <<"Not enough parameters">>
    ).

msgreftype(Pid, Sub, Target) ->
    ircd_state_send:fail(
        Pid,
        <<"CHATHISTORY">>,
        <<"INVALID_MSGREFTYPE">>,
        [Sub, Target],
        <<"Unknown message reference type">>
    ).

invalid(Pid, Sub) ->
    ircd_state_send:fail(
        Pid, <<"CHATHISTORY">>, <<"INVALID_PARAMS">>, [Sub], <<"Invalid parameters">>
    ).

%% Resolve a target the client may read, then call Fun with oldest-first entries.
with_target(#client{pid = Pid} = Client, Sub, Target, Fun) ->
    case access(Client, Target) of
        {ok, Name, Source} ->
            Fun(Name, playable(Pid, lists:reverse(entries(Source))));
        error ->
            ircd_state_send:fail(
                Pid,
                <<"CHATHISTORY">>,
                <<"INVALID_TARGET">>,
                [Sub, Target],
                <<"Messages could not be retrieved">>
            )
    end.

%% Channel history is readable by current members. Direct history needs the
%% requester to be logged in; the peer is the target's account, or an account
%% of that name when the target is offline.
access(#client{pid = Pid}, Target) ->
    case ircd_wire:channel(Target) of
        true ->
            case mnesia:dirty_read(channel, ircd_wire:fold(Target)) of
                [#channel{key = Key, name = Name, members = Members}] when
                    is_map_key(Pid, Members)
                ->
                    {ok, Name, {channel, Key}};
                _ ->
                    error
            end;
        false ->
            case ircd_state_v3:account(Pid) of
                undefined ->
                    error;
                Mine ->
                    Theirs = party({peer_account(Target), Target}),
                    {ok, Target, {direct, dm_key(party({Mine, <<>>}), Theirs)}}
            end
    end.

peer_account(Nick) ->
    case ircd_state_client:find_nick(Nick) of
        #client{pid = Pid} ->
            ircd_state_v3:account(Pid);
        undefined ->
            case ircd_state_v3:remote_account(ircd_wire:fold(Nick)) of
                undefined ->
                    case ircd_account:find(Nick) of
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
selector(_Sub, Sel, Entries) ->
    case parse_selector(Sel) of
        {time, T} ->
            {ok, {time, T}};
        {msgid, Id} ->
            case index_of(Id, Entries, 1) of
                {ok, I} -> {ok, {index, I}};
                error -> error
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

%% @doc Parse `YYYY-MM-DDThh:mm:ss[.sss]Z` to milliseconds since the epoch.
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
    lists:zip(lists:seq(1, length(Entries)), Entries).

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
        case ircd_wire:channel(Name) of
            true -> Name;
            false -> undefined
        end,
    ircd_state_send:with_batch(Pid, <<"chathistory">>, [Name], End, fun() ->
        replay_entries(Pid, ReplayName, Selected, Server)
    end),
    ok.

targets(#client{pid = Pid, channels = Keys}, From, To, N) ->
    Channels = [
        {Name, latest_time(channel_entries(Key))}
     || Key <- Keys,
        [#channel{name = Name}] <- [mnesia:dirty_read(channel, Key)]
    ],
    Direct =
        case ircd_state_v3:account(Pid) of
            undefined ->
                [];
            Account ->
                Mine = ircd_wire:fold(Account),
                Me = {account, Mine},
                [
                    {other_party(Mine, Entries), latest_time(Entries)}
                 || {A, B} = Pair <- mnesia:dirty_all_keys(direct_history),
                    A =:= Me orelse B =:= Me,
                    Entries <- [dm_entries(Pair)],
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
    ircd_state_send:with_batch(Pid, <<"draft/chathistory-targets">>, [], [], fun() ->
        lists:foreach(
            fun({Target, Time}) ->
                ircd_state_send:send(
                    Pid,
                    server(),
                    <<"CHATHISTORY">>,
                    [<<"TARGETS">>, Target, ircd_state_send:time_value(Time)],
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
    case Sender =/= undefined andalso ircd_wire:fold(Sender) =:= Mine of
        true -> Target;
        false -> hd(binary:split(Prefix, <<"!">>))
    end.

%%% MARKREAD

%% @doc `MARKREAD <target> [timestamp=...]` (draft/read-marker). Markers are
%% stored per account (Mnesia) or, without an account, per connection.
-spec markread([binary()], #client{}, binary()) -> ok.
markread([], #client{pid = Pid}, _Server) ->
    ircd_state_send:fail(
        Pid, <<"MARKREAD">>, <<"NEED_MORE_PARAMS">>, [], <<"Missing parameters">>
    );
markread([Target | Rest], #client{pid = Pid} = Client, Server) ->
    %% Only a channel or nickname can carry a marker, so a client cannot
    %% create stored rows for arbitrary strings.
    case valid_marker_target(Target) of
        true ->
            markread_valid([Target | Rest], Client, Server);
        false ->
            ircd_state_send:fail(
                Pid, <<"MARKREAD">>, <<"INVALID_PARAMS">>, [Target], <<"Invalid target">>
            )
    end.

%% @doc A read marker target is a channel name or a nickname.
-spec valid_marker_target(binary()) -> boolean().
valid_marker_target(Target) ->
    ircd_wire:channel(Target) orelse ircd_wire:nickname(Target, ircd_state:nicklen()).

markread_valid([Target], #client{pid = Pid}, Server) ->
    send_marker(Pid, Server, Target, get_marker(Pid, Target));
markread_valid([Target, <<"timestamp=", Value/binary>> | _], #client{pid = Pid}, Server) ->
    case parse_timestamp(Value) of
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
            ircd_state_send:fail(
                Pid, <<"MARKREAD">>, <<"INVALID_PARAMS">>, [Value], <<"Invalid parameters">>
            )
    end;
markread_valid([_Target, Other | _], #client{pid = Pid}, _Server) ->
    ircd_state_send:fail(
        Pid, <<"MARKREAD">>, <<"INVALID_PARAMS">>, [Other], <<"Invalid parameters">>
    ).

%% @doc After JOIN, send the channel's read marker to a read-marker client.
-spec markread_on_join(pid(), binary(), binary()) -> ok.
markread_on_join(Pid, Name, Server) ->
    case ircd_cap:enabled(Pid, <<"draft/read-marker">>) of
        true -> send_marker(Pid, Server, Name, get_marker(Pid, Name));
        false -> ok
    end.

send_marker(Pid, Server, Target, Time) ->
    Value =
        case Time of
            undefined -> <<"*">>;
            _ -> <<"timestamp=", (ircd_state_send:time_value(Time))/binary>>
        end,
    ircd_state_send:send(Pid, Server, <<"MARKREAD">>, [Target, Value], none).

get_marker(Pid, Target) ->
    case ircd_state_v3:account(Pid) of
        undefined ->
            maps:get(ircd_wire:fold(Target), ircd_conn:get(Pid, markread, #{}), undefined);
        Account ->
            case
                mnesia:dirty_read(read_marker, {ircd_wire:fold(Account), ircd_wire:fold(Target)})
            of
                [#read_marker{time = Time}] -> Time;
                [] -> undefined
            end
    end.

put_marker(Pid, Target, Time) ->
    case ircd_state_v3:account(Pid) of
        undefined ->
            Markers = ircd_conn:get(Pid, markread, #{}),
            ircd_conn:put(Pid, markread, Markers#{ircd_wire:fold(Target) => Time});
        Account ->
            Folded = ircd_wire:fold(Account),
            mnesia:dirty_write(#read_marker{key = {Folded, ircd_wire:fold(Target)}, time = Time}),
            ircd_state_sync:markread(Folded, ircd_wire:fold(Target), Time)
    end.

%% @doc Move every account's read marker for a renamed channel.
-spec rename_markers(binary(), binary()) -> ok.
rename_markers(OldKey, NewKey) ->
    lists:foreach(
        fun
            ({Account, Target} = Key) when Target =:= OldKey ->
                [#read_marker{time = Time}] = mnesia:dirty_read(read_marker, Key),
                mnesia:dirty_delete(read_marker, Key),
                mnesia:dirty_write(#read_marker{key = {Account, NewKey}, time = Time});
            (_) ->
                ok
        end,
        mnesia:dirty_all_keys(read_marker)
    ).

%% @doc Apply a read marker that moved forward on another server and tell
%% this server's read-marker clients of that account.
-spec remote_marker(binary(), binary(), integer()) -> updated | unchanged.
remote_marker(Account, Target, Time) ->
    Key = {ircd_wire:fold(Account), ircd_wire:fold(Target)},
    case mnesia:dirty_read(read_marker, Key) of
        [#read_marker{time = Stored}] when Stored >= Time ->
            unchanged;
        _ ->
            mnesia:dirty_write(#read_marker{key = Key, time = Time}),
            Server = server(),
            lists:foreach(
                fun({Pid, Map}) ->
                    case maps:get(account, Map, undefined) of
                        Name when is_binary(Name) ->
                            case
                                ircd_wire:fold(Name) =:= element(1, Key) andalso
                                    ircd_cap:enabled(Pid, <<"draft/read-marker">>)
                            of
                                true -> send_marker(Pid, Server, Target, Time);
                                false -> ok
                            end;
                        _ ->
                            ok
                    end
                end,
                ets:tab2list(ircd_conn)
            ),
            updated
    end.

%% Connections that share the requester's account and negotiated read-marker.
same_account(Pid) ->
    case ircd_state_v3:account(Pid) of
        undefined ->
            [Pid];
        Account ->
            Folded = ircd_wire:fold(Account),
            [
                Other
             || {Other, Map} <- ets:tab2list(ircd_conn),
                is_binary(maps:get(account, Map, undefined)),
                ircd_wire:fold(maps:get(account, Map)) =:= Folded,
                Other =:= Pid orelse ircd_cap:enabled(Other, <<"draft/read-marker">>)
            ]
    end.

%%% REDACT

%% @doc `REDACT <target> <msgid> [:<reason>]` (draft/message-redaction). The
%% sender's account (or a channel operator, for a channel) may redact. The
%% entry is removed from history and the REDACT goes to capable recipients.
-spec redact([binary()], #client{}, binary()) -> ok.
redact([Target, MsgId | Rest], #client{pid = Pid} = Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    case ircd_wire:channel(Target) of
        true -> redact_channel(Target, MsgId, Reason, Client, Server);
        false -> redact_direct(Target, MsgId, Reason, Client, Server)
    end,
    _ = Pid,
    ok;
redact(_, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"REDACT">>], <<"Not enough parameters">>).

redact_channel(Target, MsgId, Reason, #client{pid = Pid} = Client, _Server) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Target)) of
        [#channel{key = Key, name = Name, members = Members}] when is_map_key(Pid, Members) ->
            case find({channel, Key}, MsgId) of
                {ok, Entry} ->
                    Operator = lists:member(operator, maps:get(Pid, Members)),
                    case Operator orelse own_entry(Pid, Client, Entry) of
                        true ->
                            remove({channel, Key}, MsgId),
                            Prefix = ircd_state_send:prefix(Client),
                            Recipients = [
                                P
                             || P <- maps:keys(Members),
                                ircd_cap:enabled(P, <<"draft/message-redaction">>)
                            ],
                            ircd_state_send:broadcast(
                                Recipients, Prefix, <<"REDACT">>, [Name, MsgId], Reason
                            ),
                            ircd_state_link:server_broadcast(
                                ircd_wire:line(Prefix, <<"REDACT">>, [Name, MsgId], Reason)
                            );
                        false ->
                            forbidden(Pid, Name, MsgId)
                    end;
                error ->
                    unknown_msgid(Pid, Name, MsgId)
            end;
        _ ->
            ircd_state_send:fail(
                Pid,
                <<"REDACT">>,
                <<"INVALID_TARGET">>,
                [Target],
                [<<"You cannot delete messages from ">>, Target]
            )
    end.

redact_direct(Target, MsgId, Reason, #client{pid = Pid} = Client, _Server) ->
    case access(Client, Target) of
        {ok, _Name, {direct, Key} = Source} ->
            case find(Source, MsgId) of
                {ok, Entry} ->
                    case own_entry(Pid, Client, Entry) of
                        true ->
                            remove({direct, Key}, MsgId),
                            Prefix = ircd_state_send:prefix(Client),
                            Self = [Pid || ircd_cap:enabled(Pid, <<"draft/message-redaction">>)],
                            ircd_state_send:broadcast(
                                Self, Prefix, <<"REDACT">>, [Target, MsgId], Reason
                            ),
                            case ircd_state_client:find_nick(Target) of
                                #client{pid = Other, nick = Nick} ->
                                    case ircd_cap:enabled(Other, <<"draft/message-redaction">>) of
                                        true ->
                                            ircd_state_send:send(
                                                Other, Prefix, <<"REDACT">>, [Nick, MsgId], Reason
                                            );
                                        false ->
                                            ok
                                    end;
                                undefined ->
                                    ok
                            end;
                        false ->
                            forbidden(Pid, Target, MsgId)
                    end;
                error ->
                    unknown_msgid(Pid, Target, MsgId)
            end;
        _ ->
            ircd_state_send:fail(
                Pid,
                <<"REDACT">>,
                <<"INVALID_TARGET">>,
                [Target],
                [<<"You cannot delete messages from ">>, Target]
            )
    end.

%% The sender may redact their own message: same account, or the same
%% nick!user@host when the message was sent without an account.
own_entry(Pid, Client, #{account := Account, prefix := Prefix}) ->
    Mine = ircd_state_v3:account(Pid),
    case {Mine, Account} of
        {undefined, undefined} ->
            Prefix =:= iolist_to_binary(ircd_state_send:prefix(Client));
        {_, undefined} ->
            false;
        {undefined, _} ->
            false;
        _ ->
            ircd_wire:fold(Mine) =:= ircd_wire:fold(Account)
    end.

forbidden(Pid, Target, MsgId) ->
    ircd_state_send:fail(
        Pid,
        <<"REDACT">>,
        <<"REDACT_FORBIDDEN">>,
        [Target, MsgId],
        <<"You are not authorised to delete this message">>
    ).

unknown_msgid(Pid, Target, MsgId) ->
    ircd_state_send:fail(
        Pid,
        <<"REDACT">>,
        <<"UNKNOWN_MSGID">>,
        [Target, MsgId],
        <<"This message does not exist or is too old">>
    ).

%% @doc `:nick!user@host REDACT <channel> <msgid> [:reason]` from a peer.
-spec receive_remote_redact(binary(), binary(), [binary()]) -> ok | {error, term()}.
receive_remote_redact(Peer, Prefix, [Target, MsgId | Rest]) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    case mnesia:dirty_read(channel, ircd_wire:fold(Target)) of
        [#channel{key = Key, name = Name, members = Members}] ->
            remove({channel, Key}, MsgId),
            Recipients = [
                P
             || P <- maps:keys(Members), ircd_cap:enabled(P, <<"draft/message-redaction">>)
            ],
            ircd_state_send:broadcast(Recipients, Prefix, <<"REDACT">>, [Name, MsgId], Reason);
        [] ->
            ok
    end,
    ircd_state_link:relay_except(
        Peer, ircd_wire:line(Prefix, <<"REDACT">>, [Target, MsgId], Reason)
    ),
    ok;
receive_remote_redact(_, _, _) ->
    {error, invalid_redact_message}.

server() ->
    maps:get(name, persistent_term:get({ircd_state, config})).
