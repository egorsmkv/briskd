-module(ircd_state_channel).
-export([
    deliver/5,
    deliver_body/6,
    invite/4,
    join_channels/4,
    kick/5,
    knock/4,
    leave/5,
    leave/6,
    mask_matches/3,
    mode_command/4,
    names/3,
    names_lines/6,
    names_listing/3,
    names_unattached/2,
    nick_recipients/1,
    reop_channels/1,
    rename/3,
    role_prefix/2,
    split/1,
    topic/4,
    note_channel_history/4,
    note_channel_history/5,
    grant_predefined_operator/2,
    release_if_empty/2,
    track_opless/2,
    user_mode_string/1,
    visible_member/3,
    wildcard_match/2
]).
-include("ircd_state.hrl").

%% @doc Local channel membership, modes, names, and reop.

%% Last local member left. Safe channels always remain. Ordinary channels remain
%% when retention is `channels` or the channel is in the configured list, so
%% a predefined channel stays available after the last member leaves.
release_if_empty(#channel{name = <<$!, _/binary>>} = Channel, Remaining) ->
    mnesia:dirty_write(track_opless(Channel, Remaining));
release_if_empty(#channel{key = Key} = Channel, Remaining) ->
    case ircd_state:retention() =:= channels orelse ircd_state:predefined_channel(Key) of
        true ->
            mnesia:dirty_write(Channel#channel{members = Remaining});
        false ->
            ircd_state_meta:drop_channel(Key),
            mnesia:dirty_delete(channel, Key),
            mnesia:dirty_delete(channel_history, Key)
    end.

%% An administrator who is already on a predefined channel becomes its
%% channel operator when OPER succeeds. `+` channels stay modeless.
grant_predefined_operator(#client{pid = Pid}, Server) ->
    case ircd_state:administrator(Pid) of
        false ->
            ok;
        true ->
            Client = ircd_state_client:client(Pid),
            lists:foreach(
                fun(Key) -> grant_predefined_one(Key, Client, Server) end,
                Client#client.channels
            )
    end.

grant_predefined_one(Key, Client, Server) ->
    case ircd_state:predefined_channel(Key) of
        false -> ok;
        true -> grant_predefined_row(mnesia:dirty_read(channel, Key), Client, Server)
    end.

grant_predefined_row([], _Client, _Server) ->
    ok;
grant_predefined_row([#channel{name = <<$+, _/binary>>}], _Client, _Server) ->
    ok;
grant_predefined_row(
    [#channel{members = Members} = Channel], #client{pid = Pid, nick = Nick} = Client, _Server
) ->
    Roles = maps:get(Pid, Members, []),
    case is_map_key(Pid, Members) andalso not lists:member(operator, Roles) of
        false ->
            ok;
        true ->
            Updated = Channel#channel{members = Members#{Pid => lists:usort([operator | Roles])}},
            mnesia:dirty_write(Updated),
            ircd_state_send:broadcast(
                maps:keys(Members),
                ircd_state_send:prefix(Client),
                <<"MODE">>,
                [Channel#channel.name, <<"+o">>, Nick],
                none
            ),
            ircd_state_link:propagate_channel_mode(Client, Channel#channel.name, <<"+o">>, [Nick])
    end.

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

%% Deadline is monotonic seconds plus the configured delay and jitter.
%% Startup clears opless_since, so a persisted row never keeps a previous VM's clock.
next_reop_time() ->
    Delay = persistent_term:get({ircd_state, reop_delay}, 30),
    erlang:monotonic_time(second) + Delay + rand:uniform(Delay).

reop_channels(Server) ->
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{flags = Flags, members = Members} = Channel] ->
                    case maps:is_key($r, Flags) andalso map_size(Members) > 0 of
                        true -> maybe_reop(Channel, Server);
                        false -> ok
                    end;
                [] ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(channel)
    ).

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
            case pick_member(maps:iterator(Members)) of
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
                    ircd_state_send:broadcast(
                        Pids, Server, <<"MODE">>, [Channel#channel.name, <<"+o">>, Nick], none
                    )
            end
    end.

%% One pass over the member map: a uniformly chosen pid and every pid, in map order.
%% An empty map is not reop'd. `rand:uniform(0)` is not a valid way to observe that.
pick_member(Iterator) ->
    pick_member(Iterator, 0, undefined, []).

pick_member(Iterator, Seen, Chosen, Pids) ->
    case maps:next(Iterator) of
        none when Seen =:= 0 ->
            none;
        none ->
            {Chosen, lists:reverse(Pids)};
        {Pid, _Roles, Next} ->
            Seen1 = Seen + 1,
            Chosen1 =
                case rand:uniform(Seen1) =:= 1 of
                    true -> Pid;
                    false -> Chosen
                end,
            pick_member(Next, Seen1, Chosen1, [Pid | Pids])
    end.
join_channels([], _, _, _) ->
    ok;
join_channels([Name | Names], Keys, Pid, Server) ->
    {Password, Remaining} =
        case Keys of
            [Key | Tail] -> {Key, Tail};
            [] -> {undefined, []}
        end,
    join(Name, Password, ircd_state_client:client(Pid), Server),
    join_channels(Names, Remaining, Pid, Server).

%% Resolve safe channel names, then apply membership, key, limit, and ban checks.
join(Name, Password, Client, Server) ->
    case resolve_channel(Name) of
        error ->
            ircd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        {ok, Canonical} ->
            Key = ircd_wire:fold(Canonical),
            case lists:member(Key, Client#client.channels) of
                true -> ok;
                false -> add_member(Key, Canonical, Client, Server, Password)
            end
    end.

resolve_channel(<<$!, Short/binary>> = Requested) ->
    Key = ircd_wire:fold(Requested),
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Existing}] ->
            {ok, Existing};
        [] ->
            case {byte_size(Short) =< 44, ircd_wire:channel(<<$#, Short/binary>>)} of
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
    case ircd_wire:channel(Name) of
        true -> {ok, Name};
        false -> error
    end.

find_safe_short(Short) ->
    Wanted = ircd_wire:fold(Short),
    case
        [
            Name
         || Key <- mnesia:dirty_all_keys(channel),
            [#channel{name = <<$!, _Id:5/binary, ExistingShort/binary>> = Name}] <-
                [mnesia:dirty_read(channel, Key)],
            ircd_wire:fold(ExistingShort) =:= Wanted
        ]
    of
        [Name | _] -> {ok, Name};
        [] -> none
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

%% Add a client to a channel and grant operator status to the first member.
add_member(Key, Name, #client{pid = Pid} = Client, Server, Password) ->
    {Channel, IsNew} =
        case mnesia:dirty_read(channel, Key) of
            [Existing] ->
                {Existing, false};
            [] ->
                {
                    #channel{
                        key = Key,
                        name = Name,
                        creator =
                            case binary:first(Name) of
                                $! -> Pid;
                                _ -> undefined
                            end,
                        flags =
                            case binary:first(Name) of
                                $+ -> #{$t => true};
                                _ -> #{}
                            end
                    },
                    true
                }
        end,
    #channel{name = Canonical, members = Members} = Channel,
    Admin = ircd_state:administrator(Pid) andalso ircd_state:predefined_channel(Key),
    Role =
        case {IsNew, binary:first(Canonical), Admin} of
            {true, $!, _} -> [operator, creator];
            {_, $+, _} -> [member];
            {true, _, _} -> [operator];
            {false, _, true} -> [operator];
            _ -> [member]
        end,
    NewMembers =
        case Role of
            Roles when is_list(Roles) -> Members#{Pid => Roles};
            _ -> Members#{Pid => [Role]}
        end,
    Joined = length(Client#client.channels),
    case ircd_state_net:channel_blocked(Canonical) of
        true ->
            ircd_state_send:numeric(
                Client,
                Server,
                <<"437">>,
                [Canonical],
                <<"Nick/channel is temporarily unavailable">>
            );
        false ->
            case ircd_route:channel_allowed(Joined, ircd_route:max_channels()) of
                false ->
                    ircd_state_send:numeric(
                        Client,
                        Server,
                        <<"405">>,
                        [Canonical],
                        <<"You have joined too many channels">>
                    );
                true ->
                    join_checked(Channel, Client, Server, NewMembers, Members, Password)
            end
    end.

join_checked(
    Channel, #client{pid = Pid, channels = Channels} = Client, Server, NewMembers, Members, Password
) ->
    Canonical = Channel#channel.name,
    case Channel of
        #channel{password = Required} when Required =/= undefined, Required =/= Password ->
            ircd_state_send:numeric(
                Client, Server, <<"475">>, [Canonical], <<"Cannot join channel (+k)">>
            );
        #channel{limit = Limit} when is_integer(Limit), map_size(Members) >= Limit ->
            ircd_state_send:numeric(
                Client, Server, <<"471">>, [Canonical], <<"Cannot join channel (+l)">>
            );
        _ ->
            Invited =
                lists:member(Pid, Channel#channel.invited) orelse
                    mask_matches(Channel, invite, Client),
            Banned =
                mask_matches(Channel, ban, Client) andalso
                    not mask_matches(Channel, exception, Client),
            case {maps:is_key($i, Channel#channel.flags) andalso not Invited, Banned} of
                {true, _} ->
                    ircd_state_send:numeric(
                        Client, Server, <<"473">>, [Canonical], <<"Cannot join channel (+i)">>
                    );
                {_, true} ->
                    ircd_state_send:numeric(
                        Client, Server, <<"474">>, [Canonical], <<"Cannot join channel (+b)">>
                    );
                _ ->
                    finish_join(Channel, Client, Server, NewMembers, Channels)
            end
    end.

finish_join(
    #channel{key = Key, name = Canonical, invited = Invited, flags = Flags} = Channel,
    #client{pid = Pid} = Client,
    Server,
    NewMembers,
    Channels
) ->
    mnesia:dirty_write(Channel#channel{
        members = NewMembers,
        invited = lists:delete(Pid, Invited)
    }),
    mnesia:dirty_write(Client#client{channels = [Key | Channels]}),
    ircd_state_link:propagate_join(Client, Canonical, maps:get(Pid, NewMembers)),
    JoinRecipients =
        case maps:is_key($q, Flags) of
            true -> [Pid];
            false -> maps:keys(NewMembers)
        end,
    Origin = channel_origin_prefix(Channel, Client),
    Anonymous = maps:is_key($a, Flags),
    {JoinAccount, JoinReal} =
        case Anonymous of
            true -> {undefined, <<"anonymous">>};
            false -> {ircd_state_v3:account(Pid), Client#client.real}
        end,
    ircd_state_v3:join_broadcast(JoinRecipients, Origin, Canonical, JoinAccount, JoinReal),
    ircd_state_history:note_event(Key, <<"JOIN">>, Origin, [], none),
    case Anonymous of
        true ->
            ok;
        false ->
            ircd_state_v3:away_on_join(
                [P || P <- JoinRecipients, P =/= Pid], Origin, Client#client.away
            )
    end,
    topic_reply(Channel, Client, Server),
    ircd_state_history:markread_on_join(Pid, Canonical, Server),
    case ircd_cap:enabled(Pid, <<"no-implicit-names">>) of
        true -> ok;
        false -> names(Canonical, Client, Server)
    end,
    ircd_state_meta:on_join(Key, Client, Server),
    replay_channel_history(Key, Canonical, Pid).

leave(Key, Client, Command, Reason, Notify) ->
    leave(Key, Client, Command, Reason, Notify, Notify).

leave(Key, #client{pid = Pid} = Client, Command, Reason, Notify, Propagate) ->
    [#channel{name = Name, members = Members, flags = Flags} = Channel] =
        mnesia:dirty_read(channel, Key),
    case Notify of
        true ->
            Recipients =
                case maps:is_key($q, Flags) of
                    true -> [Pid];
                    false -> maps:keys(Members)
                end,
            ircd_state_send:broadcast(
                Recipients, channel_origin_prefix(Channel, Client), Command, [Name], Reason
            ),
            ircd_state_history:note_event(
                Key, Command, channel_origin_prefix(Channel, Client), [], Reason
            );
        false ->
            ok
    end,
    case Propagate andalso Command =:= <<"PART">> of
        true ->
            ReasonParams =
                case Reason of
                    none -> none;
                    _ -> Reason
                end,
            ircd_state_link:server_broadcast(
                ircd_wire:line(ircd_state_send:prefix(Client), <<"PART">>, [Name], ReasonParams)
            );
        false ->
            ok
    end,
    case maps:remove(Pid, Members) of
        Remaining when map_size(Remaining) =:= 0 ->
            release_if_empty(Channel, Remaining);
        Remaining ->
            mnesia:dirty_write(track_opless(Channel, Remaining))
    end,
    Current = ircd_state_client:client(Pid),
    mnesia:dirty_write(Current#client{channels = lists:delete(Key, Current#client.channels)}).

kick(_, [], _, _, _) ->
    ok;
kick(Name, [Nick | Nicks], Reason, #client{pid = Pid} = Client, Server) ->
    Key = ircd_wire:fold(Name),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            ircd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        [#channel{name = Canonical, members = Members} = Channel] ->
            case maps:is_key(Pid, Members) of
                false ->
                    ircd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                true ->
                    case lists:member(operator, maps:get(Pid, Members, [])) of
                        false ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"482">>,
                                [Canonical],
                                <<"You're not channel operator">>
                            );
                        true ->
                            kick_member(
                                Nick, Nicks, Reason, Client, Server, Key, Canonical, Channel
                            )
                    end
            end
    end.

kick_member(
    Nick,
    Nicks,
    Reason,
    Client,
    Server,
    Key,
    Canonical,
    #channel{members = Members} = Channel
) ->
    case ircd_state_client:find_nick(Nick) of
        undefined ->
            ircd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>),
            kick(Canonical, Nicks, Reason, Client, Server);
        #client{pid = TargetPid, nick = Actual} = Target ->
            case maps:is_key(TargetPid, Members) of
                false ->
                    ircd_state_send:numeric(
                        Client,
                        Server,
                        <<"441">>,
                        [Actual, Canonical],
                        <<"They aren't on that channel">>
                    ),
                    kick(Canonical, Nicks, Reason, Client, Server);
                true ->
                    ircd_state_send:broadcast(
                        case maps:is_key($q, Channel#channel.flags) of
                            true -> [Client#client.pid, TargetPid];
                            false -> maps:keys(Members)
                        end,
                        channel_origin_prefix(Channel, Client),
                        <<"KICK">>,
                        [Canonical, Actual],
                        Reason
                    ),
                    ircd_state_history:note_event(
                        Key, <<"KICK">>, channel_origin_prefix(Channel, Client), [Actual], Reason
                    ),
                    ircd_state_link:propagate_channel_kick(Client, Canonical, Actual, Reason),
                    Remaining = maps:remove(TargetPid, Members),
                    case map_size(Remaining) of
                        0 ->
                            release_if_empty(Channel, Remaining);
                        _ ->
                            mnesia:dirty_write(track_opless(Channel, Remaining))
                    end,
                    mnesia:dirty_write(Target#client{
                        channels = lists:delete(Key, Target#client.channels)
                    }),
                    kick(Canonical, Nicks, Reason, Client, Server)
            end
    end.
nick_recipients(#client{pid = Pid, channels = Channels}) ->
    lists:usort([
        Pid
        | [
            Other
         || Key <- Channels,
            [#channel{members = Members, flags = Flags}] <- [mnesia:dirty_read(channel, Key)],
            not maps:is_key($a, Flags),
            not maps:is_key($q, Flags),
            Other <- maps:keys(Members),
            Other =/= Pid
        ]
    ]).

channel_origin_prefix(#channel{flags = Flags}, _Client) when is_map_key($a, Flags) ->
    <<"anonymous!anonymous@anonymous.">>;
channel_origin_prefix(_, Client) ->
    ircd_state_send:prefix(Client).

%% Route PRIVMSG/NOTICE/TAGMSG to nicknames and channels, applying channel restrictions.
%% Client-only tags are relayed. Each delivered message gets a `msgid` and a
%% `time` tag (filtered per recipient by capability). TAGMSG has no text body.
deliver(Command, Params, #client{pid = Pid} = Client, Server, Tags) ->
    ClientTags =
        case ircd_cap:enabled(Pid, <<"message-tags">>) of
            true -> ircd_cap:client_tags(Tags);
            false -> []
        end,
    case {Command, Params} of
        {<<"TAGMSG">>, []} ->
            message_error(Command, Client, Server, <<"411">>, [], <<"No recipient given">>);
        {<<"TAGMSG">>, [Targets | _]} ->
            deliver_targets(Targets, none, Command, Client, Server, ClientTags);
        {_, []} ->
            message_error(Command, Client, Server, <<"411">>, [], <<"No recipient given">>);
        {_, [_]} ->
            message_error(Command, Client, Server, <<"412">>, [], <<"No text to send">>);
        {_, [_, <<>> | _]} ->
            message_error(Command, Client, Server, <<"412">>, [], <<"No text to send">>);
        {_, [Targets, Text | _]} ->
            deliver_targets(Targets, Text, Command, Client, Server, ClientTags)
    end.

deliver_targets(Targets, Text, Command, Client, Server, Tags) ->
    lists:foreach(
        fun(Target) -> deliver_body(Command, Target, Text, Client, Server, Tags) end,
        lists:uniq(split(Targets))
    ).

%% @doc Deliver one message body to one target. `Body` is a binary, `none`
%% for TAGMSG, or `{multiline, Lines}` from a draft/multiline batch.
deliver_body(Command, Target, Body, #client{pid = Pid} = Client, Server, ClientTags) ->
    MsgId = ircd_state_send:msgid(),
    Now = erlang:system_time(millisecond),
    %% message-tags: server tags come before client-only tags.
    Tags = [{<<"msgid">>, MsgId}, {<<"time">>, ircd_state_send:time_value(Now)} | ClientTags],
    Account = ircd_state_v3:account(Pid),
    case mnesia:dirty_read(channel, ircd_wire:fold(Target)) of
        [#channel{name = Name, members = Members, flags = Flags} = Channel] ->
            Roles = maps:get(Pid, Members, []),
            Outside = maps:is_key($n, Flags) andalso not maps:is_key(Pid, Members),
            Moderated =
                maps:is_key($m, Flags) andalso
                    not (lists:member(operator, Roles) orelse lists:member(voice, Roles)),
            Banned =
                mask_matches(Channel, ban, Client) andalso
                    not mask_matches(Channel, exception, Client),
            BannedWithoutPrivilege =
                Banned andalso
                    not (lists:member(operator, Roles) orelse lists:member(voice, Roles)),
            case Outside orelse Moderated orelse BannedWithoutPrivilege of
                true ->
                    message_error(
                        Command, Client, Server, <<"404">>, [Name], <<"Cannot send to channel">>
                    );
                false ->
                    Origin = channel_origin_prefix(Channel, Client),
                    Recipients = maps:keys(maps:remove(Pid, Members)),
                    fan_out(Recipients, Origin, Command, Name, Body, Tags),
                    echo(Pid, Origin, Command, Name, Body, Tags),
                    Stored =
                        case maps:is_key($a, Flags) of
                            true -> undefined;
                            false -> Account
                        end,
                    ircd_state_history:note_channel(
                        ircd_wire:fold(Name),
                        ircd_state_history:entry(
                            Command, Origin, Body, MsgId, Now, ClientTags, Stored
                        )
                    ),
                    lists:foreach(
                        fun({Text, LineTags}) ->
                            ircd_state_link:propagate_channel_message(
                                Name, Text, Command, Client, LineTags
                            )
                        end,
                        wire_lines(Body, Tags)
                    )
            end;
        [] ->
            Recipient =
                case ircd_state_client:find_nick(Target) of
                    #client{} = Found ->
                        case ircd_state_client:ready(Found) of
                            true -> Found;
                            false -> held
                        end;
                    undefined ->
                        undefined
                end,
            case Recipient of
                held ->
                    message_error(
                        Command, Client, Server, <<"401">>, [Target], <<"No such nick/channel">>
                    );
                #client{pid = Other, nick = Nick, away = Away} ->
                    Prefix = ircd_state_send:prefix(Client),
                    case Other =:= Pid andalso ircd_cap:enabled(Pid, <<"echo-message">>) of
                        true -> ok;
                        false -> fan_out([Other], Prefix, Command, Nick, Body, Tags)
                    end,
                    echo(Pid, Prefix, Command, Nick, Body, Tags),
                    ircd_state_history:note_direct(
                        Account,
                        ircd_state_v3:account(Other),
                        Nick,
                        ircd_state_history:entry(
                            Command, Prefix, Body, MsgId, Now, ClientTags, Account
                        )
                    ),
                    case {Command, Away} of
                        {<<"PRIVMSG">>, Message} when Message =/= undefined ->
                            ircd_state_send:numeric(Client, Server, <<"301">>, [Nick], Message);
                        _ ->
                            ok
                    end;
                undefined ->
                    case mnesia:dirty_read(remote_client, ircd_wire:fold(Target)) of
                        [#remote_client{peer = Peer, nick = Nick, account = Theirs}] ->
                            Prefix = ircd_state_send:prefix(Client),
                            Results = [
                                ircd_links:send(
                                    Peer, ircd_wire:message(LineTags, Prefix, Command, [Nick], Text)
                                )
                             || {Text, LineTags} <- wire_lines(Body, Tags)
                            ],
                            case lists:all(fun(R) -> R =:= ok end, Results) of
                                true ->
                                    echo(Pid, Prefix, Command, Nick, Body, Tags),
                                    ircd_state_history:note_direct(
                                        Account,
                                        Theirs,
                                        Nick,
                                        ircd_state_history:entry(
                                            Command, Prefix, Body, MsgId, Now, ClientTags, Account
                                        )
                                    );
                                false ->
                                    message_error(
                                        Command,
                                        Client,
                                        Server,
                                        <<"401">>,
                                        [Target],
                                        <<"No such nick/channel">>
                                    )
                            end;
                        [] ->
                            message_error(
                                Command,
                                Client,
                                Server,
                                <<"401">>,
                                [Target],
                                <<"No such nick/channel">>
                            )
                    end
            end
    end.

fan_out(Pids, Prefix, Command, Target, {multiline, Lines}, Tags) ->
    lists:foreach(
        fun(P) ->
            ircd_state_batch:deliver_multiline(P, Prefix, Command, Target, Lines, Tags, normal)
        end,
        Pids
    );
fan_out(Pids, Prefix, Command, Target, Text, Tags) ->
    ircd_state_send:broadcast(Pids, Prefix, Command, [Target], Text, Tags).

%% echo-message: the sender gets the message as recipients saw it.
echo(Pid, Prefix, Command, Target, Body, Tags) ->
    case ircd_cap:enabled(Pid, <<"echo-message">>) of
        false ->
            ok;
        true ->
            case Body of
                {multiline, Lines} ->
                    ircd_state_batch:deliver_multiline(
                        Pid, Prefix, Command, Target, Lines, Tags, echo
                    );
                _ ->
                    ircd_state_send:echo(Pid, Prefix, Command, [Target], Body, Tags)
            end
    end.

%% Server-link form of a body: one line, or the multiline fallback lines with
%% the message tags on the first.
wire_lines({multiline, Lines}, Tags) ->
    NonBlank = [Text || {_, Text} <- Lines, Text =/= <<>>],
    {Out, _} = lists:mapfoldl(
        fun(Text, First) ->
            case First of
                true -> {{Text, Tags}, false};
                false -> {{Text, [T || {<<"+", _/binary>>, _} = T <- Tags]}, false}
            end
        end,
        true,
        NonBlank
    ),
    Out;
wire_lines(Text, Tags) ->
    [{Text, Tags}].

message_error(<<"NOTICE">>, _, _, _, _, _) ->
    ok;
message_error(_, Client, Server, Number, Middle, Text) ->
    ircd_state_send:numeric(Client, Server, Number, Middle, Text).

%% Remember an accepted channel PRIVMSG or NOTICE from a peer. The body is not
%% logged. `Tags` may carry the peer's `msgid` and `time`.
note_channel_history(Key, Command, Prefix, Text) ->
    note_channel_history(Key, Command, Prefix, Text, []).

note_channel_history(Key, Command, Prefix, Text, Tags) when is_binary(Text) ->
    MsgId =
        case lists:keyfind(<<"msgid">>, 1, Tags) of
            {_, Id} when is_binary(Id) -> Id;
            _ -> ircd_state_send:msgid()
        end,
    Time =
        case lists:keyfind(<<"time">>, 1, Tags) of
            {_, Stamp} when is_binary(Stamp) ->
                case ircd_state_history:parse_timestamp(Stamp) of
                    {ok, T} -> T;
                    error -> erlang:system_time(millisecond)
                end;
            _ ->
                erlang:system_time(millisecond)
        end,
    Account = maps:get(
        account, ircd_state_v3:remote_source_info(iolist_to_binary(Prefix)), undefined
    ),
    ircd_state_history:note_channel(
        Key,
        ircd_state_history:entry(
            Command, Prefix, Text, MsgId, Time, ircd_cap:client_tags(Tags), Account
        )
    );
note_channel_history(_Key, _Command, _Prefix, _Text, _Tags) ->
    ok.

replay_channel_history(Key, Name, Pid) ->
    ircd_state_history:replay_on_join(Key, Name, Pid).

topic(Name, Rest, #client{pid = Pid} = Client, Server) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, flags = Flags} = Channel] ->
            Operator = lists:member(operator, maps:get(Pid, Members, [])),
            Hidden = maps:is_key($s, Flags) andalso not maps:is_key(Pid, Members),
            case {Hidden, maps:is_key(Pid, Members), Rest} of
                {true, _, _} ->
                    ircd_state_send:numeric(
                        Client, Server, <<"403">>, [Canonical], <<"No such channel">>
                    );
                {false, false, [_ | _]} ->
                    ircd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                {false, _, []} ->
                    topic_reply(effective_topic(Channel), Client, Server);
                {false, true, [_ | _]} when is_map_key($t, Flags), not Operator ->
                    ircd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    );
                {false, true, [Text | _]} ->
                    mnesia:dirty_write(Channel#channel{topic = ircd_wire:retain(Text)}),
                    ircd_state_history:note_event(
                        Channel#channel.key,
                        <<"TOPIC">>,
                        channel_origin_prefix(Channel, Client),
                        [],
                        Text
                    ),
                    ircd_state_send:broadcast(
                        maps:keys(Members),
                        channel_origin_prefix(Channel, Client),
                        <<"TOPIC">>,
                        [Canonical],
                        Text
                    ),
                    ircd_state_link:propagate_topic(Client, Canonical, Text)
            end;
        [] ->
            case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
                [#remote_channel{name = Canonical, flags = RemoteFlags}] ->
                    case {maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags), Rest} of
                        {true, _} ->
                            ircd_state_send:numeric(
                                Client, Server, <<"403">>, [Canonical], <<"No such channel">>
                            );
                        {false, []} ->
                            topic_reply(
                                #channel{
                                    name = Canonical, topic = maps:get(topic, RemoteFlags, <<>>)
                                },
                                Client,
                                Server
                            );
                        {false, [_ | _]} ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"442">>,
                                [Canonical],
                                <<"You're not on that channel">>
                            )
                    end;
                [] ->
                    ircd_state_send:numeric(
                        Client, Server, <<"403">>, [Name], <<"No such channel">>
                    )
            end
    end.

effective_topic(#channel{name = Name, topic = <<>>} = Channel) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{flags = RemoteFlags}] ->
            Channel#channel{topic = maps:get(topic, RemoteFlags, <<>>)};
        [] ->
            Channel
    end;
effective_topic(Channel) ->
    Channel.

topic_reply(#channel{name = Name, topic = <<>>}, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"331">>, [Name], <<"No topic is set">>);
topic_reply(#channel{name = Name, topic = Topic}, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"332">>, [Name], Topic).

names(Name, Client, Server) ->
    Canonical =
        case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
            [#channel{name = Existing, members = Members, flags = Flags}] ->
                LocalMember = maps:is_key(Client#client.pid, Members),
                RemoteFlags = ircd_state_link:remote_channel_flags(Name),
                Hidden =
                    (not LocalMember andalso
                        (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))) orelse
                        (not LocalMember andalso
                            (maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags))),
                case Hidden of
                    true ->
                        ok;
                    false ->
                        VisiblePids =
                            case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                                true ->
                                    case maps:is_key(Client#client.pid, Members) of
                                        true -> [Client#client.pid];
                                        false -> []
                                    end;
                                false ->
                                    maps:keys(Members)
                            end,
                        LocalEntries = [
                            display_nick(
                                ircd_state_client:client(Pid), maps:get(Pid, Members), Client
                            )
                         || Pid <- VisiblePids,
                            visible_member(Pid, Client, Members)
                        ],
                        RemoteEntries =
                            case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                                true ->
                                    [];
                                false ->
                                    ircd_state_link:remote_names_entries(Name, Client, LocalMember)
                            end,
                        Entries = lists:usort(fun nick_less/2, LocalEntries ++ RemoteEntries),
                        names_lines(Entries, [], 0, Existing, Client, Server)
                end,
                Existing;
            [] ->
                case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
                    [#remote_channel{name = Existing, flags = Flags}] ->
                        case
                            maps:is_key($p, Flags) orelse maps:is_key($s, Flags) orelse
                                maps:is_key($a, Flags)
                        of
                            true ->
                                ok;
                            false ->
                                names_lines(
                                    ircd_state_link:remote_names_entries(Name, Client, false),
                                    [],
                                    0,
                                    Existing,
                                    Client,
                                    Server
                                )
                        end,
                        Existing;
                    [] ->
                        Name
                end
        end,
    ircd_state_send:numeric(Client, Server, <<"366">>, [Canonical], <<"End of NAMES list">>).

names_listing(Key, Client, Server) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Name, members = Members, flags = Flags}] ->
            RemoteFlags = ircd_state_link:remote_channel_flags(Name),
            LocalMember = maps:is_key(Client#client.pid, Members),
            Visible =
                LocalMember orelse
                    not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags) orelse
                        maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags)),

            case Visible of
                true ->
                    VisiblePids =
                        case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                            true ->
                                case maps:is_key(Client#client.pid, Members) of
                                    true -> [Client#client.pid];
                                    false -> []
                                end;
                            false ->
                                maps:keys(Members)
                        end,
                    LocalEntries = [
                        display_nick(
                            ircd_state_client:client(Pid), maps:get(Pid, Members), Client
                        )
                     || Pid <- VisiblePids,
                        visible_member(Pid, Client, Members)
                    ],
                    RemoteEntries =
                        case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                            true -> [];
                            false -> ircd_state_link:remote_names_entries(Name, Client, LocalMember)
                        end,
                    Entries = lists:usort(fun nick_less/2, LocalEntries ++ RemoteEntries),
                    names_lines(Entries, [], 0, Name, Client, Server);
                false ->
                    ok
            end;
        [] ->
            ok
    end.

nick_less(Left, Right) -> ircd_wire:fold(Left) =< ircd_wire:fold(Right).

names_unattached(#client{pid = RequesterPid}, Server) ->
    Requester = ircd_state_client:client(RequesterPid),
    Entries = lists:sort([
        Member#client.nick
     || Pid <- mnesia:dirty_all_keys(client),
        [Member] <- [mnesia:dirty_read(client, Pid)],
        ircd_state_client:ready(Member),
        ircd_state_client:user_visible(Member, Requester),
        not has_visible_channel(Member#client.channels, Requester)
    ]),
    names_lines(Entries, [], 0, <<"*">>, Requester, Server).

visible_member(Pid, Requester, Members) ->
    maps:is_key(Requester#client.pid, Members) orelse
        case mnesia:dirty_read(client, Pid) of
            [Member] -> ircd_state_client:user_visible(Member, Requester);
            [] -> false
        end.

has_visible_channel(Keys, #client{pid = RequesterPid}) ->
    lists:any(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{members = Members, flags = Flags}] ->
                    maps:is_key(RequesterPid, Members) orelse
                        not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags));
                [] ->
                    false
            end
        end,
        Keys
    ).

names_lines([], [], _, _, _, _) ->
    ok;
names_lines([], Acc, _, Name, Client, Server) ->
    ircd_state_send:numeric(
        Client,
        Server,
        <<"353">>,
        [names_symbol(Name), Name],
        lists:join(<<" ">>, lists:reverse(Acc))
    );
names_lines([Entry | Rest], Acc, Size, Name, Client, Server) when Size + byte_size(Entry) < 370 ->
    names_lines(Rest, [Entry | Acc], Size + byte_size(Entry) + 1, Name, Client, Server);
names_lines(Entries, Acc, _, Name, Client, Server) ->
    names_lines([], Acc, 0, Name, Client, Server),
    names_lines(Entries, [], 0, Name, Client, Server).

names_symbol(<<"*">>) ->
    <<"*">>;
names_symbol(Name) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{flags = Flags}] when is_map_key($s, Flags) -> <<"@">>;
        [#channel{flags = Flags}] when is_map_key($p, Flags) -> <<"*">>;
        _ ->
            case ircd_state_link:remote_channel_flags(Name) of
                Flags when is_map_key($s, Flags) -> <<"@">>;
                Flags when is_map_key($p, Flags) -> <<"*">>;
                _ -> <<"=">>
            end
    end.

%% NAMES entry for a local member as seen by Requester: multi-prefix shows
%% every status prefix and userhost-in-names adds `!user@host`.
display_nick(#client{nick = Nick, user = User, host = Host}, Roles, #client{pid = Requester}) ->
    Name =
        case ircd_cap:enabled(Requester, <<"userhost-in-names">>) of
            true -> <<Nick/binary, "!", User/binary, "@", Host/binary>>;
            false -> Nick
        end,
    <<(role_prefix(Roles, Requester))/binary, Name/binary>>.

%% @doc Status prefix for channel roles. With multi-prefix the requester sees
%% every prefix in rank order (`@+`), otherwise only the highest.
-spec role_prefix([atom()], pid()) -> binary().
role_prefix(Roles, Requester) ->
    Operator = lists:member(operator, Roles) orelse lists:member(creator, Roles),
    Voice = lists:member(voice, Roles),
    case {Operator, Voice, ircd_cap:enabled(Requester, <<"multi-prefix">>)} of
        {true, true, true} -> <<"@+">>;
        {true, _, _} -> <<"@">>;
        {false, true, _} -> <<"+">>;
        _ -> <<>>
    end.

%% Ban, exception, and invite masks. `$a:<account>` (IRCv3 account-extban,
%% advertised as EXTBAN=$,a and ACCOUNTEXTBAN=a) matches a logged-in user by
%% account name with wildcards and RFC 1459 folding; `$a` alone matches any
%% logged-in user. Other masks match `nick!user@host`.
mask_matches(
    #channel{lists = Lists}, Type, #client{nick = Nick, user = User, host = Host} = Client
) ->
    Identity = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
    lists:any(
        fun
            (<<"$a:", AccountMask/binary>>) ->
                case identity_account(Client) of
                    undefined -> false;
                    Account -> wildcard_match(AccountMask, Account)
                end;
            (<<"$a">>) ->
                identity_account(Client) =/= undefined;
            (Mask) ->
                wildcard_match(Mask, Identity)
        end,
        maps:get(Type, Lists, [])
    ).

identity_account(#client{pid = Pid}) when is_pid(Pid) ->
    ircd_state_v3:account(Pid);
identity_account(#client{nick = Nick}) ->
    ircd_state_v3:remote_account(ircd_wire:fold(Nick)).

wildcard_match(Mask, Value) ->
    wildcard_match_chars(
        binary_to_list(ircd_wire:fold(Mask)),
        binary_to_list(ircd_wire:fold(Value))
    ).

wildcard_match_chars([], []) ->
    true;
wildcard_match_chars([$* | Mask], Value) ->
    wildcard_match_chars(Mask, Value) orelse
        case Value of
            [] -> false;
            [_ | Rest] -> wildcard_match_chars([$* | Mask], Rest)
        end;
wildcard_match_chars([$? | Mask], [_ | Value]) ->
    wildcard_match_chars(Mask, Value);
wildcard_match_chars([Char | Mask], [Char | Value]) ->
    wildcard_match_chars(Mask, Value);
wildcard_match_chars(_, _) ->
    false.

knock(Name, ReasonParams, #client{pid = Pid} = Client, Server) ->
    Reason =
        case ReasonParams of
            [Text | _] -> Text;
            [] -> <<>>
        end,
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [] ->
            ircd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        [#channel{name = Canonical, members = Members, flags = Flags} = Channel] ->
            case maps:is_key(Pid, Members) of
                true ->
                    ircd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're already on that channel">>
                    );
                false ->
                    case {maps:is_key($K, Flags), maps:is_key($i, Flags)} of
                        {true, _} ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"480">>,
                                [Canonical],
                                <<"Cannot knock on channel">>
                            );
                        {false, false} ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"480">>,
                                [Canonical],
                                <<"Channel is not invite-only">>
                            );
                        {false, true} ->
                            Operators = [
                                MemberPid
                             || {MemberPid, Roles} <- maps:to_list(Members),
                                lists:member(operator, Roles)
                            ],
                            case Operators of
                                [] ->
                                    ircd_state_send:numeric(
                                        Client,
                                        Server,
                                        <<"480">>,
                                        [Canonical],
                                        <<"No channel operators available">>
                                    );
                                _ ->
                                    ircd_state_send:broadcast(
                                        Operators,
                                        channel_origin_prefix(Channel, Client),
                                        <<"KNOCK">>,
                                        [Canonical],
                                        Reason
                                    ),
                                    ok
                            end
                    end
            end
    end.

invite(Nick, Name, #client{pid = Pid} = Client, Server) ->
    Found =
        case ircd_state_client:find_nick(Nick) of
            #client{} = Local ->
                case ircd_state_client:ready(Local) of
                    true -> Local;
                    false -> held
                end;
            undefined ->
                undefined
        end,
    case Found of
        held ->
            ircd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>);
        undefined ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [#remote_client{} = Remote] ->
                    invite_remote(Remote, Name, Client, Server);
                [] ->
                    ircd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>)
            end;
        #client{} = Target ->
            case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
                [] ->
                    notify_invite(Target, Name, Client, Server);
                [
                    #channel{
                        name = Canonical,
                        members = Members,
                        flags = Flags,
                        invited = Invited
                    } = Channel
                ] ->
                    IsMember = maps:is_key(Pid, Members),
                    IsOperator = lists:member(operator, maps:get(Pid, Members, [])),
                    case
                        {
                            maps:is_key(Target#client.pid, Members),
                            IsMember,
                            maps:is_key($i, Flags) andalso not IsOperator
                        }
                    of
                        {true, _, _} ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"443">>,
                                [Target#client.nick, Canonical],
                                <<"is already on channel">>
                            );
                        {false, false, _} ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"442">>,
                                [Canonical],
                                <<"You're not on that channel">>
                            );
                        {false, true, true} ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"482">>,
                                [Canonical],
                                <<"You're not channel operator">>
                            );
                        {false, true, false} ->
                            mnesia:dirty_write(Channel#channel{
                                invited =
                                    lists:usort([Target#client.pid | Invited])
                            }),
                            notify_invite(Target, Canonical, Client, Server),
                            ircd_state_v3:invite_notify(
                                Channel,
                                Target,
                                Target#client.nick,
                                {Pid, invite_origin_prefix(Canonical, Client)}
                            )
                    end
            end
    end.

invite_remote(
    #remote_client{key = NickKey, nick = RemoteNick, peer = Dest},
    Name,
    #client{pid = Pid} = Client,
    Server
) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [] ->
            ircd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        [#channel{name = Canonical, members = Members, flags = Flags}] ->
            IsMember = maps:is_key(Pid, Members),
            IsOperator = lists:member(operator, maps:get(Pid, Members, [])),
            case {IsMember, maps:is_key($i, Flags) andalso not IsOperator} of
                {false, _} ->
                    ircd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                {true, true} ->
                    ircd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    );
                {true, false} ->
                    remember_remote_invite(NickKey, Canonical),
                    ircd_state_send:numeric(
                        Client, Server, <<"341">>, [RemoteNick, Canonical], none
                    ),
                    ircd_state_link:propagate_invite(Client, RemoteNick, Canonical, Dest)
            end
    end.

remember_remote_invite(NickKey, Name) ->
    Key = ircd_wire:fold(Name),
    Channel =
        case mnesia:dirty_read(remote_channel, Key) of
            [Existing] -> Existing;
            [] -> #remote_channel{key = Key, name = Name}
        end,
    Invited = Channel#remote_channel.invited,
    mnesia:dirty_write(Channel#remote_channel{invited = Invited#{NickKey => true}}).

notify_invite(
    #client{pid = TargetPid, nick = TargetNick, away = Away},
    Channel,
    Client,
    Server
) ->
    ircd_state_send:numeric(Client, Server, <<"341">>, [TargetNick, Channel], none),
    ircd_state_send:send(
        TargetPid, invite_origin_prefix(Channel, Client), <<"INVITE">>, [TargetNick, Channel], none
    ),
    case Away of
        undefined -> ok;
        _ -> ircd_state_send:numeric(Client, Server, <<"301">>, [TargetNick], Away)
    end.

invite_origin_prefix(Channel, Client) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Channel)) of
        [Record] -> channel_origin_prefix(Record, Client);
        [] -> ircd_state_send:prefix(Client)
    end.

%% Route MODE to a channel or to the requesting user's supported modes.
mode_command(Target, Rest, Client, Server) ->
    case ircd_wire:channel(Target) of
        true -> channel_mode(Target, Rest, Client, Server);
        false -> user_mode(Target, Rest, Client, Server)
    end.

user_mode(Target, Rest, #client{pid = Pid} = Client, Server) ->
    case ircd_state_client:find_nick(Target) of
        undefined ->
            ircd_state_send:numeric(
                Client, Server, <<"401">>, [Target], <<"No such nick/channel">>
            );
        #client{pid = Other} when Other =/= Pid ->
            ircd_state_send:numeric(
                Client, Server, <<"502">>, [], <<"Cannot change mode for other users">>
            );
        #client{nick = Nick} ->
            Modes = ircd_state_client:user_modes(Pid),
            case Rest of
                [] ->
                    ircd_state_send:numeric(
                        Client, Server, <<"221">>, [user_mode_string(Modes)], none
                    );
                [ModeSpec | _] ->
                    change_user_modes(
                        binary_to_list(ModeSpec),
                        undefined,
                        Modes,
                        Nick,
                        Client,
                        Server
                    )
            end
    end.

user_mode_string(Modes) ->
    list_to_binary([$+ | lists:sort(maps:keys(Modes))]).

change_user_modes([], _, Modes, _, Client, _Server) ->
    mnesia:dirty_write(#user_modes{pid = Client#client.pid, modes = Modes});
change_user_modes([$+ | Rest], _, Modes, Nick, Client, Server) ->
    change_user_modes(Rest, add, Modes, Nick, Client, Server);
change_user_modes([$- | Rest], _, Modes, Nick, Client, Server) ->
    change_user_modes(Rest, remove, Modes, Nick, Client, Server);
change_user_modes([_Mode | Rest], undefined, Modes, Nick, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"501">>, [], <<"Unknown MODE flag">>),
    change_user_modes(Rest, undefined, Modes, Nick, Client, Server);
change_user_modes([Mode | Rest], Action, Modes, Nick, Client, Server) when
    Mode =:= $i; Mode =:= $w; Mode =:= $B
->
    New =
        case Action of
            add -> Modes#{Mode => true};
            remove -> maps:remove(Mode, Modes)
        end,
    case New =/= Modes of
        true ->
            mnesia:dirty_write(#user_modes{pid = Client#client.pid, modes = New}),
            Sign =
                case Action of
                    add -> $+;
                    remove -> $-
                end,
            ircd_state_send:send(
                Client#client.pid,
                ircd_state_send:prefix(Client),
                <<"MODE">>,
                [Nick, <<Sign, Mode>>],
                none
            ),
            ircd_state_link:server_broadcast(
                ircd_wire:line(
                    ircd_state_send:prefix(Client), <<"MODE">>, [Nick, <<Sign, Mode>>], none
                )
            );
        false ->
            ok
    end,
    change_user_modes(Rest, Action, New, Nick, Client, Server);
change_user_modes([$o | Rest], Action, Modes, Nick, Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>
    ),
    change_user_modes(Rest, Action, Modes, Nick, Client, Server);
change_user_modes([_Mode | Rest], Action, Modes, Nick, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"501">>, [], <<"Unknown MODE flag">>),
    change_user_modes(Rest, Action, Modes, Nick, Client, Server).

%% Query or update channel flags, lists, keys, limits, and member roles.
channel_mode(Name, [Mode], #client{pid = Pid} = Client, Server) when
    Mode =:= <<"+b">>; Mode =:= <<"+e">>; Mode =:= <<"+I">>
->
    Type =
        case Mode of
            <<"+b">> -> ban;
            <<"+e">> -> exception;
            <<"+I">> -> invite
        end,
    list_mode(Type, Name, Pid, Client, Server);
channel_mode(Name, Rest, #client{pid = Pid} = Client, Server) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members} = Channel] ->
            IsCreator = Channel#channel.creator =:= Pid,
            IsOperator = lists:member(operator, maps:get(Pid, Members, [])),
            case {Rest, IsOperator orelse IsCreator} of
                {[], _} ->
                    report_modes(Channel, Client, Server);
                {[Modes | Args], true} ->
                    change_modes(binary_to_list(Modes), add, Args, Channel, Client, Server);
                {_, false} ->
                    ircd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    )
            end;
        [] ->
            ircd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>)
    end.

list_mode(Type, Name, Pid, Client, Server) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, lists = Lists}] ->
            case Type =:= invite orelse lists:member(operator, maps:get(Pid, Members, [])) of
                false ->
                    ircd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    );
                true ->
                    Mode =
                        case Type of
                            ban -> $b;
                            exception -> $e;
                            invite -> $I
                        end,
                    lists:foreach(
                        fun(Entry) ->
                            ircd_state_send:numeric(
                                Client, Server, <<"367">>, [Canonical, Entry], none
                            )
                        end,
                        maps:get(Type, Lists, [])
                    ),
                    ircd_state_send:numeric(
                        Client,
                        Server,
                        <<"368">>,
                        [Canonical, <<Mode>>],
                        <<"End of channel list">>
                    )
            end;
        [] ->
            ircd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>)
    end.

report_modes(
    #channel{
        name = Name,
        flags = Flags,
        limit = Limit,
        password = Password,
        members = Members
    },
    #client{pid = Pid} = Client,
    Server
) ->
    KeyFields =
        case Password of
            undefined ->
                {[], []};
            _ ->
                Display =
                    case maps:is_key(Pid, Members) of
                        true -> Password;
                        false -> <<"*">>
                    end,
                {"k", [Display]}
        end,
    LimitFields =
        case Limit of
            undefined -> {[], []};
            _ -> {"l", [integer_to_binary(Limit)]}
        end,
    {KeyMode, KeyArgs} = KeyFields,
    {LimitMode, LimitArgs} = LimitFields,
    Modes = list_to_binary([$+ | lists:sort(maps:keys(Flags)) ++ KeyMode ++ LimitMode]),
    ircd_state_send:numeric(Client, Server, <<"324">>, [Name, Modes | KeyArgs ++ LimitArgs], none).

change_modes([], _, _, _, _, _) ->
    ok;
change_modes([$+ | Rest], _, Args, Channel, Client, Server) ->
    change_modes(Rest, add, Args, Channel, Client, Server);
change_modes([$- | Rest], _, Args, Channel, Client, Server) ->
    change_modes(Rest, remove, Args, Channel, Client, Server);
change_modes([Mode | Rest], Action, Args, Channel, Client, Server) ->
    #channel{name = Name, members = Members} = Channel,
    Authorized = mode_authorized(Mode, Action, Channel, Client),
    case {Mode, Authorized, apply_mode(Mode, Action, Args, Channel)} of
        {$q, _, _} ->
            ircd_state_send:numeric(
                Client,
                Server,
                <<"481">>,
                [],
                <<"Permission Denied- Quiet mode is server only">>
            ),
            change_modes(Rest, Action, Args, Channel, Client, Server);
        {_, false, _} ->
            ircd_state_send:numeric(
                Client, Server, <<"482">>, [Name], <<"You're not channel creator">>
            ),
            change_modes(Rest, Action, Args, Channel, Client, Server);
        {_, true, {ok, New, Tail, Parameters}} ->
            case New =/= Channel of
                true ->
                    mnesia:dirty_write(New),
                    Sign =
                        case Action of
                            add -> $+;
                            remove -> $-
                        end,
                    ircd_state_send:broadcast(
                        maps:keys(Members),
                        channel_origin_prefix(Channel, Client),
                        <<"MODE">>,
                        [Name, <<Sign, Mode>> | Parameters],
                        none
                    ),
                    %% A channel key is not written to history.
                    case Mode of
                        $k ->
                            ok;
                        _ ->
                            ircd_state_history:note_event(
                                Channel#channel.key,
                                <<"MODE">>,
                                channel_origin_prefix(Channel, Client),
                                [<<Sign, Mode>> | Parameters],
                                none
                            )
                    end,
                    ircd_state_link:propagate_channel_mode(
                        Client, Name, <<Sign, Mode>>, Parameters
                    );
                false ->
                    ok
            end,
            change_modes(Rest, Action, Tail, New, Client, Server);
        {_, true, {error, Code, Params, Message, Tail}} ->
            ircd_state_send:numeric(Client, Server, Code, Params, Message),
            change_modes(Rest, Action, Tail, Channel, Client, Server)
    end.

mode_authorized($r, _Action, #channel{name = <<$!, _/binary>>} = Channel, Client) ->
    Channel#channel.creator =:= Client#client.pid;
mode_authorized($r, _Action, _, _) ->
    false;
mode_authorized($a, _Action, #channel{name = <<$!, _/binary>>} = Channel, Client) ->
    Channel#channel.creator =:= Client#client.pid;
mode_authorized($a, _Action, #channel{name = <<$&, _/binary>>}, _) ->
    true;
mode_authorized($a, _Action, _, _) ->
    false;
mode_authorized(_, _, _, _) ->
    true.

apply_mode(Mode, Action, Args, #channel{lists = Lists} = Channel) when
    Mode =:= $b; Mode =:= $e; Mode =:= $I
->
    Type =
        case Mode of
            $b -> ban;
            $e -> exception;
            $I -> invite
        end,
    Existing = maps:get(Type, Lists, []),
    case Args of
        [Mask | Tail] ->
            StoredMask = ircd_wire:retain(Mask),
            NewList =
                case Action of
                    add -> lists:usort([StoredMask | Existing]);
                    remove -> lists:delete(Mask, Existing)
                end,
            {ok, Channel#channel{lists = Lists#{Type => NewList}}, Tail, [Mask]};
        [] ->
            {ok, Channel, [], []}
    end;
apply_mode($a, Action, Args, #channel{name = <<$&, _/binary>>, flags = Flags} = Channel) ->
    New =
        case Action of
            add -> Flags#{$a => true};
            remove -> maps:remove($a, Flags)
        end,
    {ok, Channel#channel{flags = New}, Args, []};
apply_mode($a, add, Args, #channel{name = <<$!, _/binary>>, flags = Flags} = Channel) ->
    {ok, Channel#channel{flags = Flags#{$a => true}}, Args, []};
apply_mode($a, remove, Args, #channel{name = <<$!, _/binary>>} = Channel) ->
    {error, <<"482">>, [Channel#channel.name], <<"Cannot unset anonymous mode on a safe channel">>,
        Args};
apply_mode($a, _, Args, _) ->
    {error, <<"472">>, [<<"a">>], <<"Anonymous mode is only available on local and safe channels">>,
        Args};
apply_mode($r, Action, Args, #channel{name = <<$!, _/binary>>, flags = Flags} = Channel) ->
    New =
        case Action of
            add -> Flags#{$r => true};
            remove -> maps:remove($r, Flags)
        end,
    {ok, Channel#channel{flags = New, opless_since = undefined}, Args, []};
apply_mode($r, _, Args, _) ->
    {error, <<"472">>, [<<"r">>], <<"Reop mode is only available on safe channels">>, Args};
apply_mode(Mode, Action, Args, #channel{flags = Flags} = Channel) when
    Mode =:= $i; Mode =:= $m; Mode =:= $n; Mode =:= $q; Mode =:= $t; Mode =:= $K
->
    New =
        case Action of
            add -> Flags#{Mode => true};
            remove -> maps:remove(Mode, Flags)
        end,
    {ok, Channel#channel{flags = New}, Args, []};
apply_mode(Mode, add, Args, #channel{flags = Flags} = Channel) when
    Mode =:= $p; Mode =:= $s
->
    Other =
        case Mode of
            $p -> $s;
            $s -> $p
        end,
    New = (maps:remove(Other, Flags))#{Mode => true},
    {ok, Channel#channel{flags = New}, Args, []};
apply_mode(Mode, remove, Args, #channel{flags = Flags} = Channel) when
    Mode =:= $p; Mode =:= $s
->
    {ok, Channel#channel{flags = maps:remove(Mode, Flags)}, Args, []};
apply_mode($l, remove, Args, Channel) ->
    {ok, Channel#channel{limit = undefined}, Args, []};
apply_mode($l, add, [Value | Args], Channel) ->
    case string:to_integer(Value) of
        {Limit, <<>>} when Limit > 0, Limit =< 2147483647 ->
            {ok, Channel#channel{limit = Limit}, Args, [integer_to_binary(Limit)]};
        _ ->
            {error, <<"461">>, [<<"MODE">>], <<"Invalid channel limit">>, Args}
    end;
apply_mode($k, add, [Key | Args], Channel) when byte_size(Key) > 0, byte_size(Key) =< 64 ->
    case binary:match(Key, [<<" ">>, <<",">>, <<":">>]) of
        nomatch -> {ok, Channel#channel{password = ircd_wire:retain(Key)}, Args, [Key]};
        _ -> {error, <<"461">>, [<<"MODE">>], <<"Invalid channel key">>, Args}
    end;
apply_mode($k, add, [_ | Args], _) ->
    {error, <<"461">>, [<<"MODE">>], <<"Invalid channel key">>, Args};
apply_mode($k, remove, [_ | Args], Channel) ->
    {ok, Channel#channel{password = undefined}, Args, [<<"*">>]};
apply_mode(Mode, Action, [Nick | Args], #channel{name = Name, members = Members} = Channel) when
    Mode =:= $o; Mode =:= $v
->
    Role =
        case Mode of
            $o -> operator;
            $v -> voice
        end,
    case ircd_state_client:find_nick(Nick) of
        #client{pid = Pid, nick = Actual} when is_map_key(Pid, Members) ->
            Roles = maps:get(Pid, Members),
            New =
                case Action of
                    add -> lists:usort([Role | Roles]);
                    remove -> lists:delete(Role, Roles)
                end,
            {ok, Channel#channel{members = Members#{Pid := New}}, Args, [Actual]};
        _ ->
            {error, <<"441">>, [Nick, Name], <<"They aren't on that channel">>, Args}
    end;
apply_mode(Mode, _, [], _) when Mode =:= $k; Mode =:= $l; Mode =:= $o; Mode =:= $v ->
    {error, <<"461">>, [<<"MODE">>], <<"Not enough parameters">>, []};
apply_mode(Mode, _, Args, _) ->
    {error, <<"472">>, [<<Mode>>], <<"Unknown mode character">>, Args}.
split(Value) -> binary:split(Value, <<",">>, [global, trim_all]).

%% @doc `RENAME <old> <new> [:reason]` (draft/channel-rename). A channel
%% operator may rename a local channel. The type prefix cannot change, safe
%% `!` channels and channels shared with a server link cannot be renamed.
%% channel-rename clients see RENAME; other members see PART, then JOIN with
%% the topic and names burst. A case-only rename sends no fallback.
rename([Old, New | Rest], #client{pid = Pid} = Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> <<>>
        end,
    OldKey = ircd_wire:fold(Old),
    NewKey = ircd_wire:fold(New),
    case mnesia:dirty_read(channel, OldKey) of
        [] ->
            ircd_state_send:numeric(Client, Server, <<"403">>, [Old], <<"No such channel">>);
        [#channel{name = Canonical, members = Members} = Channel] ->
            Roles = maps:get(Pid, Members, undefined),
            CaseOnly = OldKey =:= NewKey,
            Shared =
                mnesia:dirty_read(remote_channel, OldKey) =/= [] orelse
                    mnesia:dirty_read(remote_channel, NewKey) =/= [],
            Taken =
                not CaseOnly andalso
                    (mnesia:dirty_read(channel, NewKey) =/= [] orelse
                        mnesia:dirty_read(remote_channel, NewKey) =/= []),
            if
                Roles =:= undefined ->
                    ircd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                not is_list(Roles) ->
                    ok;
                true ->
                    case lists:member(operator, Roles) of
                        false ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"482">>,
                                [Canonical],
                                <<"You're not channel operator">>
                            );
                        true ->
                            Valid =
                                ircd_wire:channel(New) andalso
                                    binary:first(New) =:= binary:first(Canonical) andalso
                                    binary:first(New) =/= $! andalso not Shared,
                            case {Valid, Taken} of
                                {false, _} ->
                                    ircd_state_send:fail(
                                        Pid,
                                        <<"RENAME">>,
                                        <<"CANNOT_RENAME">>,
                                        [Canonical, New],
                                        <<"The channel cannot be renamed">>
                                    );
                                {true, true} ->
                                    ircd_state_send:fail(
                                        Pid,
                                        <<"RENAME">>,
                                        <<"CHANNEL_NAME_IN_USE">>,
                                        [Canonical, New],
                                        <<"The channel name is already taken">>
                                    );
                                {true, false} ->
                                    apply_rename(Channel, New, Reason, Client, Server, CaseOnly)
                            end
                    end
            end
    end;
rename(_, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"RENAME">>], <<"Not enough parameters">>).

apply_rename(
    #channel{key = OldKey, name = OldName, members = Members} = Channel,
    New,
    Reason,
    Client,
    Server,
    CaseOnly
) ->
    NewKey = ircd_wire:fold(New),
    Name = ircd_wire:retain(New),
    Renamed = Channel#channel{key = NewKey, name = Name},
    case CaseOnly of
        true ->
            mnesia:dirty_write(Renamed);
        false ->
            mnesia:dirty_delete(channel, OldKey),
            mnesia:dirty_write(Renamed),
            lists:foreach(
                fun(Pid) ->
                    case mnesia:dirty_read(client, Pid) of
                        [#client{channels = Keys} = Member] ->
                            mnesia:dirty_write(Member#client{
                                channels = [
                                    case K of
                                        OldKey -> NewKey;
                                        _ -> K
                                    end
                                 || K <- Keys
                                ]
                            });
                        [] ->
                            ok
                    end
                end,
                maps:keys(Members)
            ),
            case mnesia:dirty_read(channel_history, OldKey) of
                [History] ->
                    mnesia:dirty_delete(channel_history, OldKey),
                    mnesia:dirty_write(History#channel_history{channel = NewKey});
                [] ->
                    ok
            end,
            ircd_state_meta:rename_channel(OldKey, NewKey),
            ircd_state_history:rename_markers(OldKey, NewKey)
    end,
    logger:info(#{event => channel_renamed, actor => Client#client.nick}),
    Origin = channel_origin_prefix(Channel, Client),
    {Capable, Legacy} = lists:partition(
        fun(P) -> ircd_cap:enabled(P, <<"draft/channel-rename">>) end, maps:keys(Members)
    ),
    ircd_state_send:broadcast(Capable, Origin, <<"RENAME">>, [OldName, Name], Reason),
    case CaseOnly of
        true ->
            ok;
        false ->
            PartReason =
                case Reason of
                    <<>> -> none;
                    _ -> Reason
                end,
            lists:foreach(
                fun(Pid) ->
                    case mnesia:dirty_read(client, Pid) of
                        [Member] ->
                            Self = ircd_state_send:prefix(Member),
                            ircd_state_send:send(Pid, Self, <<"PART">>, [OldName], PartReason),
                            ircd_state_v3:join_broadcast(
                                [Pid],
                                Self,
                                Name,
                                ircd_state_v3:account(Pid),
                                Member#client.real
                            ),
                            topic_reply(Renamed, Member, Server),
                            ircd_state_history:markread_on_join(Pid, Name, Server),
                            case ircd_cap:enabled(Pid, <<"no-implicit-names">>) of
                                true -> ok;
                                false -> names(Name, Member, Server)
                            end;
                        [] ->
                            ok
                    end
                end,
                Legacy
            )
    end,
    ok.
