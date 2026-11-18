-module(ircd_state_send).
-export([
    broadcast/5,
    numeric/5,
    prefix/1,
    send/5
]).
-include("ircd_state.hrl").

%% @doc Format IRC replies and deliver them to client sockets.

prefix(#client{nick = Nick, user = User, host = Host}) -> [Nick, <<"!">>, User, <<"@">>, Host].

numeric(#client{pid = Pid, nick = Nick}, Server, Number, Params, Text) ->
    send(Pid, Server, Number, [Nick | Params], Text).
broadcast(Pids, Prefix, Command, Middle, Tail) ->
    lists:foreach(fun(Pid) -> send(Pid, Prefix, Command, Middle, Tail) end, Pids).
send(Pid, Prefix, Command, Middle, Tail) ->
    Line = ircd_wire:line(Prefix, Command, Middle, Tail),
    Pid ! {irc, Line},
    ircd_state_client:update_connection_stats(Pid, sent_messages, sent_bytes, iolist_size(Line)),
    ok.
