-module(briskd_state_net).
-moduledoc """
Server topology, services, nickname and channel holds, `CAP` replies, and
operator server commands.

The functions run only inside the `m:briskd_state` process, which is the single
writer of the `known_server` and `service` Mnesia rows and of the
`briskd_holds`, `briskd_inbound_peers`, and `briskd_outbound_ready` ETS tables. All
of that state is transient and is cleared on restart.

Topology follows RFC 2813: an adjacent peer is registered with hop 1 by
`register_adjacent/4`, servers behind it arrive as `SERVER` introductions
(`introduce_server/6`, placement checked by `briskd_route:accept_server/4`), and
`split/3` removes a lost server together with every server, user, and service
behind it. Names lost in a split or collision are held for the
`resource_delay` period (RFC 2813 section 5.7) so a local client cannot take
them over immediately.
""".
-export([
    configured_peer/1,
    expire_holds/0,
    cap/3,
    notify_cap_changes/2,
    channel_blocked/1,
    hold_channel/1,
    hold_nick/1,
    hold_nick/2,
    import_service/3,
    introduce_server/6,
    burst_server_lines/1,
    links_entries/0,
    nick_blocked/1,
    nick_blocked/2,
    reclaim/3,
    oper_command/4,
    register_adjacent/4,
    release_link/2,
    drop_server/3,
    servlist/4,
    service_count/0,
    remove_remote_user/1,
    split/3,
    squery/3,
    remote_squery/3
]).
-include("briskd_state.hrl").

-define(HOLDS, briskd_holds).
-define(INBOUND, briskd_inbound_peers).

-doc """
Record an authenticated, directly connected server peer.

Writes a `known_server` row for `Name` with hop 1, the local server as parent,
and the link's `Token`, then makes the link reachable by `m:briskd_links`:
`Kind` `inbound` stores `Pid` (the `m:briskd_session` serving the link) in
`briskd_inbound_peers`; `outbound` stores it (the `m:briskd_link` worker) in
`briskd_outbound_ready`.
""".
-spec register_adjacent(binary(), binary(), inbound | outbound, pid()) ->
    ok | {error, duplicate_peer}.
register_adjacent(Name, Token, Kind, Pid) ->
    Fold = briskd_wire:fold(Name),
    Owners = [
        Owner
     || {_, {Owner, _}} <-
            ets:lookup(?INBOUND, Fold) ++ ets:lookup(briskd_outbound_ready, Fold)
    ],
    case [Owner || Owner <- Owners, Owner =/= Pid] of
        [_ | _] ->
            {error, duplicate_peer};
        [] ->
            register_adjacent_new(Name, Token, Kind, Pid)
    end.

register_adjacent_new(Name, Token, Kind, Pid) ->
    Local = local_name(),
    Record = #known_server{
        key = briskd_wire:fold(Name),
        name = Name,
        hop = 1,
        token = Token,
        adjacent = Name,
        parent = Local,
        info = <<"Direct peer">>
    },
    mnesia:dirty_write(briskd_wire:retain_fields(Record)),
    case Kind of
        inbound -> ets:insert(?INBOUND, {briskd_wire:fold(Name), {Pid, Name}});
        outbound -> ets:insert(briskd_outbound_ready, {briskd_wire:fold(Name), {Pid, Name}})
    end,
    briskd_population:on_server_change(),
    ok.

-doc """
Import a `SERVER` introduction (RFC 2813 section 4.1.2) received on the
adjacent link `Ingress`.

`Prefix` names the new server's parent; `undefined` means the parent is
`Ingress`. `HopBin` must be a non-negative decimal and `Token` 1 to 16 digits,
otherwise the result is `{error, invalid_server}`. Placement is decided by
`briskd_route:accept_server/4`, whose errors (`loop`, `duplicate_route`,
`bad_hop`, `unknown_parent`, `invalid_server`) are returned unchanged. An
accepted server is stored as a `known_server` row and announced to every
other peer with its hop count increased by one.
""".
-spec introduce_server(binary(), binary(), binary(), binary(), binary(), binary()) ->
    ok | {error, atom()}.
introduce_server(Ingress, Prefix, Name, HopBin, Token, Info) ->
    case {briskd_route:valid_decimal(HopBin), valid_token(Token)} of
        {false, _} ->
            {error, invalid_server};
        {_, false} ->
            {error, invalid_server};
        {true, true} ->
            Parent =
                case Prefix of
                    undefined -> Ingress;
                    _ -> Prefix
                end,
            Intro = #{
                name => Name,
                hop => binary_to_integer(HopBin),
                token => Token,
                parent => Parent,
                info => Info
            },
            case briskd_route:accept_server(local_name(), Ingress, Intro, known_maps()) of
                {ok, Map} ->
                    case peer_server_room(Ingress, Name) of
                        false ->
                            {error, too_many_remote_servers};
                        true ->
                            store_server(Map),
                            announce_server(Map, Ingress),
                            ok
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-doc """
Remove a remote user after a nickname collision.

Local clients sharing a channel with the user see a `QUIT` with reason
`Nick collision`. The `remote_client` row, its channel memberships, its
MONITOR presence, and its metadata are dropped; a remote channel left empty
is deleted and its name is held when no local channel has it. The nickname
is held. Nothing is sent to peers; the caller announces the collision.
""".
-spec remove_remote_user(#remote_client{}) -> ok.
remove_remote_user(Remote) ->
    drop_remote_user(Remote, <<"Nick collision">>).

-doc """
Remove the server `Lost` and everything behind it after `SQUIT` or link loss
(RFC 2813 section 4.1.6).

Each remote user whose home server is lost is removed as in
`remove_remote_user/1`, with `Reason` as the `QUIT` text; all of those
`QUIT`s go to local clients in one IRCv3 `netsplit` batch whose parameters are
`Lost`'s parent (or this server) and `Lost`. Services homed on a lost server
are deleted. For every lost server the `known_server` row is deleted and
`SQUIT <name> :<Reason>` is sent to every peer except `Except`, the ingress
link (`undefined` for a split started on this server). When `Lost` is an
adjacent peer its peer table entries are removed so no further lines are
sent to it.
""".
-spec split(binary(), binary(), undefined | binary()) -> ok.
split(Lost, Reason, Except) ->
    Folds = [briskd_wire:fold(Name) || Name <- lost_names(Lost)],
    %% Every QUIT caused by this split goes in one `netsplit` batch.
    %% The two parameters are the servers on either side of the split.
    Uplink =
        case mnesia:dirty_read(known_server, briskd_wire:fold(Lost)) of
            [#known_server{parent = Parent}] when is_binary(Parent) -> Parent;
            _ -> local_name()
        end,
    briskd_state_send:begin_batch(<<"netsplit">>, [Uplink, Lost], [<<"QUIT">>]),
    try
        lists:foreach(
            fun(Key) ->
                case mnesia:dirty_read(remote_client, Key) of
                    [#remote_client{} = Remote] ->
                        case lost_client(Remote, Folds) of
                            true -> drop_remote_user(Remote, Reason);
                            false -> ok
                        end;
                    _ ->
                        ok
                end
            end,
            briskd_state:table_keys(remote_client)
        )
    after
        briskd_state_send:end_batch()
    end,
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(service, Key) of
                [#service{server = Server}] ->
                    case lists:member(briskd_wire:fold(Server), Folds) of
                        true ->
                            mnesia:dirty_delete(service, Key),
                            briskd_state_link:untrack_peer_item(service, Key);
                        false ->
                            ok
                    end;
                _ ->
                    ok
            end
        end,
        briskd_state:table_keys(service)
    ),
    lists:foreach(
        fun(Name) ->
            ServerKey = briskd_wire:fold(Name),
            mnesia:dirty_delete(known_server, ServerKey),
            briskd_state_link:untrack_peer_item(server, ServerKey),
            Line = briskd_wire:line(local_name(), <<"SQUIT">>, [Name], Reason),
            _ = briskd_links:send_except(Except, Line),
            case ServerKey =:= briskd_wire:fold(Lost) of
                true ->
                    ets:delete(?INBOUND, ServerKey),
                    ets:delete(briskd_outbound_ready, ServerKey);
                false ->
                    ok
            end
        end,
        [Name || Name <- lost_names(Lost)]
    ),
    briskd_population:on_server_change(),
    ok.

-doc """
Forget the direction rows of `Name` that `Pid` owns.

`split` when that was the last direction, so the caller removes the peer's
users. `kept` when another direction is still registered. `absent` when `Pid`
owns neither row: a session that lost the name, or one that already left,
must not split whoever holds it now.
""".
-spec release_link(binary(), pid()) -> split | kept | absent.
release_link(Name, Pid) ->
    Fold = briskd_wire:fold(Name),
    OwnIn = owns_direction(?INBOUND, Fold, Pid),
    OwnOut = owns_direction(briskd_outbound_ready, Fold, Pid),
    case OwnIn orelse OwnOut of
        false ->
            absent;
        true ->
            case OwnIn of
                true -> ets:delete(?INBOUND, Fold);
                false -> ok
            end,
            case OwnOut of
                true -> ets:delete(briskd_outbound_ready, Fold);
                false -> ok
            end,
            case
                ets:lookup(?INBOUND, Fold) =:= [] andalso
                    ets:lookup(briskd_outbound_ready, Fold) =:= []
            of
                true -> split;
                false -> kept
            end
    end.

owns_direction(Table, Fold, Pid) ->
    case ets:lookup(Table, Fold) of
        [{_, {Pid, _}}] -> true;
        _ -> false
    end.

%% Link processes registered for an adjacent peer. Captured before `split/3`,
%% which removes the rows.
adjacent_pids(Name) ->
    Fold = briskd_wire:fold(Name),
    [
        Pid
     || Table <- [?INBOUND, briskd_outbound_ready],
        {_, {Pid, _}} <- ets:lookup(Table, Fold),
        is_pid(Pid)
    ].

-doc """
Remove server `Name` and close a direct link when `Name` is adjacent.

The owner pids are taken before `split/3` deletes them. Those processes are
then stopped with reason `squit`, so the socket cannot keep sending as the
peer after the registration is gone. A name that is not a direct link has no
owner and only the split runs.
""".
-spec drop_server(binary(), binary(), undefined | binary()) -> ok.
drop_server(Name, Reason, Except) ->
    Pids = adjacent_pids(Name),
    case Pids of
        [] ->
            ok;
        _ ->
            briskd_state_link:flush_netjoin(Name),
            ok = briskd_state_link:forget_peer_batches(Name)
    end,
    split(Name, Reason, Except),
    lists:foreach(fun(Pid) -> exit(Pid, squit) end, Pids),
    ok.

-doc """
Hold a nickname lost in a split or collision so it cannot be taken at once
(RFC 2813 section 5.7).

The hold lasts `resource_delay` seconds from the configuration, defaulting
to `briskd_route:resource_delay_seconds/0`; a delay of 0 disables holds. The
deadline is stored in the `briskd_holds` ETS table under the folded name, in
monotonic seconds.
""".
-spec hold_nick(binary()) -> ok.
hold_nick(Nick) ->
    hold(nick, Nick).

-doc """
Hold the nickname a local client gave up (quit, lost connection, or nick
change), like `hold_nick/1`, but owned by that client: a later connection
that presents the same `RECLAIM` secret, or is logged in to the same
account, may take it back at once (`nick_blocked/2`). Everyone else waits
out the delay. This is what lets a WebIRC page reload keep its nickname.
""".
-spec hold_nick(binary(), #client{}) -> ok.
hold_nick(Nick, Client) ->
    hold(nick, Nick, hold_owner(Client)).

%% Who may take back a nickname held for a local client: the hash of its
%% RECLAIM secret, and its account, if logged in. Without either, the hold
%% has no owner.
hold_owner(#client{pid = Pid}) ->
    case {briskd_conn:get(Pid, reclaim), briskd_state_v3:account(Pid)} of
        {undefined, undefined} -> undefined;
        {Token, Account} -> #{token => Token, account => Account}
    end.

-doc """
Handle `RECLAIM <secret>`: remember the SHA-256 of a client-chosen secret
for this connection, so a nickname it later gives up can be taken back by a
connection presenting the same secret (`hold_nick/2`). A server extension
used by WebIRC, which keeps the secret for the browser tab; send it before
`NICK`. The secret is 16 to 64 characters of letters, digits, `-`, and `_`.
A missing secret gets 461; an invalid one `FAIL RECLAIM INVALID_SECRET`.
Success has no reply. The secret is never stored or logged.
""".
-spec reclaim([binary()], #client{}, binary()) -> ok.
reclaim([Secret | _], #client{pid = Pid}, _Server) ->
    case valid_secret(Secret) of
        true ->
            briskd_conn:put(Pid, reclaim, crypto:hash(sha256, Secret));
        false ->
            briskd_state_send:fail(
                Pid, <<"RECLAIM">>, <<"INVALID_SECRET">>, [], <<"Invalid reclaim secret">>
            )
    end;
reclaim([], Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"RECLAIM">>], <<"Not enough parameters">>
    ).

valid_secret(Secret) ->
    byte_size(Secret) >= 16 andalso byte_size(Secret) =< 64 andalso
        lists:all(
            fun(C) ->
                (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
                    (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $_
            end,
            binary_to_list(Secret)
        ).

-doc """
Hold a channel name whose last remote member was lost, under the same rules
as `hold_nick/1` (the RFC 2811 channel delay).
""".
-spec hold_channel(binary()) -> ok.
hold_channel(Name) ->
    hold(channel, Name).

-doc """
True while a hold set by `hold_nick/1` is still in force for `Nick`.

An expired hold found here is deleted.
""".
-spec nick_blocked(binary()) -> boolean().
nick_blocked(Nick) ->
    blocked(nick, Nick).

-doc """
True while `Nick` is held against `Client` (numeric 437). A hold owned by
the same `RECLAIM` secret or account (`hold_nick/2`) does not block
`Client`; it is released instead, so the nickname is theirs again.
""".
-spec nick_blocked(binary(), #client{}) -> boolean().
nick_blocked(Nick, #client{pid = Pid}) ->
    Key = {nick, briskd_wire:fold(Nick)},
    case ets:lookup(?HOLDS, Key) of
        [{_, _Until, #{token := OwnerToken, account := OwnerAccount}}] ->
            Token = briskd_conn:get(Pid, reclaim),
            SameToken =
                is_binary(OwnerToken) andalso is_binary(Token) andalso
                    crypto:hash_equals(OwnerToken, Token),
            Account = briskd_state_v3:account(Pid),
            SameAccount =
                is_binary(OwnerAccount) andalso is_binary(Account) andalso
                    briskd_wire:fold(OwnerAccount) =:= briskd_wire:fold(Account),
            case SameToken orelse SameAccount of
                true ->
                    true = ets:delete(?HOLDS, Key),
                    false;
                false ->
                    blocked(nick, Nick)
            end;
        _ ->
            blocked(nick, Nick)
    end.

-doc """
True while a hold set by `hold_channel/1` is still in force for `Name`.

An expired hold found here is deleted.
""".
-spec channel_blocked(binary()) -> boolean().
channel_blocked(Name) ->
    blocked(channel, Name).

-doc """
Handle a client `CAP` command (IRCv3 capability negotiation).

- `LS [version]` records the requested version, suspends registration until
  `CAP END`, and lists the advertised capabilities from `m:briskd_cap`; values
  (`name=value`) are shown only to clients that asked for version 302.
- `LIST` lists the enabled capabilities.
- `REQ` applies the request atomically with `briskd_cap:request/2` and answers
  `ACK` or `NAK`. The reply is formatted with the capabilities in force before
  the request; the new set applies from the next line.
- `END` finishes negotiation and sends the welcome burst when registration is
  otherwise complete.

An unknown subcommand gets numeric 410 and a missing one 461. A reply that
does not fit one line continues with `*` only for `LS` and `LIST` at
version 302; an older client gets one line, and names that do not fit are
left out.
""".
-spec cap(#client{}, binary(), [binary()]) -> ok.
cap(#client{pid = Pid, nick = Nick} = Client, Server, [Sub | Rest]) ->
    case Sub of
        <<"LS">> ->
            briskd_cap:note_ls(Pid, [Sub | Rest]),
            briskd_cap:hold(Pid),
            send_cap_list(Pid, Nick, Server, <<"LS">>, ls_tokens(Pid));
        <<"LIST">> ->
            send_cap_list(Pid, Nick, Server, <<"LIST">>, briskd_cap:list_names(Pid));
        <<"REQ">> ->
            briskd_cap:hold(Pid),
            %% The ACK is sent with the capabilities in force before the
            %% request; the new set applies from the next line on.
            Before = briskd_cap:state(Pid),
            {Kind, Text} = briskd_cap:request(Pid, Rest),
            After = briskd_cap:state(Pid),
            Reply =
                case Kind of
                    ack -> <<"ACK">>;
                    nak -> <<"NAK">>
                end,
            briskd_cap:restore(Pid, Before),
            briskd_state_send:send(Pid, Server, <<"CAP">>, [Nick, Reply], Text),
            briskd_cap:restore(Pid, After);
        <<"END">> ->
            case briskd_cap:finish(Pid, briskd_state_client:identified(Client)) of
                welcome ->
                    briskd_state_client:send_welcome(briskd_state_client:client(Pid), Server);
                _ ->
                    ok
            end;
        _ ->
            briskd_state_send:numeric(Client, Server, <<"410">>, [Sub], <<"Invalid CAP command">>)
    end;
cap(Client, Server, []) ->
    briskd_state_send:numeric(Client, Server, <<"461">>, [<<"CAP">>], <<"Not enough parameters">>).

%% CAP LS tokens. Values are only shown to clients that asked for version 302.
ls_tokens(Pid) ->
    Values = maps:get(version, briskd_cap:state(Pid)) >= 302,
    [cap_token(Name, Value, Values) || {Name, Value} <- briskd_cap:advertised(Pid)].

cap_token(Name, undefined, _) -> Name;
cap_token(Name, _Value, false) -> Name;
cap_token(Name, Value, true) -> <<Name/binary, "=", Value/binary>>.

-doc """
Tell `cap-notify` clients about capabilities whose advertisement changed.

`Before` maps each client pid to its earlier advertised list, and `Server` is
the reply prefix. A capability that disappears is sent as `CAP DEL` (never for
`sts`) and is disabled. A new capability, or one whose value changed, is sent
as `CAP NEW`.
""".
-spec notify_cap_changes(#{pid() => [{binary(), undefined | binary()}]}, binary()) -> ok.
notify_cap_changes(Before, Server) ->
    maps:foreach(
        fun(Pid, Old) ->
            case briskd_cap:enabled(Pid, <<"cap-notify">>) of
                true -> notify_cap_change(Pid, Old, briskd_cap:advertised(Pid), Server);
                false -> ok
            end
        end,
        Before
    ).

notify_cap_change(Pid, Old, New, Server) ->
    Nick =
        case mnesia:dirty_read(client, Pid) of
            [#client{nick = N}] -> N;
            [] -> <<"*">>
        end,
    Removed = [
        Name
     || {Name, _} <- Old, not lists:keymember(Name, 1, New), Name =/= <<"sts">>
    ],
    Added = [Pair || Pair <- New, not lists:member(Pair, Old)],
    case Removed of
        [] ->
            ok;
        _ ->
            briskd_cap:disable(Pid, Removed),
            send_cap_list(Pid, Nick, Server, <<"DEL">>, Removed)
    end,
    case Added of
        [] ->
            ok;
        _ ->
            Values = maps:get(version, briskd_cap:state(Pid)) >= 302,
            send_cap_list(
                Pid, Nick, Server, <<"NEW">>, [cap_token(N, V, Values) || {N, V} <- Added]
            )
    end.

send_cap_list(Pid, Nick, Server, Sub, Names) ->
    %% The `*` continuation exists only for LS and LIST.
    Multiline =
        maps:get(version, briskd_cap:state(Pid)) >= 302 andalso
            (Sub =:= <<"LS">> orelse Sub =:= <<"LIST">>),
    Budget = cap_budget(Server, Nick, Sub, Multiline),
    Bodies =
        case Multiline orelse (Sub =/= <<"LS">> andalso Sub =/= <<"LIST">>) of
            true ->
                briskd_cap:pack(Names, Budget);
            false ->
                %% Before 302 a client reads one LS/LIST line only: names that
                %% do not fit are left out rather than sent on a second line.
                [hd(briskd_cap:pack(Names, Budget))]
        end,
    Last = length(Bodies),
    lists:foreach(
        fun({Index, Body}) ->
            Middle =
                case Multiline andalso Index < Last of
                    true -> [Nick, Sub, <<"*">>];
                    false -> [Nick, Sub]
                end,
            briskd_state_send:send(Pid, Server, <<"CAP">>, Middle, Body)
        end,
        lists:enumerate(Bodies)
    ).

%% Bytes left for the capability list after `:server CAP nick SUB [* ] :`.
cap_budget(Server, Nick, Sub, Multiline) ->
    Star =
        case Multiline of
            true -> 2;
            false -> 0
        end,
    512 - (11 + Star + byte_size(Server) + byte_size(Nick) + byte_size(Sub)).

-doc """
Answer `SERVLIST` (RFC 2812 section 3.5.1).

Sends numeric 234 (`RPL_SERVLIST`) for every known service whose name matches
the wildcard `Mask` and whose type equals `Type` (any type when `Type` is
`*`), then 235 (`RPL_SERVLISTEND`).
""".
-spec servlist(binary(), binary(), #client{}, binary()) -> ok.
servlist(Mask, Type, Client, Server) ->
    lists:foreach(
        fun(
            #service{
                name = Name, server = Home, distribution = Dist, type = ServiceType, info = Info
            }
        ) ->
            Matches =
                briskd_state_channel:wildcard_match(Mask, Name) andalso
                    (Type =:= <<"*">> orelse Type =:= ServiceType),
            case Matches of
                true ->
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"234">>,
                        [Name, Home, Dist, ServiceType, <<"1">>],
                        Info
                    );
                false ->
                    ok
            end
        end,
        services()
    ),
    briskd_state_send:numeric(
        Client, Server, <<"235">>, [Mask, Type], <<"End of service listing">>
    ).

-doc """
Handle a client `SQUERY` (RFC 2812 section 3.5.2).

Replies 411 without a target, 412 without text, and 401 for an unknown
service. A service registered on this server delivers the text as a `NOTICE`
from the client to every local operator (user mode `+o`), with 401 when no
operator is online. A remote service gets the `SQUERY` forwarded to the peer
it was learned from.
""".
-spec squery([binary()], #client{}, binary()) -> ok.
squery([], Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"411">>, [], <<"No recipient given (SQUERY)">>);
squery([_Service], Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"412">>, [], <<"No text to send">>);
squery([_Service, <<>> | _], Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"412">>, [], <<"No text to send">>);
squery([Name, Text | _], Client, Server) ->
    case mnesia:dirty_read(service, briskd_wire:fold(Name)) of
        [] ->
            briskd_state_send:numeric(
                Client, Server, <<"401">>, [Name], <<"No such nick/channel">>
            );
        [#service{peer = undefined, name = ServiceName}] ->
            deliver_local_service(ServiceName, Text, Client, Server);
        [#service{peer = Peer, name = ServiceName}] ->
            Line = briskd_wire:line(
                briskd_state_send:prefix(Client), <<"SQUERY">>, [ServiceName], Text
            ),
            _ = briskd_links:send(Peer, Line),
            ok
    end.

-doc """
Handle an `SQUERY` (RFC 2812 section 3.5.2) that arrived from the peer `Peer`.

`Prefix` must be a remote user reached through `Peer`
(`briskd_state_link:remote_source/2`). A service registered on this server
delivers the text as a `NOTICE` from that user to every local operator, as a
local `SQUERY` does; no 401 is routed back when no operator is online. A
service learned from another peer gets the `SQUERY` forwarded there, never
back to `Peer`. Any other target goes to
`briskd_state_link:receive_remote_message/4` as before.

Errors: `unknown_remote_source` and those of
`briskd_state_link:receive_remote_message/4`.
""".
-spec remote_squery(binary(), binary(), [binary()]) -> ok | {error, atom()}.
remote_squery(Peer, Prefix, [Name, Text | _] = Params) when Text =/= <<>> ->
    case mnesia:dirty_read(service, briskd_wire:fold(Name)) of
        [] ->
            briskd_state_link:receive_remote_message(Peer, Prefix, <<"SQUERY">>, Params);
        [#service{peer = ServicePeer, name = ServiceName}] ->
            case briskd_state_link:remote_source(Peer, Prefix) of
                {ok, _} when ServicePeer =:= undefined ->
                    Operators = briskd_oper:local_operators(),
                    briskd_state_send:broadcast(
                        Operators, Prefix, <<"NOTICE">>, [ServiceName], Text
                    );
                {ok, _} ->
                    case briskd_route:should_forward(Peer, ServicePeer) of
                        true ->
                            Line = briskd_wire:line(Prefix, <<"SQUERY">>, [ServiceName], Text),
                            _ = briskd_links:send(ServicePeer, Line),
                            ok;
                        false ->
                            ok
                    end;
                error ->
                    {error, unknown_remote_source}
            end
    end;
remote_squery(Peer, Prefix, Params) ->
    briskd_state_link:receive_remote_message(Peer, Prefix, <<"SQUERY">>, Params).

-doc """
Import a `SERVICE` introduction (RFC 2813 section 4.1.4) from the peer
`Peer`.

Accepts the RFC 2813 form `<name> <reserved> <distribution> <type>
<reserved> :<info>` and a shorter `<name> <distribution> <type> :<info>`.
The home server is `Prefix`, or `Peer` when there is no prefix. Returns
`{error, invalid_service}` for a bad parameter list or service name and
`{error, nickname_collision}` when a local or remote user holds the name.
The service is stored but not relayed to other peers.
""".
-spec import_service(binary(), binary(), [binary()]) -> ok | {error, atom()}.
import_service(Peer, Prefix, Params) ->
    case service_params(Params) of
        error ->
            {error, invalid_service};
        {Name, Dist, Type, Info} ->
            Home =
                case Prefix of
                    undefined -> Peer;
                    _ -> Prefix
                end,
            case
                briskd_state_link:trusted_server(Peer, Home) andalso
                    briskd_wire:nickname(Name, briskd_state:nicklen())
            of
                false ->
                    {error, invalid_service};
                true ->
                    case peer_service_room(Peer, Name) of
                        false -> {error, too_many_remote_services};
                        true -> store_service(Name, Dist, Type, Info, Home, Peer)
                    end
            end
    end.

-doc """
Number of known services, local and imported.
""".
-spec service_count() -> non_neg_integer().
service_count() ->
    case mnesia:table_info(service, size) of
        Size when is_integer(Size), Size >= 0 -> Size
    end.

-doc """
`SERVER` lines for every known server, nearest first, for a new peer's burst
(RFC 2813 section 5.3.2).

`Local` is this server's name. A line is prefixed by the server's parent
(`Local` for an adjacent peer) and carries the stored hop count plus one, as
seen from the receiving peer.
""".
-spec burst_server_lines(binary()) -> [binary()].
burst_server_lines(Local) ->
    [
        iolist_to_binary(intro_line(Local, Server))
     || Server <- briskd_route:burst_order(known_maps())
    ].

-doc """
Known servers as `{Name, Hop, Info}`, nearest first, for the `LINKS` reply.

The local server is not included.
""".
-spec links_entries() -> [{binary(), non_neg_integer(), binary()}].
links_entries() ->
    [
        {Name, Hop, Info}
     || #{name := Name, hop := Hop, info := Info} <- briskd_route:burst_order(known_maps())
    ].

-doc """
Run an operator-only server command for a local client.

A client without user mode `+o` gets numeric 481. The caller passes only
these commands:

- `SQUIT <server> [:<reason>]` runs `split/3` locally and confirms with a
  `NOTICE`; 402 for an unknown server.
- `CONNECT <server>` asks `briskd_links:connect_peer/1` to connect a configured
  peer and confirms with a `NOTICE`; 402 for a name that is not configured.
- `SERVICE <name> <distribution> <type> [:<info>]` registers a local service
  and replies 234, or 432 for a bad name and 433 for a name in use.
- `DIE` and `RESTART` call `init:stop/0` and `init:restart/0` from a new
  process.

A command missing its required parameters gets 461.
""".
-spec oper_command(binary(), [binary()], #client{}, binary()) -> ok.
oper_command(Command, Params, #client{pid = Pid} = Client, Server) ->
    case maps:is_key($o, briskd_state_client:user_modes(Pid)) of
        false ->
            briskd_state_send:numeric(Client, Server, <<"481">>, [], <<"Permission Denied">>);
        true ->
            oper_command_allowed(Command, Params, Client, Server)
    end.

oper_command_allowed(<<"SQUIT">>, [Target | Rest], Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> <<"SQUIT">>
        end,
    case mnesia:dirty_read(known_server, briskd_wire:fold(Target)) of
        [] ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        [#known_server{name = Name}] ->
            drop_server(Name, Reason, undefined),
            briskd_state_send:send(
                Client#client.pid,
                Server,
                <<"NOTICE">>,
                [Client#client.nick],
                <<"SQUIT ", Name/binary>>
            )
    end;
oper_command_allowed(<<"SQUIT">>, _, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"SQUIT">>], <<"Not enough parameters">>
    );
oper_command_allowed(<<"CONNECT">>, [Target | _], Client, Server) ->
    case configured_peer(Target) of
        {ok, Name} ->
            _ = briskd_links:connect_peer(Name),
            briskd_state_send:send(
                Client#client.pid,
                Server,
                <<"NOTICE">>,
                [Client#client.nick],
                <<"Connect attempt for ", Name/binary>>
            );
        error ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end;
oper_command_allowed(<<"CONNECT">>, _, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"CONNECT">>], <<"Not enough parameters">>
    );
oper_command_allowed(<<"SERVICE">>, [Name, Dist, Type | Rest], Client, Server) ->
    Info =
        case Rest of
            [Text | _] -> Text;
            [] -> <<"service">>
        end,
    case briskd_wire:nickname(Name, briskd_state:nicklen()) of
        true ->
            case store_service(Name, Dist, Type, Info, local_name(), undefined) of
                ok ->
                    briskd_state_send:numeric(
                        Client, Server, <<"234">>, [Name, local_name(), Dist, Type, <<"0">>], Info
                    );
                {error, nickname_collision} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"433">>, [Name], <<"Nickname is already in use">>
                    )
            end;
        false ->
            briskd_state_send:numeric(Client, Server, <<"432">>, [Name], <<"Erroneous nickname">>)
    end;
oper_command_allowed(<<"SERVICE">>, _, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"SERVICE">>], <<"Not enough parameters">>
    );
%% RFC 2812 DIE shuts the node down. RESTART restarts the runtime. Both are
%% operator-only; a non-operator already received numeric 481.
oper_command_allowed(<<"DIE">>, _, _Client, _Server) ->
    erlang:spawn(fun init:stop/0),
    ok;
oper_command_allowed(<<"RESTART">>, _, _Client, _Server) ->
    erlang:spawn(fun init:restart/0),
    ok.

store_service(Name, Dist, Type, Info, Home, Peer) ->
    Key = briskd_wire:fold(Name),
    case briskd_state_client:find_nick(Name) =/= undefined orelse remote_nick(Name) of
        true ->
            {error, nickname_collision};
        false ->
            mnesia:dirty_write(
                briskd_wire:retain_fields(#service{
                    key = Key,
                    name = Name,
                    distribution = Dist,
                    type = Type,
                    info = Info,
                    server = Home,
                    peer = Peer
                })
            ),
            case is_binary(Peer) of
                true -> briskd_state_link:track_peer_item(service, Key, Peer);
                false -> briskd_state_link:untrack_peer_item(service, Key)
            end,
            ok
    end.

deliver_local_service(ServiceName, Text, Client, Server) ->
    Operators = briskd_oper:local_operators(),
    briskd_state_send:broadcast(
        Operators,
        briskd_state_send:prefix(Client),
        <<"NOTICE">>,
        [ServiceName],
        Text
    ),
    case Operators of
        [] ->
            briskd_state_send:numeric(
                Client, Server, <<"401">>, [ServiceName], <<"No such nick/channel">>
            );
        _ ->
            ok
    end.

service_params([Name, _Reserved, Dist, Type, _Reserved2, Info | _]) ->
    {Name, Dist, Type, Info};
service_params([Name, Dist, Type, Info | _]) ->
    {Name, Dist, Type, Info};
service_params(_) ->
    error.

lost_names(Lost) ->
    Known = lost_known(Lost),
    case lists:any(fun(Name) -> briskd_wire:fold(Name) =:= briskd_wire:fold(Lost) end, Known) of
        true -> Known;
        false -> [Lost | Known]
    end.

lost_known(Lost) ->
    briskd_route:servers_behind(Lost, known_maps()).

lost_client(#remote_client{server = Server, peer = Peer}, Folds) ->
    Home =
        case Server of
            undefined -> Peer;
            _ -> Server
        end,
    lists:member(briskd_wire:fold(Home), Folds).

drop_remote_user(#remote_client{key = Key, nick = Nick, user = User, host = Host}, Reason) ->
    hold(nick, Nick),
    Prefix = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
    briskd_state_send:with_source(briskd_state_v3:remote_source_info(Prefix), fun() ->
        briskd_state_send:broadcast(
            briskd_state_link:remote_user_local_recipients(Key), Prefix, <<"QUIT">>, [], Reason
        )
    end),
    mnesia:dirty_delete(remote_client, Key),
    briskd_state_link:untrack_peer_item(user, Key),
    briskd_population:on_remote_user_delete(Key),
    briskd_state_monitor:offline(Nick),
    briskd_state_meta:forget_remote(Key),
    ok = briskd_e2ee:forget_remote(Key),
    ok = briskd_calls:remote_gone(Key),
    drop_memberships(Key).

drop_memberships(NickKey) ->
    lists:foreach(
        fun(ChannelKey) ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{name = Name, members = Members} = Channel] ->
                    case maps:is_key(NickKey, Members) of
                        true ->
                            briskd_state_link:unindex_remote_member(NickKey, ChannelKey),
                            Remaining = maps:remove(NickKey, Members),
                            case map_size(Remaining) of
                                0 ->
                                    mnesia:dirty_delete(remote_channel, ChannelKey),
                                    briskd_population:on_channel_delete(ChannelKey),
                                    case mnesia:dirty_read(channel, ChannelKey) of
                                        [] -> hold(channel, Name);
                                        _ -> ok
                                    end;
                                _ ->
                                    mnesia:dirty_write(
                                        briskd_wire:retain_fields(Channel#remote_channel{
                                            members = Remaining
                                        })
                                    )
                            end;
                        false ->
                            ok
                    end;
                _ ->
                    ok
            end
        end,
        briskd_state_link:remote_user_channels(NickKey)
    ).

store_server(#{
    name := Name, hop := Hop, token := Token, adjacent := Adjacent, parent := Parent, info := Info
}) ->
    Key = briskd_wire:fold(Name),
    mnesia:dirty_write(
        briskd_wire:retain_fields(#known_server{
            key = Key,
            name = Name,
            hop = Hop,
            token = Token,
            adjacent = Adjacent,
            parent = Parent,
            info = Info
        })
    ),
    case Key =:= briskd_wire:fold(Adjacent) of
        true -> ok;
        false -> briskd_state_link:track_peer_item(server, Key, Adjacent)
    end,
    briskd_population:on_server_change().

announce_server(Map, Except) ->
    _ = briskd_links:send_except(Except, intro_line(local_name(), Map)).

intro_line(Local, #{name := Name, hop := Hop, token := Token, parent := Parent, info := Info}) ->
    Prefix =
        case briskd_wire:fold(Parent) =:= briskd_wire:fold(Local) of
            true -> Local;
            false -> Parent
        end,
    briskd_wire:line(Prefix, <<"SERVER">>, [Name, integer_to_binary(Hop + 1), Token], Info).

known_maps() ->
    [
        #{
            name => Name,
            hop => Hop,
            token => Token,
            adjacent => Adjacent,
            parent => Parent,
            info => Info
        }
     || Key <- briskd_state:table_keys(known_server),
        [
            #known_server{
                name = Name,
                hop = Hop,
                token = Token,
                adjacent = Adjacent,
                parent = Parent,
                info = Info
            }
        ] <- [mnesia:dirty_read(known_server, Key)]
    ].

services() ->
    [
        Service
     || Key <- briskd_state:table_keys(service),
        [#service{} = Service] <- [mnesia:dirty_read(service, Key)]
    ].

%% `resource_delay` (seconds) overrides the default delay; 0 disables holds.
%% A hold is {{Kind, Folded}, Until} in monotonic seconds, or
%% {{Kind, Folded}, Until, Owner} when a local client owns it (hold/3).
hold(Kind, Name) ->
    hold(Kind, Name, undefined).

hold(Kind, Name, Owner) ->
    Delay = maps:get(
        resource_delay,
        briskd_config:current_or_empty(),
        briskd_route:resource_delay_seconds()
    ),
    case Delay of
        0 ->
            ok;
        _ ->
            Until = erlang:monotonic_time(second) + Delay,
            Key = {Kind, briskd_wire:fold(Name)},
            case Owner of
                undefined -> ets:insert(?HOLDS, {Key, Until});
                _ -> ets:insert(?HOLDS, {Key, Until, Owner})
            end,
            ok
    end.

blocked(Kind, Name) ->
    Key = {Kind, briskd_wire:fold(Name)},
    Now = erlang:monotonic_time(second),
    case ets:lookup(?HOLDS, Key) of
        [Hold] ->
            Until = element(2, Hold),
            case briskd_route:nick_delay_blocked(Key, Now, #{Key => Until}) of
                true ->
                    true;
                false ->
                    true = ets:delete(?HOLDS, Key),
                    false
            end;
        [] ->
            false
    end.

-doc """
Drop nickname and channel holds whose delay has passed.

Called from the state process's one-second tick so that holds nobody asks
about again do not accumulate.
""".
-spec expire_holds() -> ok.
expire_holds() ->
    Now = erlang:monotonic_time(second),
    _ = ets:select_delete(?HOLDS, [
        {{'_', '$1'}, [{'=<', '$1', Now}], [true]},
        {{'_', '$1', '_'}, [{'=<', '$1', Now}], [true]}
    ]),
    ok.

-doc """
The configured `server_links` entry whose name equals `Target` under the
RFC 1459 case fold, as `{ok, Name}` with the configured spelling, or `error`.
Reads only configuration, so any process may call it.
""".
-spec configured_peer(binary()) -> {ok, binary()} | error.
configured_peer(Target) ->
    Fold = briskd_wire:fold(Target),
    Links = persistent_term:get({briskd_state, server_links}, []),
    case lists:search(fun(#{name := Name}) -> briskd_wire:fold(Name) =:= Fold end, Links) of
        {value, #{name := Name}} -> {ok, Name};
        false -> error
    end.

remote_nick(Name) ->
    mnesia:dirty_read(remote_client, briskd_wire:fold(Name)) =/= [].

peer_server_room(Peer, Name) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(known_server, Key) of
        [_] ->
            true;
        [] ->
            Max = maps:get(
                max_peer_servers, briskd_config:current_or_empty(), 100
            ),
            briskd_state_link:peer_item_count(server, Peer) < Max
    end.

peer_service_room(Peer, Name) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(service, Key) of
        [#service{peer = Peer}] ->
            true;
        _ ->
            Max = maps:get(
                max_peer_services, briskd_config:current_or_empty(), 100
            ),
            briskd_state_link:peer_item_count(service, Peer) < Max
    end.

local_name() ->
    maps:get(name, briskd_config:current()).

valid_token(Token) when is_binary(Token), byte_size(Token) > 0, byte_size(Token) =< 16 ->
    lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Token));
valid_token(_) ->
    false.
