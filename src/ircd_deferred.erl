-module(ircd_deferred).
-export([request/2, take/0, start/5, resume/3, in_flight/0, run/1]).

-moduledoc """
Deferred command replies for work too slow for the `m:ircd_state` process.

`ircd_state` is the single writer for protocol state, so a costly computation
inside a command (the PBKDF2 derivation of SASL `PLAIN` and `REGISTER`, about
4096 HMAC-SHA-256 rounds) would stall every other client. Such a command
calls `request/2` with the pure work and a continuation. `ircd_state` then:

1. takes the request (`take/0`) after dispatch, suspends the command's reply
   context (labeled-response collector and source tags), and starts a
   monitored worker process that runs the work (`start/5`);
2. keeps serving other clients; the calling session stays blocked in its
   `gen_server:call`, so its own commands stay in order (a `CAP END`
   pipelined after `AUTHENTICATE` still sees the login);
3. on the worker's `'DOWN'` (`resume/3`), restores the reply context, runs
   the continuation with `{ok, Result}` or `{error, Reason}` in the state
   process, ends the label, and answers the session with `gen_server:reply/2`.

At most `?MAX_IN_FLIGHT` workers run at once. Past that the continuation runs
immediately with `{error, busy}`, so the command fails fast (SASL 904,
`FAIL REGISTER TEMPORARILY_UNAVAILABLE`) instead of queueing without bound.

Secrets stay out of the state process: only the worker's closure holds the
password. The pending job stored here (process dictionary of `ircd_state`,
visible in `sys:get_status/1`) holds the caller, the reply context, and the
continuation, which must not capture the password.

If the client disconnects while its worker runs, the result is dropped and
the session (already gone) gets no reply. A worker that crashes resumes the
continuation with `{error, {worker, Reason}}`.
""".

-include("ircd_state.hrl").

%% Workers allowed at once (implementation policy). A derivation takes a few
%% milliseconds, so this bounds CPU use and memory under a login flood.
-define(MAX_IN_FLIGHT, 32).
-define(REQUEST, ircd_deferred_request).
-define(COUNT, ircd_deferred_count).

-type work() :: fun(() -> term()).
-type continuation() :: fun(({ok, term()} | {error, term()}) -> term()).
-export_type([work/0, continuation/0]).

-doc """
Ask `ircd_state` to run `Work` in a worker and finish the current command with
`Then` (called in the state process with `{ok, Result}`, `{error, busy}`, or
`{error, {worker, Reason}}`). Call it at most once per command, as the last
step of the command's handler; the command's return value is replaced by what
`Then` returns. `Then` must not capture secrets.
""".
-spec request(work(), continuation()) -> ok.
request(Work, Then) when is_function(Work, 0), is_function(Then, 1) ->
    undefined = put(?REQUEST, {Work, Then}),
    ok.

-doc "Take the request made by `request/2` during the current command, if any.".
-spec take() -> none | {work(), continuation()}.
take() ->
    case erase(?REQUEST) of
        undefined -> none;
        Request -> Request
    end.

-doc """
Start a request taken with `take/0` for the session `Pid` whose call is
`From`. Returns `{noreply, Server}` when a worker started, or
`{reply, Reply, Server}` when the pool was full and `Then({error, busy})`
already ran in the current reply context.
""".
-spec start(gen_server:from(), pid(), work(), continuation(), binary()) ->
    {noreply, binary()} | {reply, term(), binary()}.
start(From, Pid, Work, Then, Server) ->
    case in_flight() < ?MAX_IN_FLIGHT of
        true ->
            Context = ircd_state_send:suspend_reply(),
            {_Worker, Ref} = spawn_monitor(?MODULE, run, [Work]),
            put({?MODULE, Ref}, #{from => From, pid => Pid, then => Then, context => Context}),
            put(?COUNT, in_flight() + 1),
            {noreply, Server};
        false ->
            logger:warning(#{event => deferred_busy, in_flight => in_flight()}),
            Reply = Then({error, busy}),
            finish(Server),
            {reply, Reply, Server}
    end.

-doc """
Handle a `'DOWN'` message in `ircd_state`. Returns `handled` when `Ref` is a
worker started here (the deferred reply has been sent), or `not_ours`.
""".
-spec resume(reference(), term(), binary()) -> handled | not_ours.
resume(Ref, Reason, Server) ->
    case erase({?MODULE, Ref}) of
        undefined ->
            not_ours;
        #{from := From, pid := Pid, then := Then, context := Context} ->
            put(?COUNT, max(0, in_flight() - 1)),
            Result =
                case Reason of
                    {?MODULE, done, Value} -> {ok, Value};
                    Other -> {error, {worker, Other}}
                end,
            case mnesia:dirty_read(client, Pid) of
                [_] ->
                    ircd_state_send:resume_reply(Context),
                    Reply =
                        try
                            Then(Result)
                        after
                            finish(Server)
                        end,
                    ircd_state_client:touch_activity(Pid),
                    gen_server:reply(From, Reply);
                [] ->
                    %% The client left while the worker ran: nothing to say.
                    ok
            end,
            handled
    end.

-doc """
Worker body: run `Work` and exit with `{ircd_deferred, done, Result}`. The
exit reason carries the result to the monitoring `ircd_state` process.
""".
-spec run(work()) -> no_return().
run(Work) ->
    exit({?MODULE, done, Work()}).

-doc "Number of workers currently running.".
-spec in_flight() -> non_neg_integer().
in_flight() ->
    case get(?COUNT) of
        undefined -> 0;
        Count -> Count
    end.

finish(Server) ->
    ircd_state_send:end_label(Server),
    ircd_state_send:clear_source().
