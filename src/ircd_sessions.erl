-module(ircd_sessions).
-behaviour(supervisor).
-export([start_link/1, start_child/3, init/1]).

%% @doc Start the dynamic supervisor for client sessions with a hard client limit.
-spec start_link(pos_integer()) -> supervisor:startchild_ret().
start_link(MaxClients) -> supervisor:start_link({local, ?MODULE}, ?MODULE, MaxClients).

%% @doc Start a session only if the configured active-client limit allows it.
start_child(Kind, Socket, Peer) ->
    %% TCP and TLS listeners can accept concurrently, so serialize the check
    %% and child start to make the configured limit strict.
    global:trans({?MODULE, self()}, fun() ->
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
    end).
%% Initialize the supervisor and publish its admission limit to session admission.
init(MaxClients) ->
    persistent_term:put({?MODULE, max_clients}, MaxClients),
    {ok, {#{}, []}}.
