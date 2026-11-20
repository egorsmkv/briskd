-module(ircd_shutdown).
-moduledoc """
Graceful shutdown of clients and server links.

`drain/1` runs from `ircd_app:prep_stop/1` before the supervision tree stops.
That covers `init:stop/0` from SIGTERM (OTP's default SIGTERM handler),
operator `DIE` and `RESTART`, and `application:stop(ircd)`.

1. Stop every listener, so no new connection is accepted.
2. Tell directly linked servers with `SQUIT <this server>` (RFC 2813
   section 4.1.6).
3. Send each session a `NOTICE` and then `ERROR :Closing Link` (RFC 2812
   section 3.7.4); the session sends both and closes its socket.
4. Wait for the sessions to finish, at most `shutdown_grace` seconds
   (configuration, default 5). Whatever remains is stopped by the supervisor.

Mnesia is stopped after the application, so durable rows (WHOWAS, safe
channels, accounts, read markers, and retained channels) stay consistent.
""".
-export([drain/1]).

-define(POLL_MS, 100).

-doc """
Close listeners, links, and sessions, then wait for the sessions to end.

`Reason` is the human-readable text used in the `NOTICE`, the `SQUIT`, and the
`ERROR :Closing Link: <server> (<Reason>)` line. Waits at most
`shutdown_grace` seconds, polling every 100 ms, logs `shutdown_started` and
`shutdown_drained` (with the number of sessions still open), and always
returns `ok`. It is safe to call when the session or link supervisor is
already gone.
""".
-spec drain(binary()) -> ok.
drain(Reason) ->
    Config = ircd_config:current_or_empty(),
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
    flush_state_and_mnesia(),
    logger:notice(#{event => shutdown_drained, remaining_sessions => Left}),
    ok.

%% Ensure `ircd_state` has processed all session `'DOWN'` messages (writing
%% WHOWAS and cleaning up channel memberships) and flush Mnesia's disk log
%% before the supervision tree terminates.
flush_state_and_mnesia() ->
    try sys:get_state(ircd_state, 5000) of
        _ -> ok
    catch
        _:_ -> ok
    end,
    try mnesia:dump_log() of
        _ -> ok
    catch
        _:_ -> ok
    end,
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
