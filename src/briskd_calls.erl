-module(briskd_calls).
-moduledoc """
User-to-user voice and video calls relayed through [rtpflux](https://github.com/RustedBytes/rtpflux)
(the `calls` configuration key, vendor capability `egorsmkv.github.io/calls`).

This is a server extension, not an IRC or IRCv3 specification. Clients that
negotiate the capability exchange WebRTC session descriptions with the
`CALL` command; the server passes each description through rtpflux's NG
control protocol, so media flows browser → rtpflux → browser and neither
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
hold; the media path through rtpflux is unchanged, so the call keeps
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
callee's answer through its own rtpflux, so each user still sees only the
relay's address. The callee's server checks the callee (capability,
account, busy, limits) and relays lines between its user and the link
without touching rtpflux (`relay` mode). Each side ends its record when
the other user quits or is split away, re-keys it on a nick change, and
keeps its own ring and duration timers. A peer that does not know `CALL`
ignores it, so the caller hears no answer until the ring timeout.

Process model: `command/3` runs inside `m:briskd_state`, validates syntax,
resolves the callee among local users or users behind a link, checks the
capabilities it can see, and casts to this process. This process owns the call table, chunk reassembly, the UDP
socket to rtpflux, the ring and duration timers, and a monitor on each
party; it reads client rows from Mnesia and sends lines straight to session
processes. It never calls `m:briskd_state`, so there is no call cycle.

Bounds: one call per user (ringing or active), `max_calls` calls in total,
`calls_per_minute` new calls per caller, descriptions of at most 40 chunks
and 12 KiB (`m:briskd_call_proto`), and a 10-second window to finish sending a
description. NG requests are retried twice (after 1 s each) with the same
cookie, which rtpflux answers from its cache, then treated as failed.
Call state is in memory only; a restart ends every call.
""".
-behaviour(gen_server).
-include("briskd_client.hrl").
-include("briskd_remote.hrl").
-export([
    start_link/1,
    enabled/0,
    cap_value/0,
    command/3,
    receive_link/3,
    remote_gone/1,
    remote_renamed/2,
    fail/4,
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

-doc "Start the call server, registered as `briskd_calls`.".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

-doc "Whether voice calls are configured (the `calls` key is set).".
-spec enabled() -> boolean().
enabled() ->
    maps:get(calls, briskd_config:current_or_empty(), null) =/= null.

-doc """
Value of the `egorsmkv.github.io/calls` capability: protocol version, ring
timeout, `hold` (the server relays `HOLD` and `RESUME`), and `video` when
video calls are allowed (`calls.video`, on by default).
""".
-spec cap_value() -> binary().
cap_value() ->
    #{calls := #{ring_timeout := Ring} = Calls} = briskd_config:current(),
    Video =
        case maps:get(video, Calls, false) of
            true -> <<",video">>;
            false -> <<>>
        end,
    <<"v=1,ring=", (integer_to_binary(Ring))/binary, ",hold", Video/binary>>.

%% Whether descriptions may carry video (`calls.video`).
video_enabled() ->
    case briskd_config:current() of
        #{calls := #{video := true}} -> true;
        _ -> false
    end.

-doc """
Handle `CALL` from a registered local client. Runs in `m:briskd_state`.

Validates the parameters and the caller (capability, and an account when
`require_account` is set); for `OFFER` also resolves the callee, which must
be a different local user with the capability (and, with `require_account`,
logged in). Valid commands are passed to
this process; invalid ones get `FAIL CALL`.
""".
-spec command([binary()], #client{}, binary()) -> ok.
command([Sub0 | Params], #client{pid = Pid} = Client, Server) ->
    Sub = briskd_wire:upper(Sub0),
    case caller_ok(Pid) of
        ok -> dispatch(Sub, Params, Client, Server);
        {error, Code, Text} -> fail(Pid, Code, [], Text)
    end;
command([], Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"461">>, [<<"CALL">>], <<"Not enough parameters">>).

caller_ok(Pid) ->
    case briskd_cap:enabled(Pid, ?CAP) of
        false ->
            {error, <<"NEED_CAPABILITY">>, <<"Negotiate egorsmkv.github.io/calls first">>};
        true ->
            case needs_account() andalso briskd_state_v3:account(Pid) =:= undefined of
                true -> {error, <<"ACCOUNT_REQUIRED">>, <<"Log in to make calls">>};
                false -> ok
            end
    end.

dispatch(Sub, [Nick, Token, PartBin, TotalBin, Chunk | _], #client{pid = Pid}, _Server) when
    Sub =:= <<"OFFER">>; Sub =:= <<"ANSWER">>
->
    case
        {
            briskd_call_proto:valid_token(Token),
            briskd_call_proto:parse_part(PartBin, TotalBin),
            briskd_call_proto:valid_chunk(Chunk)
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
    case briskd_call_proto:valid_token(Token) of
        true ->
            Reason =
                case Rest of
                    [R | _] -> briskd_call_proto:reason(R);
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
    case briskd_call_proto:valid_token(Token) of
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
    case briskd_state_client:find_nick(Nick) of
        #client{pid = Pid} ->
            {error, <<"INVALID_TARGET">>, <<"You cannot call yourself">>};
        #client{pid = Callee} ->
            case briskd_cap:enabled(Callee, ?CAP) of
                true ->
                    %% With require_account the callee must be able to answer.
                    case needs_account() andalso briskd_state_v3:account(Callee) =:= undefined of
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
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
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
    #{calls := #{require_account := Required}} = briskd_config:current(),
    Required.

cast(Msg) ->
    gen_server:cast(?MODULE, Msg).

-doc "Send a `FAIL CALL` notice to a local client or a `CALL FAIL` across a server link.".
-spec fail(pid() | {remote, binary()}, binary(), [binary()], binary()) -> ok.
fail(Pid, Code, Context, Text) when is_pid(Pid) ->
    briskd_state_send:fail(Pid, <<"CALL">>, Code, Context, Text);
fail({remote, Key}, Code, [Token | _], Text) ->
    %% The far server turns this into FAIL CALL for its user.
    case briskd_calls_ng:nick_of({remote, Key}) of
        undefined ->
            ok;
        Nick ->
            briskd_calls_ng:link_send(Key, server_name(), [<<"FAIL">>, Nick, Token, Code], Text)
    end;
fail({remote, _}, _Code, [], _Text) ->
    ok.

server_name() ->
    maps:get(name, briskd_config:current()).

%%% Server links

-doc """
Handle `CALL` from the server link `Peer` with source `Prefix`. Runs in
`m:briskd_state`. A user source must be a remote user reached through `Peer`
(`briskd_state_link:remote_source/2`); a server source (`HANGUP` and `FAIL`
only) must be `Peer` or a server behind it. The line is delivered to a
local target, forwarded to the link of a remote target (never back to
`Peer`), or, for a target that is gone, answered with `FAIL NO_SUCH_NICK`.
Malformed lines and untrusted sources are logged and dropped: the link
stays up, as for a newer peer's subcommand this server does not know.
Always returns `ok`.
""".
-spec receive_link(binary(), binary(), [binary()]) -> ok.
receive_link(Peer, Prefix, [Sub0, Target, Token | Rest] = Params) ->
    Sub = briskd_wire:upper(Sub0),
    Source =
        case briskd_state_link:remote_source(Peer, Prefix) of
            {ok, Remote} ->
                {user, Remote};
            error ->
                case briskd_state_link:trusted_server(Peer, Prefix) of
                    true -> server;
                    false -> untrusted
                end
        end,
    case {Source, briskd_call_proto:valid_token(Token), link_sub(Sub, Source)} of
        {untrusted, _, _} ->
            drop_link_line(Peer, untrusted_source);
        {_, false, _} ->
            drop_link_line(Peer, invalid_token);
        {_, true, false} ->
            drop_link_line(Peer, invalid_subcommand);
        {_, true, true} ->
            case briskd_state_client:find_nick(Target) of
                #client{pid = Pid} ->
                    deliver_link(Source, Sub, Pid, Token, Rest, Peer);
                undefined ->
                    case mnesia:dirty_read(remote_client, briskd_wire:fold(Target)) of
                        [#remote_client{peer = Next}] when Next =/= Peer ->
                            {Middle, Trailing} = split_last(Params),
                            _ = briskd_links:send(
                                Next, briskd_wire:line(Prefix, <<"CALL">>, Middle, Trailing)
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
    _ = briskd_links:send(
        Peer, briskd_wire:line(server_name(), <<"CALL">>, [<<"FAIL">>, Nick, Token, Code], Text)
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
                            briskd_call_proto:parse_part(PartBin, TotalBin),
                            briskd_call_proto:valid_chunk(Chunk)
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
            briskd_cap:enabled(Pid, ?CAP),
            needs_account(),
            CallerAccount,
            briskd_state_v3:account(Pid)
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

reason_of([R | _]) -> briskd_call_proto:reason(R);
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
away: end their call. Called by `m:briskd_state_link` and
`m:briskd_state_net`; a no-op when calls are not configured.
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
    {Host, Port} = maps:get(rtpflux, Calls),
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
    {ok, briskd_calls_ng:resolve_ng(State)}.

-doc false.
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.

-doc false.
handle_cast({offer, Pid, Callee, Token, Part, Total, Chunk}, State) ->
    {noreply, offer_chunk(Pid, Callee, Token, Part, Total, Chunk, State)};
handle_cast({answer, Pid, Token, Part, Total, Chunk}, State) ->
    {noreply, answer_chunk(Pid, Token, Part, Total, Chunk, State)};
handle_cast({ringing, Pid, Token, _}, State) ->
    {noreply, briskd_calls_ng:ringing(Pid, Token, State)};
handle_cast({Hold, Pid, Token, _}, State) when Hold =:= hold; Hold =:= resume ->
    briskd_calls_ng:hold(Hold, Pid, Token, State),
    {noreply, State};
handle_cast({reject, Pid, Token, Reason}, State) ->
    {noreply, briskd_calls_ng:reject(Pid, Token, Reason, State)};
handle_cast({hangup, Pid, Token, Reason}, State) ->
    {noreply, briskd_calls_ng:hangup(Pid, Token, Reason, State)};
handle_cast({remote_hangup, Pid, Token, Reason}, State) ->
    %% The far server ended the call (timeout, disconnect, media failure).
    case briskd_calls_ng:lookup(Pid, Token, State) of
        {ok, Call} ->
            {noreply,
                briskd_calls_ng:end_call(
                    Call, Reason, {except, briskd_calls_ng:other(Call, Pid)}, State
                )};
        error ->
            {noreply, State}
    end;
handle_cast({remote_fail, Pid, Token, Code, Text}, State) ->
    %% The far server refused the call (busy, unsupported client, limits).
    case briskd_calls_ng:lookup(Pid, Token, State) of
        {ok, Call} ->
            fail(Pid, Code, [Token], Text),
            {noreply, briskd_calls_ng:end_call(Call, <<"refused">>, none, State)};
        error ->
            {noreply, State}
    end;
handle_cast({remote_gone, Key}, #{busy := Busy, chunks := Chunks} = State) ->
    Party = {remote, Key},
    State1 = State#{chunks := maps:filter(fun({P, _, _}, _) -> P =/= Party end, Chunks)},
    case Busy of
        #{Party := Id} ->
            Call = maps:get(Id, maps:get(calls, State1)),
            {noreply, briskd_calls_ng:end_call(Call, <<"disconnected">>, {except, Party}, State1)};
        #{} ->
            {noreply, State1}
    end;
handle_cast({remote_renamed, OldKey, NewKey}, State) ->
    {noreply, briskd_calls_ng:rekey({remote, OldKey}, {remote, NewKey}, State)};
handle_cast(_, State) ->
    {noreply, State}.

-doc false.
handle_info({udp, Sock, Ip, Port, Packet}, #{sock := Sock, ng := {_, Port}, ng_ip := Ip} = State) ->
    case briskd_call_proto:parse_reply(Packet) of
        {ok, Cookie, Result} -> {noreply, briskd_calls_ng:ng_reply(Cookie, Result, State)};
        error -> {noreply, State}
    end;
handle_info({udp, Sock, _Ip, _Port, _Packet}, #{sock := Sock} = State) ->
    %% Only rtpflux's NG address may answer; anything else is dropped
    %% before parsing (the random cookie is the second line of defense).
    {noreply, State};
handle_info({ng_retry, Cookie}, #{pending := Pending} = State) ->
    case maps:find(Cookie, Pending) of
        {ok, #{tries := Tries} = Req} when Tries < ?NG_TRIES ->
            briskd_calls_ng:send_ng(maps:get(packet, Req), State),
            Timer = erlang:send_after(?NG_RETRY_MS, self(), {ng_retry, Cookie}),
            {noreply, State#{
                pending := Pending#{Cookie := Req#{tries := Tries + 1, timer := Timer}}
            }};
        {ok, _} ->
            {noreply, briskd_calls_ng:ng_reply(Cookie, {error, <<"timeout">>}, State)};
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
            {noreply, briskd_calls_ng:end_call(Call, Reason, both, State)};
        _ ->
            {noreply, State}
    end;
handle_info({'DOWN', _MRef, process, Pid, _}, #{busy := Busy, chunks := Chunks} = State) ->
    State1 = State#{chunks := maps:filter(fun({P, _, _}, _) -> P =/= Pid end, Chunks)},
    case Busy of
        #{Pid := Id} ->
            Call = maps:get(Id, maps:get(calls, State1)),
            {noreply, briskd_calls_ng:end_call(Call, <<"disconnected">>, {except, Pid}, State1)};
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
            case briskd_calls_ng:take_rate(Pid, State) of
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
    case briskd_call_proto:decode_sdp(Base64, video_enabled()) of
        {ok, Sdp} when Kind =:= offer ->
            briskd_calls_ng:start_call(Pid, maps:get(callee, Entry), Token, Sdp, State1);
        {ok, Sdp} ->
            briskd_calls_ng:answer_call(Pid, Token, Sdp, State1);
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
            case briskd_calls_ng:lookup(Pid, Token, State) of
                {ok, Call} -> briskd_calls_ng:end_call(Call, <<"media-error">>, both, State);
                error -> State
            end
    end.
