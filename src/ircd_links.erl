-module(ircd_links).
-moduledoc """
Supervisor for outbound server-link workers, and the send API for every
authenticated server peer.

It starts one permanent `m:ircd_link` worker per `server_links` entry, with
child id `{server_link, Name}`, under a `one_for_one` strategy that allows 10
restarts in 60 seconds. It is the third child of `m:ircd_sup`, after the state
process and the session supervisor.

The send functions reach both directions of a link. Outbound peers that have
completed the RFC 2813 `PASS`/`SERVER` handshake are listed in the
`ircd_outbound_ready` ETS table and receive `{send, Line}` casts. Inbound
peers, which connect to a client listener and are served by `m:ircd_session`,
are listed in `ircd_inbound_peers` and receive `{irc, Line}` messages. Both
tables are keyed by the folded peer name and filled by
`ircd_state_net:register_adjacent/4`. When a peer appears in both tables the
outbound connection is used. Sends are asynchronous: `ok` means the line was
handed to the owning process, not that the peer received it.
""".
-behaviour(supervisor).
-export([connect_peer/1, send/2, send_all/1, send_except/2, start_link/1, init/1]).

-doc """
Start the link supervisor, registered locally as `ircd_links`.

`Config` is the validated server configuration; its `server_links` list gives
one `m:ircd_link` child per configured peer.
""".
-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Config) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

-doc """
Ask the outbound worker for the configured peer `Name` to connect now.

Used by the operator `CONNECT` command. The name is matched with
`ircd_wire:fold/1`. A disconnected worker cancels its reconnect timer and
connects immediately; a worker that is connected or in its handshake ignores
the request. Returns `{error, peer_unavailable}` when no worker exists for
that name.
""".
-spec connect_peer(binary()) -> ok | {error, peer_unavailable}.
connect_peer(Name) ->
    case outbound_pid(Name) of
        {ok, Pid} ->
            gen_server:cast(Pid, connect_now),
            ok;
        error ->
            {error, peer_unavailable}
    end.

-doc """
Send an already encoded server line to one authenticated adjacent peer.

`Peer` is the adjacent link name, matched after `ircd_wire:fold/1`. Returns
`{error, peer_unavailable}` when that peer is not linked or has not finished
its handshake. The line is not re-encoded or length-checked here.
""".
-spec send(binary(), iodata()) -> ok | {error, peer_unavailable}.
send(Peer, Line) ->
    Fold = ircd_wire:fold(Peer),
    case ets:lookup(ircd_outbound_ready, Fold) of
        [{_, {Pid, _Name}}] when is_pid(Pid) ->
            gen_server:cast(Pid, {send, Line}),
            ok;
        _ ->
            case ets:lookup(ircd_inbound_peers, Fold) of
                [{_, {Pid, _Name}}] when is_pid(Pid) ->
                    Pid ! {irc, Line},
                    ok;
                _ ->
                    {error, peer_unavailable}
            end
    end.

-doc """
Send an already encoded server line to every authenticated peer, outbound or
inbound.
""".
-spec send_all(iodata()) -> ok.
send_all(Line) ->
    send_except(undefined, Line).

-doc """
Send an already encoded server line to every authenticated peer except
`Except`.

`Except` is the ingress link name, so a relayed line is not echoed back to the
peer that sent it, or `undefined` to send to every peer. Each peer receives
the line once even when it has both an inbound and an outbound entry.
""".
-spec send_except(undefined | binary(), iodata()) -> ok.
send_except(Except, Line) ->
    ExceptFold =
        case Except of
            undefined -> undefined;
            Peer when is_binary(Peer) -> ircd_wire:fold(Peer)
        end,
    lists:foreach(
        fun
            ({Name, Pid, outbound}) ->
                case ExceptFold =/= undefined andalso ircd_wire:fold(Name) =:= ExceptFold of
                    true -> ok;
                    false -> gen_server:cast(Pid, {send, Line})
                end;
            ({Name, Pid, inbound}) ->
                case ExceptFold =/= undefined andalso ircd_wire:fold(Name) =:= ExceptFold of
                    true -> ok;
                    false -> Pid ! {irc, Line}
                end
        end,
        peer_entries()
    ),
    ok.

outbound_pid(Name) ->
    case
        [
            Pid
         || {{server_link, Peer}, Pid, worker, _} <- supervisor:which_children(?MODULE),
            is_pid(Pid),
            is_binary(Peer),
            ircd_wire:fold(Peer) =:= ircd_wire:fold(Name)
        ]
    of
        [Pid | _] -> {ok, Pid};
        [] -> error
    end.

peer_entries() ->
    Outbound = [
        {Name, Pid, outbound}
     || {_Fold, {Pid, Name}} <- ets:tab2list(ircd_outbound_ready), is_pid(Pid)
    ],
    Inbound = [
        {Name, Pid, inbound}
     || {_Fold, {Pid, Name}} <- ets:tab2list(ircd_inbound_peers),
        is_pid(Pid),
        not outbound_named(Name, Outbound)
    ],
    Outbound ++ Inbound.

outbound_named(Name, Outbound) ->
    lists:any(fun({Peer, _, _}) -> ircd_wire:fold(Peer) =:= ircd_wire:fold(Name) end, Outbound).

-doc false.
init(#{server_links := Peers} = Config) ->
    Children =
        [
            #{
                id => {server_link, maps:get(name, Peer)},
                start => {ircd_link, start_link, [Config, Peer]},
                restart => permanent
            }
         || Peer <- Peers
        ],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 60}, Children}}.
