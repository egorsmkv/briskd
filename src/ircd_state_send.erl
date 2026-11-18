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

broadcast(Pids, Prefix, Command, Middle, Tail, Tags) ->
    lists:foreach(fun(Pid) -> send(Pid, Prefix, Command, Middle, Tail, Tags) end, Pids).

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
            lists:foreach(fun(Message) -> send_batched(Pid, Ref, Message) end, Messages),
            relay(Pid, Server, <<"BATCH">>, [<<"-", Ref/binary>>], none, []);
        _ ->
            ok
    end.

send(Pid, Prefix, Command, Middle, Tail, Tags) ->
    case get(ircd_label) of
        {Pid, Label, _Acc} when is_binary(Label) ->
            case own_message(Command) of
                true -> relay(Pid, Prefix, Command, Middle, Tail, Tags);
                false -> buffer_label(Prefix, Command, Middle, Tail, Tags)
            end;
        _ ->
            relay(Pid, Prefix, Command, Middle, Tail, Tags)
    end.

buffer_label(Prefix, Command, Middle, Tail, Tags) ->
    {Pid, Label, Acc} = get(ircd_label),
    put(ircd_label, {Pid, Label, Acc ++ [{Prefix, Command, Middle, Tail, Tags}]}),
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
    Pid ! {irc, Line},
    ircd_state_client:update_connection_stats(Pid, sent_messages, sent_bytes, iolist_size(Line)),
    ok.

own_message(<<"PRIVMSG">>) -> true;
own_message(<<"NOTICE">>) -> true;
own_message(<<"TAGMSG">>) -> true;
own_message(_) -> false.

batch_ref() ->
    Next =
        case get(ircd_batch_n) of
            undefined -> 1;
            Value -> Value
        end,
    put(ircd_batch_n, Next + 1),
    integer_to_binary(Next, 36).
