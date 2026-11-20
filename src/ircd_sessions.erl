-module(ircd_sessions).
-moduledoc """
Supervisor of connection sessions, with `max_clients` admission control.

Every accepted socket, whether a client or an inbound server link, runs in one
`m:ircd_session` process started here as a `temporary` child, so a session
that ends is never restarted. Admission happens before a session is created:
`start_child/3` refuses a new connection once `max_clients` sessions are
active, and the listener then closes the socket.

The limit is set at startup from the `max_clients` configuration key and
stored with `persistent_term`; it changes only when this supervisor restarts.
""".
-behaviour(supervisor).
-export([start_link/1, start_child/3, init/1]).

-doc """
Start the session supervisor, registered as `ircd_sessions`.

`MaxClients` is the maximum number of active sessions admitted by
`start_child/3`.
""".
-spec start_link(pos_integer()) -> supervisor:startlink_ret().
start_link(MaxClients) -> supervisor:start_link({local, ?MODULE}, ?MODULE, MaxClients).

-doc """
Start an `m:ircd_session` for an accepted socket if the client limit allows it.

`Kind`, `Socket`, and `Peer` are passed to `ircd_session:start_link/3`.
Returns `{error, max_clients}` when `max_clients` sessions are already active.
The count and the start run under one `global:trans/2` lock, so concurrent
listeners cannot exceed the limit. On success the caller still owns the
socket and must transfer it to the new process.
""".
-spec start_child(atom(), term(), binary()) -> {ok, pid()} | {error, term()}.
start_child(Kind, Socket, Peer) ->
    %% TCP and TLS listeners can accept concurrently, so serialize the check
    %% and child start to make the configured limit strict.
    Result = global:trans({?MODULE, self()}, fun() ->
        Counts = supervisor:count_children(?MODULE),
        Active = proplists:get_value(active, Counts, 0),
        Limit = persistent_term:get({?MODULE, max_clients}),
        case Active >= Limit of
            true ->
                {error, max_clients};
            false ->
                supervisor:start_child(
                    ?MODULE,
                    #{
                        id => make_ref(),
                        start => {ircd_session, start_link, [Kind, Socket, Peer]},
                        restart => temporary
                    }
                )
        end
    end),
    case Result of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        {error, Reason} -> {error, Reason};
        %% `aborted` (global:trans/2 gave up) or an unexpected start result.
        Other -> {error, Other}
    end.

%% Initialize the supervisor and publish its admission limit to session admission.
-doc false.
init(MaxClients) ->
    persistent_term:put({?MODULE, max_clients}, MaxClients),
    {ok, {#{}, []}}.
