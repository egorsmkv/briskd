-module(ircd_state_client).
-export([
    client/1,
    identified/1,
    connection_stats/1,
    disconnect/3,
    find_nick/1,
    initial_user_modes/1,
    pass/3,
    put_connection_stats/2,
    ready/1,
    save_identity/3,
    send_welcome/2,
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

%% A client is registered once NICK, USER (and PASS when required) are done
%% and the welcome has been sent. While CAP negotiation holds the welcome
%% (IRCv3: registration MUST NOT complete before CAP END) the client is not
%% ready: commands that need registration get 451 and peers do not see it.
ready(#client{pid = Pid} = Client) ->
    identified(Client) andalso ircd_cap:welcomed(Pid).

%% @doc NICK, USER, and any required PASS have been accepted.
identified(#client{nick = Nick, user = User, pass = Pass}) ->
    HasIdentity = Nick =/= <<"*">> andalso User =/= undefined,
    Password = persistent_term:get({ircd_state, client_password}, null),
    Authenticated = Password =:= null orelse Pass =:= true,
    HasIdentity andalso Authenticated.

%% Find a registered nickname using the RFC1459 case-folding rules.
%% `ircd_nicks` is the folded-nick index maintained by the state process.
find_nick(Nick) ->
    case ets:lookup(ircd_nicks, ircd_wire:fold(Nick)) of
        [{_, Pid}] ->
            case mnesia:dirty_read(client, Pid) of
                [#client{nick = Stored} = Client] when Stored =/= <<"*">> ->
                    case ircd_wire:fold(Stored) =:= ircd_wire:fold(Nick) of
                        true -> Client;
                        false -> undefined
                    end;
                _ ->
                    undefined
            end;
        [] ->
            undefined
    end.

%% Persist nickname or USER changes and send the registration welcome once ready.
save_identity(Old, New, Server) ->
    Current = client(Old#client.pid),
    Updated = New#client{
        nick = stored_nick(New#client.nick, Current#client.nick),
        user = stored_field(New#client.user, Current#client.user),
        real = stored_field(New#client.real, Current#client.real),
        away = stored_field(New#client.away, Current#client.away),
        channels = Current#client.channels
    },
    ok = index_nick(Updated#client.pid, Current#client.nick, Updated#client.nick),
    case ready(Current) andalso Current#client.nick =/= Updated#client.nick of
        true -> save_whowas(Current, Server);
        false -> ok
    end,
    mnesia:dirty_write(Updated),
    case not identified(Old) andalso identified(Updated) of
        true ->
            case maps:get(negotiating, ircd_cap:state(Updated#client.pid)) of
                true ->
                    ok;
                false ->
                    welcome = ircd_cap:finish(Updated#client.pid, true),
                    send_welcome(Updated, Server)
            end;
        false ->
            ok
    end.

%% @doc Send the numeric burst that completes registration.
%% The caller marks the connection welcomed before this runs.
send_welcome(#client{nick = Nick, user = User, host = Host} = Client, Server) ->
    ircd_state_link:propagate_introduction(Client, Server),
    ircd_state_v3:registered(Client, Server),
    logger:info(#{event => client_registered, nick => Nick, user => User, host => Host}),
    ircd_state_send:numeric(Client, Server, <<"001">>, [], [
        <<"Welcome to IRC ">>, ircd_state_send:prefix(Client)
    ]),
    ircd_state_send:numeric(
        Client,
        Server,
        <<"002">>,
        [],
        [<<"Your host is ">>, Server, <<", running version 0.1.0">>]
    ),
    ircd_state_send:numeric(
        Client,
        Server,
        <<"003">>,
        [],
        [
            <<"This server was created ">>,
            persistent_term:get({ircd_state, started})
        ]
    ),
    ircd_state_send:numeric(
        Client,
        Server,
        <<"004">>,
        [Server, <<"0.1.0">>, <<"iowB">>, <<"abeIimnpsqrKltkov">>],
        none
    ),
    ircd_isupport:send(Client, Server, ircd_isupport:tokens()),
    ircd_state_meta:on_registered(Client, Server),
    ircd_state_info:motd([], Client, Server).

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
            ),
            ircd_state_history:note_user_event(
                Channels, <<"QUIT">>, ircd_state_send:prefix(Client), Reason
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
    ok = forget_nick(Pid, Client#client.nick),
    mnesia:dirty_delete(client, Pid),
    mnesia:dirty_delete(activity, Pid),
    mnesia:dirty_delete(user_modes, Pid),
    case ets:whereis(ircd_admins) of
        undefined -> ok;
        _ -> ets:delete(ircd_admins, Pid)
    end,
    ircd_state_v3:disconnect(Client),
    ircd_cap:disconnect(Pid),
    remove_connection_stats(Pid),
    logger:info(#{
        event => client_disconnected,
        nick => Client#client.nick,
        host => Client#client.host
    }).

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
user_visible(#client{pid = Pid, channels = Channels} = Target, #client{pid = RequesterPid}) ->
    %% A client whose registration is still held by CAP negotiation is not
    %% visible to anyone else yet.
    ready(Target) andalso
        (not maps:is_key($i, user_modes(Pid)) orelse
            lists:any(
                fun(Key) ->
                    case mnesia:dirty_read(channel, Key) of
                        [#channel{members = Members}] -> maps:is_key(RequesterPid, Members);
                        [] -> false
                    end
                end,
                Channels
            )).

%% `<<"*">>` means the caller is not changing the nickname.
stored_nick(<<"*">>, Current) -> Current;
stored_nick(Value, Value) -> Value;
stored_nick(Value, _Current) -> ircd_wire:retain(Value).

%% `undefined` means the caller is not changing this field.
%% Equal binaries keep the copy already owned by the client record.
stored_field(undefined, Current) -> Current;
stored_field(Value, Value) -> Value;
stored_field(Value, _Current) -> ircd_wire:retain(Value).

index_nick(Pid, OldNick, NewNick) ->
    OldKey = nick_key(OldNick),
    NewKey = nick_key(NewNick),
    case OldKey =:= NewKey of
        true ->
            ok;
        false ->
            forget_key(OldKey, Pid),
            remember_key(NewKey, Pid)
    end.

forget_nick(Pid, Nick) ->
    forget_key(nick_key(Nick), Pid).

nick_key(<<"*">>) -> undefined;
nick_key(Nick) when is_binary(Nick) -> ircd_wire:fold(Nick);
nick_key(_) -> undefined.

forget_key(undefined, _Pid) ->
    ok;
forget_key(Key, Pid) ->
    case ets:lookup(ircd_nicks, Key) of
        [{_, Pid}] ->
            ets:delete(ircd_nicks, Key),
            ok;
        _ ->
            ok
    end.

remember_key(undefined, _Pid) ->
    ok;
remember_key(Key, Pid) ->
    ets:insert(ircd_nicks, {Key, Pid}),
    ok.

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
