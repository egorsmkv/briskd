-module(briskd_history_storage_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("briskd/include/briskd_channel.hrl").
-include_lib("briskd/include/briskd_account.hrl").

%% Channel history in `channel_message`: one row per entry, trimmed per
%% class (messages and events separately) to `history_limit`, read newest
%% first, and migrated from the older one-row-per-channel `channel_history`.

storage_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun appends_and_trims/0,
            fun events_trimmed_separately/0,
            fun replace_delete_and_listing/0,
            fun migrates_old_rows/0,
            fun direct_messages/0,
            fun direct_conversation_cap/0
        ]
    end}.

setup() ->
    Dir = filename:join(
        "/tmp", "briskd-history-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Old = persistent_term:get({briskd_state, config}, undefined),
    _ = application:load(mnesia),
    ok = application:set_env(mnesia, dir, Dir),
    ok = mnesia:start(),
    {atomic, ok} = mnesia:create_table(channel_history, [
        {attributes, record_info(fields, channel_history)}
    ]),
    {atomic, ok} = mnesia:create_table(channel_message, [
        {attributes, record_info(fields, channel_message)}, {type, ordered_set}
    ]),
    {atomic, ok} = mnesia:create_table(direct_history, [
        {attributes, record_info(fields, direct_history)}
    ]),
    {atomic, ok} = mnesia:create_table(direct_message, [
        {attributes, record_info(fields, direct_message)}, {type, ordered_set}
    ]),
    ok = mnesia:wait_for_tables(
        [channel_history, channel_message, direct_history, direct_message], 5000
    ),
    persistent_term:put({briskd_state, config}, #{chathistory => true, history_limit => 5}),
    ok = briskd_state_history:init_storage(),
    {Dir, Old}.

cleanup({Dir, Old}) ->
    case Old of
        undefined -> persistent_term:erase({briskd_state, config});
        _ -> persistent_term:put({briskd_state, config}, Old)
    end,
    stopped = mnesia:stop(),
    _ = application:unset_env(mnesia, dir),
    _ = file:del_dir_r(Dir),
    ok.

msg(N) ->
    briskd_state_history:entry(
        <<"PRIVMSG">>, <<"a!a@h">>, integer_to_binary(N), integer_to_binary(N), N, [], undefined
    ).

texts(Key) ->
    [T || #{text := T} <- briskd_state_history:channel_history(Key)].

rows(Key) ->
    length(mnesia:dirty_match_object({channel_message, {Key, '_', '_'}, '_'})).

%% 50 messages with history_limit 5: the newest 5, newest first, and only
%% 5 rows stored (each message writes one row and drops one).
appends_and_trims() ->
    Key = <<"#trim">>,
    [ok = briskd_state_history:note_channel(Key, msg(N)) || N <- lists:seq(1, 50)],
    ?assertEqual([<<"50">>, <<"49">>, <<"48">>, <<"47">>, <<"46">>], texts(Key)),
    ?assertEqual(5, rows(Key)),
    %% A lowered limit applies on the next write.
    persistent_term:put({briskd_state, config}, #{chathistory => true, history_limit => 2}),
    ok = briskd_state_history:note_channel(Key, msg(51)),
    ?assertEqual([<<"51">>, <<"50">>], texts(Key)),
    persistent_term:put({briskd_state, config}, #{chathistory => true, history_limit => 5}).

%% Events never push messages out: each class keeps its own newest 5.
events_trimmed_separately() ->
    Key = <<"#mixed">>,
    [ok = briskd_state_history:note_channel(Key, msg(N)) || N <- lists:seq(1, 3)],
    [
        ok = briskd_state_history:note_event(Key, <<"MODE">>, <<"a!a@h">>, [<<"+m">>], none)
     || _ <- lists:seq(1, 20)
    ],
    History = briskd_state_history:channel_history(Key),
    ?assertEqual(3, length([E || #{cmd := <<"PRIVMSG">>} = E <- History])),
    ?assertEqual(5, length([E || #{cmd := <<"MODE">>} = E <- History])),
    %% Newest first across both classes: the events came last.
    ?assertMatch([#{cmd := <<"MODE">>} | _], History).

replace_delete_and_listing() ->
    Key = <<"#replace">>,
    ok = briskd_state_history:replace_channel(Key, [msg(3), msg(2), msg(1)]),
    ?assertEqual([<<"3">>, <<"2">>, <<"1">>], texts(Key)),
    ?assert(briskd_state_history:has_channel_history(Key)),
    ?assert(lists:member(Key, briskd_state_history:history_channels())),
    %% Appending after a replace continues the sequence.
    ok = briskd_state_history:note_channel(Key, msg(4)),
    ?assertEqual([<<"4">>, <<"3">>, <<"2">>, <<"1">>], texts(Key)),
    ok = briskd_state_history:delete_channel_history(Key),
    ?assertNot(briskd_state_history:has_channel_history(Key)),
    ?assertEqual([], texts(Key)),
    ?assertNot(lists:member(Key, briskd_state_history:history_channels())).

%% A row of the older format (one list per channel, newest first, with a
%% legacy tuple) becomes per-entry rows, and the old row goes.
migrates_old_rows() ->
    Key = <<"#old">>,
    ok = mnesia:dirty_write(#channel_history{
        channel = Key, entries = [msg(2), {<<"PRIVMSG">>, <<"o!u@h">>, <<"legacy">>}]
    }),
    ok = briskd_state_history:init_storage(),
    ?assertEqual([], mnesia:dirty_read(channel_history, Key)),
    ?assertEqual([<<"2">>, <<"legacy">>], texts(Key)),
    %% The other channels survived the index rebuild.
    ?assertEqual([<<"51">>, <<"50">>], lists:sublist(texts(<<"#trim">>), 2)).

dm(From, To, N) ->
    ok = briskd_state_history:note_direct(
        {From, From}, {To, To}, To, (msg(N))#{account => From}
    ).

pair(A, B) ->
    list_to_tuple(lists:sort([{account, A}, {account, B}])).

%% A direct message appends one row; the newest 5 stay (history_limit 5).
%% An older direct_history row is migrated like a channel's.
direct_messages() ->
    [dm(<<"ann">>, <<"bob">>, N) || N <- lists:seq(1, 12)],
    Pair = pair(<<"ann">>, <<"bob">>),
    ?assertEqual(
        [<<"12">>, <<"11">>, <<"10">>, <<"9">>, <<"8">>],
        [T || #{text := T} <- briskd_state_history:direct_history(Pair)]
    ),
    ?assertEqual(
        5, length(mnesia:dirty_match_object({direct_message, {Pair, '_', '_'}, '_'}))
    ),
    Old = pair(<<"cat">>, <<"dan">>),
    ok = mnesia:dirty_write(#direct_history{key = Old, entries = [msg(2), msg(1)]}),
    ok = briskd_state_history:init_storage(),
    ?assertEqual([], mnesia:dirty_read(direct_history, Old)),
    ?assertEqual(
        [<<"2">>, <<"1">>], [T || #{text := T} <- briskd_state_history:direct_history(Old)]
    ),
    ?assert(lists:member(Pair, briskd_state_history:direct_conversations())).

%% An account keeps at most max_direct_conversations conversations: a new
%% one drops the one with the oldest last message.
direct_conversation_cap() ->
    persistent_term:put(
        {briskd_state, config},
        #{chathistory => true, history_limit => 5, max_direct_conversations => 2}
    ),
    dm(<<"eve">>, <<"p1">>, 100),
    dm(<<"eve">>, <<"p2">>, 200),
    dm(<<"eve">>, <<"p3">>, 300),
    Mine = [
        P
     || P <- briskd_state_history:direct_conversations(),
        element(1, P) =:= {account, <<"eve">>} orelse element(2, P) =:= {account, <<"eve">>}
    ],
    ?assertEqual(
        lists:sort([pair(<<"eve">>, <<"p2">>), pair(<<"eve">>, <<"p3">>)]), lists:sort(Mine)
    ),
    persistent_term:put({briskd_state, config}, #{chathistory => true, history_limit => 5}).
