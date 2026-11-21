-module(ircd_state_history).
-export([
    channel_history/1,
    delete_channel_history/1,
    erase_account/1,
    has_channel_history/1,
    history_channels/0,
    init_storage/0,
    direct_conversations/0,
    direct_history/1,
    replace_direct/2,
    replace_channel/2,
    valid_marker_target/1,
    chathistory/3,
    entry/7,
    find/2,
    fold_messages/2,
    search_scope/2,
    search_entry/2,
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

%% One stored message or event. `msgid` is `undefined` for a line that
%% arrived without one; events (JOIN, PART, ...) add `params` and `notarget`.
-type entry() :: #{
    cmd := binary(),
    prefix := binary(),
    text := ircd_state_channel:body(),
    msgid := undefined | binary(),
    time := integer(),
    tags := [{binary(), undefined | binary()}],
    account := undefined | binary(),
    params => [binary()],
    notarget => boolean()
}.
-export_type([entry/0]).

-moduledoc """
Message history for
[draft/chathistory](https://ircv3.net/specs/extensions/chathistory),
draft/event-playback,
[draft/read-marker](https://ircv3.net/specs/extensions/read-marker), and
[draft/message-redaction](https://ircv3.net/specs/extensions/message-redaction).

Runs inside `m:ircd_state`. Channel history is the Mnesia `channel_message`
table (ordered_set), one row per entry keyed by folded channel name, class
(message or event), and sequence number, so recording a message writes one
small row; a per-channel index (ETS `ircd_history_index`) keeps the last
sequence number and the counts used to drop the oldest entry. Direct-message
history is the Mnesia `direct_message` table, stored the same way and keyed
by the sorted pair of participants; a message is recorded only when at least
one side is logged in, and only a logged-in user can read it. Both are capped
by `history_limit` (`ircd_state:history_limit/0`): the newest `history_limit`
messages (`PRIVMSG`, `NOTICE`, `TAGMSG`) and, separately, the newest
`history_limit` events, so event-playback never pushes messages out. History
survives restart only under `channels` retention; `transient` retention
clears both tables on startup. Recording is disabled with
`"chathistory": false`. Bodies are never logged.

An entry is a map: `cmd`, `prefix`, `text` (binary, or `{multiline, Lines}`
where each line is `{Concat, Text}`), `msgid`, `time` (ms since epoch),
`tags` (client-only tags), `account`, and, for direct messages, `target`
(wire spelling). Events also carry `params` and `notarget`. Entries written
before this format are `{Command, Prefix, Text}` tuples and are still read.

Read markers are the Mnesia `read_marker` table, keyed by folded account and
target (bounded by `max_read_markers` per account), and survive every restart;
a connection without an account keeps them in `m:ircd_conn` until it
disconnects. Direct-message conversations are bounded per account by
`max_direct_conversations`. Markers only move forward and are synchronized to
peers through `m:ircd_state_sync`.
""".

-doc """
Build a history entry map from a message's command, sender prefix, text
(binary or `{multiline, Lines}`), `msgid`, time in milliseconds,
client-only tags, and sender account.

Stored binaries are copied (`ircd_wire:retain/1`) so they do not pin a
receive buffer.
""".
-spec entry(
    binary(),
    iodata(),
    ircd_state_channel:body(),
    undefined | binary(),
    integer(),
    [{binary(), undefined | binary()}],
    undefined | binary()
) -> entry().
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
    maps:get(chathistory, ircd_config:current(), true).

limit() ->
    ircd_state:history_limit().

-doc """
Record an accepted `PRIVMSG`, `NOTICE`, or `TAGMSG` entry in the history of
the channel with folded name `Key`. Other commands and disabled history are
ignored.
""".
-spec note_channel(binary(), map()) -> ok.
note_channel(Key, #{cmd := <<"TAGMSG">>, tags := Tags} = Entry) ->
    case is_ephemeral_tagmsg(Tags) of
        true ->
            ok;
        false ->
            note_channel_entry(Key, Entry)
    end;
note_channel(Key, #{cmd := Command} = Entry) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>
->
    note_channel_entry(Key, Entry);
note_channel(_Key, _Entry) ->
    ok.

note_channel_entry(Key, Entry) ->
    case enabled() of
        true -> append_channel(Key, Entry);
        false -> ok
    end.

%% Typing indicators are ephemeral and must not pollute message history or
%% push real messages/reactions out of `history_limit`.
is_ephemeral_tagmsg(Tags) when is_list(Tags) ->
    HasTyping =
        lists:keymember(<<"+typing">>, 1, Tags) orelse
            lists:keymember(<<"+draft/typing">>, 1, Tags),
    HasReact = lists:keymember(<<"+draft/react">>, 1, Tags),
    HasTyping andalso not HasReact;
is_ephemeral_tagmsg(_) ->
    false.

is_reaction_entry(#{cmd := <<"TAGMSG">>, tags := Tags}) when is_list(Tags) ->
    lists:keymember(<<"+draft/react">>, 1, Tags) andalso
        lists:keymember(<<"+draft/reply">>, 1, Tags);
is_reaction_entry(_) ->
    false.

-doc """
Record a channel event (`JOIN`, `PART`, `KICK`, `TOPIC`, `MODE`) for
draft/event-playback with a fresh `msgid` and time. `Params` are the
parameters after the channel name and `Text` the trailing parameter or
`none`.
""".
-spec note_event(binary(), binary(), iodata(), [binary()], none | binary()) -> ok.
note_event(Key, Command, Prefix, Params, Text) ->
    {_, Meta} = event_tags(),
    store_event(Key, Command, Prefix, Params, Text, Meta).

-doc """
Like `note_event/5` with the `msgid` and `time` already sent on the live
line (from `event_tags/0`), so history replays the same identifiers.
""".
-spec note_event(binary(), binary(), iodata(), [binary()], none | binary(), {binary(), integer()}) ->
    ok.
note_event(Key, Command, Prefix, Params, Text, Meta) ->
    store_event(Key, Command, Prefix, Params, Text, Meta).

-doc """
Tags for a live channel event plus the `{MsgId, TimeMillis}` to store with
it. Events carry a `msgid` (message-tags) and `time` (server-time) so
draft/event-playback replays them with the identifiers clients saw.
""".
-spec event_tags() -> {list(), {binary(), integer()}}.
event_tags() ->
    MsgId = ircd_state_send:msgid(),
    Now = erlang:system_time(millisecond),
    {[{<<"msgid">>, MsgId}, {<<"time">>, ircd_state_send:time_value(Now)}], {MsgId, Now}}.

-doc """
Record a `QUIT` or `NICK` with a fresh `msgid` and time in the history of
every channel in `Keys` (folded names). These lines have no channel
parameter when replayed.
""".
-spec note_user_event([binary()], binary(), iodata(), none | binary()) -> ok.
note_user_event(Keys, Command, Prefix, Text) ->
    {_, Meta} = event_tags(),
    note_user_event(Keys, Command, Prefix, Text, Meta).

-doc """
Like `note_user_event/4` with the `{MsgId, TimeMillis}` already sent on the
live line (from `event_tags/0`).
""".
-spec note_user_event([binary()], binary(), iodata(), none | binary(), {binary(), integer()}) ->
    ok.
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
            append_channel(Key, Entry);
        false ->
            ok
    end.

params_list(notarget) -> [];
params_list(Params) -> Params.

%% Messages a client may receive from history. Without draft/event-playback
%% PRIVMSG, NOTICE, and persistent reaction TAGMSGs (for message-tags clients)
%% are replayed.
playable(Pid, Entries) ->
    case ircd_cap:enabled(Pid, <<"draft/event-playback">>) of
        true ->
            Entries;
        false ->
            HasTags = ircd_cap:enabled(Pid, <<"message-tags">>),
            [
                E
             || #{cmd := C} = E <- Entries,
                C =:= <<"PRIVMSG">> orelse C =:= <<"NOTICE">> orelse
                    (HasTags andalso is_reaction_entry(E))
            ]
    end.

-doc """
Record a direct `PRIVMSG`, `NOTICE`, or `TAGMSG` when at least one side is
logged in. Each side is `{Account | undefined, Nick}`: a logged-in
participant is keyed by folded account, the other by folded nickname.
`Target` (wire spelling) is stored in the entry. Only logged-in users can
read history, so a nickname-keyed side never reads it, even if someone else
takes the nick.
""".
-spec note_direct(
    {undefined | binary(), binary()}, {undefined | binary(), binary()}, binary(), map()
) ->
    ok.
note_direct({FromAccount, _} = From, {ToAccount, _} = To, Target, #{cmd := Command} = Entry) when
    (is_binary(FromAccount) orelse is_binary(ToAccount)),
    (Command =:= <<"PRIVMSG">> orelse Command =:= <<"NOTICE">> orelse Command =:= <<"TAGMSG">>)
->
    Skip = Command =:= <<"TAGMSG">> andalso is_ephemeral_tagmsg(maps:get(tags, Entry, [])),
    case enabled() andalso not Skip of
        true ->
            PartyA = party(From),
            PartyB = party(To),
            Key = dm_key(PartyA, PartyB),
            case has(direct_message, Key) of
                false ->
                    prune_direct_conversations(PartyA, Key),
                    prune_direct_conversations(PartyB, Key);
                true ->
                    ok
            end,
            append(direct_message, Key, Entry#{target => ircd_wire:retain(Target)});
        false ->
            ok
    end;
note_direct(_, _, _, _) ->
    ok.

-doc """
Remove what the account `Folded` (its folded name) wrote from stored
history, for "Delete my data": its messages in every channel history, its
messages in its direct conversations, and every direct conversation whose
other side is a nickname (only the account could read those). A
conversation with another account keeps that account's own messages.
Entries stored by older releases as tuples carry no account and are kept.
Returns the number of channel and direct messages removed. Call from
`m:ircd_state`.
""".
-spec erase_account(binary()) -> #{channel := non_neg_integer(), direct := non_neg_integer()}.
erase_account(Folded) ->
    Mine = fun
        (#{account := A}) when is_binary(A) -> ircd_wire:fold(A) =:= Folded;
        (_) -> false
    end,
    Channel = lists:sum([
        begin
            {Gone, Kept} = lists:partition(Mine, Entries),
            case Gone of
                [] -> ok;
                _ -> replace_channel(Key, Kept)
            end,
            length(Gone)
        end
     || Key <- history_channels(),
        Entries <- [channel_entries(Key)]
    ]),
    Me = {account, Folded},
    Direct = lists:sum([
        begin
            Entries = dm_entries(Key),
            {Gone, Kept} = lists:partition(Mine, Entries),
            case {Other, Gone, Kept} of
                %% Only the account could read a conversation with a nick.
                {{nick, _}, _, _} -> delete(direct_message, Key);
                {_, [], _} -> ok;
                {_, _, []} -> delete(direct_message, Key);
                _ -> replace(direct_message, Key, Kept)
            end,
            length(Gone)
        end
     || {A, B} = Key <- dm_conversations(),
        Other <- [
            if
                A =:= Me -> B;
                B =:= Me -> A;
                true -> none
            end
        ],
        Other =/= none
    ]),
    #{channel => Channel, direct => Direct}.

%% A conversation participant: `{account, Folded}` or `{nick, Folded}`.
party({undefined, Nick}) -> {nick, ircd_wire:fold(Nick)};
party({Account, _Nick}) -> {account, ircd_wire:fold(Account)}.

dm_key(A, B) ->
    list_to_tuple(lists:sort([A, B])).

prune_direct_conversations({account, _} = Party, KeepingKey) ->
    Max = maps:get(
        max_direct_conversations, ircd_config:current_or_empty(), 200
    ),
    Convos = [
        {dm_latest_time(Key), Key}
     || Key <- dm_conversations(),
        Key =/= KeepingKey,
        element(1, Key) =:= Party orelse element(2, Key) =:= Party
    ],
    Excess = length(Convos) - (Max - 1),
    case Excess > 0 of
        true ->
            Oldest = lists:sublist(lists:sort(Convos), Excess),
            lists:foreach(
                fun({_, OldKey}) -> delete(direct_message, OldKey) end,
                Oldest
            );
        false ->
            ok
    end;
prune_direct_conversations(_, _) ->
    ok.

%%% History storage: one row per entry.
%%
%% Channel history is `channel_message`, keyed {FoldedChannel, Class, Seq};
%% direct-message history is `direct_message`, keyed {PartyPair, Class, Seq}.
%% Class is `msg` or `event` (each trimmed to `history_limit`), and Seq
%% orders a conversation's entries. Appending writes one small row; the
%% older formats (`channel_history`, `direct_history`: one row per
%% conversation holding its whole list) were rewritten for every message and
%% are only read to migrate them. Match specifications are written as plain
%% tuples ('_' and '$N' do not fit the record field types) and bind the
%% conversation, so ordered_set selects stay within it.

-define(INDEX, ircd_history_index).

-doc """
Create the history index (per conversation: last sequence number and entry
counts per class) and move rows of the older one-row-per-conversation
tables, `channel_history` and `direct_history`, into `channel_message` and
`direct_message`. Call from `m:ircd_state`'s `init/1`, which owns the index.
""".
-spec init_storage() -> ok.
init_storage() ->
    _ =
        case ets:whereis(?INDEX) of
            undefined -> ets:new(?INDEX, [named_table, public, set]);
            Tab -> ets:delete_all_objects(Tab)
        end,
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel_history, Key) of
                [#channel_history{channel = Channel, entries = Entries}] ->
                    replace(channel_message, Channel, Entries),
                    mnesia:dirty_delete(channel_history, Channel);
                [] ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(channel_history)
    ),
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(direct_history, Key) of
                [#direct_history{key = Pair, entries = Entries}] ->
                    replace(direct_message, Pair, Entries),
                    mnesia:dirty_delete(direct_history, Pair);
                [] ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(direct_history)
    ).

-doc "The stored history of channel `Key` (folded name), newest first.".
-spec channel_history(binary()) -> [map()].
channel_history(Key) ->
    channel_entries(Key).

channel_entries(Key) ->
    entries(channel_message, Key).

dm_entries(Pair) ->
    entries(direct_message, Pair).

-doc "Every direct conversation with stored history, as its party pair.".
-spec direct_conversations() -> [{dm_party(), dm_party()}].
direct_conversations() ->
    dm_conversations().

-doc "The stored history of direct conversation `Pair`, newest first.".
-spec direct_history({dm_party(), dm_party()}) -> [map()].
direct_history(Pair) ->
    dm_entries(Pair).

-doc "Replace the history of direct conversation `Pair` (newest first).".
-spec replace_direct({dm_party(), dm_party()}, [map() | tuple()]) -> ok.
replace_direct(Pair, Entries) ->
    replace(direct_message, Pair, Entries).

-doc """
Replace the whole history of channel `Key` with `Entries` (newest first,
trimmed to `history_limit` per class). Used after a redaction and when an
account's messages are erased.
""".
-spec replace_channel(binary(), [map() | tuple()]) -> ok.
replace_channel(Key, Entries) ->
    replace(channel_message, Key, Entries).

-doc "Delete the history of channel `Key` (the channel is gone).".
-spec delete_channel_history(binary()) -> ok.
delete_channel_history(Key) ->
    delete(channel_message, Key).

-doc "Whether channel `Key` has stored history.".
-spec has_channel_history(binary()) -> boolean().
has_channel_history(Key) ->
    has(channel_message, Key).

-doc "Every channel (folded name) with stored history.".
-spec history_channels() -> [binary()].
history_channels() ->
    [K || K <- conversations(channel_message), is_binary(K)].

append_channel(Key, Entry) ->
    append(channel_message, Key, Entry).

%% {Seq, Entry} rows of conversation `Conv` in `Tab`, newest first.
entries(Tab, Conv) ->
    Rows = [
        Row
     || {Seq, _} = Row <- mnesia:dirty_select(Tab, [
            {{Tab, {Conv, '_', '$1'}, '$2'}, [], [{{'$1', '$2'}}]}
        ]),
        is_integer(Seq)
    ],
    [normalize(E) || {_Seq, E} <- lists:reverse(lists:keysort(1, Rows))].

class_of(#{cmd := Cmd}) when
    Cmd =:= <<"PRIVMSG">>; Cmd =:= <<"NOTICE">>; Cmd =:= <<"TAGMSG">>
->
    msg;
class_of({Cmd, _, _}) when Cmd =:= <<"PRIVMSG">>; Cmd =:= <<"NOTICE">> ->
    msg;
class_of(_) ->
    event.

%% {LastSeq, Messages, Events} of `Conv` in `Tab`, counted once from its rows
%% and then kept up to date.
index(Tab, Conv) ->
    Id = {Tab, Conv},
    case ets:lookup(?INDEX, Id) of
        [{Id, Last, Msgs, Events}] ->
            {Last, Msgs, Events};
        [] ->
            Rows = mnesia:dirty_select(Tab, [
                {{Tab, {Conv, '$1', '$2'}, '_'}, [], [{{'$1', '$2'}}]}
            ]),
            Last = lists:max([0 | [Seq || {_, Seq} <- Rows]]),
            Msgs = length([1 || {msg, _} <- Rows]),
            Events = length(Rows) - Msgs,
            ets:insert(?INDEX, {Id, Last, Msgs, Events}),
            {Last, Msgs, Events}
    end.

%% Append `Entry`: one row, then the oldest of its class is dropped while
%% the class holds more than `history_limit` entries.
append(Tab, Conv, Entry) ->
    Class = class_of(Entry),
    {Last, Msgs, Events} = index(Tab, Conv),
    Seq = Last + 1,
    mnesia:dirty_write({Tab, {Conv, Class, Seq}, Entry}),
    case Class of
        msg -> ircd_search:note_add(Tab, Conv, Seq, Entry);
        event -> ok
    end,
    Limit = limit(),
    {Msgs1, Events1} =
        case Class of
            msg -> {drop_oldest(Tab, Conv, msg, Msgs + 1, Limit), Events};
            event -> {Msgs, drop_oldest(Tab, Conv, event, Events + 1, Limit)}
        end,
    ets:insert(?INDEX, {{Tab, Conv}, Seq, Msgs1, Events1}),
    ok.

drop_oldest(Tab, Conv, Class, Count, Limit) when Count > Limit ->
    case mnesia:dirty_next(Tab, {Conv, Class, 0}) of
        {Conv, Class, Seq} = Oldest ->
            mnesia:dirty_delete(Tab, Oldest),
            case Class of
                msg when is_integer(Seq) -> ircd_search:note_delete(Tab, Conv, Seq);
                _ -> ok
            end,
            drop_oldest(Tab, Conv, Class, Count - 1, Limit);
        _ ->
            0
    end;
drop_oldest(_Tab, _Conv, _Class, Count, _Limit) ->
    Count.

%% Replace a conversation's history with `Entries` (newest first).
replace(Tab, Conv, Entries) ->
    delete(Tab, Conv),
    lists:foreach(fun(E) -> append(Tab, Conv, E) end, lists:reverse(Entries)).

delete(Tab, Conv) ->
    Keys = mnesia:dirty_select(Tab, [
        {{Tab, {Conv, '$1', '$2'}, '_'}, [], [{{{const, Conv}, '$1', '$2'}}]}
    ]),
    lists:foreach(fun(K) -> mnesia:dirty_delete(Tab, K) end, Keys),
    ets:delete(?INDEX, {Tab, Conv}),
    ircd_search:note_delete_conv(Tab, Conv),
    ok.

%% `a` sorts before both classes: the next key is the conversation's first.
has(Tab, Conv) ->
    case mnesia:dirty_next(Tab, {Conv, a, 0}) of
        {Conv, _, _} -> true;
        _ -> false
    end.

%% Every conversation in `Tab`; `z` sorts after both classes, so the next
%% key after {Conv, z, 0} is the next conversation's first.
conversations(Tab) ->
    conversations(Tab, mnesia:dirty_first(Tab), []).

conversations(Tab, {Conv, _, _}, Acc) ->
    conversations(Tab, mnesia:dirty_next(Tab, {Conv, z, 0}), [Conv | Acc]);
conversations(_Tab, _, Acc) ->
    lists:reverse(Acc).

%% Time of the newest message of direct conversation `Pair` (0 if none).
dm_latest_time(Pair) ->
    case mnesia:dirty_prev(direct_message, {Pair, z, 0}) of
        {Pair, _, _} = Newest ->
            case mnesia:dirty_read(direct_message, Newest) of
                [{direct_message, _, #{time := Time}}] when is_integer(Time) -> Time;
                _ -> 0
            end;
        _ ->
            0
    end.

%% Direct conversations, keyed by party pair.
dm_conversations() ->
    [P || {_, _} = P <- conversations(direct_message)].

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

entries({channel, Key}) -> channel_entries(Key);
entries({direct, Key}) -> dm_entries(Key).

remove(Source, MsgId) ->
    Kept = [E || E <- entries(Source), maps:get(msgid, E) =/= MsgId],
    case Source of
        {channel, Key} -> replace_channel(Key, Kept);
        {direct, Key} -> replace(direct_message, Key, Kept)
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
    Upper = ircd_wire:upper(Sub),
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
                 || {A, B} = Pair <- dm_conversations(),
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

%%% Message search (m:ircd_search, m:ircd_state_search)

-doc """
Fold `Fun(Table, Conversation, Seq, Entry, Acc)` over every stored message
(the `msg` class: `PRIVMSG`, `NOTICE`, `TAGMSG`) of every channel and direct
conversation. `m:ircd_search` rebuilds its index with it; it reads one
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
                                Fun(Tab, Conv, Seq, normalize(Entry), Acc3);
                            (_, Acc3) ->
                                Acc3
                        end,
                        Acc2,
                        Rows
                    )
                end,
                Acc1,
                conversations(Tab)
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
        {ircd_search:conv_id(channel_message, Key), {channel_message, Key}, Name}
     || Key <- Keys,
        [#channel{name = Name}] <- [mnesia:dirty_read(channel, Key)]
    ],
    Direct =
        case ircd_state_v3:account(Pid) of
            undefined ->
                [];
            Account ->
                Me = {account, ircd_wire:fold(Account)},
                [
                    {ircd_search:conv_id(direct_message, Pair), {direct_message, Pair}, undefined}
                 || {A, B} = Pair <- dm_conversations(),
                    A =:= Me orelse B =:= Me
                ]
        end,
    {ok, Channels ++ Direct};
search_scope(Client, Target) ->
    case access(Client, Target) of
        {ok, Name, {channel, Key}} ->
            {ok, [{ircd_search:conv_id(channel_message, Key), {channel_message, Key}, Name}]};
        {ok, _Name, {direct, Pair}} ->
            {ok, [{ircd_search:conv_id(direct_message, Pair), {direct_message, Pair}, undefined}]};
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
        [{_, _, Entry}] -> {ok, normalize(Entry)};
        [] -> error
    end.

%%% MARKREAD

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

-doc """
True when `Target` may carry a read marker: a valid channel name or a valid
nickname (`ircd_wire:channel/1`, `ircd_wire:nickname/2`).
""".
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

-doc """
After `JOIN`, send the channel's read marker (`MARKREAD <channel> <value>`)
to a client with draft/read-marker.
""".
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
    FoldedTarget = ircd_wire:fold(Target),
    case ircd_state_v3:account(Pid) of
        undefined ->
            Markers0 = ircd_conn:get(Pid, markread, #{}),
            Markers1 = trim_conn_markers(Markers0, FoldedTarget, max_read_markers()),
            ircd_conn:put(Pid, markread, Markers1#{FoldedTarget => Time});
        Account ->
            Folded = ircd_wire:fold(Account),
            store_account_marker(Folded, FoldedTarget, Time),
            ircd_state_sync:markread(Folded, FoldedTarget, Time)
    end.

max_read_markers() ->
    maps:get(max_read_markers, ircd_config:current_or_empty(), 500).

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
    lists:foreach(
        fun
            ({Account, Target} = Key) when Target =:= OldKey ->
                [#read_marker{time = Time}] = mnesia:dirty_read(read_marker, Key),
                mnesia:dirty_delete(read_marker, Key),
                mnesia:dirty_write(#read_marker{key = {Account, NewKey}, time = Time});
            (_) ->
                ok
        end,
        ircd_state:table_keys(read_marker)
    ),
    case ets:whereis(ircd_conn) of
        undefined ->
            ok;
        _ ->
            lists:foreach(
                fun({Pid, Map}) ->
                    case maps:get(markread, Map, undefined) of
                        Markers when is_map(Markers), is_map_key(OldKey, Markers) ->
                            Time = maps:get(OldKey, Markers),
                            Updated = (maps:remove(OldKey, Markers))#{NewKey => Time},
                            ircd_conn:put(Pid, markread, Updated);
                        _ ->
                            ok
                    end
                end,
                ets:tab2list(ircd_conn)
            )
    end.

-doc """
Apply a read marker received from another server. Returns `unchanged` when
the stored marker is already at or past `Time`; otherwise stores it, tells
this server's read-marker clients of that account, and returns `updated`.
""".
-spec remote_marker(binary(), binary(), integer()) -> updated | unchanged.
remote_marker(Account, Target, Time) ->
    Key = {ircd_wire:fold(Account), ircd_wire:fold(Target)},
    case mnesia:dirty_read(read_marker, Key) of
        [#read_marker{time = Stored}] when Stored >= Time ->
            unchanged;
        _ ->
            store_account_marker(element(1, Key), element(2, Key), Time),
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

-doc """
`REDACT <target> <msgid> [:<reason>]` (draft/message-redaction).

The sender may redact its own message (same account, or the same
`nick!user@host` when sent without an account); in a channel a channel
operator may redact any message. The entry is removed from history and
`REDACT` goes to recipients with the capability; a channel redaction is also
sent to peers. Errors are `FAIL REDACT` with `INVALID_TARGET`,
`REDACT_FORBIDDEN`, or `UNKNOWN_MSGID`; missing parameters get 461.
""".
-spec redact([binary()], #client{}, binary()) -> ok.
redact([Target, MsgId | Rest], #client{pid = Pid} = Client, Server) ->
    case redaction_enabled() of
        false ->
            ircd_state_send:fail(
                Pid,
                <<"REDACT">>,
                <<"REDACTION_DISABLED">>,
                [Target],
                <<"Message redaction is disabled">>
            );
        true ->
            Reason =
                case Rest of
                    [Text | _] -> Text;
                    [] -> none
                end,
            case ircd_wire:channel(Target) of
                true -> redact_channel(Target, MsgId, Reason, Client, Server);
                false -> redact_direct(Target, MsgId, Reason, Client, Server)
            end
    end,
    ok;
redact(_, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"REDACT">>], <<"Not enough parameters">>).

redaction_enabled() ->
    Features = maps:get(features, ircd_config:current_or_empty(), #{}),
    maps:get(redaction, Features, true).

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

-doc """
`:nick!user@host REDACT <channel> <msgid> [:reason]` from a peer: remove
the entry from the local channel history, tell local members with
draft/message-redaction, and relay to the other peers.

The rules of a local `REDACT` apply. `Prefix` must be the exact
`nick!user@host` of a remote user reached through `Peer`, and that user must
be a member of the channel through `Peer`. A channel operator may redact any
message; anyone else only their own (same account, or the same
`nick!user@host` when the message was sent without an account). A message
missing from the local history cannot be checked here, so a non-operator's
redaction of it changes nothing locally and is only relayed; the servers that
hold it apply the same check.

Errors: `invalid_redact_message`, `unknown_remote_source`,
`remote_user_not_on_channel`, and `redact_forbidden`.
""".
-spec receive_remote_redact(binary(), binary(), [binary()]) ->
    ok
    | {error,
        invalid_redact_message
        | redact_forbidden
        | remote_user_not_on_channel
        | unknown_remote_source}.
receive_remote_redact(Peer, Prefix, [Target, MsgId | Rest]) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    Key = ircd_wire:fold(Target),
    case {remote_sender(Peer, Prefix), mnesia:dirty_read(remote_channel, Key)} of
        {error, _} ->
            {error, unknown_remote_source};
        {{ok, #remote_client{key = NickKey} = Remote}, [#remote_channel{members = Members}]} ->
            case Members of
                #{NickKey := {Peer, Roles}} ->
                    Operator = lists:member(operator, Roles),
                    case
                        remote_redact_allowed(Operator, Remote, Prefix, find({channel, Key}, MsgId))
                    of
                        true -> apply_remote_redact(Peer, Prefix, Target, MsgId, Reason);
                        false -> {error, redact_forbidden}
                    end;
                #{} ->
                    {error, remote_user_not_on_channel}
            end;
        {{ok, _}, []} ->
            {error, remote_user_not_on_channel}
    end;
receive_remote_redact(_, _, _) ->
    {error, invalid_redact_message}.

%% The remote user behind Peer whose exact nick!user@host is Prefix.
remote_sender(Peer, Prefix) ->
    case binary:split(Prefix, <<"!">>) of
        [Nick, _] ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [#remote_client{peer = Peer, nick = Nick, user = User, host = Host} = Remote] when
                    Prefix =:= <<Nick/binary, "!", User/binary, "@", Host/binary>>
                ->
                    {ok, Remote};
                _ ->
                    error
            end;
        _ ->
            error
    end.

%% An operator may redact anything. Otherwise the stored entry must be the
%% sender's own, as in own_entry/3; an entry this server does not hold
%% cannot be checked and is left to the servers that hold it.
remote_redact_allowed(true, _Remote, _Prefix, _Found) ->
    true;
remote_redact_allowed(false, _Remote, _Prefix, error) ->
    true;
remote_redact_allowed(false, #remote_client{account = Mine}, Prefix, {ok, Entry}) ->
    #{account := Account, prefix := EntryPrefix} = Entry,
    case {Mine, Account} of
        {undefined, undefined} -> EntryPrefix =:= Prefix;
        {_, undefined} -> false;
        {undefined, _} -> false;
        _ -> ircd_wire:fold(Mine) =:= ircd_wire:fold(Account)
    end.

apply_remote_redact(Peer, Prefix, Target, MsgId, Reason) ->
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
    ok.

server() ->
    maps:get(name, ircd_config:current()).
