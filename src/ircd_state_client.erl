-module(ircd_state_client).
-export([
    client/1,
    connection_stats/1,
    disconnect/3,
    find_nick/1,
    initial_user_modes/1,
    pass/3,
    put_connection_stats/2,
    ready/1,
    save_identity/3,
    touch_activity/1,
    update_connection_stats/4,
    user_modes/1,
    user_visible/2
]).
-include("ircd_state.hrl").

%% @doc Local client identity, registration, visibility, and connection stats.

%% Retrieve the Mnesia record associated with a live session process.
client(Pid) ->
    [Client] = mnesia:dirty_read(client, Pid),
    Client.

ready(#client{nick = Nick, user = User, pass = Pass}) ->
    HasIdentity = Nick =/= <<"*">> andalso User =/= undefined,
    Password = persistent_term:get({ircd_state, client_password}, null),
    Authenticated = Password =:= null orelse Pass =:= true,
    HasIdentity andalso Authenticated.

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
            ircd_state_link:propagate_introduction(Updated, Server),
            ircd_state_send:numeric(Updated, Server, <<"001">>, [], [
                <<"Welcome to IRC ">>, ircd_state_send:prefix(New)
            ]),
            ircd_state_send:numeric(
                Updated,
                Server,
                <<"002">>,
                [],
                [<<"Your host is ">>, Server, <<", running version 0.1.0">>]
            ),
            ircd_state_send:numeric(
                Updated,
                Server,
                <<"003">>,
                [],
                [
                    <<"This server was created ">>,
                    persistent_term:get({ircd_state, started})
                ]
            ),
            ircd_state_send:numeric(
                Updated,
                Server,
                <<"004">>,
                [Server, <<"0.1.0">>, <<"iow">>, <<"abeIimnpsqrKltkov">>],
                none
            ),
            ircd_state_info:motd([], Updated, Server);
        false ->
            ok
    end.

pass(Params, Client, Server) ->
    case identity_ready(Client) of
        true ->
            ircd_state_send:numeric(Client, Server, <<"462">>, [], <<"You may not reregister">>);
        false ->
            pass_unregistered(Params, Client, Server)
    end.

pass_unregistered([], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"PASS">>], <<"Not enough parameters">>);
pass_unregistered(_, #client{pass = Pass} = Client, Server) when Pass =/= undefined ->
    ircd_state_send:numeric(Client, Server, <<"462">>, [], <<"You may not reregister">>);
pass_unregistered([Given | _], Client, Server) ->
    Expected = persistent_term:get({ircd_state, client_password}, null),
    case Expected =:= null orelse ircd_config:secret_match(Given, Expected) of
        true ->
            save_identity(Client, Client#client{pass = true}, Server);
        false ->
            mnesia:dirty_write(Client#client{pass = false}),
            ircd_state_send:numeric(Client, Server, <<"464">>, [], <<"Password incorrect">>)
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
put_connection_stats(Pid, _Entry) ->
    ets:insert(ircd_connection_stats, {Pid, erlang:monotonic_time(second), 0, 0, 0, 0}).

remove_connection_stats(Pid) ->
    ets:delete(ircd_connection_stats, Pid).

connection_stats(Pid) ->
    case ets:lookup(ircd_connection_stats, Pid) of
        [{Pid, ConnectedAt, SentMessages, SentBytes, RecvMessages, RecvBytes}] ->
            #{
                connected_at => ConnectedAt,
                sent_messages => SentMessages,
                sent_bytes => SentBytes,
                recv_messages => RecvMessages,
                recv_bytes => RecvBytes
            };
        [] ->
            #{}
    end.

update_connection_stats(Pid, MessagesKey, BytesKey, Bytes) ->
    case {MessagesKey, BytesKey} of
        {sent_messages, sent_bytes} -> update_connection_stats_counter(Pid, 3, 4, Bytes);
        {recv_messages, recv_bytes} -> update_connection_stats_counter(Pid, 5, 6, Bytes);
        _ -> ok
    end.

update_connection_stats_counter(Pid, MessagesPosition, BytesPosition, Bytes) ->
    case ets:member(ircd_connection_stats, Pid) of
        true ->
            ets:update_counter(
                ircd_connection_stats,
                Pid,
                [{MessagesPosition, 1}, {BytesPosition, Bytes}]
            );
        false ->
            ok
    end.

%% Broadcast QUIT, leave joined channels, and delete all per-client Mnesia rows.
disconnect(#client{pid = Pid, channels = Channels} = Client, Reason, Server) ->
    case ready(Client) of
        true ->
            save_whowas(Client, Server),
            ircd_state_net:hold_nick(Client#client.nick),
            ircd_state_link:propagate_quit(Client, Reason);
        false ->
            ok
    end,
    case ready(Client) of
        true ->
            ircd_state_send:broadcast(
                quit_recipients(Client), ircd_state_send:prefix(Client), <<"QUIT">>, [], Reason
            );
        false ->
            ok
    end,
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{flags = Flags}] ->
                    ircd_state_channel:leave(
                        Key, Client, <<"PART">>, none, maps:is_key($a, Flags), false
                    );
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
