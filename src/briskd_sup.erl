-module(briskd_sup).
-moduledoc """
Top-level supervisor of the `briskd` application.

Children start in this order under a `rest_for_one` strategy with the default
restart intensity (one restart in five seconds):

1. `m:briskd_state`, the single owner of nickname, channel, and peer state.
2. `m:briskd_sessions`, the supervisor of client sessions and inbound links.
3. `m:briskd_links`, the supervisor of outbound server-link workers.
4. One `m:briskd_listener` per configured port, in the order `tcp`, `tls`,
   `ws`, `wss`. A port set to `null` has no listener.
5. `m:briskd_certs`, the TLS certificate watcher, when a `tls` or `wss`
   listener is configured and `tls_reload_interval` is not 0. It restarts the
   `tls` and `wss` listeners after a certificate renewal.
6. `m:briskd_dronebl`, `m:briskd_ctl`, and `m:briskd_webui` (when `webui` is set).
7. `m:briskd_calls`, the voice-call server, when `calls` is set. A restart
   ends every call in progress.
8. `m:briskd_bots`, the AI assistant bot supervisor, when `bots` is not empty.
   It is `transient`: if it exhausts its own restart intensity it stays down
   instead of restarting the rest of the tree.
9. `m:briskd_stats`, the statistics sampler behind the admin Stats tab.
10. `m:briskd_search`, the message search indexer, when `search` is configured.

With `rest_for_one`, a restart of the state process also restarts every
session, link, and listener started after it, so no connection outlives the
state it refers to. A crashed listener restarts only itself and the listeners
after it. `m:briskd_shutdown` stops the listeners by their child ids (`tcp`,
`tls`, `ws`, `wss`) before the tree stops.
""".
-behaviour(supervisor).
-export([start_link/1, init/1]).

-doc """
Start the top-level supervisor, registered as `briskd_sup`.

`Config` is the normalized map from `briskd_config:load/1`; it is passed to the
state process, the link supervisor, and each listener, and its `max_clients`
to `m:briskd_sessions`.
""".
-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Config) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

-doc false.
init(Config) ->
    Children = [
        #{id => briskd_state, start => {briskd_state, start_link, [Config]}},
        #{
            id => briskd_sessions,
            start => {briskd_sessions, start_link, [maps:get(max_clients, Config)]},
            type => supervisor
        },
        #{id => briskd_links, start => {briskd_links, start_link, [Config]}, type => supervisor}
    ],
    Listeners = [
        #{id => Kind, start => {briskd_listener, start_link, [Kind, Port, Config]}}
     || Kind <- [tcp, tls, ws, wss], Port <- [maps:get(Kind, Config)], Port =/= null
    ],
    %% Last, so a restart of the watcher or control socket affects nothing else (rest_for_one).
    Certs = [
        #{id => briskd_certs, start => {briskd_certs, start_link, [Config]}}
     || maps:get(tls_options, Config, []) =/= [],
        maps:get(tls_reload_interval, Config, 60) > 0
    ],
    Ctl =
        [
            #{id => briskd_dronebl, start => {briskd_dronebl, start_link, [Config]}},
            #{id => briskd_ctl, start => {briskd_ctl, start_link, [Config]}}
        ] ++
            [
                #{id => briskd_webui, start => {briskd_webui, start_link, [Config]}}
             || maps:get(webui, Config, null) =/= null
            ],
    %% Voice calls: the call table and the rtpengine control socket.
    Calls = [
        #{id => briskd_calls, start => {briskd_calls, start_link, [Config]}}
     || maps:get(calls, Config, null) =/= null
    ],
    %% Bots last and transient: if the bot supervisor gives up, nothing else
    %% restarts and it stays down; a state restart still restarts it.
    Bots = [
        #{
            id => briskd_bots,
            start => {briskd_bots, start_link, [Config]},
            type => supervisor,
            restart => transient
        }
     || maps:get(bots, Config, []) =/= []
    ],
    %% The statistics sampler for the admin Stats tab, last: it depends on
    %% nothing after it and its restart affects nothing else.
    Stats = [#{id => briskd_stats, start => {briskd_stats, start_link, []}}],
    %% The message search indexer, when `search` is configured; last, so a
    %% restart rebuilds the index without touching anything else.
    Search = [
        #{id => briskd_search, start => {briskd_search, start_link, []}}
     || maps:get(search, Config, null) =/= null
    ],
    {ok, {
        #{strategy => rest_for_one},
        Children ++ Listeners ++ Certs ++ Ctl ++ Calls ++ Bots ++ Stats ++ Search
    }}.
