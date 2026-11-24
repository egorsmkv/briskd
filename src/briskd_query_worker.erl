-module(briskd_query_worker).
-moduledoc """
Bounded ETS-continuation worker for streaming expensive read-only queries.

Traverses the `client` table in chunks of `?CHUNK_SIZE` (128) records via
`ets:select/3` and `ets:select/1`, monitoring the requesting session so it
cancels immediately on disconnect, enforcing a 5-second monotonic deadline, and
pausing when the session mailbox approaches `max_sendq`.

For unlabeled queries, chunks are streamed incrementally to the session via
`briskd_reply:send_chunk/2`. For IRCv3 `labeled-response` queries, specs are
collected across chunks and delivered as a single labeled batch via
`briskd_reply:deliver_all/2`.
""".

-export([start_link/1, init/1, execute/1]).

-define(CHUNK_SIZE, 128).
-define(QUERY_DEADLINE_MS, 5000).

-doc "Query job specification passed to `execute/1`.".
-type job() ::
    {trace_server, briskd_reply:reply_context(), boolean()}
    | {stats_links, briskd_reply:reply_context()}.

-doc "Argument tuple for supervised worker startup.".
-type worker_arg() :: {job(), pid(), reference()}.

-export_type([job/0, worker_arg/0]).

-doc "Start a supervised worker for `Arg`.".
-spec start_link(worker_arg()) -> {ok, pid()}.
start_link(Arg) ->
    proc_lib:start_link(?MODULE, init, [Arg]).

-doc false.
-spec init(worker_arg()) -> no_return().
init({Job, Caller, Ref}) ->
    ok = proc_lib:init_ack({ok, self()}),
    Result = execute(Job),
    Caller ! {Ref, Result},
    exit(normal).

-doc """
Execute a bounded chunked query job synchronously in the calling worker
process. Returns `ok` or `{error, disconnected | slow_consumer | timeout}`.
""".
-spec execute(job()) -> ok | {error, disconnected | slow_consumer | timeout}.
execute({trace_server, Ctx, RequesterIsOperator}) ->
    run_chunked(
        Ctx,
        fun(Rows, Acc) ->
            trace_rows(Rows, RequesterIsOperator, Acc)
        end,
        {<<"262">>, [maps:get(server, Ctx), <<"briskd-", (briskd_app:vsn())/binary>>],
            <<"End of TRACE">>}
    );
execute({stats_links, Ctx}) ->
    Now = erlang:monotonic_time(second),
    run_chunked(
        Ctx,
        fun(Rows, Acc) ->
            stats_link_rows(Rows, Now, Acc)
        end,
        {<<"219">>, [<<"l">>], <<"End of STATS report">>}
    ).

run_chunked(#{session := Session, label := Label} = Ctx, RowFun, EndSpec) ->
    Mref = erlang:monitor(process, Session),
    Deadline = erlang:monotonic_time(millisecond) + ?QUERY_DEADLINE_MS,
    Streaming = Label =:= undefined,
    %% Match spec uses the raw #client{} tuple shape: '_' is not valid in typed record fields.
    MatchSpec = [
        {{client, '$1', '_', '$2', '_', '_', '_', '_', '_'}, [{'=/=', '$2', <<"*">>}], [
            {{'$1', '$2'}}
        ]}
    ],
    try
        Initial = safe_select_init(MatchSpec),
        case chunk_loop(Initial, Session, Mref, Deadline, Streaming, Ctx, RowFun, []) of
            {ok, Collected} ->
                FinalSpecs =
                    case Streaming of
                        true ->
                            ok = briskd_reply:send_chunk(Ctx, [EndSpec]),
                            ok;
                        false ->
                            ok = briskd_reply:deliver_all(
                                Ctx, lists:reverse([EndSpec | Collected])
                            ),
                            ok
                    end,
                FinalSpecs;
            {error, _} = Err ->
                Err
        end
    after
        erlang:demonitor(Mref, [flush])
    end.

chunk_loop('$end_of_table', _Session, _Mref, _Deadline, _Streaming, _Ctx, _RowFun, Acc) ->
    {ok, Acc};
chunk_loop({Rows, Cont}, Session, Mref, Deadline, Streaming, Ctx, RowFun, Acc) ->
    case check_cancelled(Session, Mref, Deadline) of
        {error, _} = Err ->
            Err;
        ok ->
            Specs = RowFun(Rows, []),
            NextAcc =
                case Streaming of
                    true ->
                        case briskd_reply:wait_capacity(Session, Deadline) of
                            ok ->
                                ok = briskd_reply:send_chunk(Ctx, Specs),
                                Acc;
                            {error, _} = CapErr ->
                                CapErr
                        end;
                    false ->
                        lists:reverse(Specs, Acc)
                end,
            case NextAcc of
                {error, _} = Error ->
                    Error;
                _ ->
                    Next = safe_select_cont(Cont),
                    chunk_loop(Next, Session, Mref, Deadline, Streaming, Ctx, RowFun, NextAcc)
            end
    end.

check_cancelled(Session, Mref, Deadline) ->
    receive
        {'DOWN', Mref, process, Session, _} ->
            {error, disconnected}
    after 0 ->
        case erlang:monotonic_time(millisecond) >= Deadline of
            true -> {error, timeout};
            false -> ok
        end
    end.

trace_rows([], _RequesterIsOperator, Acc) ->
    lists:reverse(Acc);
trace_rows([{Pid, Nick} | Rest], RequesterIsOperator, Acc) when is_pid(Pid), is_binary(Nick) ->
    IsOperator = briskd_oper:is_operator(Pid),
    NextAcc =
        case IsOperator orelse RequesterIsOperator of
            true ->
                {Reply, Label} =
                    case IsOperator of
                        true -> {<<"204">>, <<"Oper">>};
                        false -> {<<"205">>, <<"User">>}
                    end,
                [briskd_reply:numeric_spec(Reply, [Label, <<"0">>, Nick], none) | Acc];
            false ->
                Acc
        end,
    trace_rows(Rest, RequesterIsOperator, NextAcc);
trace_rows([_ | Rest], RequesterIsOperator, Acc) ->
    trace_rows(Rest, RequesterIsOperator, Acc).

stats_link_rows([], _Now, Acc) ->
    lists:reverse(Acc);
stats_link_rows([{Pid, Nick} | Rest], Now, Acc) when is_pid(Pid), is_binary(Nick) ->
    NextAcc =
        case briskd_state_client:connection_stats(Pid) of
            #{
                sent_messages := SentMessages,
                sent_bytes := SentBytes,
                recv_messages := RecvMessages,
                recv_bytes := RecvBytes,
                connected_at := ConnectedAt
            } ->
                Open = max(0, Now - ConnectedAt),
                Spec = briskd_reply:numeric_spec(
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
                ),
                [Spec | Acc];
            _ ->
                Acc
        end,
    stats_link_rows(Rest, Now, NextAcc);
stats_link_rows([_ | Rest], Now, Acc) ->
    stats_link_rows(Rest, Now, Acc).

safe_select_init(MatchSpec) ->
    try
        ets:select(client, MatchSpec, ?CHUNK_SIZE)
    catch
        error:badarg -> '$end_of_table'
    end.

safe_select_cont(Cont) ->
    try
        ets:select(Cont)
    catch
        error:badarg -> '$end_of_table'
    end.
