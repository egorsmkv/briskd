-module(ircd_state).
-behaviour(gen_server).
-export([
    start_link/1,
    connect/1,
    command/3,
    registered/0,
    server_burst/0,
    authenticate_server_link/2,
    server_command/4,
    server_disconnect/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-record(client, {pid, host, nick = <<"*">>, user, real, channels = [], away, pass}).
-record(channel, {
    key,
    name,
    topic = <<>>,
    members = #{},
    flags = #{},
    lists = #{},
    invited = [],
    limit,
    password,
    creator,
    opless_since
}).
-record(activity, {pid, last}).
-record(whowas, {key, nick, user, host, real, server, time}).
-record(user_modes, {pid, modes = #{}}).
-record(remote_client, {key, peer, nick, user, host, token, modes = #{}, real}).
-record(remote_channel, {key, name, members = #{}, flags = #{}}).

%% @doc Start the process that owns IRC client and channel state.
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% @doc Register the calling session as a connected client using its peer host.
-spec connect(binary()) -> ok.
connect(Host) -> gen_server:call(?MODULE, {connect, Host}).

%% @doc Apply a parsed IRC command on behalf of the calling session.
%% Params contains the command's tokenized parameters and Bytes is the wire line size.
-spec command(binary(), [binary()], non_neg_integer()) -> ok | quit.
command(Command, Params, Bytes) -> gen_server:call(?MODULE, {command, Command, Params, Bytes}).

%% @doc Return whether the calling session has completed NICK and USER registration.
-spec registered() -> boolean().
registered() -> gen_server:call(?MODULE, registered).

%% @doc Return the RFC 2813 client and channel burst for an authenticated link.
-spec server_burst() -> [binary()].
server_burst() -> gen_server:call(?MODULE, server_burst).

%% @doc Apply a state message received from an authenticated peer.
-spec server_command(binary(), undefined | binary(), binary(), [binary()]) -> ok | {error, term()}.
server_command(Peer, Prefix, Command, Params) ->
    gen_server:call(?MODULE, {server_command, Peer, Prefix, Command, Params}).

%% @doc Drop imported client state when a server link closes.
-spec server_disconnect(binary()) -> ok.
server_disconnect(Peer) -> gen_server:call(?MODULE, {server_disconnect, Peer}).

%% @doc Check an inbound server's name and shared password against configured peers.
-spec authenticate_server_link(binary(), binary()) -> boolean().
authenticate_server_link(Name, Password) ->
    Links = persistent_term:get({?MODULE, server_links}, []),
    lists:any(
        fun(#{name := Expected, password := Secret}) ->
            ircd_wire:fold(Name) =:= ircd_wire:fold(Expected) andalso Password =:= Secret
        end,
        Links
    ).

%% @doc Initialize Mnesia tables and start the state server with the server name.
-spec init(map()) -> {ok, binary()}.
init(#{name := Name} = Config) ->
    Started = calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}]),
    persistent_term:put({?MODULE, started}, Started),
    persistent_term:put({?MODULE, started_at}, erlang:monotonic_time(second)),
    persistent_term:put({?MODULE, command_stats}, #{}),
    persistent_term:put({?MODULE, connection_stats}, #{}),
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
    ok = mnesia:wait_for_tables(
        [client, channel, activity, whowas, user_modes, remote_client, remote_channel], 5000
    ),
    {atomic, ok} = mnesia:clear_table(client),
    reset_channels(),
    {atomic, ok} = mnesia:clear_table(activity),
    {atomic, ok} = mnesia:clear_table(user_modes),
    {atomic, ok} = mnesia:clear_table(remote_client),
    {atomic, ok} = mnesia:clear_table(remote_channel),
    erlang:send_after(1000, self(), reop_tick),
    {ok, Name}.

table(Table, Fields, Options) ->
    case mnesia:create_table(Table, [{attributes, Fields}, {disc_copies, [node()]} | Options]) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, Table}} ->
            ensure_table_shape(Table, Fields),
            ensure_disc_copy(Table)
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
    case mnesia:table_info(remote_channel, attributes) of
        Fields ->
            ok;
        OldFields ->
            {atomic, ok} = mnesia:transform_table(
                remote_channel,
                fun(Old) -> list_to_tuple(tuple_to_list(Old) ++ [#{}]) end,
                Fields
            ),
            logger:info("Migrated remote channel table from ~p", [OldFields])
    end;
ensure_table_shape(_, _) ->
    ok.

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

next_reop_time() ->
    Delay = persistent_term:get({?MODULE, reop_delay}, 30),
    erlang:system_time(second) + Delay + rand:uniform(Delay).

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
    case erlang:system_time(second) >= ReopAt of
        false ->
            ok;
        true ->
            Pids = maps:keys(Members),
            Pid = lists:nth(rand:uniform(length(Pids)), Pids),
            Nick =
                case mnesia:dirty_read(client, Pid) of
                    [#client{nick = CurrentNick}] -> CurrentNick;
                    [] -> <<"*">>
                end,
            NewMembers = Members#{Pid := lists:usort([operator | maps:get(Pid, Members)])},
            mnesia:dirty_write(Channel#channel{members = NewMembers, opless_since = undefined}),
            broadcast(Pids, Server, <<"MODE">>, [Channel#channel.name, <<"+o">>, Nick], none)
    end.

%% @doc Handle session registration, registration queries, and client commands.
handle_call({connect, Host}, {Pid, _}, Server) ->
    monitor(process, Pid),
    mnesia:dirty_write(#client{pid = Pid, host = Host}),
    touch_activity(Pid),
    put_connection_stats(Pid, #{}),
    mnesia:dirty_write(#user_modes{pid = Pid}),
    {reply, ok, Server};
handle_call(registered, {Pid, _}, Server) ->
    {reply, ready(client(Pid)), Server};
handle_call(server_burst, _, Server) ->
    {reply, server_burst_lines(Server), Server};
handle_call({server_command, Peer, Prefix, <<"NICK">>, Params}, _, Server) when
    is_binary(Prefix), length(Params) =:= 7
->
    case ircd_wire:fold(Prefix) =:= ircd_wire:fold(Peer) of
        true -> {reply, import_remote_nick(Peer, Params), Server};
        false -> {reply, {error, invalid_introduction_prefix}, Server}
    end;
handle_call({server_command, Peer, _Prefix, <<"NJOIN">>, [Name, Members]}, _, Server) ->
    {reply, import_remote_njoin(Peer, Name, Members), Server};
handle_call({server_command, Peer, Prefix, <<"JOIN">>, [Name | _]}, _, Server) when
    is_binary(Prefix)
->
    {reply, import_remote_join(Peer, Prefix, Name), Server};
handle_call({server_command, Peer, Prefix, <<"PART">>, [Name | _]}, _, Server) when
    is_binary(Prefix)
->
    {reply, remove_remote_channel_member(Peer, Prefix, Name), Server};
handle_call({server_command, Peer, Prefix, <<"TOPIC">>, [Name, Text]}, _, Server) when
    is_binary(Prefix)
->
    {reply, update_remote_topic(Peer, Prefix, Name, Text), Server};
handle_call({server_command, Peer, Prefix, <<"KICK">>, [Name, Nick | Rest]}, _, Server) when
    is_binary(Prefix)
->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    {reply, receive_remote_kick(Peer, Prefix, Name, Nick, Reason), Server};
handle_call({server_command, Peer, Prefix, <<"NICK">>, [Nick]}, _, Server) when
    is_binary(Prefix)
->
    {reply, rename_remote_nick(Peer, Prefix, Nick), Server};
handle_call({server_command, Peer, Prefix, <<"QUIT">>, _Params}, _, Server) when
    is_binary(Prefix)
->
    {reply, remove_remote_nick(Peer, Prefix), Server};
handle_call({server_command, Peer, Prefix, <<"AWAY">>, Params}, _, Server) when
    is_binary(Prefix)
->
    {reply, set_remote_away(Peer, Prefix, Params), Server};
handle_call({server_command, Peer, Prefix, <<"MODE">>, [Name, Modes | Args]}, _, Server) ->
    {reply, update_remote_modes(Peer, Prefix, Name, Modes, Args), Server};
handle_call({server_command, Peer, Prefix, Command, Params}, _, Server) when
    is_binary(Prefix), (Command =:= <<"PRIVMSG">> orelse Command =:= <<"NOTICE">>)
->
    {reply, receive_remote_message(Peer, Prefix, Command, Params), Server};
handle_call({server_command, _Peer, _Prefix, _Command, _Params}, _, Server) ->
    {reply, ok, Server};
handle_call({server_disconnect, Peer}, _, Server) ->
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(remote_client, Key) of
                [#remote_client{peer = Peer}] -> mnesia:dirty_delete(remote_client, Key);
                _ -> ok
            end
        end,
        mnesia:dirty_all_keys(remote_client)
    ),
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(remote_channel, Key) of
                [#remote_channel{members = Members} = Channel] ->
                    Remaining = maps:filter(
                        fun(_NickKey, {MemberPeer, _Roles}) -> MemberPeer =/= Peer end,
                        Members
                    ),
                    case map_size(Remaining) of
                        0 -> mnesia:dirty_delete(remote_channel, Key);
                        _ -> mnesia:dirty_write(Channel#remote_channel{members = Remaining})
                    end;
                _ ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(remote_channel)
    ),
    {reply, ok, Server};
handle_call({command, Command, Params, Bytes}, {Pid, _}, Server) ->
    count_command(Pid, Command, Bytes),
    Reply = dispatch(Command, Params, client(Pid), Server),
    case Reply of
        quit -> ok;
        _ -> touch_activity(Pid)
    end,
    {reply, Reply, Server}.

server_burst_lines(Server) ->
    ClientLines =
        lists:flatmap(
            fun(Pid) ->
                case mnesia:dirty_read(client, Pid) of
                    [Client] ->
                        case ready(Client) of
                            true -> client_burst_lines(Client, Server);
                            false -> []
                        end;
                    _ ->
                        []
                end
            end,
            mnesia:dirty_all_keys(client)
        ),
    ChannelLines =
        lists:flatmap(
            fun(Key) ->
                case mnesia:dirty_read(channel, Key) of
                    [Channel] -> channel_burst_lines(Channel, Server);
                    [] -> []
                end
            end,
            mnesia:dirty_all_keys(channel)
        ),
    ClientLines ++ ChannelLines.

client_burst_lines(
    #client{nick = Nick, user = User, host = Host, real = Real, pid = Pid}, Server
) ->
    Modes = user_mode_string(user_modes(Pid)),
    [
        iolist_to_binary(
            ircd_wire:line(
                Server,
                <<"NICK">>,
                [Nick, <<"0">>, User, Host, <<"1">>, Modes],
                Real
            )
        )
    ].

channel_burst_lines(
    #channel{
        name = Name,
        members = Members,
        flags = Flags,
        lists = Lists,
        creator = Creator,
        password = Password,
        limit = Limit,
        topic = Topic
    },
    Server
) ->
    LiveMembers =
        [
            {Pid, Client, Roles}
         || {Pid, Roles} <- maps:to_list(Members),
            [Client] <- [mnesia:dirty_read(client, Pid)],
            ready(Client)
        ],
    NjoinLines =
        njoin_lines(
            Name,
            [njoin_member(Client, Roles) || {_Pid, Client, Roles} <- LiveMembers],
            Server
        ),
    CreatorLines =
        case lists:keyfind(Creator, 1, LiveMembers) of
            {Creator, CreatorClient, _} ->
                [
                    ircd_wire:line(
                        Server,
                        <<"MODE">>,
                        [Name, <<"+O">>, CreatorClient#client.nick],
                        none
                    )
                ];
            false ->
                []
        end,
    TopicLines =
        case Topic of
            <<>> -> [];
            _ -> [ircd_wire:line(Server, <<"TOPIC">>, [Name], Topic)]
        end,
    NjoinLines ++ channel_mode_burst(Name, Flags, Password, Limit, Lists, Server) ++
        CreatorLines ++ TopicLines.

njoin_member(#client{nick = Nick}, Roles) ->
    case
        {lists:member(creator, Roles), lists:member(operator, Roles), lists:member(voice, Roles)}
    of
        {true, _, _} -> <<"@@", Nick/binary>>;
        {false, true, _} -> <<$@, Nick/binary>>;
        {false, false, true} -> <<$+, Nick/binary>>;
        _ -> Nick
    end.

njoin_lines(_Name, [], _Server) ->
    [];
njoin_lines(Name, Members, Server) ->
    PrefixSize = byte_size(Server) + byte_size(Name) + 11,
    MaxMembers = max(1, 510 - PrefixSize),
    Batches = member_batches(Members, MaxMembers, [], 0, []),
    [ircd_wire:line(Server, <<"NJOIN">>, [Name], lists:join(<<$,>>, Batch)) || Batch <- Batches].

member_batches([], _Max, [], _Size, Batches) ->
    lists:reverse(Batches);
member_batches([], _Max, Current, _Size, Batches) ->
    lists:reverse([lists:reverse(Current) | Batches]);
member_batches([Member | Rest], Max, Current, Size, Batches) ->
    AddedSize =
        byte_size(Member) +
            case Current of
                [] -> 0;
                _ -> 1
            end,
    case Size + AddedSize =< Max of
        true ->
            member_batches(Rest, Max, [Member | Current], Size + AddedSize, Batches);
        false when Current =:= [] ->
            member_batches(Rest, Max, [Member], byte_size(Member), Batches);
        false ->
            member_batches(
                [Member | Rest], Max, [], 0, [lists:reverse(Current) | Batches]
            )
    end.

channel_mode_burst(Name, Flags, Password, Limit, Lists, Server) ->
    KeyMode =
        case Password of
            undefined -> [];
            _ -> [$k]
        end,
    LimitMode =
        case Limit of
            undefined -> [];
            _ -> [$l]
        end,
    Modes = lists:sort(maps:keys(Flags)) ++ KeyMode ++ LimitMode,
    Args =
        (case Password of
            undefined -> [];
            _ -> [Password]
        end) ++
            (case Limit of
                undefined -> [];
                _ -> [integer_to_binary(Limit)]
            end),
    FlagLines =
        case Modes of
            [] ->
                [];
            _ ->
                [
                    ircd_wire:line(
                        Server, <<"MODE">>, [Name, list_to_binary([$+ | Modes]) | Args], none
                    )
                ]
        end,
    AccessLines =
        lists:flatmap(
            fun({Type, Mode}) ->
                [
                    ircd_wire:line(Server, <<"MODE">>, [Name, <<$+, Mode>>, Mask], none)
                 || Mask <- maps:get(Type, Lists, [])
                ]
            end,
            [{ban, $b}, {exception, $e}, {invite, $I}]
        ),
    FlagLines ++ AccessLines.

%% @doc Ignore unsupported asynchronous state messages.
handle_cast(_, State) -> {noreply, State}.

%% @doc Remove client state after its session process exits.
handle_info({'DOWN', _, process, Pid, _}, State) ->
    case mnesia:dirty_read(client, Pid) of
        [Client] -> disconnect(Client, <<"Connection closed">>, State);
        [] -> ok
    end,
    {noreply, State};
handle_info(reop_tick, Server) ->
    reop_channels(Server),
    erlang:send_after(1000, self(), reop_tick),
    {noreply, Server};
handle_info(_, State) ->
    {noreply, State}.

%% Retrieve the Mnesia record associated with a live session process.
client(Pid) ->
    [Client] = mnesia:dirty_read(client, Pid),
    Client.

ready(#client{nick = Nick, user = User, pass = Pass}) ->
    HasIdentity = Nick =/= <<"*">> andalso User =/= undefined,
    Password = persistent_term:get({?MODULE, client_password}, null),
    Authenticated = Password =:= null orelse Pass =:= true,
    HasIdentity andalso Authenticated.

%% Route commands accepted before registration and enforce registration for the rest.
dispatch(<<"QUIT">>, Params, Client, Server) ->
    Reason =
        case Params of
            [Text | _] -> Text;
            [] -> <<"Client quit">>
        end,
    disconnect(Client, Reason, Server),
    quit;
dispatch(<<"PASS">>, Params, Client, Server) ->
    pass(Params, Client, Server);
dispatch(<<"PING">>, [Token | _], Client, Server) ->
    send(Client#client.pid, Server, <<"PONG">>, [Server], Token);
dispatch(<<"PING">>, [], Client, Server) ->
    numeric(Client, Server, <<"409">>, [], <<"No origin specified">>);
dispatch(<<"PONG">>, _, _, _) ->
    ok;
dispatch(<<"CAP">>, [<<"LS">> | _], Client, Server) ->
    send(Client#client.pid, Server, <<"CAP">>, [Client#client.nick, <<"LS">>], <<>>);
dispatch(<<"NICK">>, [Nick | _], Client, Server) ->
    case
        {
            ircd_wire:nickname(Nick),
            ircd_wire:fold(Nick),
            find_nick(Nick),
            remote_nick_exists(Nick)
        }
    of
        {_, <<"anonymous">>, _, _} ->
            numeric(Client, Server, <<"432">>, [Nick], <<"Erroneous nickname">>);
        {false, _, _, _} ->
            numeric(Client, Server, <<"432">>, [Nick], <<"Erroneous nickname">>);
        {true, _, #client{pid = Pid}, _} when Pid =/= Client#client.pid ->
            numeric(Client, Server, <<"433">>, [Nick], <<"Nickname is already in use">>);
        {true, _, _, true} ->
            numeric(Client, Server, <<"433">>, [Nick], <<"Nickname is already in use">>);
        {true, _, _, false} ->
            case ready(Client) of
                true ->
                    broadcast(
                        nick_recipients(Client),
                        prefix(Client),
                        <<"NICK">>,
                        [],
                        Nick
                    ),
                    propagate_nick_change(Client, Nick);
                false ->
                    ok
            end,
            save_identity(Client, Client#client{nick = Nick}, Server)
    end;
dispatch(<<"NICK">>, [], Client, Server) ->
    numeric(Client, Server, <<"431">>, [], <<"No nickname given">>);
dispatch(<<"USER">>, [User, Mode, _, Real], #client{user = undefined} = Client, Server) ->
    case
        {
            re:run(User, <<"^[A-Za-z0-9_.-]{1,32}$">>, [{capture, none}, dollar_endonly]),
            initial_user_modes(Mode)
        }
    of
        {match, {ok, Modes}} ->
            mnesia:dirty_write(#user_modes{pid = Client#client.pid, modes = Modes}),
            save_identity(Client, Client#client{user = User, real = Real}, Server);
        {nomatch, _} ->
            numeric(Client, Server, <<"461">>, [<<"USER">>], <<"Invalid username">>);
        {_, error} ->
            numeric(Client, Server, <<"461">>, [<<"USER">>], <<"Invalid user mode mask">>)
    end;
dispatch(<<"USER">>, _, Client, Server) ->
    case Client#client.user of
        undefined -> numeric(Client, Server, <<"461">>, [<<"USER">>], <<"Not enough parameters">>);
        _ -> numeric(Client, Server, <<"462">>, [], <<"You may not reregister">>)
    end;
dispatch(Command, Params, Client, Server) ->
    case ready(Client) of
        true -> registered_command(Command, Params, Client, Server);
        false -> numeric(Client, Server, <<"451">>, [], <<"You have not registered">>)
    end.

%% Find a registered nickname using the RFC1459 case-folding rules.
find_nick(Nick) ->
    Key = ircd_wire:fold(Nick),
    Matches = [
        Client
     || Pid <- mnesia:dirty_all_keys(client),
        [Client] <- [mnesia:dirty_read(client, Pid)],
        Client#client.nick =/= <<"*">>,
        ircd_wire:fold(Client#client.nick) =:= Key
    ],
    case Matches of
        [Client] -> Client;
        [] -> undefined
    end.

remote_nick_exists(Nick) ->
    mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) =/= [].

import_remote_nick(
    Peer,
    [Nick, Hop, User, Host, Token, ModeString, Real]
) ->
    Key = ircd_wire:fold(Nick),
    case
        {
            ircd_wire:nickname(Nick),
            Key =/= <<"anonymous">>,
            valid_decimal(Hop),
            valid_decimal(Token),
            re:run(User, <<"^[A-Za-z0-9_.-]{1,32}$">>, [{capture, none}, dollar_endonly]),
            valid_server_host(Host),
            server_user_modes(ModeString),
            find_nick(Nick),
            mnesia:dirty_read(remote_client, Key)
        }
    of
        {true, true, true, true, match, true, {ok, Modes}, undefined, []} ->
            mnesia:dirty_write(
                #remote_client{
                    key = Key,
                    peer = Peer,
                    nick = Nick,
                    user = User,
                    host = Host,
                    token = Token,
                    modes = Modes,
                    real = Real
                }
            ),
            ok;
        {true, true, true, true, match, true, {ok, _Modes}, undefined, [
            #remote_client{peer = Peer}
        ]} ->
            ok;
        {false, _, _, _, _, _, _, _, _} ->
            {error, invalid_nickname};
        {_, false, _, _, _, _, _, _, _} ->
            {error, reserved_nickname};
        {_, _, false, _, _, _, _, _, _} ->
            {error, invalid_hopcount};
        {_, _, _, false, _, _, _, _, _} ->
            {error, invalid_server_token};
        {_, _, _, _, nomatch, _, _, _, _} ->
            {error, invalid_username};
        {_, _, _, _, _, false, _, _, _} ->
            {error, invalid_hostname};
        {_, _, _, _, _, _, error, _, _} ->
            {error, invalid_user_modes};
        {_, _, _, _, _, _, _, #client{}, _} ->
            {error, nickname_collision};
        {_, _, _, _, _, _, _, _, [_]} ->
            {error, nickname_collision};
        _ ->
            {error, invalid_nick_message}
    end;
import_remote_nick(_, _) ->
    {error, invalid_nick_message}.

rename_remote_nick(Peer, Prefix, Nick) ->
    NewKey = ircd_wire:fold(Nick),
    case remote_source(Peer, Prefix) of
        {ok, #remote_client{key = OldKey} = Remote} ->
            case
                {
                    ircd_wire:nickname(Nick),
                    NewKey =/= <<"anonymous">>,
                    find_nick(Nick),
                    mnesia:dirty_read(remote_client, NewKey)
                }
            of
                {true, true, undefined, []} ->
                    mnesia:dirty_delete(remote_client, OldKey),
                    mnesia:dirty_write(Remote#remote_client{key = NewKey, nick = Nick}),
                    rename_remote_memberships(Peer, OldKey, NewKey),
                    ok;
                {true, true, undefined, [#remote_client{key = OldKey, peer = Peer}]} ->
                    mnesia:dirty_write(Remote#remote_client{nick = Nick}),
                    ok;
                {true, true, undefined, [#remote_client{peer = Peer}]} ->
                    {error, nickname_collision};
                {false, _, _, _} ->
                    {error, invalid_nickname};
                {_, false, _, _} ->
                    {error, reserved_nickname};
                _ ->
                    {error, nickname_collision}
            end;
        _ ->
            {error, unknown_remote_nick}
    end.

remove_remote_nick(Peer, Prefix) ->
    case remote_source(Peer, Prefix) of
        {ok, #remote_client{key = Key}} ->
            mnesia:dirty_delete(remote_client, Key),
            remove_remote_memberships(Peer, Key),
            ok;
        error ->
            {error, unknown_remote_nick}
    end.

set_remote_away(Peer, Prefix, Params) ->
    case remote_source(Peer, Prefix) of
        {ok, Remote} ->
            Modes =
                case Params of
                    [] -> maps:remove($a, Remote#remote_client.modes);
                    [_Message | _] -> (Remote#remote_client.modes)#{$a => true}
                end,
            mnesia:dirty_write(Remote#remote_client{modes = Modes}),
            ok;
        error ->
            {error, unknown_remote_nick}
    end.

remote_source(Peer, Prefix) ->
    case binary:split(Prefix, <<"!">>) of
        [Nick, _UserHost] ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [#remote_client{peer = Peer, nick = Nick, user = User, host = Host} = Remote] ->
                    case Prefix =:= <<Nick/binary, "!", User/binary, "@", Host/binary>> of
                        true -> {ok, Remote};
                        false -> error
                    end;
                _ ->
                    error
            end;
        _ ->
            error
    end.

update_remote_topic(Peer, Prefix, Name, Topic) ->
    Key = ircd_wire:fold(Name),
    case {ircd_wire:channel(Name), ircd_wire:fold(Prefix) =:= ircd_wire:fold(Peer)} of
        {false, _} ->
            {error, invalid_channel};
        {true, true} ->
            store_remote_topic(Prefix, Key, Name, Topic);
        {true, false} ->
            case {remote_source(Peer, Prefix), mnesia:dirty_read(remote_channel, Key)} of
                {{ok, #remote_client{key = NickKey}}, [
                    #remote_channel{members = Members, flags = Flags}
                ]} ->
                    case maps:find(NickKey, Members) of
                        {ok, {Peer, Roles}} ->
                            Restricted = maps:is_key($t, Flags) orelse local_channel_mode(Key, $t),
                            case Restricted andalso not lists:member(operator, Roles) of
                                true -> {error, remote_topic_requires_operator};
                                false -> store_remote_topic(Prefix, Key, Name, Topic)
                            end;
                        _ ->
                            {error, remote_user_not_on_channel}
                    end;
                {{error, _}, _} ->
                    {error, unknown_remote_source};
                {_, []} ->
                    {error, unknown_remote_channel}
            end
    end.

store_remote_topic(Prefix, Key, Name, Topic) ->
    Remote =
        case mnesia:dirty_read(remote_channel, Key) of
            [RemoteRecord] -> RemoteRecord;
            [] -> #remote_channel{key = Key, name = Name}
        end,
    Flags = (Remote#remote_channel.flags)#{topic => Topic},
    mnesia:dirty_write(Remote#remote_channel{flags = Flags}),
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Canonical, members = Members, flags = ChannelFlags} = Channel] ->
            mnesia:dirty_write(Channel#channel{topic = Topic}),
            EventPrefix =
                case
                    maps:is_key($a, ChannelFlags) orelse
                        maps:is_key($a, Remote#remote_channel.flags)
                of
                    true -> <<"anonymous!anonymous@anonymous.">>;
                    false -> Prefix
                end,
            broadcast(maps:keys(Members), EventPrefix, <<"TOPIC">>, [Canonical], Topic);
        [] ->
            ok
    end,
    ok.

local_channel_mode(Key, Mode) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{flags = Flags}] -> maps:is_key(Mode, Flags);
        [] -> false
    end.

rename_remote_memberships(Peer, OldKey, NewKey) ->
    lists:foreach(
        fun(ChannelKey) ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{members = Members} = Channel] ->
                    case maps:take(OldKey, Members) of
                        {{Peer, Roles}, Remaining} ->
                            mnesia:dirty_write(
                                Channel#remote_channel{
                                    members = Remaining#{NewKey => {Peer, Roles}}
                                }
                            );
                        _ ->
                            ok
                    end;
                _ ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(remote_channel)
    ).

remove_remote_memberships(Peer, NickKey) ->
    lists:foreach(
        fun(ChannelKey) ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{members = Members} = Channel] ->
                    case maps:find(NickKey, Members) of
                        {ok, {Peer, _Roles}} ->
                            Remaining = maps:remove(NickKey, Members),
                            case map_size(Remaining) of
                                0 -> mnesia:dirty_delete(remote_channel, ChannelKey);
                                _ -> mnesia:dirty_write(Channel#remote_channel{members = Remaining})
                            end;
                        _ ->
                            ok
                    end;
                _ ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(remote_channel)
    ).

import_remote_njoin(Peer, Name, Members) ->
    case ircd_wire:channel(Name) of
        false ->
            {error, invalid_channel};
        true ->
            case parse_remote_members(Peer, binary:split(Members, <<$,>>, [global]), []) of
                {ok, Parsed} when Parsed =/= [] ->
                    Key = ircd_wire:fold(Name),
                    Existing =
                        case mnesia:dirty_read(remote_channel, Key) of
                            [Channel] -> Channel;
                            [] -> #remote_channel{key = Key, name = Name}
                        end,
                    NewMembers = lists:foldl(
                        fun({NickKey, Roles}, Acc) -> Acc#{NickKey => {Peer, Roles}} end,
                        Existing#remote_channel.members,
                        Parsed
                    ),
                    mnesia:dirty_write(Existing#remote_channel{members = NewMembers}),
                    ok;
                {ok, []} ->
                    {error, empty_njoin};
                Error ->
                    Error
            end
    end.

import_remote_join(Peer, Prefix, Name) ->
    case {remote_source(Peer, Prefix), ircd_wire:channel(Name)} of
        {{ok, #remote_client{key = NickKey}}, true} ->
            Key = ircd_wire:fold(Name),
            Channel =
                case mnesia:dirty_read(remote_channel, Key) of
                    [Existing] -> Existing;
                    [] -> #remote_channel{key = Key, name = Name}
                end,
            Members = Channel#remote_channel.members,
            case maps:is_key(NickKey, Members) of
                true ->
                    ok;
                false ->
                    mnesia:dirty_write(
                        Channel#remote_channel{members = Members#{NickKey => {Peer, [member]}}}
                    ),
                    broadcast_remote_channel_event(Name, Prefix, <<"JOIN">>, none),
                    ok
            end;
        {error, _} ->
            {error, unknown_remote_source};
        {_, false} ->
            {error, invalid_channel}
    end.

remove_remote_channel_member(Peer, Prefix, Name) ->
    case {remote_source(Peer, Prefix), mnesia:dirty_read(remote_channel, ircd_wire:fold(Name))} of
        {{ok, #remote_client{key = NickKey}}, [#remote_channel{members = Members} = Channel]} ->
            case maps:find(NickKey, Members) of
                {ok, {Peer, _Roles}} ->
                    broadcast_remote_channel_event(Name, Prefix, <<"PART">>, none),
                    Remaining = maps:remove(NickKey, Members),
                    case map_size(Remaining) of
                        0 -> mnesia:dirty_delete(remote_channel, Channel#remote_channel.key);
                        _ -> mnesia:dirty_write(Channel#remote_channel{members = Remaining})
                    end,
                    ok;
                _ ->
                    {error, remote_user_not_on_channel}
            end;
        {{error, _}, _} ->
            {error, unknown_remote_source};
        {_, []} ->
            {error, unknown_remote_channel}
    end.

receive_remote_kick(Peer, Prefix, Name, Nick, Reason) ->
    Key = ircd_wire:fold(Name),
    case {remote_source(Peer, Prefix), mnesia:dirty_read(remote_channel, Key)} of
        {{ok, #remote_client{key = SourceKey}}, [#remote_channel{members = Members} = Channel]} ->
            case maps:find(SourceKey, Members) of
                {ok, {Peer, Roles}} ->
                    case lists:member(operator, Roles) orelse lists:member(creator, Roles) of
                        true -> apply_remote_kick(Peer, Prefix, Name, Nick, Reason, Channel);
                        false -> {error, remote_kick_requires_operator}
                    end;
                _ ->
                    {error, remote_kick_requires_operator}
            end;
        {{error, _}, _} ->
            {error, unknown_remote_source};
        {_, []} ->
            {error, unknown_remote_channel}
    end.

apply_remote_kick(Peer, Prefix, Name, Nick, Reason, RemoteChannel) ->
    Key = RemoteChannel#remote_channel.key,
    case find_nick(Nick) of
        #client{pid = TargetPid, nick = Actual} = Target ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{members = Members} = Channel] when is_map_key(TargetPid, Members) ->
                    broadcast_kick(Channel, Prefix, Actual, Reason),
                    Remaining = maps:remove(TargetPid, Members),
                    case map_size(Remaining) of
                        0 ->
                            case Channel#channel.name of
                                <<$!, _/binary>> ->
                                    mnesia:dirty_write(track_opless(Channel, Remaining));
                                _ ->
                                    mnesia:dirty_delete(channel, Key)
                            end;
                        _ ->
                            mnesia:dirty_write(track_opless(Channel, Remaining))
                    end,
                    mnesia:dirty_write(Target#client{
                        channels = lists:delete(Key, Target#client.channels)
                    }),
                    remove_remote_channel_member_record(
                        Peer, ircd_wire:fold(Actual), RemoteChannel
                    );
                _ ->
                    {error, remote_kick_target_not_on_channel}
            end;
        undefined ->
            TargetKey = ircd_wire:fold(Nick),
            case maps:find(TargetKey, RemoteChannel#remote_channel.members) of
                {ok, {_TargetPeer, _TargetRoles}} ->
                    case mnesia:dirty_read(remote_client, TargetKey) of
                        [#remote_client{nick = Actual}] ->
                            broadcast_kick_by_name(Name, Prefix, Actual, Reason),
                            remove_remote_channel_member_record(Peer, TargetKey, RemoteChannel);
                        [] ->
                            {error, unknown_remote_kick_target}
                    end;
                error ->
                    {error, remote_kick_target_not_on_channel}
            end
    end.

remove_remote_channel_member_record(_Peer, NickKey, #remote_channel{key = Key} = Channel) ->
    Members = maps:remove(NickKey, Channel#remote_channel.members),
    case map_size(Members) of
        0 -> mnesia:dirty_delete(remote_channel, Key);
        _ -> mnesia:dirty_write(Channel#remote_channel{members = Members})
    end,
    ok.

broadcast_kick(#channel{name = Name, members = Members, flags = Flags}, Prefix, Nick, Reason) ->
    EventPrefix =
        case maps:is_key($a, Flags) of
            true -> <<"anonymous!anonymous@anonymous.">>;
            false -> Prefix
        end,
    broadcast(maps:keys(Members), EventPrefix, <<"KICK">>, [Name, Nick], Reason).

broadcast_kick_by_name(Name, Prefix, Nick, Reason) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [Channel] -> broadcast_kick(Channel, Prefix, Nick, Reason);
        [] -> ok
    end.

broadcast_remote_channel_event(Name, Prefix, Command, Reason) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, flags = Flags}] ->
            EventPrefix =
                case maps:is_key($a, Flags) of
                    true -> <<"anonymous!anonymous@anonymous.">>;
                    false -> Prefix
                end,
            broadcast(maps:keys(Members), EventPrefix, Command, [Canonical], Reason);
        [] ->
            ok
    end.

parse_remote_members(_Peer, [], Acc) ->
    {ok, lists:reverse(Acc)};
parse_remote_members(Peer, [RawMember | Rest], Acc) ->
    {Roles, Nick} = remote_member(RawMember),
    Key = ircd_wire:fold(Nick),
    case {ircd_wire:nickname(Nick), mnesia:dirty_read(remote_client, Key)} of
        {true, [#remote_client{peer = Peer}]} ->
            parse_remote_members(Peer, Rest, [{Key, Roles} | Acc]);
        {true, [_]} ->
            {error, remote_member_from_other_peer};
        _ ->
            {error, unknown_remote_member}
    end.

remote_member(<<"@@", Nick/binary>>) -> {[creator, operator], Nick};
remote_member(<<$@, Nick/binary>>) -> {[operator], Nick};
remote_member(<<$+, Nick/binary>>) -> {[voice], Nick};
remote_member(Nick) -> {[member], Nick}.

update_remote_modes(Peer, Prefix, Name, ModeString, Args) ->
    case ircd_wire:channel(Name) of
        false -> update_remote_user_modes(Peer, Prefix, Name, ModeString);
        true -> update_remote_channel_modes(Peer, Prefix, Name, ModeString, Args)
    end.

update_remote_channel_modes(Peer, Prefix, Name, ModeString, Args) ->
    Key = ircd_wire:fold(Name),
    TrustedServer = ircd_wire:fold(Prefix) =:= ircd_wire:fold(Peer),
    Channel =
        case mnesia:dirty_read(remote_channel, Key) of
            [ExistingRecord] -> ExistingRecord;
            [] when TrustedServer -> #remote_channel{key = Key, name = Name};
            [] -> undefined
        end,
    case Channel of
        undefined ->
            {error, unknown_remote_channel};
        #remote_channel{members = Members} = ChannelRecord ->
            Authorized =
                case TrustedServer of
                    true ->
                        true;
                    false ->
                        case remote_source(Peer, Prefix) of
                            {ok, #remote_client{key = NickKey}} ->
                                case maps:find(NickKey, Members) of
                                    {ok, {Peer, Roles}} ->
                                        lists:member(operator, Roles) orelse
                                            lists:member(creator, Roles);
                                    _ ->
                                        false
                                end;
                            error ->
                                false
                        end
                end,
            case Authorized of
                false ->
                    {error, remote_mode_requires_operator};
                true ->
                    case
                        apply_remote_modes(
                            binary_to_list(ModeString), undefined, Args, ChannelRecord
                        )
                    of
                        {ok, Updated, []} ->
                            mnesia:dirty_write(Updated),
                            synchronize_local_channel(Updated),
                            case TrustedServer of
                                true -> ok;
                                false -> broadcast_remote_mode(Name, Prefix, ModeString, Args)
                            end;
                        {ok, _Updated, Remaining} ->
                            {error, {extra_mode_arguments, Remaining}};
                        Error ->
                            Error
                    end
            end
    end.

synchronize_local_channel(#remote_channel{key = Key, flags = RemoteFlags}) ->
    case mnesia:dirty_read(channel, Key) of
        [Channel] ->
            ModeKeys = [$a, $i, $m, $n, $p, $q, $r, $s, $t, $K],
            Flags = maps:with(ModeKeys, RemoteFlags),
            Lists = maps:with([ban, exception, invite], RemoteFlags),
            mnesia:dirty_write(Channel#channel{
                flags = Flags,
                password = maps:get(key, RemoteFlags, undefined),
                limit = maps:get(limit, RemoteFlags, undefined),
                lists = Lists
            });
        [] ->
            ok
    end.

apply_remote_modes([], _Action, Args, Channel) ->
    {ok, Channel, Args};
apply_remote_modes([$+ | Rest], _Action, Args, Channel) ->
    apply_remote_modes(Rest, add, Args, Channel);
apply_remote_modes([$- | Rest], _Action, Args, Channel) ->
    apply_remote_modes(Rest, remove, Args, Channel);
apply_remote_modes([Mode | Rest], Action, Args, #remote_channel{flags = Flags} = Channel) when
    Mode =:= $a;
    Mode =:= $i;
    Mode =:= $m;
    Mode =:= $n;
    Mode =:= $p;
    Mode =:= $s;
    Mode =:= $t;
    Mode =:= $r;
    Mode =:= $K;
    Mode =:= $q
->
    NewFlags =
        case {Mode, Action} of
            {$p, add} -> (maps:remove($s, Flags))#{$p => true};
            {$s, add} -> (maps:remove($p, Flags))#{$s => true};
            {_, add} -> Flags#{Mode => true};
            {_, remove} -> maps:remove(Mode, Flags)
        end,
    apply_remote_modes(Rest, Action, Args, Channel#remote_channel{flags = NewFlags});
apply_remote_modes([$k | Rest], Action, [Key | Args], #remote_channel{flags = Flags} = Channel) ->
    NewFlags =
        case Action of
            add -> Flags#{key => Key};
            remove -> maps:remove(key, Flags)
        end,
    apply_remote_modes(Rest, Action, Args, Channel#remote_channel{flags = NewFlags});
apply_remote_modes([$l | Rest], Action, Args, #remote_channel{flags = Flags} = Channel) ->
    case {Action, Args} of
        {add, [Value | Tail]} ->
            try binary_to_integer(Value) of
                Limit when Limit > 0 ->
                    apply_remote_modes(Rest, Action, Tail, Channel#remote_channel{
                        flags = Flags#{limit => Limit}
                    });
                _ ->
                    {error, invalid_channel_limit}
            catch
                error:badarg -> {error, invalid_channel_limit}
            end;
        {remove, _} ->
            apply_remote_modes(Rest, Action, Args, Channel#remote_channel{
                flags = maps:remove(limit, Flags)
            });
        _ ->
            {error, missing_channel_limit}
    end;
apply_remote_modes(
    [Mode | Rest], Action, [Mask | Args], #remote_channel{flags = Flags} = Channel
) when
    Mode =:= $b; Mode =:= $e; Mode =:= $I
->
    Type =
        case Mode of
            $b -> ban;
            $e -> exception;
            $I -> invite
        end,
    Existing = maps:get(Type, Flags, []),
    Updated =
        case Action of
            add -> lists:usort([Mask | Existing]);
            remove -> lists:delete(Mask, Existing)
        end,
    apply_remote_modes(Rest, Action, Args, Channel#remote_channel{flags = Flags#{Type => Updated}});
apply_remote_modes(
    [Mode | Rest], Action, [Nick | Args], #remote_channel{members = Members} = Channel
) when
    Mode =:= $o; Mode =:= $v; Mode =:= $O
->
    Key = ircd_wire:fold(Nick),
    Role =
        case Mode of
            $o -> operator;
            $v -> voice;
            $O -> creator
        end,
    case maps:find(Key, Members) of
        {ok, {Owner, Roles}} ->
            NewRoles =
                case Action of
                    add -> lists:usort([Role | Roles]);
                    remove -> lists:delete(Role, Roles)
                end,
            apply_remote_modes(Rest, Action, Args, Channel#remote_channel{
                members = Members#{Key := {Owner, NewRoles}}
            });
        error ->
            {error, unknown_remote_mode_target}
    end;
apply_remote_modes([Mode | _], _Action, [], _Channel) when
    Mode =:= $k; Mode =:= $o; Mode =:= $v; Mode =:= $O; Mode =:= $b; Mode =:= $e; Mode =:= $I
->
    {error, missing_mode_argument};
apply_remote_modes([Mode | _], _Action, _Args, _Channel) ->
    {error, {unsupported_channel_mode, Mode}}.

broadcast_remote_mode(Name, Prefix, Modes, Args) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, flags = Flags}] ->
            EventPrefix =
                case maps:is_key($a, Flags) of
                    true -> <<"anonymous!anonymous@anonymous.">>;
                    false -> Prefix
                end,
            broadcast(
                maps:keys(Members), EventPrefix, <<"MODE">>, [Canonical, Modes | Args], none
            );
        [] ->
            ok
    end.

update_remote_user_modes(Peer, Prefix, Nick, ModeString) ->
    Key = ircd_wire:fold(Nick),
    case remote_source(Peer, Prefix) of
        {ok, #remote_client{key = Key, modes = Modes} = Remote} ->
            Updated = apply_remote_user_modes(binary_to_list(ModeString), undefined, Modes),
            mnesia:dirty_write(Remote#remote_client{modes = Updated}),
            broadcast(
                remote_user_local_recipients(Key), Prefix, <<"MODE">>, [Nick, ModeString], none
            ),
            ok;
        {ok, _OtherRemote} ->
            {error, remote_user_mode_source_mismatch};
        error ->
            {error, unknown_remote_source}
    end.

apply_remote_user_modes([], _Action, Modes) ->
    Modes;
apply_remote_user_modes([$+ | Rest], _Action, Modes) ->
    apply_remote_user_modes(Rest, add, Modes);
apply_remote_user_modes([$- | Rest], _Action, Modes) ->
    apply_remote_user_modes(Rest, remove, Modes);
apply_remote_user_modes([Mode | Rest], Action, Modes) when
    Mode =:= $a; Mode =:= $i; Mode =:= $o; Mode =:= $w
->
    NewModes =
        case Action of
            add -> Modes#{Mode => true};
            remove -> maps:remove(Mode, Modes);
            undefined -> Modes
        end,
    apply_remote_user_modes(Rest, Action, NewModes);
apply_remote_user_modes([_ | Rest], Action, Modes) ->
    apply_remote_user_modes(Rest, Action, Modes).

valid_decimal(Value) ->
    try binary_to_integer(Value) of
        Number -> Number >= 0
    catch
        error:badarg -> false
    end.

valid_server_host(Host) ->
    byte_size(Host) > 0 andalso byte_size(Host) =< 253 andalso
        binary:match(Host, [<<0>>, <<" ">>, <<"\r">>, <<"\n">>]) =:= nomatch.

server_user_modes(<<$+, Modes/binary>>) ->
    case lists:all(fun(Mode) -> lists:member(Mode, "aiow") end, binary_to_list(Modes)) of
        true -> {ok, maps:from_list([{Mode, true} || Mode <- binary_to_list(Modes)])};
        false -> error
    end;
server_user_modes(_) ->
    error.

%% Persist nickname or USER changes and send the registration welcome once ready.
save_identity(Old, New, Server) ->
    Current = client(Old#client.pid),
    Updated = New#client{
        nick =
            case New#client.nick of
                <<"*">> -> Current#client.nick;
                Value -> Value
            end,
        user =
            case New#client.user of
                undefined -> Current#client.user;
                Value -> Value
            end,
        real =
            case New#client.real of
                undefined -> Current#client.real;
                Value -> Value
            end,
        away =
            case New#client.away of
                undefined -> Current#client.away;
                Value -> Value
            end,
        channels = Current#client.channels
    },
    case ready(Current) andalso Current#client.nick =/= Updated#client.nick of
        true -> save_whowas(Current, Server);
        false -> ok
    end,
    mnesia:dirty_write(Updated),
    case not ready(Old) andalso ready(Updated) of
        true ->
            propagate_introduction(Updated, Server),
            numeric(Updated, Server, <<"001">>, [], [<<"Welcome to IRC ">>, prefix(New)]),
            numeric(
                Updated,
                Server,
                <<"002">>,
                [],
                [<<"Your host is ">>, Server, <<", running version 0.1.0">>]
            ),
            numeric(
                Updated,
                Server,
                <<"003">>,
                [],
                [
                    <<"This server was created ">>,
                    persistent_term:get({?MODULE, started})
                ]
            ),
            numeric(
                Updated,
                Server,
                <<"004">>,
                [Server, <<"0.1.0">>, <<"iow">>, <<"abeIimnpsqrKltkov">>],
                none
            ),
            motd([], Updated, Server);
        false ->
            ok
    end.

pass(Params, Client, Server) ->
    case identity_ready(Client) of
        true ->
            numeric(Client, Server, <<"462">>, [], <<"You may not reregister">>);
        false ->
            pass_unregistered(Params, Client, Server)
    end.

pass_unregistered([], Client, Server) ->
    numeric(Client, Server, <<"461">>, [<<"PASS">>], <<"Not enough parameters">>);
pass_unregistered(_, #client{pass = Pass} = Client, Server) when Pass =/= undefined ->
    numeric(Client, Server, <<"462">>, [], <<"You may not reregister">>);
pass_unregistered([Given | _], Client, Server) ->
    Expected = persistent_term:get({?MODULE, client_password}, null),
    case Expected =:= null orelse Given =:= Expected of
        true ->
            save_identity(Client, Client#client{pass = true}, Server);
        false ->
            mnesia:dirty_write(Client#client{pass = false}),
            numeric(Client, Server, <<"464">>, [], <<"Password incorrect">>)
    end.

identity_ready(#client{nick = Nick, user = User}) ->
    Nick =/= <<"*">> andalso User =/= undefined.

initial_user_modes(Mode) ->
    try binary_to_integer(Mode) of
        Mask when Mask >= 0 ->
            Modes0 = #{},
            Modes1 =
                case Mask band 4 of
                    0 -> Modes0;
                    _ -> Modes0#{$w => true}
                end,
            Modes2 =
                case Mask band 8 of
                    0 -> Modes1;
                    _ -> Modes1#{$i => true}
                end,
            {ok, Modes2};
        _ ->
            error
    catch
        error:badarg -> error
    end.

%% Implement commands that require a fully registered client.
registered_command(<<"AWAY">>, [], #client{} = Client, Server) ->
    case Client#client.away of
        undefined ->
            numeric(Client, Server, <<"305">>, [], <<"You are no longer marked as being away">>);
        _ ->
            mnesia:dirty_write(Client#client{away = undefined}),
            propagate_away(Client, none),
            numeric(Client, Server, <<"305">>, [], <<"You are no longer marked as being away">>)
    end,
    ok;
registered_command(<<"AWAY">>, [Message | _], #client{} = Client, Server) ->
    mnesia:dirty_write(Client#client{away = Message}),
    propagate_away(Client, Message),
    numeric(Client, Server, <<"306">>, [], <<"You have been marked as being away">>),
    ok;
registered_command(<<"JOIN">>, [<<"0">> | _], Client, _) ->
    lists:foreach(
        fun(Key) -> leave(Key, Client, <<"PART">>, none, true) end, Client#client.channels
    );
registered_command(<<"JOIN">>, [Names | Rest], Client, Server) ->
    Keys =
        case Rest of
            [Passwords | _] -> binary:split(Passwords, <<",">>, [global]);
            [] -> []
        end,
    join_channels(split(Names), Keys, Client#client.pid, Server);
registered_command(<<"PART">>, [Names | Rest], Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    lists:foreach(
        fun(Name) ->
            Key = ircd_wire:fold(Name),
            Current = client(Client#client.pid),
            case {mnesia:dirty_read(channel, Key), lists:member(Key, Current#client.channels)} of
                {[], _} ->
                    numeric(Current, Server, <<"403">>, [Name], <<"No such channel">>);
                {_, false} ->
                    numeric(Current, Server, <<"442">>, [Name], <<"You're not on that channel">>);
                {_, true} ->
                    leave(Key, Current, <<"PART">>, Reason, true)
            end
        end,
        split(Names)
    );
registered_command(<<"KICK">>, [Name, Nicks | Rest], Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> Client#client.nick
        end,
    Channels = split(Name),
    Targets = split(Nicks),
    case {Channels, Targets} of
        {[Channel], [_ | _]} ->
            kick(Channel, Targets, Reason, Client, Server);
        {ChannelList, TargetList} when
            length(ChannelList) =:= length(TargetList),
            length(ChannelList) > 1
        ->
            lists:foreach(
                fun({Channel, Target}) ->
                    kick(Channel, [Target], Reason, Client, Server)
                end,
                lists:zip(ChannelList, TargetList)
            );
        _ ->
            numeric(Client, Server, <<"461">>, [<<"KICK">>], <<"Invalid channel/user list">>)
    end;
registered_command(<<"KICK">>, _, Client, Server) ->
    numeric(Client, Server, <<"461">>, [<<"KICK">>], <<"Not enough parameters">>);
registered_command(Command, Params, Client, Server) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>
->
    deliver(Command, Params, Client, Server);
registered_command(<<"KNOCK">>, [Name | Rest], Client, Server) ->
    knock(Name, Rest, Client, Server);
registered_command(<<"KNOCK">>, [], Client, Server) ->
    numeric(Client, Server, <<"461">>, [<<"KNOCK">>], <<"Not enough parameters">>);
registered_command(<<"INVITE">>, [Nick, Name | _], Client, Server) ->
    invite(Nick, Name, Client, Server);
registered_command(<<"INVITE">>, _, Client, Server) ->
    numeric(Client, Server, <<"461">>, [<<"INVITE">>], <<"Not enough parameters">>);
registered_command(<<"MODE">>, [Target | Rest], Client, Server) ->
    mode_command(Target, Rest, Client, Server);
registered_command(<<"OPER">>, [Name, Password | _], Client, Server) ->
    oper(Name, Password, Client, Server);
registered_command(<<"OPER">>, _, Client, Server) ->
    numeric(Client, Server, <<"461">>, [<<"OPER">>], <<"Not enough parameters">>);
registered_command(<<"KILL">>, Params, Client, Server) ->
    kill(Params, Client, Server);
registered_command(<<"WALLOPS">>, _, Client, Server) ->
    numeric(
        Client,
        Server,
        <<"481">>,
        [],
        <<"Permission Denied- WALLOPS is server only">>
    );
registered_command(<<"REHASH">>, _, Client, Server) ->
    rehash(Client, Server);
registered_command(<<"SUMMON">>, _, Client, Server) ->
    numeric(Client, Server, <<"445">>, [], <<"SUMMON has been disabled">>);
registered_command(<<"USERS">>, Params, Client, Server) ->
    users_disabled(Params, Client, Server);
registered_command(<<"TOPIC">>, [Name | Rest], Client, Server) ->
    topic(Name, Rest, Client, Server);
registered_command(<<"NAMES">>, Params, Client, Server) ->
    case Params of
        [Names | _] ->
            lists:foreach(fun(Name) -> names(Name, Client, Server) end, split(Names));
        [] ->
            lists:foreach(
                fun(Key) -> names_listing(Key, Client, Server) end,
                mnesia:dirty_all_keys(channel)
            ),
            LocalKeys = mnesia:dirty_all_keys(channel),
            lists:foreach(
                fun(Key) ->
                    case lists:member(Key, LocalKeys) of
                        true -> ok;
                        false -> remote_names_listing(Key, Client, Server)
                    end
                end,
                mnesia:dirty_all_keys(remote_channel)
            ),
            names_unattached(Client, Server),
            numeric(Client, Server, <<"366">>, [<<"*">>], <<"End of NAMES list">>)
    end;
registered_command(<<"LIST">>, Params, Client, Server) ->
    Keys =
        case Params of
            [Names | _] -> [ircd_wire:fold(Name) || Name <- split(Names)];
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
                            numeric(
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
    numeric(Client, Server, <<"323">>, [], <<"End of LIST">>);
registered_command(<<"TIME">>, Params, Client, Server) ->
    case query_local_server(Params, Server) of
        true ->
            numeric(
                Client,
                Server,
                <<"391">>,
                [Server],
                calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}])
            );
        {false, Target} ->
            numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end;
registered_command(<<"TRACE">>, Params, Client, Server) ->
    trace(Params, Client, Server);
registered_command(<<"STATS">>, Params, Client, Server) ->
    stats(Params, Client, Server);
registered_command(<<"SERVLIST">>, Params, Client, Server) ->
    {Mask, Type} =
        case Params of
            [GivenMask, GivenType | _] -> {GivenMask, GivenType};
            [GivenMask] -> {GivenMask, <<"*">>};
            [] -> {<<"*">>, <<"*">>}
        end,
    numeric(Client, Server, <<"235">>, [Mask, Type], <<"End of service listing">>);
registered_command(<<"SQUERY">>, Params, Client, Server) ->
    squery(Params, Client, Server);
registered_command(<<"VERSION">>, Params, Client, Server) ->
    case query_local_server(Params, Server) of
        true ->
            numeric(Client, Server, <<"351">>, [<<"0.1.0">>, Server], <<"Erlang/OTP IRC server">>);
        {false, Target} ->
            numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end;
registered_command(<<"INFO">>, Params, Client, Server) ->
    info(Params, Client, Server);
registered_command(<<"ADMIN">>, Params, Client, Server) ->
    admin(Params, Client, Server);
registered_command(<<"LINKS">>, Params, Client, Server) ->
    links(Params, Client, Server);
registered_command(<<"LUSERS">>, Params, Client, Server) ->
    lusers(Params, Client, Server);
registered_command(<<"ISON">>, [], Client, Server) ->
    numeric(Client, Server, <<"461">>, [<<"ISON">>], <<"Not enough parameters">>);
registered_command(<<"ISON">>, [<<>> | _], Client, Server) ->
    numeric(Client, Server, <<"461">>, [<<"ISON">>], <<"Not enough parameters">>);
registered_command(<<"ISON">>, Nicks, Client, Server) ->
    Existing = [
        Actual
     || Nick <- Nicks,
        Actual <- [ison_nick(Nick)],
        Actual =/= undefined
    ],
    numeric(Client, Server, <<"303">>, [], lists:join(<<" ">>, Existing));
registered_command(<<"USERHOST">>, [], Client, Server) ->
    numeric(Client, Server, <<"461">>, [<<"USERHOST">>], <<"Not enough parameters">>);
registered_command(<<"USERHOST">>, Nicks, Client, Server) ->
    userhost(Nicks, Client, Server);
registered_command(<<"WHO">>, Params, Client, Server) ->
    who_command(Params, Client, Server);
registered_command(<<"WHOIS">>, [_ | _] = Args, Client, Server) ->
    case Args of
        [NickMasks] ->
            lists:foreach(fun(Nick) -> whois(Nick, Client, Server) end, split(NickMasks));
        [Target, NickMasks | _] ->
            case query_local_server([Target], Server) of
                true ->
                    lists:foreach(
                        fun(Nick) -> whois(Nick, Client, Server) end,
                        split(NickMasks)
                    );
                {false, Unknown} ->
                    numeric(Client, Server, <<"402">>, [Unknown], <<"No such server">>)
            end
    end;
registered_command(<<"WHOWAS">>, [], Client, Server) ->
    numeric(Client, Server, <<"431">>, [], <<"No nickname given">>);
registered_command(<<"WHOWAS">>, [NickMasks | Rest], Client, Server) ->
    {Count, Target} = whowas_options(Rest),
    case
        query_local_server(
            case Target of
                undefined -> [];
                _ -> [Target]
            end,
            Server
        )
    of
        {false, Unknown} ->
            numeric(Client, Server, <<"402">>, [Unknown], <<"No such server">>);
        true ->
            Nicks = split(NickMasks),
            lists:foreach(fun(Nick) -> whowas_reply(Nick, Count, Client, Server) end, Nicks),
            numeric(Client, Server, <<"369">>, [NickMasks], <<"End of WHOWAS">>)
    end;
registered_command(<<"MOTD">>, Params, Client, Server) ->
    motd(Params, Client, Server);
registered_command(<<"CAP">>, [<<"END">>], _, _) ->
    ok;
registered_command(<<"AWAY">>, _, Client, Server) ->
    numeric(Client, Server, <<"461">>, [<<"AWAY">>], <<"Not enough parameters">>);
registered_command(Command, [], Client, Server) when
    Command =:= <<"JOIN">>;
    Command =:= <<"PART">>;
    Command =:= <<"TOPIC">>;
    Command =:= <<"WHOIS">>;
    Command =:= <<"MODE">>;
    Command =:= <<"KICK">>
->
    numeric(Client, Server, <<"461">>, [Command], <<"Not enough parameters">>);
registered_command(Command, _, Client, Server) ->
    numeric(Client, Server, <<"421">>, [Command], <<"Unknown command">>).

%% Match an optional server argument against this server's configured name.
query_local_server([], _) ->
    true;
query_local_server([Target | _], Server) ->
    case wildcard_match(Target, Server) of
        true -> true;
        false -> {false, Target}
    end.

trace([], Client, Server) ->
    trace_server(Client, Server);
trace([Target | _], Client, Server) ->
    case wildcard_match(Target, Server) of
        true ->
            trace_server(Client, Server);
        false ->
            case find_nick(Target) of
                undefined ->
                    numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
                User ->
                    trace_user(User, Client, Server),
                    trace_end(Client, Server)
            end
    end.

trace_server(Client, Server) ->
    RequesterIsOperator = maps:is_key($o, user_modes(Client#client.pid)),
    lists:foreach(
        fun(Pid) ->
            case mnesia:dirty_read(client, Pid) of
                [User] when User#client.nick =/= <<"*">> ->
                    IsOperator = maps:is_key($o, user_modes(Pid)),
                    case IsOperator orelse RequesterIsOperator of
                        true -> trace_user(User, Client, Server);
                        false -> ok
                    end;
                _ ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(client)
    ),
    trace_end(Client, Server).

trace_end(Client, Server) ->
    numeric(
        Client,
        Server,
        <<"262">>,
        [Server, <<"ircd-0.1.0">>],
        <<"End of TRACE">>
    ).

trace_user(#client{pid = Pid, nick = Nick}, Client, Server) ->
    {Reply, Label} =
        case maps:is_key($o, user_modes(Pid)) of
            true -> {<<"204">>, <<"Oper">>};
            false -> {<<"205">>, <<"User">>}
        end,
    numeric(Client, Server, Reply, [Label, <<"0">>, Nick], none).

users_disabled(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        true ->
            numeric(Client, Server, <<"446">>, [], <<"USERS has been disabled">>);
        {false, Target} ->
            numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end.

squery([], Client, Server) ->
    numeric(Client, Server, <<"411">>, [], <<"No recipient given (SQUERY)">>);
squery([_Service], Client, Server) ->
    numeric(Client, Server, <<"412">>, [], <<"No text to send">>);
squery([_Service, <<>> | _], Client, Server) ->
    numeric(Client, Server, <<"412">>, [], <<"No text to send">>);
squery([Service | _], Client, Server) ->
    numeric(Client, Server, <<"401">>, [Service], <<"No such nick/channel">>).

count_command(Pid, Command, MessageBytes) ->
    case supported_command(Command) of
        true ->
            Stats = persistent_term:get({?MODULE, command_stats}, #{}),
            {Count, Bytes} = maps:get(Command, Stats, {0, 0}),
            persistent_term:put({?MODULE, command_stats}, Stats#{
                Command => {Count + 1, Bytes + MessageBytes}
            });
        false ->
            ok
    end,
    update_connection_stats(Pid, recv_messages, recv_bytes, MessageBytes).

server_wallops(Text, Server) ->
    Recipients =
        [
            Pid
         || Pid <- mnesia:dirty_all_keys(client),
            maps:is_key($w, user_modes(Pid))
        ],
    broadcast(Recipients, Server, <<"WALLOPS">>, [], Text).

supported_command(Command) ->
    lists:member(
        Command,
        [
            <<"ADMIN">>,
            <<"AWAY">>,
            <<"CAP">>,
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
            <<"SERVLIST">>,
            <<"SQUERY">>,
            <<"STATS">>,
            <<"SUMMON">>,
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

put_connection_stats(Pid, Entry) ->
    Stats = persistent_term:get({?MODULE, connection_stats}, #{}),
    persistent_term:put({?MODULE, connection_stats}, Stats#{
        Pid => Entry#{
            connected_at => erlang:monotonic_time(second),
            sent_messages => 0,
            sent_bytes => 0,
            recv_messages => 0,
            recv_bytes => 0
        }
    }).

remove_connection_stats(Pid) ->
    Stats = persistent_term:get({?MODULE, connection_stats}, #{}),
    persistent_term:put({?MODULE, connection_stats}, maps:remove(Pid, Stats)).

connection_stats(Pid) ->
    maps:get(Pid, persistent_term:get({?MODULE, connection_stats}, #{}), #{}).

update_connection_stats(Pid, MessagesKey, BytesKey, Bytes) ->
    Stats = persistent_term:get({?MODULE, connection_stats}, #{}),
    case maps:find(Pid, Stats) of
        {ok, Entry} ->
            Updated = Entry#{
                MessagesKey := maps:get(MessagesKey, Entry) + 1,
                BytesKey := maps:get(BytesKey, Entry) + Bytes
            },
            persistent_term:put({?MODULE, connection_stats}, Stats#{Pid := Updated});
        error ->
            ok
    end.

stats(Params, Client, Server) ->
    {Query, Target} =
        case Params of
            [Letter, Name | _] -> {Letter, Name};
            [Letter] -> {Letter, undefined};
            [] -> {<<"*">>, undefined}
        end,
    case Target =/= undefined andalso not wildcard_match(Target, Server) of
        true ->
            numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        false ->
            report_stats(Query, Client, Server)
    end.

report_stats(<<"u">>, Client, Server) ->
    Uptime = erlang:monotonic_time(second) - persistent_term:get({?MODULE, started_at}),
    Days = Uptime div 86400,
    Hours = (Uptime rem 86400) div 3600,
    Minutes = (Uptime rem 3600) div 60,
    Seconds = Uptime rem 60,
    numeric(
        Client,
        Server,
        <<"242">>,
        [],
        [
            <<"Server Up ">>,
            integer_to_binary(Days),
            <<" days ">>,
            two_digits(Hours),
            <<":">>,
            two_digits(Minutes),
            <<":">>,
            two_digits(Seconds)
        ]
    ),
    numeric(Client, Server, <<"219">>, [<<"u">>], <<"End of STATS report">>);
report_stats(<<"m">>, Client, Server) ->
    Stats = persistent_term:get({?MODULE, command_stats}, #{}),
    lists:foreach(
        fun({Command, {Count, Bytes}}) ->
            numeric(
                Client,
                Server,
                <<"212">>,
                [Command, integer_to_binary(Count), integer_to_binary(Bytes), <<"0">>],
                none
            )
        end,
        lists:sort(maps:to_list(Stats))
    ),
    numeric(Client, Server, <<"219">>, [<<"m">>], <<"End of STATS report">>);
report_stats(<<"l">>, Client, Server) ->
    lists:foreach(
        fun(Pid) ->
            case {mnesia:dirty_read(client, Pid), connection_stats(Pid)} of
                {
                    [#client{nick = Nick}],
                    #{
                        sent_messages := SentMessages,
                        sent_bytes := SentBytes,
                        recv_messages := RecvMessages,
                        recv_bytes := RecvBytes,
                        connected_at := ConnectedAt
                    }
                } ->
                    Open = erlang:monotonic_time(second) - ConnectedAt,
                    numeric(
                        Client,
                        Server,
                        <<"211">>,
                        [
                            Nick,
                            <<"0">>,
                            integer_to_binary(SentMessages),
                            integer_to_binary(SentBytes div 1024),
                            integer_to_binary(RecvMessages),
                            integer_to_binary(RecvBytes div 1024),
                            integer_to_binary(Open)
                        ],
                        none
                    );
                _ ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(client)
    ),
    numeric(Client, Server, <<"219">>, [<<"l">>], <<"End of STATS report">>);
report_stats(<<"o">>, Client, Server) ->
    lists:foreach(
        fun({Name, _Password}) ->
            numeric(Client, Server, <<"243">>, [<<"O">>, <<"*">>, <<"*">>, Name], none)
        end,
        persistent_term:get({?MODULE, operators}, [])
    ),
    numeric(Client, Server, <<"219">>, [<<"o">>], <<"End of STATS report">>);
report_stats(Query, Client, Server) ->
    numeric(Client, Server, <<"219">>, [Query], <<"End of STATS report">>).

two_digits(Value) when Value < 10 -> <<$0, ($0 + Value)>>;
two_digits(Value) -> integer_to_binary(Value).

oper(Name, Password, #client{pid = Pid} = Client, Server) ->
    Credentials = persistent_term:get({?MODULE, operators}, []),
    case lists:keyfind(ircd_wire:fold(Name), 1, Credentials) of
        false ->
            numeric(Client, Server, <<"491">>, [], <<"No O-lines for your host">>);
        {_, Password} ->
            Modes = (user_modes(Pid))#{$o => true},
            mnesia:dirty_write(#user_modes{pid = Pid, modes = Modes}),
            server_broadcast(
                ircd_wire:line(prefix(Client), <<"MODE">>, [Client#client.nick, <<"+o">>], none)
            ),
            numeric(Client, Server, <<"381">>, [], <<"You are now an IRC operator">>);
        _ ->
            numeric(Client, Server, <<"464">>, [], <<"Password incorrect">>)
    end.

kill(Params, #client{pid = Pid} = Client, Server) ->
    case maps:is_key($o, user_modes(Pid)) of
        false ->
            numeric(
                Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>
            );
        true ->
            kill_target(Params, Client, Server)
    end.

kill_target([Nick, Reason | _], Client, Server) ->
    case find_nick(Nick) of
        undefined ->
            numeric(Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>);
        #client{pid = TargetPid, nick = Actual} = Target ->
            Line = ircd_wire:line(prefix(Client), <<"KILL">>, [Actual], Reason),
            TargetPid ! {irc_close, Line},
            server_wallops(
                [<<"Oper ">>, Client#client.nick, <<" used KILL on ">>, Actual, <<": ">>, Reason],
                Server
            ),
            disconnect(Target, Reason, Server),
            case TargetPid =:= Client#client.pid of
                true -> quit;
                false -> ok
            end
    end;
kill_target(_, Client, Server) ->
    numeric(Client, Server, <<"461">>, [<<"KILL">>], <<"Not enough parameters">>).

rehash(#client{pid = Pid} = Client, Server) ->
    case maps:is_key($o, user_modes(Pid)) of
        false ->
            numeric(
                Client,
                Server,
                <<"481">>,
                [],
                <<"Permission Denied- You're not an IRC operator">>
            );
        true ->
            Path = persistent_term:get({?MODULE, config_path}),
            case ircd_config:load(Path) of
                {ok, NewConfig} ->
                    rehash_config(NewConfig, Path, Client, Server);
                {error, Reason} ->
                    logger:warning(#{event => rehash_failed, reason => Reason}),
                    numeric(
                        Client,
                        Server,
                        <<"400">>,
                        [<<"REHASH">>],
                        <<"Configuration reload failed">>
                    )
            end
    end.

rehash_config(NewConfig, Path, Client, Server) ->
    OldConfig = persistent_term:get({?MODULE, config}),
    StaticKeys = [name, ip, tcp, tls, tls_options, mnesia_dir, client_password, server_links],
    case
        lists:all(fun(Key) -> maps:get(Key, OldConfig) =:= maps:get(Key, NewConfig) end, StaticKeys)
    of
        false ->
            numeric(
                Client,
                Server,
                <<"400">>,
                [<<"REHASH">>],
                <<"Listener and database changes require a restart">>
            );
        true ->
            apply_rehash(NewConfig),
            server_wallops(
                [<<"Oper ">>, Client#client.nick, <<" rehashed the configuration">>], Server
            ),
            numeric(
                Client, Server, <<"382">>, [unicode:characters_to_binary(Path)], <<"Rehashing">>
            )
    end.

apply_rehash(Config) ->
    persistent_term:put({?MODULE, config}, Config),
    persistent_term:put({?MODULE, operators}, maps:get(operators, Config)),
    persistent_term:put({?MODULE, motd_file}, maps:get(motd_file, Config)),
    persistent_term:put({?MODULE, admin}, maps:get(admin, Config)),
    persistent_term:put({?MODULE, reop_delay}, maps:get(reop_delay, Config)),
    persistent_term:put({?MODULE, server_links}, maps:get(server_links, Config)),
    persistent_term:put({ircd_sessions, max_clients}, maps:get(max_clients, Config)),
    Formatter =
        case maps:get(log_format, Config) of
            <<"json">> -> {ircd_log, #{}};
            <<"text">> -> {flatlog, #{template => [time, " ", level, " ", msg]}}
        end,
    ok = logger:update_handler_config(default, formatter, Formatter),
    ok = logger:update_handler_config(default, level, maps:get(level, Config)).

admin(Params, Client, Server) ->
    case admin_target(Params, Server) of
        {false, Target} ->
            numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            Info = persistent_term:get({?MODULE, admin}, #{}),
            numeric(
                Client,
                Server,
                <<"256">>,
                [Server],
                maps:get(name, Info, <<"IRC server administrator">>)
            ),
            numeric(Client, Server, <<"257">>, [], maps:get(location1, Info, <<"Not configured">>)),
            numeric(Client, Server, <<"258">>, [], maps:get(location2, Info, <<"Not configured">>)),
            numeric(Client, Server, <<"259">>, [], maps:get(email, Info, <<"Not configured">>))
    end.

admin_target([], _) ->
    true;
admin_target([Target | _], Server) ->
    case wildcard_match(Target, Server) orelse find_nick(Target) =/= undefined of
        true -> true;
        false -> {false, Target}
    end.

%% Send the configured MOTD sequence, or the RFC missing-file response.
motd(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        {false, Target} ->
            numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            case persistent_term:get({?MODULE, motd_file}, null) of
                null ->
                    numeric(Client, Server, <<"422">>, [], <<"MOTD File is missing">>);
                Path ->
                    case file:read_file(Path) of
                        {ok, Contents} ->
                            numeric(Client, Server, <<"375">>, [], <<"- Message of the day -">>),
                            lists:foreach(
                                fun(Line) ->
                                    numeric(Client, Server, <<"372">>, [], [<<"- ">>, Line])
                                end,
                                motd_lines(Contents)
                            ),
                            numeric(Client, Server, <<"376">>, [], <<"End of MOTD command">>);
                        {error, _} ->
                            numeric(Client, Server, <<"422">>, [], <<"MOTD File is missing">>)
                    end
            end
    end.

motd_lines(<<>>) ->
    [];
motd_lines(Contents) ->
    Lines = binary:split(Contents, <<"\n">>, [global]),
    ContentLines = lists:sublist(
        Lines,
        length(Lines) -
            case lists:last(Lines) of
                <<>> -> 1;
                _ -> 0
            end
    ),
    lists:append([wrap_motd_line(strip_cr(Line)) || Line <- ContentLines]).

wrap_motd_line(<<>>) ->
    [<<>>];
wrap_motd_line(Line) when byte_size(Line) =< 80 ->
    [Line];
wrap_motd_line(<<Chunk:80/binary, Rest/binary>>) ->
    [Chunk | wrap_motd_line(Rest)].

strip_cr(<<>>) ->
    <<>>;
strip_cr(Line) ->
    case binary:last(Line) of
        $\r -> binary:part(Line, 0, byte_size(Line) - 1);
        _ -> Line
    end.

info(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        {false, Target} ->
            numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            CompileTime = proplists:get_value(time, ?MODULE:module_info(compile)),
            CompileText = iolist_to_binary(io_lib:format("~p", [CompileTime])),
            Started = persistent_term:get({?MODULE, started}),
            numeric(Client, Server, <<"371">>, [], <<"ircd-0.1.0, Erlang/OTP IRC server">>),
            numeric(Client, Server, <<"371">>, [], [<<"Compiled: ">>, CompileText]),
            numeric(Client, Server, <<"371">>, [], <<"Patch level: 0">>),
            numeric(Client, Server, <<"371">>, [], [<<"Started: ">>, Started]),
            numeric(
                Client,
                Server,
                <<"371">>,
                [],
                <<"Protocol references: RFC 1459, 2810, 2811, 2812, 2813, 7194">>
            ),
            numeric(Client, Server, <<"374">>, [], <<"End of INFO list">>)
    end.

links(Params, Client, Server) ->
    {Remote, Mask} =
        case Params of
            [] -> {undefined, <<"*">>};
            [GivenMask] -> {undefined, GivenMask};
            [GivenRemote, GivenMask | _] -> {GivenRemote, GivenMask}
        end,
    case Remote =:= undefined orelse wildcard_match(Remote, Server) of
        false ->
            numeric(Client, Server, <<"402">>, [Remote], <<"No such server">>);
        true ->
            case wildcard_match(Mask, Server) of
                true ->
                    numeric(
                        Client,
                        Server,
                        <<"364">>,
                        [Mask, Server],
                        [<<"0 ">>, Server, <<" (Erlang/OTP IRC server)">>]
                    );
                false ->
                    ok
            end,
            numeric(Client, Server, <<"365">>, [Mask], <<"End of LINKS list">>)
    end.

lusers(Params, Client, Server) ->
    {Mask, Target} =
        case Params of
            [] -> {<<"*">>, Server};
            [GivenMask] -> {GivenMask, Server};
            [GivenMask, GivenTarget | _] -> {GivenMask, GivenTarget}
        end,
    case wildcard_match(Target, Server) of
        false ->
            numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            Included = wildcard_match(Mask, Server),
            {Users, Operators, Unknown, Channels, Clients, Servers} =
                case Included of
                    true ->
                        ClientRecords = [
                            Record
                         || Pid <- mnesia:dirty_all_keys(client),
                            [Record] <- [mnesia:dirty_read(client, Pid)]
                        ],
                        ReadyCount = length([ok || Record <- ClientRecords, ready(Record)]),
                        RemoteRecords = [
                            Record
                         || Key <- mnesia:dirty_all_keys(remote_client),
                            [Record] <- [mnesia:dirty_read(remote_client, Key)]
                        ],
                        RemoteCount = length(RemoteRecords),
                        RemoteServers = lists:usort([
                            Peer
                         || #remote_client{peer = Peer} <- RemoteRecords
                        ]),
                        UnknownCount = length(ClientRecords) - ReadyCount,
                        LocalOperatorCount = length([
                            ok
                         || #client{pid = Pid} = Record <- ClientRecords,
                            ready(Record),
                            maps:is_key($o, user_modes(Pid))
                        ]),
                        RemoteOperatorCount = length([
                            ok
                         || #remote_client{modes = Modes} <- RemoteRecords,
                            maps:is_key($o, Modes)
                        ]),
                        {
                            ReadyCount + RemoteCount,
                            LocalOperatorCount + RemoteOperatorCount,
                            UnknownCount,
                            length(
                                lists:usort(
                                    mnesia:dirty_all_keys(channel) ++
                                        mnesia:dirty_all_keys(remote_channel)
                                )
                            ),
                            length(ClientRecords) + RemoteCount,
                            1 + length(RemoteServers)
                        };
                    false ->
                        {0, 0, 0, 0, 0, 0}
                end,
            numeric(
                Client,
                Server,
                <<"251">>,
                [],
                [
                    <<"There are ">>,
                    integer_to_binary(Users),
                    <<" users and 0 services on ">>,
                    integer_to_binary(Servers),
                    <<" servers">>
                ]
            ),
            case Operators of
                0 ->
                    ok;
                _ ->
                    numeric(
                        Client,
                        Server,
                        <<"252">>,
                        [integer_to_binary(Operators)],
                        <<"operator(s) online">>
                    )
            end,
            case Unknown of
                0 ->
                    ok;
                _ ->
                    numeric(
                        Client,
                        Server,
                        <<"253">>,
                        [integer_to_binary(Unknown)],
                        <<"unknown connection(s)">>
                    )
            end,
            case Channels of
                0 ->
                    ok;
                _ ->
                    numeric(
                        Client,
                        Server,
                        <<"254">>,
                        [integer_to_binary(Channels)],
                        <<"channels formed">>
                    )
            end,
            numeric(
                Client,
                Server,
                <<"255">>,
                [],
                [
                    <<"I have ">>,
                    integer_to_binary(Clients),
                    <<" clients and ">>,
                    integer_to_binary(Servers),
                    <<" servers">>
                ]
            )
    end.

join_channels([], _, _, _) ->
    ok;
join_channels([Name | Names], Keys, Pid, Server) ->
    {Password, Remaining} =
        case Keys of
            [Key | Tail] -> {Key, Tail};
            [] -> {undefined, []}
        end,
    join(Name, Password, client(Pid), Server),
    join_channels(Names, Remaining, Pid, Server).

%% Resolve safe channel names, then apply membership, key, limit, and ban checks.
join(Name, Password, Client, Server) ->
    case resolve_channel(Name) of
        error ->
            numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
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
add_member(Key, Name, #client{pid = Pid, channels = Channels} = Client, Server, Password) ->
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
    Role =
        case {IsNew, binary:first(Canonical)} of
            {true, $!} -> [operator, creator];
            {true, Prefix} when Prefix =/= $+ -> [operator];
            _ -> [member]
        end,
    NewMembers =
        case Role of
            Roles when is_list(Roles) -> Members#{Pid => Roles};
            _ -> Members#{Pid => [Role]}
        end,
    case Channel of
        #channel{password = Required} when Required =/= undefined, Required =/= Password ->
            numeric(Client, Server, <<"475">>, [Canonical], <<"Cannot join channel (+k)">>);
        #channel{limit = Limit} when is_integer(Limit), map_size(Members) >= Limit ->
            numeric(Client, Server, <<"471">>, [Canonical], <<"Cannot join channel (+l)">>);
        _ ->
            Invited =
                lists:member(Pid, Channel#channel.invited) orelse
                    mask_matches(Channel, invite, Client),
            Banned =
                mask_matches(Channel, ban, Client) andalso
                    not mask_matches(Channel, exception, Client),
            case {maps:is_key($i, Channel#channel.flags) andalso not Invited, Banned} of
                {true, _} ->
                    numeric(Client, Server, <<"473">>, [Canonical], <<"Cannot join channel (+i)">>);
                {_, true} ->
                    numeric(Client, Server, <<"474">>, [Canonical], <<"Cannot join channel (+b)">>);
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
    propagate_join(Client, Canonical, maps:get(Pid, NewMembers)),
    JoinRecipients =
        case maps:is_key($q, Flags) of
            true -> [Pid];
            false -> maps:keys(NewMembers)
        end,
    broadcast(
        JoinRecipients, channel_origin_prefix(Channel, Client), <<"JOIN">>, [Canonical], none
    ),
    topic_reply(Channel, Client, Server),
    names(Canonical, Client, Server).

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
            broadcast(Recipients, channel_origin_prefix(Channel, Client), Command, [Name], Reason);
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
            server_broadcast(ircd_wire:line(prefix(Client), <<"PART">>, [Name], ReasonParams));
        false ->
            ok
    end,
    case maps:remove(Pid, Members) of
        Remaining when map_size(Remaining) =:= 0 ->
            case Name of
                <<$!, _/binary>> ->
                    mnesia:dirty_write(track_opless(Channel, Remaining));
                _ ->
                    mnesia:dirty_delete(channel, Key)
            end;
        Remaining ->
            mnesia:dirty_write(track_opless(Channel, Remaining))
    end,
    Current = client(Pid),
    mnesia:dirty_write(Current#client{channels = lists:delete(Key, Current#client.channels)}).

kick(_, [], _, _, _) ->
    ok;
kick(Name, [Nick | Nicks], Reason, #client{pid = Pid} = Client, Server) ->
    Key = ircd_wire:fold(Name),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        [#channel{name = Canonical, members = Members} = Channel] ->
            case maps:is_key(Pid, Members) of
                false ->
                    numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                true ->
                    case lists:member(operator, maps:get(Pid, Members, [])) of
                        false ->
                            numeric(
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
    case find_nick(Nick) of
        undefined ->
            numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>),
            kick(Canonical, Nicks, Reason, Client, Server);
        #client{pid = TargetPid, nick = Actual} = Target ->
            case maps:is_key(TargetPid, Members) of
                false ->
                    numeric(
                        Client,
                        Server,
                        <<"441">>,
                        [Actual, Canonical],
                        <<"They aren't on that channel">>
                    ),
                    kick(Canonical, Nicks, Reason, Client, Server);
                true ->
                    broadcast(
                        case maps:is_key($q, Channel#channel.flags) of
                            true -> [Client#client.pid, TargetPid];
                            false -> maps:keys(Members)
                        end,
                        channel_origin_prefix(Channel, Client),
                        <<"KICK">>,
                        [Canonical, Actual],
                        Reason
                    ),
                    propagate_channel_kick(Client, Canonical, Actual, Reason),
                    Remaining = maps:remove(TargetPid, Members),
                    case map_size(Remaining) of
                        0 ->
                            case Canonical of
                                <<$!, _/binary>> ->
                                    mnesia:dirty_write(track_opless(Channel, Remaining));
                                _ ->
                                    mnesia:dirty_delete(channel, Key)
                            end;
                        _ ->
                            mnesia:dirty_write(track_opless(Channel, Remaining))
                    end,
                    mnesia:dirty_write(Target#client{
                        channels = lists:delete(Key, Target#client.channels)
                    }),
                    kick(Canonical, Nicks, Reason, Client, Server)
            end
    end.

%% Broadcast QUIT, leave joined channels, and delete all per-client Mnesia rows.
disconnect(#client{pid = Pid, channels = Channels} = Client, Reason, Server) ->
    case ready(Client) of
        true ->
            save_whowas(Client, Server),
            propagate_quit(Client, Reason);
        false ->
            ok
    end,
    case ready(Client) of
        true -> broadcast(quit_recipients(Client), prefix(Client), <<"QUIT">>, [], Reason);
        false -> ok
    end,
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{flags = Flags}] ->
                    leave(Key, Client, <<"PART">>, none, maps:is_key($a, Flags), false);
                [] ->
                    ok
            end
        end,
        Channels
    ),
    mnesia:dirty_delete(client, Pid),
    mnesia:dirty_delete(activity, Pid),
    mnesia:dirty_delete(user_modes, Pid),
    remove_connection_stats(Pid).

quit_recipients(#client{pid = Pid, channels = Channels}) ->
    lists:usort([
        OtherPid
     || Key <- Channels,
        [#channel{members = Members, flags = Flags}] <- [mnesia:dirty_read(channel, Key)],
        not maps:is_key($a, Flags),
        not maps:is_key($q, Flags),
        OtherPid <- maps:keys(Members),
        OtherPid =/= Pid
    ]).

touch_activity(Pid) ->
    mnesia:dirty_write(#activity{pid = Pid, last = erlang:system_time(second)}).

user_modes(Pid) ->
    case mnesia:dirty_read(user_modes, Pid) of
        [#user_modes{modes = Modes}] -> Modes;
        [] -> #{}
    end.

user_visible(#client{pid = Pid}, #client{pid = RequesterPid}) when
    Pid =:= RequesterPid
->
    true;
user_visible(#client{pid = Pid, channels = Channels}, #client{pid = RequesterPid}) ->
    not maps:is_key($i, user_modes(Pid)) orelse
        lists:any(
            fun(Key) ->
                case mnesia:dirty_read(channel, Key) of
                    [#channel{members = Members}] -> maps:is_key(RequesterPid, Members);
                    [] -> false
                end
            end,
            Channels
        ).

nick_recipients(#client{pid = Pid, channels = Channels}) ->
    lists:usort(
        [
            Other
         || Key <- Channels,
            [#channel{members = Members, flags = Flags}] <- [mnesia:dirty_read(channel, Key)],
            not maps:is_key($a, Flags),
            not maps:is_key($q, Flags),
            Other <- maps:keys(Members),
            Other =/= Pid
        ] ++ [Pid]
    ).

channel_origin_prefix(#channel{flags = Flags}, _Client) when is_map_key($a, Flags) ->
    <<"anonymous!anonymous@anonymous.">>;
channel_origin_prefix(_, Client) ->
    prefix(Client).

%% Route PRIVMSG/NOTICE to nicknames and channels, applying channel restrictions.
deliver(Command, [], Client, Server) ->
    message_error(Command, Client, Server, <<"411">>, [], <<"No recipient given">>);
deliver(Command, [_], Client, Server) ->
    message_error(Command, Client, Server, <<"412">>, [], <<"No text to send">>);
deliver(Command, [_, <<>> | _], Client, Server) ->
    message_error(Command, Client, Server, <<"412">>, [], <<"No text to send">>);
deliver(Command, [Targets, Text | _], Client, Server) ->
    lists:foreach(
        fun(Target) -> deliver_to(Target, Text, Command, Client, Server) end,
        lists:uniq(split(Targets))
    ).

deliver_to(Target, Text, Command, #client{pid = Pid} = Client, Server) ->
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
                    broadcast(
                        maps:keys(maps:remove(Pid, Members)),
                        channel_origin_prefix(Channel, Client),
                        Command,
                        [Name],
                        Text
                    ),
                    propagate_channel_message(Name, Text, Command, Client)
            end;
        [] ->
            case find_nick(Target) of
                #client{pid = Other, nick = Nick, away = Away} ->
                    send(Other, prefix(Client), Command, [Nick], Text),
                    case {Command, Away} of
                        {<<"PRIVMSG">>, Message} when Message =/= undefined ->
                            numeric(Client, Server, <<"301">>, [Nick], Message);
                        _ ->
                            ok
                    end;
                undefined ->
                    case mnesia:dirty_read(remote_client, ircd_wire:fold(Target)) of
                        [#remote_client{peer = Peer, nick = Nick}] ->
                            Line = ircd_wire:line(prefix(Client), Command, [Nick], Text),
                            case ircd_links:send(Peer, Line) of
                                ok ->
                                    ok;
                                {error, _} ->
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

receive_remote_message(Peer, Prefix, Command, [Target, Text | _]) ->
    case binary:split(Prefix, <<"!">>) of
        [Nick, _UserHost] ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [
                    #remote_client{
                        peer = Peer,
                        nick = Nick,
                        user = User,
                        host = Host
                    } = Remote
                ] ->
                    ExpectedPrefix = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
                    case Prefix =:= ExpectedPrefix of
                        true ->
                            receive_remote_target(Peer, Remote, Prefix, Target, Text, Command);
                        false ->
                            {error, remote_prefix_mismatch}
                    end;
                _ ->
                    {error, unknown_remote_source}
            end;
        _ ->
            {error, malformed_remote_prefix}
    end;
receive_remote_message(_Peer, _Prefix, _Command, _Params) ->
    {error, invalid_remote_message}.

receive_remote_target(Peer, Remote, Prefix, Target, Text, Command) ->
    case find_nick(Target) of
        #client{pid = Pid, nick = LocalNick} ->
            send(Pid, Prefix, Command, [LocalNick], Text),
            ok;
        undefined ->
            case ircd_wire:channel(Target) of
                true -> receive_remote_channel_message(Peer, Remote, Prefix, Target, Text, Command);
                false -> ok
            end
    end.

receive_remote_channel_message(Peer, Remote, Prefix, Name, Text, Command) ->
    Key = ircd_wire:fold(Name),
    case {mnesia:dirty_read(remote_channel, Key), mnesia:dirty_read(channel, Key)} of
        {[#remote_channel{members = RemoteMembers, flags = RemoteFlags}], [Channel]} ->
            NickKey = Remote#remote_client.key,
            case maps:find(NickKey, RemoteMembers) of
                {ok, {Peer, Roles}} ->
                    Flags = maps:merge(RemoteFlags, Channel#channel.flags),
                    RemoteIdentity = #client{
                        nick = Remote#remote_client.nick,
                        user = Remote#remote_client.user,
                        host = Remote#remote_client.host
                    },
                    Banned =
                        mask_matches(Channel, ban, RemoteIdentity) andalso
                            not mask_matches(Channel, exception, RemoteIdentity),
                    Allowed =
                        not maps:is_key($m, Flags) orelse
                            lists:member(operator, Roles) orelse lists:member(voice, Roles),
                    case Allowed andalso not Banned of
                        true ->
                            Origin =
                                case maps:is_key($a, Flags) of
                                    true -> <<"anonymous!anonymous@anonymous.">>;
                                    false -> Prefix
                                end,
                            broadcast(
                                maps:keys(Channel#channel.members), Origin, Command, [Name], Text
                            );
                        false ->
                            ok
                    end;
                _ ->
                    {error, remote_user_not_on_channel}
            end;
        {[#remote_channel{members = RemoteMembers}], []} ->
            case maps:find(Remote#remote_client.key, RemoteMembers) of
                {ok, {Peer, _Roles}} -> ok;
                _ -> {error, remote_user_not_on_channel}
            end;
        {[], _} ->
            {error, unknown_remote_channel};
        {_, []} ->
            {error, unknown_remote_channel}
    end.

message_error(<<"NOTICE">>, _, _, _, _, _) ->
    ok;
message_error(_, Client, Server, Number, Middle, Text) ->
    numeric(Client, Server, Number, Middle, Text).

topic(Name, Rest, #client{pid = Pid} = Client, Server) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, flags = Flags} = Channel] ->
            Operator = lists:member(operator, maps:get(Pid, Members, [])),
            Hidden = maps:is_key($s, Flags) andalso not maps:is_key(Pid, Members),
            case {Hidden, maps:is_key(Pid, Members), Rest} of
                {true, _, _} ->
                    numeric(Client, Server, <<"403">>, [Canonical], <<"No such channel">>);
                {false, false, [_ | _]} ->
                    numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                {false, _, []} ->
                    topic_reply(effective_topic(Channel), Client, Server);
                {false, true, [_ | _]} when is_map_key($t, Flags), not Operator ->
                    numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    );
                {false, true, [Text | _]} ->
                    mnesia:dirty_write(Channel#channel{topic = Text}),
                    broadcast(
                        maps:keys(Members),
                        channel_origin_prefix(Channel, Client),
                        <<"TOPIC">>,
                        [Canonical],
                        Text
                    ),
                    propagate_topic(Client, Canonical, Text)
            end;
        [] ->
            case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
                [#remote_channel{name = Canonical, flags = RemoteFlags}] ->
                    case {maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags), Rest} of
                        {true, _} ->
                            numeric(Client, Server, <<"403">>, [Canonical], <<"No such channel">>);
                        {false, []} ->
                            topic_reply(
                                #channel{
                                    name = Canonical, topic = maps:get(topic, RemoteFlags, <<>>)
                                },
                                Client,
                                Server
                            );
                        {false, [_ | _]} ->
                            numeric(
                                Client,
                                Server,
                                <<"442">>,
                                [Canonical],
                                <<"You're not on that channel">>
                            )
                    end;
                [] ->
                    numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>)
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
    numeric(Client, Server, <<"331">>, [Name], <<"No topic is set">>);
topic_reply(#channel{name = Name, topic = Topic}, Client, Server) ->
    numeric(Client, Server, <<"332">>, [Name], Topic).

names(Name, Client, Server) ->
    Canonical =
        case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
            [#channel{name = Existing, members = Members, flags = Flags}] ->
                LocalMember = maps:is_key(Client#client.pid, Members),
                RemoteFlags = remote_channel_flags(Name),
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
                            display_nick(client(Pid), maps:get(Pid, Members))
                         || Pid <- VisiblePids,
                            visible_member(Pid, Client, Members)
                        ],
                        RemoteEntries =
                            case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                                true -> [];
                                false -> remote_names_entries(Name, Client, LocalMember)
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
                                    remote_names_entries(Name, Client, false),
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
    numeric(Client, Server, <<"366">>, [Canonical], <<"End of NAMES list">>).

names_listing(Key, Client, Server) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Name, members = Members, flags = Flags}] ->
            RemoteFlags = remote_channel_flags(Name),
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
                        display_nick(client(Pid), maps:get(Pid, Members))
                     || Pid <- VisiblePids,
                        visible_member(Pid, Client, Members)
                    ],
                    RemoteEntries =
                        case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                            true -> [];
                            false -> remote_names_entries(Name, Client, LocalMember)
                        end,
                    Entries = lists:usort(fun nick_less/2, LocalEntries ++ RemoteEntries),
                    names_lines(Entries, [], 0, Name, Client, Server);
                false ->
                    ok
            end;
        [] ->
            ok
    end.

remote_names_listing(Key, Client, Server) ->
    case mnesia:dirty_read(remote_channel, Key) of
        [#remote_channel{name = Name, flags = Flags}] ->
            LocalMember =
                case mnesia:dirty_read(channel, Key) of
                    [#channel{members = Members}] -> maps:is_key(Client#client.pid, Members);
                    [] -> false
                end,
            Hidden =
                (maps:is_key($p, Flags) orelse maps:is_key($s, Flags)) andalso
                    not LocalMember,
            case Hidden orelse maps:is_key($a, Flags) of
                true ->
                    ok;
                false ->
                    names_lines(
                        remote_names_entries(Name, Client, LocalMember), [], 0, Name, Client, Server
                    )
            end;
        [] ->
            ok
    end.

remote_channel_flags(Name) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{flags = Flags}] -> Flags;
        [] -> #{}
    end.

remote_names_entries(Name, Client, LocalMember) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            lists:sort([
                remote_display_nick(Remote, Roles)
             || {NickKey, {_Peer, Roles}} <- maps:to_list(Members),
                [Remote] <- [mnesia:dirty_read(remote_client, NickKey)],
                remote_visible_in_names(Remote, Client, LocalMember)
            ]);
        [] ->
            []
    end.

remote_visible_in_names(#remote_client{modes = Modes}, _Client, LocalMember) ->
    LocalMember orelse not maps:is_key($i, Modes).

remote_user_visible_to_requester(NickKey, Modes, Client) ->
    not maps:is_key($i, Modes) orelse
        lists:any(
            fun(ChannelKey) ->
                case
                    {
                        mnesia:dirty_read(remote_channel, ChannelKey),
                        mnesia:dirty_read(channel, ChannelKey)
                    }
                of
                    {
                        [#remote_channel{members = RemoteMembers}],
                        [#channel{members = LocalMembers}]
                    } ->
                        maps:is_key(NickKey, RemoteMembers) andalso
                            maps:is_key(Client#client.pid, LocalMembers);
                    _ ->
                        false
                end
            end,
            mnesia:dirty_all_keys(remote_channel)
        ).

remote_user_local_recipients(NickKey) ->
    lists:usort([
        Pid
     || ChannelKey <- mnesia:dirty_all_keys(remote_channel),
        [#remote_channel{members = RemoteMembers, flags = RemoteFlags}] <-
            [mnesia:dirty_read(remote_channel, ChannelKey)],
        maps:is_key(NickKey, RemoteMembers),
        not maps:is_key($a, RemoteFlags),
        not maps:is_key($q, RemoteFlags),
        [#channel{members = LocalMembers, flags = LocalFlags}] <-
            [mnesia:dirty_read(channel, ChannelKey)],
        not maps:is_key($a, LocalFlags),
        not maps:is_key($q, LocalFlags),
        Pid <- maps:keys(LocalMembers)
    ]).

remote_display_nick(#remote_client{nick = Nick}, Roles) ->
    case
        {lists:member(creator, Roles), lists:member(operator, Roles), lists:member(voice, Roles)}
    of
        {true, _, _} -> <<$@, Nick/binary>>;
        {false, true, _} -> <<$@, Nick/binary>>;
        {false, false, true} -> <<$+, Nick/binary>>;
        _ -> Nick
    end.

nick_less(Left, Right) -> ircd_wire:fold(Left) =< ircd_wire:fold(Right).

names_unattached(#client{pid = RequesterPid}, Server) ->
    Requester = client(RequesterPid),
    Entries = lists:sort([
        Member#client.nick
     || Pid <- mnesia:dirty_all_keys(client),
        [Member] <- [mnesia:dirty_read(client, Pid)],
        ready(Member),
        user_visible(Member, Requester),
        not has_visible_channel(Member#client.channels, Requester)
    ]),
    names_lines(Entries, [], 0, <<"*">>, Requester, Server).

visible_member(Pid, Requester, Members) ->
    maps:is_key(Requester#client.pid, Members) orelse
        case mnesia:dirty_read(client, Pid) of
            [Member] -> user_visible(Member, Requester);
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
    numeric(
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
            case remote_channel_flags(Name) of
                Flags when is_map_key($s, Flags) -> <<"@">>;
                Flags when is_map_key($p, Flags) -> <<"*">>;
                _ -> <<"=">>
            end
    end.

display_nick(#client{nick = Nick}, Roles) ->
    case {lists:member(operator, Roles), lists:member(voice, Roles)} of
        {true, _} -> <<$@, Nick/binary>>;
        {false, true} -> <<$+, Nick/binary>>;
        _ -> Nick
    end.

mask_matches(#channel{lists = Lists}, Type, #client{nick = Nick, user = User, host = Host}) ->
    Identity = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
    lists:any(fun(Mask) -> wildcard_match(Mask, Identity) end, maps:get(Type, Lists, [])).

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
            numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        [#channel{name = Canonical, members = Members, flags = Flags} = Channel] ->
            case maps:is_key(Pid, Members) of
                true ->
                    numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're already on that channel">>
                    );
                false ->
                    case {maps:is_key($K, Flags), maps:is_key($i, Flags)} of
                        {true, _} ->
                            numeric(
                                Client,
                                Server,
                                <<"480">>,
                                [Canonical],
                                <<"Cannot knock on channel">>
                            );
                        {false, false} ->
                            numeric(
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
                                    numeric(
                                        Client,
                                        Server,
                                        <<"480">>,
                                        [Canonical],
                                        <<"No channel operators available">>
                                    );
                                _ ->
                                    broadcast(
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
    case find_nick(Nick) of
        undefined ->
            numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>);
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
                            numeric(
                                Client,
                                Server,
                                <<"443">>,
                                [Target#client.nick, Canonical],
                                <<"is already on channel">>
                            );
                        {false, false, _} ->
                            numeric(
                                Client,
                                Server,
                                <<"442">>,
                                [Canonical],
                                <<"You're not on that channel">>
                            );
                        {false, true, true} ->
                            numeric(
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
                            notify_invite(Target, Canonical, Client, Server)
                    end
            end
    end.

notify_invite(
    #client{pid = TargetPid, nick = TargetNick, away = Away},
    Channel,
    Client,
    Server
) ->
    numeric(Client, Server, <<"341">>, [TargetNick, Channel], none),
    send(
        TargetPid, invite_origin_prefix(Channel, Client), <<"INVITE">>, [TargetNick, Channel], none
    ),
    case Away of
        undefined -> ok;
        _ -> numeric(Client, Server, <<"301">>, [TargetNick], Away)
    end.

invite_origin_prefix(Channel, Client) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Channel)) of
        [Record] -> channel_origin_prefix(Record, Client);
        [] -> prefix(Client)
    end.

%% Route MODE to a channel or to the requesting user's supported modes.
mode_command(Target, Rest, Client, Server) ->
    case ircd_wire:channel(Target) of
        true -> channel_mode(Target, Rest, Client, Server);
        false -> user_mode(Target, Rest, Client, Server)
    end.

user_mode(Target, Rest, #client{pid = Pid} = Client, Server) ->
    case find_nick(Target) of
        undefined ->
            numeric(Client, Server, <<"401">>, [Target], <<"No such nick/channel">>);
        #client{pid = Other} when Other =/= Pid ->
            numeric(Client, Server, <<"502">>, [], <<"Cannot change mode for other users">>);
        #client{nick = Nick} ->
            Modes = user_modes(Pid),
            case Rest of
                [] ->
                    numeric(Client, Server, <<"221">>, [user_mode_string(Modes)], none);
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
    numeric(Client, Server, <<"501">>, [], <<"Unknown MODE flag">>),
    change_user_modes(Rest, undefined, Modes, Nick, Client, Server);
change_user_modes([Mode | Rest], Action, Modes, Nick, Client, Server) when
    Mode =:= $i; Mode =:= $w
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
            send(Client#client.pid, prefix(Client), <<"MODE">>, [Nick, <<Sign, Mode>>], none),
            server_broadcast(
                ircd_wire:line(prefix(Client), <<"MODE">>, [Nick, <<Sign, Mode>>], none)
            );
        false ->
            ok
    end,
    change_user_modes(Rest, Action, New, Nick, Client, Server);
change_user_modes([$o | Rest], Action, Modes, Nick, Client, Server) ->
    numeric(Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>),
    change_user_modes(Rest, Action, Modes, Nick, Client, Server);
change_user_modes([_Mode | Rest], Action, Modes, Nick, Client, Server) ->
    numeric(Client, Server, <<"501">>, [], <<"Unknown MODE flag">>),
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
                    numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    )
            end;
        [] ->
            numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>)
    end.

list_mode(Type, Name, Pid, Client, Server) ->
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, lists = Lists}] ->
            case Type =:= invite orelse lists:member(operator, maps:get(Pid, Members, [])) of
                false ->
                    numeric(
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
                            numeric(Client, Server, <<"367">>, [Canonical, Entry], none)
                        end,
                        maps:get(Type, Lists, [])
                    ),
                    numeric(
                        Client,
                        Server,
                        <<"368">>,
                        [Canonical, <<Mode>>],
                        <<"End of channel list">>
                    )
            end;
        [] ->
            numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>)
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
    numeric(Client, Server, <<"324">>, [Name, Modes | KeyArgs ++ LimitArgs], none).

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
            numeric(
                Client,
                Server,
                <<"481">>,
                [],
                <<"Permission Denied- Quiet mode is server only">>
            ),
            change_modes(Rest, Action, Args, Channel, Client, Server);
        {_, false, _} ->
            numeric(Client, Server, <<"482">>, [Name], <<"You're not channel creator">>),
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
                    broadcast(
                        maps:keys(Members),
                        channel_origin_prefix(Channel, Client),
                        <<"MODE">>,
                        [Name, <<Sign, Mode>> | Parameters],
                        none
                    ),
                    propagate_channel_mode(Client, Name, <<Sign, Mode>>, Parameters);
                false ->
                    ok
            end,
            change_modes(Rest, Action, Tail, New, Client, Server);
        {_, true, {error, Code, Params, Message, Tail}} ->
            numeric(Client, Server, Code, Params, Message),
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
            NewList =
                case Action of
                    add -> lists:usort([Mask | Existing]);
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
        nomatch -> {ok, Channel#channel{password = Key}, Args, [Key]};
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
    case find_nick(Nick) of
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

userhost(Nicks, Client, Server) ->
    Entries = lists:filtermap(
        fun(Nick) ->
            case find_nick(Nick) of
                #client{pid = Pid, nick = Actual, host = Host, away = Away} ->
                    AwayMarker =
                        case Away of
                            undefined -> <<"+">>;
                            _ -> <<"-">>
                        end,
                    OperatorMarker =
                        case maps:is_key($o, user_modes(Pid)) of
                            true -> <<"*">>;
                            false -> <<>>
                        end,
                    {
                        true,
                        <<Actual/binary, OperatorMarker/binary, $=, AwayMarker/binary, Host/binary>>
                    };
                undefined ->
                    remote_userhost(Nick)
            end
        end,
        lists:sublist(Nicks, 5)
    ),
    numeric(Client, Server, <<"302">>, [], lists:join(<<" ">>, Entries)).

ison_nick(Nick) ->
    case find_nick(Nick) of
        #client{nick = Actual} ->
            Actual;
        undefined ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [#remote_client{nick = Actual}] -> Actual;
                [] -> undefined
            end
    end.

remote_userhost(Nick) ->
    case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
        [#remote_client{nick = Actual, host = Host, modes = Modes}] ->
            OperatorMarker =
                case maps:is_key($o, Modes) of
                    true -> <<"*">>;
                    false -> <<>>
                end,
            AwayMarker =
                case maps:is_key($a, Modes) of
                    true -> $-;
                    false -> $+
                end,
            {true, <<Actual/binary, OperatorMarker/binary, $=, AwayMarker, Host/binary>>};
        [] ->
            false
    end.

%% Select WHO matches and format RFC 2812 WHO replies.
who_command([], Client, Server) ->
    who_mask(<<"*">>, false, Client, Server);
who_command([Mask, Filter | _], Client, Server) ->
    who_mask(Mask, ircd_wire:fold(Filter) =:= <<"o">>, Client, Server);
who_command([Mask], Client, Server) ->
    who_mask(Mask, false, Client, Server).

who_mask(Mask, OperatorsOnly, Client, Server) ->
    ChannelKey = ircd_wire:fold(Mask),
    case mnesia:dirty_read(channel, ChannelKey) of
        [#channel{name = Name, members = Members, flags = Flags}] ->
            RemoteFlags = remote_channel_flags(Name),
            LocalMember = maps:is_key(Client#client.pid, Members),
            Visible =
                not (maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags)) andalso
                    (LocalMember orelse
                        not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags) orelse
                            maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags))),
            lists:foreach(
                fun(Pid) ->
                    case {Visible, mnesia:dirty_read(client, Pid)} of
                        {true, [Member]} ->
                            case
                                visible_member(Pid, Client, Members) andalso
                                    who_operator_matches(Pid, OperatorsOnly)
                            of
                                true -> who_reply(Member, Name, Client, Server);
                                false -> ok
                            end;
                        _ ->
                            ok
                    end
                end,
                maps:keys(Members)
            ),
            case Visible of
                true -> remote_who_channel(Name, Client, OperatorsOnly, Server);
                false -> ok
            end;
        [] ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{name = Name}] ->
                    remote_who_channel(Name, Client, OperatorsOnly, Server);
                [] ->
                    who_mask_nonchannel(Mask, OperatorsOnly, Client, Server)
            end
    end,
    numeric(Client, Server, <<"315">>, [Mask], <<"End of WHO list">>).

who_mask_nonchannel(Mask, OperatorsOnly, Client, Server) ->
    case find_nick(Mask) of
        #client{} = Member ->
            case
                user_visible(Member, Client) andalso
                    who_operator_matches(Member#client.pid, OperatorsOnly)
            of
                true -> who_reply(Member, <<"*">>, Client, Server);
                false -> ok
            end;
        undefined ->
            lists:foreach(
                fun(Pid) ->
                    case mnesia:dirty_read(client, Pid) of
                        [Member] ->
                            case
                                ready(Member) andalso who_matches(Mask, Member) andalso
                                    user_visible(Member, Client) andalso
                                    who_operator_matches(Member#client.pid, OperatorsOnly)
                            of
                                true ->
                                    who_reply(
                                        Member, who_channel(Member, Client), Client, Server
                                    );
                                false ->
                                    ok
                            end;
                        [] ->
                            ok
                    end
                end,
                mnesia:dirty_all_keys(client)
            ),
            remote_who_mask(Mask, OperatorsOnly, Client, Server)
    end.

remote_who_channel(Name, Client, OperatorsOnly, Server) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{name = Canonical, members = Members, flags = Flags}] ->
            LocalMember =
                case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
                    [#channel{members = LocalMembers}] ->
                        maps:is_key(Client#client.pid, LocalMembers);
                    [] ->
                        false
                end,
            Visible =
                not maps:is_key($a, Flags) andalso
                    (LocalMember orelse not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))),
            case Visible of
                false ->
                    ok;
                true ->
                    lists:foreach(
                        fun({NickKey, {_Peer, Roles}}) ->
                            case mnesia:dirty_read(remote_client, NickKey) of
                                [
                                    #remote_client{
                                        nick = Nick,
                                        user = User,
                                        host = Host,
                                        real = Real,
                                        peer = Peer,
                                        modes = Modes
                                    }
                                ] ->
                                    IsOperator = maps:is_key($o, Modes),
                                    case
                                        remote_user_visible_to_requester(NickKey, Modes, Client) andalso
                                            (not OperatorsOnly orelse IsOperator)
                                    of
                                        true ->
                                            Away =
                                                case maps:is_key($a, Modes) of
                                                    true -> $G;
                                                    false -> $H
                                                end,
                                            UserOperator =
                                                case IsOperator of
                                                    true -> $*;
                                                    false -> <<>>
                                                end,
                                            ChannelStatus =
                                                case
                                                    {
                                                        lists:member(operator, Roles),
                                                        lists:member(voice, Roles)
                                                    }
                                                of
                                                    {true, _} -> <<$@>>;
                                                    {false, true} -> <<$+>>;
                                                    _ -> <<>>
                                                end,
                                            Status = list_to_binary([
                                                Away, UserOperator, ChannelStatus
                                            ]),
                                            numeric(
                                                Client,
                                                Server,
                                                <<"352">>,
                                                [Canonical, User, Host, Peer, Nick, Status],
                                                [<<"0 ">>, Real]
                                            );
                                        false ->
                                            ok
                                    end;
                                [] ->
                                    ok
                            end
                        end,
                        maps:to_list(Members)
                    )
            end;
        [] ->
            ok
    end.

who_operator_matches(_Pid, false) ->
    true;
who_operator_matches(Pid, true) ->
    maps:is_key($o, user_modes(Pid)).

remote_who_mask(Mask, OperatorsOnly, Client, Server) ->
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(remote_client, Key) of
                [
                    #remote_client{
                        nick = Nick,
                        user = User,
                        host = Host,
                        real = Real,
                        peer = Peer,
                        modes = Modes
                    }
                ] ->
                    Matches =
                        (Mask =:= <<"*">> orelse wildcard_match(Mask, Nick) orelse
                            wildcard_match(Mask, User) orelse wildcard_match(Mask, Host) orelse
                            wildcard_match(Mask, Real)),
                    Visible = remote_user_visible_to_requester(
                        ircd_wire:fold(Nick), Modes, Client
                    ),
                    Operator = maps:is_key($o, Modes),
                    Away = maps:is_key($a, Modes),
                    case Matches andalso Visible andalso (not OperatorsOnly orelse Operator) of
                        true ->
                            Status =
                                list_to_binary([
                                    case Away of
                                        true -> $G;
                                        false -> $H
                                    end,
                                    case Operator of
                                        true -> $*;
                                        false -> <<>>
                                    end
                                ]),
                            numeric(
                                Client,
                                Server,
                                <<"352">>,
                                [<<"*">>, User, Host, Peer, Nick, Status],
                                [<<"0 ">>, Real]
                            );
                        false ->
                            ok
                    end;
                [] ->
                    ok
            end
        end,
        mnesia:dirty_all_keys(remote_client)
    ).

who_matches(<<"*">>, _) ->
    true;
who_matches(Mask, #client{nick = Nick, user = User, host = Host, real = Real}) ->
    Identity = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
    wildcard_match(Mask, Nick) orelse wildcard_match(Mask, User) orelse
        wildcard_match(Mask, Host) orelse wildcard_match(Mask, Real) orelse
        wildcard_match(Mask, Identity).

who_channel(#client{channels = Keys}, #client{pid = RequesterPid}) ->
    case
        [
            Name
         || Key <- Keys,
            [#channel{name = Name, members = Members, flags = Flags}] <-
                [mnesia:dirty_read(channel, Key)],
            not maps:is_key($a, Flags),
            maps:is_key(RequesterPid, Members) orelse
                not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))
        ]
    of
        [Name | _] -> Name;
        [] -> <<"*">>
    end.

who_reply(
    #client{nick = Nick, user = User, host = Host, real = Real} = Member,
    Channel,
    Requester,
    Server
) ->
    Away =
        case Member#client.away of
            undefined -> <<"H">>;
            _ -> <<"G">>
        end,
    Roles =
        case mnesia:dirty_read(channel, ircd_wire:fold(Channel)) of
            [#channel{members = Members}] -> maps:get(Member#client.pid, Members, []);
            [] -> []
        end,
    ChannelStatus =
        case {lists:member(operator, Roles), lists:member(voice, Roles)} of
            {true, _} -> <<"@">>;
            {false, true} -> <<"+">>;
            _ -> <<>>
        end,
    UserOperator =
        case maps:is_key($o, user_modes(Member#client.pid)) of
            true -> <<"*">>;
            false -> <<>>
        end,
    Status = <<Away/binary, UserOperator/binary, ChannelStatus/binary>>,
    numeric(
        Requester,
        Server,
        <<"352">>,
        [Channel, User, Host, Server, Nick, Status],
        [<<"0 ">>, Real]
    ).

%% Produce the local server's WHOIS numerics for one nickname mask.
whois(Nick, Client, Server) ->
    case find_nick(Nick) of
        #client{
            pid = TargetPid,
            nick = Actual,
            user = User,
            host = Host,
            real = Real,
            away = Away,
            channels = Channels
        } = Target when User =/= undefined ->
            case user_visible(Target, Client) of
                true ->
                    numeric(Client, Server, <<"311">>, [Actual, User, Host, <<"*">>], Real),
                    case Away of
                        undefined -> ok;
                        _ -> numeric(Client, Server, <<"301">>, [Actual], Away)
                    end,
                    whois_channels(Channels, TargetPid, Actual, Client, Server),
                    numeric(Client, Server, <<"312">>, [Actual, Server], <<"IRC server">>),
                    Idle =
                        case mnesia:dirty_read(activity, TargetPid) of
                            [#activity{last = Last}] ->
                                max(0, erlang:system_time(second) - Last);
                            [] ->
                                0
                        end,
                    numeric(
                        Client,
                        Server,
                        <<"317">>,
                        [Actual, integer_to_binary(Idle)],
                        <<"seconds idle">>
                    );
                false ->
                    numeric(Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>)
            end;
        _ ->
            remote_whois(Nick, Client, Server)
    end,
    numeric(Client, Server, <<"318">>, [Nick], <<"End of WHOIS list">>).

remote_whois(Nick, Client, Server) ->
    case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
        [
            #remote_client{
                nick = Actual,
                user = User,
                host = Host,
                peer = Peer,
                real = Real,
                modes = Modes
            }
        ] ->
            case remote_user_visible_to_requester(ircd_wire:fold(Actual), Modes, Client) of
                false ->
                    numeric(Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>);
                true ->
                    numeric(Client, Server, <<"311">>, [Actual, User, Host, <<"*">>], Real),
                    numeric(Client, Server, <<"312">>, [Actual, Peer], <<"IRC server">>),
                    case maps:is_key($a, Modes) of
                        true -> numeric(Client, Server, <<"301">>, [Actual], <<"is away">>);
                        false -> ok
                    end,
                    case maps:is_key($o, Modes) of
                        true ->
                            numeric(
                                Client,
                                Server,
                                <<"313">>,
                                [Actual],
                                <<"is an IRC operator">>
                            );
                        false ->
                            ok
                    end
            end;
        [] ->
            numeric(Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>)
    end.

whois_channels(Keys, Pid, Nick, Client, Server) ->
    Entries = lists:filtermap(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{name = Name, members = Members, flags = Flags}] ->
                    Roles = maps:get(Pid, Members, []),
                    Visible =
                        not maps:is_key($a, Flags) andalso
                            (maps:is_key(Client#client.pid, Members) orelse
                                not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))),
                    case Visible of
                        false ->
                            false;
                        true ->
                            Prefix =
                                case {lists:member(operator, Roles), lists:member(voice, Roles)} of
                                    {true, _} -> <<"@">>;
                                    {false, true} -> <<"+">>;
                                    _ -> <<>>
                                end,
                            {true, <<Prefix/binary, Name/binary>>}
                    end;
                [] ->
                    false
            end
        end,
        Keys
    ),
    case Entries of
        [] -> ok;
        _ -> whois_channel_lines(Entries, [], 0, Nick, Client, Server)
    end.

whois_channel_lines([], [], _, _, _, _) ->
    ok;
whois_channel_lines([], Acc, _, Nick, Client, Server) ->
    emit_whois_channels(lists:reverse(Acc), Nick, Client, Server);
whois_channel_lines([Entry | Rest], [], _, Nick, Client, Server) ->
    whois_channel_lines(Rest, [Entry], byte_size(Entry), Nick, Client, Server);
whois_channel_lines([Entry | Rest], Acc, Size, Nick, Client, Server) when
    Size + byte_size(Entry) + 1 =< 350
->
    whois_channel_lines(
        Rest,
        [Entry | Acc],
        Size + byte_size(Entry) + 1,
        Nick,
        Client,
        Server
    );
whois_channel_lines([Entry | Rest], Acc, _, Nick, Client, Server) ->
    emit_whois_channels(lists:reverse(Acc), Nick, Client, Server),
    whois_channel_lines([Entry | Rest], [], 0, Nick, Client, Server).

emit_whois_channels(Entries, Nick, Client, Server) ->
    numeric(Client, Server, <<"319">>, [Nick], lists:join(<<" ">>, Entries)).

%% Keep the most recent user identity for lookup after a nickname is released.
save_whowas(#client{nick = Nick, user = User, host = Host, real = Real}, Server) ->
    Time = erlang:system_time(second),
    Key = {ircd_wire:fold(Nick), -Time, erlang:unique_integer([positive])},
    mnesia:dirty_write(#whowas{
        key = Key,
        nick = Nick,
        user = User,
        host = Host,
        real = Real,
        server = Server,
        time = Time
    }).

whowas_options([]) ->
    {all, undefined};
whowas_options([Count | Rest]) ->
    Target =
        case Rest of
            [Value | _] -> Value;
            [] -> undefined
        end,
    try binary_to_integer(Count) of
        Limit -> {Limit, Target}
    catch
        error:badarg -> {all, Target}
    end.

whowas_reply(Nick, Count, Client, Server) ->
    Folded = ircd_wire:fold(Nick),
    History = lists:sort(
        fun(#whowas{time = Left}, #whowas{time = Right}) -> Left > Right end,
        [
            Entry
         || Key <- mnesia:dirty_all_keys(whowas),
            [Entry = #whowas{nick = StoredNick}] <- [mnesia:dirty_read(whowas, Key)],
            ircd_wire:fold(StoredNick) =:= Folded
        ]
    ),
    Results =
        case Count of
            Limit when is_integer(Limit), Limit > 0 -> lists:sublist(History, Limit);
            _ -> History
        end,
    case Results of
        [] ->
            numeric(Client, Server, <<"406">>, [Nick], <<"There was no such nickname">>);
        _ ->
            lists:foreach(
                fun(Entry) ->
                    #whowas{
                        nick = OldNick,
                        user = User,
                        host = Host,
                        real = Real,
                        server = OldServer
                    } = Entry,
                    numeric(
                        Client,
                        Server,
                        <<"314">>,
                        [OldNick, User, Host, <<"*">>],
                        Real
                    ),
                    numeric(
                        Client,
                        Server,
                        <<"312">>,
                        [OldNick, OldServer],
                        <<"IRC server">>
                    )
                end,
                Results
            )
    end.

split(Value) -> binary:split(Value, <<",">>, [global, trim_all]).
prefix(#client{nick = Nick, user = User, host = Host}) -> [Nick, <<"!">>, User, <<"@">>, Host].

propagate_introduction(
    #client{nick = Nick, user = User, host = Host, real = Real, pid = Pid}, Server
) ->
    Modes = user_mode_string(user_modes(Pid)),
    server_broadcast(
        ircd_wire:line(
            Server,
            <<"NICK">>,
            [Nick, <<"0">>, User, Host, <<"1">>, Modes],
            Real
        )
    ).

propagate_nick_change(Client, Nick) ->
    server_broadcast(ircd_wire:line(prefix(Client), <<"NICK">>, [Nick], none)).

propagate_away(Client, none) ->
    server_broadcast(ircd_wire:line(prefix(Client), <<"AWAY">>, [], none));
propagate_away(Client, Message) ->
    server_broadcast(ircd_wire:line(prefix(Client), <<"AWAY">>, [], Message)).

propagate_quit(Client, Reason) ->
    server_broadcast(ircd_wire:line(prefix(Client), <<"QUIT">>, [], Reason)).

server_broadcast(Line) ->
    try ircd_links:send_all(iolist_to_binary(Line)) of
        _ -> ok
    catch
        exit:_ -> ok
    end.

propagate_topic(Client, Name, Topic) ->
    server_broadcast(ircd_wire:line(prefix(Client), <<"TOPIC">>, [Name], Topic)).

propagate_channel_mode(Client, Name, Mode, Args) ->
    server_broadcast(ircd_wire:line(prefix(Client), <<"MODE">>, [Name, Mode | Args], none)).

propagate_channel_kick(Client, Name, Nick, Reason) ->
    server_broadcast(ircd_wire:line(prefix(Client), <<"KICK">>, [Name, Nick], Reason)).

propagate_join(Client, Name, Roles) ->
    Server = maps:get(name, persistent_term:get({?MODULE, config})),
    server_broadcast(ircd_wire:line(prefix(Client), <<"JOIN">>, [Name], none)),
    Member = iolist_to_binary(njoin_member(Client, Roles)),
    server_broadcast(ircd_wire:line(Server, <<"NJOIN">>, [Name], Member)),
    case mnesia:dirty_read(channel, ircd_wire:fold(Name)) of
        [#channel{flags = Flags, password = Password, limit = Limit, lists = Lists}] ->
            lists:foreach(
                fun(Line) -> server_broadcast(Line) end,
                channel_mode_burst(Name, Flags, Password, Limit, Lists, Server)
            );
        [] ->
            ok
    end.

propagate_channel_message(Name, Text, Command, Client) ->
    case mnesia:dirty_read(remote_channel, ircd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Line = iolist_to_binary(ircd_wire:line(prefix(Client), Command, [Name], Text)),
            Peers = lists:usort([Peer || {_Nick, {Peer, _Roles}} <- maps:to_list(Members)]),
            lists:foreach(fun(Peer) -> _ = ircd_links:send(Peer, Line) end, Peers),
            ok;
        [] ->
            ok
    end.

numeric(#client{pid = Pid, nick = Nick}, Server, Number, Params, Text) ->
    send(Pid, Server, Number, [Nick | Params], Text).
broadcast(Pids, Prefix, Command, Middle, Tail) ->
    lists:foreach(fun(Pid) -> send(Pid, Prefix, Command, Middle, Tail) end, Pids).
send(Pid, Prefix, Command, Middle, Tail) ->
    Line = ircd_wire:line(Prefix, Command, Middle, Tail),
    Pid ! {irc, Line},
    update_connection_stats(Pid, sent_messages, sent_bytes, iolist_size(Line)),
    ok.
