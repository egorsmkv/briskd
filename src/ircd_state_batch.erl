-module(ircd_state_batch).
-export([batch/4, deliver_multiline/7, in_batch/2, label/1]).
-include("ircd_state.hrl").

%% @doc Client-initiated batches (IRCv3 client-batch) of type draft/multiline.
%% One open batch per connection is kept in `ircd_conn` under `batch`. Lines
%% are bounded by the advertised `max-bytes` and `max-lines`; exceeding either
%% drops the batch with `FAIL BATCH MULTILINE_MAX_BYTES` or `MULTILINE_MAX_LINES`.

%% @doc Label carried by the opening BATCH line of the open batch, if any.
-spec label(pid()) -> undefined | binary().
label(Pid) ->
    case ircd_conn:get(Pid, batch) of
        #{label := Label} -> Label;
        _ -> undefined
    end.

%% @doc `BATCH +<ref> draft/multiline <target>` and `BATCH -<ref>`.
-spec batch([binary()], [{binary(), undefined | binary()}], #client{}, binary()) -> ok.
batch([<<"+", Ref/binary>>, Type | Rest], Tags, #client{pid = Pid}, _Server) ->
    case {valid_ref(Ref), ircd_conn:get(Pid, batch), Type, Rest} of
        {false, _, _, _} ->
            fail(Pid, <<"INVALID_REFTAG">>, [Ref], <<"Invalid batch reference">>);
        {true, Open, _, _} when Open =/= undefined ->
            ircd_conn:remove(Pid, batch),
            fail(Pid, <<"MULTILINE_INVALID">>, [], <<"Nested batches are not allowed">>);
        {true, undefined, <<"draft/multiline">>, [Target | _]} ->
            case ircd_cap:enabled(Pid, <<"draft/multiline">>) of
                true ->
                    ircd_conn:put(Pid, batch, #{
                        ref => ircd_wire:retain(Ref),
                        target => ircd_wire:retain(Target),
                        command => undefined,
                        lines => [],
                        bytes => 0,
                        count => 0,
                        tags => [
                            {ircd_wire:retain(K), ircd_wire:retain(V)}
                         || {K, V} <- ircd_cap:client_tags(Tags)
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
    case ircd_conn:get(Pid, batch) of
        #{ref := Ref} = Open ->
            ircd_conn:remove(Pid, batch),
            finish(Open, Client, Server);
        _ ->
            fail(Pid, <<"INVALID_REFTAG">>, [Ref], <<"Unknown batch reference">>)
    end;
batch(_Params, _Tags, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"BATCH">>], <<"Not enough parameters">>).

%% @doc Add a PRIVMSG or NOTICE carrying `batch=<ref>` to the open batch.
%% Returns `false` when the line is not part of an open batch.
-spec in_batch({binary(), [binary()], list()}, #client{}) -> boolean().
in_batch({Command, Params, Tags}, #client{pid = Pid}) ->
    case {lists:keyfind(<<"batch">>, 1, Tags), ircd_conn:get(Pid, batch)} of
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
    {MaxBytes, MaxLines} = ircd_cap:multiline_limits(),
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
    SameTarget = ircd_wire:fold(Target) =:= ircd_wire:fold(BatchTarget),
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
            ircd_conn:put(Pid, batch, Open#{
                command => Command,
                lines => [{Concat, ircd_wire:retain(Text)} | Lines],
                bytes => NewBytes,
                count => Count + 1
            })
    end;
add_line(_Command, _Params, _Tags, _Open, Pid) ->
    drop(Pid, <<"MULTILINE_INVALID">>, [], <<"Invalid line in multiline batch">>).

drop(Pid, Code, Context, Text) ->
    ircd_conn:remove(Pid, batch),
    fail(Pid, Code, Context, Text).

finish(#{command := undefined}, #client{pid = Pid}, _Server) ->
    fail(Pid, <<"MULTILINE_INVALID">>, [], <<"Empty multiline batch">>);
finish(#{command := Command, target := Target, lines := Reversed, tags := Tags}, Client, Server) ->
    Lines = lists:reverse(Reversed),
    case lists:all(fun({_, Text}) -> Text =:= <<>> end, Lines) of
        true ->
            fail(Client#client.pid, <<"MULTILINE_INVALID">>, [], <<"Blank multiline message">>);
        false ->
            ircd_state_channel:deliver_body(
                Command, Target, {multiline, Lines}, Client, Server, Tags
            )
    end.

%% @doc Deliver a multiline message to one recipient. Capable clients get a
%% draft/multiline batch with tags on the opening line; others get each
%% non-blank line as its own message, with message tags on the first only.
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
            echo -> fun ircd_state_send:echo/6;
            _ -> fun ircd_state_send:send/6
        end,
    case ircd_cap:enabled(Pid, <<"draft/multiline">>) andalso ircd_cap:enabled(Pid, <<"batch">>) of
        true ->
            Ref = ircd_state_send:batch_ref(),
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
            lists:foldl(
                fun(Text, First) ->
                    LineTags =
                        case First of
                            true -> Tags;
                            false -> [T || {K, _} = T <- Tags, K =:= <<"time">>]
                        end,
                    Send(Pid, Prefix, Command, [Target], Text, LineTags),
                    false
                end,
                true,
                NonBlank
            ),
            ok
    end.

valid_ref(Ref) ->
    byte_size(Ref) > 0 andalso byte_size(Ref) =< 64 andalso
        re:run(Ref, <<"^[A-Za-z0-9._-]+$">>, [{capture, none}, dollar_endonly]) =:= match.

label_tag(Tags) ->
    case lists:keyfind(<<"label">>, 1, Tags) of
        {_, Value} when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 64 -> Value;
        _ -> undefined
    end.

fail(Pid, Code, Context, Text) ->
    ircd_state_send:fail(Pid, <<"BATCH">>, Code, Context, Text).
