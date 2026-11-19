-module(ircd_sup).
-moduledoc """
Top-level supervisor of the `ircd` application.

Children start in this order under a `rest_for_one` strategy with the default
restart intensity (one restart in five seconds):

1. `m:ircd_state`, the single owner of nickname, channel, and peer state.
2. `m:ircd_sessions`, the supervisor of client sessions and inbound links.
3. `m:ircd_links`, the supervisor of outbound server-link workers.
4. One `m:ircd_listener` per configured port, in the order `tcp`, `tls`,
   `ws`, `wss`. A port set to `null` has no listener.
5. `m:ircd_certs`, the TLS certificate watcher, when a `tls` or `wss`
   listener is configured and `tls_reload_interval` is not 0. It restarts the
   `tls` and `wss` listeners after a certificate renewal.

With `rest_for_one`, a restart of the state process also restarts every
session, link, and listener started after it, so no connection outlives the
state it refers to. A crashed listener restarts only itself and the listeners
after it. `m:ircd_shutdown` stops the listeners by their child ids (`tcp`,
`tls`, `ws`, `wss`) before the tree stops.
""".
-behaviour(supervisor).
-export([start_link/1, init/1]).

-doc """
Start the top-level supervisor, registered as `ircd_sup`.

`Config` is the normalized map from `ircd_config:load/1`; it is passed to the
state process, the link supervisor, and each listener, and its `max_clients`
to `m:ircd_sessions`.
""".
-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Config) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

-doc false.
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
     || Kind <- [tcp, tls, ws, wss], Port <- [maps:get(Kind, Config)], Port =/= null
    ],
    %% Last, so a restart of the watcher or control socket affects nothing else (rest_for_one).
    Certs = [
        #{id => ircd_certs, start => {ircd_certs, start_link, [Config]}}
     || maps:get(tls_options, Config, []) =/= [],
        maps:get(tls_reload_interval, Config, 60) > 0
    ],
    Ctl =
        [
            #{id => ircd_dronebl, start => {ircd_dronebl, start_link, [Config]}},
            #{id => ircd_ctl, start => {ircd_ctl, start_link, [Config]}}
        ] ++
            [
                #{id => ircd_webui, start => {ircd_webui, start_link, [Config]}}
             || maps:get(webui, Config, null) =/= null
            ],
    {ok, {#{strategy => rest_for_one}, Children ++ Listeners ++ Certs ++ Ctl}}.
