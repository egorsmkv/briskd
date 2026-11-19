-module(ircd_links).
-behaviour(supervisor).
-export([connect_peer/1, send/2, send_all/1, send_except/2, start_link/1, init/1]).

%% @doc Supervise one outbound connector for each configured server peer.
-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Config) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

%% @doc Ask one configured outbound peer to connect or reconnect.
-spec connect_peer(binary()) -> ok | {error, peer_unavailable}.
connect_peer(Name) ->
    case outbound_pid(Name) of
        {ok, Pid} ->
            gen_server:cast(Pid, connect_now),
            ok;
        error ->
            {error, peer_unavailable}
    end.

%% @doc Send an already encoded server message to one authenticated peer.
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

%% @doc Send a server message to each authenticated peer, outbound or inbound.
-spec send_all(iodata()) -> ok.
send_all(Line) ->
    send_except(undefined, Line).

%% @doc Send a server message to every peer except the named ingress link.
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
