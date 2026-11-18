-module(ircd_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).

%% @doc Start the top-level supervisor for state, sessions, and listeners.
-spec start_link(map()) -> supervisor:startchild_ret().
start_link(Config) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

%% @doc Build the supervision tree from the enabled listener configuration.
init(Config) ->
    Children = [
        #{id => ircd_state, start => {ircd_state, start_link, [Config]}},
        #{
            id => ircd_sessions,
            start => {ircd_sessions, start_link, [maps:get(max_clients, Config)]},
            type => supervisor
        },
        #{id => ircd_links, start => {ircd_links, start_link, [Config]}, type => supervisor}
    ],
    Listeners = [
        #{id => Kind, start => {ircd_listener, start_link, [Kind, Port, Config]}}
     || Kind <- [tcp, tls], Port <- [maps:get(Kind, Config)], Port =/= null
    ],
    {ok, {#{strategy => rest_for_one}, Children ++ Listeners}}.
