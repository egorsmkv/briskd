-module(ircd_search).
-moduledoc """
Message search through the ircd-search service (the
`egorsmkv.github.io/search` extension; see `docs/search.md`).

The service (`search/` in this repository) holds a Tantivy index of the
messages this server keeps in its stored history, and nothing more: the
index mirrors `m:ircd_state_history`. Every history change is forwarded
here: a stored `PRIVMSG` or `NOTICE` is added (`note_add/4`), a message
trimmed by `history_limit` is removed (`note_delete/3`), and a deleted or
rewritten conversation (redaction, edit, account erasure, a destroyed
channel) is removed whole (`note_delete_conv/2`) before its rows are written
again. End-to-end encrypted messages (`+egorsmkv.github.io/e2ee-*` tags),
`TAGMSG`, and events are never sent: the server cannot read the first, and
the others carry no text.

This process owns the queue of index operations. The `note_*` functions
cast and return at once, so a slow or absent service never delays the state
process. Operations go out in batches (`POST /index`) every 200 milliseconds
or at 2000 operations. At most 100000 wait: past that the queue is dropped
and the index rebuilt. The index is also rebuilt from Mnesia when this
process starts and whenever the service answers again after a failed
request: a `clear` followed by every stored message, in batches. Operations
queued meanwhile are applied after it; adding a message replaces any
document with the same id, so the index converges on the history. Failures
are retried after 5 seconds, doubling to 60, and logged when the service
goes down and when it is back (`search_unavailable`, `search_ready`).

`search/4` runs a query (`POST /search`) for the conversations a user may
read; it is called from an `m:ircd_deferred` worker, never from the state
process. The service returns message ids only; `m:ircd_state_search` loads
the messages from the history, so a message deleted since it was indexed is
never shown.

Document ids name a conversation and the message's sequence number in it:
`c <channel>` for a channel (folded name) and `d <party> <party>` for direct
messages, a party being `a:<account>` or `n:<nick>`. A name that is not
valid UTF-8 is written as `~` and its hexadecimal bytes. The text sent is
the message body (`draft/multiline` lines joined), with a CTCP `ACTION`
reduced to its text; invalid UTF-8 becomes U+FFFD.
""".
-behaviour(gen_server).

-export([
    start_link/0,
    enabled/0,
    cap_value/0,
    note_add/4,
    note_delete/3,
    note_delete_conv/2,
    conv_id/2,
    search/4
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

%% Flush the queue this long after its first operation, ms.
-define(FLUSH_MS, 200).
%% Operations per POST /index.
-define(BATCH, 2000).
%% Queued operations before the queue is dropped for a rebuild.
-define(MAX_QUEUE, 100000).
%% Retry delays after a failure, ms.
-define(RETRY_MIN_MS, 5000).
-define(RETRY_MAX_MS, 60000).
%% Largest response accepted from the service, bytes.
-define(MAX_RESPONSE, 4 * 1024 * 1024).

-type history_table() :: channel_message | direct_message.
-type hit() :: #{conv := binary(), seq := pos_integer(), time := integer()}.
-export_type([hit/0]).

-doc "Start the indexer, registered as `ircd_search` (only when `search` is configured).".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Whether message search is configured.".
-spec enabled() -> boolean().
enabled() ->
    config() =/= null.

-doc "The `egorsmkv.github.io/search` capability value: `limit=<max_results>`.".
-spec cap_value() -> binary().
cap_value() ->
    #{max_results := Max} = config(),
    <<"limit=", (integer_to_binary(Max))/binary>>.

-doc """
A message was stored in history: index it, unless it has no searchable text
or is end-to-end encrypted. Returns at once.
""".
-spec note_add(history_table(), term(), pos_integer(), map()) -> ok.
note_add(Tab, Conv, Seq, Entry) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            case document(Tab, Conv, Seq, Entry) of
                skip -> ok;
                Op -> gen_server:cast(Pid, {op, Op})
            end
    end.

-doc "A message left history (trimmed by `history_limit`): remove it from the index.".
-spec note_delete(history_table(), term(), pos_integer()) -> ok.
note_delete(Tab, Conv, Seq) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid, {op, #{op => delete, id => doc_id(conv_id(Tab, Conv), Seq)}})
    end.

-doc "A conversation's history was deleted or is about to be rewritten.".
-spec note_delete_conv(history_table(), term()) -> ok.
note_delete_conv(Tab, Conv) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid, {op, #{op => delete_conv, conv => conv_id(Tab, Conv)}})
    end.

-doc """
The index's name for a history conversation: `c <channel>` or
`d <party> <party>` (see the module documentation).
""".
-spec conv_id(history_table(), term()) -> binary().
conv_id(channel_message, Channel) when is_binary(Channel) ->
    <<"c ", (name(Channel))/binary>>;
conv_id(direct_message, {A, B}) ->
    <<"d ", (party(A))/binary, " ", (party(B))/binary>>.

-doc """
Search the conversations `Convs` (index names from `conv_id/2`) for `Query`:
at most `Limit` hits, newest first, older than `Before` (milliseconds) when
it is an integer. Returns the hits and the total number of matches. Makes an
HTTP request: call it from a worker, not from `m:ircd_state`.
""".
-spec search(binary(), [binary()], pos_integer(), undefined | integer()) ->
    {ok, [hit()], non_neg_integer()} | {error, term()}.
search(Query, Convs, Limit, Before) ->
    Body0 = #{q => Query, convs => Convs, limit => Limit},
    Body =
        case Before of
            undefined -> Body0;
            _ -> Body0#{before => Before}
        end,
    case post(<<"/search">>, Body) of
        {ok, #{<<"hits">> := Hits, <<"total">> := Total}} when
            is_list(Hits), is_integer(Total)
        ->
            {ok, [H || Raw <- Hits, {ok, H} <- [hit(Raw)]], Total};
        {ok, _} ->
            {error, bad_response};
        {error, _} = Error ->
            Error
    end.

hit(#{<<"id">> := Id, <<"conv">> := Conv, <<"time">> := Time}) when
    is_binary(Id), is_binary(Conv), is_integer(Time)
->
    case string:split(Id, <<" ">>, trailing) of
        [Conv, SeqText] ->
            try binary_to_integer(SeqText) of
                Seq when Seq > 0 -> {ok, #{conv => Conv, seq => Seq, time => Time}};
                _ -> error
            catch
                error:badarg -> error
            end;
        _ ->
            error
    end;
hit(_) ->
    error.

%%% Documents

document(Tab, Conv, Seq, #{cmd := Cmd, text := Body} = Entry) when
    Cmd =:= <<"PRIVMSG">>; Cmd =:= <<"NOTICE">>
->
    case {encrypted(maps:get(tags, Entry, [])), text(Body)} of
        {false, Text} when byte_size(Text) > 0 ->
            ConvId = conv_id(Tab, Conv),
            #{
                op => add,
                id => doc_id(ConvId, Seq),
                conv => ConvId,
                time => maps:get(time, Entry, 0),
                text => ircd_websocket:utf8_safe(Text)
            };
        _ ->
            skip
    end;
document(_Tab, _Conv, _Seq, _Entry) ->
    skip.

encrypted(Tags) when is_list(Tags) ->
    lists:any(
        fun
            ({Key, _}) when is_binary(Key) -> binary:match(Key, <<"/e2ee-">>) =/= nomatch;
            (_) -> false
        end,
        Tags
    );
encrypted(_) ->
    false.

text(Body) when is_binary(Body) ->
    action(Body);
%% A draft/multiline body: a line flagged `true` (multiline-concat) continues
%% the previous one; other lines start on a new line.
text({multiline, Lines}) when is_list(Lines) ->
    Parts = lists:foldl(
        fun
            ({_, Line}, []) -> [Line];
            ({true, Line}, Acc) -> [Line | Acc];
            ({_, Line}, Acc) -> [Line, <<"\n">> | Acc]
        end,
        [],
        [{Concat, L} || {Concat, L} <- Lines, is_binary(L)]
    ),
    iolist_to_binary(lists:reverse(Parts));
text(_) ->
    <<>>.

%% "\x01ACTION waves\x01" is searchable as "waves".
action(<<1, "ACTION ", Rest/binary>>) ->
    case binary:last(<<0, Rest/binary>>) of
        1 -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> Rest
    end;
action(Text) ->
    Text.

doc_id(ConvId, Seq) ->
    <<ConvId/binary, " ", (integer_to_binary(Seq))/binary>>.

party({account, Name}) when is_binary(Name) -> <<"a:", (name(Name))/binary>>;
party({nick, Name}) when is_binary(Name) -> <<"n:", (name(Name))/binary>>.

%% A name is used as is when it is valid UTF-8, so ids stay readable; other
%% bytes are hex-encoded, keeping the id unique and the JSON valid.
name(Name) ->
    case unicode:characters_to_binary(Name, utf8, utf8) of
        Name -> Name;
        _ -> <<"~", (binary:encode_hex(Name, lowercase))/binary>>
    end.

%%% Process

-doc false.
init([]) ->
    self() ! rebuild,
    {ok, #{
        queue => [],
        count => 0,
        flush => undefined,
        status => starting,
        retry => ?RETRY_MIN_MS,
        retry_timer => undefined
    }}.

-doc false.
handle_call(status, _From, #{status := Status, count := Count} = State) ->
    {reply, #{status => Status, queued => Count}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-doc false.
handle_cast({op, _Op}, #{count := Count} = State) when Count >= ?MAX_QUEUE ->
    logger:warning(#{event => search_queue_overflow, dropped => Count}),
    {noreply, schedule_rebuild(State#{queue := [], count := 0}, 0)};
handle_cast({op, Op}, #{queue := Queue, count := Count} = State) ->
    Next = State#{queue := [Op | Queue], count := Count + 1},
    case Count + 1 >= ?BATCH of
        true -> {noreply, flush(Next)};
        false -> {noreply, arm_flush(Next)}
    end;
handle_cast(_Message, State) ->
    {noreply, State}.

-doc false.
handle_info(flush, State) ->
    {noreply, flush(State#{flush := undefined})};
handle_info(rebuild, State) ->
    {noreply, rebuild(State#{retry_timer := undefined})};
handle_info(_Message, State) ->
    {noreply, State}.

-doc false.
format_status(Status) ->
    %% Queued operations carry message text.
    maps:map(
        fun
            (state, #{queue := _} = S) -> S#{queue := redacted};
            (_, V) -> V
        end,
        Status
    ).

arm_flush(#{flush := undefined} = State) ->
    State#{flush := erlang:send_after(?FLUSH_MS, self(), flush)};
arm_flush(State) ->
    State.

%% While a rebuild is pending, operations only queue: the rebuild replays
%% the whole history and they are applied after it.
flush(#{status := Status} = State) when Status =/= ready ->
    State;
flush(#{queue := []} = State) ->
    State;
flush(#{queue := Queue} = State0) ->
    State = cancel_flush(State0),
    case send_ops(lists:reverse(Queue)) of
        ok -> State#{queue := [], count := 0};
        {error, Reason} -> failed(Reason, State#{queue := [], count := 0})
    end.

cancel_flush(#{flush := undefined} = State) ->
    State;
cancel_flush(#{flush := Ref} = State) ->
    _ = erlang:cancel_timer(Ref),
    State#{flush := undefined}.

send_ops([]) ->
    ok;
send_ops(Ops) ->
    {Batch, Rest} = lists:split(min(?BATCH, length(Ops)), Ops),
    case post(<<"/index">>, #{ops => Batch}) of
        {ok, _} -> send_ops(Rest);
        {error, _} = Error -> Error
    end.

%% Clear the index and send every stored message, then the queued operations.
rebuild(State) ->
    Started = erlang:monotonic_time(millisecond),
    Result =
        try
            Pending = ircd_state_history:fold_messages(
                fun(Tab, Conv, Seq, Entry, Acc) ->
                    case document(Tab, Conv, Seq, Entry) of
                        skip -> Acc;
                        Op -> push(Op, Acc)
                    end
                end,
                {[#{op => clear}], 1}
            ),
            {Last, _} = Pending,
            send_ops(lists:reverse(Last))
        catch
            throw:{search_failed, Failure} -> {error, Failure}
        end,
    case Result of
        ok ->
            WasDown = maps:get(status, State) =:= down,
            log_ready(WasDown, erlang:monotonic_time(millisecond) - Started),
            flush(State#{status := ready, retry := ?RETRY_MIN_MS});
        {error, Reason} ->
            failed(Reason, State)
    end.

%% Accumulate rebuild operations, sending a batch whenever one fills.
push(Op, {Acc, N}) when N + 1 >= ?BATCH ->
    case send_ops(lists:reverse([Op | Acc])) of
        ok -> {[], 0};
        {error, Reason} -> throw({search_failed, Reason})
    end;
push(Op, {Acc, N}) ->
    {[Op | Acc], N + 1}.

log_ready(WasDown, Ms) ->
    logger:notice(#{event => search_ready, recovered => WasDown, rebuild_ms => Ms}).

failed(Reason, #{status := Status, retry := Retry} = State) ->
    case Status of
        down -> ok;
        _ -> logger:warning(#{event => search_unavailable, reason => Reason, retry_ms => Retry})
    end,
    schedule_rebuild(
        State#{status := down, retry := min(Retry * 2, ?RETRY_MAX_MS)}, Retry
    ).

schedule_rebuild(#{retry_timer := undefined} = State, Delay) ->
    State#{
        status := down,
        retry_timer := erlang:send_after(Delay, self(), rebuild)
    };
schedule_rebuild(State, _Delay) ->
    State#{status := down}.

%%% HTTP

config() ->
    maps:get(search, ircd_config:current_or_empty(), null).

post(Path, Body) ->
    case config() of
        null ->
            {error, disabled};
        #{url := Url, token := Token, timeout := Timeout} ->
            Headers = [
                {<<"content-type">>, <<"application/json">>},
                {<<"accept">>, <<"application/json">>}
                | case Token of
                    undefined -> [];
                    _ -> [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
                end
            ],
            Opts = [
                {recv_timeout, Timeout},
                {connect_timeout, min(Timeout, 5000)},
                {follow_redirect, false},
                {max_body_size, ?MAX_RESPONSE}
            ],
            Json = iolist_to_binary(json:encode(Body)),
            try hackney:request(post, <<Url/binary, Path/binary>>, Headers, Json, Opts) of
                {ok, Status, _RespHeaders, Resp} when
                    Status >= 200, Status < 300, is_binary(Resp)
                ->
                    decode(Resp);
                {ok, Status, _RespHeaders, _Resp} ->
                    {error, {http_status, Status}};
                {error, Reason} ->
                    {error, Reason}
            catch
                error:Reason -> {error, Reason}
            end
    end.

decode(Resp) ->
    try json:decode(Resp) of
        Map when is_map(Map) -> {ok, Map};
        _ -> {error, bad_response}
    catch
        error:_ -> {error, bad_response}
    end.
