-module(briskd_net_service).
-moduledoc """
IRC service listings, `SQUERY` delivery/routing, remote `SERVICE` imports, and
operator server commands (`SQUIT`, `CONNECT`, `SERVICE`, `DIE`, `RESTART`).
""".
-export([
    import_service/3,
    oper_command/4,
    remote_squery/3,
    service_count/0,
    servlist/4,
    squery/3
]).
-include("briskd_client.hrl").
-include("briskd_remote.hrl").

-doc """
Answer `SERVLIST` (RFC 2812 section 3.5.1).

Sends numeric 234 (`RPL_SERVLIST`) for every known service whose name matches
the wildcard `Mask` and whose type equals `Type` (any type when `Type` is
`*`), then 235 (`RPL_SERVLISTEND`).
""".
-spec servlist(binary(), binary(), #client{}, binary()) -> ok.
servlist(Mask, Type, Client, Server) ->
    lists:foreach(
        fun(
            #service{
                name = Name, server = Home, distribution = Dist, type = ServiceType, info = Info
            }
        ) ->
            Matches =
                briskd_state_channel:wildcard_match(Mask, Name) andalso
                    (Type =:= <<"*">> orelse Type =:= ServiceType),
            case Matches of
                true ->
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"234">>,
                        [Name, Home, Dist, ServiceType, <<"1">>],
                        Info
                    );
                false ->
                    ok
            end
        end,
        services()
    ),
    briskd_state_send:numeric(
        Client, Server, <<"235">>, [Mask, Type], <<"End of service listing">>
    ).

-doc """
Handle a client `SQUERY` (RFC 2812 section 3.5.2).

Replies 411 without a target, 412 without text, and 401 for an unknown
service. A service registered on this server delivers the text as a `NOTICE`
from the client to every local operator (user mode `+o`), with 401 when no
operator is online. A remote service gets the `SQUERY` forwarded to the peer
it was learned from.
""".
-spec squery([binary()], #client{}, binary()) -> ok.
squery([], Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"411">>, [], <<"No recipient given (SQUERY)">>);
squery([_Service], Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"412">>, [], <<"No text to send">>);
squery([_Service, <<>> | _], Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"412">>, [], <<"No text to send">>);
squery([Name, Text | _], Client, Server) ->
    case mnesia:dirty_read(service, briskd_wire:fold(Name)) of
        [] ->
            briskd_state_send:numeric(
                Client, Server, <<"401">>, [Name], <<"No such nick/channel">>
            );
        [#service{peer = undefined, name = ServiceName}] ->
            deliver_local_service(ServiceName, Text, Client, Server);
        [#service{peer = Peer, name = ServiceName}] ->
            Line = briskd_wire:line(
                briskd_state_send:prefix(Client), <<"SQUERY">>, [ServiceName], Text
            ),
            _ = briskd_links:send(Peer, Line),
            ok
    end.

-doc """
Handle an `SQUERY` (RFC 2812 section 3.5.2) that arrived from the peer `Peer`.

`Prefix` must be a remote user reached through `Peer`
(`briskd_state_link:remote_source/2`). A service registered on this server
delivers the text as a `NOTICE` from that user to every local operator, as a
local `SQUERY` does; no 401 is routed back when no operator is online. A
service learned from another peer gets the `SQUERY` forwarded there, never
back to `Peer`. Any other target goes to
`briskd_state_link:receive_remote_message/4` as before.

Errors: `unknown_remote_source` and those of
`briskd_state_link:receive_remote_message/4`.
""".
-spec remote_squery(binary(), binary(), [binary()]) -> ok | {error, atom()}.
remote_squery(Peer, Prefix, [Name, Text | _] = Params) when Text =/= <<>> ->
    case mnesia:dirty_read(service, briskd_wire:fold(Name)) of
        [] ->
            briskd_state_link:receive_remote_message(Peer, Prefix, <<"SQUERY">>, Params);
        [#service{peer = ServicePeer, name = ServiceName}] ->
            case briskd_state_link:remote_source(Peer, Prefix) of
                {ok, _} when ServicePeer =:= undefined ->
                    Operators = briskd_oper:local_operators(),
                    briskd_state_send:broadcast(
                        Operators, Prefix, <<"NOTICE">>, [ServiceName], Text
                    );
                {ok, _} ->
                    case briskd_route:should_forward(Peer, ServicePeer) of
                        true ->
                            Line = briskd_wire:line(Prefix, <<"SQUERY">>, [ServiceName], Text),
                            _ = briskd_links:send(ServicePeer, Line),
                            ok;
                        false ->
                            ok
                    end;
                error ->
                    {error, unknown_remote_source}
            end
    end;
remote_squery(Peer, Prefix, Params) ->
    briskd_state_link:receive_remote_message(Peer, Prefix, <<"SQUERY">>, Params).

-doc """
Import a `SERVICE` introduction (RFC 2813 section 4.1.4) from the peer
`Peer`.

Accepts the RFC 2813 form `<name> <reserved> <distribution> <type>
<reserved> :<info>` and a shorter `<name> <distribution> <type> :<info>`.
The home server is `Prefix`, or `Peer` when there is no prefix. Returns
`{error, invalid_service}` for a bad parameter list or service name and
`{error, nickname_collision}` when a local or remote user holds the name.
The service is stored but not relayed to other peers.
""".
-spec import_service(binary(), binary(), [binary()]) -> ok | {error, atom()}.
import_service(Peer, Prefix, Params) ->
    case service_params(Params) of
        error ->
            {error, invalid_service};
        {Name, Dist, Type, Info} ->
            Home =
                case Prefix of
                    undefined -> Peer;
                    _ -> Prefix
                end,
            case
                briskd_state_link:trusted_server(Peer, Home) andalso
                    briskd_wire:nickname(Name, briskd_state:nicklen())
            of
                false ->
                    {error, invalid_service};
                true ->
                    case peer_service_room(Peer, Name) of
                        false -> {error, too_many_remote_services};
                        true -> store_service(Name, Dist, Type, Info, Home, Peer)
                    end
            end
    end.

-doc """
Number of known services, local and imported.
""".
-spec service_count() -> non_neg_integer().
service_count() ->
    case mnesia:table_info(service, size) of
        Size when is_integer(Size), Size >= 0 -> Size
    end.

-doc """
Run an operator-only server command for a local client.

A client without user mode `+o` gets numeric 481. The caller passes only
these commands:

- `SQUIT <server> [:<reason>]` runs `briskd_state_net:drop_server/3` locally
  and confirms with a `NOTICE`; 402 for an unknown server.
- `CONNECT <server>` asks `briskd_links:connect_peer/1` to connect a configured
  peer and confirms with a `NOTICE`; 402 for a name that is not configured.
- `SERVICE <name> <distribution> <type> [:<info>]` registers a local service
  and replies 234, or 432 for a bad name and 433 for a name in use.
- `DIE` and `RESTART` call `init:stop/0` and `init:restart/0` from a new
  process.

A command missing its required parameters gets 461.
""".
-spec oper_command(binary(), [binary()], #client{}, binary()) -> ok.
oper_command(Command, Params, #client{pid = Pid} = Client, Server) ->
    case maps:is_key($o, briskd_state_client:user_modes(Pid)) of
        false ->
            briskd_state_send:numeric(Client, Server, <<"481">>, [], <<"Permission Denied">>);
        true ->
            oper_command_allowed(Command, Params, Client, Server)
    end.

oper_command_allowed(<<"SQUIT">>, [Target | Rest], Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> <<"SQUIT">>
        end,
    case mnesia:dirty_read(known_server, briskd_wire:fold(Target)) of
        [] ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        [#known_server{name = Name}] ->
            briskd_state_net:drop_server(Name, Reason, undefined),
            briskd_state_send:send(
                Client#client.pid,
                Server,
                <<"NOTICE">>,
                [Client#client.nick],
                <<"SQUIT ", Name/binary>>
            )
    end;
oper_command_allowed(<<"SQUIT">>, _, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"SQUIT">>], <<"Not enough parameters">>
    );
oper_command_allowed(<<"CONNECT">>, [Target | _], Client, Server) ->
    case briskd_state_net:configured_peer(Target) of
        {ok, Name} ->
            _ = briskd_links:connect_peer(Name),
            briskd_state_send:send(
                Client#client.pid,
                Server,
                <<"NOTICE">>,
                [Client#client.nick],
                <<"Connect attempt for ", Name/binary>>
            );
        error ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end;
oper_command_allowed(<<"CONNECT">>, _, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"CONNECT">>], <<"Not enough parameters">>
    );
oper_command_allowed(<<"SERVICE">>, [Name, Dist, Type | Rest], Client, Server) ->
    Info =
        case Rest of
            [Text | _] -> Text;
            [] -> <<"service">>
        end,
    case briskd_wire:nickname(Name, briskd_state:nicklen()) of
        true ->
            case store_service(Name, Dist, Type, Info, local_name(), undefined) of
                ok ->
                    briskd_state_send:numeric(
                        Client, Server, <<"234">>, [Name, local_name(), Dist, Type, <<"0">>], Info
                    );
                {error, nickname_collision} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"433">>, [Name], <<"Nickname is already in use">>
                    )
            end;
        false ->
            briskd_state_send:numeric(Client, Server, <<"432">>, [Name], <<"Erroneous nickname">>)
    end;
oper_command_allowed(<<"SERVICE">>, _, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"SERVICE">>], <<"Not enough parameters">>
    );
%% RFC 2812 DIE shuts the node down. RESTART restarts the runtime. Both are
%% operator-only; a non-operator already received numeric 481.
oper_command_allowed(<<"DIE">>, _, _Client, _Server) ->
    erlang:spawn(fun init:stop/0),
    ok;
oper_command_allowed(<<"RESTART">>, _, _Client, _Server) ->
    erlang:spawn(fun init:restart/0),
    ok.

store_service(Name, Dist, Type, Info, Home, Peer) ->
    Key = briskd_wire:fold(Name),
    case briskd_state_client:find_nick(Name) =/= undefined orelse remote_nick(Name) of
        true ->
            {error, nickname_collision};
        false ->
            mnesia:dirty_write(
                briskd_wire:retain_fields(#service{
                    key = Key,
                    name = Name,
                    distribution = Dist,
                    type = Type,
                    info = Info,
                    server = Home,
                    peer = Peer
                })
            ),
            case is_binary(Peer) of
                true -> briskd_state_link:track_peer_item(service, Key, Peer);
                false -> briskd_state_link:untrack_peer_item(service, Key)
            end,
            ok
    end.

deliver_local_service(ServiceName, Text, Client, Server) ->
    Operators = briskd_oper:local_operators(),
    briskd_state_send:broadcast(
        Operators,
        briskd_state_send:prefix(Client),
        <<"NOTICE">>,
        [ServiceName],
        Text
    ),
    case Operators of
        [] ->
            briskd_state_send:numeric(
                Client, Server, <<"401">>, [ServiceName], <<"No such nick/channel">>
            );
        _ ->
            ok
    end.

service_params([Name, _Reserved, Dist, Type, _Reserved2, Info | _]) ->
    {Name, Dist, Type, Info};
service_params([Name, Dist, Type, Info | _]) ->
    {Name, Dist, Type, Info};
service_params(_) ->
    error.

services() ->
    [
        Service
     || Key <- briskd_state:table_keys(service),
        [#service{} = Service] <- [mnesia:dirty_read(service, Key)]
    ].

remote_nick(Name) ->
    mnesia:dirty_read(remote_client, briskd_wire:fold(Name)) =/= [].

peer_service_room(Peer, Name) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(service, Key) of
        [#service{peer = Peer}] ->
            true;
        _ ->
            Max = maps:get(
                max_peer_services, briskd_config:current_or_empty(), 100
            ),
            briskd_state_link:peer_item_count(service, Peer) < Max
    end.

local_name() ->
    maps:get(name, briskd_config:current()).
