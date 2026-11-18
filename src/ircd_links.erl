-module(ircd_links).
-behaviour(supervisor).
-export([start_link/1, send/2, send_all/1, init/1]).

%% @doc Supervise one outbound connector for each configured server peer.
start_link(Config) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

%% @doc Send an already encoded server message to one authenticated peer.
send(Peer, Line) ->
    case lists:keyfind({server_link, Peer}, 1, supervisor:which_children(?MODULE)) of
        {{server_link, Peer}, Pid, worker, _} when is_pid(Pid) ->
            gen_server:cast(Pid, {send, Line});
        _ ->
            {error, peer_unavailable}
    end.

%% @doc Send a server message to each currently authenticated peer worker.
send_all(Line) ->
    lists:foreach(
        fun
            ({_Id, Pid, worker, _}) when is_pid(Pid) -> gen_server:cast(Pid, {send, Line});
            (_) -> ok
        end,
        supervisor:which_children(?MODULE)
    ),
    ok.

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
