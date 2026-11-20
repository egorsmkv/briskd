-module(ircd_features_tests).
-include_lib("eunit/include/eunit.hrl").

config_features_test() ->
    TmpDir = filename:join([
        "/tmp",
        "ircd_features_cfg_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    DefaultPath = filename:join(TmpDir, "default.json"),
    PartialPath = filename:join(TmpDir, "partial.json"),
    BadPath = filename:join(TmpDir, "bad.json"),
    try
        ok = file:write_file(DefaultPath, json:encode(#{<<"tcp_port">> => 6667})),
        {ok, #{features := Def}} = ircd_config:load(DefaultPath),
        ?assertEqual(
            #{
                reactions => true,
                replies => true,
                typing => true,
                editing => true,
                redaction => true,
                link_previews => true
            },
            Def
        ),

        ok = file:write_file(
            PartialPath,
            json:encode(#{
                <<"tcp_port">> => 6667,
                <<"features">> => #{
                    <<"reactions">> => false,
                    <<"typing">> => false,
                    <<"redaction">> => false
                }
            })
        ),
        {ok, #{features := Partial}} = ircd_config:load(PartialPath),
        ?assertEqual(false, maps:get(reactions, Partial)),
        ?assertEqual(true, maps:get(replies, Partial)),
        ?assertEqual(false, maps:get(typing, Partial)),
        ?assertEqual(true, maps:get(editing, Partial)),
        ?assertEqual(false, maps:get(redaction, Partial)),

        ok = file:write_file(
            BadPath,
            json:encode(#{
                <<"tcp_port">> => 6667,
                <<"features">> => #{<<"typing">> => <<"yes">>}
            })
        ),
        ?assertMatch({error, {invalid_config, BadPath, _}}, ircd_config:load(BadPath))
    after
        _ = file:delete(DefaultPath),
        _ = file:delete(PartialPath),
        _ = file:delete(BadPath),
        _ = file:del_dir(TmpDir)
    end.

cap_features_advertisement_test() ->
    Old = persistent_term:get({ircd_state, config}, undefined),
    Created =
        case ets:whereis(ircd_caps) of
            undefined ->
                ets:new(ircd_caps, [named_table, public, set]),
                true;
            _ ->
                false
        end,
    try
        ircd_cap:connect(self()),
        persistent_term:put({ircd_state, config}, #{
            features => #{
                reactions => true,
                replies => false,
                typing => true,
                editing => false,
                redaction => false,
                link_previews => false
            }
        }),
        Adv = maps:from_list(ircd_cap:advertised(self())),
        ?assertNot(maps:is_key(<<"draft/message-redaction">>, Adv)),
        ?assertEqual(<<"reactions,typing">>, maps:get(<<"egorsmkv.github.io/features">>, Adv)),

        persistent_term:put({ircd_state, config}, #{
            features => #{
                reactions => false,
                replies => false,
                typing => false,
                editing => false,
                redaction => false,
                link_previews => false
            }
        }),
        AdvNone = maps:from_list(ircd_cap:advertised(self())),
        ?assertEqual(<<"none">>, maps:get(<<"egorsmkv.github.io/features">>, AdvNone))
    after
        ircd_cap:disconnect(self()),
        case Created of
            true -> ets:delete(ircd_caps);
            false -> ok
        end,
        case Old of
            undefined -> persistent_term:erase({ircd_state, config});
            _ -> persistent_term:put({ircd_state, config}, Old)
        end
    end.

reaction_persistence_test() ->
    Old = persistent_term:get({ircd_state, config}, undefined),
    %% Start a RAM-only Mnesia in a scratch directory unless one is already
    %% running, and stop it afterwards so later suites can start `ircd`.
    Started = not lists:keymember(mnesia, 1, application:which_applications()),
    Dir = filename:join(
        "/tmp", "ircd-features-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    case Started of
        true ->
            _ = application:load(mnesia),
            ok = application:set_env(mnesia, dir, Dir),
            ok = mnesia:start();
        false ->
            ok
    end,
    case
        mnesia:create_table(channel_history, [
            {attributes, [channel, entries]}, {record_name, channel_history}
        ])
    of
        {atomic, ok} -> ok;
        {aborted, {already_exists, channel_history}} -> ok
    end,
    ok = mnesia:wait_for_tables([channel_history], 5000),
    try
        persistent_term:put({ircd_state, config}, #{chathistory => true, history_limit => 50}),
        Key = <<"#react_persist_test">>,
        mnesia:dirty_delete(channel_history, Key),
        Msg = ircd_state_history:entry(
            <<"PRIVMSG">>, <<"alice!a@h">>, <<"hi">>, <<"m1">>, 1000, [], <<"alice">>
        ),
        React = ircd_state_history:entry(
            <<"TAGMSG">>,
            <<"bob!b@h">>,
            none,
            <<"m2">>,
            1001,
            [{<<"+draft/reply">>, <<"m1">>}, {<<"+draft/react">>, <<"👍">>}],
            <<"bob">>
        ),
        Typing = ircd_state_history:entry(
            <<"TAGMSG">>,
            <<"bob!b@h">>,
            none,
            <<"m3">>,
            1002,
            [{<<"+typing">>, <<"active">>}],
            <<"bob">>
        ),
        ok = ircd_state_history:note_channel(Key, Msg),
        ok = ircd_state_history:note_channel(Key, React),
        ok = ircd_state_history:note_channel(Key, Typing),
        [{channel_history, Key, Entries}] = mnesia:dirty_read(channel_history, Key),
        %% Typing TAGMSG must NOT be persisted; PRIVMSG + reaction TAGMSG MUST be persisted.
        ?assertEqual(2, length(Entries)),
        ?assertEqual([<<"m2">>, <<"m1">>], [maps:get(msgid, E) || E <- Entries]),
        mnesia:dirty_delete(channel_history, Key)
    after
        case Old of
            undefined -> persistent_term:erase({ircd_state, config});
            _ -> persistent_term:put({ircd_state, config}, Old)
        end,
        case Started of
            true ->
                _ = mnesia:delete_table(channel_history),
                stopped = mnesia:stop(),
                _ = application:unset_env(mnesia, dir),
                _ = file:del_dir_r(Dir);
            false ->
                ok
        end
    end.
