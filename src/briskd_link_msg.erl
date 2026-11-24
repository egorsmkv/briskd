-module(briskd_link_msg).
-moduledoc """
Server-link message ingress (`PRIVMSG`, `NOTICE`, `TAGMSG`, `SQUERY`) and
outbound channel message propagation.
""".
-export([
    note_remote_direct/7,
    propagate_channel_message/5,
    receive_remote_message/4,
    receive_remote_message/5,
    trusted_server_tags/1
]).
-include("briskd_client.hrl").
-include("briskd_channel.hrl").
-include("briskd_remote.hrl").

-doc """
Deliver a `PRIVMSG`, `NOTICE`, `TAGMSG`, or `SQUERY` from a remote user,
without message tags.

Same as `receive_remote_message/5` with an empty tag list.
""".
-spec receive_remote_message(binary(), binary(), binary(), [binary()]) ->
    ok
    | {error,
        invalid_remote_message
        | malformed_remote_prefix
        | remote_prefix_mismatch
        | remote_user_not_on_channel
        | unknown_remote_channel
        | unknown_remote_source}.
receive_remote_message(Peer, Prefix, Command, Params) ->
    receive_remote_message(Peer, Prefix, Command, Params, []).

-doc """
Deliver a `PRIVMSG`, `NOTICE`, or `TAGMSG` from a remote user to its target.

`Peer` is the adjacent link the line arrived on and `Prefix` its source
prefix, which must be the exact `nick!user@host` of a remote user reached
through `Peer`. `Params` is the target
and text (`TAGMSG` needs only the target). Only a `msgid` of at most 64 bytes
without space or colon, a valid `time`, and client-only tags are kept from
`Tags`.

- A local nickname receives the message, and it is stored in that user's
  direct-message history.
- A channel is delivered to local members when the sender is a member
  through `Peer`, is not banned (unless an exception matches), and may speak
  under `+m`; a `+a` channel shows the anonymous prefix. The message is saved
  in channel history and forwarded to the other peers that have members.
- A remote nickname has the message forwarded to its link, unless that link
  is `Peer`.

An unknown target is dropped with `ok`. Errors: `invalid_remote_message`,
`malformed_remote_prefix`, `remote_prefix_mismatch`, `unknown_remote_source`,
`unknown_remote_channel`, and `remote_user_not_on_channel`.
""".
-spec receive_remote_message(binary(), binary(), binary(), [binary()], [
    {binary(), undefined | binary()}
]) ->
    ok
    | {error,
        invalid_remote_message
        | malformed_remote_prefix
        | remote_prefix_mismatch
        | remote_user_not_on_channel
        | unknown_remote_channel
        | unknown_remote_source}.
receive_remote_message(Peer, Prefix, <<"TAGMSG">>, [Target | _], Tags) ->
    relay_remote_message(Peer, Prefix, <<"TAGMSG">>, Target, none, Tags);
receive_remote_message(Peer, Prefix, Command, [Target, Text | _], Tags) ->
    relay_remote_message(Peer, Prefix, Command, Target, Text, Tags);
receive_remote_message(_Peer, _Prefix, _Command, _Params, _Tags) ->
    {error, invalid_remote_message}.

relay_remote_message(Peer, Prefix, Command, Target, Text, Tags) ->
    ClientTags = trusted_server_tags(Tags) ++ briskd_cap:client_tags(Tags),
    case binary:split(Prefix, <<"!">>) of
        [Nick, _UserHost] ->
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
                [
                    #remote_client{
                        peer = Peer,
                        nick = Nick,
                        user = User,
                        host = Host
                    } = Remote
                ] ->
                    ExpectedPrefix = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
                    case Prefix =:= ExpectedPrefix of
                        true ->
                            receive_remote_target(
                                Peer, Remote, Prefix, Target, Text, Command, ClientTags
                            );
                        false ->
                            {error, remote_prefix_mismatch}
                    end;
                _ ->
                    {error, unknown_remote_source}
            end;
        _ ->
            {error, malformed_remote_prefix}
    end.

-doc """
Keep only trusted `msgid` (<= 64 bytes, no space or colon) and valid `time`
tags from a configured peer's message.
""".
-spec trusted_server_tags([{binary(), undefined | binary()}]) ->
    [{binary(), undefined | binary()}].
trusted_server_tags(Tags) ->
    MsgId =
        case lists:keyfind(<<"msgid">>, 1, Tags) of
            {_, Id} when is_binary(Id), byte_size(Id) =< 64 ->
                case binary:match(Id, [<<" ">>, <<":">>]) of
                    nomatch -> [{<<"msgid">>, Id}];
                    _ -> []
                end;
            _ ->
                []
        end,
    Time =
        case lists:keyfind(<<"time">>, 1, Tags) of
            {_, Stamp} when is_binary(Stamp) ->
                case briskd_state_history:parse_timestamp(Stamp) of
                    {ok, _} -> [{<<"time">>, Stamp}];
                    error -> []
                end;
            _ ->
                []
        end,
    MsgId ++ Time.

receive_remote_target(Peer, Remote, Prefix, Target, Text, Command, Tags) ->
    case briskd_state_client:find_nick(Target) of
        #client{pid = Pid, nick = LocalNick} ->
            briskd_state_send:send(Pid, Prefix, Command, [LocalNick], Text, Tags),
            note_remote_direct(Remote, Prefix, Command, LocalNick, Text, Tags, Pid),
            ok;
        undefined ->
            case briskd_wire:channel(Target) of
                true ->
                    %% A message rejected here (unknown channel, sender not
                    %% a member through Peer) is not passed on to other peers.
                    case
                        receive_remote_channel_message(
                            Peer, Remote, Prefix, Target, Text, Command, Tags
                        )
                    of
                        ok -> forward_channel(Peer, Target, Prefix, Command, Text, Tags);
                        {error, _} = Error -> Error
                    end;
                false ->
                    forward_user(Peer, Prefix, Command, Target, Text, Tags)
            end
    end.

-doc """
Keep the recipient's copy of a direct message from a remote user.
""".
-spec note_remote_direct(
    #remote_client{},
    binary(),
    binary(),
    binary(),
    none | binary() | {multiline, [{boolean(), binary()}]},
    [{binary(), undefined | binary()}],
    pid()
) -> ok.
note_remote_direct(
    #remote_client{account = From, nick = FromNick}, Prefix, Command, Target, Text, Tags, Pid
) ->
    Time =
        case lists:keyfind(<<"time">>, 1, Tags) of
            {_, Stamp} when is_binary(Stamp) ->
                case briskd_state_history:parse_timestamp(Stamp) of
                    {ok, T} -> T;
                    error -> erlang:system_time(millisecond)
                end;
            _ ->
                erlang:system_time(millisecond)
        end,
    MsgId =
        case lists:keyfind(<<"msgid">>, 1, Tags) of
            {_, Id} -> Id;
            false -> undefined
        end,
    briskd_state_history:note_direct(
        {From, FromNick},
        {briskd_state_v3:account(Pid), Target},
        Target,
        briskd_state_history:entry(
            Command, Prefix, Text, MsgId, Time, briskd_cap:client_tags(Tags), From
        )
    ).

forward_user(Ingress, Prefix, Command, Target, Text, Tags) ->
    case mnesia:dirty_read(remote_client, briskd_wire:fold(Target)) of
        [#remote_client{peer = Dest, nick = Nick}] ->
            case briskd_route:should_forward(Ingress, Dest) of
                true ->
                    Line = briskd_wire:message(Tags, Prefix, Command, [Nick], Text),
                    _ = briskd_links:send(Dest, Line),
                    ok;
                false ->
                    ok
            end;
        [] ->
            ok
    end.

forward_channel(Ingress, Name, Prefix, Command, Text, Tags) ->
    case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Line = iolist_to_binary(briskd_wire:message(Tags, Prefix, Command, [Name], Text)),
            Peers = lists:usort([MemberPeer || _Nick := {MemberPeer, _} <- Members]),
            lists:foreach(
                fun(Dest) ->
                    case briskd_route:should_forward(Ingress, Dest) of
                        true -> _ = briskd_links:send(Dest, Line);
                        false -> ok
                    end
                end,
                Peers
            );
        [] ->
            ok
    end.

receive_remote_channel_message(_Peer, _Remote, _Prefix, <<$&, _/binary>>, _Text, _Command, _Tags) ->
    {error, unknown_remote_channel};
receive_remote_channel_message(Peer, Remote, Prefix, Name, Text, Command, Tags) ->
    Key = briskd_wire:fold(Name),
    case {mnesia:dirty_read(remote_channel, Key), mnesia:dirty_read(channel, Key)} of
        {[#remote_channel{members = RemoteMembers, flags = RemoteFlags}], [#channel{} = Channel]} ->
            NickKey = Remote#remote_client.key,
            case RemoteMembers of
                #{NickKey := {Peer, Roles}} ->
                    Flags = maps:merge(RemoteFlags, Channel#channel.flags),
                    Banned =
                        briskd_state_channel:mask_matches(Channel, ban, Remote) andalso
                            not briskd_state_channel:mask_matches(Channel, exception, Remote),
                    Allowed =
                        not maps:is_key($m, Flags) orelse
                            lists:member(operator, Roles) orelse lists:member(voice, Roles),
                    case Allowed andalso not Banned of
                        true ->
                            Origin =
                                case maps:is_key($a, Flags) of
                                    true -> <<"anonymous!anonymous@anonymous.">>;
                                    false -> Prefix
                                end,
                            briskd_state_send:broadcast(
                                maps:keys(Channel#channel.members),
                                Origin,
                                Command,
                                [Name],
                                Text,
                                Tags
                            ),
                            briskd_state_channel:note_channel_history(
                                Channel#channel.key, Command, Origin, Text, Tags
                            );
                        false ->
                            ok
                    end;
                #{} ->
                    {error, remote_user_not_on_channel}
            end;
        {[#remote_channel{members = RemoteMembers}], []} ->
            case maps:find(Remote#remote_client.key, RemoteMembers) of
                {ok, {Peer, _Roles}} -> ok;
                _ -> {error, remote_user_not_on_channel}
            end;
        {[], _} ->
            {error, unknown_remote_channel};
        {_, []} ->
            {error, unknown_remote_channel}
    end.

-doc """
Send a local user's channel `PRIVMSG`, `NOTICE`, or `TAGMSG` to every peer
that has members of channel `Name`.

`Tags` are the message tags to put on the server line.
""".
-spec propagate_channel_message(binary(), none | iodata(), binary(), #client{}, [
    {binary(), undefined | binary()}
]) -> ok.
propagate_channel_message(<<$&, _/binary>>, _Text, _Command, _Client, _Tags) ->
    ok;
propagate_channel_message(Name, Text, Command, Client, Tags) ->
    case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Line = iolist_to_binary(
                briskd_wire:message(Tags, briskd_state_send:prefix(Client), Command, [Name], Text)
            ),
            Peers = lists:usort([Peer || _Nick := {Peer, _Roles} <- Members]),
            lists:foreach(fun(Peer) -> _ = briskd_links:send(Peer, Line) end, Peers),
            ok;
        [] ->
            ok
    end.
