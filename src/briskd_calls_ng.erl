-module(briskd_calls_ng).
-moduledoc """
Call lifecycle transitions, per-caller rate limiting, and rtpflux NG control
socket handling for `m:briskd_calls`.
""".

-include("briskd_client.hrl").
-include("briskd_remote.hrl").

-export([
    start_call/5,
    other/2,
    rekey/3,
    answer_call/4,
    ringing/3,
    hold/4,
    reject/4,
    hangup/4,
    end_call/4,
    lookup/3,
    resolve_ng/1,
    send_ng/2,
    ng_reply/3,
    nick_of/1,
    link_send/4,
    take_rate/2
]).

-define(NG_RETRY_MS, 1000).
-define(MAX_RATE_ENTRIES, 10000).

%%% Call lifecycle

-doc "Start a new call between `Caller` and `Callee`, anchoring or relaying media.".
-spec start_call(
    pid() | {remote, binary()},
    pid() | {remote, binary()},
    binary(),
    binary(),
    map()
) -> map().
start_call(Caller, Callee, Token, Sdp, #{busy := Busy, server := Server} = State) ->
    case is_map_key(Callee, Busy) orelse not alive(Callee) of
        true ->
            briskd_calls:fail(
                Caller, <<"TARGET_BUSY">>, [Token], <<"That user is busy or unavailable">>
            ),
            State;
        false when is_map_key(Caller, Busy) ->
            briskd_calls:fail(
                Caller, <<"ALREADY_IN_CALL">>, [Token], <<"You are already in a call">>
            ),
            State;
        false ->
            Id = <<Server/binary, "-", (hex(8))/binary>>,
            %% The caller's server anchors the media; a call from a user
            %% on another server is only relayed here.
            Mode =
                case Caller of
                    {remote, _} -> relay;
                    _ -> anchor
                end,
            Call = #{
                id => Id,
                token => Token,
                caller => Caller,
                callee => Callee,
                mode => Mode,
                state => offering,
                from_tag => <<"a", (hex(6))/binary>>,
                to_tag => <<"b", (hex(6))/binary>>,
                started => now_ms(),
                timer => undefined,
                timer_ref => undefined,
                monitors => [monitor(process, P) || P <- [Caller, Callee], is_pid(P)]
            },
            logger:info(#{
                event => call_started,
                call => Id,
                mode => Mode,
                remote => remote(Call),
                video => briskd_call_proto:has_video(Sdp)
            }),
            State1 = put_call(Call, State),
            case Mode of
                anchor ->
                    ng_request(
                        Id,
                        offer,
                        briskd_call_proto:offer(Id, maps:get(from_tag, Call), Sdp),
                        State1
                    );
                relay ->
                    %% The offer was rewritten by the caller's rtpflux.
                    media_result(offer, {ok, Sdp}, Call, State1)
            end
    end.

%% Whether one party is a user on another server.
remote(#{caller := Caller, callee := Callee}) ->
    not (is_pid(Caller) andalso is_pid(Callee)).

-doc "Return the other party in `Call`.".
-spec other(map(), pid() | {remote, binary()}) -> pid() | {remote, binary()}.
other(#{caller := Caller, callee := Callee}, Party) ->
    case Party of
        Caller -> Callee;
        _ -> Caller
    end.

-doc "Move a remote user's active call, chunks, and rate bucket after a nick change.".
-spec rekey({remote, binary()}, {remote, binary()}, map()) -> map().
rekey(Old, New, #{busy := Busy} = State) ->
    #{chunks := Chunks, rate := Rate, parties := Parties, calls := Calls} = State,
    Swap = fun
        (P) when P =:= Old -> New;
        (P) -> P
    end,
    State1 = State#{
        chunks := maps:from_list([{{Swap(P), T, K}, V} || {{P, T, K}, V} <- maps:to_list(Chunks)]),
        rate := maps:from_list([{Swap(P), V} || {P, V} <- maps:to_list(Rate)])
    },
    case Busy of
        #{Old := Id} ->
            #{caller := Caller, callee := Callee, token := Token} = Call = maps:get(Id, Calls),
            Moved = Call#{caller := Swap(Caller), callee := Swap(Callee)},
            State1#{
                busy := (maps:remove(Old, Busy))#{New => Id},
                parties := (maps:remove({Old, Token}, Parties))#{{New, Token} => Id},
                calls := Calls#{Id := Moved}
            };
        #{} ->
            State1
    end.

-doc "Answer a ringing call with the callee's decoded SDP.".
-spec answer_call(pid() | {remote, binary()}, binary(), binary(), map()) -> map().
answer_call(Callee, Token, Sdp, State) ->
    case lookup(Callee, Token, State) of
        {ok, #{id := Id, callee := Callee, state := ringing} = Call} ->
            Answering = Call#{state := answering},
            State1 = put_call(Answering, State),
            case maps:get(mode, Call, anchor) of
                anchor ->
                    #{from_tag := From, to_tag := To} = Call,
                    ng_request(Id, answer, briskd_call_proto:answer(Id, From, To, Sdp), State1);
                relay ->
                    %% The caller's server passes the answer through its
                    %% rtpflux before the caller sees it.
                    media_result(answer, {ok, Sdp}, Answering, State1)
            end;
        _ ->
            briskd_calls:fail(
                Callee, <<"INVALID_STATE">>, [Token], <<"The call cannot be answered now">>
            ),
            State
    end.

-doc "Relay `CALL RINGING` from callee to caller.".
-spec ringing(pid() | {remote, binary()}, binary(), map()) -> map().
ringing(Pid, Token, State) ->
    case lookup(Pid, Token, State) of
        {ok, #{callee := Pid, caller := Caller, state := ringing}} ->
            relay(Pid, Caller, [<<"RINGING">>], Token, none),
            State;
        _ ->
            State
    end.

-doc "Relay `HOLD` or `RESUME` to the other party of an active call.".
-spec hold(hold | resume, pid() | {remote, binary()}, binary(), map()) -> ok.
hold(Kind, Pid, Token, State) ->
    Line =
        case Kind of
            hold -> <<"HOLD">>;
            resume -> <<"RESUME">>
        end,
    case lookup(Pid, Token, State) of
        {ok, #{state := active, caller := Caller, callee := Callee}} ->
            Other =
                case Pid of
                    Caller -> Callee;
                    Callee -> Caller
                end,
            relay(Pid, Other, [Line], Token, none);
        {ok, _} ->
            briskd_calls:fail(
                Pid, <<"INVALID_STATE">>, [Token], <<"Only an active call can be put on hold">>
            );
        error ->
            briskd_calls:fail(Pid, <<"UNKNOWN_CALL">>, [Token], <<"No such call">>)
    end.

-doc "Reject a ringing or offering call from the callee.".
-spec reject(pid() | {remote, binary()}, binary(), binary(), map()) -> map().
reject(Pid, Token, Reason, State) ->
    case lookup(Pid, Token, State) of
        {ok, #{callee := Pid, caller := Caller, state := CallState} = Call} when
            CallState =:= ringing; CallState =:= offering
        ->
            relay(Pid, Caller, [<<"REJECT">>], Token, Reason),
            end_call(Call, Reason, none, State);
        {ok, _} ->
            briskd_calls:fail(
                Pid, <<"INVALID_STATE">>, [Token], <<"Only a ringing call can be rejected">>
            ),
            State;
        error ->
            briskd_calls:fail(Pid, <<"UNKNOWN_CALL">>, [Token], <<"No such call">>),
            State
    end.

-doc "Hang up a call from either party.".
-spec hangup(pid() | {remote, binary()}, binary(), binary(), map()) -> map().
hangup(Pid, Token, Reason, State) ->
    case lookup(Pid, Token, State) of
        {ok, #{caller := Caller, callee := Callee, state := CallState} = Call} ->
            Other =
                case Pid of
                    Caller -> Callee;
                    Callee -> Caller
                end,
            %% The callee has not seen an offer that rtpflux is still handling.
            case Pid =:= Caller andalso CallState =:= offering of
                true -> ok;
                false -> relay(Pid, Other, [<<"HANGUP">>], Token, Reason)
            end,
            end_call(Call, Reason, none, State);
        error ->
            %% Hanging up a call that already ended (a race with the peer) is harmless.
            State
    end.

-doc """
End a call: tell `both` parties, every party `{except, Pid}`, or `none`
(the caller of this function already notified the other side).
""".
-spec end_call(
    map(), binary(), both | none | {except, pid() | {remote, binary()}}, map()
) -> map().
end_call(
    #{id := Id, caller := Caller, callee := Callee, token := Token} = Call, Reason, Notify, State
) ->
    #{server := Server} = State,
    Targets =
        case Notify of
            both -> [Caller, Callee];
            {except, Pid} -> [Caller, Callee] -- [Pid];
            none -> []
        end,
    %% A callee never saw an offer still being processed by rtpflux.
    Seen =
        case maps:get(state, Call) of
            offering -> [P || P <- Targets, P =/= Callee];
            _ -> Targets
        end,
    lists:foreach(
        fun(P) ->
            case {nick_of(P), P} of
                {undefined, _} ->
                    ok;
                {Nick, {remote, Key}} ->
                    link_send(Key, Server, [<<"HANGUP">>, Nick, Token], Reason);
                {Nick, _} ->
                    briskd_state_send:send(
                        P, Server, <<"CALL">>, [<<"HANGUP">>, Nick, Token], Reason
                    )
            end
        end,
        Seen
    ),
    cancel(maps:get(timer, Call)),
    [demonitor(M, [flush]) || M <- maps:get(monitors, Call)],
    logger:info(#{
        event => call_ended,
        call => Id,
        reason => Reason,
        duration_s => (now_ms() - maps:get(started, Call)) div 1000
    }),
    State1 = State#{
        calls := maps:remove(Id, maps:get(calls, State)),
        pending := drop_pending(Id, maps:get(pending, State)),
        parties := maps:without([{Caller, Token}, {Callee, Token}], maps:get(parties, State)),
        busy := maps:without([Caller, Callee], maps:get(busy, State))
    },
    case maps:get(mode, Call, anchor) of
        anchor -> send_ng(briskd_call_proto:frame(cookie(), briskd_call_proto:delete(Id)), State1);
        relay -> ok
    end,
    State1.

put_call(#{id := Id, caller := Caller, callee := Callee, token := Token} = Call, State) ->
    State#{
        calls := (maps:get(calls, State))#{Id => Call},
        parties := (maps:get(parties, State))#{{Caller, Token} => Id, {Callee, Token} => Id},
        busy := (maps:get(busy, State))#{Caller => Id, Callee => Id}
    }.

-doc "Look up an active call by party (`Pid` or `{remote, Key}`) and `Token`.".
-spec lookup(pid() | {remote, binary()}, binary(), map()) -> {ok, map()} | error.
lookup(Pid, Token, #{parties := Parties, calls := Calls}) ->
    case Parties of
        #{{Pid, Token} := Id} -> maps:find(Id, Calls);
        #{} -> error
    end.

set_timer(Call, Seconds) ->
    cancel(maps:get(timer, Call)),
    Ref = make_ref(),
    Timer = erlang:send_after(Seconds * 1000, self(), {call_timer, maps:get(id, Call), Ref}),
    Call#{timer := Timer, timer_ref := Ref}.

cancel(undefined) ->
    ok;
cancel(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

%%% rtpflux NG

ng_request(Id, Op, Message, State0) ->
    %% Re-resolve once per request so a restarted rtpflux container with a
    %% new address is found; retries and deletes reuse the address.
    #{pending := Pending} = State = resolve_ng(State0),
    Cookie = cookie(),
    Packet = iolist_to_binary(briskd_call_proto:frame(Cookie, Message)),
    send_ng(Packet, State),
    Timer = erlang:send_after(?NG_RETRY_MS, self(), {ng_retry, Cookie}),
    Req = #{id => Id, op => Op, packet => Packet, tries => 1, timer => Timer},
    State#{pending := Pending#{Cookie => Req}}.

%% A request still in flight for an ended call must not be retried after the
%% NG `delete`: a retransmitted `offer` would recreate the call in rtpflux.
drop_pending(Id, Pending) ->
    maps:filter(
        fun
            (_, #{id := I, timer := Timer}) when I =:= Id ->
                cancel(Timer),
                false;
            (_, _) ->
                true
        end,
        Pending
    ).

-doc "Resolve the configured rtpflux NG hostname to an IPv4 address.".
-spec resolve_ng(map()) -> map().
resolve_ng(#{ng := {Host, _}, ng_ip := Old} = State) ->
    case inet:getaddr(Host, inet) of
        {ok, Ip} ->
            State#{ng_ip := Ip};
        {error, Reason} ->
            logger:warning(#{event => rtpflux_resolve_failed, reason => Reason}),
            State#{ng_ip := Old}
    end.

-doc "Send an encoded rtpflux NG packet over the UDP socket.".
-spec send_ng(iodata(), map()) -> ok.
send_ng(_Packet, #{ng_ip := undefined}) ->
    logger:warning(#{event => rtpflux_send_failed, reason => unresolved});
send_ng(Packet, #{sock := Sock, ng := {_, Port}, ng_ip := Ip}) ->
    case gen_udp:send(Sock, Ip, Port, Packet) of
        ok -> ok;
        {error, Reason} -> logger:warning(#{event => rtpflux_send_failed, reason => Reason})
    end.

-doc "Handle a decoded rtpflux NG reply or timeout for `Cookie`.".
-spec ng_reply(binary(), {ok, undefined | binary()} | {error, term()}, map()) -> map().
ng_reply(Cookie, Result, #{pending := Pending} = State) ->
    case maps:take(Cookie, Pending) of
        {#{id := Id, op := Op, timer := Timer}, Rest} ->
            cancel(Timer),
            State1 = State#{pending := Rest},
            case maps:get(calls, State1) of
                #{Id := Call} -> media_result(Op, Result, Call, State1);
                #{} -> State1
            end;
        error ->
            State
    end.

media_result(offer, {ok, Sdp}, #{state := offering} = Call, State) when is_binary(Sdp) ->
    #{caller := Caller, callee := Callee, token := Token} = Call,
    relay_sdp(Caller, Callee, <<"OFFER">>, Token, Sdp),
    Ring = maps:get(ring_timeout, maps:get(limits, State)),
    put_call(set_timer(Call#{state := ringing}, Ring), State);
media_result(answer, {ok, Sdp}, #{state := answering} = Call, State) when is_binary(Sdp) ->
    #{caller := Caller, callee := Callee, token := Token, id := Id} = Call,
    relay_sdp(Callee, Caller, <<"ANSWER">>, Token, Sdp),
    logger:info(#{
        event => call_answered, call => Id, setup_ms => now_ms() - maps:get(started, Call)
    }),
    Call1 =
        case maps:get(max_duration, maps:get(limits, State)) of
            0 -> (Call#{state := active, timer := cancel_and_clear(Call)});
            Max -> set_timer(Call#{state := active}, Max)
        end,
    put_call(Call1, State);
media_result(Op, Result, #{id := Id} = Call, State) when Op =:= offer; Op =:= answer ->
    Why =
        case Result of
            {error, W} -> W;
            {ok, _} -> <<"no sdp">>
        end,
    logger:warning(#{event => call_media_error, call => Id, op => Op, reason => Why}),
    case Op of
        offer ->
            briskd_calls:fail(
                maps:get(caller, Call),
                <<"MEDIA_ERROR">>,
                [maps:get(token, Call)],
                <<"The media relay is unavailable">>
            ),
            end_call(Call, <<"media-error">>, none, State);
        answer ->
            end_call(Call, <<"media-error">>, both, State)
    end.

cancel_and_clear(#{timer := Timer}) ->
    cancel(Timer),
    undefined.

%% Send `Sdp` from `From` to `To` as numbered base64 chunks.
relay_sdp(From, To, Kind, Token, Sdp) ->
    Chunks = briskd_call_proto:chunks(Sdp),
    Total = integer_to_binary(length(Chunks)),
    lists:foreach(
        fun({N, Chunk}) ->
            relay(From, To, [Kind], Token, {Chunk, [integer_to_binary(N), Total]})
        end,
        lists:enumerate(Chunks)
    ).

%% One `CALL` line to `To` with `From`'s prefix. `Tail` is a reason, `none`,
%% or `{Chunk, [Part, Total]}` for a description chunk.
relay(From, To, [Kind], Token, Tail) ->
    case {prefix_of(From), nick_of(To)} of
        {Prefix, Nick} when Prefix =/= undefined, Nick =/= undefined ->
            {Params, Trailing} =
                case Tail of
                    {Chunk, PartTotal} -> {[Kind, Nick, Token | PartTotal], Chunk};
                    _ -> {[Kind, Nick, Token], Tail}
                end,
            case To of
                {remote, Key} -> link_send(Key, Prefix, Params, Trailing);
                _ -> briskd_state_send:send(To, Prefix, <<"CALL">>, Params, Trailing)
            end;
        _ ->
            ok
    end.

%% The source prefix of a party: a local session's `nick!user@host`, or a
%% remote user's as its server announced it.
prefix_of({remote, Key}) ->
    case mnesia:dirty_read(remote_client, Key) of
        [#remote_client{nick = Nick, user = User, host = Host}] ->
            <<Nick/binary, "!", User/binary, "@", Host/binary>>;
        [] ->
            undefined
    end;
prefix_of(Pid) ->
    case mnesia:dirty_read(client, Pid) of
        [#client{} = Source] -> briskd_state_send:prefix(Source);
        [] -> undefined
    end.

-doc "Return the current nickname of a local pid or `{remote, Key}` party.".
-spec nick_of(pid() | {remote, binary()}) -> undefined | binary().
nick_of({remote, Key}) ->
    case mnesia:dirty_read(remote_client, Key) of
        [#remote_client{nick = Nick}] -> Nick;
        [] -> undefined
    end;
nick_of(Pid) ->
    case mnesia:dirty_read(client, Pid) of
        [#client{nick = Nick}] when Nick =/= <<"*">> -> Nick;
        _ -> undefined
    end.

-doc "Send a `CALL` line toward the remote user `Key` on the link they are reached through.".
-spec link_send(binary(), iodata(), [binary()], none | binary()) -> ok.
link_send(Key, Prefix, Params, Trailing) ->
    case mnesia:dirty_read(remote_client, Key) of
        [#remote_client{peer = Peer}] ->
            _ = briskd_links:send(Peer, briskd_wire:line(Prefix, <<"CALL">>, Params, Trailing)),
            ok;
        [] ->
            ok
    end.

alive(Pid) ->
    nick_of(Pid) =/= undefined.

%%% Per-caller rate limit: `calls_per_minute` as a token bucket.

-doc "Consume one call token from `Pid`'s rate bucket if available.".
-spec take_rate(pid() | {remote, binary()}, map()) -> {ok, map()} | limited.
take_rate(Pid, #{limits := Limits, rate := Rate} = State) ->
    PerMinute = maps:get(calls_per_minute, Limits),
    Now = now_ms(),
    {Tokens, Last} = maps:get(Pid, Rate, {float(PerMinute), Now}),
    Refilled = min(float(PerMinute), Tokens + (Now - Last) * PerMinute / 60000),
    case Refilled >= 1.0 of
        true ->
            Pruned = prune(Rate, Now),
            {ok, State#{rate := Pruned#{Pid => {Refilled - 1.0, Now}}}};
        false ->
            limited
    end.

%% Forget buckets idle for over a minute (they are full again) once the
%% table is large, so departed callers do not accumulate.
prune(Rate, Now) when map_size(Rate) >= ?MAX_RATE_ENTRIES ->
    maps:filter(fun(_, {_, Last}) -> Now - Last < 60000 end, Rate);
prune(Rate, _Now) ->
    Rate.

%%% Helpers

cookie() ->
    hex(8).

hex(Bytes) ->
    binary:encode_hex(crypto:strong_rand_bytes(Bytes), lowercase).

now_ms() ->
    erlang:monotonic_time(millisecond).
