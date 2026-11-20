-module(ircd_calls).
-moduledoc """
User-to-user voice calls relayed through [rtpengine](https://github.com/sipwise/rtpengine)
(the `calls` configuration key, vendor capability `egorsmkv.github.io/calls`).

This is a server extension, not an IRC or IRCv3 specification. Clients that
negotiate the capability exchange WebRTC session descriptions with the
`CALL` command; the server passes each description through rtpengine's NG
control protocol, so media flows browser → rtpengine → browser and neither
side learns the other's address.

```text
CALL OFFER   <nick> <token> <part> <total> :<base64 SDP chunk>   caller → callee
CALL RINGING <nick> <token>                                       callee → caller
CALL ANSWER  <nick> <token> <part> <total> :<base64 SDP chunk>   callee → caller
CALL REJECT  <nick> <token> [:<reason>]                           callee → caller
CALL HANGUP  <nick> <token> [:<reason>]                           either side
CALL HOLD    <nick> <token>                                       either side
CALL RESUME  <nick> <token>                                       either side
```

The server relays each to the other party with that party's prefix
(`:alice!u@h CALL OFFER bob <token> 1 3 :...`). Calls are identified by the
caller's `<token>`; after the `OFFER`, `<nick>` is informational, so a nick
change does not break a call. Server-originated `HANGUP`s (ring timeout,
`max_duration`, disconnect, media failure) come from the server name.
Errors are `FAIL CALL <code> <token> :<text>`.

`HOLD` and `RESUME` only tell the other party that a user put an active
call on hold (and plays hold audio in place of the microphone) or took it off
hold; the media path through rtpengine is unchanged, so the call keeps
running and `max_duration` still applies.

Calls to users on other servers (RFC 2813 links) use the same command
between servers, with the sending user's prefix, routed hop by hop to the
target user's server like a private message (`receive_link/3`):

```text
:alice!u@h CALL OFFER bob <token> <part> <total> :<chunk>   any subcommand, user → user
:server CALL HANGUP <nick> <token> [:<reason>]             timeout, disconnect, media
:server CALL FAIL <nick> <token> <code> :<text>            refusal by the far server
```

The caller's server is the media anchor: it passes the offer and the
callee's answer through its own rtpengine, so each user still sees only the
relay's address. The callee's server checks the callee (capability,
account, busy, limits) and relays lines between its user and the link
without touching rtpengine (`relay` mode). Each side ends its record when
the other user quits or is split away, re-keys it on a nick change, and
keeps its own ring and duration timers. A peer that does not know `CALL`
ignores it, so the caller hears no answer until the ring timeout.

Process model: `command/3` runs inside `m:ircd_state`, validates syntax,
resolves the callee among local users or users behind a link, checks the
capabilities it can see, and casts to this process. This process owns the call table, chunk reassembly, the UDP
socket to rtpengine, the ring and duration timers, and a monitor on each
party; it reads client rows from Mnesia and sends lines straight to session
processes. It never calls `m:ircd_state`, so there is no call cycle.

Bounds: one call per user (ringing or active), `max_calls` calls in total,
`calls_per_minute` new calls per caller, descriptions of at most 40 chunks
and 12 KiB (`m:ircd_call_proto`), and a 10-second window to finish sending a
description. NG requests are retried twice (after 1 s each) with the same
cookie, which rtpengine answers from its cache, then treated as failed.
Call state is in memory only; a restart ends every call.
""".
-behaviour(gen_server).
-include("ircd_client.hrl").
-include("ircd_remote.hrl").
-export([
    start_link/1,
    enabled/0,
    cap_value/0,
    command/3,
    receive_link/3,
    remote_gone/1,
    remote_renamed/2,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    format_status/1
]).

-define(CAP, <<"egorsmkv.github.io/calls">>).
-define(ASSEMBLY_MS, 10000).
-define(NG_RETRY_MS, 1000).
-define(NG_TRIES, 3).
-define(MAX_RATE_ENTRIES, 10000).

-doc "Start the call server, registered as `ircd_calls`.".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

-doc "Whether voice calls are configured (the `calls` key is set).".
-spec enabled() -> boolean().
enabled() ->
    maps:get(calls, ircd_config:current_or_empty(), null) =/= null.

-doc """
Value of the `egorsmkv.github.io/calls` capability: protocol version, ring
timeout, and `hold` (the server relays `HOLD` and `RESUME`).
""".
-spec cap_value() -> binary().
cap_value() ->
    #{calls := #{ring_timeout := Ring}} = ircd_config:current(),
    <<"v=1,ring=", (integer_to_binary(Ring))/binary, ",hold">>.

-doc """
Handle `CALL` from a registered local client. Runs in `m:ircd_state`.

Validates the parameters and the caller (capability, and an account when
`require_account` is set); for `OFFER` also resolves the callee, which must
be a different local user with the capability (and, with `require_account`,
logged in). Valid commands are passed to
this process; invalid ones get `FAIL CALL`.
""".
-spec command([binary()], #client{}, binary()) -> ok.
command([Sub0 | Params], #client{pid = Pid} = Client, Server) ->
    Sub = ircd_wire:upper(Sub0),
    case caller_ok(Pid) of
        ok -> dispatch(Sub, Params, Client, Server);
        {error, Code, Text} -> fail(Pid, Code, [], Text)
    end;
command([], Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"CALL">>], <<"Not enough parameters">>).

caller_ok(Pid) ->
    case ircd_cap:enabled(Pid, ?CAP) of
        false ->
            {error, <<"NEED_CAPABILITY">>, <<"Negotiate egorsmkv.github.io/calls first">>};
        true ->
            case needs_account() andalso ircd_state_v3:account(Pid) =:= undefined of
                true -> {error, <<"ACCOUNT_REQUIRED">>, <<"Log in to make calls">>};
                false -> ok
            end
    end.

dispatch(Sub, [Nick, Token, PartBin, TotalBin, Chunk | _], #client{pid = Pid}, _Server) when
    Sub =:= <<"OFFER">>; Sub =:= <<"ANSWER">>
->
    case
        {
            ircd_call_proto:valid_token(Token),
            ircd_call_proto:parse_part(PartBin, TotalBin),
            ircd_call_proto:valid_chunk(Chunk)
        }
    of
        {true, {ok, Part, Total}, true} when Sub =:= <<"OFFER">> ->
            case callee(Nick, Pid) of
                {ok, Callee} ->
                    cast({offer, Pid, Callee, Token, Part, Total, Chunk});
                {error, Code, Text} ->
                    fail(Pid, Code, [Token], Text)
            end;
        {true, {ok, Part, Total}, true} ->
            cast({answer, Pid, Token, Part, Total, Chunk});
        _ ->
            fail(Pid, <<"INVALID_PARAMS">>, echo(Token), <<"Invalid CALL parameters">>)
    end;
dispatch(Sub, [_Nick, Token | Rest], #client{pid = Pid}, _Server) when
    Sub =:= <<"RINGING">>;
    Sub =:= <<"REJECT">>;
    Sub =:= <<"HANGUP">>;
    Sub =:= <<"HOLD">>;
    Sub =:= <<"RESUME">>
->
    case ircd_call_proto:valid_token(Token) of
        true ->
            Reason =
                case Rest of
                    [R | _] -> ircd_call_proto:reason(R);
                    [] -> <<"normal">>
                end,
            cast({signal(Sub), Pid, Token, Reason});
        false ->
            fail(Pid, <<"INVALID_PARAMS">>, [], <<"Invalid call token">>)
    end;
dispatch(Sub, _Params, #client{pid = Pid}, _Server) when
    Sub =:= <<"OFFER">>;
    Sub =:= <<"ANSWER">>;
    Sub =:= <<"RINGING">>;
    Sub =:= <<"REJECT">>;
    Sub =:= <<"HANGUP">>;
    Sub =:= <<"HOLD">>;
    Sub =:= <<"RESUME">>
->
    fail(Pid, <<"INVALID_PARAMS">>, [], <<"Not enough parameters">>);
dispatch(Sub, _Params, #client{pid = Pid}, _Server) ->
    Context =
        case
            Sub =/= <<>> andalso
                lists:all(fun(C) -> C >= $A andalso C =< $Z end, binary_to_list(Sub))
        of
            true when byte_size(Sub) =< 16 -> [Sub];
            _ -> []
        end,
    fail(Pid, <<"UNKNOWN_SUBCOMMAND">>, Context, <<"Unknown CALL subcommand">>).

%% Only a well-formed token is echoed in FAIL context: a trailing parameter
%% may hold spaces or a leading colon that would break the reply's framing.
echo(Token) ->
    case ircd_call_proto:valid_token(Token) of
        true -> [Token];
        false -> []
    end.

signal(<<"RINGING">>) -> ringing;
signal(<<"REJECT">>) -> reject;
signal(<<"HANGUP">>) -> hangup;
signal(<<"HOLD">>) -> hold;
signal(<<"RESUME">>) -> resume.

%% The callee: a different local user that negotiated the capability.
callee(Nick, Pid) ->
    case ircd_state_client:find_nick(Nick) of
        #client{pid = Pid} ->
            {error, <<"INVALID_TARGET">>, <<"You cannot call yourself">>};
        #client{pid = Callee} ->
            case ircd_cap:enabled(Callee, ?CAP) of
                true ->
                    %% With require_account the callee must be able to answer.
                    case needs_account() andalso ircd_state_v3:account(Callee) =:= undefined of
                        true -> {error, <<"TARGET_UNSUPPORTED">>, <<"That user is not logged in">>};
                        false -> {ok, Callee}
                    end;
                false ->
                    {error, <<"TARGET_UNSUPPORTED">>,
                        <<"That user's client does not support calls">>}
            end;
        undefined ->
            %% A user behind a link: the capability is checked by that
            %% user's server, which answers FAIL if the call cannot ring.
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [#remote_client{key = Key, account = Account}] ->
                    case needs_account() andalso Account =:= undefined of
                        true -> {error, <<"TARGET_UNSUPPORTED">>, <<"That user is not logged in">>};
                        false -> {ok, {remote, Key}}
                    end;
                [] ->
                    {error, <<"NO_SUCH_NICK">>, <<"No such nick">>}
            end
    end.

needs_account() ->
    #{calls := #{require_account := Required}} = ircd_config:current(),
    Required.

cast(Msg) ->
    gen_server:cast(?MODULE, Msg).

fail(Pid, Code, Context, Text) when is_pid(Pid) ->
    ircd_state_send:fail(Pid, <<"CALL">>, Code, Context, Text);
fail({remote, Key}, Code, [Token | _], Text) ->
    %% The far server turns this into FAIL CALL for its user.
    case nick_of({remote, Key}) of
        undefined -> ok;
        Nick -> link_send(Key, server_name(), [<<"FAIL">>, Nick, Token, Code], Text)
    end;
fail({remote, _}, _Code, [], _Text) ->
    ok.

server_name() ->
    maps:get(name, ircd_config:current()).

%%% Server links

-doc """
Handle `CALL` from the server link `Peer` with source `Prefix`. Runs in
`m:ircd_state`. A user source must be a remote user reached through `Peer`
(`ircd_state_link:remote_source/2`); a server source (`HANGUP` and `FAIL`
only) must be `Peer` or a server behind it. The line is delivered to a
local target, forwarded to the link of a remote target (never back to
`Peer`), or, for a target that is gone, answered with `FAIL NO_SUCH_NICK`.
Malformed lines and untrusted sources are logged and dropped: the link
stays up, as for a newer peer's subcommand this server does not know.
Always returns `ok`.
""".
-spec receive_link(binary(), binary(), [binary()]) -> ok.
receive_link(Peer, Prefix, [Sub0, Target, Token | Rest] = Params) ->
    Sub = ircd_wire:upper(Sub0),
    Source =
        case ircd_state_link:remote_source(Peer, Prefix) of
            {ok, Remote} ->
                {user, Remote};
            error ->
                case ircd_state_link:trusted_server(Peer, Prefix) of
                    true -> server;
                    false -> untrusted
                end
        end,
    case {Source, ircd_call_proto:valid_token(Token), link_sub(Sub, Source)} of
        {untrusted, _, _} ->
            drop_link_line(Peer, untrusted_source);
        {_, false, _} ->
            drop_link_line(Peer, invalid_token);
        {_, true, false} ->
            drop_link_line(Peer, invalid_subcommand);
        {_, true, true} ->
            case ircd_state_client:find_nick(Target) of
                #client{pid = Pid} ->
                    deliver_link(Source, Sub, Pid, Token, Rest, Peer);
                undefined ->
                    case mnesia:dirty_read(remote_client, ircd_wire:fold(Target)) of
                        [#remote_client{peer = Next}] when Next =/= Peer ->
                            {Middle, Trailing} = split_last(Params),
                            _ = ircd_links:send(
                                Next, ircd_wire:line(Prefix, <<"CALL">>, Middle, Trailing)
                            ),
                            ok;
                        _ ->
                            link_fail(Source, Peer, Token, <<"NO_SUCH_NICK">>, <<"No such nick">>)
                    end
            end
    end;
receive_link(Peer, _Prefix, _Params) ->
    drop_link_line(Peer, missing_params).

%% Subcommands a user may send across a link, and the two a server sends.
link_sub(Sub, {user, _}) ->
    lists:member(Sub, [
        <<"OFFER">>,
        <<"ANSWER">>,
        <<"RINGING">>,
        <<"REJECT">>,
        <<"HANGUP">>,
        <<"HOLD">>,
        <<"RESUME">>
    ]);
link_sub(Sub, server) ->
    Sub =:= <<"HANGUP">> orelse Sub =:= <<"FAIL">>;
link_sub(_, untrusted) ->
    false.

drop_link_line(Peer, Reason) ->
    logger:warning(#{event => call_link_dropped, peer => Peer, reason => Reason}),
    ok.

split_last(Params) ->
    {lists:droplast(Params), lists:last(Params)}.

%% Tell the user who sent a line that its call cannot continue.
link_fail({user, #remote_client{nick = Nick}}, Peer, Token, Code, Text) ->
    _ = ircd_links:send(
        Peer, ircd_wire:line(server_name(), <<"CALL">>, [<<"FAIL">>, Nick, Token, Code], Text)
    ),
    ok;
link_fail(_, _Peer, _Token, _Code, _Text) ->
    ok.

%% A line for the local user `Pid`, from a remote user or a server.
deliver_link(Source, Sub, Pid, Token, Rest, Peer) when Source =/= server ->
    case whereis(?MODULE) of
        undefined ->
            link_fail(
                Source,
                Peer,
                Token,
                <<"TARGET_UNSUPPORTED">>,
                <<"Calls are not enabled on that user's server">>
            );
        _ ->
            deliver_user(Source, Sub, Pid, Token, Rest, Peer)
    end;
deliver_link(server, <<"HANGUP">>, Pid, Token, Rest, _Peer) ->
    cast({remote_hangup, Pid, Token, reason_of(Rest)});
deliver_link(server, <<"FAIL">>, Pid, Token, [Code, Text | _], Peer) ->
    case valid_code(Code) of
        true -> cast({remote_fail, Pid, Token, Code, bounded_text(Text)});
        false -> drop_link_line(Peer, invalid_fail_code)
    end;
deliver_link(server, _Sub, _Pid, _Token, _Rest, Peer) ->
    drop_link_line(Peer, missing_params).

deliver_user(
    {user, #remote_client{key = Key, account = Account}} = Source, Sub, Pid, Token, Rest, Peer
) ->
    Party = {remote, Key},
    case Sub of
        _ when Sub =:= <<"OFFER">>; Sub =:= <<"ANSWER">> ->
            case Rest of
                [PartBin, TotalBin, Chunk | _] ->
                    case
                        {
                            ircd_call_proto:parse_part(PartBin, TotalBin),
                            ircd_call_proto:valid_chunk(Chunk)
                        }
                    of
                        {{ok, Part, Total}, true} when Sub =:= <<"OFFER">> ->
                            case local_callee(Pid, Account) of
                                ok ->
                                    cast({offer, Party, Pid, Token, Part, Total, Chunk});
                                {error, Code, Text} ->
                                    link_fail(Source, Peer, Token, Code, Text)
                            end;
                        {{ok, Part, Total}, true} ->
                            cast({answer, Party, Token, Part, Total, Chunk});
                        _ ->
                            drop_link_line(Peer, invalid_params)
                    end;
                _ ->
                    drop_link_line(Peer, missing_params)
            end;
        _ ->
            cast({signal(Sub), Party, Token, reason_of(Rest)})
    end.

%% The local user a remote user calls: the same checks as for a local
%% caller (`callee/2`), plus an account for the caller with `require_account`.
local_callee(Pid, CallerAccount) ->
    case
        {
            ircd_cap:enabled(Pid, ?CAP),
            needs_account(),
            CallerAccount,
            ircd_state_v3:account(Pid)
        }
    of
        {false, _, _, _} ->
            {error, <<"TARGET_UNSUPPORTED">>, <<"That user's client does not support calls">>};
        {true, true, undefined, _} ->
            {error, <<"ACCOUNT_REQUIRED">>, <<"Log in to call users on that server">>};
        {true, true, _, undefined} ->
            {error, <<"TARGET_UNSUPPORTED">>, <<"That user is not logged in">>};
        _ ->
            ok
    end.

reason_of([R | _]) -> ircd_call_proto:reason(R);
reason_of([]) -> <<"normal">>.

%% A FAIL code: 1 to 32 of A-Z, 0-9, and _ (the IRCv3 standard-reply form).
valid_code(Code) ->
    byte_size(Code) >= 1 andalso byte_size(Code) =< 32 andalso
        lists:all(
            fun(C) ->
                (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9) orelse C =:= $_
            end,
            binary_to_list(Code)
        ).

bounded_text(Text) when byte_size(Text) =< 200 -> Text;
bounded_text(_) -> <<"Call failed">>.

-doc """
The remote user with folded nick `Key` quit, was killed, or was split
away: end their call. Called by `m:ircd_state_link` and
`m:ircd_state_net`; a no-op when calls are not configured.
""".
-spec remote_gone(binary()) -> ok.
remote_gone(Key) ->
    cast({remote_gone, Key}).

-doc """
The remote user `OldKey` is now `NewKey` (a nick change): their call
continues under the new name.
""".
-spec remote_renamed(binary(), binary()) -> ok.
remote_renamed(OldKey, NewKey) ->
    cast({remote_renamed, OldKey, NewKey}).

%%% gen_server

-doc false.
init(Config) ->
    Calls = maps:get(calls, Config),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}]),
    {Host, Port} = maps:get(rtpengine, Calls),
    State = #{
        server => maps:get(name, Config),
        limits => Calls,
        sock => Sock,
        ng => {binary_to_list(Host), Port},
        ng_ip => undefined,
        calls => #{},
        parties => #{},
        busy => #{},
        chunks => #{},
        pending => #{},
        rate => #{}
    },
    {ok, resolve_ng(State)}.

-doc false.
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.

-doc false.
handle_cast({offer, Pid, Callee, Token, Part, Total, Chunk}, State) ->
    {noreply, offer_chunk(Pid, Callee, Token, Part, Total, Chunk, State)};
handle_cast({answer, Pid, Token, Part, Total, Chunk}, State) ->
    {noreply, answer_chunk(Pid, Token, Part, Total, Chunk, State)};
handle_cast({ringing, Pid, Token, _}, State) ->
    {noreply, ringing(Pid, Token, State)};
handle_cast({Hold, Pid, Token, _}, State) when Hold =:= hold; Hold =:= resume ->
    hold(Hold, Pid, Token, State),
    {noreply, State};
handle_cast({reject, Pid, Token, Reason}, State) ->
    {noreply, reject(Pid, Token, Reason, State)};
handle_cast({hangup, Pid, Token, Reason}, State) ->
    {noreply, hangup(Pid, Token, Reason, State)};
handle_cast({remote_hangup, Pid, Token, Reason}, State) ->
    %% The far server ended the call (timeout, disconnect, media failure).
    case lookup(Pid, Token, State) of
        {ok, Call} -> {noreply, end_call(Call, Reason, {except, other(Call, Pid)}, State)};
        error -> {noreply, State}
    end;
handle_cast({remote_fail, Pid, Token, Code, Text}, State) ->
    %% The far server refused the call (busy, unsupported client, limits).
    case lookup(Pid, Token, State) of
        {ok, Call} ->
            fail(Pid, Code, [Token], Text),
            {noreply, end_call(Call, <<"refused">>, none, State)};
        error ->
            {noreply, State}
    end;
handle_cast({remote_gone, Key}, #{busy := Busy, chunks := Chunks} = State) ->
    Party = {remote, Key},
    State1 = State#{chunks := maps:filter(fun({P, _, _}, _) -> P =/= Party end, Chunks)},
    case Busy of
        #{Party := Id} ->
            Call = maps:get(Id, maps:get(calls, State1)),
            {noreply, end_call(Call, <<"disconnected">>, {except, Party}, State1)};
        #{} ->
            {noreply, State1}
    end;
handle_cast({remote_renamed, OldKey, NewKey}, State) ->
    {noreply, rekey({remote, OldKey}, {remote, NewKey}, State)};
handle_cast(_, State) ->
    {noreply, State}.

-doc false.
handle_info({udp, Sock, Ip, Port, Packet}, #{sock := Sock, ng := {_, Port}, ng_ip := Ip} = State) ->
    case ircd_call_proto:parse_reply(Packet) of
        {ok, Cookie, Result} -> {noreply, ng_reply(Cookie, Result, State)};
        error -> {noreply, State}
    end;
handle_info({udp, Sock, _Ip, _Port, _Packet}, #{sock := Sock} = State) ->
    %% Only rtpengine's NG address may answer; anything else is dropped
    %% before parsing (the random cookie is the second line of defense).
    {noreply, State};
handle_info({ng_retry, Cookie}, #{pending := Pending} = State) ->
    case maps:find(Cookie, Pending) of
        {ok, #{tries := Tries} = Req} when Tries < ?NG_TRIES ->
            send_ng(maps:get(packet, Req), State),
            Timer = erlang:send_after(?NG_RETRY_MS, self(), {ng_retry, Cookie}),
            {noreply, State#{
                pending := Pending#{Cookie := Req#{tries := Tries + 1, timer := Timer}}
            }};
        {ok, _} ->
            {noreply, ng_reply(Cookie, {error, <<"timeout">>}, State)};
        error ->
            {noreply, State}
    end;
handle_info({assembly_timeout, Key, Ref}, #{chunks := Chunks} = State) ->
    case Chunks of
        #{Key := #{ref := Ref}} ->
            {Pid, Token, _} = Key,
            fail(Pid, <<"TIMEOUT">>, [Token], <<"Session description incomplete">>),
            {noreply, State#{chunks := maps:remove(Key, Chunks)}};
        #{} ->
            {noreply, State}
    end;
handle_info({call_timer, Id, Ref}, #{calls := Calls} = State) ->
    case maps:find(Id, Calls) of
        {ok, #{timer_ref := Ref, state := CallState} = Call} ->
            Reason =
                case CallState of
                    active -> <<"max-duration">>;
                    _ -> <<"no-answer">>
                end,
            {noreply, end_call(Call, Reason, both, State)};
        _ ->
            {noreply, State}
    end;
handle_info({'DOWN', _MRef, process, Pid, _}, #{busy := Busy, chunks := Chunks} = State) ->
    State1 = State#{chunks := maps:filter(fun({P, _, _}, _) -> P =/= Pid end, Chunks)},
    case Busy of
        #{Pid := Id} ->
            Call = maps:get(Id, maps:get(calls, State1)),
            {noreply, end_call(Call, <<"disconnected">>, {except, Pid}, State1)};
        #{} ->
            {noreply, State1}
    end;
handle_info(_, State) ->
    {noreply, State}.

-doc false.
format_status(Status) ->
    maps:map(
        fun
            (state, S) when is_map(S) -> S#{chunks := redacted, pending := redacted};
            (_, V) -> V
        end,
        Status
    ).

%%% Session descriptions in chunks

offer_chunk(Pid, Callee, Token, 1, Total, Chunk, State) ->
    #{busy := Busy, calls := Calls, limits := Limits, parties := Parties} = State,
    if
        is_map_key(Pid, Busy) ->
            fail(Pid, <<"ALREADY_IN_CALL">>, [Token], <<"You are already in a call">>),
            State;
        is_map_key({Pid, Token}, Parties) ->
            fail(Pid, <<"INVALID_PARAMS">>, [Token], <<"Call token already in use">>),
            State;
        map_size(Calls) >= map_get(max_calls, Limits) ->
            fail(Pid, <<"LIMIT_REACHED">>, [Token], <<"Too many calls on this server">>),
            State;
        true ->
            case take_rate(Pid, State) of
                {ok, State1} ->
                    add_chunk({Pid, Token, offer}, 1, Total, Chunk, #{callee => Callee}, State1);
                limited ->
                    fail(Pid, <<"RATE_LIMITED">>, [Token], <<"Too many calls; try again later">>),
                    State
            end
    end;
offer_chunk(Pid, _Callee, Token, Part, Total, Chunk, State) ->
    add_chunk({Pid, Token, offer}, Part, Total, Chunk, #{}, State).

answer_chunk(Pid, Token, Part, Total, Chunk, #{parties := Parties, calls := Calls} = State) ->
    case Parties of
        #{{Pid, Token} := Id} ->
            case maps:get(Id, Calls) of
                #{callee := Pid, state := ringing} ->
                    add_chunk({Pid, Token, answer}, Part, Total, Chunk, #{}, State);
                _ ->
                    fail(Pid, <<"INVALID_STATE">>, [Token], <<"The call cannot be answered now">>),
                    State
            end;
        #{} ->
            fail(Pid, <<"UNKNOWN_CALL">>, [Token], <<"No such call">>),
            State
    end.

%% Chunks arrive in order 1..Total; the description is handled when complete.
add_chunk(Key, 1, Total, Chunk, Extra, #{chunks := Chunks} = State) ->
    Chunks1 =
        case Chunks of
            #{Key := Old} -> cancel_assembly(Old, Chunks, Key);
            #{} -> Chunks
        end,
    Ref = make_ref(),
    Timer = erlang:send_after(?ASSEMBLY_MS, self(), {assembly_timeout, Key, Ref}),
    Entry = Extra#{total => Total, next => 2, parts => [Chunk], ref => Ref, timer => Timer},
    maybe_complete(Key, Entry, State#{chunks := Chunks1#{Key => Entry}});
add_chunk({Pid, Token, _} = Key, Part, Total, Chunk, _Extra, #{chunks := Chunks} = State) ->
    case maps:find(Key, Chunks) of
        {ok, #{total := Total, next := Part, parts := Parts} = Entry} ->
            Entry1 = Entry#{next := Part + 1, parts := [Chunk | Parts]},
            maybe_complete(Key, Entry1, State#{chunks := Chunks#{Key := Entry1}});
        {ok, Entry} ->
            fail(Pid, <<"INVALID_PARAMS">>, [Token], <<"Session description chunk out of order">>),
            State#{chunks := cancel_assembly(Entry, Chunks, Key)};
        error ->
            fail(Pid, <<"INVALID_PARAMS">>, [Token], <<"Session description chunk out of order">>),
            State
    end.

cancel_assembly(#{timer := Timer}, Chunks, Key) ->
    _ = erlang:cancel_timer(Timer),
    maps:remove(Key, Chunks).

maybe_complete(Key, #{total := Total, next := Next} = Entry, #{chunks := Chunks} = State) when
    Next > Total
->
    State1 = State#{chunks := cancel_assembly(Entry, Chunks, Key)},
    Base64 = iolist_to_binary(lists:reverse(maps:get(parts, Entry))),
    {Pid, Token, Kind} = Key,
    case ircd_call_proto:decode_sdp(Base64) of
        {ok, Sdp} when Kind =:= offer ->
            start_call(Pid, maps:get(callee, Entry), Token, Sdp, State1);
        {ok, Sdp} ->
            answer_call(Pid, Token, Sdp, State1);
        {error, Why} ->
            invalid_sdp(Pid, Token, Kind, Why, State1)
    end;
maybe_complete(_Key, _Entry, State) ->
    State.

invalid_sdp(Pid, Token, Kind, Why, State) ->
    fail(
        Pid,
        <<"INVALID_SDP">>,
        [Token],
        <<"Invalid session description: ", (atom_to_binary(Why))/binary>>
    ),
    case Kind of
        offer ->
            State;
        answer ->
            %% A broken answer ends the call for both sides.
            case lookup(Pid, Token, State) of
                {ok, Call} -> end_call(Call, <<"media-error">>, both, State);
                error -> State
            end
    end.

%%% Call lifecycle

start_call(Caller, Callee, Token, Sdp, #{busy := Busy, server := Server} = State) ->
    case is_map_key(Callee, Busy) orelse not alive(Callee) of
        true ->
            fail(Caller, <<"TARGET_BUSY">>, [Token], <<"That user is busy or unavailable">>),
            State;
        false when is_map_key(Caller, Busy) ->
            fail(Caller, <<"ALREADY_IN_CALL">>, [Token], <<"You are already in a call">>),
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
            logger:info(#{event => call_started, call => Id, mode => Mode, remote => remote(Call)}),
            State1 = put_call(Call, State),
            case Mode of
                anchor ->
                    ng_request(
                        Id, offer, ircd_call_proto:offer(Id, maps:get(from_tag, Call), Sdp), State1
                    );
                relay ->
                    %% The offer was rewritten by the caller's rtpengine.
                    media_result(offer, {ok, Sdp}, Call, State1)
            end
    end.

%% Whether one party is a user on another server.
remote(#{caller := Caller, callee := Callee}) ->
    not (is_pid(Caller) andalso is_pid(Callee)).

%% The other party of `Call`.
other(#{caller := Caller, callee := Callee}, Party) ->
    case Party of
        Caller -> Callee;
        _ -> Caller
    end.

%% A remote user's nick changed: their call, chunks, and rate bucket follow.
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

answer_call(Callee, Token, Sdp, State) ->
    case lookup(Callee, Token, State) of
        {ok, #{id := Id, callee := Callee, state := ringing} = Call} ->
            Answering = Call#{state := answering},
            State1 = put_call(Answering, State),
            case maps:get(mode, Call, anchor) of
                anchor ->
                    #{from_tag := From, to_tag := To} = Call,
                    ng_request(Id, answer, ircd_call_proto:answer(Id, From, To, Sdp), State1);
                relay ->
                    %% The caller's server passes the answer through its
                    %% rtpengine before the caller sees it.
                    media_result(answer, {ok, Sdp}, Answering, State1)
            end;
        _ ->
            fail(Callee, <<"INVALID_STATE">>, [Token], <<"The call cannot be answered now">>),
            State
    end.

ringing(Pid, Token, State) ->
    case lookup(Pid, Token, State) of
        {ok, #{callee := Pid, caller := Caller, state := ringing}} ->
            relay(Pid, Caller, [<<"RINGING">>], Token, none),
            State;
        _ ->
            State
    end.

%% Relay HOLD or RESUME to the other party of an active call.
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
            fail(Pid, <<"INVALID_STATE">>, [Token], <<"Only an active call can be put on hold">>);
        error ->
            fail(Pid, <<"UNKNOWN_CALL">>, [Token], <<"No such call">>)
    end.

reject(Pid, Token, Reason, State) ->
    case lookup(Pid, Token, State) of
        {ok, #{callee := Pid, caller := Caller, state := CallState} = Call} when
            CallState =:= ringing; CallState =:= offering
        ->
            relay(Pid, Caller, [<<"REJECT">>], Token, Reason),
            end_call(Call, Reason, none, State);
        {ok, _} ->
            fail(Pid, <<"INVALID_STATE">>, [Token], <<"Only a ringing call can be rejected">>),
            State;
        error ->
            fail(Pid, <<"UNKNOWN_CALL">>, [Token], <<"No such call">>),
            State
    end.

hangup(Pid, Token, Reason, State) ->
    case lookup(Pid, Token, State) of
        {ok, #{caller := Caller, callee := Callee, state := CallState} = Call} ->
            Other =
                case Pid of
                    Caller -> Callee;
                    Callee -> Caller
                end,
            %% The callee has not seen an offer that rtpengine is still handling.
            case Pid =:= Caller andalso CallState =:= offering of
                true -> ok;
                false -> relay(Pid, Other, [<<"HANGUP">>], Token, Reason)
            end,
            end_call(Call, Reason, none, State);
        error ->
            %% Hanging up a call that already ended (a race with the peer) is harmless.
            State
    end.

%% End a call: tell `both` parties, every party `{except, Pid}`, or `none`
%% (the caller of this function already notified the other side).
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
    %% A callee never saw an offer still being processed by rtpengine.
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
                    ircd_state_send:send(P, Server, <<"CALL">>, [<<"HANGUP">>, Nick, Token], Reason)
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
        anchor -> send_ng(ircd_call_proto:frame(cookie(), ircd_call_proto:delete(Id)), State1);
        relay -> ok
    end,
    State1.

put_call(#{id := Id, caller := Caller, callee := Callee, token := Token} = Call, State) ->
    State#{
        calls := (maps:get(calls, State))#{Id => Call},
        parties := (maps:get(parties, State))#{{Caller, Token} => Id, {Callee, Token} => Id},
        busy := (maps:get(busy, State))#{Caller => Id, Callee => Id}
    }.

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

%%% rtpengine NG

ng_request(Id, Op, Message, State0) ->
    %% Re-resolve once per request so a restarted rtpengine container with a
    %% new address is found; retries and deletes reuse the address.
    #{pending := Pending} = State = resolve_ng(State0),
    Cookie = cookie(),
    Packet = iolist_to_binary(ircd_call_proto:frame(Cookie, Message)),
    send_ng(Packet, State),
    Timer = erlang:send_after(?NG_RETRY_MS, self(), {ng_retry, Cookie}),
    Req = #{id => Id, op => Op, packet => Packet, tries => 1, timer => Timer},
    State#{pending := Pending#{Cookie => Req}}.

%% A request still in flight for an ended call must not be retried after the
%% NG `delete`: a retransmitted `offer` would recreate the call in rtpengine.
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

resolve_ng(#{ng := {Host, _}, ng_ip := Old} = State) ->
    case inet:getaddr(Host, inet) of
        {ok, Ip} ->
            State#{ng_ip := Ip};
        {error, Reason} ->
            logger:warning(#{event => rtpengine_resolve_failed, reason => Reason}),
            State#{ng_ip := Old}
    end.

send_ng(_Packet, #{ng_ip := undefined}) ->
    logger:warning(#{event => rtpengine_send_failed, reason => unresolved});
send_ng(Packet, #{sock := Sock, ng := {_, Port}, ng_ip := Ip}) ->
    case gen_udp:send(Sock, Ip, Port, Packet) of
        ok -> ok;
        {error, Reason} -> logger:warning(#{event => rtpengine_send_failed, reason => Reason})
    end.

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
            fail(
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
    Chunks = ircd_call_proto:chunks(Sdp),
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
                _ -> ircd_state_send:send(To, Prefix, <<"CALL">>, Params, Trailing)
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
        [#client{} = Source] -> ircd_state_send:prefix(Source);
        [] -> undefined
    end.

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

%% Send a `CALL` line toward the remote user `Key` on the link they are
%% reached through.
link_send(Key, Prefix, Params, Trailing) ->
    case mnesia:dirty_read(remote_client, Key) of
        [#remote_client{peer = Peer}] ->
            _ = ircd_links:send(Peer, ircd_wire:line(Prefix, <<"CALL">>, Params, Trailing)),
            ok;
        [] ->
            ok
    end.

alive(Pid) ->
    nick_of(Pid) =/= undefined.

%%% Per-caller rate limit: `calls_per_minute` as a token bucket.

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
