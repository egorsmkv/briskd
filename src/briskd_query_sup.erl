-module(briskd_query_sup).
-moduledoc """
Supervisor for bounded read-only query workers (`m:briskd_query_worker`).

Isolates expensive enumerations (`TRACE`, `STATS l`) in a separate supervision
subtree so worker failures or slow consumers never crash `m:briskd_state` or
disconnect IRC client sessions. Also owns the `briskd_active_queries` ETS
table used for per-session and global worker admission control.
""".

-behaviour(supervisor).

-export([start_link/0, start_worker/1, init/1]).

-doc "Start and register the query worker supervisor.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "Start one temporary `m:briskd_query_worker` child.".
-spec start_worker(briskd_query_worker:worker_arg()) -> supervisor:startchild_ret().
start_worker(Arg) ->
    supervisor:start_child(?MODULE, [Arg]).

-doc false.
init([]) ->
    case ets:whereis(briskd_active_queries) of
        undefined ->
            _ = ets:new(briskd_active_queries, [
                named_table, public, set, {write_concurrency, true}
            ]),
            ok;
        _ ->
            ok
    end,
    ChildSpec = #{
        id => briskd_query_worker,
        start => {briskd_query_worker, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [briskd_query_worker]
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 60}, [ChildSpec]}}.
