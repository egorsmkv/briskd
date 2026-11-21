-module(ircd_flood).
-moduledoc """
Client flood and spam control: per-connection token buckets for incoming
lines, messages, channel joins, and nickname changes, plus a per-host
`REGISTER` rate limit.

Runs inside `m:ircd_state` and stores ephemeral state in the `ircd_flood` ETS
table. Local IRC operators (user mode `+o`) are exempt from per-connection
flood disconnection, and `QUIT` is always accepted so a client can close
cleanly. `PONG` is an ordinary line: this server does not use client `PONG`
for liveness. When a connection exceeds any bucket,
`check_command/5` returns `{flood, Category}` and `m:ircd_state` closes the
connection with `ERROR :Closing Link: <host> (Excess Flood)`.

Configuration key `flood` (`null` disables all limits; otherwise a map with
defaults):

- `lines_burst` (default 500) and `lines_per_second` (default 50): every
  client line costs one token.
- `messages_burst` (default 200) and `messages_per_second` (default 20):
  `PRIVMSG`, `NOTICE`, and `TAGMSG` outside a `draft/multiline` batch cost one
  token per target; opening a `draft/multiline` batch, `INVITE`, and `KNOCK`
  cost one token.
- `join_burst` (default 50) and `join_per_minute` (default 60): `JOIN`
  (other than `JOIN 0`) costs one token per channel name.
- `nick_burst` (default 50) and `nick_per_minute` (default 60): `NICK` after
  registration costs one token.
- `register_per_minute` (default 30): `REGISTER` attempts that reach account
  creation are rate-limited per client host (`allow_register/1`).
""".
-export([
    allow_register/1,
    check_command/5,
    consume_bucket/7,
    default_config/0,
    disconnect/1,
    expire/0,
    init/0
]).

-define(TABLE, ircd_flood).
-define(SECOND_MS, 1000).
-define(MINUTE_MS, 60000).

-doc "Flood category that was exceeded.".
-type category() :: lines | messages | join | nick.
-export_type([category/0]).

-doc """
Default `flood` configuration map used when the JSON file omits `flood`.
""".
-spec default_config() -> map().
default_config() ->
    #{
        lines_burst => 500,
        lines_per_second => 50,
        messages_burst => 200,
        messages_per_second => 20,
        join_burst => 50,
        join_per_minute => 60,
        nick_burst => 50,
        nick_per_minute => 60,
        register_per_minute => 30
    }.

-doc """
Create or clear the `ircd_flood` ETS table. Called by `m:ircd_state` at startup.
""".
-spec init() -> ok.
init() ->
    case ets:whereis(?TABLE) of
        undefined -> ?TABLE = ets:new(?TABLE, [named_table, public, set]);
        _ -> true = ets:delete_all_objects(?TABLE)
    end,
    ok.

-doc """
Drop the per-connection token buckets for session `Pid` on disconnect.
""".
-spec disconnect(pid()) -> ok.
disconnect(Pid) when is_pid(Pid) ->
    case ets:whereis(?TABLE) of
        undefined -> ok;
        _ -> ets:delete(?TABLE, {conn, Pid})
    end,
    ok.

-doc """
Delete per-host `REGISTER` rate-limit entries that have been idle for at least
60 seconds. Called from `m:ircd_state`'s one-second tick.
""".
-spec expire() -> ok.
expire() ->
    case ets:whereis(?TABLE) of
        undefined ->
            ok;
        _ ->
            Cutoff = erlang:monotonic_time(millisecond) - ?MINUTE_MS,
            _ = ets:select_delete(?TABLE, [
                {{{register, '_'}, '_', '$1'}, [{'=<', '$1', Cutoff}], [true]}
            ]),
            ok
    end.

-doc """
Check and charge the token buckets for one client command.

`Pid` is the client session, `Command` the uppercase IRC command, `Params` its
parameters, `Tags` its message tags, and `IsReady` whether the client has
completed registration. Returns `allow` or `{flood, Category}`.
""".
-spec check_command(pid(), binary(), [binary()], list(), boolean()) ->
    allow | {flood, category()}.
%% QUIT disconnects after one command, so it is not a flood vehicle.
%% PONG is an ordinary line: the server does not use client PONGs for
%% liveness, and an unlimited PONG would occupy ircd_state indefinitely.
check_command(_Pid, <<"QUIT">>, _Params, _Tags, _IsReady) ->
    allow;
check_command(Pid, Command, Params, Tags, IsReady) ->
    case config() of
        null ->
            allow;
        Config ->
            case maps:is_key($o, ircd_state_client:user_modes(Pid)) of
                true ->
                    allow;
                false ->
                    Now = erlang:monotonic_time(millisecond),
                    Buckets0 = load_buckets(Pid, Config, Now),
                    Checks = command_checks(Command, Params, Tags, IsReady, Config),
                    case apply_checks(Checks, Buckets0, Now) of
                        {allow, Buckets1} ->
                            ets:insert(?TABLE, {{conn, Pid}, Buckets1}),
                            allow;
                        {flood, _} = Flood ->
                            Flood
                    end
            end
    end.

-doc """
Check and charge the per-host `REGISTER` rate limit for `Host`.

Returns `true` when the registration attempt may proceed and `false` when
`register_per_minute` is exceeded.
""".
-spec allow_register(binary()) -> boolean().
allow_register(Host) when is_binary(Host) ->
    case config() of
        null ->
            true;
        #{register_per_minute := Limit} ->
            Now = erlang:monotonic_time(millisecond),
            Key = {register, Host},
            {Units, Last} =
                case ets:lookup(?TABLE, Key) of
                    [{Key, U, L}] -> {U, L};
                    [] -> {Limit * ?MINUTE_MS, Now}
                end,
            case consume_bucket(Units, Last, Now, Limit, Limit, ?MINUTE_MS, 1) of
                {allow, NextUnits, NextLast} ->
                    ets:insert(?TABLE, {Key, NextUnits, NextLast}),
                    true;
                deny ->
                    false
            end
    end.

-doc """
Pure token-bucket step using integer units of `1 / WindowMs` token.

`Units` is the current balance (up to `Burst * WindowMs`), `LastMs` the
previous timestamp in milliseconds, `NowMs` the current timestamp in
milliseconds, `Burst` the bucket capacity in tokens, `Refill` the tokens
restored per `WindowMs`, and `Cost` the tokens to spend. Returns
`{allow, RemainingUnits, NowMs}` or `deny`.
""".
-spec consume_bucket(
    non_neg_integer(),
    integer(),
    integer(),
    pos_integer(),
    pos_integer(),
    pos_integer(),
    pos_integer()
) ->
    {allow, non_neg_integer(), integer()} | deny.
consume_bucket(Units, LastMs, NowMs, Burst, Refill, WindowMs, Cost) ->
    Cap = Burst * WindowMs,
    Elapsed = max(0, NowMs - LastMs),
    Available = min(Cap, Units + Elapsed * Refill),
    Needed = Cost * WindowMs,
    case Available >= Needed of
        true -> {allow, Available - Needed, NowMs};
        false -> deny
    end.

config() ->
    maps:get(flood, ircd_config:current_or_empty(), default_config()).

load_buckets(Pid, Config, Now) ->
    case ets:lookup(?TABLE, {conn, Pid}) of
        [{{conn, Pid}, Buckets}] ->
            Buckets;
        [] ->
            #{
                lines_burst := LB,
                messages_burst := MB,
                join_burst := JB,
                nick_burst := NB
            } = Config,
            #{
                lines => {LB * ?SECOND_MS, Now},
                messages => {MB * ?SECOND_MS, Now},
                join => {JB * ?MINUTE_MS, Now},
                nick => {NB * ?MINUTE_MS, Now}
            }
    end.

command_checks(Command, Params, Tags, IsReady, Config) ->
    #{
        lines_burst := LB,
        lines_per_second := LR
    } = Config,
    LineCheck = {lines, LB, LR, ?SECOND_MS, 1},
    Extra = extra_check(Command, Params, Tags, IsReady, Config),
    [LineCheck | Extra].

extra_check(Command, [Targets | _], Tags, _IsReady, #{
    messages_burst := MB, messages_per_second := MR
}) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>; Command =:= <<"TAGMSG">>
->
    case lists:keymember(<<"batch">>, 1, Tags) of
        true ->
            [];
        false ->
            Count = max(1, length(binary:split(Targets, <<",">>, [global, trim_all]))),
            [{messages, MB, MR, ?SECOND_MS, Count}]
    end;
extra_check(<<"BATCH">>, [<<"+", _/binary>>, <<"draft/multiline">> | _], _Tags, _IsReady, #{
    messages_burst := MB, messages_per_second := MR
}) ->
    [{messages, MB, MR, ?SECOND_MS, 1}];
extra_check(Command, _Params, _Tags, _IsReady, #{
    messages_burst := MB, messages_per_second := MR
}) when
    Command =:= <<"INVITE">>; Command =:= <<"KNOCK">>
->
    [{messages, MB, MR, ?SECOND_MS, 1}];
extra_check(<<"JOIN">>, [<<"0">> | _], _Tags, _IsReady, _Config) ->
    [];
extra_check(<<"JOIN">>, [Names | _], _Tags, _IsReady, #{
    join_burst := JB, join_per_minute := JR
}) ->
    Count = max(1, length(binary:split(Names, <<",">>, [global, trim_all]))),
    [{join, JB, JR, ?MINUTE_MS, Count}];
extra_check(<<"NICK">>, [_ | _], _Tags, true, #{
    nick_burst := NB, nick_per_minute := NR
}) ->
    [{nick, NB, NR, ?MINUTE_MS, 1}];
extra_check(_Command, _Params, _Tags, _IsReady, _Config) ->
    [].

apply_checks([], Buckets, _Now) ->
    {allow, Buckets};
apply_checks([{Category, Burst, Refill, WindowMs, Cost} | Rest], Buckets, Now) ->
    {Units, Last} = maps:get(Category, Buckets),
    case consume_bucket(Units, Last, Now, Burst, Refill, WindowMs, Cost) of
        {allow, NextUnits, NextLast} ->
            apply_checks(Rest, Buckets#{Category => {NextUnits, NextLast}}, Now);
        deny ->
            {flood, Category}
    end.
