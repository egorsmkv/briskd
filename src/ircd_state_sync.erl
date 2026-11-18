-module(ircd_state_sync).
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

%% @doc Network-wide IRCv3 state carried over RFC 2813 server links, so that
%% accounts, metadata, and read markers behave the same on every server:
%%
%%   :<server> ACCOUNTSYNC <name> <salt> <iterations> <storedkey> <serverkey>
%%       <created> :<certfps>
%%   :<nick!user@host> METADATA <nick> <key> * [:<value>]
%%   :<server> METADATA <#channel> <key> * [:<value>]
%%   :<server> MARKREAD <account> <target> <ms>
%%
%% Binary fields are base64. Peers are configured, authenticated servers, the
%% same trust level as the rest of the burst. Only SCRAM verifiers travel; the
%% email address stays on the server where the account was registered. When two
%% servers hold the same account name, the one created first wins everywhere.
%% A value without a trailing parameter removes the metadata key.

%% @doc Announce a usable account to every peer.
-spec account_created(#account{}) -> ok.
account_created(Account) ->
    ircd_state_link:server_broadcast(account_line(Account)).

%% @doc Accounts, metadata, and read markers for a new peer's burst.
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
        [#channel{name = Name}] <- [mnesia:dirty_read(channel, ChannelKey)],
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
        iolist_to_binary(lists:join(<<",">>, Fps))
    ).

%% @doc Apply an account replicated by a peer and pass it on.
-spec receive_accountsync(binary(), undefined | binary(), [binary()]) -> ok | {error, term()}.
receive_accountsync(Peer, Prefix, [Name, Salt, I, Stored, ServerKey, Created | Rest]) ->
    try
        true = ircd_account:valid_name(Name),
        Iterations = binary_to_integer(I),
        true = Iterations >= 4096 andalso Iterations =< 1000000,
        Fps =
            case Rest of
                [List | _] -> [F || F <- binary:split(List, <<",">>, [global, trim_all])];
                [] -> []
            end,
        Account = #account{
            key = ircd_wire:fold(Name),
            name = ircd_wire:retain(Name),
            salt = base64:decode(Salt),
            iterations = Iterations,
            stored_key = base64:decode(Stored),
            server_key = base64:decode(ServerKey),
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

%% @doc A local user's metadata key changed (`none` removes it).
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

%% @doc A channel metadata key changed (`none` removes it).
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

%% @doc Apply metadata from a peer, notify local subscribers, and relay it.
-spec receive_metadata(binary(), undefined | binary(), [binary()]) -> ok | {error, term()}.
receive_metadata(Peer, Prefix, [Target, Key, _Visibility | Rest]) ->
    Value =
        case Rest of
            [V | _] -> ircd_wire:retain(V);
            [] -> none
        end,
    Result =
        case ircd_wire:channel(Target) of
            true -> ircd_state_meta:remote_channel_change(Target, Key, Value, Prefix);
            false -> remote_user_change(Peer, Target, Key, Value, Prefix)
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
remote_user_change(Peer, Target, Key, Value, Prefix) ->
    case
        {
            binary:split(Prefix, <<"!">>),
            mnesia:dirty_read(remote_client, ircd_wire:fold(Target))
        }
    of
        {[Nick, _], [#remote_client{peer = Peer, nick = Actual}]} ->
            case ircd_wire:fold(Nick) =:= ircd_wire:fold(Actual) of
                true -> ircd_state_meta:remote_user_change(Target, Key, Value, Prefix);
                false -> {error, metadata_source_mismatch}
            end;
        _ ->
            {error, metadata_source_mismatch}
    end.

%% @doc A read marker moved forward on this server.
-spec markread(binary(), binary(), integer()) -> ok.
markread(Account, Target, Time) ->
    ircd_state_link:server_broadcast(markread_line(Account, Target, Time)).

markread_line(Account, Target, Time) ->
    ircd_wire:line(server(), <<"MARKREAD">>, [Account, Target, integer_to_binary(Time)], none).

%% @doc Apply a read marker from a peer when it is newer, and relay it.
-spec receive_markread(binary(), undefined | binary(), [binary()]) -> ok | {error, term()}.
receive_markread(Peer, Prefix, [Account, Target, Raw | _]) ->
    try binary_to_integer(Raw) of
        Time ->
            case ircd_state_history:remote_marker(Account, Target, Time) of
                updated ->
                    ircd_state_link:relay_except(
                        Peer, ircd_wire:line(Prefix, <<"MARKREAD">>, [Account, Target, Raw], none)
                    );
                unchanged ->
                    ok
            end,
            ok
    catch
        error:badarg -> {error, invalid_markread}
    end;
receive_markread(_, _, _) ->
    {error, invalid_markread}.

server() ->
    maps:get(name, persistent_term:get({ircd_state, config})).
