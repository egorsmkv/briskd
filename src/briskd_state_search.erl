-module(briskd_state_search).
-moduledoc """
The `SEARCH` command of the `egorsmkv.github.io/search` extension (see
`docs/search.md`), handled for `m:briskd_state`.

```text
SEARCH <target> <limit> [timestamp=<time>] :<query>
```

`<target>` is a channel the client is a member of, a nickname or account (the
direct conversation with it; the client must be logged in), or `*` for every
channel the client is in and every direct conversation of its account: the
same access as `CHATHISTORY`. `<limit>` is at least 1 and is lowered to the
capability's `limit`. `timestamp=` (RFC 3339) returns only messages older
than that time, for paging; `*` in its place means no bound. `<query>` is
1 to 300 bytes in the service's query syntax: words (all must match),
`"a phrase"`, `prefix*`, `-excluded`, `a OR b`.

Results come newest first in a batch of type `egorsmkv.github.io/search`
whose parameters are the target and the total number of matches. Each result
is the stored message replayed as `CHATHISTORY` does, with its `msgid` and
`time` tags, addressed to its channel or, for a direct message, to its
stored target. Only this server's stored history is searched, as far back as
`history_limit` keeps it.

Errors are standard replies: `FAIL SEARCH NEED_MORE_PARAMS`,
`INVALID_PARAMS` (limit, timestamp, or query), `INVALID_TARGET` (not a
channel the client is in, or a nickname while not logged in), and
`TEMPORARILY_UNAVAILABLE` (the service did not answer, or the server is busy).
Without `search` configured the command is unknown (421).

The query runs in an `m:briskd_deferred` worker, so the state process keeps
serving others while the service answers. When 24 or more deferred workers
are busy, `SEARCH` fails at once, keeping room for logins (SASL and
`REGISTER` use the same workers). When the result arrives the target's
conversations are resolved again, so a channel left meanwhile is not shown.
""".

-export([search/3]).

-include("briskd_state.hrl").

%% Longest query, bytes.
-define(MAX_QUERY, 300).
%% Deferred workers SEARCH may leave busy; the rest are kept for logins.
-define(MAX_DEFERRED_FOR_SEARCH, 24).
-define(BATCH_TYPE, <<"egorsmkv.github.io/search">>).

-doc "Handle `SEARCH` for a registered client.".
-spec search([binary()], #client{}, binary()) -> ok.
search(Params, #client{pid = Pid} = Client, Server) ->
    case briskd_search:enabled() of
        false ->
            briskd_state_send:numeric(
                Client, Server, <<"421">>, [<<"SEARCH">>], <<"Unknown command">>
            );
        true ->
            case parse(Params) of
                {ok, Target, Limit, Before, Query} ->
                    run(Client, Server, Target, Limit, Before, Query);
                need_more ->
                    fail(Pid, <<"NEED_MORE_PARAMS">>, [], <<"Missing parameters">>);
                {invalid, What} ->
                    fail(Pid, <<"INVALID_PARAMS">>, [What], <<"Invalid parameters">>)
            end
    end.

parse([Target, LimitText, Query]) ->
    parse([Target, LimitText, <<"*">>, Query]);
parse([Target, LimitText, BeforeText, Query0]) ->
    Query = string:trim(Query0),
    case {limit(LimitText), before(BeforeText)} of
        {error, _} ->
            {invalid, LimitText};
        {_, error} ->
            {invalid, BeforeText};
        _ when Query =:= <<>>; byte_size(Query) > ?MAX_QUERY ->
            {invalid, <<"query">>};
        {{ok, Limit}, {ok, Before}} ->
            {ok, Target, Limit, Before, Query}
    end;
parse(_) ->
    need_more.

limit(Text) ->
    #{max_results := Max} = maps:get(search, briskd_config:current()),
    try binary_to_integer(Text) of
        N when N > 0 -> {ok, min(N, Max)};
        _ -> error
    catch
        error:badarg -> error
    end.

before(<<"*">>) ->
    {ok, undefined};
before(<<"timestamp=", Value/binary>>) ->
    case briskd_state_history:parse_timestamp(Value) of
        {ok, Ms} -> {ok, Ms};
        error -> error
    end;
before(_) ->
    error.

run(#client{pid = Pid} = Client, Server, Target, Limit, Before, Query) ->
    case briskd_state_history:search_scope(Client, Target) of
        error ->
            fail(Pid, <<"INVALID_TARGET">>, [Target], <<"Messages could not be searched">>);
        {ok, []} ->
            send_results(Pid, Target, [], 0, Server);
        {ok, Scope} ->
            case briskd_deferred:in_flight() >= ?MAX_DEFERRED_FOR_SEARCH of
                true ->
                    unavailable(Pid, Target);
                false ->
                    Convs = [Id || {Id, _Source, _Replay} <- Scope],
                    briskd_deferred:request(
                        fun() -> briskd_search:search(Query, Convs, Limit, Before) end,
                        fun(Result) -> finish(Result, Pid, Target, Server) end
                    )
            end
    end.

%% Runs in the state process: every result shape has a clause, since a crash
%% here would take briskd_state down. The worker's value arrives as
%% {ok, Value}; {error, busy} and {error, {worker, _}} come from briskd_deferred.
finish({ok, {ok, Hits, Total}}, Pid, Target, Server) when is_list(Hits), is_integer(Total) ->
    Client = briskd_state_client:client(Pid),
    %% Access is decided again now: the client may have left a channel or
    %% logged out while the service answered.
    case briskd_state_history:search_scope(Client, Target) of
        {ok, Scope} ->
            Allowed = maps:from_list([{Id, {Source, Replay}} || {Id, Source, Replay} <- Scope]),
            Found = [
                {Entry, Replay}
             || #{conv := Conv, seq := Seq} <- Hits,
                {Source, Replay} <- [maps:get(Conv, Allowed, none)],
                {ok, Entry} <- [briskd_state_history:search_entry(Source, Seq)]
            ],
            send_results(Pid, Target, Found, Total, Server);
        error ->
            fail(Pid, <<"INVALID_TARGET">>, [Target], <<"Messages could not be searched">>)
    end;
finish(Other, Pid, Target, _Server) ->
    logger:debug(#{event => search_failed, reason => reason(Other)}),
    unavailable(Pid, Target).

reason({ok, {error, Reason}}) -> Reason;
reason({error, Reason}) -> Reason;
reason(_) -> bad_result.

send_results(Pid, Target, Found, Total, Server) ->
    briskd_state_send:with_batch(Pid, ?BATCH_TYPE, [Target, integer_to_binary(Total)], [], fun() ->
        lists:foreach(
            fun({Entry, Replay}) ->
                briskd_state_history:replay_entries(Pid, Replay, [Entry], Server)
            end,
            Found
        )
    end),
    ok.

unavailable(Pid, Target) ->
    fail(Pid, <<"TEMPORARILY_UNAVAILABLE">>, [Target], <<"Search is not available right now">>).

fail(Pid, Code, Context, Text) ->
    briskd_state_send:fail(Pid, <<"SEARCH">>, Code, Context, Text).
