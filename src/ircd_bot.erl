-module(ircd_bot).
-moduledoc """
One configured AI assistant bot (the `bots` configuration key).

The bot is a local client without a socket. It registers with `m:ircd_state`
the way `m:ircd_session` does, so the calling process is the client: it
negotiates `message-tags` and `echo-message`, sends `NICK` and `USER`, sets user mode `+B`
(advertised as `BOT=B`, so its messages carry the `bot` tag), and joins its
configured channels. Lines for the bot arrive as `{irc, Line}` messages and
are parsed with `ircd_wire:parse_server/1`.

When a channel message addresses the bot (`nick: question`, `nick, question`,
`@nick`, or a `+draft/reply` to one of the bot's own messages; every message
with `respond_to: all`), or a user sends it a
private message with `direct_messages` enabled, the bot calls the configured
OpenAI-compatible provider in a monitored worker process and answers with
`PRIVMSG` lines; the first line carries `+draft/reply` pointing at the
question when it had a `msgid`. While a request runs it sends
`+typing=active` `TAGMSG`s.

The bot learns the `msgid` of each line it sends from the `echo-message`
copy and keeps the last `?MAX_OWN_MSGIDS` with their text, so a reply to an
older answer is recognized and quoted to the model.

Loop and abuse protection:

- The bot never answers a `NOTICE` (RFC 2812 3.3.2), a message carrying the
  `bot` tag, its own messages, or CTCP requests.
- One request runs per channel or conversation, at most `?MAX_IN_FLIGHT` per
  bot, and requests are limited by a `requests_per_minute` token bucket.
  Refused requests get a `NOTICE` to the asker.
- Conversation memory is in-process only, capped at `history_lines` turns per
  target and `?MAX_DM_TARGETS` private conversations, and lost on restart.

Timers use the monotonic clock. A worker that outlives the provider timeout
plus `?GUARD_MS` is stopped and reported as a timeout. When the server closes
the bot's connection (an operator `KILL`), the bot registers again after
`?RECONNECT_MS`. The provider API key and conversation memory are redacted
from `format_status/1`.
""".
-behaviour(gen_server).
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-define(MAX_IN_FLIGHT, 4).
-define(MAX_DM_TARGETS, 100).
-define(GUARD_MS, 5000).
-define(RECONNECT_MS, 15000).
-define(REJOIN_MS, 30000).
-define(TYPING_MS, 4000).
-define(NICK_RETRY_MS, 60000).
-define(MAX_ASSISTANT_BYTES, 4000).
-define(MAX_OWN_MSGIDS, 500).
-define(QUOTE_BYTES, 200).

-doc """
Start a bot. `Bot` is one normalized entry of the `bots` configuration list
(`ircd_config`), with `provider` resolved to its `ai_providers` entry and
`server_name` added by `m:ircd_bots`.
""".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Bot) ->
    gen_server:start_link(?MODULE, Bot, []).

-doc false.
init(Bot) ->
    self() ! connect,
    {ok, #{
        bot => Bot,
        nick => maps:get(nick, Bot),
        nick_attempt => 0,
        registered => false,
        bucket => {float(maps:get(requests_per_minute, Bot)), now_ms()},
        pending => #{},
        busy => #{},
        history => #{},
        dm_seq => 0,
        typing_timer => undefined,
        own_msgids => #{},
        own_order => queue:new()
    }}.

-doc false.
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.

-doc false.
handle_cast(_, State) -> {noreply, State}.

-doc false.
handle_info(connect, State) ->
    {noreply, register(State)};
handle_info({irc, Line}, State) ->
    case ircd_wire:parse_server(iolist_to_binary(Line)) of
        {ok, Tags, Prefix, Command, Params} ->
            {noreply, handle_line(Tags, Prefix, Command, Params, State)};
        _ ->
            {noreply, State}
    end;
handle_info({irc_close, _Line}, #{bot := Bot} = State) ->
    %% KILL or a server-side close: ircd_state has already removed the client.
    logger:warning(#{event => bot_disconnected, bot => maps:get(nick, Bot)}),
    erlang:send_after(?RECONNECT_MS, self(), connect),
    {noreply, State#{registered := false}};
handle_info({irc_safelist, _}, State) ->
    {noreply, State};
handle_info({rejoin, Channel}, #{registered := true} = State) ->
    cmd(<<"JOIN">>, [Channel]),
    {noreply, State};
handle_info({rejoin, _}, State) ->
    {noreply, State};
handle_info(retry_nick, #{registered := false} = State) ->
    {noreply, register(State#{nick_attempt := 0})};
handle_info(retry_nick, State) ->
    {noreply, State};
handle_info({bot_result, Ref, Result}, #{pending := Pending} = State) ->
    case maps:take(Ref, Pending) of
        {Req, Rest} ->
            demonitor(maps:get(mref, Req), [flush]),
            _ = erlang:cancel_timer(maps:get(guard, Req)),
            {noreply, finish(Req, Result, State#{pending := Rest})};
        error ->
            {noreply, State}
    end;
handle_info({bot_timeout, Ref}, #{pending := Pending} = State) ->
    case maps:take(Ref, Pending) of
        {Req, Rest} ->
            demonitor(maps:get(mref, Req), [flush]),
            exit(maps:get(worker, Req), timeout),
            {noreply, finish(Req, {error, timeout}, State#{pending := Rest})};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', MRef, process, _Pid, Reason}, #{pending := Pending} = State) ->
    %% A worker sends its result before exiting, so a DOWN for a request that
    %% is still pending means the worker failed without answering.
    case [R || {R, #{mref := M}} <- maps:to_list(Pending), M =:= MRef] of
        [Ref] ->
            {Req, Rest} = maps:take(Ref, Pending),
            _ = erlang:cancel_timer(maps:get(guard, Req)),
            {noreply, finish(Req, {error, {worker_exit, Reason}}, State#{pending := Rest})};
        [] ->
            {noreply, State}
    end;
handle_info(typing_tick, #{pending := Pending} = State) ->
    maps:foreach(fun(_, #{target := Target}) -> typing(Target, <<"active">>) end, Pending),
    {noreply, schedule_typing(State#{typing_timer := undefined})};
%% Other session messages (attach, ban notices) do not apply to a bot.
handle_info(_, State) ->
    {noreply, State}.

-doc false.
format_status(Status) ->
    maps:map(
        fun
            (state, #{bot := Bot} = S) ->
                Provider = maps:get(provider, Bot),
                S#{
                    bot := Bot#{provider := Provider#{api_key => redacted}},
                    history := redacted,
                    own_msgids := redacted
                };
            (_, Value) ->
                Value
        end,
        Status
    ).

%%% Registration

register(#{bot := Bot, nick := Nick} = State) ->
    ok = ircd_state:connect(maps:get(server_name, Bot), #{
        transport => bot, secure => true
    }),
    cmd(<<"CAP">>, [<<"REQ">>, <<"message-tags echo-message">>]),
    cmd(<<"NICK">>, [Nick]),
    cmd(<<"USER">>, [maps:get(user, Bot), <<"0">>, <<"*">>, maps:get(realname, Bot)]),
    cmd(<<"CAP">>, [<<"END">>]),
    State.

registered(Nick, #{bot := Bot} = State) ->
    cmd(<<"MODE">>, [Nick, <<"+B">>]),
    lists:foreach(fun(Channel) -> cmd(<<"JOIN">>, [Channel]) end, maps:get(channels, Bot)),
    logger:info(#{
        event => bot_registered,
        bot => Nick,
        channels => length(maps:get(channels, Bot))
    }),
    State#{nick := Nick, registered := true, nick_attempt := 0}.

%% 432/433 during registration: try `nick_`, `nick__`, then wait and retry.
nick_rejected(#{bot := Bot, nick_attempt := Attempt} = State) when Attempt < 2 ->
    Base = maps:get(nick, Bot),
    Next = alternate_nick(Base, Attempt + 1, ircd_state:nicklen()),
    cmd(<<"NICK">>, [Next]),
    State#{nick := Next, nick_attempt := Attempt + 1};
nick_rejected(#{bot := Bot} = State) ->
    logger:warning(#{event => bot_nick_unavailable, bot => maps:get(nick, Bot)}),
    cmd(<<"QUIT">>, [<<"Nickname unavailable">>]),
    erlang:send_after(?NICK_RETRY_MS, self(), retry_nick),
    State#{nick := maps:get(nick, Bot), registered := false}.

alternate_nick(Base, Count, NickLen) ->
    Suffix = binary:copy(<<"_">>, Count),
    Keep = max(1, min(byte_size(Base), NickLen - Count)),
    <<(binary:part(Base, 0, Keep))/binary, Suffix/binary>>.

%%% Incoming lines

handle_line(_Tags, _Prefix, <<"001">>, [Nick | _], State) ->
    registered(Nick, State);
handle_line(_Tags, _Prefix, Code, _Params, #{registered := false} = State) when
    Code =:= <<"432">>; Code =:= <<"433">>; Code =:= <<"437">>
->
    nick_rejected(State);
handle_line(_Tags, _Prefix, <<"PING">>, Params, State) ->
    cmd(<<"PONG">>, Params),
    State;
handle_line(_Tags, Prefix, <<"NICK">>, [New | _], #{nick := Nick} = State) ->
    case ircd_wire:fold(source_nick(Prefix)) =:= ircd_wire:fold(Nick) of
        true -> State#{nick := New};
        false -> State
    end;
handle_line(_Tags, _Prefix, <<"KICK">>, [Channel, Victim | _], #{nick := Nick} = State) ->
    case ircd_wire:fold(Victim) =:= ircd_wire:fold(Nick) of
        true ->
            _ = erlang:send_after(?REJOIN_MS, self(), {rejoin, Channel}),
            ok;
        false ->
            ok
    end,
    State;
handle_line(_Tags, _Prefix, Code, [_, Channel | _], #{bot := Bot} = State) when
    Code =:= <<"471">>; Code =:= <<"473">>; Code =:= <<"474">>; Code =:= <<"475">>
->
    logger:warning(#{
        event => bot_join_refused, bot => maps:get(nick, Bot), numeric => Code, channel => Channel
    }),
    State;
handle_line(Tags, Prefix, <<"PRIVMSG">>, [Target, Text | _], #{registered := true} = State) ->
    Sender = source_nick(Prefix),
    case is_self(Sender, State) of
        true ->
            %% echo-message: learn the msgid of our own line.
            note_own(tag(<<"msgid">>, Tags), Text, State);
        false ->
            case ignored(Tags, Sender, Text, State) of
                true -> State;
                false -> message(Tags, Sender, Target, Text, State)
            end
    end;
handle_line(_Tags, _Prefix, _Command, _Params, State) ->
    State.

source_nick(undefined) ->
    <<>>;
source_nick(Prefix) ->
    hd(binary:split(Prefix, <<"!">>)).

is_self(Sender, #{nick := Nick}) ->
    ircd_wire:fold(Sender) =:= ircd_wire:fold(Nick).

%% Never answer other bots (the `bot` tag), servers, or CTCP.
ignored(Tags, Sender, Text, _State) ->
    Sender =:= <<>> orelse
        binary:match(Sender, <<".">>) =/= nomatch orelse
        lists:keymember(<<"bot">>, 1, Tags) orelse
        is_ctcp(Text).

tag(Key, Tags) ->
    case lists:keyfind(Key, 1, Tags) of
        {_, Value} when is_binary(Value) -> valid_msgid(Value);
        _ -> undefined
    end.

%% Server msgids are short tokens; anything else is not used as a reference.
valid_msgid(Value) when byte_size(Value) > 0, byte_size(Value) =< 128 ->
    case re:run(Value, <<"^[A-Za-z0-9._:-]+$">>, [{capture, none}]) of
        match -> Value;
        nomatch -> undefined
    end;
valid_msgid(_) ->
    undefined.

%% Remember our last ?MAX_OWN_MSGIDS lines (msgid => text), oldest evicted.
note_own(undefined, _Text, State) ->
    State;
note_own(MsgId, Text, #{own_msgids := Own, own_order := Order} = State) ->
    Quote = ircd_bot_ai:clean_input(binary:part(Text, 0, min(byte_size(Text), ?QUOTE_BYTES))),
    Own1 = Own#{MsgId => Quote},
    Order1 = queue:in(MsgId, Order),
    case queue:len(Order1) > ?MAX_OWN_MSGIDS of
        true ->
            {{value, Old}, Order2} = queue:out(Order1),
            State#{own_msgids := maps:remove(Old, Own1), own_order := Order2};
        false ->
            State#{own_msgids := Own1, own_order := Order1}
    end.

%% The bot's line a message replies to (`+draft/reply`), if it is one of ours.
replied_line(Tags, #{own_msgids := Own}) ->
    case tag(<<"+draft/reply">>, Tags) of
        undefined -> undefined;
        MsgId -> maps:get(MsgId, Own, undefined)
    end.

is_ctcp(<<1, "ACTION ", _/binary>>) -> false;
is_ctcp(<<1, _/binary>>) -> true;
is_ctcp(_) -> false.

message(Tags, Sender, Target, Text0, #{bot := Bot, nick := Nick} = State) ->
    Text = action_text(Sender, Text0),
    Origin = #{msgid => tag(<<"msgid">>, Tags), quote => replied_line(Tags, State)},
    case is_channel(Target) of
        true ->
            Key = ircd_wire:fold(Target),
            Clean = ircd_bot_ai:clean_input(Text),
            State1 =
                case maps:get(context, Bot) of
                    channel when Clean =/= <<>> ->
                        remember(Key, [{user, <<Sender/binary, ": ", Clean/binary>>}], State);
                    _ ->
                        State
                end,
            Trigger =
                case maps:get(respond_to, Bot) of
                    all when Text =:= Text0 -> {true, Text};
                    all -> false;
                    mention -> mention_or_reply(Nick, Text, Text0, Origin)
                end,
            case Trigger of
                {true, Question} -> ask(Target, Sender, Question, Origin, State1);
                false -> State1
            end;
        false ->
            case maps:get(direct_messages, Bot) of
                true when Text =:= Text0 ->
                    ask(Sender, Sender, Text, Origin, State);
                true ->
                    State;
                false ->
                    notice(Sender, <<"I only answer in channels.">>),
                    State
            end
    end.

%% Addressed by name, or a reply to one of the bot's own lines.
mention_or_reply(Nick, Text, Text0, #{quote := Quote}) ->
    case ircd_bot_ai:addressed(Nick, Text) of
        {true, _} = Addressed -> Addressed;
        false when Quote =/= undefined, Text =:= Text0 -> {true, Text};
        false -> false
    end.

action_text(Sender, <<1, "ACTION ", Rest/binary>>) ->
    <<"* ", Sender/binary, " ", (binary:replace(Rest, <<1>>, <<>>, [global]))/binary>>;
action_text(_Sender, Text) ->
    Text.

is_channel(<<C, _/binary>>) -> C =:= $# orelse C =:= $& orelse C =:= $+ orelse C =:= $!;
is_channel(_) -> false.

%%% Requests

ask(Target, Asker, Question0, Origin, #{bot := Bot} = State) ->
    Question = ircd_bot_ai:clean_input(Question0),
    Key = ircd_wire:fold(Target),
    #{busy := Busy, pending := Pending} = State,
    if
        Question =:= <<>> ->
            State;
        is_map_key(Key, Busy) ->
            notice(Asker, <<"I'm still answering the previous question here; please wait.">>),
            State;
        map_size(Pending) >= ?MAX_IN_FLIGHT ->
            notice(Asker, <<"I'm busy right now; please try again in a moment.">>),
            State;
        true ->
            case take_token(State) of
                {ok, State1} ->
                    start_request(Target, Key, Asker, Question, Origin, Bot, State1);
                limited ->
                    logger:notice(#{event => bot_rate_limited, bot => maps:get(nick, Bot)}),
                    notice(Asker, <<"Too many requests; please try again in a minute.">>),
                    State
            end
    end.

start_request(Target, Key, Asker, Question0, Origin, Bot, #{nick := Nick} = State) ->
    InChannel = is_channel(Target),
    %% A reply quotes the bot line it answers, so the model knows the thread.
    Question =
        case maps:get(quote, Origin) of
            undefined -> Question0;
            Quote -> <<"(replying to your message \"", Quote/binary, "\") ", Question0/binary>>
        end,
    UserTurn =
        case InChannel of
            true -> <<Asker/binary, ": ", Question/binary>>;
            false -> Question
        end,
    Turns = lists:reverse(history(Key, State)),
    %% With channel context the triggering line is already the newest
    %% remembered turn; it is sent once, as the question.
    Prior =
        case InChannel andalso maps:get(context, Bot) =:= channel of
            true -> drop_last_user(Turns);
            false -> Turns
        end,
    Context = context_line(Nick, Target, InChannel, Bot),
    Body = ircd_bot_ai:build_request(
        maps:with([model, max_tokens, temperature], Bot),
        maps:get(system_prompt, Bot),
        Context,
        Prior,
        UserTurn
    ),
    Provider = maps:get(provider, Bot),
    Timeout = maps:get(timeout, Provider),
    Self = self(),
    Ref = make_ref(),
    {Worker, MRef} = spawn_monitor(fun() ->
        Self ! {bot_result, Ref, ircd_bot_ai:request(Provider, Body, Timeout)}
    end),
    Guard = erlang:send_after(Timeout + ?GUARD_MS, self(), {bot_timeout, Ref}),
    typing(Target, <<"active">>),
    Req = #{
        key => Key,
        target => Target,
        asker => Asker,
        user_turn => UserTurn,
        reply_to => maps:get(msgid, Origin),
        worker => Worker,
        mref => MRef,
        guard => Guard
    },
    State1 = State#{
        pending := (maps:get(pending, State))#{Ref => Req},
        busy := (maps:get(busy, State))#{Key => Ref}
    },
    schedule_typing(State1).

drop_last_user(Turns) ->
    case lists:reverse(Turns) of
        [{user, _} | Rest] -> lists:reverse(Rest);
        _ -> Turns
    end.

context_line(Nick, Target, true, _Bot) ->
    Network = maps:get(network, persistent_term:get({ircd_state, config}, #{}), <<"IRC">>),
    <<"You are ", Nick/binary, ", an assistant in the IRC channel ", Target/binary, " on ",
        Network/binary,
        ". User messages are prefixed with the sender's nickname. Reply in plain text "
        "without Markdown; keep answers short.">>;
context_line(Nick, Target, false, _Bot) ->
    Network = maps:get(network, persistent_term:get({ircd_state, config}, #{}), <<"IRC">>),
    <<"You are ", Nick/binary, ", an assistant in a private IRC conversation with ", Target/binary,
        " on ", Network/binary, ". Reply in plain text without Markdown; keep answers short.">>.

finish(#{key := Key, target := Target, asker := Asker} = Req, Result, #{bot := Bot} = State) ->
    State1 = State#{busy := maps:remove(Key, maps:get(busy, State))},
    case Result of
        {ok, Text} ->
            reply(Target, Asker, Text, maps:get(reply_to, Req), State1),
            %% Channel context already holds the question line.
            Turns =
                case maps:get(context, Bot) =:= channel andalso is_channel(Target) of
                    true -> [assistant(Text)];
                    false -> [{user, maps:get(user_turn, Req)}, assistant(Text)]
                end,
            remember(Key, Turns, State1);
        {error, Reason} ->
            logger:warning(#{
                event => bot_request_failed,
                bot => maps:get(nick, Bot),
                reason => failure_reason(Reason)
            }),
            typing(Target, <<"done">>),
            notice(Asker, <<"Sorry, I couldn't get an answer right now.">>),
            State1
    end.

assistant(Text) ->
    {assistant, ircd_bot_ai:clean_reply(Text, ?MAX_ASSISTANT_BYTES)}.

%% Log the kind of failure only: provider messages may echo user input.
failure_reason({http_status, Status, _}) -> {http_status, Status};
failure_reason({worker_exit, _}) -> worker_exit;
failure_reason(Reason) when is_atom(Reason) -> Reason;
failure_reason(Reason) when is_tuple(Reason) -> element(1, Reason);
failure_reason(_) -> other.

reply(Target, Asker, Text, ReplyTo, #{bot := Bot, nick := Nick}) ->
    Prefix =
        case is_channel(Target) of
            true -> <<Asker/binary, ": ">>;
            false -> <<>>
        end,
    Budget =
        ircd_bot_ai:text_budget(Nick, maps:get(user, Bot), maps:get(server_name, Bot), Target) -
            byte_size(Prefix),
    case ircd_bot_ai:reply_lines(Text, Budget, maps:get(max_reply_lines, Bot)) of
        [] ->
            typing(Target, <<"done">>);
        [First | Rest] ->
            %% Thread the answer under the question (`+draft/reply`).
            Tags =
                case ReplyTo of
                    undefined -> [];
                    MsgId -> [{<<"+draft/reply">>, MsgId}]
                end,
            command(<<"PRIVMSG">>, [Target, <<Prefix/binary, First/binary>>], Tags),
            lists:foreach(fun(Line) -> cmd(<<"PRIVMSG">>, [Target, Line]) end, Rest)
    end.

%%% Memory

history(Key, #{history := History}) ->
    case maps:find(Key, History) of
        {ok, {_Seq, Turns}} -> Turns;
        error -> []
    end.

%% Newest first, capped at `history_lines` turns; private conversations are
%% capped at ?MAX_DM_TARGETS by evicting the least recently used.
remember(Key, NewTurns, #{bot := Bot, history := History, dm_seq := Seq} = State) ->
    Limit = maps:get(history_lines, Bot),
    case Limit of
        0 ->
            State;
        _ ->
            Turns = lists:sublist(lists:reverse(NewTurns) ++ history(Key, State), Limit),
            History1 = evict(Key, History),
            State#{history := History1#{Key => {Seq + 1, Turns}}, dm_seq := Seq + 1}
    end.

evict(Key, History) when is_map_key(Key, History) ->
    History;
evict(Key, History) ->
    Dms = [{S, K} || K := {S, _} <- History, not is_channel(K)],
    case not is_channel(Key) andalso length(Dms) >= ?MAX_DM_TARGETS of
        true ->
            {_, Oldest} = lists:min(Dms),
            maps:remove(Oldest, History);
        false ->
            History
    end.

%%% Rate limit: a token bucket refilled at `requests_per_minute`.

take_token(#{bot := Bot, bucket := {Tokens, Last}} = State) ->
    Rate = maps:get(requests_per_minute, Bot),
    Now = now_ms(),
    Refilled = min(float(Rate), Tokens + (Now - Last) * Rate / 60000),
    case Refilled >= 1.0 of
        true -> {ok, State#{bucket := {Refilled - 1.0, Now}}};
        false -> limited
    end.

now_ms() ->
    erlang:monotonic_time(millisecond).

%%% Output

schedule_typing(#{pending := Pending, typing_timer := undefined} = State) when
    map_size(Pending) > 0
->
    State#{typing_timer := erlang:send_after(?TYPING_MS, self(), typing_tick)};
schedule_typing(State) ->
    State.

typing(Target, Value) ->
    command(<<"TAGMSG">>, [Target], [{<<"+typing">>, Value}]).

notice(Target, Text) ->
    cmd(<<"NOTICE">>, [Target, Text]).

cmd(Command, Params) ->
    command(Command, Params, []).

command(Command, Params, Tags) ->
    Bytes = byte_size(Command) + lists:sum([byte_size(P) + 2 || P <- Params]) + 2,
    _ = ircd_state:command(Command, Params, Bytes, Tags),
    ok.
