-module(ircd_shutdown).
-export([drain/1]).

%% @doc Graceful shutdown, run from ircd_app:prep_stop/1 before the supervision
%% tree stops. That covers `init:stop/0` from SIGTERM (OTP's default SIGTERM
%% handler), operator DIE and RESTART, and `application:stop(ircd)`.
%%
%% 1. Stop every listener, so no new connection is accepted.
%% 2. Tell directly linked servers with `SQUIT <this server>` (RFC 2813 4.1.6).
%% 3. Send each session a NOTICE and then `ERROR :Closing Link` (RFC 2812
%%    3.7.4); the session flushes both and closes its socket.
%% 4. Wait for the sessions to finish, at most `shutdown_grace` seconds
%%    (configuration, default 5). Whatever remains is stopped by the supervisor.
%%
%% Mnesia is stopped after the application, so durable rows (WHOWAS, safe
%% channels, accounts, read markers, and retained channels) stay consistent.

-define(POLL_MS, 100).

-spec drain(binary()) -> ok.
drain(Reason) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    Server = maps:get(name, Config, <<"irc.local">>),
    Grace = maps:get(shutdown_grace, Config, 5),
    Sessions = sessions(),
    logger:notice(#{event => shutdown_started, sessions => length(Sessions), grace_s => Grace}),
    stop_listeners(),
    notify_links(Server, Reason),
    Notice = iolist_to_binary(ircd_wire:line(Server, <<"NOTICE">>, [<<"*">>], Reason)),
    Error = iolist_to_binary(
        ircd_wire:line(Server, <<"ERROR">>, [], [
            <<"Closing Link: ">>, Server, <<" (">>, Reason, <<")">>
        ])
    ),
    lists:foreach(
        fun(Pid) ->
            Pid ! {irc, Notice},
            Pid ! {irc_close, Error}
        end,
        Sessions
    ),
    Left = wait(erlang:monotonic_time(millisecond) + Grace * 1000),
    logger:notice(#{event => shutdown_drained, remaining_sessions => Left}),
    ok.

sessions() ->
    try supervisor:which_children(ircd_sessions) of
        Children -> [Pid || {_, Pid, _, _} <- Children, is_pid(Pid)]
    catch
        exit:_ -> []
    end.

stop_listeners() ->
    lists:foreach(
        fun(Kind) ->
            case supervisor:terminate_child(ircd_sup, Kind) of
                ok -> logger:info(#{event => listener_stopped, transport => Kind});
                {error, not_found} -> ok
            end
        end,
        [tcp, tls, ws, wss]
    ).

%% Every direct peer, outbound worker or inbound session, gets the SQUIT.
notify_links(Server, Reason) ->
    Squit = iolist_to_binary(ircd_wire:line(Server, <<"SQUIT">>, [Server], Reason)),
    try ircd_links:send_except(undefined, Squit) of
        _ -> ok
    catch
        exit:_ -> ok
    end.

wait(Deadline) ->
    case length(sessions()) of
        0 ->
            0;
        Left ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    Left;
                false ->
                    timer:sleep(?POLL_MS),
                    wait(Deadline)
            end
    end.
