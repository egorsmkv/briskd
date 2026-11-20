-module(ircd_bots).
-moduledoc """
Supervisor of the configured AI assistant bots (`m:ircd_bot`), one child per
entry of the `bots` configuration list.

Strategy `one_for_one`, at most 5 restarts in 60 seconds. `m:ircd_sup` starts
this supervisor last and as a `transient` child: when bots keep crashing and
this supervisor gives up (exit reason `shutdown`), it is not restarted, so a
failing bot never affects listeners or client sessions. It is still restarted
together with `m:ircd_state` under `rest_for_one`.
""".
-behaviour(supervisor).
-export([start_link/1, init/1]).

-doc """
Start the bot supervisor. `Config` is the normalized configuration map from
`ircd_config:load/1`; its `bots` list must not be empty.
""".
-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

-doc false.
init(Config) ->
    Name = maps:get(name, Config),
    Children = [
        #{
            id => {bot, maps:get(nick, Bot)},
            start => {ircd_bot, start_link, [Bot#{server_name => Name}]},
            restart => permanent,
            shutdown => 2000
        }
     || Bot <- maps:get(bots, Config, [])
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 60}, Children}}.
