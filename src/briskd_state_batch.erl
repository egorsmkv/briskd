-module(briskd_state_batch).
-export([batch/4, deliver_multiline/7, in_batch/2, label/1, link_lines/5]).
-include("briskd_state.hrl").

-moduledoc """
Client-initiated [batches](https://ircv3.net/specs/extensions/batch) of type
[draft/multiline](https://ircv3.net/specs/extensions/multiline), and the
delivery of multiline messages to clients and peers.

Runs inside `m:briskd_state`. One open batch per connection is kept in
`m:briskd_conn` under `batch`; nested batches are refused. Lines are bounded
by the advertised `max-bytes` (combined body) and `max-lines` from
`briskd_cap:multiline_limits/0`; exceeding either drops the batch with
`FAIL BATCH MULTILINE_MAX_BYTES` or `MULTILINE_MAX_LINES`. A completed batch
is delivered as one message through `briskd_state_channel:deliver_body/6`.
Replies to the batched lines are deferred until `BATCH -ref`, which uses the
`label` of the opening line (labeled-response).
""".

-doc """
Label carried by the opening `BATCH` line of the connection's open batch,
or `undefined`.
""".
-spec label(pid()) -> undefined | binary().
label(Pid) ->
    case briskd_conn:get(Pid, batch) of
        #{label := Label} -> Label;
        _ -> undefined
    end.

-doc """
`BATCH +<ref> draft/multiline <target>` and `BATCH -<ref>` from a client.

Opening a batch requires the `draft/multiline` capability and a reference
of 1 to 64 characters `[A-Za-z0-9._-]`; client-only tags and the label of the
opening line are kept for delivery. Closing delivers the collected message.
Errors are `FAIL BATCH` with `INVALID_REFTAG`, `UNKNOWN_TYPE`, or
`MULTILINE_INVALID` (nested, empty, or blank batch, missing target); missing
parameters get 461.
""".
-spec batch([binary()], [{binary(), undefined | binary()}], #client{}, binary()) -> ok.
batch([<<"+", Ref/binary>>, Type | Rest], Tags, #client{pid = Pid}, _Server) ->
    case {valid_ref(Ref), briskd_conn:get(Pid, batch), Type, Rest} of
        {false, _, _, _} ->
            fail(Pid, <<"INVALID_REFTAG">>, [Ref], <<"Invalid batch reference">>);
        {true, Open, _, _} when Open =/= undefined ->
            briskd_conn:remove(Pid, batch),
            fail(Pid, <<"MULTILINE_INVALID">>, [], <<"Nested batches are not allowed">>);
        {true, undefined, <<"draft/multiline">>, [Target | _]} ->
            case briskd_cap:enabled(Pid, <<"draft/multiline">>) of
                true ->
                    briskd_conn:put(Pid, batch, #{
                        ref => briskd_wire:retain(Ref),
                        target => briskd_wire:retain(Target),
                        command => undefined,
                        lines => [],
                        bytes => 0,
                        count => 0,
                        tags => [
                            {briskd_wire:retain(K), briskd_wire:retain(V)}
                         || {K, V} <- briskd_cap:client_tags(Tags)
                        ],
                        label => label_tag(Tags)
                    });
                false ->
                    fail(Pid, <<"UNKNOWN_TYPE">>, [Ref, Type], <<"Unsupported batch type">>)
            end;
        {true, undefined, <<"draft/multiline">>, []} ->
            fail(Pid, <<"MULTILINE_INVALID">>, [], <<"Missing batch target">>);
        {true, undefined, _, _} ->
            fail(Pid, <<"UNKNOWN_TYPE">>, [Ref, Type], <<"Unsupported batch type">>)
    end;
batch([<<"-", Ref/binary>> | _], _Tags, #client{pid = Pid} = Client, Server) ->
    case briskd_conn:get(Pid, batch) of
        #{ref := Ref} = Open ->
            briskd_conn:remove(Pid, batch),
            finish(Open, Client, Server);
        _ ->
            fail(Pid, <<"INVALID_REFTAG">>, [Ref], <<"Unknown batch reference">>)
    end;
batch(_Params, _Tags, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"BATCH">>], <<"Not enough parameters">>
    ).

-doc """
Add a `PRIVMSG` or `NOTICE` carrying `batch=<ref>` to the open batch.

Returns `false` when the line has no `batch` tag, so the caller delivers it
normally. Returns `true` when the line was consumed: added, or rejected with
a `FAIL BATCH` code (unknown reference, `MULTILINE_INVALID_TARGET`, mixed
commands, blank concatenated line, or a limit), which drops the batch.
""".
-spec in_batch({binary(), [binary()], list()}, #client{}) -> boolean().
in_batch({Command, Params, Tags}, #client{pid = Pid}) ->
    case {lists:keyfind(<<"batch">>, 1, Tags), briskd_conn:get(Pid, batch)} of
        {false, _} ->
            false;
        {{_, Ref}, #{ref := Ref} = Open} ->
            add_line(Command, Params, Tags, Open, Pid),
            true;
        {{_, Ref}, _} ->
            fail(Pid, <<"INVALID_REFTAG">>, [Ref], <<"Unknown batch reference">>),
            true
    end.

add_line(Command, [Target, Text | _], Tags, #{target := BatchTarget} = Open, Pid) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>
->
    {MaxBytes, MaxLines} = briskd_cap:multiline_limits(),
    Concat = lists:keymember(<<"draft/multiline-concat">>, 1, Tags),
    #{command := Previous, lines := Lines, bytes := Bytes, count := Count} = Open,
    Separator =
        case {Lines, Concat} of
            {[], _} -> 0;
            {_, true} -> 0;
            {_, false} -> 1
        end,
    NewBytes = Bytes + Separator + byte_size(Text),
    %% Targets are compared with the server's RFC 1459 casemapping.
    SameTarget = briskd_wire:fold(Target) =:= briskd_wire:fold(BatchTarget),
    if
        not SameTarget ->
            drop(
                Pid,
                <<"MULTILINE_INVALID_TARGET">>,
                [BatchTarget, Target],
                <<"Invalid multiline target">>
            );
        Previous =/= undefined, Previous =/= Command ->
            drop(Pid, <<"MULTILINE_INVALID">>, [], <<"Mixed message types in multiline batch">>);
        Concat, Text =:= <<>> ->
            drop(Pid, <<"MULTILINE_INVALID">>, [], <<"Blank concatenated line">>);
        Count + 1 > MaxLines ->
            drop(
                Pid, <<"MULTILINE_MAX_LINES">>, [integer_to_binary(MaxLines)], <<"Too many lines">>
            );
        NewBytes > MaxBytes ->
            drop(
                Pid, <<"MULTILINE_MAX_BYTES">>, [integer_to_binary(MaxBytes)], <<"Too many bytes">>
            );
        true ->
            briskd_conn:put(Pid, batch, Open#{
                command => Command,
                lines => [{Concat, briskd_wire:retain(Text)} | Lines],
                bytes => NewBytes,
                count => Count + 1
            })
    end;
add_line(_Command, _Params, _Tags, _Open, Pid) ->
    drop(Pid, <<"MULTILINE_INVALID">>, [], <<"Invalid line in multiline batch">>).

drop(Pid, Code, Context, Text) ->
    briskd_conn:remove(Pid, batch),
    fail(Pid, Code, Context, Text).

finish(#{command := undefined}, #client{pid = Pid}, _Server) ->
    fail(Pid, <<"MULTILINE_INVALID">>, [], <<"Empty multiline batch">>);
finish(#{command := Command, target := Target, lines := Reversed, tags := Tags}, Client, Server) ->
    Lines = lists:reverse(Reversed),
    case lists:all(fun({_, Text}) -> Text =:= <<>> end, Lines) of
        true ->
            fail(Client#client.pid, <<"MULTILINE_INVALID">>, [], <<"Blank multiline message">>);
        false ->
            briskd_state_channel:deliver_body(
                Command, Target, {multiline, Lines}, Client, Server, Tags
            )
    end.

-doc """
Deliver a multiline message to one recipient.

Clients with `draft/multiline` and `batch` get a draft/multiline batch with
`Tags` on the opening line and `draft/multiline-concat` where set. Others
get each non-blank line as its own message; only the first carries
`msgid`, later lines keep `time` and client-only tags. `Mode` `echo` sends
through `briskd_state_send:echo/6` (the labeled echo-message copy); `normal`
and `replay` use `briskd_state_send:send/6`.
""".
-spec deliver_multiline(
    pid(),
    iodata(),
    binary(),
    binary(),
    [{boolean(), binary()}],
    list(),
    normal | echo | replay
) -> ok.
deliver_multiline(Pid, Prefix, Command, Target, Lines, Tags, Mode) ->
    Send =
        case Mode of
            echo -> fun briskd_state_send:echo/6;
            _ -> fun briskd_state_send:send/6
        end,
    case
        briskd_cap:enabled(Pid, <<"draft/multiline">>) andalso briskd_cap:enabled(Pid, <<"batch">>)
    of
        true ->
            Ref = briskd_state_send:batch_ref(),
            Send(
                Pid,
                Prefix,
                <<"BATCH">>,
                [<<"+", Ref/binary>>, <<"draft/multiline">>, Target],
                none,
                Tags
            ),
            lists:foreach(
                fun({Concat, Text}) ->
                    LineTags =
                        case Concat of
                            true -> [{<<"batch">>, Ref}, {<<"draft/multiline-concat">>, undefined}];
                            false -> [{<<"batch">>, Ref}]
                        end,
                    Send(Pid, Prefix, Command, [Target], Text, LineTags)
                end,
                Lines
            ),
            Send(Pid, Prefix, <<"BATCH">>, [<<"-", Ref/binary>>], none, []);
        false ->
            NonBlank = [Text || {_, Text} <- Lines, Text =/= <<>>],
            lists:foreach(
                fun({Index, Text}) ->
                    LineTags =
                        case Index =:= 1 of
                            true ->
                                Tags;
                            %% Later lines keep `time` and client-only tags;
                            %% only the first carries `msgid`.
                            false ->
                                [
                                    T
                                 || {K, _} = T <- Tags,
                                    K =:= <<"time">> orelse binary:first(K) =:= $+
                                ]
                        end,
                    Send(Pid, Prefix, Command, [Target], Text, LineTags)
                end,
                lists:enumerate(NonBlank)
            )
    end.

-doc """
Server-link lines for a message body. A multiline message travels as
`BATCH +<ref> draft/multiline <target>` (carrying the message tags), its
lines tagged `batch=<ref>`, and `BATCH -<ref>`, so peers deliver it whole.
A plain binary body is one ordinary line with `Tags`.
""".
-spec link_lines(iodata(), binary(), binary(), briskd_state_channel:body(), [
    {binary(), undefined | binary()}
]) -> [iodata()].
link_lines(Prefix, Command, Target, {multiline, Lines}, Tags) ->
    Ref = briskd_state_send:batch_ref(),
    [
        briskd_wire:message(
            Tags, Prefix, <<"BATCH">>, [<<"+", Ref/binary>>, <<"draft/multiline">>, Target], none
        )
    ] ++
        [
            briskd_wire:message(
                case Concat of
                    true -> [{<<"batch">>, Ref}, {<<"draft/multiline-concat">>, undefined}];
                    false -> [{<<"batch">>, Ref}]
                end,
                Prefix,
                Command,
                [Target],
                Text
            )
         || {Concat, Text} <- Lines
        ] ++
        [briskd_wire:message([], Prefix, <<"BATCH">>, [<<"-", Ref/binary>>], none)];
link_lines(Prefix, Command, Target, Text, Tags) ->
    [briskd_wire:message(Tags, Prefix, Command, [Target], Text)].

valid_ref(Ref) ->
    byte_size(Ref) > 0 andalso byte_size(Ref) =< 64 andalso
        re:run(Ref, <<"^[A-Za-z0-9._-]+$">>, [{capture, none}, dollar_endonly]) =:= match.

label_tag(Tags) ->
    case lists:keyfind(<<"label">>, 1, Tags) of
        {_, Value} when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 64 -> Value;
        _ -> undefined
    end.

fail(Pid, Code, Context, Text) ->
    briskd_state_send:fail(Pid, <<"BATCH">>, Code, Context, Text).
