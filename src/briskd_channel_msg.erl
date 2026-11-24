-module(briskd_channel_msg).
-moduledoc """
`PRIVMSG`, `NOTICE`, and `TAGMSG` routing to channels and direct targets,
including `TARGMAX`, `echo-message`, `draft/multiline` fan-out, and peer history
recording (RFC 2812 section 3.3).

Runs inside the `m:briskd_state` process.
""".
-export([
    deliver/5,
    deliver_body/6,
    note_channel_history/4,
    note_channel_history/5,
    split/1
]).
-include("briskd_state.hrl").

-doc """
A message body: `none` for `TAGMSG`, the text of a `PRIVMSG` or `NOTICE`, or a
draft/multiline batch as `{Concat, Line}` pairs in order.
""".
-type body() :: none | binary() | {multiline, [{boolean(), binary()}]}.
-export_type([body/0]).

-define(MAX_TARGETS, 4).

-doc """
Split a comma-separated parameter, dropping empty items.
""".
-spec split(binary()) -> [binary()].
split(Value) -> binary:split(Value, <<",">>, [global, trim_all]).

-doc """
Route `PRIVMSG`, `NOTICE`, or `TAGMSG` to nicknames and channels (RFC 2812 section 3.3).
""".
-spec deliver(binary(), [binary()], #client{}, binary(), [{binary(), undefined | binary()}]) -> ok.
deliver(Command, Params, #client{pid = Pid} = Client, Server, Tags) ->
    ClientTags =
        case briskd_cap:enabled(Pid, <<"message-tags">>) of
            true -> briskd_cap:client_tags(Tags);
            false -> briskd_e2ee:envelope_tags(Tags)
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
    All = lists:uniq(split(Targets)),
    {Allowed, Extra} = lists:split(min(length(All), ?MAX_TARGETS), All),
    lists:foreach(
        fun(Target) -> deliver_body(Command, Target, Text, Client, Server, Tags) end,
        Allowed
    ),
    lists:foreach(
        fun(Target) ->
            message_error(
                Command, Client, Server, <<"407">>, [Target], <<"Too many recipients">>
            )
        end,
        Extra
    ).

-doc """
Deliver one message body to one target (channel, local user, E2EE queue, or
remote user).
""".
-spec deliver_body(binary(), binary(), body(), #client{}, binary(), [
    {binary(), undefined | binary()}
]) -> ok.
deliver_body(Command, Target, Body, #client{pid = Pid} = Client, Server, ClientTags) ->
    MsgId = briskd_state_send:msgid(),
    Now = erlang:system_time(millisecond),
    Tags = [{<<"msgid">>, MsgId}, {<<"time">>, briskd_state_send:time_value(Now)} | ClientTags],
    Account = briskd_state_v3:account(Pid),
    case mnesia:dirty_read(channel, briskd_wire:fold(Target)) of
        [#channel{name = Name, members = Members, flags = Flags} = Channel] ->
            Roles = maps:get(Pid, Members, []),
            Outside =
                (maps:is_key($n, Flags) orelse maps:is_key($a, Flags)) andalso
                    not maps:is_key(Pid, Members),
            Moderated =
                maps:is_key($m, Flags) andalso
                    not (lists:member(operator, Roles) orelse lists:member(voice, Roles)),
            Banned =
                briskd_channel_mode:mask_matches(Channel, ban, Client) andalso
                    not briskd_channel_mode:mask_matches(Channel, exception, Client),
            BannedWithoutPrivilege =
                Banned andalso
                    not (lists:member(operator, Roles) orelse lists:member(voice, Roles)),
            case Outside orelse Moderated orelse BannedWithoutPrivilege of
                true ->
                    message_error(
                        Command, Client, Server, <<"404">>, [Name], <<"Cannot send to channel">>
                    );
                false ->
                    Origin = briskd_channel_mode:channel_origin_prefix(Channel, Client),
                    Recipients = maps:keys(maps:remove(Pid, Members)),
                    fan_out(Recipients, Origin, Command, Name, Body, Tags),
                    echo(Pid, Origin, Command, Name, Body, Tags),
                    Stored =
                        case maps:is_key($a, Flags) of
                            true -> undefined;
                            false -> Account
                        end,
                    briskd_state_history:note_channel(
                        briskd_wire:fold(Name),
                        briskd_state_history:entry(
                            Command, Origin, Body, MsgId, Now, ClientTags, Stored
                        )
                    ),
                    briskd_state_link:propagate_channel_lines(
                        Name,
                        briskd_state_batch:link_lines(
                            briskd_state_send:prefix(Client), Command, Name, Body, Tags
                        )
                    )
            end;
        [] ->
            case briskd_e2ee:route(Target, Body, Client, {ClientTags, Tags, Command}) of
                handled ->
                    ok;
                pass ->
                    deliver_direct(
                        Command,
                        Target,
                        Body,
                        Client,
                        Server,
                        {ClientTags, Tags, MsgId, Now, Account}
                    )
            end
    end.

deliver_direct(
    Command,
    Target,
    Body,
    #client{pid = Pid} = Client,
    Server,
    {ClientTags, Tags, MsgId, Now, Account}
) ->
    Recipient =
        case briskd_state_client:find_nick(Target) of
            #client{} = Found ->
                case briskd_state_client:ready(Found) of
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
            Prefix = briskd_state_send:prefix(Client),
            fan_out([Other], Prefix, Command, Nick, Body, Tags),
            echo(Pid, Prefix, Command, Nick, Body, Tags),
            briskd_state_history:note_direct(
                {Account, Client#client.nick},
                {briskd_state_v3:account(Other), Nick},
                Nick,
                briskd_state_history:entry(
                    Command, Prefix, Body, MsgId, Now, ClientTags, Account
                )
            ),
            case {Command, Away} of
                {<<"PRIVMSG">>, Message} when Message =/= undefined ->
                    briskd_state_send:numeric(Client, Server, <<"301">>, [Nick], Message);
                _ ->
                    ok
            end;
        undefined ->
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Target)) of
                [#remote_client{peer = Peer, nick = Nick, account = Theirs}] ->
                    Prefix = briskd_state_send:prefix(Client),
                    Results = [
                        briskd_links:send(Peer, iolist_to_binary(Line))
                     || Line <- briskd_state_batch:link_lines(
                            Prefix, Command, Nick, Body, Tags
                        )
                    ],
                    case lists:all(fun(R) -> R =:= ok end, Results) of
                        true ->
                            echo(Pid, Prefix, Command, Nick, Body, Tags),
                            briskd_state_history:note_direct(
                                {Account, Client#client.nick},
                                {Theirs, Nick},
                                Nick,
                                briskd_state_history:entry(
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
    end.

fan_out(Pids, Prefix, Command, Target, {multiline, Lines}, Tags) ->
    lists:foreach(
        fun(P) ->
            briskd_state_batch:deliver_multiline(P, Prefix, Command, Target, Lines, Tags, normal)
        end,
        Pids
    );
fan_out(Pids, Prefix, Command, Target, Text, Tags) ->
    briskd_state_send:broadcast(Pids, Prefix, Command, [Target], Text, Tags).

echo(Pid, Prefix, Command, Target, Body, Tags) ->
    case briskd_cap:enabled(Pid, <<"echo-message">>) of
        false ->
            ok;
        true ->
            case Body of
                {multiline, Lines} ->
                    briskd_state_batch:deliver_multiline(
                        Pid, Prefix, Command, Target, Lines, Tags, echo
                    );
                _ ->
                    briskd_state_send:echo(Pid, Prefix, Command, [Target], Body, Tags)
            end
    end.

message_error(<<"NOTICE">>, _, _, _, _, _) ->
    ok;
message_error(_, Client, Server, Number, Middle, Text) ->
    briskd_state_send:numeric(Client, Server, Number, Middle, Text).

-doc """
Record a channel `PRIVMSG` or `NOTICE` accepted from a server peer; see
`note_channel_history/5`.
""".
-spec note_channel_history(binary(), binary(), binary(), none | iodata()) -> ok.
note_channel_history(Key, Command, Prefix, Text) ->
    note_channel_history(Key, Command, Prefix, Text, []).

-doc """
Record a channel `PRIVMSG` or `NOTICE` accepted from a server peer.
""".
-spec note_channel_history(binary(), binary(), binary(), none | iodata(), [
    {binary(), undefined | binary()}
]) -> ok.
note_channel_history(Key, Command, Prefix, Text, Tags) when is_binary(Text) ->
    MsgId =
        case lists:keyfind(<<"msgid">>, 1, Tags) of
            {_, Id} when is_binary(Id) -> Id;
            _ -> undefined
        end,
    Time =
        case lists:keyfind(<<"time">>, 1, Tags) of
            {_, Stamp} when is_binary(Stamp) ->
                case briskd_state_history:parse_timestamp(Stamp) of
                    {ok, T} -> T;
                    error -> erlang:system_time(millisecond)
                end;
            _ ->
                erlang:system_time(millisecond)
        end,
    Account = maps:get(
        account, briskd_state_v3:remote_source_info(iolist_to_binary(Prefix)), undefined
    ),
    briskd_state_history:note_channel(
        Key,
        briskd_state_history:entry(
            Command, Prefix, Text, MsgId, Time, briskd_cap:client_tags(Tags), Account
        )
    );
note_channel_history(_Key, _Command, _Prefix, _Text, _Tags) ->
    ok.
