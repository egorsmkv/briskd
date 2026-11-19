-module(ircd_state_send).
-export([
    batch_ref/0,
    begin_batch/2,
    begin_batch/3,
    begin_label/2,
    broadcast/5,
    broadcast/6,
    clear_source/0,
    resume_reply/1,
    suspend_reply/0,
    echo/6,
    end_batch/0,
    end_label/1,
    fail/5,
    msgid/0,
    note/5,
    numeric/5,
    prefix/1,
    send/5,
    send/6,
    set_source/1,
    with_source/2,
    source_tags/1,
    time_tag/0,
    time_value/1,
    warn/5,
    with_batch/5
]).
-include("ircd_state.hrl").

-moduledoc """
Reply formatting, per-recipient tag filtering, labeled responses, batches,
and delivery of lines to client sessions.

Runs inside `m:ircd_state`. Every line is encoded with
`ircd_wire:message/5` and sent to the session process as `{irc, Line}`; the
session writes it to its socket. Sent message and byte counts are recorded
for `STATS l`. The label, ambient batch, and command source live in the
process dictionary for the duration of one command.

## Tag filtering

Tags are filtered per recipient by negotiated capability
([message-tags](https://ircv3.net/specs/extensions/message-tags)): `label`
and `batch` always pass; `time` needs `server-time`; `account` needs
`account-tag`; `draft/oper` needs `draft/oper-tag`; every other tag
(client-only `+` tags, `msgid`, `bot`) needs `message-tags`. A recipient
with `server-time` gets a `time` tag on every line. `TAGMSG` is not
delivered to a recipient without `message-tags`. In a channel fan-out each
distinct visible tag set is encoded once and the binary is shared.

## Labels and batches

A labeled command ([labeled-response](https://ircv3.net/specs/extensions/labeled-response))
buffers replies to the commanding client between `begin_label/2` and
`end_label/1`, which emits one tagged line, one `labeled-response`
[batch](https://ircv3.net/specs/extensions/batch), or `ACK` when there was
no reply. Copies of other users' messages delivered to the same client are
not part of the labeled reply.

An ambient batch (`begin_batch/2` .. `end_batch/0`) wraps every line sent
while it is open, for each recipient that negotiated `batch`; it is used for
`netsplit`, `netjoin`, and similar server-initiated batches.
`with_batch/5` wraps the lines to one client.

## Source tags

The source (`set_source/1`) names the user whose command is being applied.
Lines with that user's prefix carry `account`, `bot`, and `draft/oper`.
""".

-doc """
The `nick!user@host` prefix of a client, as iodata.
""".
-spec prefix(#client{}) -> iolist().
prefix(#client{nick = Nick, user = User, host = Host}) -> [Nick, <<"!">>, User, <<"@">>, Host].

-doc """
Send numeric reply `Number` from `Server` to a client.

The client's current nickname (`*` before registration) is added as the
first parameter, as RFC 2812 2.4 requires. `Text` is the trailing parameter,
or `none` for no trailing parameter.
""".
-spec numeric(#client{}, binary(), term(), [binary()], none | iodata()) -> ok.
numeric(#client{pid = Pid, nick = Nick}, Server, Number, Params, Text) ->
    send(Pid, Server, Number, [Nick | Params], Text).

-doc """
Send the [standard reply](https://ircv3.net/specs/extensions/standard-replies)
`FAIL <command> <code> [context...] :<text>` from the local server.
""".
-spec fail(pid(), binary(), binary(), [iodata()], iodata()) -> ok.
fail(Pid, Command, Code, Context, Text) ->
    standard(Pid, <<"FAIL">>, Command, Code, Context, Text).

-doc """
Send the standard reply `WARN <command> <code> [context...] :<text>` from
the local server.
""".
-spec warn(pid(), binary(), binary(), [iodata()], iodata()) -> ok.
warn(Pid, Command, Code, Context, Text) ->
    standard(Pid, <<"WARN">>, Command, Code, Context, Text).

-doc """
Send the standard reply `NOTE <command> <code> [context...] :<text>` from
the local server.
""".
-spec note(pid(), binary(), binary(), [iodata()], iodata()) -> ok.
note(Pid, Command, Code, Context, Text) ->
    standard(Pid, <<"NOTE">>, Command, Code, Context, Text).

standard(Pid, Type, Command, Code, Context, Text) ->
    send(Pid, local_server(), Type, [Command, Code | Context], Text).

-doc """
Send one line to every pid in `Pids`.

Same as `broadcast(Pids, Prefix, Command, Middle, Tail, [])`.
""".
-spec broadcast([pid()], iodata(), binary(), [iodata()], none | iodata()) -> ok.
broadcast(Pids, Prefix, Command, Middle, Tail) ->
    broadcast(Pids, Prefix, Command, Middle, Tail, []).

-doc """
Send one line with `Tags` to every pid in `Pids` (channel fan-out).

A `time` tag and the current source's tags are added once for all
recipients, so every copy carries the same timestamp. Each recipient sees
only the tags its capabilities allow. Outside an ambient batch, each
distinct filtered line is encoded once and shared between recipients.
""".
-spec broadcast([pid()], iodata(), binary(), [iodata()], none | iodata(), [
    {binary(), undefined | binary()}
]) -> ok.
broadcast([], _Prefix, _Command, _Middle, _Tail, _Tags) ->
    ok;
broadcast(Pids, Prefix, Command, Middle, Tail, Tags0) ->
    Tags = with_time(add_source_tags(Prefix, Tags0)),
    case get(ircd_batch) of
        #{} ->
            lists:foreach(fun(Pid) -> send(Pid, Prefix, Command, Middle, Tail, Tags) end, Pids);
        _ ->
            LabelPid = label_pid(),
            lists:foldl(
                fun
                    (Pid, Cache) when Pid =:= LabelPid ->
                        send(Pid, Prefix, Command, Middle, Tail, Tags),
                        Cache;
                    (Pid, Cache) ->
                        send_cached(Pid, Prefix, Command, Middle, Tail, Tags, Cache)
                end,
                #{},
                Pids
            ),
            ok
    end.

-doc """
Send one line to the session `Pid`. Same as `send/6` with no tags.
""".
-spec send(pid(), iodata(), binary(), [iodata()], none | iodata()) -> ok.
send(Pid, Prefix, Command, Middle, Tail) ->
    send(Pid, Prefix, Command, Middle, Tail, []).

-doc """
Send one line `[@Tags] :Prefix Command Middle... [:Tail]` to the session
`Pid`.

`Tail` is the trailing parameter, or `none`. Source tags are added when
`Prefix` is the current source, the line joins an open ambient batch, and
the tags are filtered for the recipient. When `Pid` is the client of the
current labeled command, the line is buffered for `end_label/1` instead,
unless it is a copy of a user's `PRIVMSG`, `NOTICE`, or `TAGMSG`. A line
that `ircd_wire:message/5` cannot fit is dropped.
""".
-spec send(pid(), iodata(), binary(), [iodata()], none | iodata(), [
    {binary(), undefined | binary()}
]) -> ok.
send(Pid, Prefix, Command, Middle, Tail, Tags0) ->
    Tags =
        case batch_command(Command) of
            true -> ambient_batch(Pid, add_source_tags(Prefix, Tags0));
            false -> add_source_tags(Prefix, Tags0)
        end,
    case get(ircd_label) of
        {Pid, Label, _Acc} when is_binary(Label) ->
            %% A batched line (history replay, a multiline copy) belongs to
            %% the labeled reply even when it looks like a client's message.
            Batched = lists:keymember(<<"batch">>, 1, Tags),
            case client_echo(Command, Prefix) andalso not Batched of
                true -> relay(Pid, Prefix, Command, Middle, Tail, Tags);
                false -> buffer_label(Prefix, Command, Middle, Tail, Tags)
            end;
        _ ->
            relay(Pid, Prefix, Command, Middle, Tail, Tags)
    end.

-doc """
Send the sender's own copy of a message
([echo-message](https://ircv3.net/specs/extensions/echo-message)).

Unlike `send/6`, the copy is buffered as the labeled response when the
command carries a label, and no ambient batch tag is added.
""".
-spec echo(pid(), iodata(), binary(), [iodata()], none | iodata(), list()) -> ok.
echo(Pid, Prefix, Command, Middle, Tail, Tags0) ->
    Tags = add_source_tags(Prefix, Tags0),
    case get(ircd_label) of
        {Pid, Label, _Acc} when is_binary(Label) ->
            buffer_label(Prefix, Command, Middle, Tail, Tags);
        _ ->
            relay(Pid, Prefix, Command, Middle, Tail, Tags)
    end.

-doc """
Start collecting replies to `Pid` when `Label` is a binary label value.

With `undefined` (no label, or `labeled-response` not negotiated) replies
are sent immediately. Must be paired with `end_label/1`.
""".
-spec begin_label(pid(), undefined | binary()) -> ok.
begin_label(Pid, Label) when is_binary(Label) ->
    put(ircd_label, {Pid, Label, []}),
    ok;
begin_label(_Pid, _) ->
    put(ircd_label, off),
    ok.

-doc """
Take the current command's reply context (the labeled-response collector and
the source set by `set_source/1`) out of this process, for a command whose
reply is deferred (`m:ircd_deferred`). Pass the result to `resume_reply/1`
before sending the rest of the reply.
""".
-spec suspend_reply() -> {term(), term()}.
suspend_reply() ->
    {erase(ircd_label), erase(ircd_source)}.

-doc """
Restore a reply context taken by `suspend_reply/0`; the command then finishes
with `end_label/1` and `clear_source/0` as usual.
""".
-spec resume_reply({term(), term()}) -> ok.
resume_reply({Label, Source}) ->
    _ =
        case Label of
            undefined -> erase(ircd_label);
            _ -> put(ircd_label, Label)
        end,
    _ =
        case Source of
            undefined -> erase(ircd_source);
            _ -> put(ircd_source, Source)
        end,
    ok.

-doc """
Send the collected labeled reply, if a label was active, from `Server`.

No reply sends `ACK`; one reply carries the `label` tag itself; a reply
that is already a single batch gets the label on its opening `BATCH`;
several replies are wrapped in a `labeled-response` batch.
""".
-spec end_label(binary()) -> ok.
end_label(Server) ->
    case erase(ircd_label) of
        {Pid, Label, []} ->
            relay(Pid, Server, <<"ACK">>, [], none, [{<<"label">>, Label}]);
        {Pid, Label, [Message]} ->
            send_labeled(Pid, Label, Message);
        {Pid, Label, Messages} ->
            case single_batch(lists:reverse(Messages)) of
                {true, [{Prefix, Command, Middle, Tail, Tags} | Rest]} ->
                    %% The reply is already one batch (a draft/multiline echo):
                    %% the label goes on its opening BATCH line.
                    relay(Pid, Prefix, Command, Middle, Tail, [{<<"label">>, Label} | Tags]),
                    lists:foreach(
                        fun({P, C, M, T, G}) -> relay(Pid, P, C, M, T, G) end, Rest
                    );
                false ->
                    labeled_batch(Pid, Server, Label, Messages)
            end;
        _ ->
            ok
    end.

%% True when the messages are exactly one BATCH +ref ... BATCH -ref with every
%% line between them tagged with that reference.
single_batch([{_, <<"BATCH">>, [<<"+", Ref/binary>> | _], _, _} | _] = Ordered) when
    length(Ordered) >= 2
->
    {Inner, [Last]} = lists:split(length(Ordered) - 2, tl(Ordered)),
    Closes =
        case Last of
            {_, <<"BATCH">>, [<<"-", Ref/binary>>], _, _} -> true;
            _ -> false
        end,
    Tagged = lists:all(
        fun({_, _, _, _, Tags}) -> lists:member({<<"batch">>, Ref}, Tags) end, Inner
    ),
    case Closes andalso Tagged of
        true -> {true, Ordered};
        false -> false
    end;
single_batch(_) ->
    false.

labeled_batch(Pid, Server, Label, Messages) ->
    Ref = batch_ref(),
    relay(
        Pid,
        Server,
        <<"BATCH">>,
        [<<"+", Ref/binary>>, <<"labeled-response">>],
        none,
        [{<<"label">>, Label}]
    ),
    lists:foreach(fun(Message) -> send_batched(Pid, Ref, Message) end, lists:reverse(Messages)),
    relay(Pid, Server, <<"BATCH">>, [<<"-", Ref/binary>>], none, []).

-doc """
Open an ambient batch of `Type` with `Params`.

`BATCH +ref` is sent lazily to each recipient with the `batch` capability
when it receives its first line before `end_batch/0`; every such line is
tagged with the reference.
""".
-spec begin_batch(binary(), [binary()]) -> ok.
begin_batch(Type, Params) ->
    begin_batch(Type, Params, any).

-doc """
Like `begin_batch/2`, but only lines whose command is in `Commands` join
the batch (for example only `QUIT` in `netsplit`, only `JOIN` in `netjoin`).
`any` admits every command.
""".
-spec begin_batch(binary(), [binary()], any | [binary()]) -> ok.
begin_batch(Type, Params, Commands) ->
    put(ircd_batch_commands, Commands),
    begin_batch_any(Type, Params).

begin_batch_any(Type, Params) ->
    put(ircd_batch, #{type => Type, params => Params, ref => batch_ref(), opened => []}),
    ok.

-doc """
Close the ambient batch: send `BATCH -ref` to each recipient that saw it
open. A no-op when no batch is open.
""".
-spec end_batch() -> ok.
end_batch() ->
    erase(ircd_batch_commands),
    case erase(ircd_batch) of
        #{ref := Ref, opened := Opened} ->
            Server = local_server(),
            lists:foreach(
                fun(Pid) -> send(Pid, Server, <<"BATCH">>, [<<"-", Ref/binary>>], none, []) end,
                lists:reverse(Opened)
            );
        _ ->
            ok
    end.

-doc """
Run `Fun` with every line to `Pid` wrapped in one batch of `Type` with
`Params`, when `Pid` negotiated `batch`; otherwise just run `Fun`.

`Extra` tags go on the opening `BATCH` line. An empty batch is still sent.
Lines to other recipients are not batched. Returns the result of `Fun`.
""".
-spec with_batch(pid(), binary(), [binary()], list(), fun(() -> term())) -> term().
with_batch(Pid, Type, Params, Extra, Fun) ->
    case ircd_cap:enabled(Pid, <<"batch">>) of
        false ->
            Fun();
        true ->
            Server = local_server(),
            Ref = batch_ref(),
            Previous = get(ircd_batch),
            send(Pid, Server, <<"BATCH">>, [<<"+", Ref/binary>>, Type | Params], none, Extra),
            put(ircd_batch, #{ref => Ref, only => Pid, opened => [Pid]}),
            try
                Fun()
            after
                restore_batch(Previous),
                send(Pid, Server, <<"BATCH">>, [<<"-", Ref/binary>>], none, [])
            end
    end.

restore_batch(undefined) -> erase(ircd_batch);
restore_batch(Previous) -> put(ircd_batch, Previous).

-doc """
Remember the user whose command is being applied, for source tags.

`Info` has `prefix` (binary `nick!user@host`), `account`, `bot`, and `oper`.
Lines whose prefix equals `prefix` get the `account`, `bot`, and
`draft/oper` tags. Cleared with `clear_source/0`.
""".
-spec set_source(map()) -> ok.
set_source(Info) ->
    put(ircd_source, Info),
    ok.

-doc """
Run `Fun` with `Info` as the source, then restore the previous source.

Used where a user's own line (`QUIT`, `JOIN`, `CHGHOST`) is sent outside
that user's command, so account-tag and oper-tag still apply.
""".
-spec with_source(map(), fun(() -> term())) -> term().
with_source(Info, Fun) ->
    Previous = get(ircd_source),
    put(ircd_source, Info),
    try
        Fun()
    after
        case Previous of
            undefined -> erase(ircd_source);
            _ -> put(ircd_source, Previous)
        end
    end.

-doc """
Forget the source set by `set_source/1`.
""".
-spec clear_source() -> ok.
clear_source() ->
    erase(ircd_source),
    ok.

-doc """
Source tags (`account`, `bot`, `draft/oper`) for a line with `Prefix`, or
`[]` when `Prefix` is not the current source.
""".
-spec source_tags(iodata()) -> [{binary(), undefined | binary()}].
source_tags(Prefix) ->
    case get(ircd_source) of
        #{prefix := Source} = Info ->
            case iolist_to_binary(Prefix) =:= Source of
                true -> info_tags(Info);
                false -> []
            end;
        _ ->
            []
    end.

info_tags(Info) ->
    Account =
        case maps:get(account, Info, undefined) of
            undefined -> [];
            Name -> [{<<"account">>, Name}]
        end,
    Bot =
        case maps:get(bot, Info, false) of
            true -> [{<<"bot">>, undefined}];
            false -> []
        end,
    Oper =
        case maps:get(oper, Info, undefined) of
            undefined -> [];
            Nick -> [{<<"draft/oper">>, Nick}]
        end,
    Account ++ Bot ++ Oper.

add_source_tags(Prefix, Tags) ->
    case get(ircd_source) of
        undefined ->
            Tags;
        _ ->
            Extra = [
                Tag
             || {Key, _} = Tag <- source_tags(Prefix), not lists:keymember(Key, 1, Tags)
            ],
            Extra ++ Tags
    end.

-doc """
A new `msgid` tag value: microsecond time and a node-local monotonic
counter in base 36, then `-` and a hash of the server name, so two servers
on one network do not collide.
""".
-spec msgid() -> binary().
msgid() ->
    Server = erlang:phash2(local_server(), 1 bsl 32),
    iolist_to_binary([
        integer_to_binary(erlang:system_time(microsecond), 36),
        integer_to_binary(erlang:unique_integer([positive, monotonic]), 36),
        <<"-">>,
        integer_to_binary(Server, 36)
    ]).

-doc """
`time` tag for the current wall clock with millisecond precision
([server-time](https://ircv3.net/specs/extensions/server-time)).
""".
-spec time_tag() -> {binary(), binary()}.
time_tag() ->
    {<<"time">>, time_value(erlang:system_time(millisecond))}.

-doc """
Format milliseconds since the Unix epoch as `YYYY-MM-DDThh:mm:ss.sssZ` (UTC).
""".
-spec time_value(integer()) -> binary().
time_value(Millis) ->
    list_to_binary(
        calendar:system_time_to_rfc3339(Millis, [{unit, millisecond}, {offset, "Z"}])
    ).

with_time(Tags) ->
    case lists:keymember(<<"time">>, 1, Tags) of
        true -> Tags;
        false -> [time_tag() | Tags]
    end.

batch_command(Command) ->
    case get(ircd_batch_commands) of
        Commands when is_list(Commands) ->
            case get(ircd_batch) of
                #{only := _} -> true;
                #{} -> lists:member(Command, Commands);
                _ -> true
            end;
        _ ->
            true
    end.

ambient_batch(Pid, Tags) ->
    case get(ircd_batch) of
        #{only := Only} when Only =/= Pid ->
            Tags;
        #{ref := Ref, opened := Opened} = Batch ->
            case lists:keymember(<<"batch">>, 1, Tags) of
                true ->
                    Tags;
                false ->
                    case lists:member(Pid, Opened) of
                        true ->
                            [{<<"batch">>, Ref} | Tags];
                        false ->
                            case ircd_cap:enabled(Pid, <<"batch">>) of
                                true ->
                                    open_ambient(Pid, Batch),
                                    [{<<"batch">>, Ref} | Tags];
                                false ->
                                    Tags
                            end
                    end
            end;
        _ ->
            Tags
    end.

open_ambient(Pid, #{type := Type, params := Params, ref := Ref, opened := Opened} = Batch) ->
    put(ircd_batch, Batch#{opened => [Pid | Opened]}),
    Server = local_server(),
    case get(ircd_label) of
        {Pid, Label, _} when is_binary(Label) ->
            buffer_label(Server, <<"BATCH">>, [<<"+", Ref/binary>>, Type | Params], none, []);
        _ ->
            relay(Pid, Server, <<"BATCH">>, [<<"+", Ref/binary>>, Type | Params], none, [])
    end.

buffer_label(Prefix, Command, Middle, Tail, Tags) ->
    {Pid, Label, Acc} = get(ircd_label),
    put(ircd_label, {Pid, Label, [{Prefix, Command, Middle, Tail, Tags} | Acc]}),
    ok.

send_labeled(Pid, Label, {Prefix, Command, Middle, Tail, Tags}) ->
    relay(Pid, Prefix, Command, Middle, Tail, [{<<"label">>, Label} | Tags]).

%% Lines already inside a nested batch keep their own batch tag.
send_batched(Pid, Ref, {Prefix, Command, Middle, Tail, Tags}) ->
    case lists:keymember(<<"batch">>, 1, Tags) of
        true -> relay(Pid, Prefix, Command, Middle, Tail, Tags);
        false -> relay(Pid, Prefix, Command, Middle, Tail, [{<<"batch">>, Ref} | Tags])
    end.

relay(Pid, Prefix, Command, Middle, Tail, Tags) ->
    Enabled = ircd_cap:enabled_set(Pid),
    case Command =:= <<"TAGMSG">> andalso not maps:is_key(<<"message-tags">>, Enabled) of
        true -> ok;
        false -> deliver(Pid, Prefix, Command, Middle, Tail, visible(Enabled, Tags))
    end.

deliver(Pid, Prefix, Command, Middle, Tail, Tags) ->
    Line = ircd_wire:message(Tags, Prefix, Command, Middle, Tail),
    deliver_line(Pid, Line, iolist_size(Line)).

deliver_line(_Pid, [], _Size) ->
    ok;
deliver_line(Pid, Line, Size) ->
    Pid ! {irc, Line},
    ircd_state_client:update_connection_stats(Pid, sent_messages, sent_bytes, Size),
    ok.

%% Build each distinct tag variant once per fan-out and share the binary.
send_cached(Pid, Prefix, Command, Middle, Tail, Tags, Cache) ->
    Enabled = ircd_cap:enabled_set(Pid),
    case Command =:= <<"TAGMSG">> andalso not maps:is_key(<<"message-tags">>, Enabled) of
        true ->
            Cache;
        false ->
            Visible = visible(Enabled, Tags),
            case Cache of
                #{Visible := {Line, Size}} ->
                    deliver_line(Pid, Line, Size),
                    Cache;
                _ ->
                    Line = iolist_to_binary(
                        ircd_wire:message(Visible, Prefix, Command, Middle, Tail)
                    ),
                    Size = byte_size(Line),
                    deliver_line(Pid, Line, Size),
                    Cache#{Visible => {Line, Size}}
            end
    end.

%% Tags the recipient may see. A `server-time` recipient always gets `time`.
visible(Enabled, Tags) ->
    Kept = [Tag || {Key, _} = Tag <- Tags, tag_allowed(Key, Enabled)],
    case maps:is_key(<<"server-time">>, Enabled) andalso not lists:keymember(<<"time">>, 1, Kept) of
        true -> [time_tag() | Kept];
        false -> Kept
    end.

tag_allowed(<<"label">>, _) -> true;
tag_allowed(<<"batch">>, _) -> true;
tag_allowed(<<"time">>, Enabled) -> maps:is_key(<<"server-time">>, Enabled);
tag_allowed(<<"account">>, Enabled) -> maps:is_key(<<"account-tag">>, Enabled);
tag_allowed(<<"draft/oper">>, Enabled) -> maps:is_key(<<"draft/oper-tag">>, Enabled);
tag_allowed(_, Enabled) -> maps:is_key(<<"message-tags">>, Enabled).

label_pid() ->
    case get(ircd_label) of
        {Pid, Label, _Acc} when is_binary(Label) -> Pid;
        _ -> undefined
    end.

%% A copy of the sender's own PRIVMSG, NOTICE, or TAGMSG is not a labeled reply.
%% Those copies use a nick!user@host prefix. A server-prefixed NOTICE, including
%% the SQUIT and CONNECT results, is the command's reply and keeps the label.
%% echo-message copies go through echo/6, which does carry the label.
client_echo(Command, Prefix) ->
    message_command(Command) andalso has_user_prefix(Prefix).

message_command(<<"PRIVMSG">>) -> true;
message_command(<<"NOTICE">>) -> true;
message_command(<<"TAGMSG">>) -> true;
message_command(_) -> false.

has_user_prefix(Prefix) when is_binary(Prefix) ->
    binary:match(Prefix, <<"!">>) =/= nomatch;
has_user_prefix(Prefix) when is_list(Prefix) ->
    lists:any(fun has_user_prefix/1, Prefix);
has_user_prefix(_) ->
    false.

-doc """
A new batch reference (base 36 counter) unique within this state process.
""".
-spec batch_ref() -> binary().
batch_ref() ->
    Next =
        case get(ircd_batch_n) of
            undefined -> 1;
            Value -> Value
        end,
    put(ircd_batch_n, Next + 1),
    integer_to_binary(Next, 36).

local_server() ->
    maps:get(name, persistent_term:get({ircd_state, config}), <<"irc.local">>).
