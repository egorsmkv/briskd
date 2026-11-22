-module(briskd_dronebl).
-moduledoc """
DroneBL DNS-based blacklist (DNSBL) lookup and connection banning.

When enabled in configuration (`"dronebl": true` or `"dronebl": { ... }`),
every accepted client connection is checked against DroneBL
(`dnsbl.dronebl.org` by default, RFC 5782):

1. **Fast path (`check_sync/1`):** O(1) ETS lookup against the local ban and
   negative-result cache. A previously listed IP is rejected immediately with
   `ERROR :Closing Link` without spawning a DNS query.
2. **Async lookup (`check_async/2`):** On a cache miss, a bounded pool of
   short-lived worker processes queries `inet_res:lookup/5` for the reversed
   IPv4 octets or IPv6 nibbles under the configured DNSBL zone. Concurrent
   connections from the same IP coalesce onto a single in-flight lookup.
3. **Ban after lookup:** If the DNSBL returns an `A` record in `127.0.0.X`
   matching an enabled DroneBL listing type (`X >= 2`), the IP is stored in the
   ETS ban table for `ban_ttl` seconds (default 3600) and every waiting session
   receives `{dronebl_banned, Reason}` so it closes immediately with
   `ERROR :Closing Link`. Negative (`NXDOMAIN` / empty) results are cached for
   `cache_ttl` seconds (default 300). DNS timeouts and errors fail open so
   legitimate users are not locked out during upstream DNS outages.

Private, loopback, and link-local addresses are skipped by default
(`skip_private: true`), and authenticated RFC 2813 server links are never
disconnected by a DroneBL result.

Configuration is read dynamically with `briskd_config:current_or_empty/0`,
so enabling, disabling, or tuning `dronebl` takes effect immediately on
`REHASH` or `briskdctl rehash`.
""".
-behaviour(gen_server).

-export([
    start_link/1,
    is_enabled/0,
    check_sync/1,
    check_async/2,
    ban/3,
    unban/1,
    list_bans/0,
    stats/0,
    set_resolver/1,
    query_name/2,
    parse_peer/1,
    is_private/1,
    type_name/1,
    classify_answers/2,
    ban_reason/3,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    format_status/1,
    terminate/2
]).

-define(TABLE, briskd_dronebl_cache).
-define(SWEEP_INTERVAL_MS, 60000).

-doc """
DNS resolver used for a DroneBL lookup: the query name and the timeout in
milliseconds passed to `inet_res:lookup/5`. Tests inject a stub through
`set_resolver/1`.
""".
-type resolver() :: fun((string(), pos_integer()) -> {ok, [inet:ip_address()]} | {error, term()}).
-export_type([resolver/0]).

-doc """
Start the DroneBL lookup and ban cache manager, registered as `briskd_dronebl`.
""".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, [
        {hibernate_after, 15000},
        {spawn_opt, [{fullsweep_after, 20}]}
    ]).

-doc """
Return `true` when DroneBL checking is enabled in the active configuration.
""".
-spec is_enabled() -> boolean().
is_enabled() ->
    maps:get(enabled, current_cfg(), false).

-doc """
Check `Peer` synchronously against the local DroneBL cache and ban table.

Returns:
- `clean` when DroneBL is disabled, `Peer` is not a valid IP address, `Peer` is
  a private/loopback address (with `skip_private: true`), or `Peer` has a
  non-expired clean cache entry;
- `{banned, Reason}` when `Peer` has an active ban entry;
- `lookup` on a cache miss, meaning the caller should invoke `check_async/2`.
""".
-spec check_sync(binary() | string() | inet:ip_address()) ->
    clean | {banned, binary()} | lookup.
check_sync(Peer) ->
    Cfg = current_cfg(),
    case maps:get(enabled, Cfg, false) of
        false ->
            clean;
        true ->
            case parse_peer(Peer) of
                error ->
                    clean;
                {ok, IP} ->
                    case maps:get(skip_private, Cfg, true) andalso is_private(IP) of
                        true ->
                            clean;
                        false ->
                            lookup_cache(IP)
                    end
            end
    end.

-doc """
Start an asynchronous DroneBL DNS lookup for `Peer` on behalf of `SessionPid`.

If the IP is listed, `briskd_dronebl` records a ban in the cache and sends
`{dronebl_banned, Reason}` to `SessionPid`. Safe to call even if `briskd_dronebl`
is not running (fails open).
""".
-spec check_async(binary() | string() | inet:ip_address(), pid()) -> ok.
check_async(Peer, SessionPid) when is_pid(SessionPid) ->
    case parse_peer(Peer) of
        {ok, IP} ->
            case whereis(?MODULE) of
                undefined -> ok;
                _ -> gen_server:cast(?MODULE, {lookup, IP, SessionPid})
            end;
        error ->
            ok
    end.

-doc """
Manually insert a temporary DroneBL ban for `Peer` using the configured `ban_ttl`.
""".
-spec ban(binary() | string() | inet:ip_address(), byte(), binary()) -> ok | {error, invalid_ip}.
ban(Peer, Code, Desc) when is_integer(Code), Code >= 1, Code =< 255, is_binary(Desc) ->
    case parse_peer(Peer) of
        {ok, IP} ->
            gen_server:call(?MODULE, {ban, IP, Code, Desc}, 5000);
        error ->
            {error, invalid_ip}
    end.

-doc """
Remove any cached ban or clean entry for `Peer`.
""".
-spec unban(binary() | string() | inet:ip_address()) -> ok.
unban(Peer) ->
    case parse_peer(Peer) of
        {ok, IP} ->
            case whereis(?MODULE) of
                undefined -> ok;
                _ -> gen_server:call(?MODULE, {unban, IP}, 5000)
            end;
        error ->
            ok
    end.

-doc """
Return a list of currently active (non-expired) DroneBL bans as maps.
""".
-spec list_bans() -> [map()].
list_bans() ->
    case ets:whereis(?TABLE) of
        undefined ->
            [];
        _ ->
            Now = erlang:monotonic_time(second),
            ets:foldl(
                fun
                    ({IP, banned, Exp, Code, Reason}, Acc) when Exp > Now ->
                        [
                            #{
                                ip => briskd_wire:ip_text(IP),
                                code => Code,
                                reason => Reason,
                                expires_in => Exp - Now
                            }
                            | Acc
                        ];
                    (_, Acc) ->
                        Acc
                end,
                [],
                ?TABLE
            )
    end.

-doc """
Return current DroneBL statistics (`enabled`, `bans`, `cached_clean`, `in_flight`).
""".
-spec stats() -> map().
stats() ->
    Cfg = current_cfg(),
    Enabled = maps:get(enabled, Cfg, false),
    case whereis(?MODULE) of
        undefined ->
            #{enabled => Enabled, bans => 0, cached_clean => 0, in_flight => 0};
        _ ->
            gen_server:call(?MODULE, stats, 5000)
    end.

-doc """
Override the DNS resolver function used for DroneBL lookups, or pass `default`
to restore `inet_res:lookup/5`. Intended for deterministic testing.
""".
-spec set_resolver(default | resolver()) -> ok.
set_resolver(Resolver) when Resolver =:= default; is_function(Resolver, 2) ->
    gen_server:call(?MODULE, {set_resolver, Resolver}, 5000).

-doc """
Build the RFC 5782 reversed-IP DNSBL query name for `IP` under `Zone`.
""".
-spec query_name(inet:ip_address(), binary() | string()) -> string().
query_name({A, B, C, D}, Zone) ->
    lists:flatten([
        integer_to_list(D),
        ".",
        integer_to_list(C),
        ".",
        integer_to_list(B),
        ".",
        integer_to_list(A),
        ".",
        to_list(Zone)
    ]);
query_name({_, _, _, _, _, _, _, _} = IP, Zone) ->
    Hex = binary_to_list(binary:encode_hex(<<<<W:16>> || W <- tuple_to_list(IP)>>, lowercase)),
    Reversed = lists:join($., lists:reverse(Hex)),
    lists:flatten([Reversed, ".", to_list(Zone)]).

-doc """
Parse a peer address (binary, string, or IP tuple) into an `inet:ip_address()`.

The `0`-prefixed IPv6 form emitted by `m:briskd_listener` (for example
`<<"0::1">>` -> `{0, 0, 0, 0, 0, 0, 0, 1}`) is ordinary IPv6 text that
`inet:parse_address/1` accepts.
""".
-spec parse_peer(binary() | string() | inet:ip_address()) -> {ok, inet:ip_address()} | error.
parse_peer(IP) when is_tuple(IP) ->
    case inet:is_ip_address(IP) of
        true -> {ok, IP};
        false -> error
    end;
parse_peer(Bin) when is_binary(Bin) ->
    parse_peer(binary_to_list(Bin));
parse_peer(Str) when is_list(Str) ->
    case inet:parse_address(Str) of
        {ok, IP} -> {ok, IP};
        {error, _} -> error
    end;
parse_peer(_) ->
    error.

-doc """
Return `true` when `IP` is a loopback, private (RFC 1918 / ULA), link-local,
CGNAT (RFC 6598), multicast, or unspecified address.

Unique-local IPv6 is `fc00::/7`, so both `fc00::/8` and `fd00::/8` match.
An IPv4-mapped address (`::ffff:0:0/96`) is judged as the IPv4 address it
carries.
""".
-spec is_private(inet:ip_address()) -> boolean().
is_private({0, 0, 0, 0, 0, 16#FFFF, Hi, Lo}) ->
    is_private({Hi bsr 8, Hi band 16#FF, Lo bsr 8, Lo band 16#FF});
is_private({_, _, _, _} = IP) ->
    briskd_ip:any(IP, private_ranges());
is_private({_, _, _, _, _, _, _, _} = IP) ->
    briskd_ip:any(IP, private_ranges()).

%% Addresses DroneBL skips. `224.0.0.0/3` is multicast and the former Class E
%% block, the same set as an address whose first octet is at least 224.
private_ranges() ->
    [
        {{0, 0, 0, 0}, 8},
        {{10, 0, 0, 0}, 8},
        {{100, 64, 0, 0}, 10},
        {{127, 0, 0, 0}, 8},
        {{169, 254, 0, 0}, 16},
        {{172, 16, 0, 0}, 12},
        {{192, 168, 0, 0}, 16},
        {{224, 0, 0, 0}, 3},
        {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
        {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
        {{16#FC00, 0, 0, 0, 0, 0, 0, 0}, 7},
        {{16#FE80, 0, 0, 0, 0, 0, 0, 0}, 10},
        {{16#FF00, 0, 0, 0, 0, 0, 0, 0}, 8}
    ].

-doc """
Return the human-readable DroneBL listing description for return code `Code`.
""".
-spec type_name(byte()) -> binary().
type_name(2) -> <<"Sample data">>;
type_name(3) -> <<"IRC Drone">>;
type_name(5) -> <<"Bottler">>;
type_name(6) -> <<"Unknown spambot or drone">>;
type_name(7) -> <<"DDOS Drone">>;
type_name(8) -> <<"SOCKS Proxy">>;
type_name(9) -> <<"HTTP Proxy">>;
type_name(10) -> <<"ProxyChain">>;
type_name(11) -> <<"Web Page Proxy">>;
type_name(12) -> <<"Open DNS Resolver">>;
type_name(13) -> <<"Brute force attackers">>;
type_name(14) -> <<"Open Wingate Proxy">>;
type_name(15) -> <<"Compromised router / gateway">>;
type_name(16) -> <<"Autorooting worms">>;
type_name(17) -> <<"Automatically determined botnet IP">>;
type_name(18) -> <<"DNS/MX type hostname detected on IRC">>;
type_name(19) -> <<"Abused VPN Service">>;
type_name(255) -> <<"Unknown">>;
type_name(Code) -> <<"DroneBL type ", (integer_to_binary(Code))/binary>>.

-doc """
Classify a list of DNSBL `A` record answers against configured DroneBL `Types`.

Only `127.0.0.Code` answers with `Code >= 2` are treated as DroneBL listings;
`127.0.0.1` and non-`127.0.0.*` addresses are ignored to prevent false bans
from hijacked DNS resolvers.
""".
%% Answers are untrusted DNS data; anything but 127.0.0.N (N >= 2) is skipped.
-spec classify_answers([term()], all | [byte()]) ->
    clean | {listed, byte(), binary()}.
classify_answers([], _Types) ->
    clean;
classify_answers([{127, 0, 0, Code} | Rest], Types) when is_integer(Code), Code >= 2 ->
    case Types =:= all orelse lists:member(Code, Types) of
        true -> {listed, Code, type_name(Code)};
        false -> classify_answers(Rest, Types)
    end;
classify_answers([_ | Rest], Types) ->
    classify_answers(Rest, Types).

-doc """
Format the `ERROR :Closing Link` reason sent to a DroneBL-banned client.
""".
-spec ban_reason(inet:ip_address(), byte(), binary()) -> binary().
ban_reason(IP, Code, Desc) ->
    IPBin = briskd_wire:ip_text(IP),
    <<
        "Banned: listed in DroneBL (",
        Desc/binary,
        ", type ",
        (integer_to_binary(Code))/binary,
        ") - https://dronebl.org/lookup?ip=",
        IPBin/binary
    >>.

%%% gen_server callbacks

-doc false.
init(_Config) ->
    Table = ets:new(?TABLE, [named_table, set, protected, {read_concurrency, true}]),
    Timer = erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep),
    {ok, #{
        table => Table,
        in_flight => #{},
        workers => #{},
        resolver => default,
        sweep_timer => Timer
    }}.

-doc false.
handle_call({ban, IP, Code, Desc}, _From, State) ->
    Cfg = current_cfg(),
    Reason = ban_reason(IP, Code, Desc),
    store_entry(
        maps:get(table, State),
        IP,
        {IP, banned, erlang:monotonic_time(second) + maps:get(ban_ttl, Cfg, 3600), Code, Reason},
        maps:get(max_entries, Cfg, 10000)
    ),
    logger:warning(#{
        event => dronebl_ban_added,
        ip => briskd_wire:ip_text(IP),
        code => Code,
        description => Desc
    }),
    {reply, ok, State};
handle_call({unban, IP}, _From, #{table := Table} = State) ->
    ets:delete(Table, IP),
    {reply, ok, State};
handle_call({set_resolver, Resolver}, _From, State) ->
    {reply, ok, State#{resolver := Resolver}};
handle_call(stats, _From, #{table := Table, in_flight := InFlight} = State) ->
    Now = erlang:monotonic_time(second),
    Bans = ets:select_count(Table, [{{'_', banned, '$1', '_', '_'}, [{'>', '$1', Now}], [true]}]),
    Clean = ets:select_count(Table, [{{'_', clean, '$1'}, [{'>', '$1', Now}], [true]}]),
    {reply,
        #{
            enabled => is_enabled(),
            bans => Bans,
            cached_clean => Clean,
            in_flight => maps:size(InFlight)
        },
        State};
handle_call(_, _From, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
handle_cast({lookup, IP, SessionPid}, #{in_flight := InFlight, workers := Workers} = State) ->
    Cfg = current_cfg(),
    case maps:get(enabled, Cfg, false) of
        false ->
            {noreply, State};
        true ->
            case lookup_cache(IP) of
                {banned, Reason} ->
                    SessionPid ! {dronebl_banned, Reason},
                    {noreply, State};
                clean ->
                    {noreply, State};
                lookup ->
                    case InFlight of
                        #{IP := Waiters} ->
                            {noreply, State#{in_flight := InFlight#{IP => [SessionPid | Waiters]}}};
                        #{} ->
                            MaxWorkers = maps:get(max_in_flight, Cfg, 64),
                            case maps:size(InFlight) >= MaxWorkers of
                                true ->
                                    logger:warning(#{
                                        event => dronebl_busy,
                                        in_flight => maps:size(InFlight)
                                    }),
                                    {noreply, State};
                                false ->
                                    Zone = maps:get(zone, Cfg, <<"dnsbl.dronebl.org">>),
                                    Timeout = maps:get(timeout_ms, Cfg, 3000),
                                    Types = maps:get(types, Cfg, all),
                                    Resolver = maps:get(resolver, State),
                                    Self = self(),
                                    {_Pid, Ref} = spawn_monitor(fun() ->
                                        Result = run_lookup(IP, Zone, Timeout, Types, Resolver),
                                        gen_server:cast(Self, {lookup_done, IP, Result})
                                    end),
                                    {noreply, State#{
                                        in_flight := InFlight#{IP => [SessionPid]},
                                        workers := Workers#{Ref => IP}
                                    }}
                            end
                    end
            end
    end;
handle_cast({lookup_done, IP, Result}, #{table := Table, in_flight := InFlight} = State) ->
    case maps:take(IP, InFlight) of
        {Waiters, Rest} ->
            handle_result(Table, IP, Waiters, Result),
            {noreply, State#{in_flight := Rest}};
        error ->
            {noreply, State}
    end;
handle_cast(_, State) ->
    {noreply, State}.

-doc false.
handle_info(
    {'DOWN', Ref, process, _Pid, _Reason}, #{workers := Workers, in_flight := InFlight} = State
) ->
    case maps:take(Ref, Workers) of
        {IP, RestWorkers} ->
            {noreply, State#{
                workers := RestWorkers,
                in_flight := maps:remove(IP, InFlight)
            }};
        error ->
            {noreply, State}
    end;
handle_info(sweep, #{table := Table} = State) ->
    sweep_expired(Table),
    Timer = erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep),
    {noreply, State#{sweep_timer := Timer}};
handle_info(_, State) ->
    {noreply, State}.

-doc false.
format_status(#{state := State} = Status) ->
    Status#{
        state => #{
            in_flight_count => maps:size(maps:get(in_flight, State, #{})),
            resolver =>
                case maps:get(resolver, State, default) of
                    default -> default;
                    _ -> custom
                end
        }
    };
format_status(Status) ->
    Status.

-doc false.
terminate(_, #{sweep_timer := Timer}) ->
    _ = erlang:cancel_timer(Timer),
    ok;
terminate(_, _) ->
    ok.

%%% Internals

current_cfg() ->
    Config = briskd_config:current_or_empty(),
    maps:get(dronebl, Config, #{enabled => false}).

lookup_cache(IP) ->
    case ets:whereis(?TABLE) of
        undefined ->
            lookup;
        _ ->
            Now = erlang:monotonic_time(second),
            case ets:lookup(?TABLE, IP) of
                [{IP, banned, Exp, _Code, Reason}] when Exp > Now ->
                    {banned, Reason};
                [{IP, clean, Exp}] when Exp > Now ->
                    clean;
                _ ->
                    lookup
            end
    end.

run_lookup(IP, Zone, Timeout, Types, Resolver) ->
    Query = query_name(IP, Zone),
    Reply =
        try
            case Resolver of
                default -> {ok, inet_res:lookup(Query, in, a, [], Timeout)};
                Fun -> Fun(Query, Timeout)
            end
        catch
            Class:Reason -> {error, {Class, Reason}}
        end,
    case Reply of
        {ok, Answers} when is_list(Answers) ->
            classify_answers(Answers, Types);
        {error, Err} ->
            {error, Err}
    end.

handle_result(Table, IP, Waiters, {listed, Code, Desc}) ->
    Cfg = current_cfg(),
    Reason = ban_reason(IP, Code, Desc),
    Exp = erlang:monotonic_time(second) + maps:get(ban_ttl, Cfg, 3600),
    store_entry(Table, IP, {IP, banned, Exp, Code, Reason}, maps:get(max_entries, Cfg, 10000)),
    logger:warning(#{
        event => dronebl_listed,
        ip => briskd_wire:ip_text(IP),
        code => Code,
        description => Desc,
        ban_ttl => maps:get(ban_ttl, Cfg, 3600)
    }),
    lists:foreach(
        fun(Pid) -> Pid ! {dronebl_banned, Reason} end,
        Waiters
    );
handle_result(Table, IP, _Waiters, clean) ->
    Cfg = current_cfg(),
    case maps:get(cache_ttl, Cfg, 300) of
        Ttl when Ttl > 0 ->
            Exp = erlang:monotonic_time(second) + Ttl,
            store_entry(Table, IP, {IP, clean, Exp}, maps:get(max_entries, Cfg, 10000));
        _ ->
            ok
    end;
handle_result(_Table, IP, _Waiters, {error, Reason}) ->
    logger:debug(#{
        event => dronebl_lookup_error,
        ip => briskd_wire:ip_text(IP),
        reason => Reason
    }),
    ok.

store_entry(Table, IP, Entry, MaxEntries) ->
    case ets:info(Table, size) >= MaxEntries andalso not ets:member(Table, IP) of
        true ->
            sweep_expired(Table),
            case ets:info(Table, size) >= MaxEntries of
                true ->
                    case ets:first(Table) of
                        '$end_of_table' -> ok;
                        Key -> ets:delete(Table, Key)
                    end;
                false ->
                    ok
            end;
        false ->
            ok
    end,
    ets:insert(Table, Entry),
    ok.

sweep_expired(Table) ->
    Now = erlang:monotonic_time(second),
    _ = ets:select_delete(Table, [
        {{'_', banned, '$1', '_', '_'}, [{'=<', '$1', Now}], [true]},
        {{'_', clean, '$1'}, [{'=<', '$1', Now}], [true]}
    ]),
    ok.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
