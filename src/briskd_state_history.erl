-module(briskd_state_history).
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
    parse_timestamp/1,
    conversations/1,
    dm_key/2,
    normalize/1,
    party/1,
    playable/2
]).
-include("briskd_state.hrl").
-include("briskd_account.hrl").

-doc """
One stored message or event. `msgid` is `undefined` for a line that arrived
without one. Events (`JOIN`, `PART`, and the rest) add `params` and
`notarget`.
""".
-type entry() :: #{
    cmd := binary(),
    prefix := binary(),
    text := briskd_state_channel:body(),
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

Runs inside `m:briskd_state`. Channel history is the Mnesia `channel_message`
table (ordered_set), one row per entry keyed by folded channel name, class
(message or event), and sequence number, so recording a message writes one
small row; a per-channel index (ETS `briskd_history_index`) keeps the last
sequence number and the counts used to drop the oldest entry. Direct-message
history is the Mnesia `direct_message` table, stored the same way and keyed
by the sorted pair of participants; a message is recorded only when at least
one side is logged in, and only a logged-in user can read it. Both are capped
by `history_limit` (`briskd_state:history_limit/0`): the newest `history_limit`
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
a connection without an account keeps them in `m:briskd_conn` until it
disconnects. Direct-message conversations are bounded per account by
`max_direct_conversations`. Markers only move forward and are synchronized to
peers through `m:briskd_state_sync`.
""".

-doc """
Build a history entry map from a message's command, sender prefix, text
(binary or `{multiline, Lines}`), `msgid`, time in milliseconds,
client-only tags, and sender account.

Stored binaries are copied (`briskd_wire:retain/1`) so they do not pin a
receive buffer.
""".
-spec entry(
    binary(),
    iodata(),
    briskd_state_channel:body(),
    undefined | binary(),
    integer(),
    [{binary(), undefined | binary()}],
    undefined | binary()
) -> entry().
entry(Command, Prefix, Text, MsgId, Time, Tags, Account) ->
    #{
        cmd => Command,
        prefix => briskd_wire:retain(iolist_to_binary(Prefix)),
        text => retain_text(Text),
        msgid => MsgId,
        time => Time,
        tags => [{briskd_wire:retain(K), briskd_wire:retain(V)} || {K, V} <- Tags],
        account => Account
    }.

retain_text({multiline, Lines}) -> {multiline, [{C, briskd_wire:retain(T)} || {C, T} <- Lines]};
retain_text(Text) -> briskd_wire:retain(Text).

enabled() ->
    maps:get(chathistory, briskd_config:current(), true).

limit() ->
    briskd_state:history_limit().

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
    MsgId = briskd_state_send:msgid(),
    Now = erlang:system_time(millisecond),
    {[{<<"msgid">>, MsgId}, {<<"time">>, briskd_state_send:time_value(Now)}], {MsgId, Now}}.

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
                case lists:keyfind(<<"account">>, 1, briskd_state_send:source_tags(Prefix)) of
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
                params => [briskd_wire:retain(P) || P <- params_list(Params)],
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
-doc "Filter history entries to those playable for `Pid`.".
-spec playable(pid(), [map()]) -> [map()].
playable(Pid, Entries) ->
    case briskd_cap:enabled(Pid, <<"draft/event-playback">>) of
        true ->
            Entries;
        false ->
            HasTags = briskd_cap:enabled(Pid, <<"message-tags">>),
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
            append(direct_message, Key, Entry#{target => briskd_wire:retain(Target)});
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
`m:briskd_state`.
""".
-spec erase_account(binary()) -> #{channel := non_neg_integer(), direct := non_neg_integer()}.
erase_account(Folded) ->
    Mine = fun
        (#{account := A}) when is_binary(A) -> briskd_wire:fold(A) =:= Folded;
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
-doc "Normalize a DM participant to `{account, Folded}` or `{nick, Folded}`.".
-spec party({undefined | binary(), binary()}) -> dm_party().
party({undefined, Nick}) -> {nick, briskd_wire:fold(Nick)};
party({Account, _Nick}) -> {account, briskd_wire:fold(Account)}.

-doc "Canonical sorted pair key for a direct-message conversation.".
-spec dm_key(dm_party(), dm_party()) -> {dm_party(), dm_party()}.
dm_key(A, B) ->
    case A =< B of
        true -> {A, B};
        false -> {B, A}
    end.

prune_direct_conversations({account, _} = Party, KeepingKey) ->
    Max = maps:get(
        max_direct_conversations, briskd_config:current_or_empty(), 200
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

-define(INDEX, briskd_history_index).

-doc """
Create the history index (per conversation: last sequence number and entry
counts per class) and move rows of the older one-row-per-conversation
tables, `channel_history` and `direct_history`, into `channel_message` and
`direct_message`. Call from `m:briskd_state`'s `init/1`, which owns the index.
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
        msg -> briskd_search:note_add(Tab, Conv, Seq, Entry);
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
                msg when is_integer(Seq) -> briskd_search:note_delete(Tab, Conv, Seq);
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
    briskd_search:note_delete_conv(Tab, Conv),
    ok.

%% `a` sorts before both classes: the next key is the conversation's first.
has(Tab, Conv) ->
    case mnesia:dirty_next(Tab, {Conv, a, 0}) of
        {Conv, _, _} -> true;
        _ -> false
    end.

%% Every conversation in `Tab`; `z` sorts after both classes, so the next
%% key after {Conv, z, 0} is the next conversation's first.
-doc "Every conversation key present in Mnesia table `Tab`.".
-spec conversations(channel_message | direct_message) -> [term()].
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

-doc "Normalize legacy tuple entries or map entries to the current map shape.".
-spec normalize(term()) -> map().
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

-doc "Find a `PRIVMSG`, `NOTICE`, or `TAGMSG` entry by `msgid` in stored history.".
-spec find({channel, binary()} | {direct, tuple()}, binary()) -> {ok, map()} | error.
find(Source, MsgId) ->
    briskd_history_query:find(Source, MsgId).

-doc "Replay stored channel history, oldest first, to a joining client.".
-spec replay_on_join(binary(), binary(), pid()) -> ok.
replay_on_join(Key, Name, Pid) ->
    briskd_history_query:replay_on_join(Key, Name, Pid).

-doc "Send entries (oldest first) to `Pid` with their stored tags.".
-spec replay_entries(pid(), undefined | binary(), [map()], binary()) -> ok.
replay_entries(Pid, Name, Entries, Server) ->
    briskd_history_query:replay_entries(Pid, Name, Entries, Server).

-doc "`CHATHISTORY <subcommand> ...` (draft/chathistory).".
-spec chathistory([binary()], #client{}, binary()) -> ok.
chathistory(Params, Client, Server) ->
    briskd_history_query:chathistory(Params, Client, Server).

-doc "Parse an RFC 3339 timestamp to milliseconds since the epoch.".
-spec parse_timestamp(binary()) -> {ok, integer()} | error.
parse_timestamp(Value) ->
    briskd_history_query:parse_timestamp(Value).

-doc "Fold `Fun` over every stored message in channel and direct history.".
-spec fold_messages(
    fun((channel_message | direct_message, term(), pos_integer(), map(), Acc) -> Acc), Acc
) -> Acc.
fold_messages(Fun, Acc0) ->
    briskd_history_query:fold_messages(Fun, Acc0).

-doc "The conversations `Client` may search for `Target`.".
-spec search_scope(#client{}, binary()) ->
    {ok, [{binary(), {channel_message | direct_message, term()}, binary() | undefined}]}
    | error.
search_scope(Client, Target) ->
    briskd_history_query:search_scope(Client, Target).

-doc "The stored message `Seq` of `{Table, Conversation}`, if still present.".
-spec search_entry({channel_message | direct_message, term()}, pos_integer()) ->
    {ok, map()} | error.
search_entry(Conv, Seq) ->
    briskd_history_query:search_entry(Conv, Seq).

-doc "`MARKREAD <target> [timestamp=...]` (draft/read-marker).".
-spec markread([binary()], #client{}, binary()) -> ok.
markread(Params, Client, Server) ->
    briskd_history_markread:markread(Params, Client, Server).

-doc "True when `Target` may carry a read marker.".
-spec valid_marker_target(binary()) -> boolean().
valid_marker_target(Target) ->
    briskd_history_markread:valid_marker_target(Target).

-doc "After `JOIN`, send the channel's read marker to a draft/read-marker client.".
-spec markread_on_join(pid(), binary(), binary()) -> ok.
markread_on_join(Pid, Name, Server) ->
    briskd_history_markread:markread_on_join(Pid, Name, Server).

-doc "Move every account's read marker from `OldKey` to `NewKey` after channel rename.".
-spec rename_markers(binary(), binary()) -> ok.
rename_markers(OldKey, NewKey) ->
    briskd_history_markread:rename_markers(OldKey, NewKey).

-doc "Apply a read marker received from another server.".
-spec remote_marker(binary(), binary(), integer()) -> updated | unchanged.
remote_marker(Account, Target, Time) ->
    briskd_history_markread:remote_marker(Account, Target, Time).

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
            briskd_state_send:fail(
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
            case briskd_wire:channel(Target) of
                true -> redact_channel(Target, MsgId, Reason, Client, Server);
                false -> redact_direct(Target, MsgId, Reason, Client, Server)
            end
    end,
    ok;
redact(_, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"REDACT">>], <<"Not enough parameters">>
    ).

redaction_enabled() ->
    Features = maps:get(features, briskd_config:current_or_empty(), #{}),
    maps:get(redaction, Features, true).

redact_channel(Target, MsgId, Reason, #client{pid = Pid} = Client, _Server) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Target)) of
        [#channel{key = Key, name = Name, members = Members}] when is_map_key(Pid, Members) ->
            case briskd_history_query:find({channel, Key}, MsgId) of
                {ok, Entry} ->
                    Operator = lists:member(operator, maps:get(Pid, Members)),
                    case Operator orelse own_entry(Pid, Client, Entry) of
                        true ->
                            briskd_history_query:remove({channel, Key}, MsgId),
                            Prefix = briskd_state_send:prefix(Client),
                            Recipients = [
                                P
                             || P <- maps:keys(Members),
                                briskd_cap:enabled(P, <<"draft/message-redaction">>)
                            ],
                            briskd_state_send:broadcast(
                                Recipients, Prefix, <<"REDACT">>, [Name, MsgId], Reason
                            ),
                            briskd_state_link:server_broadcast(
                                briskd_wire:line(Prefix, <<"REDACT">>, [Name, MsgId], Reason)
                            );
                        false ->
                            forbidden(Pid, Name, MsgId)
                    end;
                error ->
                    unknown_msgid(Pid, Name, MsgId)
            end;
        _ ->
            briskd_state_send:fail(
                Pid,
                <<"REDACT">>,
                <<"INVALID_TARGET">>,
                [Target],
                [<<"You cannot delete messages from ">>, Target]
            )
    end.

redact_direct(Target, MsgId, Reason, #client{pid = Pid} = Client, _Server) ->
    case briskd_history_query:access(Client, Target) of
        {ok, _Name, {direct, Key} = Source} ->
            case briskd_history_query:find(Source, MsgId) of
                {ok, Entry} ->
                    case own_entry(Pid, Client, Entry) of
                        true ->
                            briskd_history_query:remove({direct, Key}, MsgId),
                            Prefix = briskd_state_send:prefix(Client),
                            Self = [Pid || briskd_cap:enabled(Pid, <<"draft/message-redaction">>)],
                            briskd_state_send:broadcast(
                                Self, Prefix, <<"REDACT">>, [Target, MsgId], Reason
                            ),
                            case briskd_state_client:find_nick(Target) of
                                #client{pid = Other, nick = Nick} ->
                                    case briskd_cap:enabled(Other, <<"draft/message-redaction">>) of
                                        true ->
                                            briskd_state_send:send(
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
            briskd_state_send:fail(
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
    Mine = briskd_state_v3:account(Pid),
    case {Mine, Account} of
        {undefined, undefined} ->
            Prefix =:= iolist_to_binary(briskd_state_send:prefix(Client));
        {_, undefined} ->
            false;
        {undefined, _} ->
            false;
        _ ->
            briskd_wire:fold(Mine) =:= briskd_wire:fold(Account)
    end.

forbidden(Pid, Target, MsgId) ->
    briskd_state_send:fail(
        Pid,
        <<"REDACT">>,
        <<"REDACT_FORBIDDEN">>,
        [Target, MsgId],
        <<"You are not authorised to delete this message">>
    ).

unknown_msgid(Pid, Target, MsgId) ->
    briskd_state_send:fail(
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
    Key = briskd_wire:fold(Target),
    case {remote_sender(Peer, Prefix), mnesia:dirty_read(remote_channel, Key)} of
        {error, _} ->
            {error, unknown_remote_source};
        {{ok, #remote_client{key = NickKey} = Remote}, [#remote_channel{members = Members}]} ->
            case Members of
                #{NickKey := {Peer, Roles}} ->
                    Operator = lists:member(operator, Roles),
                    case
                        remote_redact_allowed(
                            Operator,
                            Remote,
                            Prefix,
                            briskd_history_query:find({channel, Key}, MsgId)
                        )
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
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
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
        _ -> briskd_wire:fold(Mine) =:= briskd_wire:fold(Account)
    end.

apply_remote_redact(Peer, Prefix, Target, MsgId, Reason) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Target)) of
        [#channel{key = Key, name = Name, members = Members}] ->
            briskd_history_query:remove({channel, Key}, MsgId),
            Recipients = [
                P
             || P <- maps:keys(Members), briskd_cap:enabled(P, <<"draft/message-redaction">>)
            ],
            briskd_state_send:broadcast(Recipients, Prefix, <<"REDACT">>, [Name, MsgId], Reason);
        [] ->
            ok
    end,
    briskd_state_link:relay_except(
        Peer, briskd_wire:line(Prefix, <<"REDACT">>, [Target, MsgId], Reason)
    ),
    ok.
