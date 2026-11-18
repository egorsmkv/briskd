-module(ircd_state_send).
-export([
    begin_label/2,
    broadcast/5,
    broadcast/6,
    end_label/1,
    numeric/5,
    prefix/1,
    send/5,
    send/6
]).
-include("ircd_state.hrl").

%% @doc Format IRC replies and deliver them to client sockets.
%% A labeled command buffers replies to the commanding client, then end_label/1
%% emits one tagged line, one labeled-response batch, or one ACK.

prefix(#client{nick = Nick, user = User, host = Host}) -> [Nick, <<"!">>, User, <<"@">>, Host].

numeric(#client{pid = Pid, nick = Nick}, Server, Number, Params, Text) ->
    send(Pid, Server, Number, [Nick | Params], Text).

broadcast(Pids, Prefix, Command, Middle, Tail) ->
    broadcast(Pids, Prefix, Command, Middle, Tail, []).

broadcast([], _Prefix, _Command, _Middle, _Tail, _Tags) ->
    ok;
broadcast(Pids, Prefix, Command, Middle, Tail, Tags) ->
    Lines = prepared_lines(Prefix, Command, Middle, Tail, Tags),
    LabelPid = label_pid(),
    lists:foreach(
        fun
            (Pid) when Pid =:= LabelPid ->
                send(Pid, Prefix, Command, Middle, Tail, Tags);
            (Pid) ->
                send_prepared(Pid, Command, Lines)
        end,
        Pids
    ).

send(Pid, Prefix, Command, Middle, Tail) ->
    send(Pid, Prefix, Command, Middle, Tail, []).

%% @doc Start collecting replies to Pid when Label is a binary label value.
-spec begin_label(pid(), undefined | binary()) -> ok.
begin_label(Pid, Label) when is_binary(Label) ->
    put(ircd_label, {Pid, Label, []}),
    ok;
begin_label(_Pid, _) ->
    put(ircd_label, off),
    ok.

%% @doc Send the collected labeled reply, if a label was active.
-spec end_label(binary()) -> ok.
end_label(Server) ->
    case erase(ircd_label) of
        {Pid, Label, []} ->
            relay(Pid, Server, <<"ACK">>, [], none, [{<<"label">>, Label}]);
        {Pid, Label, [Message]} ->
            send_labeled(Pid, Label, Message);
        {Pid, Label, Messages} ->
            Ref = batch_ref(),
            relay(
                Pid,
                Server,
                <<"BATCH">>,
                [<<"+", Ref/binary>>, <<"labeled-response">>],
                none,
                [{<<"label">>, Label}]
            ),
            lists:foreach(
                fun(Message) -> send_batched(Pid, Ref, Message) end, lists:reverse(Messages)
            ),
            relay(Pid, Server, <<"BATCH">>, [<<"-", Ref/binary>>], none, []);
        _ ->
            ok
    end.

send(Pid, Prefix, Command, Middle, Tail, Tags) ->
    case get(ircd_label) of
        {Pid, Label, _Acc} when is_binary(Label) ->
            case client_echo(Command, Prefix) of
                true -> relay(Pid, Prefix, Command, Middle, Tail, Tags);
                false -> buffer_label(Prefix, Command, Middle, Tail, Tags)
            end;
        _ ->
            relay(Pid, Prefix, Command, Middle, Tail, Tags)
    end.

buffer_label(Prefix, Command, Middle, Tail, Tags) ->
    {Pid, Label, Acc} = get(ircd_label),
    put(ircd_label, {Pid, Label, [{Prefix, Command, Middle, Tail, Tags} | Acc]}),
    ok.

send_labeled(Pid, Label, {Prefix, Command, Middle, Tail, Tags}) ->
    relay(Pid, Prefix, Command, Middle, Tail, [{<<"label">>, Label} | Tags]).

send_batched(Pid, Ref, {Prefix, Command, Middle, Tail, Tags}) ->
    relay(Pid, Prefix, Command, Middle, Tail, [{<<"batch">>, Ref} | Tags]).

relay(Pid, Prefix, <<"TAGMSG">> = Command, Middle, Tail, Tags) ->
    case ircd_cap:enabled(Pid, <<"message-tags">>) of
        true -> deliver(Pid, Prefix, Command, Middle, Tail, Tags);
        false -> ok
    end;
relay(Pid, Prefix, Command, Middle, Tail, Tags) ->
    Visible =
        case ircd_cap:enabled(Pid, <<"message-tags">>) of
            true -> Tags;
            false -> []
        end,
    deliver(Pid, Prefix, Command, Middle, Tail, Visible).

deliver(Pid, Prefix, Command, Middle, Tail, Tags) ->
    Line = ircd_wire:message(Tags, Prefix, Command, Middle, Tail),
    deliver_line(Pid, Line, iolist_size(Line)).

deliver_line(Pid, Line, Size) ->
    Pid ! {irc, Line},
    ircd_state_client:update_connection_stats(Pid, sent_messages, sent_bytes, Size),
    ok.

%% One tagged line and one plain line, shared by every recipient of this fan-out.
prepared_lines(Prefix, Command, Middle, Tail, Tags) ->
    Tagged = iolist_to_binary(ircd_wire:message(Tags, Prefix, Command, Middle, Tail)),
    case Tags of
        [] ->
            {Tagged, byte_size(Tagged), Tagged, byte_size(Tagged)};
        _ ->
            Plain = iolist_to_binary(ircd_wire:message([], Prefix, Command, Middle, Tail)),
            {Tagged, byte_size(Tagged), Plain, byte_size(Plain)}
    end.

send_prepared(Pid, <<"TAGMSG">>, {Tagged, TaggedSize, _Plain, _PlainSize}) ->
    case ircd_cap:enabled(Pid, <<"message-tags">>) of
        true -> deliver_line(Pid, Tagged, TaggedSize);
        false -> ok
    end;
send_prepared(Pid, _Command, {Tagged, TaggedSize, Plain, PlainSize}) ->
    case ircd_cap:enabled(Pid, <<"message-tags">>) of
        true -> deliver_line(Pid, Tagged, TaggedSize);
        false -> deliver_line(Pid, Plain, PlainSize)
    end.

label_pid() ->
    case get(ircd_label) of
        {Pid, Label, _Acc} when is_binary(Label) -> Pid;
        _ -> undefined
    end.

%% A copy of the sender's own PRIVMSG, NOTICE, or TAGMSG is not a labeled reply.
%% Those copies use a nick!user@host prefix. A server-prefixed NOTICE, including
%% the SQUIT and CONNECT results, is the command's reply and keeps the label.
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

batch_ref() ->
    Next =
        case get(ircd_batch_n) of
            undefined -> 1;
            Value -> Value
        end,
    put(ircd_batch_n, Next + 1),
    integer_to_binary(Next, 36).
