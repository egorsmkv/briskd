-module(briskd_query).
-moduledoc """
Query routing and admission control for `TRACE` and `STATS`.

Lightweight `STATS` queries (`u`, `m`, `o`, and non-operator single-connection
`l`) complete in O(1) or over bounded configuration lists without touching
`client`. Expensive enumerations (`TRACE` over all local users and operator
`STATS l`) are admitted up to `?MAX_WORKERS` (32) global workers and
`?MAX_PER_SESSION` (1) per session, and executed via `m:briskd_query_worker`
under `m:briskd_query_sup`.

When called from `m:briskd_state`, expensive queries are handed off via
`m:briskd_deferred` so `briskd_state` stays responsive to other clients while
preserving the requesting session's IRC command ordering.
""".

-export([
    trace/3,
    stats/3
]).

-include("briskd_state.hrl").

-define(ACTIVE_TABLE, briskd_active_queries).
-define(MAX_WORKERS, 32).
-define(MAX_PER_SESSION, 1).
-define(WORKER_WAIT_MS, 5500).

-doc """
Handle `TRACE [<target>]` (RFC 2812 section 3.4.8).

An exact local nickname answers immediately with 204/205 and 262. A server
enumeration (no target or target matching `Server`) is executed through a
bounded query worker.
""".
-spec trace([binary()], #client{}, binary()) -> ok.
trace([], Client, Server) ->
    run_trace_server(Client, Server);
trace([Target | _], Client, Server) ->
    case briskd_state_channel:wildcard_match(Target, Server) of
        true ->
            run_trace_server(Client, Server);
        false ->
            case briskd_state_client:find_nick(Target) of
                undefined ->
                    briskd_state_send:numeric(
                        Client, Server, <<"402">>, [Target], <<"No such server">>
                    );
                User ->
                    trace_user(User, Client, Server),
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"262">>,
                        [Server, <<"briskd-", (briskd_app:vsn())/binary>>],
                        <<"End of TRACE">>
                    )
            end
    end.

-doc """
Handle `STATS [<query> [<target>]]` (RFC 2812 section 3.4.4).
""".
-spec stats([binary()], #client{}, binary()) -> ok.
stats(Params, Client, Server) ->
    {Query, Targets} =
        case Params of
            [Letter | Rest] -> {Letter, Rest};
            [] -> {<<"*">>, []}
        end,
    case briskd_info:query_local_server(Targets, Server) of
        {false, Target} ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            report_stats(Query, Client, Server)
    end.

%% Internal helpers

run_trace_server(#client{pid = Pid} = Client, Server) ->
    RequesterIsOperator = briskd_oper:is_operator(Pid),
    Label = active_label(Pid),
    Ctx = briskd_reply:from_client(Client, Server, Label),
    Job = {trace_server, Ctx, RequesterIsOperator},
    EndSpec = {
        <<"262">>, [Server, <<"briskd-", (briskd_app:vsn())/binary>>], <<"End of TRACE">>
    },
    run_expensive(Job, Client, Server, EndSpec).

report_stats(<<"u">>, Client, Server) ->
    Uptime = erlang:monotonic_time(second) - persistent_term:get({briskd_state, started_at}),
    {Days, {Hours, Minutes, Seconds}} = calendar:seconds_to_daystime(Uptime),
    briskd_state_send:numeric(
        Client,
        Server,
        <<"242">>,
        [],
        io_lib:format("Server Up ~B days ~2..0B:~2..0B:~2..0B", [Days, Hours, Minutes, Seconds])
    ),
    briskd_state_send:numeric(Client, Server, <<"219">>, [<<"u">>], <<"End of STATS report">>);
report_stats(<<"m">>, Client, Server) ->
    lists:foreach(
        fun({Command, Count, Bytes}) ->
            briskd_state_send:numeric(
                Client,
                Server,
                <<"212">>,
                [Command, integer_to_binary(Count), integer_to_binary(Bytes), <<"0">>],
                none
            )
        end,
        briskd_metrics:command_stats()
    ),
    briskd_state_send:numeric(Client, Server, <<"219">>, [<<"m">>], <<"End of STATS report">>);
report_stats(<<"l">>, #client{pid = Self} = Client, Server) ->
    case briskd_oper:is_operator(Self) of
        false ->
            report_own_link_stats(Client, Server),
            briskd_state_send:numeric(
                Client, Server, <<"219">>, [<<"l">>], <<"End of STATS report">>
            );
        true ->
            Label = active_label(Self),
            Ctx = briskd_reply:from_client(Client, Server, Label),
            Job = {stats_links, Ctx},
            EndSpec = {<<"219">>, [<<"l">>], <<"End of STATS report">>},
            run_expensive(Job, Client, Server, EndSpec)
    end;
report_stats(<<"o">>, #client{pid = Self} = Client, Server) ->
    case briskd_oper:is_operator(Self) of
        true ->
            lists:foreach(
                fun(Name) ->
                    briskd_state_send:numeric(
                        Client, Server, <<"243">>, [<<"O">>, <<"*">>, <<"*">>, Name], none
                    )
                end,
                briskd_oper:operator_names()
            );
        false ->
            briskd_state_send:numeric(
                Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>
            )
    end,
    briskd_state_send:numeric(Client, Server, <<"219">>, [<<"o">>], <<"End of STATS report">>);
report_stats(Query, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"219">>, [Query], <<"End of STATS report">>).

report_own_link_stats(#client{pid = Self} = Client, Server) ->
    case {mnesia:dirty_read(client, Self), briskd_state_client:connection_stats(Self)} of
        {
            [#client{nick = Nick}],
            #{
                sent_messages := SentMessages,
                sent_bytes := SentBytes,
                recv_messages := RecvMessages,
                recv_bytes := RecvBytes,
                connected_at := ConnectedAt
            }
        } ->
            Open = max(0, erlang:monotonic_time(second) - ConnectedAt),
            briskd_state_send:numeric(
                Client,
                Server,
                <<"211">>,
                [
                    Nick,
                    <<"0">>,
                    integer_to_binary(SentMessages),
                    integer_to_binary(SentBytes div 1024),
                    integer_to_binary(RecvMessages),
                    integer_to_binary(RecvBytes div 1024),
                    integer_to_binary(Open)
                ],
                none
            );
        _ ->
            ok
    end.

trace_user(#client{pid = Pid, nick = Nick}, Client, Server) ->
    {Reply, Label} =
        case briskd_oper:is_operator(Pid) of
            true -> {<<"204">>, <<"Oper">>};
            false -> {<<"205">>, <<"User">>}
        end,
    briskd_state_send:numeric(Client, Server, Reply, [Label, <<"0">>, Nick], none).

run_expensive(Job, #client{pid = Pid} = Client, Server, {EndNum, EndParams, EndText}) ->
    case whereis(briskd_state) =:= self() of
        true ->
            Work = fun() -> execute_admitted(Pid, Job) end,
            Then = fun(Outcome) ->
                case Outcome of
                    {ok, ok} ->
                        %% The worker already delivered all lines (including
                        %% any labeled-response wrapper) directly via briskd_reply.
                        _ = erase(briskd_label),
                        ok;
                    {ok, {error, disconnected}} ->
                        _ = erase(briskd_label),
                        ok;
                    _ ->
                        %% Busy, timeout, slow consumer, or worker error:
                        %% finish cleanly in the restored reply context.
                        briskd_state_send:numeric(Client, Server, EndNum, EndParams, EndText),
                        ok
                end
            end,
            briskd_deferred:request(Work, Then);
        false ->
            case execute_admitted(Pid, Job) of
                ok ->
                    ok;
                {error, disconnected} ->
                    ok;
                _ ->
                    briskd_state_send:numeric(Client, Server, EndNum, EndParams, EndText),
                    ok
            end
    end.

execute_admitted(SessionPid, Job) ->
    case acquire_slot(SessionPid) of
        false ->
            {error, busy};
        true ->
            try
                run_worker(Job)
            after
                release_slot(SessionPid)
            end
    end.

run_worker(Job) ->
    case whereis(briskd_query_sup) of
        undefined ->
            briskd_query_worker:execute(Job);
        _ ->
            Ref = make_ref(),
            case briskd_query_sup:start_worker({Job, self(), Ref}) of
                {ok, WorkerPid} when is_pid(WorkerPid) ->
                    Mref = erlang:monitor(process, WorkerPid),
                    receive
                        {Ref, Result} ->
                            erlang:demonitor(Mref, [flush]),
                            Result;
                        {'DOWN', Mref, process, WorkerPid, Reason} ->
                            {error, {worker, Reason}}
                    after ?WORKER_WAIT_MS ->
                        erlang:demonitor(Mref, [flush]),
                        exit(WorkerPid, kill),
                        {error, timeout}
                    end;
                {error, Reason} ->
                    {error, {worker, Reason}}
            end
    end.

acquire_slot(SessionPid) ->
    case ets:whereis(?ACTIVE_TABLE) of
        undefined ->
            true;
        _ ->
            Total =
                case ets:info(?ACTIVE_TABLE, size) of
                    N when is_integer(N) -> N;
                    _ -> 0
                end,
            PerSession = ets:lookup(?ACTIVE_TABLE, SessionPid),
            case Total < ?MAX_WORKERS andalso length(PerSession) < ?MAX_PER_SESSION of
                true ->
                    ets:insert_new(?ACTIVE_TABLE, {SessionPid, self()});
                false ->
                    false
            end
    end.

release_slot(SessionPid) ->
    case ets:whereis(?ACTIVE_TABLE) of
        undefined -> ok;
        _ -> ets:delete_object(?ACTIVE_TABLE, {SessionPid, self()})
    end,
    ok.

active_label(Pid) ->
    case get(briskd_label) of
        {Pid, Label, _} when is_binary(Label) -> Label;
        _ -> undefined
    end.
