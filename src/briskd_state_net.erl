-module(briskd_state_net).
-moduledoc """
Server topology, services, nickname and channel holds, `CAP` replies, and
operator server commands.

The functions run only inside the `m:briskd_state` process, which is the single
writer of the `known_server` and `service` Mnesia rows and of the
`briskd_holds`, `briskd_inbound_peers`, and `briskd_outbound_ready` ETS tables. All
of that state is transient and is cleared on restart.

Topology follows RFC 2813: an adjacent peer is registered with hop 1 by
`register_adjacent/4`, servers behind it arrive as `SERVER` introductions
(`introduce_server/6`, placement checked by `briskd_route:accept_server/4`), and
`split/3` removes a lost server together with every server, user, and service
behind it. Names lost in a split or collision are held for the
`resource_delay` period (RFC 2813 section 5.7) so a local client cannot take
them over immediately.
""".
-export([
    configured_peer/1,
    expire_holds/0,
    cap/3,
    notify_cap_changes/2,
    channel_blocked/1,
    hold_channel/1,
    hold_nick/1,
    hold_nick/2,
    import_service/3,
    introduce_server/6,
    burst_server_lines/1,
    links_entries/0,
    nick_blocked/1,
    nick_blocked/2,
    reclaim/3,
    oper_command/4,
    register_adjacent/4,
    release_link/2,
    drop_server/3,
    servlist/4,
    service_count/0,
    remove_remote_user/1,
    split/3,
    squery/3,
    remote_squery/3
]).
-include("briskd_state.hrl").

-define(INBOUND, briskd_inbound_peers).

-doc """
Record an authenticated, directly connected server peer.

Writes a `known_server` row for `Name` with hop 1, the local server as parent,
and the link's `Token`, then makes the link reachable by `m:briskd_links`:
`Kind` `inbound` stores `Pid` (the `m:briskd_session` serving the link) in
`briskd_inbound_peers`; `outbound` stores it (the `m:briskd_link` worker) in
`briskd_outbound_ready`.
""".
-spec register_adjacent(binary(), binary(), inbound | outbound, pid()) ->
    ok | {error, duplicate_peer}.
register_adjacent(Name, Token, Kind, Pid) ->
    Fold = briskd_wire:fold(Name),
    Owners = [
        Owner
     || {_, {Owner, _}} <-
            ets:lookup(?INBOUND, Fold) ++ ets:lookup(briskd_outbound_ready, Fold)
    ],
    case [Owner || Owner <- Owners, Owner =/= Pid] of
        [_ | _] ->
            {error, duplicate_peer};
        [] ->
            register_adjacent_new(Name, Token, Kind, Pid)
    end.

register_adjacent_new(Name, Token, Kind, Pid) ->
    Local = local_name(),
    Record = #known_server{
        key = briskd_wire:fold(Name),
        name = Name,
        hop = 1,
        token = Token,
        adjacent = Name,
        parent = Local,
        info = <<"Direct peer">>
    },
    mnesia:dirty_write(briskd_wire:retain_fields(Record)),
    case Kind of
        inbound -> ets:insert(?INBOUND, {briskd_wire:fold(Name), {Pid, Name}});
        outbound -> ets:insert(briskd_outbound_ready, {briskd_wire:fold(Name), {Pid, Name}})
    end,
    briskd_population:on_server_change(),
    ok.

-doc """
Import a `SERVER` introduction (RFC 2813 section 4.1.2) received on the
adjacent link `Ingress`.

`Prefix` names the new server's parent; `undefined` means the parent is
`Ingress`. `HopBin` must be a non-negative decimal and `Token` 1 to 16 digits,
otherwise the result is `{error, invalid_server}`. Placement is decided by
`briskd_route:accept_server/4`, whose errors (`loop`, `duplicate_route`,
`bad_hop`, `unknown_parent`, `invalid_server`) are returned unchanged. An
accepted server is stored as a `known_server` row and announced to every
other peer with its hop count increased by one.
""".
-spec introduce_server(binary(), binary(), binary(), binary(), binary(), binary()) ->
    ok | {error, atom()}.
introduce_server(Ingress, Prefix, Name, HopBin, Token, Info) ->
    case {briskd_route:valid_decimal(HopBin), valid_token(Token)} of
        {false, _} ->
            {error, invalid_server};
        {_, false} ->
            {error, invalid_server};
        {true, true} ->
            Parent =
                case Prefix of
                    undefined -> Ingress;
                    _ -> Prefix
                end,
            Intro = #{
                name => Name,
                hop => binary_to_integer(HopBin),
                token => Token,
                parent => Parent,
                info => Info
            },
            case briskd_route:accept_server(local_name(), Ingress, Intro, known_maps()) of
                {ok, Map} ->
                    case peer_server_room(Ingress, Name) of
                        false ->
                            {error, too_many_remote_servers};
                        true ->
                            store_server(Map),
                            announce_server(Map, Ingress),
                            ok
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-doc """
Remove a remote user after a nickname collision.

Local clients sharing a channel with the user see a `QUIT` with reason
`Nick collision`. The `remote_client` row, its channel memberships, its
MONITOR presence, and its metadata are dropped; a remote channel left empty
is deleted and its name is held when no local channel has it. The nickname
is held. Nothing is sent to peers; the caller announces the collision.
""".
-spec remove_remote_user(#remote_client{}) -> ok.
remove_remote_user(Remote) ->
    drop_remote_user(Remote, <<"Nick collision">>).

-doc """
Remove the server `Lost` and everything behind it after `SQUIT` or link loss
(RFC 2813 section 4.1.6).

Each remote user whose home server is lost is removed as in
`remove_remote_user/1`, with `Reason` as the `QUIT` text; all of those
`QUIT`s go to local clients in one IRCv3 `netsplit` batch whose parameters are
`Lost`'s parent (or this server) and `Lost`. Services homed on a lost server
are deleted. For every lost server the `known_server` row is deleted and
`SQUIT <name> :<Reason>` is sent to every peer except `Except`, the ingress
link (`undefined` for a split started on this server). When `Lost` is an
adjacent peer its peer table entries are removed so no further lines are
sent to it.
""".
-spec split(binary(), binary(), undefined | binary()) -> ok.
split(Lost, Reason, Except) ->
    Folds = [briskd_wire:fold(Name) || Name <- lost_names(Lost)],
    %% Every QUIT caused by this split goes in one `netsplit` batch.
    %% The two parameters are the servers on either side of the split.
    Uplink =
        case mnesia:dirty_read(known_server, briskd_wire:fold(Lost)) of
            [#known_server{parent = Parent}] when is_binary(Parent) -> Parent;
            _ -> local_name()
        end,
    briskd_state_send:begin_batch(<<"netsplit">>, [Uplink, Lost], [<<"QUIT">>]),
    try
        lists:foreach(
            fun(Key) ->
                case mnesia:dirty_read(remote_client, Key) of
                    [#remote_client{} = Remote] ->
                        case lost_client(Remote, Folds) of
                            true -> drop_remote_user(Remote, Reason);
                            false -> ok
                        end;
                    _ ->
                        ok
                end
            end,
            briskd_state:table_keys(remote_client)
        )
    after
        briskd_state_send:end_batch()
    end,
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(service, Key) of
                [#service{server = Server}] ->
                    case lists:member(briskd_wire:fold(Server), Folds) of
                        true ->
                            mnesia:dirty_delete(service, Key),
                            briskd_state_link:untrack_peer_item(service, Key);
                        false ->
                            ok
                    end;
                _ ->
                    ok
            end
        end,
        briskd_state:table_keys(service)
    ),
    lists:foreach(
        fun(Name) ->
            ServerKey = briskd_wire:fold(Name),
            mnesia:dirty_delete(known_server, ServerKey),
            briskd_state_link:untrack_peer_item(server, ServerKey),
            Line = briskd_wire:line(local_name(), <<"SQUIT">>, [Name], Reason),
            _ = briskd_links:send_except(Except, Line),
            case ServerKey =:= briskd_wire:fold(Lost) of
                true ->
                    ets:delete(?INBOUND, ServerKey),
                    ets:delete(briskd_outbound_ready, ServerKey);
                false ->
                    ok
            end
        end,
        [Name || Name <- lost_names(Lost)]
    ),
    briskd_population:on_server_change(),
    ok.

-doc """
Forget the direction rows of `Name` that `Pid` owns.

`split` when that was the last direction, so the caller removes the peer's
users. `kept` when another direction is still registered. `absent` when `Pid`
owns neither row: a session that lost the name, or one that already left,
must not split whoever holds it now.
""".
-spec release_link(binary(), pid()) -> split | kept | absent.
release_link(Name, Pid) ->
    Fold = briskd_wire:fold(Name),
    OwnIn = owns_direction(?INBOUND, Fold, Pid),
    OwnOut = owns_direction(briskd_outbound_ready, Fold, Pid),
    case OwnIn orelse OwnOut of
        false ->
            absent;
        true ->
            case OwnIn of
                true -> ets:delete(?INBOUND, Fold);
                false -> ok
            end,
            case OwnOut of
                true -> ets:delete(briskd_outbound_ready, Fold);
                false -> ok
            end,
            case
                ets:lookup(?INBOUND, Fold) =:= [] andalso
                    ets:lookup(briskd_outbound_ready, Fold) =:= []
            of
                true -> split;
                false -> kept
            end
    end.

owns_direction(Table, Fold, Pid) ->
    case ets:lookup(Table, Fold) of
        [{_, {Pid, _}}] -> true;
        _ -> false
    end.

%% Link processes registered for an adjacent peer. Captured before `split/3`,
%% which removes the rows.
adjacent_pids(Name) ->
    Fold = briskd_wire:fold(Name),
    [
        Pid
     || Table <- [?INBOUND, briskd_outbound_ready],
        {_, {Pid, _}} <- ets:lookup(Table, Fold),
        is_pid(Pid)
    ].

-doc """
Remove server `Name` and close a direct link when `Name` is adjacent.

The owner pids are taken before `split/3` deletes them. Those processes are
then stopped with reason `squit`, so the socket cannot keep sending as the
peer after the registration is gone. A name that is not a direct link has no
owner and only the split runs.
""".
-spec drop_server(binary(), binary(), undefined | binary()) -> ok.
drop_server(Name, Reason, Except) ->
    Pids = adjacent_pids(Name),
    case Pids of
        [] ->
            ok;
        _ ->
            briskd_state_link:flush_netjoin(Name),
            ok = briskd_state_link:forget_peer_batches(Name)
    end,
    split(Name, Reason, Except),
    lists:foreach(fun(Pid) -> exit(Pid, squit) end, Pids),
    ok.

-doc """
Hold a nickname lost in a split or collision so it cannot be taken at once
(RFC 2813 section 5.7).
""".
-spec hold_nick(binary()) -> ok.
hold_nick(Nick) ->
    briskd_net_holds:hold_nick(Nick).

-doc """
Hold the nickname a local client gave up, owned by that client's `RECLAIM`
secret or account.
""".
-spec hold_nick(binary(), #client{}) -> ok.
hold_nick(Nick, Client) ->
    briskd_net_holds:hold_nick(Nick, Client).

-doc """
Handle `RECLAIM <secret>`: remember the SHA-256 of a client-chosen secret
for this connection.
""".
-spec reclaim([binary()], #client{}, binary()) -> ok.
reclaim(Params, Client, Server) ->
    briskd_net_holds:reclaim(Params, Client, Server).

-doc """
Hold a channel name whose last remote member was lost, under the same rules
as `hold_nick/1` (the RFC 2811 channel delay).
""".
-spec hold_channel(binary()) -> ok.
hold_channel(Name) ->
    briskd_net_holds:hold_channel(Name).

-doc """
True while a hold set by `hold_nick/1` is still in force for `Nick`.
""".
-spec nick_blocked(binary()) -> boolean().
nick_blocked(Nick) ->
    briskd_net_holds:nick_blocked(Nick).

-doc """
True while `Nick` is held against `Client` (numeric 437).
""".
-spec nick_blocked(binary(), #client{}) -> boolean().
nick_blocked(Nick, Client) ->
    briskd_net_holds:nick_blocked(Nick, Client).

-doc """
True while a hold set by `hold_channel/1` is still in force for `Name`.
""".
-spec channel_blocked(binary()) -> boolean().
channel_blocked(Name) ->
    briskd_net_holds:channel_blocked(Name).

-doc """
Handle a client `CAP` command (IRCv3 capability negotiation).
""".
-spec cap(#client{}, binary(), [binary()]) -> ok.
cap(Client, Server, Params) ->
    briskd_net_cap:cap(Client, Server, Params).

-doc """
Tell `cap-notify` clients about capabilities whose advertisement changed.
""".
-spec notify_cap_changes(#{pid() => [{binary(), undefined | binary()}]}, binary()) -> ok.
notify_cap_changes(Before, Server) ->
    briskd_net_cap:notify_cap_changes(Before, Server).

-doc """
Answer `SERVLIST` (RFC 2812 section 3.5.1).
""".
-spec servlist(binary(), binary(), #client{}, binary()) -> ok.
servlist(Mask, Type, Client, Server) ->
    briskd_net_service:servlist(Mask, Type, Client, Server).

-doc """
Handle a client `SQUERY` (RFC 2812 section 3.5.2).
""".
-spec squery([binary()], #client{}, binary()) -> ok.
squery(Params, Client, Server) ->
    briskd_net_service:squery(Params, Client, Server).

-doc """
Handle an `SQUERY` (RFC 2812 section 3.5.2) that arrived from the peer `Peer`.
""".
-spec remote_squery(binary(), binary(), [binary()]) -> ok | {error, atom()}.
remote_squery(Peer, Prefix, Params) ->
    briskd_net_service:remote_squery(Peer, Prefix, Params).

-doc """
Import a `SERVICE` introduction (RFC 2813 section 4.1.4) from the peer
`Peer`.
""".
-spec import_service(binary(), binary(), [binary()]) -> ok | {error, atom()}.
import_service(Peer, Prefix, Params) ->
    briskd_net_service:import_service(Peer, Prefix, Params).

-doc """
Number of known services, local and imported.
""".
-spec service_count() -> non_neg_integer().
service_count() ->
    briskd_net_service:service_count().

-doc """
`SERVER` lines for every known server, nearest first, for a new peer's burst
(RFC 2813 section 5.3.2).

`Local` is this server's name. A line is prefixed by the server's parent
(`Local` for an adjacent peer) and carries the stored hop count plus one, as
seen from the receiving peer.
""".
-spec burst_server_lines(binary()) -> [binary()].
burst_server_lines(Local) ->
    [
        iolist_to_binary(intro_line(Local, Server))
     || Server <- briskd_route:burst_order(known_maps())
    ].

-doc """
Known servers as `{Name, Hop, Info}`, nearest first, for the `LINKS` reply.

The local server is not included.
""".
-spec links_entries() -> [{binary(), non_neg_integer(), binary()}].
links_entries() ->
    [
        {Name, Hop, Info}
     || #{name := Name, hop := Hop, info := Info} <- briskd_route:burst_order(known_maps())
    ].

-doc """
Run an operator-only server command for a local client.
""".
-spec oper_command(binary(), [binary()], #client{}, binary()) -> ok.
oper_command(Command, Params, Client, Server) ->
    briskd_net_service:oper_command(Command, Params, Client, Server).

lost_names(Lost) ->
    Known = lost_known(Lost),
    case lists:any(fun(Name) -> briskd_wire:fold(Name) =:= briskd_wire:fold(Lost) end, Known) of
        true -> Known;
        false -> [Lost | Known]
    end.

lost_known(Lost) ->
    briskd_route:servers_behind(Lost, known_maps()).

lost_client(#remote_client{server = Server, peer = Peer}, Folds) ->
    Home =
        case Server of
            undefined -> Peer;
            _ -> Server
        end,
    lists:member(briskd_wire:fold(Home), Folds).

drop_remote_user(#remote_client{key = Key, nick = Nick, user = User, host = Host}, Reason) ->
    hold_nick(Nick),
    Prefix = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
    briskd_state_send:with_source(briskd_state_v3:remote_source_info(Prefix), fun() ->
        briskd_state_send:broadcast(
            briskd_state_link:remote_user_local_recipients(Key), Prefix, <<"QUIT">>, [], Reason
        )
    end),
    mnesia:dirty_delete(remote_client, Key),
    briskd_state_link:untrack_peer_item(user, Key),
    briskd_population:on_remote_user_delete(Key),
    briskd_state_monitor:offline(Nick),
    briskd_state_meta:forget_remote(Key),
    ok = briskd_e2ee:forget_remote(Key),
    ok = briskd_calls:remote_gone(Key),
    drop_memberships(Key).

drop_memberships(NickKey) ->
    lists:foreach(
        fun(ChannelKey) ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{name = Name, members = Members} = Channel] ->
                    case maps:is_key(NickKey, Members) of
                        true ->
                            briskd_state_link:unindex_remote_member(NickKey, ChannelKey),
                            Remaining = maps:remove(NickKey, Members),
                            case map_size(Remaining) of
                                0 ->
                                    mnesia:dirty_delete(remote_channel, ChannelKey),
                                    briskd_population:on_channel_delete(ChannelKey),
                                    case mnesia:dirty_read(channel, ChannelKey) of
                                        [] -> hold_channel(Name);
                                        _ -> ok
                                    end;
                                _ ->
                                    mnesia:dirty_write(
                                        briskd_wire:retain_fields(Channel#remote_channel{
                                            members = Remaining
                                        })
                                    )
                            end;
                        false ->
                            ok
                    end;
                _ ->
                    ok
            end
        end,
        briskd_state_link:remote_user_channels(NickKey)
    ).

store_server(#{
    name := Name, hop := Hop, token := Token, adjacent := Adjacent, parent := Parent, info := Info
}) ->
    Key = briskd_wire:fold(Name),
    mnesia:dirty_write(
        briskd_wire:retain_fields(#known_server{
            key = Key,
            name = Name,
            hop = Hop,
            token = Token,
            adjacent = Adjacent,
            parent = Parent,
            info = Info
        })
    ),
    case Key =:= briskd_wire:fold(Adjacent) of
        true -> ok;
        false -> briskd_state_link:track_peer_item(server, Key, Adjacent)
    end,
    briskd_population:on_server_change().

announce_server(Map, Except) ->
    _ = briskd_links:send_except(Except, intro_line(local_name(), Map)).

intro_line(Local, #{name := Name, hop := Hop, token := Token, parent := Parent, info := Info}) ->
    Prefix =
        case briskd_wire:fold(Parent) =:= briskd_wire:fold(Local) of
            true -> Local;
            false -> Parent
        end,
    briskd_wire:line(Prefix, <<"SERVER">>, [Name, integer_to_binary(Hop + 1), Token], Info).

known_maps() ->
    [
        #{
            name => Name,
            hop => Hop,
            token => Token,
            adjacent => Adjacent,
            parent => Parent,
            info => Info
        }
     || Key <- briskd_state:table_keys(known_server),
        [
            #known_server{
                name = Name,
                hop = Hop,
                token = Token,
                adjacent = Adjacent,
                parent = Parent,
                info = Info
            }
        ] <- [mnesia:dirty_read(known_server, Key)]
    ].

-doc """
Drop nickname and channel holds whose delay has passed.

Called from the state process's one-second tick so that holds nobody asks
about again do not accumulate.
""".
-spec expire_holds() -> ok.
expire_holds() ->
    briskd_net_holds:expire_holds().

-doc """
The configured `server_links` entry whose name equals `Target` under the
RFC 1459 case fold, as `{ok, Name}` with the configured spelling, or `error`.
Reads only configuration, so any process may call it.
""".
-spec configured_peer(binary()) -> {ok, binary()} | error.
configured_peer(Target) ->
    Fold = briskd_wire:fold(Target),
    Links = persistent_term:get({briskd_state, server_links}, []),
    case lists:search(fun(#{name := Name}) -> briskd_wire:fold(Name) =:= Fold end, Links) of
        {value, #{name := Name}} -> {ok, Name};
        false -> error
    end.

peer_server_room(Peer, Name) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(known_server, Key) of
        [_] ->
            true;
        [] ->
            Max = maps:get(
                max_peer_servers, briskd_config:current_or_empty(), 100
            ),
            briskd_state_link:peer_item_count(server, Peer) < Max
    end.

local_name() ->
    maps:get(name, briskd_config:current()).

valid_token(Token) when is_binary(Token), byte_size(Token) > 0, byte_size(Token) =< 16 ->
    lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Token));
valid_token(_) ->
    false.
