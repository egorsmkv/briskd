-module(briskd_channel_invite).
-moduledoc """
Channel `KNOCK` and `INVITE` handling (including `invite-notify` and remote
invite forwarding).
""".
-export([invite/4, knock/4]).
-include("briskd_client.hrl").
-include("briskd_channel.hrl").
-include("briskd_remote.hrl").

-doc """
Handle `KNOCK <channel> [:<message>]`.

Replies 403 for an unknown channel, 714 when already on it, 480 on `+K` or a
non-invite-only channel, and 713 when open without `+i`, `+k`, or `+l`. 713
and 714 are the numerics common ircds use for `KNOCK`; they are not assigned
by RFC 2812. Otherwise the local channel operators receive `KNOCK <channel>
:<message>` from the requester.
""".
-spec knock(binary(), [binary()], #client{}, binary()) -> ok.
knock(Name, ReasonParams, #client{pid = Pid} = Client, Server) ->
    Reason =
        case ReasonParams of
            [Text | _] -> Text;
            [] -> <<>>
        end,
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        [#channel{name = Canonical, members = Members, flags = Flags} = Channel] ->
            Open =
                Channel#channel.password =:= undefined andalso
                    Channel#channel.limit =:= undefined,
            case maps:is_key(Pid, Members) of
                true ->
                    briskd_state_send:numeric(
                        Client, Server, <<"714">>, [Canonical], <<"You're already on that channel">>
                    );
                false ->
                    case {maps:is_key($K, Flags), maps:is_key($i, Flags)} of
                        {false, false} when Open ->
                            briskd_state_send:numeric(
                                Client, Server, <<"713">>, [Canonical], <<"Channel is open">>
                            );
                        {true, _} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"480">>,
                                [Canonical],
                                <<"Cannot knock on channel">>
                            );
                        {false, false} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"480">>,
                                [Canonical],
                                <<"Channel is not invite-only">>
                            );
                        {false, true} ->
                            Operators = [
                                MemberPid
                             || MemberPid := Roles <- Members, lists:member(operator, Roles)
                            ],
                            case Operators of
                                [] ->
                                    briskd_state_send:numeric(
                                        Client,
                                        Server,
                                        <<"480">>,
                                        [Canonical],
                                        <<"No channel operators available">>
                                    );
                                _ ->
                                    briskd_state_send:broadcast(
                                        Operators,
                                        briskd_channel_mode:channel_origin_prefix(Channel, Client),
                                        <<"KNOCK">>,
                                        [Canonical],
                                        Reason
                                    ),
                                    ok
                            end
                    end
            end
    end.

-doc """
Handle `INVITE <nick> <channel>` (RFC 2812 section 3.2.7).

A local user still registering, or an unknown nickname, gets 401
ERR_NOSUCHNICK. For a local target: an existing channel requires that the
target is not already on it (443 ERR_USERONCHANNEL), that the inviter is on it
(442 ERR_NOTONCHANNEL), and, with `+i`, that the inviter is an operator (482
ERR_CHANOPRIVSNEEDED); the invite is then remembered on the channel and
`invite-notify` members are told. The inviter gets 341 RPL_INVITING (and 301
RPL_AWAY for an away target) and the target receives `INVITE`. An invite to a
channel that does not exist is delivered without checks. A remote target
requires an existing local channel (403 otherwise) and the same membership and
operator checks; the invite is remembered and forwarded to the target's link.
""".
-spec invite(binary(), binary(), #client{}, binary()) -> ok.
invite(Nick, Name, #client{pid = Pid} = Client, Server) ->
    Found =
        case briskd_state_client:find_nick(Nick) of
            #client{} = Local ->
                case briskd_state_client:ready(Local) of
                    true -> Local;
                    false -> held
                end;
            undefined ->
                undefined
        end,
    case Found of
        held ->
            briskd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>);
        undefined ->
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
                [#remote_client{} = Remote] ->
                    invite_remote(Remote, Name, Client, Server);
                [] ->
                    briskd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>)
            end;
        #client{} = Target ->
            case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
                [] ->
                    notify_invite(Target, Name, Client, Server);
                [
                    #channel{
                        name = Canonical,
                        members = Members,
                        flags = Flags,
                        invited = Invited
                    } = Channel
                ] ->
                    IsMember = maps:is_key(Pid, Members),
                    IsOperator = lists:member(operator, maps:get(Pid, Members, [])),
                    case
                        {
                            maps:is_key(Target#client.pid, Members),
                            IsMember,
                            maps:is_key($i, Flags) andalso not IsOperator
                        }
                    of
                        {true, _, _} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"443">>,
                                [Target#client.nick, Canonical],
                                <<"is already on channel">>
                            );
                        {false, false, _} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"442">>,
                                [Canonical],
                                <<"You're not on that channel">>
                            );
                        {false, true, true} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"482">>,
                                [Canonical],
                                <<"You're not channel operator">>
                            );
                        {false, true, false} ->
                            AliveInvited = [P || P <- Invited, is_process_alive(P)],
                            mnesia:dirty_write(Channel#channel{
                                invited =
                                    lists:usort([Target#client.pid | AliveInvited])
                            }),
                            briskd_state_channel:note_invited(
                                Target#client.pid, Channel#channel.key
                            ),
                            notify_invite(Target, Canonical, Client, Server),
                            briskd_state_v3:invite_notify(
                                Channel,
                                Target,
                                Target#client.nick,
                                {Pid, invite_origin_prefix(Canonical, Client)}
                            )
                    end
            end
    end.

invite_remote(
    #remote_client{nick = RemoteNick, peer = Dest},
    Name,
    #client{pid = Pid} = Client,
    Server
) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>);
        [#channel{name = Canonical, members = Members, flags = Flags}] ->
            IsMember = maps:is_key(Pid, Members),
            IsOperator = lists:member(operator, maps:get(Pid, Members, [])),
            case {IsMember, maps:is_key($i, Flags) andalso not IsOperator} of
                {false, _} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                {true, true} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    );
                {true, false} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"341">>, [RemoteNick, Canonical], none
                    ),
                    briskd_state_link:propagate_invite(Client, RemoteNick, Canonical, Dest)
            end
    end.

notify_invite(
    #client{pid = TargetPid, nick = TargetNick, away = Away},
    Channel,
    Client,
    Server
) ->
    briskd_state_send:numeric(Client, Server, <<"341">>, [TargetNick, Channel], none),
    briskd_state_send:send(
        TargetPid, invite_origin_prefix(Channel, Client), <<"INVITE">>, [TargetNick, Channel], none
    ),
    case Away of
        undefined -> ok;
        _ -> briskd_state_send:numeric(Client, Server, <<"301">>, [TargetNick], Away)
    end.

invite_origin_prefix(Channel, Client) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Channel)) of
        [#channel{} = Record] -> briskd_channel_mode:channel_origin_prefix(Record, Client);
        [] -> briskd_state_send:prefix(Client)
    end.
