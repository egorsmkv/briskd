-module(briskd_state_dispatch).
-moduledoc """
Client command admission, flood protection, IRCv3 `labeled-response` wrapping,
deferred PBKDF2 hand-off, UTF-8 validation, and command routing for
`m:briskd_state`.

All functions execute inside the single-writer `m:briskd_state` process.
""".
-export([
    change_nick/3,
    dispatch/5,
    handle_command/6,
    handle_command_as/7,
    handle_input_too_long/3
]).
-include("briskd_state.hrl").

-doc """
Handle an over-long tagged client line (`417 ERR_INPUTTOOLONG`) while charging
one flood token.
""".
-spec handle_input_too_long([{binary(), undefined | binary()}], pid(), binary()) ->
    {reply, ok | quit, binary()}.
handle_input_too_long(Tags, Pid, Server) ->
    Client = briskd_state_client:client(Pid),
    %% One line token, and no message or join token: the line was not a command.
    case briskd_flood:check_command(Pid, <<"PING">>, [], [], briskd_state_client:ready(Client)) of
        {flood, Category} ->
            flood_quit(Client, Category, Server);
        allow ->
            Label = briskd_cap:label(briskd_cap:state(Pid), Tags),
            ok = briskd_state_send:begin_label(Pid, Label),
            try
                briskd_state_send:numeric(
                    Client, Server, <<"417">>, [], <<"Input line was too long">>
                )
            after
                briskd_state_send:end_label(Server)
            end,
            {reply, ok, Server}
    end.

-doc """
Handle a command sent through a secondary multiclient connection attached to
`Primary`.
""".
-spec handle_command_as(
    pid(),
    binary(),
    [binary()],
    non_neg_integer(),
    list(),
    {pid(), term()},
    binary()
) -> {reply, ok | quit | starttls, binary()} | {noreply, binary()}.
handle_command_as(Primary, Command, Params, Bytes, Tags, {Caller, Ref}, Server) ->
    case ets:lookup(briskd_attached, Caller) of
        [{Caller, Primary}] ->
            case mnesia:dirty_read(client, Primary) of
                [_] -> handle_command(Command, Params, Bytes, Tags, {Primary, Ref}, Server);
                [] -> {reply, quit, Server}
            end;
        _ ->
            {reply, quit, Server}
    end.

-doc """
Handle a client command from session `From` (`{Pid, Ref}`).
""".
-spec handle_command(
    binary(), [binary()], non_neg_integer(), list(), {pid(), term()}, binary()
) -> {reply, ok | quit | starttls, binary()} | {noreply, binary()}.
handle_command(Command, Params, Bytes, Tags, {Pid, Ref}, Server) ->
    case mnesia:dirty_read(client, Pid) of
        [_] ->
            client_command(Command, Params, Bytes, Tags, {Pid, Ref}, Server);
        [] ->
            %% multiclient: finish_attach/2 dropped this connection's client
            %% row, but lines the session read before it saw {attach, Holder}
            %% still arrive as plain commands. Run them as the holder; a
            %% connection with no client row and no holder is closed.
            case ets:lookup(briskd_attached, Pid) of
                [{Pid, Holder}] ->
                    handle_command_as(Holder, Command, Params, Bytes, Tags, {Pid, Ref}, Server);
                [] ->
                    {reply, quit, Server}
            end
    end.

client_command(Command, Params, Bytes, Tags, {Pid, _} = From, Server) ->
    briskd_metrics:count_command(Pid, Command, Bytes),
    Client = briskd_state_client:client(Pid),
    briskd_log:client_command(Client#client.nick, Command, Params),
    case
        briskd_flood:check_command(
            Pid, Command, Params, Tags, briskd_state_client:ready(Client)
        )
    of
        {flood, Category} ->
            flood_quit(Client, Category, Server);
        allow ->
            run_client_command(Command, Params, Tags, Client, From, Server)
    end.

flood_quit(#client{pid = Pid} = Client, Category, Server) ->
    logger:warning(#{
        event => flood_exceeded,
        nick => Client#client.nick,
        host => Client#client.host,
        category => Category
    }),
    briskd_state_send:send(
        Pid,
        Server,
        <<"ERROR">>,
        [],
        [<<"Closing Link: ">>, Client#client.host, <<" (Excess Flood)">>]
    ),
    briskd_state_client:disconnect(Client, <<"Excess Flood">>, Server),
    {reply, quit, Server}.

run_client_command(Command, Params, Tags, #client{pid = Pid} = Client, From, Server) ->
    Label =
        case welcomed_cap_end(Client, Command, Params) of
            true -> undefined;
            false -> command_label(Pid, Command, Params, Tags)
        end,
    ok = briskd_state_send:begin_label(Pid, Label),
    briskd_state_send:set_source(briskd_state_v3:source_info(Client)),
    Reply =
        try
            dispatch(Command, Params, Client, Server, Tags)
        catch
            Class:Reason:Stack ->
                _ = briskd_deferred:take(),
                end_reply(Server),
                erlang:raise(Class, Reason, Stack)
        end,
    case briskd_deferred:take() of
        none ->
            end_reply(Server),
            case Reply of
                quit -> ok;
                %% PONG is not a liveness answer here, so it must not refresh
                %% the idle timer on its own.
                _ when Command =:= <<"PONG">> -> ok;
                _ -> briskd_state_client:touch_activity(Pid)
            end,
            {reply, Reply, Server};
        {Work, Then} ->
            %% Costly work (PBKDF2) runs in a worker; the reply follows when
            %% it finishes (briskd_deferred:resume/3 from handle_info 'DOWN').
            briskd_deferred:start(From, Pid, Work, Then, Server)
    end.

end_reply(Server) ->
    briskd_state_send:end_label(Server),
    briskd_state_send:clear_source().

%% Lines inside a client batch, and the opening BATCH, are answered when the
%% batch closes. The closing BATCH uses the label from the opening line.
command_label(_Pid, <<"BATCH">>, [<<"+", _/binary>> | _], _Tags) ->
    undefined;
command_label(Pid, <<"BATCH">>, [<<"-", _/binary>> | _], _Tags) ->
    case briskd_state_batch:label(Pid) of
        undefined -> undefined;
        Stored -> briskd_cap:label(briskd_cap:state(Pid), [{<<"label">>, Stored}])
    end;
command_label(Pid, Command, _Params, Tags) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>
->
    case lists:keymember(<<"batch">>, 1, Tags) of
        true -> undefined;
        false -> briskd_cap:label(briskd_cap:state(Pid), Tags)
    end;
command_label(Pid, _Command, _Params, Tags) ->
    briskd_cap:label(briskd_cap:state(Pid), Tags).

welcomed_cap_end(Client, <<"CAP">>, [<<"END">> | _]) ->
    briskd_cap:welcomed(Client#client.pid);
welcomed_cap_end(_, _, _) ->
    false.

-doc """
Validate `utf8_only` (when enabled) and dispatch one client command.
""".
-spec dispatch(binary(), [binary()], #client{}, binary(), [{binary(), undefined | binary()}]) ->
    ok | quit | starttls.
dispatch(Command, Params, Client, Server, Tags) ->
    case utf8_rejected(Command, Params) of
        true ->
            briskd_state_send:fail(
                Client#client.pid,
                Command,
                <<"INVALID_UTF8">>,
                [],
                <<"Message rejected, your IRC software MUST use UTF-8 encoding on this network">>
            );
        false ->
            dispatch_command(Command, Params, Client, Server, Tags)
    end.

utf8_rejected(Command, _Params) when
    Command =:= <<"PASS">>;
    Command =:= <<"OPER">>;
    Command =:= <<"AUTHENTICATE">>;
    Command =:= <<"REGISTER">>;
    Command =:= <<"WEBIRC">>
->
    false;
utf8_rejected(_Command, Params) ->
    maps:get(utf8_only, briskd_config:current(), false) andalso
        not lists:all(fun briskd_state_v3:valid_utf8/1, Params).

%% Route commands accepted before registration and enforce registration for the rest.
dispatch_command(<<"QUIT">>, Params, Client, Server, _Tags) ->
    Reason =
        case Params of
            [Text | _] -> Text;
            [] -> <<"Client quit">>
        end,
    %% RFC 2812 3.1.7: the server acknowledges QUIT with ERROR. The session
    %% flushes it before closing the socket.
    briskd_state_send:send(
        Client#client.pid,
        Server,
        <<"ERROR">>,
        [],
        [<<"Closing Link: ">>, Client#client.host, <<" (Quit: ">>, Reason, <<")">>]
    ),
    briskd_state_client:disconnect(Client, Reason, Server),
    quit;
dispatch_command(<<"PASS">>, Params, Client, Server, _Tags) ->
    briskd_state_client:pass(Params, Client, Server);
dispatch_command(<<"RECLAIM">>, Params, Client, Server, _Tags) ->
    briskd_state_net:reclaim(Params, Client, Server);
dispatch_command(<<"PING">>, [Token | _], Client, Server, _Tags) ->
    briskd_state_send:send(Client#client.pid, Server, <<"PONG">>, [Server], Token);
dispatch_command(<<"PING">>, [], Client, Server, _Tags) ->
    briskd_state_send:numeric(Client, Server, <<"409">>, [], <<"No origin specified">>);
dispatch_command(<<"PONG">>, _, _, _, _Tags) ->
    ok;
dispatch_command(<<"CAP">>, Params, Client, Server, _Tags) ->
    briskd_state_net:cap(Client, Server, Params);
dispatch_command(<<"STARTTLS">>, _Params, Client, Server, _Tags) ->
    briskd_state_v3:starttls(Client, Server);
dispatch_command(<<"AUTHENTICATE">>, Params, Client, Server, _Tags) ->
    briskd_state_v3:authenticate(Params, Client, Server);
dispatch_command(<<"REGISTER">>, Params, Client, Server, _Tags) ->
    briskd_state_v3:register(Params, Client, Server);
dispatch_command(<<"VERIFY">>, Params, Client, Server, _Tags) ->
    briskd_state_v3:verify(Params, Client, Server);
dispatch_command(<<"WEBIRC">>, Params, Client, Server, _Tags) ->
    briskd_state_v3:webirc(Params, Client, Server);
dispatch_command(<<"ISUPPORT">>, Params, Client, Server, _Tags) ->
    briskd_state_v3:isupport(Params, Client, Server);
dispatch_command(<<"AWAY">>, Params, Client, Server, Tags) ->
    case briskd_state_client:ready(Client) of
        true -> registered_command(<<"AWAY">>, Params, Client, Server, Tags);
        false -> briskd_state_v3:pre_away(Params, Client, Server)
    end;
dispatch_command(<<"METADATA">>, [<<"*">> | _] = Params, Client, Server, _Tags) ->
    briskd_state_meta:metadata(Params, Client, Server);
dispatch_command(<<"NICK">>, [Nick | _], Client, Server, _Tags) ->
    case briskd_state_net:nick_blocked(Nick, Client) of
        true ->
            briskd_state_send:numeric(
                Client, Server, <<"437">>, [Nick], <<"Nick/channel is temporarily unavailable">>
            );
        false ->
            change_nick(Nick, Client, Server)
    end;
dispatch_command(<<"NICK">>, [], Client, Server, _Tags) ->
    briskd_state_send:numeric(Client, Server, <<"431">>, [], <<"No nickname given">>);
dispatch_command(<<"USER">>, [_, _, _, <<>>], #client{user = undefined} = Client, Server, _Tags) ->
    briskd_state_send:numeric(Client, Server, <<"461">>, [<<"USER">>], <<"Not enough parameters">>);
dispatch_command(
    <<"USER">>, [User, Mode, _, Real], #client{user = undefined} = Client, Server, _Tags
) ->
    case
        {
            re:run(User, <<"^[A-Za-z0-9_.-]{1,32}$">>, [{capture, none}, dollar_endonly]),
            briskd_state_client:initial_user_modes(Mode)
        }
    of
        {match, {ok, Modes}} ->
            mnesia:dirty_write(#user_modes{pid = Client#client.pid, modes = Modes}),
            briskd_state_client:save_identity(
                Client, Client#client{user = User, real = Real}, Server
            );
        {nomatch, _} ->
            %% ERR_INVALIDUSERNAME (468)
            briskd_state_send:numeric(
                Client, Server, <<"468">>, [], <<"Your username is not valid">>
            );
        {_, error} ->
            briskd_state_send:numeric(
                Client, Server, <<"461">>, [<<"USER">>], <<"Invalid user mode mask">>
            )
    end;
dispatch_command(<<"USER">>, _, Client, Server, _Tags) ->
    case Client#client.user of
        undefined ->
            briskd_state_send:numeric(
                Client, Server, <<"461">>, [<<"USER">>], <<"Not enough parameters">>
            );
        _ ->
            briskd_state_send:numeric(Client, Server, <<"462">>, [], <<"You may not reregister">>)
    end;
dispatch_command(Command, Params, Client, Server, Tags) ->
    case briskd_state_client:ready(Client) of
        true ->
            registered_command(Command, Params, Client, Server, Tags);
        false ->
            briskd_state_send:numeric(Client, Server, <<"451">>, [], <<"You have not registered">>)
    end.

%% Implement commands that require a fully registered client.
registered_command(Command, Params, Client, Server, Tags) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>; Command =:= <<"TAGMSG">>
->
    case briskd_state_batch:in_batch({Command, Params, Tags}, Client) of
        true -> ok;
        false -> briskd_state_channel:deliver(Command, Params, Client, Server, Tags)
    end;
registered_command(<<"BATCH">>, Params, Client, Server, Tags) ->
    briskd_state_batch:batch(Params, Tags, Client, Server);
registered_command(Command, Params, Client, Server, _Tags) ->
    registered_command(Command, Params, Client, Server).

registered_command(<<"AWAY">>, [<<>> | _], #client{} = Client, Server) ->
    registered_command(<<"AWAY">>, [], Client, Server);
registered_command(<<"AWAY">>, [], #client{} = Client, Server) ->
    case Client#client.away of
        undefined ->
            briskd_state_send:numeric(
                Client, Server, <<"305">>, [], <<"You are no longer marked as being away">>
            );
        _ ->
            mnesia:dirty_write(Client#client{away = undefined}),
            briskd_state_link:propagate_away(Client, none),
            briskd_state_v3:notify(Client, <<"away-notify">>, <<"AWAY">>, [], none, false),
            briskd_state_send:numeric(
                Client, Server, <<"305">>, [], <<"You are no longer marked as being away">>
            )
    end,
    ok;
registered_command(<<"AWAY">>, [Raw | _], #client{} = Client, Server) ->
    Message =
        case Raw of
            <<"*">> -> <<"Away">>;
            _ -> Raw
        end,
    mnesia:dirty_write(Client#client{away = briskd_wire:retain(Message)}),
    briskd_state_link:propagate_away(Client, Message),
    briskd_state_v3:notify(Client, <<"away-notify">>, <<"AWAY">>, [], Message, false),
    briskd_state_send:numeric(
        Client, Server, <<"306">>, [], <<"You have been marked as being away">>
    ),
    ok;
registered_command(<<"JOIN">>, [<<"0">> | _], Client, _) ->
    lists:foreach(
        fun(Key) -> briskd_state_channel:leave(Key, Client, <<"PART">>, none, true) end,
        Client#client.channels
    );
registered_command(<<"JOIN">>, [Names | Rest], Client, Server) ->
    Keys =
        case Rest of
            [Passwords | _] -> binary:split(Passwords, <<",">>, [global]);
            [] -> []
        end,
    briskd_state_channel:join_channels(
        briskd_state_channel:split(Names), Keys, Client#client.pid, Server
    );
registered_command(<<"PART">>, [Names | Rest], Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    lists:foreach(
        fun(Name) ->
            Key = briskd_wire:fold(Name),
            Current = briskd_state_client:client(Client#client.pid),
            case {mnesia:dirty_read(channel, Key), lists:member(Key, Current#client.channels)} of
                {[], _} ->
                    briskd_state_send:numeric(
                        Current, Server, <<"403">>, [Name], <<"No such channel">>
                    );
                {_, false} ->
                    briskd_state_send:numeric(
                        Current, Server, <<"442">>, [Name], <<"You're not on that channel">>
                    );
                {_, true} ->
                    briskd_state_channel:leave(Key, Current, <<"PART">>, Reason, true)
            end
        end,
        briskd_state_channel:split(Names)
    );
registered_command(<<"KICK">>, [Name, Nicks | Rest], Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> Client#client.nick
        end,
    Channels = briskd_state_channel:split(Name),
    Targets = briskd_state_channel:split(Nicks),
    case {Channels, Targets} of
        {[Channel], [_ | _]} ->
            briskd_state_channel:kick(Channel, Targets, Reason, Client, Server);
        {ChannelList, TargetList} when
            length(ChannelList) =:= length(TargetList),
            length(ChannelList) > 1
        ->
            lists:foreach(
                fun({Channel, Target}) ->
                    briskd_state_channel:kick(Channel, [Target], Reason, Client, Server)
                end,
                lists:zip(ChannelList, TargetList)
            );
        _ ->
            briskd_state_send:numeric(
                Client, Server, <<"461">>, [<<"KICK">>], <<"Invalid channel/user list">>
            )
    end;
registered_command(<<"KICK">>, _, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"461">>, [<<"KICK">>], <<"Not enough parameters">>);
registered_command(<<"SETNAME">>, Params, Client, Server) ->
    briskd_state_v3:setname(Params, Client, Server);
registered_command(<<"CHGHOST">>, Params, Client, Server) ->
    briskd_state_v3:chghost(Params, Client, Server);
registered_command(<<"MONITOR">>, Params, Client, Server) ->
    briskd_state_monitor:monitor(Params, Client, Server);
registered_command(<<"CHATHISTORY">>, Params, Client, Server) ->
    briskd_state_history:chathistory(Params, Client, Server);
registered_command(<<"SEARCH">>, Params, Client, Server) ->
    briskd_state_search:search(Params, Client, Server);
registered_command(<<"MARKREAD">>, Params, Client, Server) ->
    briskd_state_history:markread(Params, Client, Server);
registered_command(<<"REDACT">>, Params, Client, Server) ->
    briskd_state_history:redact(Params, Client, Server);
registered_command(<<"CALL">>, Params, Client, Server) ->
    case briskd_calls:enabled() of
        true ->
            briskd_calls:command(Params, Client, Server);
        false ->
            briskd_state_send:numeric(
                Client, Server, <<"421">>, [<<"CALL">>], <<"Unknown command">>
            )
    end;
registered_command(<<"E2EE">>, Params, Client, Server) ->
    case briskd_e2ee:enabled() of
        true ->
            briskd_e2ee:command(Params, Client, Server);
        false ->
            briskd_state_send:numeric(
                Client, Server, <<"421">>, [<<"E2EE">>], <<"Unknown command">>
            )
    end;
registered_command(<<"METADATA">>, Params, Client, Server) ->
    briskd_state_meta:metadata(Params, Client, Server);
registered_command(<<"RENAME">>, Params, Client, Server) ->
    briskd_state_channel:rename(Params, Client, Server);
registered_command(<<"KNOCK">>, [Name | Rest], Client, Server) ->
    briskd_state_channel:knock(Name, Rest, Client, Server);
registered_command(<<"KNOCK">>, [], Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"KNOCK">>], <<"Not enough parameters">>
    );
registered_command(<<"INVITE">>, [<<C, _/binary>> = Name, Nick | _], Client, Server) when
    C =:= $#
->
    %% `INVITE <channel> <nick>` (parameters reversed; a `#` never starts a
    %% nickname, so this is unambiguous). An existing channel is handled as
    %% the RFC order; for a channel that does not exist, which RFC 1459/2812
    %% allow, both users see the INVITE in the order the client used.
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [_] ->
            briskd_state_channel:invite(Nick, Name, Client, Server);
        [] ->
            case briskd_state_client:find_nick(Nick) of
                #client{pid = Target} = Found ->
                    case briskd_state_client:ready(Found) of
                        true ->
                            Prefix = briskd_state_send:prefix(Client),
                            briskd_state_send:send(
                                Client#client.pid, Prefix, <<"INVITE">>, [Name, Nick], none
                            ),
                            briskd_state_send:send(
                                Target, Prefix, <<"INVITE">>, [Name, Nick], none
                            );
                        false ->
                            briskd_state_send:numeric(
                                Client, Server, <<"401">>, [Nick], <<"No such nick">>
                            )
                    end;
                undefined ->
                    briskd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>)
            end
    end;
registered_command(<<"INVITE">>, [Nick, Name | _], Client, Server) ->
    briskd_state_channel:invite(Nick, Name, Client, Server);
registered_command(<<"INVITE">>, _, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"INVITE">>], <<"Not enough parameters">>
    );
registered_command(<<"MODE">>, [Target | Rest], Client, Server) ->
    briskd_state_channel:mode_command(Target, Rest, Client, Server);
registered_command(<<"OPER">>, [Name, Password | _], Client, Server) ->
    briskd_oper:oper(Name, Password, Client, Server);
registered_command(<<"OPER">>, _, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"461">>, [<<"OPER">>], <<"Not enough parameters">>);
registered_command(<<"KILL">>, Params, Client, Server) ->
    briskd_oper:kill(Params, Client, Server);
registered_command(<<"CONNECT">>, Params, Client, Server) ->
    briskd_state_net:oper_command(<<"CONNECT">>, Params, Client, Server);
registered_command(<<"SQUIT">>, Params, Client, Server) ->
    briskd_state_net:oper_command(<<"SQUIT">>, Params, Client, Server);
registered_command(<<"DIE">>, Params, Client, Server) ->
    briskd_state_net:oper_command(<<"DIE">>, Params, Client, Server);
registered_command(<<"RESTART">>, Params, Client, Server) ->
    briskd_state_net:oper_command(<<"RESTART">>, Params, Client, Server);
registered_command(<<"SERVICE">>, Params, Client, Server) ->
    briskd_state_net:oper_command(<<"SERVICE">>, Params, Client, Server);
registered_command(<<"WALLOPS">>, Params, Client, Server) ->
    %% RFC 2812 3.7.1: an operator's WALLOPS goes to users with mode +w.
    briskd_oper:wallops(Params, Client, Server);
registered_command(<<"REHASH">>, _, Client, Server) ->
    briskd_rehash:rehash(Client, Server);
registered_command(<<"SUMMON">>, _, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"445">>, [], <<"SUMMON has been disabled">>);
registered_command(<<"USERS">>, Params, Client, Server) ->
    briskd_info:users_disabled(Params, Client, Server);
registered_command(<<"TOPIC">>, [Name | Rest], Client, Server) ->
    briskd_state_channel:topic(Name, Rest, Client, Server);
registered_command(<<"NAMES">>, Params, Client, Server) ->
    case Params of
        [Names | _] ->
            lists:foreach(
                fun(Name) -> briskd_state_channel:names(Name, Client, Server) end,
                briskd_state_channel:split(Names)
            );
        [] ->
            %% Channels oldest first (then by name), so the listing is stable.
            Ordered = lists:sort([
                {Created, Key}
             || Key <- briskd_state_schema:table_keys(channel),
                [#channel{created = Created}] <- [mnesia:dirty_read(channel, Key)]
            ]),
            lists:foreach(
                fun({_, Key}) -> briskd_state_channel:names_listing(Key, Client, Server) end,
                Ordered
            ),
            %% Remote-only channels; keys are unique, so `--` keeps each once.
            lists:foreach(
                fun(Key) -> briskd_state_link:remote_names_listing(Key, Client, Server) end,
                briskd_state_schema:table_keys(remote_channel) --
                    briskd_state_schema:table_keys(channel)
            ),
            briskd_state_channel:names_unattached(Client, Server),
            briskd_state_send:numeric(Client, Server, <<"366">>, [<<"*">>], <<"End of NAMES list">>)
    end;
registered_command(<<"LIST">>, Params, Client, Server) ->
    Keys =
        case Params of
            [Names | _] -> [briskd_wire:fold(Name) || Name <- briskd_state_channel:split(Names)];
            [] -> briskd_state_schema:table_keys(channel)
        end,
    Entries = lists:foldl(
        fun(Key, Acc) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{name = Name, topic = Topic, members = Members, flags = Flags}] ->
                    Visible =
                        maps:is_key(Client#client.pid, Members) orelse
                            not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags)),
                    case Visible of
                        true -> [{Name, integer_to_binary(map_size(Members)), Topic} | Acc];
                        false -> Acc
                    end;
                [] ->
                    Acc
            end
        end,
        [],
        Keys
    ),
    briskd_state_send:send_safelist(Client, Server, lists:reverse(Entries));
registered_command(<<"TIME">>, Params, Client, Server) ->
    briskd_info:time(Params, Client, Server);
registered_command(<<"TRACE">>, Params, Client, Server) ->
    briskd_query:trace(Params, Client, Server);
registered_command(<<"STATS">>, Params, Client, Server) ->
    briskd_query:stats(Params, Client, Server);
registered_command(<<"SERVLIST">>, Params, Client, Server) ->
    {Mask, Type} =
        case Params of
            [GivenMask, GivenType | _] -> {GivenMask, GivenType};
            [GivenMask] -> {GivenMask, <<"*">>};
            [] -> {<<"*">>, <<"*">>}
        end,
    briskd_state_net:servlist(Mask, Type, Client, Server);
registered_command(<<"SQUERY">>, Params, Client, Server) ->
    briskd_state_net:squery(Params, Client, Server);
registered_command(<<"VERSION">>, Params, Client, Server) ->
    briskd_info:version(Params, Client, Server);
registered_command(<<"INFO">>, Params, Client, Server) ->
    briskd_info:info(Params, Client, Server);
registered_command(<<"ADMIN">>, Params, Client, Server) ->
    briskd_info:admin(Params, Client, Server);
registered_command(<<"LINKS">>, Params, Client, Server) ->
    briskd_info:links(Params, Client, Server);
registered_command(<<"LUSERS">>, Params, Client, Server) ->
    briskd_info:lusers(Params, Client, Server);
registered_command(<<"ISON">>, [], Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"461">>, [<<"ISON">>], <<"Not enough parameters">>);
registered_command(<<"ISON">>, [<<>> | _], Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"461">>, [<<"ISON">>], <<"Not enough parameters">>);
registered_command(<<"ISON">>, Nicks, Client, Server) ->
    briskd_state_queries:ison(Nicks, Client, Server);
registered_command(<<"USERHOST">>, [], Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"USERHOST">>], <<"Not enough parameters">>
    );
registered_command(<<"USERHOST">>, Nicks, Client, Server) ->
    briskd_state_queries:userhost(Nicks, Client, Server);
registered_command(<<"WHO">>, Params, Client, Server) ->
    briskd_state_queries:who(Params, Client, Server);
registered_command(<<"WHOIS">>, [_ | _] = Args, Client, Server) ->
    case Args of
        [NickMasks] ->
            lists:foreach(
                fun(Nick) -> briskd_state_queries:whois(Nick, Client, Server) end,
                briskd_state_channel:split(NickMasks)
            );
        [Target, NickMasks | _] ->
            %% RFC 2812 3.6.2: the target may also be a nickname, meaning the
            %% server that user is on; this server answers for every user it knows.
            KnownNick =
                briskd_state_client:find_nick(Target) =/= undefined orelse
                    mnesia:dirty_read(remote_client, briskd_wire:fold(Target)) =/= [],
            case KnownNick orelse briskd_info:query_local_server([Target], Server) of
                true ->
                    lists:foreach(
                        fun(Nick) -> briskd_state_queries:whois(Nick, Client, Server) end,
                        briskd_state_channel:split(NickMasks)
                    );
                {false, Unknown} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"402">>, [Unknown], <<"No such server">>
                    )
            end
    end;
registered_command(<<"WHOWAS">>, [], Client, Server) ->
    %% RFC 1459/2812: RPL_ENDOFWHOWAS ends every reply, even an error.
    briskd_state_send:numeric(Client, Server, <<"431">>, [], <<"No nickname given">>),
    briskd_state_send:numeric(Client, Server, <<"369">>, [<<"*">>], <<"End of WHOWAS">>);
registered_command(<<"WHOWAS">>, [NickMasks | Rest], Client, Server) ->
    {Count, Target} = briskd_state_queries:whowas_options(Rest),
    case
        briskd_info:query_local_server(
            case Target of
                undefined -> [];
                Given when is_binary(Given) -> [Given]
            end,
            Server
        )
    of
        {false, Unknown} ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Unknown], <<"No such server">>);
        true ->
            Nicks = briskd_state_channel:split(NickMasks),
            Matched = lists:append([
                briskd_state_queries:whowas_reply(Nick, Count, Client, Server)
             || Nick <- Nicks
            ]),
            %% A mask that resolved to exactly one nickname ends with that
            %% nickname; otherwise the query as given.
            EndParam =
                case lists:usort([briskd_wire:fold(N) || N <- Matched]) of
                    [_] when length(Nicks) =:= 1 -> hd(Matched);
                    _ -> NickMasks
                end,
            briskd_state_send:numeric(Client, Server, <<"369">>, [EndParam], <<"End of WHOWAS">>)
    end;
registered_command(<<"MOTD">>, Params, Client, Server) ->
    briskd_motd:motd(Params, Client, Server);
registered_command(Command, [], Client, Server) when
    Command =:= <<"JOIN">>;
    Command =:= <<"PART">>;
    Command =:= <<"TOPIC">>;
    Command =:= <<"WHOIS">>;
    Command =:= <<"MODE">>;
    Command =:= <<"KICK">>
->
    briskd_state_send:numeric(Client, Server, <<"461">>, [Command], <<"Not enough parameters">>);
registered_command(Command, _, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"421">>, [Command], <<"Unknown command">>).

-doc """
Apply a local client's `NICK` change, checking collisions, multiclient attach,
notifications, holds, and `MONITOR` updates.
""".
-spec change_nick(binary(), #client{}, binary()) -> ok.
change_nick(Nick, Client, Server) ->
    case
        {
            briskd_wire:nickname(Nick, briskd_state_schema:nicklen()),
            briskd_wire:fold(Nick),
            briskd_state_client:find_nick(Nick),
            briskd_state_link:remote_nick_exists(Nick)
        }
    of
        {_, <<"anonymous">>, _, _} ->
            briskd_state_send:numeric(Client, Server, <<"432">>, [Nick], <<"Erroneous nickname">>);
        {false, _, _, _} ->
            briskd_state_send:numeric(Client, Server, <<"432">>, [Nick], <<"Erroneous nickname">>);
        {true, _, #client{pid = Holder} = HolderClient, _} when Holder =/= Client#client.pid ->
            case briskd_state_v3:attachable(Client, HolderClient) of
                true ->
                    briskd_state_v3:prepare_attach(Client, HolderClient, Nick);
                false ->
                    nick_in_use(Client, Nick, Server)
            end;
        {true, _, _, true} ->
            nick_in_use(Client, Nick, Server);
        {true, _, _, false} when Nick =:= Client#client.nick ->
            ok;
        {true, _, _, false} ->
            case briskd_state_client:ready(Client) of
                true ->
                    {NickTags, NickMeta} = briskd_state_history:event_tags(),
                    briskd_state_send:broadcast(
                        briskd_state_channel:nick_recipients(Client),
                        briskd_state_send:prefix(Client),
                        <<"NICK">>,
                        [],
                        Nick,
                        NickTags
                    ),
                    briskd_state_link:propagate_nick_change(Client, Nick),
                    briskd_state_history:note_user_event(
                        Client#client.channels,
                        <<"NICK">>,
                        briskd_state_send:prefix(Client),
                        Nick,
                        NickMeta
                    );
                false ->
                    ok
            end,
            case briskd_state_client:ready(Client) andalso Client#client.nick =/= <<"*">> of
                true -> briskd_state_net:hold_nick(Client#client.nick, Client);
                false -> ok
            end,
            briskd_state_client:save_identity(Client, Client#client{nick = Nick}, Server),
            CaseOnly = briskd_wire:fold(Client#client.nick) =:= briskd_wire:fold(Nick),
            case briskd_state_client:ready(Client) andalso not CaseOnly of
                true ->
                    Renamed = briskd_state_client:client(Client#client.pid),
                    briskd_state_monitor:offline(Client#client.nick),
                    briskd_state_monitor:online(
                        Nick, iolist_to_binary(briskd_state_send:prefix(Renamed))
                    );
                false ->
                    ok
            end
    end.

nick_in_use(Client, Nick, Server) ->
    remember_wanted_nick(Client, Nick),
    briskd_state_send:numeric(
        Client, Server, <<"433">>, [Nick], <<"Nickname is already in use">>
    ).

%% Before registration, a refused NICK is remembered so `REGISTER *` can name
%% the nickname the client asked for (draft/account-registration).
remember_wanted_nick(#client{pid = Pid, nick = <<"*">>}, Nick) ->
    briskd_conn:put(Pid, wanted_nick, briskd_wire:retain(Nick));
remember_wanted_nick(_Client, _Nick) ->
    ok.
