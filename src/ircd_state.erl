-module(ircd_state).
-behaviour(gen_server).
-export([
    authenticate_server_link/2,
    command/3,
    command/4,
    input_too_long/1,
    connect/1,
    find_nick/1,
    format_status/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    init/1,
    numeric/5,
    ready/1,
    registered/0,
    register_adjacent/3,
    remote_channel_flags/1,
    remote_user_visible_to_requester/3,
    server_burst/0,
    server_command/4,
    server_command/5,
    server_disconnect/1,
    start_link/1,
    user_modes/1,
    user_visible/2,
    visible_member/3,
    wildcard_match/2
]).
-include("ircd_state.hrl").

%% @doc Own IRC client, channel, and peer state for this server.

%% @doc Start the process that owns IRC client and channel state.
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% @doc Register the calling session as a connected client using its peer host.
-spec connect(binary()) -> ok.
connect(Host) -> gen_server:call(?MODULE, {connect, Host}).

%% @doc Apply a parsed IRC command on behalf of the calling session.
%% Params contains the command's tokenized parameters and Bytes is the wire line size.
-spec command(binary(), [binary()], non_neg_integer()) -> ok | quit.
command(Command, Params, Bytes) -> command(Command, Params, Bytes, []).

%% @doc Apply a client command that may carry IRCv3 message tags.
-spec command(binary(), [binary()], non_neg_integer(), [{binary(), undefined | binary()}]) ->
    ok | quit.
command(Command, Params, Bytes, Tags) ->
    gen_server:call(?MODULE, {command, Command, Params, Bytes, Tags}).

%% @doc Reject an over-long tagged line with numeric 417 and do not relay it.
-spec input_too_long([{binary(), undefined | binary()}]) -> ok.
input_too_long(Tags) -> gen_server:call(?MODULE, {input_too_long, Tags}).

%% @doc Return whether the calling session has completed NICK and USER registration.
-spec registered() -> boolean().
registered() -> gen_server:call(?MODULE, registered).

%% @doc Return the RFC 2813 client and channel burst for an authenticated link.
-spec server_burst() -> [binary()].
server_burst() -> gen_server:call(?MODULE, server_burst).

%% @doc Remember a directly connected peer after its handshake succeeds.
-spec register_adjacent(binary(), binary(), inbound | outbound) -> ok.
register_adjacent(Name, Token, Kind) ->
    gen_server:call(?MODULE, {register_adjacent, Name, Token, Kind}).

%% @doc Apply a state message received from an authenticated peer.
-spec server_command(binary(), undefined | binary(), binary(), [binary()]) -> ok | {error, term()}.
server_command(Peer, Prefix, Command, Params) ->
    server_command(Peer, Prefix, Command, Params, []).

%% @doc Apply a peer message, keeping only client-only tags for later relay.
-spec server_command(
    binary(), undefined | binary(), binary(), [binary()], [{binary(), undefined | binary()}]
) ->
    ok | {error, term()}.
server_command(Peer, Prefix, Command, Params, Tags) ->
    gen_server:call(?MODULE, {server_command, Peer, Prefix, Command, Params, Tags}).

%% @doc Drop imported client state when a server link closes.
%% A missing state process during shutdown is ignored. Other failures propagate.
-spec server_disconnect(binary()) -> ok.
server_disconnect(Peer) ->
    try gen_server:call(?MODULE, {server_disconnect, Peer}) of
        ok -> ok
    catch
        exit:{noproc, _} -> ok;
        exit:shutdown -> ok;
        exit:{shutdown, _} -> ok
    end.

%% @doc Check an inbound server's name and shared password against configured peers.
-spec authenticate_server_link(binary(), binary()) -> boolean().
authenticate_server_link(Name, Password) ->
    Links = persistent_term:get({?MODULE, server_links}, []),
    lists:any(
        fun(#{name := Expected, password := Secret}) ->
            ircd_wire:fold(Name) =:= ircd_wire:fold(Expected) andalso
                ircd_config:secret_match(Password, Secret)
        end,
        Links
    ).

%% @doc Initialize Mnesia tables and start the state server with the server name.
-spec init(map()) -> {ok, binary()}.
init(#{name := Name} = Config) ->
    Started = calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}]),
    persistent_term:put({?MODULE, started}, Started),
    persistent_term:put({?MODULE, started_at}, erlang:monotonic_time(second)),
    ets:new(ircd_command_stats, [named_table, public, set, {write_concurrency, true}]),
    ets:new(ircd_connection_stats, [named_table, public, set, {write_concurrency, true}]),
    ensure_ets(ircd_caps),
    ensure_ets(ircd_inbound_peers),
    ensure_ets(ircd_outbound_ready),
    ensure_ets(ircd_holds),
    persistent_term:put({?MODULE, config}, Config),
    persistent_term:put({?MODULE, config_path}, maps:get(config_path, Config)),
    persistent_term:put({?MODULE, motd_file}, maps:get(motd_file, Config, null)),
    persistent_term:put({?MODULE, client_password}, maps:get(client_password, Config, null)),
    persistent_term:put({?MODULE, server_links}, maps:get(server_links, Config, [])),
    persistent_term:put({?MODULE, admin}, maps:get(admin, Config, #{})),
    persistent_term:put({?MODULE, operators}, maps:get(operators, Config, [])),
    persistent_term:put({?MODULE, reop_delay}, maps:get(reop_delay, Config, 30)),
    table(client, record_info(fields, client), [{index, [nick]}]),
    table(channel, record_info(fields, channel), []),
    table(activity, record_info(fields, activity), []),
    table(whowas, record_info(fields, whowas), []),
    table(user_modes, record_info(fields, user_modes), []),
    table(remote_client, record_info(fields, remote_client), []),
    table(remote_channel, record_info(fields, remote_channel), []),
    table(known_server, record_info(fields, known_server), []),
    table(service, record_info(fields, service), []),
    ok = mnesia:wait_for_tables(
        [
            client,
            channel,
            activity,
            whowas,
            user_modes,
            remote_client,
            remote_channel,
            known_server,
            service
        ],
        5000
    ),
    {atomic, ok} = mnesia:clear_table(client),
    reset_channels(),
    {atomic, ok} = mnesia:clear_table(activity),
    {atomic, ok} = mnesia:clear_table(user_modes),
    {atomic, ok} = mnesia:clear_table(remote_client),
    {atomic, ok} = mnesia:clear_table(remote_channel),
    {atomic, ok} = mnesia:clear_table(known_server),
    {atomic, ok} = mnesia:clear_table(service),
    erlang:send_after(1000, self(), reop_tick),
    {ok, Name}.

table(Table, Fields, Options) ->
    case mnesia:create_table(Table, [{attributes, Fields}, {disc_copies, [node()]} | Options]) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, Table}} ->
            ok = load_table(Table, Fields, Options),
            ensure_table_shape(Table, Fields),
            ensure_disc_copy(Table)
    end.

%% An existing schema entry is not readable until its local copy is loaded.
load_table(Table, Fields, Options) ->
    case mnesia:force_load_table(Table) of
        yes ->
            ok;
        ok ->
            ok;
        Error ->
            logger:warning("Replacing unloaded Mnesia table ~p after ~p", [Table, Error]),
            replace_table(Table, Fields, Options)
    end.

replace_table(Table, Fields, Options) ->
    case mnesia:delete_table(Table) of
        {atomic, ok} ->
            ok;
        {aborted, Reason} ->
            logger:warning("Mnesia delete_table ~p returned ~p", [Table, Reason])
    end,
    case mnesia:create_table(Table, [{attributes, Fields}, {disc_copies, [node()]} | Options]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Table}} -> ok
    end.

ensure_disc_copy(Table) ->
    case mnesia:table_info(Table, storage_type) of
        ram_copies ->
            {atomic, ok} = mnesia:change_table_copy_type(Table, node(), disc_copies);
        disc_copies ->
            ok
    end.

ensure_table_shape(channel, Fields) ->
    case mnesia:table_info(channel, attributes) of
        Fields ->
            ok;
        OldFields ->
            {atomic, ok} = mnesia:transform_table(
                channel,
                fun(Old) -> list_to_tuple(tuple_to_list(Old) ++ [undefined, undefined]) end,
                Fields
            ),
            logger:info("Migrated Mnesia channel table from ~p", [OldFields])
    end;
ensure_table_shape(client, Fields) ->
    case mnesia:table_info(client, attributes) of
        Fields ->
            ok;
        OldFields ->
            {atomic, ok} = mnesia:transform_table(
                client,
                fun(Old) -> list_to_tuple(tuple_to_list(Old) ++ [undefined]) end,
                Fields
            ),
            logger:info("Migrated Mnesia client table from ~p", [OldFields])
    end;
ensure_table_shape(remote_channel, Fields) ->
    migrate_appended(remote_channel, Fields, #{});
ensure_table_shape(remote_client, Fields) ->
    migrate_appended(remote_client, Fields, undefined);
ensure_table_shape(Table, Fields) ->
    case mnesia:table_info(Table, attributes) of
        Fields -> ok;
        OldFields -> logger:warning("Leaving Mnesia table ~p unchanged from ~p", [Table, OldFields])
    end.

%% Append missing record fields. New remote-channel fields default to a map.
%% A migrated remote client gets `server = undefined` and `hop = 1`.
migrate_appended(Table, Fields, Default) ->
    case attributes(Table) of
        Fields ->
            ok;
        OldFields when is_list(OldFields) ->
            Width = length(Fields) + 1,
            case
                mnesia:transform_table(
                    Table,
                    fun(Old) ->
                        List = tuple_to_list(Old),
                        Missing = Width - length(List),
                        Pads = pads(Table, Missing, Default),
                        list_to_tuple(List ++ Pads)
                    end,
                    Fields
                )
            of
                {atomic, ok} ->
                    logger:info("Migrated Mnesia ~p table from ~p", [Table, OldFields]);
                {aborted, Reason} ->
                    recreate_transient_table(Table, Fields, Reason)
            end;
        Other ->
            recreate_transient_table(Table, Fields, Other)
    end.

attributes(Table) ->
    try mnesia:table_info(Table, attributes) of
        Fields when is_list(Fields) -> Fields;
        Other -> Other
    catch
        exit:Reason -> Reason
    end.

%% Remote tables are cleared on startup, so a broken disc copy can be replaced.
recreate_transient_table(Table, Fields, Reason) ->
    logger:warning("Recreating transient Mnesia table ~p after ~p", [Table, Reason]),
    replace_table(Table, Fields, []).

pads(remote_client, Missing, _Default) when Missing >= 2 ->
    [undefined, 1 | lists:duplicate(Missing - 2, undefined)];
pads(_Table, Missing, Default) ->
    lists:duplicate(Missing, Default).

ensure_ets(Name) ->
    case ets:whereis(Name) of
        undefined -> ets:new(Name, [named_table, public, set]);
        _ -> ets:delete_all_objects(Name)
    end.

reset_channels() ->
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{name = <<$!, _/binary>>} = Channel] ->
                    mnesia:dirty_write(
                        Channel#channel{members = #{}, invited = [], opless_since = undefined}
                    );
                [_Channel] ->
                    mnesia:dirty_delete(channel, Key);
                [] ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(channel)
    ).

%% @doc Handle session registration, registration queries, and client commands.
handle_call({connect, Host}, {Pid, _}, Server) ->
    monitor(process, Pid),
    mnesia:dirty_write(#client{pid = Pid, host = Host}),
    ircd_cap:connect(Pid),
    ircd_state_client:touch_activity(Pid),
    ircd_state_client:put_connection_stats(Pid, #{}),
    mnesia:dirty_write(#user_modes{pid = Pid}),
    {reply, ok, Server};
handle_call(registered, {Pid, _}, Server) ->
    {reply, ircd_state_client:ready(ircd_state_client:client(Pid)), Server};
handle_call(server_burst, _, Server) ->
    {reply, ircd_state_link:server_burst_lines(Server), Server};
handle_call({register_adjacent, Name, Token, Kind}, {Pid, _}, Server) ->
    %% Inbound registration records the calling session. Outbound links are
    %% found through the link supervisor, so the caller pid is not stored.
    Result = ircd_state_net:register_adjacent(Name, Token, Kind, Pid),
    {reply, Result, Server};
handle_call({server_command, Peer, _Prefix, <<"NJOIN">>, [Name, Members]}, _, Server) ->
    {reply, ircd_state_link:import_remote_njoin(Peer, Name, Members), Server};
handle_call({server_command, Peer, Prefix, <<"JOIN">>, [Name | _]}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_link:import_remote_join(Peer, Prefix, Name), Server};
handle_call({server_command, Peer, Prefix, <<"PART">>, [Name | Rest]}, _, Server) when
    is_binary(Prefix)
->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    {reply, ircd_state_link:remove_remote_channel_member(Peer, Prefix, Name, Reason), Server};
handle_call({server_command, Peer, Prefix, <<"TOPIC">>, [Name, Text]}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_link:update_remote_topic(Peer, Prefix, Name, Text), Server};
handle_call({server_command, Peer, Prefix, <<"KICK">>, [Name, Nick | Rest]}, _, Server) when
    is_binary(Prefix)
->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    {reply, ircd_state_link:receive_remote_kick(Peer, Prefix, Name, Nick, Reason), Server};
handle_call({server_command, Peer, Prefix, <<"NICK">>, [Nick]}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_link:rename_remote_nick(Peer, Prefix, Nick), Server};
handle_call({server_command, Peer, Prefix, <<"QUIT">>, Params}, _, Server) when
    is_binary(Prefix)
->
    Reason =
        case Params of
            [Text | _] -> Text;
            [] -> <<"QUIT">>
        end,
    {reply, ircd_state_link:remove_remote_nick(Peer, Prefix, Reason), Server};
handle_call({server_command, Peer, Prefix, <<"AWAY">>, Params}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_link:set_remote_away(Peer, Prefix, Params), Server};
handle_call({server_command, Peer, Prefix, <<"NICK">>, Params}, _, Server) when
    is_binary(Prefix), length(Params) =:= 7
->
    {reply, ircd_state_link:import_remote_nick(Peer, Prefix, Params), Server};
handle_call({server_command, Peer, Prefix, <<"MODE">>, [Name, Modes | Args]}, _, Server) ->
    {reply, ircd_state_link:update_remote_modes(Peer, Prefix, Name, Modes, Args), Server};
handle_call({server_command, Peer, Prefix, Command, Params, Tags}, _, Server) when
    is_binary(Prefix),
    (Command =:= <<"PRIVMSG">> orelse Command =:= <<"NOTICE">> orelse Command =:= <<"TAGMSG">>)
->
    {reply, ircd_state_link:receive_remote_message(Peer, Prefix, Command, Params, Tags), Server};
handle_call({server_command, Peer, Prefix, Command, Params, _Tags}, From, Server) ->
    handle_call({server_command, Peer, Prefix, Command, Params}, From, Server);
handle_call({server_command, Peer, Prefix, Command, Params}, _, Server) when
    is_binary(Prefix), (Command =:= <<"PRIVMSG">> orelse Command =:= <<"NOTICE">>)
->
    {reply, ircd_state_link:receive_remote_message(Peer, Prefix, Command, Params, []), Server};
handle_call({server_command, Peer, Prefix, <<"SERVER">>, [Name, Hop, Token, Info | _]}, _, Server) ->
    {reply, ircd_state_net:introduce_server(Peer, Prefix, Name, Hop, Token, Info), Server};
handle_call({server_command, Peer, _Prefix, <<"SQUIT">>, [Target | Rest]}, _, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> <<"SQUIT">>
        end,
    ircd_state_net:split(Target, Reason, Peer),
    {reply, ok, Server};
handle_call({server_command, Peer, Prefix, <<"INVITE">>, [Nick, Name | _]}, _, Server) ->
    {reply, ircd_state_link:receive_remote_invite(Peer, Prefix, Nick, Name), Server};
handle_call({server_command, Peer, Prefix, <<"SERVICE">>, Params}, _, Server) ->
    {reply, ircd_state_net:import_service(Peer, Prefix, Params), Server};
handle_call({server_command, Peer, Prefix, <<"SQUERY">>, Params}, _, Server) when
    is_binary(Prefix)
->
    {reply, ircd_state_link:receive_remote_message(Peer, Prefix, <<"SQUERY">>, Params), Server};
handle_call({server_command, Peer, _Prefix, <<"KILL">>, [Nick | Rest]}, _, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> <<"KILL">>
        end,
    {reply, ircd_state_link:receive_remote_kill(Peer, Nick, Reason), Server};
handle_call({server_command, _Peer, _Prefix, _Command, _Params}, _, Server) ->
    {reply, ok, Server};
handle_call({server_disconnect, Peer}, _, Server) ->
    ircd_state_net:split(Peer, <<"Netsplit ", Peer/binary>>, Peer),
    {reply, ok, Server};
handle_call({input_too_long, Tags}, {Pid, _}, Server) ->
    Client = ircd_state_client:client(Pid),
    Label = ircd_cap:label(ircd_cap:state(Pid), Tags),
    ok = ircd_state_send:begin_label(Pid, Label),
    try
        ircd_state_send:numeric(Client, Server, <<"417">>, [], <<"Input line was too long">>)
    after
        ircd_state_send:end_label(Server)
    end,
    {reply, ok, Server};
handle_call({command, Command, Params, Bytes, Tags}, {Pid, _}, Server) ->
    count_command(Pid, Command, Bytes),
    Client = ircd_state_client:client(Pid),
    Label =
        case welcomed_cap_end(Client, Command, Params) of
            true -> undefined;
            false -> ircd_cap:label(ircd_cap:state(Pid), Tags)
        end,
    ok = ircd_state_send:begin_label(Pid, Label),
    Reply =
        try
            dispatch(Command, Params, Client, Server, Tags)
        after
            ircd_state_send:end_label(Server)
        end,
    case Reply of
        quit -> ok;
        _ -> ircd_state_client:touch_activity(Pid)
    end,
    {reply, Reply, Server}.

%% @doc Ignore unsupported asynchronous state messages.
handle_cast(_, State) -> {noreply, State}.

%% @doc Remove client state after its session process exits.
handle_info({'DOWN', _, process, Pid, _}, State) ->
    case mnesia:dirty_read(client, Pid) of
        [Client] -> ircd_state_client:disconnect(Client, <<"Connection closed">>, State);
        [] -> ok
    end,
    {noreply, State};
handle_info(reop_tick, Server) ->
    ircd_state_channel:reop_channels(Server),
    erlang:send_after(1000, self(), reop_tick),
    {noreply, Server};
%% Ignore unknown messages. Reop and session DOWN are the only expected info events.
handle_info(_, State) ->
    {noreply, State}.

%% @doc Hide PASS and OPER secrets if a crash report includes the current message.
-spec format_status(map()) -> map().
format_status(Status) ->
    maps:map(fun redact_status/2, Status).

redact_status(message, Message) ->
    redact_command(Message);
redact_status(log, Log) when is_list(Log) ->
    [redact_log_event(Event) || Event <- Log];
redact_status(_, Value) ->
    Value.

redact_log_event({Type, Message}) ->
    {Type, redact_command(Message)};
redact_log_event({Type, Message, Extra}) ->
    {Type, redact_command(Message), Extra};
redact_log_event(Event) ->
    Event.

redact_command({'$gen_call', From, Request}) ->
    {'$gen_call', From, redact_command(Request)};
redact_command({command, <<"PASS">>, [_Password | Rest], Bytes, Tags}) ->
    {command, <<"PASS">>, [redacted | Rest], Bytes, Tags};
redact_command({command, <<"PASS">>, [_Password | Rest], Bytes}) ->
    {command, <<"PASS">>, [redacted | Rest], Bytes};
redact_command({command, <<"OPER">>, [Name, _Password | Rest], Bytes, Tags}) ->
    {command, <<"OPER">>, [Name, redacted | Rest], Bytes, Tags};
redact_command({command, <<"OPER">>, [Name, _Password | Rest], Bytes}) ->
    {command, <<"OPER">>, [Name, redacted | Rest], Bytes};
redact_command(Message) ->
    Message.

welcomed_cap_end(Client, <<"CAP">>, [<<"END">> | _]) ->
    ircd_cap:welcomed(Client#client.pid);
welcomed_cap_end(_, _, _) ->
    false.

%% Route commands accepted before registration and enforce registration for the rest.
dispatch(<<"QUIT">>, Params, Client, Server, _Tags) ->
    Reason =
        case Params of
            [Text | _] -> Text;
            [] -> <<"Client quit">>
        end,
    ircd_state_client:disconnect(Client, Reason, Server),
    quit;
dispatch(<<"PASS">>, Params, Client, Server, _Tags) ->
    ircd_state_client:pass(Params, Client, Server);
dispatch(<<"PING">>, [Token | _], Client, Server, _Tags) ->
    ircd_state_send:send(Client#client.pid, Server, <<"PONG">>, [Server], Token);
dispatch(<<"PING">>, [], Client, Server, _Tags) ->
    ircd_state_send:numeric(Client, Server, <<"409">>, [], <<"No origin specified">>);
dispatch(<<"PONG">>, _, _, _, _Tags) ->
    ok;
dispatch(<<"CAP">>, Params, Client, Server, _Tags) ->
    ircd_state_net:cap(Client, Server, Params);
dispatch(<<"NICK">>, [Nick | _], Client, Server, _Tags) ->
    case ircd_state_net:nick_blocked(Nick) of
        true ->
            ircd_state_send:numeric(
                Client, Server, <<"437">>, [Nick], <<"Nick/channel is temporarily unavailable">>
            );
        false ->
            change_nick(Nick, Client, Server)
    end;
dispatch(<<"NICK">>, [], Client, Server, _Tags) ->
    ircd_state_send:numeric(Client, Server, <<"431">>, [], <<"No nickname given">>);
dispatch(<<"USER">>, [User, Mode, _, Real], #client{user = undefined} = Client, Server, _Tags) ->
    case
        {
            re:run(User, <<"^[A-Za-z0-9_.-]{1,32}$">>, [{capture, none}, dollar_endonly]),
            ircd_state_client:initial_user_modes(Mode)
        }
    of
        {match, {ok, Modes}} ->
            mnesia:dirty_write(#user_modes{pid = Client#client.pid, modes = Modes}),
            ircd_state_client:save_identity(
                Client, Client#client{user = User, real = Real}, Server
            );
        {nomatch, _} ->
            ircd_state_send:numeric(
                Client, Server, <<"461">>, [<<"USER">>], <<"Invalid username">>
            );
        {_, error} ->
            ircd_state_send:numeric(
                Client, Server, <<"461">>, [<<"USER">>], <<"Invalid user mode mask">>
            )
    end;
dispatch(<<"USER">>, _, Client, Server, _Tags) ->
    case Client#client.user of
        undefined ->
            ircd_state_send:numeric(
                Client, Server, <<"461">>, [<<"USER">>], <<"Not enough parameters">>
            );
        _ ->
            ircd_state_send:numeric(Client, Server, <<"462">>, [], <<"You may not reregister">>)
    end;
dispatch(Command, Params, Client, Server, Tags) ->
    case ircd_state_client:ready(Client) of
        true ->
            registered_command(Command, Params, Client, Server, Tags);
        false ->
            ircd_state_send:numeric(Client, Server, <<"451">>, [], <<"You have not registered">>)
    end.

%% Implement commands that require a fully registered client.
registered_command(Command, Params, Client, Server, Tags) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>; Command =:= <<"TAGMSG">>
->
    ircd_state_channel:deliver(Command, Params, Client, Server, Tags);
registered_command(Command, Params, Client, Server, _Tags) ->
    registered_command(Command, Params, Client, Server).

registered_command(<<"AWAY">>, [], #client{} = Client, Server) ->
    case Client#client.away of
        undefined ->
            ircd_state_send:numeric(
                Client, Server, <<"305">>, [], <<"You are no longer marked as being away">>
            );
        _ ->
            mnesia:dirty_write(Client#client{away = undefined}),
            ircd_state_link:propagate_away(Client, none),
            ircd_state_send:numeric(
                Client, Server, <<"305">>, [], <<"You are no longer marked as being away">>
            )
    end,
    ok;
registered_command(<<"AWAY">>, [Message | _], #client{} = Client, Server) ->
    mnesia:dirty_write(Client#client{away = Message}),
    ircd_state_link:propagate_away(Client, Message),
    ircd_state_send:numeric(
        Client, Server, <<"306">>, [], <<"You have been marked as being away">>
    ),
    ok;
registered_command(<<"JOIN">>, [<<"0">> | _], Client, _) ->
    lists:foreach(
        fun(Key) -> ircd_state_channel:leave(Key, Client, <<"PART">>, none, true) end,
        Client#client.channels
    );
registered_command(<<"JOIN">>, [Names | Rest], Client, Server) ->
    Keys =
        case Rest of
            [Passwords | _] -> binary:split(Passwords, <<",">>, [global]);
            [] -> []
        end,
    ircd_state_channel:join_channels(
        ircd_state_channel:split(Names), Keys, Client#client.pid, Server
    );
registered_command(<<"PART">>, [Names | Rest], Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    lists:foreach(
        fun(Name) ->
            Key = ircd_wire:fold(Name),
            Current = ircd_state_client:client(Client#client.pid),
            case {mnesia:dirty_read(channel, Key), lists:member(Key, Current#client.channels)} of
                {[], _} ->
                    ircd_state_send:numeric(
                        Current, Server, <<"403">>, [Name], <<"No such channel">>
                    );
                {_, false} ->
                    ircd_state_send:numeric(
                        Current, Server, <<"442">>, [Name], <<"You're not on that channel">>
                    );
                {_, true} ->
                    ircd_state_channel:leave(Key, Current, <<"PART">>, Reason, true)
            end
        end,
        ircd_state_channel:split(Names)
    );
registered_command(<<"KICK">>, [Name, Nicks | Rest], Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> Client#client.nick
        end,
    Channels = ircd_state_channel:split(Name),
    Targets = ircd_state_channel:split(Nicks),
    case {Channels, Targets} of
        {[Channel], [_ | _]} ->
            ircd_state_channel:kick(Channel, Targets, Reason, Client, Server);
        {ChannelList, TargetList} when
            length(ChannelList) =:= length(TargetList),
            length(ChannelList) > 1
        ->
            lists:foreach(
                fun({Channel, Target}) ->
                    ircd_state_channel:kick(Channel, [Target], Reason, Client, Server)
                end,
                lists:zip(ChannelList, TargetList)
            );
        _ ->
            ircd_state_send:numeric(
                Client, Server, <<"461">>, [<<"KICK">>], <<"Invalid channel/user list">>
            )
    end;
registered_command(<<"KICK">>, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"KICK">>], <<"Not enough parameters">>);
registered_command(<<"KNOCK">>, [Name | Rest], Client, Server) ->
    ircd_state_channel:knock(Name, Rest, Client, Server);
registered_command(<<"KNOCK">>, [], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"KNOCK">>], <<"Not enough parameters">>);
registered_command(<<"INVITE">>, [Nick, Name | _], Client, Server) ->
    ircd_state_channel:invite(Nick, Name, Client, Server);
registered_command(<<"INVITE">>, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"INVITE">>], <<"Not enough parameters">>);
registered_command(<<"MODE">>, [Target | Rest], Client, Server) ->
    ircd_state_channel:mode_command(Target, Rest, Client, Server);
registered_command(<<"OPER">>, [Name, Password | _], Client, Server) ->
    ircd_state_info:oper(Name, Password, Client, Server);
registered_command(<<"OPER">>, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"OPER">>], <<"Not enough parameters">>);
registered_command(<<"KILL">>, Params, Client, Server) ->
    ircd_state_info:kill(Params, Client, Server);
registered_command(<<"CONNECT">>, Params, Client, Server) ->
    ircd_state_net:oper_command(<<"CONNECT">>, Params, Client, Server);
registered_command(<<"SQUIT">>, Params, Client, Server) ->
    ircd_state_net:oper_command(<<"SQUIT">>, Params, Client, Server);
registered_command(<<"DIE">>, Params, Client, Server) ->
    ircd_state_net:oper_command(<<"DIE">>, Params, Client, Server);
registered_command(<<"RESTART">>, Params, Client, Server) ->
    ircd_state_net:oper_command(<<"RESTART">>, Params, Client, Server);
registered_command(<<"SERVICE">>, Params, Client, Server) ->
    ircd_state_net:oper_command(<<"SERVICE">>, Params, Client, Server);
registered_command(<<"WALLOPS">>, _, Client, Server) ->
    ircd_state_send:numeric(
        Client,
        Server,
        <<"481">>,
        [],
        <<"Permission Denied- WALLOPS is server only">>
    );
registered_command(<<"REHASH">>, _, Client, Server) ->
    ircd_state_info:rehash(Client, Server);
registered_command(<<"SUMMON">>, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"445">>, [], <<"SUMMON has been disabled">>);
registered_command(<<"USERS">>, Params, Client, Server) ->
    ircd_state_info:users_disabled(Params, Client, Server);
registered_command(<<"TOPIC">>, [Name | Rest], Client, Server) ->
    ircd_state_channel:topic(Name, Rest, Client, Server);
registered_command(<<"NAMES">>, Params, Client, Server) ->
    case Params of
        [Names | _] ->
            lists:foreach(
                fun(Name) -> ircd_state_channel:names(Name, Client, Server) end,
                ircd_state_channel:split(Names)
            );
        [] ->
            lists:foreach(
                fun(Key) -> ircd_state_channel:names_listing(Key, Client, Server) end,
                mnesia:dirty_all_keys(channel)
            ),
            LocalKeys = mnesia:dirty_all_keys(channel),
            lists:foreach(
                fun(Key) ->
                    case lists:member(Key, LocalKeys) of
                        true -> ok;
                        false -> ircd_state_link:remote_names_listing(Key, Client, Server)
                    end
                end,
                mnesia:dirty_all_keys(remote_channel)
            ),
            ircd_state_channel:names_unattached(Client, Server),
            ircd_state_send:numeric(Client, Server, <<"366">>, [<<"*">>], <<"End of NAMES list">>)
    end;
registered_command(<<"LIST">>, Params, Client, Server) ->
    Keys =
        case Params of
            [Names | _] -> [ircd_wire:fold(Name) || Name <- ircd_state_channel:split(Names)];
            [] -> mnesia:dirty_all_keys(channel)
        end,
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{name = Name, topic = Topic, members = Members, flags = Flags}] ->
                    Visible =
                        maps:is_key(Client#client.pid, Members) orelse
                            not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags)),
                    case Visible of
                        true ->
                            ircd_state_send:numeric(
                                Client,
                                Server,
                                <<"322">>,
                                [Name, integer_to_binary(map_size(Members))],
                                Topic
                            );
                        false ->
                            ok
                    end;
                [] ->
                    ok
            end
        end,
        Keys
    ),
    ircd_state_send:numeric(Client, Server, <<"323">>, [], <<"End of LIST">>);
registered_command(<<"TIME">>, Params, Client, Server) ->
    case ircd_state_info:query_local_server(Params, Server) of
        true ->
            ircd_state_send:numeric(
                Client,
                Server,
                <<"391">>,
                [Server],
                calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}])
            );
        {false, Target} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end;
registered_command(<<"TRACE">>, Params, Client, Server) ->
    ircd_state_info:trace(Params, Client, Server);
registered_command(<<"STATS">>, Params, Client, Server) ->
    ircd_state_info:stats(Params, Client, Server);
registered_command(<<"SERVLIST">>, Params, Client, Server) ->
    {Mask, Type} =
        case Params of
            [GivenMask, GivenType | _] -> {GivenMask, GivenType};
            [GivenMask] -> {GivenMask, <<"*">>};
            [] -> {<<"*">>, <<"*">>}
        end,
    ircd_state_net:servlist(Mask, Type, Client, Server);
registered_command(<<"SQUERY">>, Params, Client, Server) ->
    ircd_state_net:squery(Params, Client, Server);
registered_command(<<"VERSION">>, Params, Client, Server) ->
    case ircd_state_info:query_local_server(Params, Server) of
        true ->
            ircd_state_send:numeric(
                Client, Server, <<"351">>, [<<"0.1.0">>, Server], <<"Erlang/OTP IRC server">>
            );
        {false, Target} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end;
registered_command(<<"INFO">>, Params, Client, Server) ->
    ircd_state_info:info(Params, Client, Server);
registered_command(<<"ADMIN">>, Params, Client, Server) ->
    ircd_state_info:admin(Params, Client, Server);
registered_command(<<"LINKS">>, Params, Client, Server) ->
    ircd_state_info:links(Params, Client, Server);
registered_command(<<"LUSERS">>, Params, Client, Server) ->
    ircd_state_info:lusers(Params, Client, Server);
registered_command(<<"ISON">>, [], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"ISON">>], <<"Not enough parameters">>);
registered_command(<<"ISON">>, [<<>> | _], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"ISON">>], <<"Not enough parameters">>);
registered_command(<<"ISON">>, Nicks, Client, Server) ->
    ircd_state_queries:ison(Nicks, Client, Server);
registered_command(<<"USERHOST">>, [], Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"USERHOST">>], <<"Not enough parameters">>
    );
registered_command(<<"USERHOST">>, Nicks, Client, Server) ->
    ircd_state_queries:userhost(Nicks, Client, Server);
registered_command(<<"WHO">>, Params, Client, Server) ->
    ircd_state_queries:who(Params, Client, Server);
registered_command(<<"WHOIS">>, [_ | _] = Args, Client, Server) ->
    case Args of
        [NickMasks] ->
            lists:foreach(
                fun(Nick) -> ircd_state_queries:whois(Nick, Client, Server) end,
                ircd_state_channel:split(NickMasks)
            );
        [Target, NickMasks | _] ->
            case ircd_state_info:query_local_server([Target], Server) of
                true ->
                    lists:foreach(
                        fun(Nick) -> ircd_state_queries:whois(Nick, Client, Server) end,
                        ircd_state_channel:split(NickMasks)
                    );
                {false, Unknown} ->
                    ircd_state_send:numeric(
                        Client, Server, <<"402">>, [Unknown], <<"No such server">>
                    )
            end
    end;
registered_command(<<"WHOWAS">>, [], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"431">>, [], <<"No nickname given">>);
registered_command(<<"WHOWAS">>, [NickMasks | Rest], Client, Server) ->
    {Count, Target} = ircd_state_queries:whowas_options(Rest),
    case
        ircd_state_info:query_local_server(
            case Target of
                undefined -> [];
                _ -> [Target]
            end,
            Server
        )
    of
        {false, Unknown} ->
            ircd_state_send:numeric(Client, Server, <<"402">>, [Unknown], <<"No such server">>);
        true ->
            Nicks = ircd_state_channel:split(NickMasks),
            lists:foreach(
                fun(Nick) -> ircd_state_queries:whowas_reply(Nick, Count, Client, Server) end, Nicks
            ),
            ircd_state_send:numeric(Client, Server, <<"369">>, [NickMasks], <<"End of WHOWAS">>)
    end;
registered_command(<<"MOTD">>, Params, Client, Server) ->
    ircd_state_info:motd(Params, Client, Server);
registered_command(<<"AWAY">>, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"AWAY">>], <<"Not enough parameters">>);
registered_command(Command, [], Client, Server) when
    Command =:= <<"JOIN">>;
    Command =:= <<"PART">>;
    Command =:= <<"TOPIC">>;
    Command =:= <<"WHOIS">>;
    Command =:= <<"MODE">>;
    Command =:= <<"KICK">>
->
    ircd_state_send:numeric(Client, Server, <<"461">>, [Command], <<"Not enough parameters">>);
registered_command(Command, _, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"421">>, [Command], <<"Unknown command">>).

change_nick(Nick, Client, Server) ->
    case
        {
            ircd_wire:nickname(Nick),
            ircd_wire:fold(Nick),
            ircd_state_client:find_nick(Nick),
            ircd_state_link:remote_nick_exists(Nick)
        }
    of
        {_, <<"anonymous">>, _, _} ->
            ircd_state_send:numeric(Client, Server, <<"432">>, [Nick], <<"Erroneous nickname">>);
        {false, _, _, _} ->
            ircd_state_send:numeric(Client, Server, <<"432">>, [Nick], <<"Erroneous nickname">>);
        {true, _, #client{pid = Pid}, _} when Pid =/= Client#client.pid ->
            ircd_state_send:numeric(
                Client, Server, <<"433">>, [Nick], <<"Nickname is already in use">>
            );
        {true, _, _, true} ->
            ircd_state_send:numeric(
                Client, Server, <<"433">>, [Nick], <<"Nickname is already in use">>
            );
        {true, _, _, false} ->
            case ircd_state_client:ready(Client) of
                true ->
                    ircd_state_send:broadcast(
                        ircd_state_channel:nick_recipients(Client),
                        ircd_state_send:prefix(Client),
                        <<"NICK">>,
                        [],
                        Nick
                    ),
                    ircd_state_link:propagate_nick_change(Client, Nick);
                false ->
                    ok
            end,
            case ircd_state_client:ready(Client) andalso Client#client.nick =/= <<"*">> of
                true -> ircd_state_net:hold_nick(Client#client.nick);
                false -> ok
            end,
            ircd_state_client:save_identity(Client, Client#client{nick = Nick}, Server)
    end.

count_command(Pid, Command, MessageBytes) ->
    case supported_command(Command) of
        true ->
            ets:update_counter(
                ircd_command_stats,
                Command,
                [{2, 1}, {3, MessageBytes}],
                {Command, 0, 0}
            );
        false ->
            ok
    end,
    ircd_state_client:update_connection_stats(Pid, recv_messages, recv_bytes, MessageBytes).

supported_command(Command) ->
    lists:member(
        Command,
        [
            <<"ADMIN">>,
            <<"AWAY">>,
            <<"CAP">>,
            <<"CONNECT">>,
            <<"DIE">>,
            <<"INVITE">>,
            <<"INFO">>,
            <<"ISON">>,
            <<"JOIN">>,
            <<"KICK">>,
            <<"KILL">>,
            <<"LINKS">>,
            <<"LIST">>,
            <<"LUSERS">>,
            <<"MODE">>,
            <<"MOTD">>,
            <<"NAMES">>,
            <<"NICK">>,
            <<"OPER">>,
            <<"PART">>,
            <<"PING">>,
            <<"PONG">>,
            <<"PRIVMSG">>,
            <<"QUIT">>,
            <<"REHASH">>,
            <<"RESTART">>,
            <<"SERVICE">>,
            <<"SERVLIST">>,
            <<"SQUERY">>,
            <<"SQUIT">>,
            <<"STATS">>,
            <<"SUMMON">>,
            <<"TAGMSG">>,
            <<"TIME">>,
            <<"TOPIC">>,
            <<"TRACE">>,
            <<"USER">>,
            <<"USERHOST">>,
            <<"USERS">>,
            <<"VERSION">>,
            <<"WHO">>,
            <<"WHOIS">>,
            <<"WHOWAS">>,
            <<"WALLOPS">>,
            <<"NOTICE">>,
            <<"PASS">>,
            <<"KNOCK">>
        ]
    ).

%% Public lookups and replies used by query handlers. The implementations
%% live with the state they read.
find_nick(A0) -> ircd_state_client:find_nick(A0).

ready(A0) -> ircd_state_client:ready(A0).

user_modes(A0) -> ircd_state_client:user_modes(A0).

user_visible(A0, A1) -> ircd_state_client:user_visible(A0, A1).

visible_member(A0, A1, A2) -> ircd_state_channel:visible_member(A0, A1, A2).

wildcard_match(A0, A1) -> ircd_state_channel:wildcard_match(A0, A1).

remote_channel_flags(A0) -> ircd_state_link:remote_channel_flags(A0).

remote_user_visible_to_requester(A0, A1, A2) ->
    ircd_state_link:remote_user_visible_to_requester(A0, A1, A2).

numeric(A0, A1, A2, A3, A4) -> ircd_state_send:numeric(A0, A1, A2, A3, A4).
