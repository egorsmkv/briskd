-module(ircd_route).
-moduledoc """
Pure routing and limit decisions for RFC 2813 server links.

This module has no process and reads no tables. Callers in `m:ircd_state_net`,
`m:ircd_state_link`, and `m:ircd_state_channel` pass in the facts (known
servers, hold deadlines, membership counts) and act on the answer, which keeps
the rules unit-testable.

Server maps use the keys `name`, `hop`, `token`, `adjacent` (the directly
connected peer the server is reached through), `parent`, and `info`. Hop
counts follow RFC 2813 section 4.1.2: a directly connected peer is one hop
away, and each introduced server is one hop beyond its parent. Every name
comparison uses the RFC 1459 case mapping of `ircd_wire:fold/1`.
""".
-export([
    accept_server/4,
    burst_order/1,
    channel_allowed/2,
    max_channels/0,
    nick_collision/2,
    nick_delay_blocked/3,
    resource_delay_seconds/0,
    servers_behind/2,
    should_forward/2
]).

-define(MAX_CHANNELS, 10).
%% RFC 2811 / RFC 2813 abuse window after a nick or channel is lost in a split.
-define(RESOURCE_DELAY_SECONDS, 60).

-doc """
Maximum number of channels one client may join (10).

`JOIN` refuses another channel with numeric 405 (`ERR_TOOMANYCHANNELS`) at
this ceiling, and `m:ircd_isupport` advertises the same value in
`RPL_ISUPPORT`.
""".
-spec max_channels() -> pos_integer().
max_channels() -> ?MAX_CHANNELS.

-doc """
Default hold time, in seconds, for a nickname or channel name lost in a
netsplit or nickname collision (60).

`m:ircd_state_net` uses it when the `resource_delay` configuration key is
absent. This is the nickname and channel delay mechanism of RFC 2811 and
RFC 2813 section 5.7.
""".
-spec resource_delay_seconds() -> pos_integer().
resource_delay_seconds() -> ?RESOURCE_DELAY_SECONDS.

-doc """
True when a client that is in `Joined` channels may join one more under the
ceiling `Max`.

The comparison is strict: a client already in `Max` channels is refused.
""".
-spec channel_allowed(non_neg_integer(), pos_integer()) -> boolean().
channel_allowed(Joined, Max) when is_integer(Joined), Joined >= 0, is_integer(Max), Max > 0 ->
    Joined < Max.

-doc """
True when `Key` is still held at time `Now`.

`Holds` maps a key to its deadline, in the same clock and unit as `Now`
(`m:ircd_state_net` uses monotonic seconds). A key without an entry is not
held, and a deadline equal to `Now` has already expired.
""".
-spec nick_delay_blocked(term(), integer(), #{term() => integer()}) -> boolean().
nick_delay_blocked(Key, Now, Holds) when is_integer(Now), is_map(Holds) ->
    maps:get(Key, Holds, 0) > Now.

-doc """
Decide what a nickname collision removes.

Returns `ok` when neither copy exists and `kill_both` otherwise: RFC 2813
removes every copy of a colliding nickname rather than choosing a winner. The
caller kills only the copies that actually exist; `m:ircd_state_link` calls
this once both copies are known.
""".
-spec nick_collision(boolean(), boolean()) -> ok | kill_both.
nick_collision(false, false) ->
    ok;
nick_collision(LocalExists, RemoteExists) when
    is_boolean(LocalExists), is_boolean(RemoteExists)
->
    kill_both.

-doc """
True when a routed message that arrived on link `Ingress` may be sent to the
adjacent link `Adjacent`.

This is the no-echo rule: a message is never sent back to the link that
delivered it. Both names are compared after `ircd_wire:fold/1`.
""".
-spec should_forward(binary(), binary()) -> boolean().
should_forward(Ingress, Adjacent) when is_binary(Ingress), is_binary(Adjacent) ->
    ircd_wire:fold(Ingress) =/= ircd_wire:fold(Adjacent).

-doc """
Sort server maps nearest-first for a burst.

Servers are ordered by hop count, then by folded name, so every parent's
`SERVER` line precedes its children's (RFC 2813 section 5.3.2) and the
output is deterministic.
""".
-spec burst_order([map()]) -> [map()].
burst_order(Servers) when is_list(Servers) ->
    lists:sort(
        fun(Left, Right) ->
            {maps:get(hop, Left), ircd_wire:fold(maps:get(name, Left))} =<
                {maps:get(hop, Right), ircd_wire:fold(maps:get(name, Right))}
        end,
        Servers
    ).

-doc """
Names of `Lost` and of every server in `Servers` whose parent chain reaches
`Lost`.

`SQUIT` and link loss use this to find every server that becomes
unreachable. Only names present in `Servers` are returned, so `Lost` is
included only when it is itself a known server. A cycle in the parent chain
stops the walk instead of looping.
""".
-spec servers_behind(binary(), [map()]) -> [binary()].
servers_behind(Lost, Servers) when is_binary(Lost), is_list(Servers) ->
    [
        maps:get(name, Server)
     || Server <- Servers,
        reaches(maps:get(name, Server), Lost, Servers, #{})
    ].

-doc """
Validate one `SERVER` introduction (RFC 2813 section 4.1.2) received on the
adjacent link `Ingress`.

`Local` is this server's name and `Servers` the currently known servers.
`Intro` holds `name`, `hop` (integer), `token` (binary), `info`, and
optionally `parent`, which defaults to `Ingress`. On success the result is
`{ok, ServerMap}` ready to store, with `adjacent` set to the link the new
server is reached through. Errors:

- `invalid_server`: the name is not 1 to 63 characters of letters, digits,
  `.`, and `-` starting with a letter or digit, or `hop`/`token` has the wrong
  type.
- `loop`: the name is the local server, or the named parent is known but is
  not reached through `Ingress`.
- `duplicate_route`: a server with this name is already known.
- `bad_hop`: the parent is the local server, or the hop count is not one more
  than the parent's (2 for a server directly behind `Ingress`).
- `unknown_parent`: the parent server is not known.
""".
-spec accept_server(binary(), binary(), map(), [map()]) -> {ok, map()} | {error, atom()}.
accept_server(Local, Ingress, Intro, Servers) when
    is_binary(Local), is_binary(Ingress), is_map(Intro), is_list(Servers)
->
    Name = maps:get(name, Intro),
    Hop = maps:get(hop, Intro),
    Token = maps:get(token, Intro),
    ParentName = maps:get(parent, Intro, Ingress),
    Info = maps:get(info, Intro, <<>>),
    case valid_server_name(Name) andalso is_integer(Hop) andalso is_binary(Token) of
        false ->
            {error, invalid_server};
        true ->
            case ircd_wire:fold(Name) =:= ircd_wire:fold(Local) of
                true ->
                    {error, loop};
                false ->
                    case lookup(Name, Servers) of
                        {ok, _} ->
                            {error, duplicate_route};
                        error ->
                            place_server(
                                Local, Ingress, ParentName, Hop, Name, Token, Info, Servers
                            )
                    end
            end
    end.

place_server(Local, Ingress, ParentName, Hop, Name, Token, Info, Servers) ->
    case ircd_wire:fold(ParentName) =:= ircd_wire:fold(Local) of
        true ->
            {error, bad_hop};
        false ->
            case ircd_wire:fold(ParentName) =:= ircd_wire:fold(Ingress) of
                true when Hop =:= 2 ->
                    {ok, server_map(Name, 2, Token, Ingress, Ingress, Info)};
                true ->
                    {error, bad_hop};
                false ->
                    place_behind(Ingress, ParentName, Hop, Name, Token, Info, Servers)
            end
    end.

place_behind(Ingress, ParentName, Hop, Name, Token, Info, Servers) ->
    case lookup(ParentName, Servers) of
        error ->
            {error, unknown_parent};
        {ok, Parent} ->
            Adjacent = maps:get(adjacent, Parent),
            ViaIngress =
                ircd_wire:fold(Adjacent) =:= ircd_wire:fold(Ingress) orelse
                    ircd_wire:fold(maps:get(name, Parent)) =:= ircd_wire:fold(Ingress),
            case ViaIngress andalso Hop =:= maps:get(hop, Parent) + 1 of
                true ->
                    {ok, server_map(Name, Hop, Token, Adjacent, maps:get(name, Parent), Info)};
                false when ViaIngress ->
                    {error, bad_hop};
                false ->
                    {error, loop}
            end
    end.

reaches(Name, Lost, Servers, Seen) when is_binary(Name), is_binary(Lost) ->
    Fold = ircd_wire:fold(Name),
    case maps:is_key(Fold, Seen) of
        true ->
            false;
        false ->
            ircd_wire:fold(Name) =:= ircd_wire:fold(Lost) orelse
                case lookup(Name, Servers) of
                    {ok, #{parent := Parent}} when is_binary(Parent) ->
                        reaches(Parent, Lost, Servers, Seen#{Fold => true});
                    _ ->
                        false
                end
    end.

lookup(Name, Servers) ->
    Fold = ircd_wire:fold(Name),
    case [Server || Server <- Servers, ircd_wire:fold(maps:get(name, Server)) =:= Fold] of
        [Server | _] -> {ok, Server};
        [] -> error
    end.

server_map(Name, Hop, Token, Adjacent, Parent, Info) ->
    #{
        name => Name,
        hop => Hop,
        token => Token,
        adjacent => Adjacent,
        parent => Parent,
        info => Info
    }.

valid_server_name(Name) when is_binary(Name) ->
    case re:run(Name, <<"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$">>, [{capture, none}, dollar_endonly]) of
        match -> true;
        nomatch -> false
    end;
valid_server_name(_) ->
    false.
