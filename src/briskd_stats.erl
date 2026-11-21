-module(briskd_stats).
-moduledoc """
Server statistics over time for the admin panel's Stats tab.

A `gen_server` that samples the server every 5 seconds and keeps the last
720 samples (one hour at that period) in memory. Nothing is persisted: a restart starts an
empty history. A sample reads only ETS and Mnesia table sizes, process and
VM statistics, and the traffic counters below, never a call to
`m:briskd_state`, so sampling continues while the state process is saturated,
which is when the charts matter most.

Each sample holds:

- `t`: wall-clock time, milliseconds since the Unix epoch.
- `sessions` (local connections), `registered` (local users past the
  welcome), `remote_users`, `channels`, and `links` (connected server peers).
- `state_queue` and `state_memory`: the message queue length and memory, in
  bytes, of `m:briskd_state`, the single writer of protocol state. A growing
  queue is the first sign of saturation.
- `memory_total`, `memory_processes`, `memory_binary`, and `memory_ets`:
  `erlang:memory/1`, bytes.
- `processes`: Erlang processes; `run_queue`: processes waiting for a
  scheduler; `scheduler_util`: busy share of the normal schedulers since the
  previous sample, percent.
- `lines_in`, `lines_out`, `bytes_in`, `bytes_out`, `connections`, and
  `rejected`: per-second rates since the previous sample, from the counters
  below; `null` in the first sample.

Traffic counters are an OTP `counters` array created by `init_counters/0`
when the application starts and kept in `persistent_term` (created once,
read on every count). `count_traffic/3` adds a client or peer line received
or written, `count_connection/0` an accepted connection, and
`count_rejected/0` a connection refused by `max_clients`. Before
`init_counters/0` they do nothing. Counts are server totals, never per
nickname or channel.
""".
-behaviour(gen_server).

-export([
    start_link/0,
    init_counters/0,
    count_traffic/3,
    count_connection/0,
    count_rejected/0,
    history/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Default sampling period, milliseconds (application env `stats_interval`
%% overrides it; tests use a short one).
-define(INTERVAL_MS, 5000).
%% Samples kept: one hour at ?INTERVAL_MS.
-define(MAX_SAMPLES, 720).
-define(COUNTERS, {?MODULE, counters}).
%% Counter indexes.
-define(LINES_IN, 1).
-define(BYTES_IN, 2).
-define(LINES_OUT, 3).
-define(BYTES_OUT, 4).
-define(CONNECTIONS, 5).
-define(REJECTED, 6).
-define(COUNTER_SIZE, 6).

-type sample() :: #{atom() => number() | null}.
-type history() :: #{interval_ms := pos_integer(), samples := [sample()]}.
-export_type([sample/0, history/0]).

-doc "Start the sampler, registered as `briskd_stats`.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Create the traffic counters, once per node: an existing array is kept, so an
application restart does not replace the `persistent_term` value.
""".
-spec init_counters() -> ok.
init_counters() ->
    case persistent_term:get(?COUNTERS, undefined) of
        undefined ->
            persistent_term:put(?COUNTERS, counters:new(?COUNTER_SIZE, [write_concurrency]));
        _ ->
            ok
    end.

-doc """
Count one line of `Bytes` octets received from (`in`) or written to (`out`) a
connection. `Lines` is the number of lines those bytes carry.
""".
-spec count_traffic(in | out, pos_integer(), non_neg_integer()) -> ok.
count_traffic(Direction, Lines, Bytes) ->
    case persistent_term:get(?COUNTERS, undefined) of
        undefined ->
            ok;
        Ref ->
            {LinesIx, BytesIx} =
                case Direction of
                    in -> {?LINES_IN, ?BYTES_IN};
                    out -> {?LINES_OUT, ?BYTES_OUT}
                end,
            counters:add(Ref, LinesIx, Lines),
            counters:add(Ref, BytesIx, Bytes)
    end.

-doc "Count one accepted connection.".
-spec count_connection() -> ok.
count_connection() ->
    bump(?CONNECTIONS).

-doc "Count one connection refused because `max_clients` was reached.".
-spec count_rejected() -> ok.
count_rejected() ->
    bump(?REJECTED).

-doc """
The samples, oldest first, and the sampling period. Answers within 5 seconds;
the sampler never waits on another process while it holds a request.
""".
-spec history() -> history().
history() ->
    gen_server:call(?MODULE, history, 5000).

interval() ->
    case application:get_env(briskd, stats_interval) of
        {ok, Ms} when is_integer(Ms), Ms >= 10 -> Ms;
        _ -> ?INTERVAL_MS
    end.

bump(Index) ->
    case persistent_term:get(?COUNTERS, undefined) of
        undefined -> ok;
        Ref -> counters:add(Ref, Index, 1)
    end.

-doc false.
init([]) ->
    %% Scheduler busy time; the flag stays on while this process lives.
    _ = erlang:system_flag(scheduler_wall_time, true),
    erlang:send_after(interval(), self(), sample),
    {ok, #{
        samples => queue:new(),
        count => 0,
        previous => snapshot(),
        previous_at => erlang:monotonic_time(millisecond)
    }}.

-doc false.
handle_call(history, _From, #{samples := Samples} = State) ->
    {reply, #{interval_ms => interval(), samples => queue:to_list(Samples)}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-doc false.
handle_cast(_Message, State) ->
    {noreply, State}.

-doc false.
handle_info(sample, State) ->
    erlang:send_after(interval(), self(), sample),
    {noreply, take_sample(State)};
handle_info(_Message, State) ->
    {noreply, State}.

take_sample(
    #{samples := Samples, count := Count, previous := Previous, previous_at := PreviousAt} =
        State
) ->
    Now = erlang:monotonic_time(millisecond),
    Snapshot = snapshot(),
    Seconds = max(1, Now - PreviousAt) / 1000,
    Sample = maps:merge(gauges(), rates(Previous, Snapshot, Seconds)),
    {Kept, Size} =
        case Count >= ?MAX_SAMPLES of
            true -> {queue:drop(Samples), Count};
            false -> {Samples, Count + 1}
        end,
    State#{
        samples := queue:in(Sample, Kept),
        count := Size,
        previous := Snapshot,
        previous_at := Now
    }.

%% Counter values and scheduler wall time at one instant.
snapshot() ->
    Counters =
        case persistent_term:get(?COUNTERS, undefined) of
            undefined -> undefined;
            Ref -> [counters:get(Ref, I) || I <- lists:seq(1, ?COUNTER_SIZE)]
        end,
    #{counters => Counters, wall => scheduler_wall()}.

%% {Active, Total} summed over the normal schedulers, or undefined.
scheduler_wall() ->
    Normal = erlang:system_info(schedulers),
    case erlang:statistics(scheduler_wall_time) of
        List when is_list(List) ->
            lists:foldl(
                fun
                    ({Id, Active, Total}, {A, T}) when Id =< Normal -> {A + Active, T + Total};
                    (_, Acc) -> Acc
                end,
                {0, 0},
                List
            );
        _ ->
            undefined
    end.

rates(#{counters := Before, wall := WallBefore}, #{counters := After, wall := WallAfter}, Seconds) ->
    Names = [lines_in, bytes_in, lines_out, bytes_out, connections, rejected],
    Rates =
        case {Before, After} of
            {[_ | _], [_ | _]} ->
                maps:from_list(
                    lists:zipwith3(
                        fun(Name, B, A) -> {Name, round1(max(0, A - B) / Seconds)} end,
                        Names,
                        Before,
                        After
                    )
                );
            _ ->
                maps:from_list([{Name, null} || Name <- Names])
        end,
    Util =
        case {WallBefore, WallAfter} of
            {{A0, T0}, {A1, T1}} when T1 > T0 -> round1(100 * (A1 - A0) / (T1 - T0));
            _ -> null
        end,
    Rates#{scheduler_util => Util}.

gauges() ->
    {StateQueue, StateMemory} =
        case whereis(briskd_state) of
            Pid when is_pid(Pid) ->
                case erlang:process_info(Pid, [message_queue_len, memory]) of
                    [{message_queue_len, Q}, {memory, M}] -> {Q, M};
                    _ -> {null, null}
                end;
            _ ->
                {null, null}
        end,
    #{
        t => erlang:system_time(millisecond),
        sessions => ets_size(briskd_connection_stats),
        registered => ets_size(briskd_ready_clients),
        remote_users => table_size(remote_client),
        channels => table_size(channel),
        links => links(),
        state_queue => StateQueue,
        state_memory => StateMemory,
        memory_total => erlang:memory(total),
        memory_processes => erlang:memory(processes),
        memory_binary => erlang:memory(binary),
        memory_ets => erlang:memory(ets),
        processes => erlang:system_info(process_count),
        run_queue => erlang:statistics(total_run_queue_lengths)
    }.

%% Connected server peers: names in the outbound and inbound link tables,
%% counted once when a peer has both.
links() ->
    Names = lists:usort(
        [
            briskd_wire:fold(Name)
         || Table <- [briskd_outbound_ready, briskd_inbound_peers],
            ets:whereis(Table) =/= undefined,
            {_Fold, {Pid, Name}} <- ets:tab2list(Table),
            is_pid(Pid),
            is_binary(Name)
        ]
    ),
    length(Names).

ets_size(Table) ->
    case ets:info(Table, size) of
        N when is_integer(N) -> N;
        _ -> null
    end.

table_size(Table) ->
    try mnesia:table_info(Table, size) of
        N when is_integer(N) -> N;
        _ -> null
    catch
        exit:_ -> null
    end.

round1(X) ->
    round(X * 10) / 10.
