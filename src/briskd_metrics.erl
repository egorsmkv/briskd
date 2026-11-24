-module(briskd_metrics).
-moduledoc """
Low-overhead per-command telemetry backed by an OTP `counters` array.

Each supported IRC command is assigned a fixed integer index `1..66` via
`command_index/1`, with bucket `67` reserved for unsupported commands. Each
bucket uses two slots in the `counters` reference stored in `persistent_term`
under `{briskd_metrics, counters}`: invocation count and cumulative wire bytes.

Using a bounded `counters` array with `[write_concurrency]` avoids ETS row
contention and dynamic key growth on the hot command path while directly
serving `STATS m` (RFC 2812 section 3.4.4, `212 RPL_STATSCOMMANDS`).
""".

-export([
    init/0,
    command_index/1,
    supported_command/1,
    count_command/3,
    command_stats/0
]).

-define(COUNTERS_KEY, {?MODULE, counters}).
-define(SUPPORTED_COUNT, 66).
-define(UNSUPPORTED_INDEX, 67).
-define(TOTAL_SLOTS, 134).

-doc """
Ensure the `counters` array exists in `persistent_term` and reset all slots
to zero for a clean server start.
""".
-spec init() -> ok.
init() ->
    Ref =
        case persistent_term:get(?COUNTERS_KEY, undefined) of
            undefined ->
                NewRef = counters:new(?TOTAL_SLOTS, [write_concurrency]),
                persistent_term:put(?COUNTERS_KEY, NewRef),
                NewRef;
            Existing ->
                Existing
        end,
    lists:foreach(fun(Slot) -> counters:put(Ref, Slot, 0) end, lists:seq(1, ?TOTAL_SLOTS)),
    ok.

-doc """
Map a supported uppercase IRC command name to its fixed counter bucket
(`1..66`), or `undefined` for unsupported commands.
""".
-spec command_index(binary()) -> 1..66 | undefined.
command_index(<<"ADMIN">>) -> 1;
command_index(<<"AUTHENTICATE">>) -> 2;
command_index(<<"AWAY">>) -> 3;
command_index(<<"BATCH">>) -> 4;
command_index(<<"CALL">>) -> 5;
command_index(<<"CAP">>) -> 6;
command_index(<<"CHATHISTORY">>) -> 7;
command_index(<<"CHGHOST">>) -> 8;
command_index(<<"CONNECT">>) -> 9;
command_index(<<"DIE">>) -> 10;
command_index(<<"E2EE">>) -> 11;
command_index(<<"INFO">>) -> 12;
command_index(<<"INVITE">>) -> 13;
command_index(<<"ISON">>) -> 14;
command_index(<<"ISUPPORT">>) -> 15;
command_index(<<"JOIN">>) -> 16;
command_index(<<"KICK">>) -> 17;
command_index(<<"KILL">>) -> 18;
command_index(<<"KNOCK">>) -> 19;
command_index(<<"LINKS">>) -> 20;
command_index(<<"LIST">>) -> 21;
command_index(<<"LUSERS">>) -> 22;
command_index(<<"MARKREAD">>) -> 23;
command_index(<<"METADATA">>) -> 24;
command_index(<<"MODE">>) -> 25;
command_index(<<"MONITOR">>) -> 26;
command_index(<<"MOTD">>) -> 27;
command_index(<<"NAMES">>) -> 28;
command_index(<<"NICK">>) -> 29;
command_index(<<"NOTICE">>) -> 30;
command_index(<<"OPER">>) -> 31;
command_index(<<"PART">>) -> 32;
command_index(<<"PASS">>) -> 33;
command_index(<<"PING">>) -> 34;
command_index(<<"PONG">>) -> 35;
command_index(<<"PRIVMSG">>) -> 36;
command_index(<<"QUIT">>) -> 37;
command_index(<<"RECLAIM">>) -> 38;
command_index(<<"REDACT">>) -> 39;
command_index(<<"REGISTER">>) -> 40;
command_index(<<"REHASH">>) -> 41;
command_index(<<"RENAME">>) -> 42;
command_index(<<"RESTART">>) -> 43;
command_index(<<"SEARCH">>) -> 44;
command_index(<<"SERVICE">>) -> 45;
command_index(<<"SERVLIST">>) -> 46;
command_index(<<"SETNAME">>) -> 47;
command_index(<<"SQUERY">>) -> 48;
command_index(<<"SQUIT">>) -> 49;
command_index(<<"STARTTLS">>) -> 50;
command_index(<<"STATS">>) -> 51;
command_index(<<"SUMMON">>) -> 52;
command_index(<<"TAGMSG">>) -> 53;
command_index(<<"TIME">>) -> 54;
command_index(<<"TOPIC">>) -> 55;
command_index(<<"TRACE">>) -> 56;
command_index(<<"USER">>) -> 57;
command_index(<<"USERHOST">>) -> 58;
command_index(<<"USERS">>) -> 59;
command_index(<<"VERIFY">>) -> 60;
command_index(<<"VERSION">>) -> 61;
command_index(<<"WALLOPS">>) -> 62;
command_index(<<"WEBIRC">>) -> 63;
command_index(<<"WHO">>) -> 64;
command_index(<<"WHOIS">>) -> 65;
command_index(<<"WHOWAS">>) -> 66;
command_index(_) -> undefined.

-doc "True when `Command` is a supported IRC command tracked by `STATS m`.".
-spec supported_command(binary()) -> boolean().
supported_command(Command) ->
    command_index(Command) =/= undefined.

-doc """
Record one received command of `MessageBytes` octets from session `Pid`.

Increments the global command counters and the session's per-connection
receive counters (`STATS l`).
""".
-spec count_command(pid(), binary(), non_neg_integer()) -> ok.
count_command(Pid, Command, MessageBytes) ->
    case persistent_term:get(?COUNTERS_KEY, undefined) of
        undefined ->
            ok;
        Ref ->
            Ix =
                case command_index(Command) of
                    undefined -> ?UNSUPPORTED_INDEX;
                    Found -> Found
                end,
            Base = (Ix - 1) * 2,
            counters:add(Ref, Base + 1, 1),
            counters:add(Ref, Base + 2, MessageBytes)
    end,
    briskd_state_client:update_connection_stats(Pid, recv_messages, recv_bytes, MessageBytes).

-doc """
Return sorted `{Command, Count, Bytes}` entries for every supported command
with at least one invocation since startup (`STATS m`).
""".
-spec command_stats() -> [{binary(), pos_integer(), non_neg_integer()}].
command_stats() ->
    case persistent_term:get(?COUNTERS_KEY, undefined) of
        undefined ->
            [];
        Ref ->
            collect_stats(1, Ref, [])
    end.

collect_stats(Ix, _Ref, Acc) when Ix > ?SUPPORTED_COUNT ->
    lists:reverse(Acc);
collect_stats(Ix, Ref, Acc) ->
    Base = (Ix - 1) * 2,
    Count = counters:get(Ref, Base + 1),
    NextAcc =
        case Count > 0 of
            true ->
                Bytes = counters:get(Ref, Base + 2),
                [{index_command(Ix), Count, Bytes} | Acc];
            false ->
                Acc
        end,
    collect_stats(Ix + 1, Ref, NextAcc).

index_command(1) -> <<"ADMIN">>;
index_command(2) -> <<"AUTHENTICATE">>;
index_command(3) -> <<"AWAY">>;
index_command(4) -> <<"BATCH">>;
index_command(5) -> <<"CALL">>;
index_command(6) -> <<"CAP">>;
index_command(7) -> <<"CHATHISTORY">>;
index_command(8) -> <<"CHGHOST">>;
index_command(9) -> <<"CONNECT">>;
index_command(10) -> <<"DIE">>;
index_command(11) -> <<"E2EE">>;
index_command(12) -> <<"INFO">>;
index_command(13) -> <<"INVITE">>;
index_command(14) -> <<"ISON">>;
index_command(15) -> <<"ISUPPORT">>;
index_command(16) -> <<"JOIN">>;
index_command(17) -> <<"KICK">>;
index_command(18) -> <<"KILL">>;
index_command(19) -> <<"KNOCK">>;
index_command(20) -> <<"LINKS">>;
index_command(21) -> <<"LIST">>;
index_command(22) -> <<"LUSERS">>;
index_command(23) -> <<"MARKREAD">>;
index_command(24) -> <<"METADATA">>;
index_command(25) -> <<"MODE">>;
index_command(26) -> <<"MONITOR">>;
index_command(27) -> <<"MOTD">>;
index_command(28) -> <<"NAMES">>;
index_command(29) -> <<"NICK">>;
index_command(30) -> <<"NOTICE">>;
index_command(31) -> <<"OPER">>;
index_command(32) -> <<"PART">>;
index_command(33) -> <<"PASS">>;
index_command(34) -> <<"PING">>;
index_command(35) -> <<"PONG">>;
index_command(36) -> <<"PRIVMSG">>;
index_command(37) -> <<"QUIT">>;
index_command(38) -> <<"RECLAIM">>;
index_command(39) -> <<"REDACT">>;
index_command(40) -> <<"REGISTER">>;
index_command(41) -> <<"REHASH">>;
index_command(42) -> <<"RENAME">>;
index_command(43) -> <<"RESTART">>;
index_command(44) -> <<"SEARCH">>;
index_command(45) -> <<"SERVICE">>;
index_command(46) -> <<"SERVLIST">>;
index_command(47) -> <<"SETNAME">>;
index_command(48) -> <<"SQUERY">>;
index_command(49) -> <<"SQUIT">>;
index_command(50) -> <<"STARTTLS">>;
index_command(51) -> <<"STATS">>;
index_command(52) -> <<"SUMMON">>;
index_command(53) -> <<"TAGMSG">>;
index_command(54) -> <<"TIME">>;
index_command(55) -> <<"TOPIC">>;
index_command(56) -> <<"TRACE">>;
index_command(57) -> <<"USER">>;
index_command(58) -> <<"USERHOST">>;
index_command(59) -> <<"USERS">>;
index_command(60) -> <<"VERIFY">>;
index_command(61) -> <<"VERSION">>;
index_command(62) -> <<"WALLOPS">>;
index_command(63) -> <<"WEBIRC">>;
index_command(64) -> <<"WHO">>;
index_command(65) -> <<"WHOIS">>;
index_command(66) -> <<"WHOWAS">>.
