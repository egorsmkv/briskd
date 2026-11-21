-module(ircd_history_storage_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ircd/include/ircd_channel.hrl").

%% Channel history in `channel_message`: one row per entry, trimmed per
%% class (messages and events separately) to `history_limit`, read newest
%% first, and migrated from the older one-row-per-channel `channel_history`.

storage_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun appends_and_trims/0,
            fun events_trimmed_separately/0,
            fun replace_delete_and_listing/0,
            fun migrates_old_rows/0
        ]
    end}.

setup() ->
    Dir = filename:join(
        "/tmp", "ircd-history-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Old = persistent_term:get({ircd_state, config}, undefined),
    _ = application:load(mnesia),
    ok = application:set_env(mnesia, dir, Dir),
    ok = mnesia:start(),
    {atomic, ok} = mnesia:create_table(channel_history, [
        {attributes, record_info(fields, channel_history)}
    ]),
    {atomic, ok} = mnesia:create_table(channel_message, [
        {attributes, record_info(fields, channel_message)}, {type, ordered_set}
    ]),
    ok = mnesia:wait_for_tables([channel_history, channel_message], 5000),
    persistent_term:put({ircd_state, config}, #{chathistory => true, history_limit => 5}),
    ok = ircd_state_history:init_channel_storage(),
    {Dir, Old}.

cleanup({Dir, Old}) ->
    case Old of
        undefined -> persistent_term:erase({ircd_state, config});
        _ -> persistent_term:put({ircd_state, config}, Old)
    end,
    stopped = mnesia:stop(),
    _ = application:unset_env(mnesia, dir),
    _ = file:del_dir_r(Dir),
    ok.

msg(N) ->
    ircd_state_history:entry(
        <<"PRIVMSG">>, <<"a!a@h">>, integer_to_binary(N), integer_to_binary(N), N, [], undefined
    ).

texts(Key) ->
    [T || #{text := T} <- ircd_state_history:channel_history(Key)].

rows(Key) ->
    length(mnesia:dirty_match_object({channel_message, {Key, '_', '_'}, '_'})).

%% 50 messages with history_limit 5: the newest 5, newest first, and only
%% 5 rows stored (each message writes one row and drops one).
appends_and_trims() ->
    Key = <<"#trim">>,
    [ok = ircd_state_history:note_channel(Key, msg(N)) || N <- lists:seq(1, 50)],
    ?assertEqual([<<"50">>, <<"49">>, <<"48">>, <<"47">>, <<"46">>], texts(Key)),
    ?assertEqual(5, rows(Key)),
    %% A lowered limit applies on the next write.
    persistent_term:put({ircd_state, config}, #{chathistory => true, history_limit => 2}),
    ok = ircd_state_history:note_channel(Key, msg(51)),
    ?assertEqual([<<"51">>, <<"50">>], texts(Key)),
    persistent_term:put({ircd_state, config}, #{chathistory => true, history_limit => 5}).

%% Events never push messages out: each class keeps its own newest 5.
events_trimmed_separately() ->
    Key = <<"#mixed">>,
    [ok = ircd_state_history:note_channel(Key, msg(N)) || N <- lists:seq(1, 3)],
    [
        ok = ircd_state_history:note_event(Key, <<"MODE">>, <<"a!a@h">>, [<<"+m">>], none)
     || _ <- lists:seq(1, 20)
    ],
    History = ircd_state_history:channel_history(Key),
    ?assertEqual(3, length([E || #{cmd := <<"PRIVMSG">>} = E <- History])),
    ?assertEqual(5, length([E || #{cmd := <<"MODE">>} = E <- History])),
    %% Newest first across both classes: the events came last.
    ?assertMatch([#{cmd := <<"MODE">>} | _], History).

replace_delete_and_listing() ->
    Key = <<"#replace">>,
    ok = ircd_state_history:replace_channel(Key, [msg(3), msg(2), msg(1)]),
    ?assertEqual([<<"3">>, <<"2">>, <<"1">>], texts(Key)),
    ?assert(ircd_state_history:has_channel_history(Key)),
    ?assert(lists:member(Key, ircd_state_history:history_channels())),
    %% Appending after a replace continues the sequence.
    ok = ircd_state_history:note_channel(Key, msg(4)),
    ?assertEqual([<<"4">>, <<"3">>, <<"2">>, <<"1">>], texts(Key)),
    ok = ircd_state_history:delete_channel_history(Key),
    ?assertNot(ircd_state_history:has_channel_history(Key)),
    ?assertEqual([], texts(Key)),
    ?assertNot(lists:member(Key, ircd_state_history:history_channels())).

%% A row of the older format (one list per channel, newest first, with a
%% legacy tuple) becomes per-entry rows, and the old row goes.
migrates_old_rows() ->
    Key = <<"#old">>,
    ok = mnesia:dirty_write(#channel_history{
        channel = Key, entries = [msg(2), {<<"PRIVMSG">>, <<"o!u@h">>, <<"legacy">>}]
    }),
    ok = ircd_state_history:init_channel_storage(),
    ?assertEqual([], mnesia:dirty_read(channel_history, Key)),
    ?assertEqual([<<"2">>, <<"legacy">>], texts(Key)),
    %% The other channels survived the index rebuild.
    ?assertEqual([<<"51">>, <<"50">>], lists:sublist(texts(<<"#trim">>), 2)).
