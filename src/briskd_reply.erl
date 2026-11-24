-module(briskd_reply).
-moduledoc """
Explicit IRCv3 reply contexts for query workers running outside `m:briskd_state`.

Unlike `m:briskd_state_send`, which keeps the active label and batch state in
`briskd_state`'s process dictionary, `briskd_reply` captures an explicit
`reply_context()` value (`session`, `request_id`, `nick`, `server`, `label`)
that any supervised query worker can pass around without relying on process
dictionary state.

Supports streaming unlabeled chunks (`send_chunk/2`), delivering complete
IRCv3 `labeled-response` batches (`deliver_all/2`), filtering `server-time`
tags per recipient, and checking downstream session queue capacity for
backpressure (`wait_capacity/2`).
""".

-export([
    new/4,
    from_client/3,
    numeric_spec/3,
    send_numeric/4,
    send_chunk/2,
    deliver_all/2,
    session_alive/1,
    session_has_capacity/1,
    wait_capacity/2
]).

-include("briskd_state.hrl").

-doc "Explicit reply target and IRCv3 label metadata.".
-type reply_context() :: #{
    session := pid(),
    request_id := reference(),
    nick := binary(),
    server := binary(),
    label := binary() | undefined
}.

-doc "A numeric reply specification `{Number, MiddleParams, TrailingText}`.".
-type line_spec() :: {binary(), [binary()], none | iodata()}.

-export_type([reply_context/0, line_spec/0]).

-doc "Construct a `reply_context()` for `Session`.".
-spec new(pid(), binary(), binary(), binary() | undefined) -> reply_context().
new(Session, Nick, Server, Label) ->
    #{
        session => Session,
        request_id => make_ref(),
        nick => Nick,
        server => Server,
        label => Label
    }.

-doc "Construct a `reply_context()` from a `#client{}` record.".
-spec from_client(#client{}, binary(), binary() | undefined) -> reply_context().
from_client(#client{pid = Pid, nick = Nick}, Server, Label) ->
    new(Pid, Nick, Server, Label).

-doc "Build a numeric `line_spec()`.".
-spec numeric_spec(binary(), [binary()], none | iodata()) -> line_spec().
numeric_spec(Number, Params, Text) ->
    {Number, Params, Text}.

-doc "Send a single numeric reply honouring `label` in `Ctx`.".
-spec send_numeric(reply_context(), binary(), [binary()], none | iodata()) -> ok.
send_numeric(Ctx, Number, Params, Text) ->
    deliver_all(Ctx, [{Number, Params, Text}]).

-doc """
Encode and send a chunk of numeric `line_spec()` replies directly to the
target session. Used for streaming unlabeled queries (`label =:= undefined`).
""".
-spec send_chunk(reply_context(), [line_spec()]) -> ok.
send_chunk(_Ctx, []) ->
    ok;
send_chunk(#{session := Pid, nick := Nick, server := Server}, Specs) ->
    Enabled = briskd_cap:enabled_set(Pid),
    Tags = visible_tags(Enabled, []),
    lists:foreach(
        fun({Number, Params, Text}) ->
            deliver_encoded(Pid, briskd_wire:message(Tags, Server, Number, [Nick | Params], Text))
        end,
        Specs
    ).

-doc """
Deliver a complete list of numeric `line_spec()` replies, wrapping them in an
IRCv3 `labeled-response` (single tagged reply, `labeled-response` batch, or
`ACK`) when `label` is set in `Ctx`.
""".
-spec deliver_all(reply_context(), [line_spec()]) -> ok.
deliver_all(#{label := undefined} = Ctx, Specs) ->
    send_chunk(Ctx, Specs);
deliver_all(#{session := Pid, server := Server, label := Label}, []) when is_binary(Label) ->
    Enabled = briskd_cap:enabled_set(Pid),
    Tags = visible_tags(Enabled, [{<<"label">>, Label}]),
    deliver_encoded(Pid, briskd_wire:message(Tags, Server, <<"ACK">>, [], none));
deliver_all(#{session := Pid, nick := Nick, server := Server, label := Label}, [
    {Number, Params, Text}
]) when is_binary(Label) ->
    Enabled = briskd_cap:enabled_set(Pid),
    Tags = visible_tags(Enabled, [{<<"label">>, Label}]),
    deliver_encoded(Pid, briskd_wire:message(Tags, Server, Number, [Nick | Params], Text));
deliver_all(#{session := Pid, nick := Nick, server := Server, label := Label}, Specs) when
    is_binary(Label)
->
    Enabled = briskd_cap:enabled_set(Pid),
    Ref = unique_batch_ref(),
    OpenTags = visible_tags(Enabled, [{<<"label">>, Label}]),
    deliver_encoded(
        Pid,
        briskd_wire:message(
            OpenTags, Server, <<"BATCH">>, [<<"+", Ref/binary>>, <<"labeled-response">>], none
        )
    ),
    ItemTags = visible_tags(Enabled, [{<<"batch">>, Ref}]),
    lists:foreach(
        fun({Number, Params, Text}) ->
            deliver_encoded(
                Pid, briskd_wire:message(ItemTags, Server, Number, [Nick | Params], Text)
            )
        end,
        Specs
    ),
    CloseTags = visible_tags(Enabled, []),
    deliver_encoded(
        Pid, briskd_wire:message(CloseTags, Server, <<"BATCH">>, [<<"-", Ref/binary>>], none)
    ).

-doc "True when session `Pid` is alive.".
-spec session_alive(pid()) -> boolean().
session_alive(Pid) ->
    is_process_alive(Pid).

-doc "True when session `Pid` is alive and its mailbox is below half of `max_sendq`.".
-spec session_has_capacity(pid()) -> boolean().
session_has_capacity(Pid) ->
    Limit = max_sendq(),
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} -> Len < max(1, Limit div 2);
        undefined -> false
    end.

-doc """
Wait until session `Pid` has queue capacity or `DeadlineMs` expires.

Returns `ok`, `{error, disconnected}` if the session exited, or
`{error, slow_consumer}` if the session mailbox remains saturated past
`DeadlineMs`.
""".
-spec wait_capacity(pid(), integer()) -> ok | {error, disconnected | slow_consumer}.
wait_capacity(Pid, DeadlineMs) ->
    case session_alive(Pid) of
        false ->
            {error, disconnected};
        true ->
            case session_has_capacity(Pid) of
                true ->
                    ok;
                false ->
                    Now = erlang:monotonic_time(millisecond),
                    case Now >= DeadlineMs of
                        true ->
                            {error, slow_consumer};
                        false ->
                            timer:sleep(min(20, DeadlineMs - Now)),
                            wait_capacity(Pid, DeadlineMs)
                    end
            end
    end.

%% Internal helpers

visible_tags(Enabled, Tags) ->
    case maps:is_key(<<"server-time">>, Enabled) of
        true -> [briskd_state_send:time_tag() | Tags];
        false -> Tags
    end.

deliver_encoded(_Pid, []) ->
    ok;
deliver_encoded(Pid, Line) ->
    Pid ! {irc, Line},
    ok.

unique_batch_ref() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic]), 36).

max_sendq() ->
    #{limits := #{max_sendq := MaxSendQ}} = briskd_rehash:current(),
    MaxSendQ.
