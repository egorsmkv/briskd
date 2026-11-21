-module(briskd_bots).
-moduledoc """
Supervisor of the configured AI assistant bots (`m:briskd_bot`), one child per
entry of the `bots` configuration list.

A bot whose provider takes its key from an `api_key_env` variable that is
unset or empty is not started; a `bot_disabled` warning names the bot and the
variable, and the rest of the server runs normally.

Strategy `one_for_one`, at most 5 restarts in 60 seconds. `m:briskd_sup` starts
this supervisor last and as a `transient` child: when bots keep crashing and
this supervisor gives up (exit reason `shutdown`), it is not restarted, so a
failing bot never affects listeners or client sessions. It is still restarted
together with `m:briskd_state` under `rest_for_one`.
""".
-behaviour(supervisor).
-export([start_link/1, init/1]).

-doc """
Start the bot supervisor. `Config` is the normalized configuration map from
`briskd_config:load/1`; its `bots` list must not be empty.
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
            start => {briskd_bot, start_link, [Bot#{server_name => Name}]},
            restart => permanent,
            shutdown => 2000
        }
     || Bot <- maps:get(bots, Config, []),
        enabled(Bot)
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 60}, Children}}.

enabled(#{nick := Nick, provider := Provider}) ->
    case maps:get(missing_key_env, Provider, undefined) of
        undefined ->
            true;
        Var ->
            logger:warning(#{
                event => bot_disabled,
                bot => Nick,
                reason => missing_api_key_env,
                env => Var
            }),
            false
    end.
