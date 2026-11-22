-module(briskd_state_client).
-moduledoc """
Local client identity, registration, visibility, and per-connection statistics.

Every function here runs inside the single `m:briskd_state` gen_server process,
which owns the Mnesia `client`, `user_modes`, `activity`, and `whowas` tables and
the ETS tables `briskd_nicks` (folded nickname to session pid) and
`briskd_connection_stats`. The functions use dirty Mnesia operations and must
not be called from any other process.

Registration follows RFC 2812 section 3.1. A connection is *identified* once
`NICK`, `USER`, and (when `client_password` is configured) a matching `PASS`
have been accepted. It is *ready* once the welcome burst (001 to 004, 005
ISUPPORT, and the MOTD) has been sent. IRCv3 `CAP` negotiation may hold the
welcome until `CAP END`. Until then the client is not ready: it is invisible to
other users, is not introduced to server peers, and gets 451 for commands that
need registration. Nicknames are compared with the RFC 1459 case mapping of
`briskd_wire:fold/1`.

When a ready client changes nickname or disconnects, a WHOWAS row is written
(RFC 2812 section 3.6.3). History is bounded: the newest `?WHOWAS_PER_NICK`
(10) rows per folded nickname are kept, and when the table exceeds
`?WHOWAS_MAX` (10000) rows the oldest tenth is dropped. Channel departures are
delegated to `m:briskd_state_channel`, peer propagation to `m:briskd_state_link`,
and IRCv3 side effects to `m:briskd_state_v3`.
""".
-export([
    client/1,
    pids/0,
    identified/1,
    connection_stats/1,
    disconnect/3,
    find_nick/1,
    initial_user_modes/1,
    pass/3,
    put_connection_stats/2,
    ready/1,
    save_identity/3,
    send_welcome/2,
    touch_activity/1,
    update_connection_stats/4,
    user_modes/1,
    user_visible/2,
    remove_connection_stats/1
]).
-include("briskd_state.hrl").

-doc """
Return the `client` row of a live local session.

Fails with `badmatch` when `Pid` has no row, so callers use it only for
sessions known to exist (for example the sender of the current command).
""".
-spec client(pid()) -> #client{}.
client(Pid) ->
    [#client{} = Client] = mnesia:dirty_read(client, Pid),
    Client.

-doc """
True when the client has completed registration and received the welcome.

That is, `identified/1` holds and `briskd_cap` has marked the connection
welcomed. While IRCv3 CAP negotiation holds the welcome (registration must not
complete before `CAP END`), the client is not ready: commands that need
registration get 451 ERR_NOTREGISTERED and peers do not see the user.
""".
-spec ready(#client{}) -> boolean().
ready(#client{pid = Pid} = Client) ->
    identified(Client) andalso briskd_cap:welcomed(Pid).

-doc """
True when `NICK`, `USER`, and any required `PASS` have been accepted.

The nickname is set (not `*`), `USER` has been given, and either no
`client_password` is configured or `PASS` matched it. This does not imply the
welcome has been sent; see `ready/1`.
""".
-spec identified(#client{}) -> boolean().
identified(#client{nick = Nick, user = User, pass = Pass}) ->
    HasIdentity = Nick =/= <<"*">> andalso User =/= undefined,
    Password = persistent_term:get({briskd_state, client_password}, null),
    Authenticated = Password =:= null orelse Pass =:= true,
    HasIdentity andalso Authenticated.

-doc """
The pids of every local connection, registered or not (the keys of the
`client` table).
""".
-spec pids() -> [pid()].
pids() ->
    briskd_state:table_keys(client).

-doc """
Look up a local client by nickname under the RFC 1459 case mapping.

Uses the `briskd_nicks` index (keyed by `briskd_wire:fold/1`) maintained by the
state process, then re-checks the stored nickname. Returns `undefined` when no
local session holds the nickname. The client may still be unregistered or held
by CAP negotiation; callers that need a registered user also check `ready/1`.
Remote users are not found here.
""".
-spec find_nick(binary()) -> undefined | #client{}.
find_nick(Nick) ->
    case ets:lookup(briskd_nicks, briskd_wire:fold(Nick)) of
        [{_, Pid}] ->
            case mnesia:dirty_read(client, Pid) of
                [#client{nick = Stored} = Client] when Stored =/= <<"*">> ->
                    case briskd_wire:fold(Stored) =:= briskd_wire:fold(Nick) of
                        true -> Client;
                        false -> undefined
                    end;
                _ ->
                    undefined
            end;
        [] ->
            undefined
    end.

-doc """
Persist a `NICK`, `USER`, or `PASS` change and complete registration when ready.

`Old` is the client record the command started from and `New` carries the
changed fields. A nickname of `*` or a field of `undefined` in `New` means
"unchanged", and the stored channel list is always kept. `Server` is this
server's name, used as the numeric prefix.

Side effects:

- updates the folded-nickname index `briskd_nicks`;
- writes a WHOWAS row when a ready client changes nickname;
- when `NICK` and `USER` are now both done but the required server password
  was not given, sends 464 ERR_PASSWDMISMATCH followed by `ERROR` and closes
  the connection;
- when the client has just become identified and CAP negotiation is not in
  progress, marks the connection welcomed and calls `send_welcome/2`.
""".
-spec save_identity(#client{}, #client{}, binary()) -> ok.
save_identity(Old, New, Server) ->
    Current = client(Old#client.pid),
    Updated = New#client{
        nick = stored_nick(New#client.nick, Current#client.nick),
        user = stored_field(New#client.user, Current#client.user),
        real = stored_field(New#client.real, Current#client.real),
        away = stored_field(New#client.away, Current#client.away),
        channels = Current#client.channels
    },
    ok = index_nick(Updated#client.pid, Current#client.nick, Updated#client.nick),
    case ready(Current) andalso Current#client.nick =/= Updated#client.nick of
        true -> save_whowas(Current, Server);
        false -> ok
    end,
    mnesia:dirty_write(Updated),
    %% NICK and USER are done but the server password was not given:
    %% ERR_PASSWDMISMATCH (464), then ERROR and close.
    case
        not identity_ready(Current) andalso identity_ready(Updated) andalso
            not identified(Updated)
    of
        true ->
            numeric_and_close(Updated, Server);
        false ->
            ok
    end,
    case not identified(Old) andalso identified(Updated) of
        true ->
            case maps:get(negotiating, briskd_cap:state(Updated#client.pid)) of
                true ->
                    ok;
                false ->
                    welcome = briskd_cap:finish(Updated#client.pid, true),
                    send_welcome(Updated, Server)
            end;
        false ->
            ok
    end.

-doc """
Send the numeric burst that completes registration.

The caller marks the connection welcomed before this runs. A normal
connection gets 001 RPL_WELCOME to 004 RPL_MYINFO, the 005 RPL_ISUPPORT
tokens, metadata notifications, and the MOTD (`briskd_state_info:motd/3`). Before
the numerics it records the signon time, updates the user-count maxima
(`briskd_state_info:note_user_counts/0`), introduces the user to server peers,
runs the IRCv3 registration hooks, and logs `client_registered`; after the MOTD
it rejoins channels remembered for the account.

A connection attaching to an existing session (`attach_to` in `m:briskd_conn`)
gets the same numerics and MOTD, is not introduced to anyone, and is then
handed to the holding session.
""".
-spec send_welcome(#client{}, binary()) -> ok.
send_welcome(#client{pid = Pid} = Client, Server) ->
    case briskd_conn:get(Pid, attach_to) of
        undefined -> send_full_welcome(Client, Server);
        Holder -> send_attach_welcome(Client, Holder, Server)
    end.

%% An attached connection gets the welcome numerics for the shared nickname
%% and is then handed to the holder; it is not introduced to anyone.
send_attach_welcome(Client, Holder, Server) ->
    %% The session stops its registration timer without asking (briskd_session).
    Client#client.pid ! registered,
    welcome_numerics(Client, Server),
    briskd_state_info:motd([], Client, Server),
    briskd_state_v3:finish_attach(Client, Holder).

send_full_welcome(#client{nick = Nick, user = User, host = Host} = Client, Server) ->
    briskd_conn:put(Client#client.pid, signon, erlang:system_time(second)),
    true = ets:insert(briskd_ready_clients, {Client#client.pid}),
    %% The session stops its registration timer without asking (briskd_session).
    Client#client.pid ! registered,
    _ = briskd_state_info:note_user_counts(),
    briskd_state_link:propagate_introduction(Client, Server),
    briskd_state_v3:registered(Client, Server),
    logger:info(#{event => client_registered, nick => Nick, user => User, host => Host}),
    welcome_numerics(Client, Server),
    briskd_state_info:motd([], Client, Server),
    briskd_state_v3:rejoin_on_login(Client, Server).

welcome_numerics(Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"001">>, [], [
        <<"Welcome to IRC ">>, briskd_state_send:prefix(Client)
    ]),
    briskd_state_send:numeric(
        Client,
        Server,
        <<"002">>,
        [],
        [<<"Your host is ">>, Server, <<", running version ">>, briskd_app:vsn()]
    ),
    briskd_state_send:numeric(
        Client,
        Server,
        <<"003">>,
        [],
        [
            <<"This server was created ">>,
            persistent_term:get({briskd_state, started})
        ]
    ),
    briskd_state_send:numeric(
        Client,
        Server,
        <<"004">>,
        [Server, briskd_app:vsn(), <<"iowB">>, <<"abeIimnpsqrKltkov">>],
        none
    ),
    briskd_isupport:send(Client, Server, briskd_isupport:tokens()),
    briskd_state_meta:on_registered(Client, Server).

numeric_and_close(#client{pid = Pid} = Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"464">>, [], <<"Password incorrect">>),
    Pid ! {irc_close, briskd_wire:line(Server, <<"ERROR">>, [], <<"Password required">>)},
    ok.

-doc """
Handle `PASS <password>` (RFC 2812 section 3.1.1).

`Params` are the command parameters, `Client` the requesting session, and
`Server` this server's name. After `NICK` and `USER`, or when `PASS` was
already given, the reply is 462 ERR_ALREADYREGISTRED. Without a parameter it
is 461 ERR_NEEDMOREPARAMS. The password is compared with the configured
`client_password` through `briskd_config:secret_match/2`; when no password is
configured any value is accepted. A match is stored and may complete
registration through `save_identity/3`. A mismatch is stored as failed and
answered with 464 ERR_PASSWDMISMATCH. The password is never logged or echoed.
""".
-spec pass([binary()], #client{}, binary()) -> ok.
pass(Params, Client, Server) ->
    case identity_ready(Client) of
        true ->
            briskd_state_send:numeric(Client, Server, <<"462">>, [], <<"You may not reregister">>);
        false ->
            pass_unregistered(Params, Client, Server)
    end.

pass_unregistered([], Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"461">>, [<<"PASS">>], <<"Not enough parameters">>);
pass_unregistered(_, #client{pass = Pass} = Client, Server) when Pass =/= undefined ->
    briskd_state_send:numeric(Client, Server, <<"462">>, [], <<"You may not reregister">>);
pass_unregistered([Given | _], Client, Server) ->
    Expected = persistent_term:get({briskd_state, client_password}, null),
    case Expected =:= null orelse briskd_config:secret_match(Given, Expected) of
        true ->
            save_identity(Client, Client#client{pass = true}, Server);
        false ->
            mnesia:dirty_write(Client#client{pass = false}),
            briskd_state_send:numeric(Client, Server, <<"464">>, [], <<"Password incorrect">>)
    end.

identity_ready(#client{nick = Nick, user = User}) ->
    Nick =/= <<"*">> andalso User =/= undefined.

-doc """
Decode the `<mode>` parameter of `USER` into initial user modes.

RFC 2812 section 3.1.3 defines a numeric bit mask: bit 2 (value 4) sets `+w`
and bit 3 (value 8) sets `+i`. Other bits are ignored. A non-numeric value,
such as the RFC 1459 hostname field or the usual `*`, sets no modes and
returns `{ok, #{}}`. A negative number returns `error`.
""".
-spec initial_user_modes(binary()) -> error | {ok, #{char() => true}}.
initial_user_modes(Mode) ->
    try binary_to_integer(Mode) of
        Mask when Mask >= 0 ->
            Modes0 = #{},
            Modes1 =
                case Mask band 4 of
                    0 -> Modes0;
                    _ -> Modes0#{$w => true}
                end,
            Modes2 =
                case Mask band 8 of
                    0 -> Modes1;
                    _ -> Modes1#{$i => true}
                end,
            {ok, Modes2};
        _ ->
            error
    catch
        %% RFC 1459 puts a hostname here and most clients send `*` or `0`.
        %% A non-numeric value sets no initial modes (RFC 2812 bit mask only
        %% applies to a number).
        error:badarg -> {ok, #{}}
    end.

-doc """
Create the zeroed traffic counters for a new connection.

The row records the connect time in monotonic seconds. The second argument is
ignored.
""".
-spec put_connection_stats(pid(), term()) -> true.
put_connection_stats(Pid, _Entry) ->
    ets:insert(briskd_connection_stats, {Pid, erlang:monotonic_time(second), 0, 0, 0, 0}).

-doc """
Delete the traffic counters of a connection.
""".
-spec remove_connection_stats(pid()) -> true.
remove_connection_stats(Pid) ->
    ets:delete(briskd_connection_stats, Pid).

-doc """
Return the traffic counters of a connection, or `#{}` when it has none.

`connected_at` is in monotonic seconds. The counters back `STATS l`
(see `briskd_state_info:stats/3`).
""".
-spec connection_stats(pid()) ->
    #{
        connected_at := integer(),
        recv_bytes := non_neg_integer(),
        recv_messages := non_neg_integer(),
        sent_bytes := non_neg_integer(),
        sent_messages := non_neg_integer()
    }
    | #{}.
connection_stats(Pid) ->
    case ets:lookup(briskd_connection_stats, Pid) of
        [{Pid, ConnectedAt, SentMessages, SentBytes, RecvMessages, RecvBytes}] when
            is_integer(ConnectedAt),
            is_integer(SentMessages),
            is_integer(SentBytes),
            is_integer(RecvMessages),
            is_integer(RecvBytes)
        ->
            #{
                connected_at => ConnectedAt,
                sent_messages => SentMessages,
                sent_bytes => SentBytes,
                recv_messages => RecvMessages,
                recv_bytes => RecvBytes
            };
        [] ->
            #{}
    end.

-doc """
Add one message of `Bytes` octets to a connection's sent or received counters,
and to the server totals of `m:briskd_stats`.

Only the key pairs `sent_messages`/`sent_bytes` and `recv_messages`/`recv_bytes`
are recognised; any other pair, or a connection without counters, is ignored.
""".
-spec update_connection_stats(
    pid(), sent_messages | recv_messages, sent_bytes | recv_bytes, non_neg_integer()
) -> ok.
update_connection_stats(Pid, MessagesKey, BytesKey, Bytes) ->
    case {MessagesKey, BytesKey} of
        {sent_messages, sent_bytes} ->
            ok = briskd_stats:count_traffic(out, 1, Bytes),
            update_connection_stats_counter(Pid, 3, 4, Bytes);
        {recv_messages, recv_bytes} ->
            ok = briskd_stats:count_traffic(in, 1, Bytes),
            update_connection_stats_counter(Pid, 5, 6, Bytes);
        _ ->
            ok
    end.

%% One atomic update. A connection without a row (not counted, or removed
%% by the state process while its session was still sending) is ignored:
%% sessions call this concurrently with that removal.
update_connection_stats_counter(Pid, MessagesPosition, BytesPosition, Bytes) ->
    try
        _ = ets:update_counter(
            briskd_connection_stats, Pid, [{MessagesPosition, 1}, {BytesPosition, Bytes}]
        ),
        ok
    catch
        error:badarg -> ok
    end.

-doc """
Remove a local client: broadcast `QUIT`, leave its channels, and delete its rows.

`Reason` is the quit text (or `none`) and `Server` this server's name. For a
ready client this also writes a WHOWAS row, holds the nickname briefly
(`m:briskd_state_net`), propagates `QUIT` to server peers, sends `QUIT` to the
local users sharing a channel (anonymous `+a` and quiet `+q` channels excepted;
an anonymous channel instead gets an anonymous `PART`), and records the event
in channel history. In every case the client leaves its channels (an emptied
channel is released per the retention policy) and its `client`, `activity`,
and `user_modes` rows, nickname index entry, administrator entry, capability
state, IRCv3 state, and traffic counters are removed. Logs
`client_disconnected`.
""".
-spec disconnect(#client{}, none | binary(), binary()) -> ok.
disconnect(#client{pid = Pid, channels = Channels} = Client, Reason, Server) ->
    briskd_state_v3:remember_channels(Client),
    case ready(Client) of
        true ->
            save_whowas(Client, Server),
            briskd_state_net:hold_nick(Client#client.nick, Client),
            briskd_state_link:propagate_quit(Client, Reason);
        false ->
            ok
    end,
    case ready(Client) of
        true ->
            {QuitTags, QuitMeta} = briskd_state_history:event_tags(),
            briskd_state_send:with_source(briskd_state_v3:source_info(Client), fun() ->
                briskd_state_send:broadcast(
                    quit_recipients(Client),
                    briskd_state_send:prefix(Client),
                    <<"QUIT">>,
                    [],
                    Reason,
                    QuitTags
                )
            end),
            briskd_state_history:note_user_event(
                Channels, <<"QUIT">>, briskd_state_send:prefix(Client), Reason, QuitMeta
            );
        false ->
            ok
    end,
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{flags = Flags}] ->
                    briskd_state_channel:leave(
                        Key, Client, <<"PART">>, none, maps:is_key($a, Flags), false
                    );
                [] ->
                    ok
            end
        end,
        Channels
    ),
    ok = forget_nick(Pid, Client#client.nick),
    ets:delete(briskd_ready_clients, Pid),
    mnesia:dirty_delete(client, Pid),
    mnesia:dirty_delete(activity, Pid),
    mnesia:dirty_delete(user_modes, Pid),
    case ets:whereis(briskd_admins) of
        undefined -> ok;
        _ -> ets:delete(briskd_admins, Pid)
    end,
    briskd_state_v3:disconnect(Client),
    briskd_cap:disconnect(Pid),
    ok = briskd_flood:disconnect(Pid),
    ok = briskd_state_channel:prune_invited(Pid),
    remove_connection_stats(Pid),
    logger:info(#{
        event => client_disconnected,
        nick => Client#client.nick,
        host => Client#client.host
    }).

quit_recipients(#client{pid = Pid, channels = Channels}) ->
    lists:usort([
        OtherPid
     || Key <- Channels,
        [#channel{members = Members, flags = Flags}] <- [mnesia:dirty_read(channel, Key)],
        not maps:is_key($a, Flags),
        not maps:is_key($q, Flags),
        OtherPid <- maps:keys(Members),
        OtherPid =/= Pid
    ]).

-doc """
Record the current wall-clock second as the client's last activity.

The value backs the idle time in 317 RPL_WHOISIDLE and the WHOX `l` field.
""".
-spec touch_activity(pid()) -> ok.
touch_activity(Pid) ->
    mnesia:dirty_write(#activity{pid = Pid, last = erlang:system_time(second)}).

-doc """
Return the user modes of a local session as a map of mode character to `true`.

Unknown sessions have no modes (`#{}`).
""".
-spec user_modes(pid()) -> #{char() => true}.
user_modes(Pid) ->
    case mnesia:dirty_read(user_modes, Pid) of
        [#user_modes{modes = Modes}] -> Modes;
        [] -> #{}
    end.

-doc """
True when `Target` may be shown to `Requester` in user queries.

A client is always visible to itself. Otherwise the target must be ready, and
a target with user mode `+i` is shown only when the requester is a member of
one of the target's channels (RFC 2812 section 3.1.5).
""".
-spec user_visible(#client{}, #client{}) -> boolean().
user_visible(#client{pid = Pid}, #client{pid = RequesterPid}) when
    Pid =:= RequesterPid
->
    true;
user_visible(#client{pid = Pid, channels = Channels} = Target, #client{pid = RequesterPid}) ->
    %% A client whose registration is still held by CAP negotiation is not
    %% visible to anyone else yet.
    ready(Target) andalso
        (not maps:is_key($i, user_modes(Pid)) orelse
            lists:any(
                fun(Key) ->
                    case mnesia:dirty_read(channel, Key) of
                        [#channel{members = Members}] -> maps:is_key(RequesterPid, Members);
                        [] -> false
                    end
                end,
                Channels
            )).

%% `<<"*">>` means the caller is not changing the nickname.
stored_nick(<<"*">>, Current) -> Current;
stored_nick(Value, Value) -> Value;
stored_nick(Value, _Current) -> briskd_wire:retain(Value).

%% `undefined` means the caller is not changing this field.
%% Equal binaries keep the copy already owned by the client record.
stored_field(undefined, Current) -> Current;
stored_field(Value, Value) -> Value;
stored_field(Value, _Current) -> briskd_wire:retain(Value).

index_nick(Pid, OldNick, NewNick) ->
    OldKey = nick_key(OldNick),
    NewKey = nick_key(NewNick),
    case OldKey =:= NewKey of
        true ->
            ok;
        false ->
            forget_key(OldKey, Pid),
            remember_key(NewKey, Pid)
    end.

forget_nick(Pid, Nick) ->
    forget_key(nick_key(Nick), Pid).

nick_key(<<"*">>) -> undefined;
nick_key(Nick) when is_binary(Nick) -> briskd_wire:fold(Nick).

forget_key(undefined, _Pid) ->
    ok;
forget_key(Key, Pid) ->
    case ets:lookup(briskd_nicks, Key) of
        [{_, Pid}] ->
            ets:delete(briskd_nicks, Key),
            ok;
        _ ->
            ok
    end.

remember_key(undefined, _Pid) ->
    ok;
remember_key(Key, Pid) ->
    ets:insert(briskd_nicks, {Key, Pid}),
    ok.

%% Keep the most recent user identity for lookup after a nickname is released.
save_whowas(#client{nick = Nick, user = User, host = Host, real = Real}, Server) when
    is_binary(User), is_binary(Real)
->
    Time = erlang:system_time(second),
    Fold = briskd_wire:fold(Nick),
    Key = {Fold, -Time, erlang:unique_integer([positive])},
    mnesia:dirty_write(#whowas{
        key = Key,
        nick = Nick,
        user = User,
        host = Host,
        real = Real,
        server = Server,
        time = Time
    }),
    trim_whowas(Fold).

%% Bound WHOWAS: the newest entries per nickname, then a total cap.
trim_whowas(Fold) ->
    %% Match specs use the raw tuple: '_' is not a valid typed record field.
    %% #whowas{} is {whowas, Key, Nick, User, Host, Real, Server, Time}.
    Mine = mnesia:dirty_select(whowas, [
        {{whowas, {Fold, '_', '_'}, '_', '_', '_', '_', '_', '_'}, [], [{element, 2, '$_'}]}
    ]),
    lists:foreach(
        fun(Key) -> mnesia:dirty_delete(whowas, Key) end,
        drop_newest(?WHOWAS_PER_NICK, Mine)
    ),
    case mnesia:table_info(whowas, size) > ?WHOWAS_MAX of
        true ->
            All = mnesia:dirty_select(whowas, [
                {{whowas, '$1', '_', '_', '_', '_', '_', '$2'}, [], [{{'$2', '$1'}}]}
            ]),
            Oldest = lists:sublist(lists:sort(All), ?WHOWAS_MAX div 10 + 1),
            lists:foreach(fun({_, Key}) -> mnesia:dirty_delete(whowas, Key) end, Oldest);
        false ->
            ok
    end.

%% Keys are {Fold, -Time, Unique}, so ascending order is newest first.
drop_newest(Keep, Keys) ->
    case length(Keys) > Keep of
        true -> lists:nthtail(Keep, lists:sort(Keys));
        false -> []
    end.
