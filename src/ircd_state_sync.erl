-module(ircd_state_sync).
-moduledoc """
Network-wide IRCv3 state carried over RFC 2813 server links, so that
accounts, metadata, and read markers behave the same on every server.

The functions run inside the `m:ircd_state` process. The wire forms are:

```text
:<server> ACCOUNTSYNC <name> <salt> <iterations> <storedkey> <serverkey> <created> :<certfps>
:<nick!user@host> METADATA <nick> <key> * [:<value>]
:<server> METADATA <#channel> <key> * [:<value>]
:<server> MARKREAD <account> <target> <ms>
```

Binary fields are base64. Peers are configured, authenticated servers, the
same trust level as the rest of the burst. Only SCRAM-SHA-256 verifiers
travel; the email address stays on the server where the account was
registered. When two servers hold the same account name, the one created
first wins everywhere (`ircd_account:import/1`). A `METADATA` line without a
trailing parameter removes the key.

Each received line is applied and then relayed to every other peer with
`ircd_state_link:relay_except/2`, never back to the link it came from.
""".
-export([
    account_created/1,
    burst_lines/1,
    channel_metadata/3,
    markread/3,
    receive_accountsync/3,
    receive_markread/3,
    receive_metadata/3,
    user_metadata/3
]).
-include("ircd_state.hrl").
-include("ircd_account.hrl").

-doc """
Send an `ACCOUNTSYNC` line for a newly usable account to every peer.

The line carries the name, SCRAM salt, iteration count, StoredKey, ServerKey,
creation time, and certificate fingerprints, never the email address.
""".
-spec account_created(#account{}) -> ok.
account_created(Account) ->
    ircd_state_link:server_broadcast(account_line(Account)).

-doc """
Lines describing accounts, metadata, and read markers for a new peer's burst.

The argument (the local server name) is unused. The result lists every
account, then the metadata of each registered local user (prefixed by that
user), then channel metadata (prefixed by this server, leaving out local `&`
channels as `channel_metadata/3` does), then every read marker. Data comes
from dirty Mnesia reads and the `ircd_conn` and `ircd_chan_meta` ETS tables.
""".
-spec burst_lines(binary()) -> [binary()].
burst_lines(_Server) ->
    Accounts = [iolist_to_binary(account_line(A)) || A <- ircd_account:list()],
    UserMeta = [
        iolist_to_binary(metadata_line(ircd_state_send:prefix(Client), Nick, Key, Value))
     || {Pid, Map} <- ets:tab2list(ircd_conn),
        is_map(maps:get(metadata, Map, undefined)),
        [#client{nick = Nick} = Client] <- [mnesia:dirty_read(client, Pid)],
        ircd_state_client:ready(Client),
        {Key, Value} <- maps:to_list(maps:get(metadata, Map))
    ],
    ChannelMeta = [
        iolist_to_binary(metadata_line(server(), Name, Key, Value))
     || {ChannelKey, Map} <- ets:tab2list(ircd_chan_meta),
        [#channel{name = <<First, _/binary>> = Name}] <- [mnesia:dirty_read(channel, ChannelKey)],
        First =/= $&,
        {Key, Value} <- maps:to_list(Map)
    ],
    Markers = [
        iolist_to_binary(markread_line(Account, Target, Time))
     || Key <- mnesia:dirty_all_keys(read_marker),
        [#read_marker{key = {Account, Target}, time = Time}] <- [
            mnesia:dirty_read(read_marker, Key)
        ]
    ],
    Accounts ++ UserMeta ++ ChannelMeta ++ Markers.

account_line(#account{
    name = Name,
    salt = Salt,
    iterations = I,
    stored_key = Stored,
    server_key = ServerKey,
    created = Created,
    certfps = Fps
}) ->
    ircd_wire:line(
        server(),
        <<"ACCOUNTSYNC">>,
        [
            Name,
            base64:encode(Salt),
            integer_to_binary(I),
            base64:encode(Stored),
            base64:encode(ServerKey),
            integer_to_binary(Created)
        ],
        binary:join(Fps, <<",">>)
    ).

-doc """
Apply an `ACCOUNTSYNC` line from the peer `Peer` and relay it.

`Prefix` is the source kept on the relayed line. The parameters are the
account name, base64 salt, iteration count (4096 to 1000000 inclusive),
base64 StoredKey and ServerKey, creation time, and an optional trailing
comma-separated fingerprint list. `ircd_account:import/1` decides the
outcome: a stored account is relayed unchanged to every other peer; a kept
local account (created no later than the incoming one) stops the line here.
Returns `{error, invalid_accountsync}` for a wrong parameter count or any
malformed field.
""".
-spec receive_accountsync(binary(), undefined | binary(), [binary()]) -> ok | {error, term()}.
receive_accountsync(Peer, Prefix, [Name, Salt, I, Stored, ServerKey, Created | Rest]) ->
    try
        true = is_binary(Prefix) andalso ircd_state_link:trusted_server(Peer, Prefix),
        true = ircd_account:valid_name(Name),
        Iterations = binary_to_integer(I),
        true = Iterations >= 4096 andalso Iterations =< 1000000,
        DecodedSalt = base64:decode(Salt),
        DecodedStored = base64:decode(Stored),
        DecodedServerKey = base64:decode(ServerKey),
        true = byte_size(DecodedSalt) > 0 andalso byte_size(DecodedSalt) =< 64,
        true = byte_size(DecodedStored) > 0 andalso byte_size(DecodedStored) =< 64,
        true = byte_size(DecodedServerKey) > 0 andalso byte_size(DecodedServerKey) =< 64,
        Fps =
            case Rest of
                [List | _] -> [F || F <- binary:split(List, <<",">>, [global, trim_all])];
                [] -> []
            end,
        Account = #account{
            key = ircd_wire:fold(Name),
            name = ircd_wire:retain(Name),
            salt = DecodedSalt,
            iterations = Iterations,
            stored_key = DecodedStored,
            server_key = DecodedServerKey,
            email = undefined,
            certfps = [ircd_wire:retain(F) || F <- Fps],
            created = binary_to_integer(Created),
            pending = undefined
        },
        case ircd_account:import(Account) of
            stored ->
                Trailing =
                    case Rest of
                        [Text | _] -> Text;
                        [] -> none
                    end,
                ircd_state_link:relay_except(
                    Peer,
                    ircd_wire:line(
                        Prefix,
                        <<"ACCOUNTSYNC">>,
                        [Name, Salt, I, Stored, ServerKey, Created],
                        Trailing
                    )
                );
            kept ->
                ok
        end,
        ok
    catch
        error:_ -> {error, invalid_accountsync}
    end;
receive_accountsync(_, _, _) ->
    {error, invalid_accountsync}.

-doc """
Broadcast a local user's metadata change to every peer.

`Value` is the new value, or `none` to remove the key. Nothing is sent for a
client that has not finished registration. The line uses the user's
`nick!user@host` prefix so peers can check its source.
""".
-spec user_metadata(#client{}, binary(), none | binary()) -> ok.
user_metadata(#client{nick = Nick} = Client, Key, Value) ->
    case ircd_state_client:ready(Client) of
        true ->
            ircd_state_link:server_broadcast(
                metadata_line(ircd_state_send:prefix(Client), Nick, Key, Value)
            );
        false ->
            ok
    end.

-doc """
Broadcast a channel metadata change to every peer, prefixed by this server.

`Value` is the new value, or `none` to remove the key. Changes on local `&`
channels are never sent.
""".
-spec channel_metadata(binary(), binary(), none | binary()) -> ok.
channel_metadata(Name, Key, Value) ->
    case binary:first(Name) of
        $& -> ok;
        _ -> ircd_state_link:server_broadcast(metadata_line(server(), Name, Key, Value))
    end.

metadata_line(Prefix, Target, Key, none) ->
    ircd_wire:line(Prefix, <<"METADATA">>, [Target, Key, <<"*">>], none);
metadata_line(Prefix, Target, Key, Value) ->
    ircd_wire:line(Prefix, <<"METADATA">>, [Target, Key, <<"*">>], Value).

-doc """
Apply a `METADATA` line from the peer `Peer`, notify local subscribers, and
relay it to the other peers.

The parameters are the target, the key, a visibility field (ignored), and an
optional value; a missing value removes the key. A channel target goes to
`ircd_state_meta:remote_channel_change/4`. For a user target, the nickname in
`Prefix` must be the target itself and the target must be a remote user
reached through `Peer`; otherwise the result is
`{error, metadata_source_mismatch}`. Errors from `m:ircd_state_meta` are
returned unchanged, and a short parameter list is
`{error, invalid_metadata}`.
""".
-spec receive_metadata(binary(), undefined | binary(), [binary()]) -> ok | {error, term()}.
receive_metadata(Peer, Prefix, [Target, Key, _Visibility | Rest]) ->
    Value =
        case Rest of
            [V | _] -> ircd_wire:retain(V);
            [] -> none
        end,
    Result =
        case ircd_wire:channel(Target) of
            true ->
                case
                    is_binary(Prefix) andalso
                        (ircd_state_link:trusted_server(Peer, Prefix) orelse
                            is_tuple(ircd_state_link:remote_source(Peer, Prefix)))
                of
                    true -> ircd_state_meta:remote_channel_change(Target, Key, Value, Prefix);
                    false -> {error, metadata_source_mismatch}
                end;
            false ->
                remote_user_change(Peer, Target, Key, Value, Prefix)
        end,
    case Result of
        ok ->
            ircd_state_link:relay_except(
                Peer, metadata_line(Prefix, Target, Key, Value)
            ),
            ok;
        Error ->
            Error
    end;
receive_metadata(_, _, _) ->
    {error, invalid_metadata}.

%% A user's metadata may only be changed by that user's own prefix, and only
%% through the link the user is reached by.
remote_user_change(Peer, Target, Key, Value, Prefix) when is_binary(Prefix) ->
    case ircd_state_link:remote_source(Peer, Prefix) of
        {ok, #remote_client{nick = Actual}} ->
            case ircd_wire:fold(Target) =:= ircd_wire:fold(Actual) of
                true -> ircd_state_meta:remote_user_change(Target, Key, Value, Prefix);
                false -> {error, metadata_source_mismatch}
            end;
        error ->
            {error, metadata_source_mismatch}
    end;
remote_user_change(_, _, _, _, _) ->
    {error, metadata_source_mismatch}.

-doc """
Broadcast to every peer that `Account`'s read marker for `Target` moved to
`Time` (milliseconds since the Unix epoch).
""".
-spec markread(binary(), binary(), integer()) -> ok.
markread(Account, Target, Time) ->
    ircd_state_link:server_broadcast(markread_line(Account, Target, Time)).

markread_line(Account, Target, Time) ->
    ircd_wire:line(server(), <<"MARKREAD">>, [Account, Target, integer_to_binary(Time)], none).

-doc """
Apply a `MARKREAD <account> <target> <ms>` line from the peer `Peer` and relay
it when it moved the marker forward.

The target must pass `ircd_state_history:valid_marker_target/1` and the time
must be a decimal integer, otherwise the result is
`{error, invalid_markread}`. A marker that is not newer than the stored one
is accepted but not relayed.
""".
-spec receive_markread(binary(), undefined | binary(), [binary()]) -> ok | {error, term()}.
receive_markread(Peer, Prefix, [Account, Target, Raw | _]) ->
    case
        is_binary(Prefix) andalso ircd_state_link:trusted_server(Peer, Prefix) andalso
            ircd_account:valid_name(Account) andalso
            ircd_state_history:valid_marker_target(Target)
    of
        true -> receive_valid_markread(Peer, Prefix, Account, Target, Raw);
        false -> {error, invalid_markread}
    end;
receive_markread(_, _, _) ->
    {error, invalid_markread}.

receive_valid_markread(Peer, Prefix, Account, Target, Raw) ->
    try binary_to_integer(Raw) of
        Time when Time >= 0 ->
            case ircd_state_history:remote_marker(Account, Target, Time) of
                updated ->
                    ircd_state_link:relay_except(
                        Peer, ircd_wire:line(Prefix, <<"MARKREAD">>, [Account, Target, Raw], none)
                    );
                unchanged ->
                    ok
            end,
            ok;
        _ ->
            {error, invalid_markread}
    catch
        error:badarg -> {error, invalid_markread}
    end.

server() ->
    maps:get(name, persistent_term:get({ircd_state, config})).
