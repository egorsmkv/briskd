-module(briskd_channel_names).
-moduledoc """
Channel `TOPIC` and `NAMES` queries, visibility rules, and `RPL_NAMREPLY`
packetization.
""".
-export([
    join_topic/3,
    names/3,
    names_lines/6,
    names_listing/3,
    names_unattached/2,
    topic/4,
    visible_member/3
]).
-include("briskd_client.hrl").
-include("briskd_channel.hrl").
-include("briskd_remote.hrl").

-doc """
Handle `TOPIC <channel> [:<topic>]` (RFC 2812 section 3.2.4).

Retrieves the current topic (`331` / `332` and `333`) or updates it (`+t`
requires channel operator status `482`, non-members get `442`, hidden `+p`/`+s`
channels get `403`). When updated, `TOPIC` is broadcast to members, recorded in
history, and propagated to peers.
""".
-spec topic(binary(), [binary()], #client{}, binary()) -> ok.
topic(Name, Rest, #client{pid = Pid} = Client, Server) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, flags = Flags} = Channel] ->
            Operator = lists:member(operator, maps:get(Pid, Members, [])),
            Hidden =
                (maps:is_key($s, Flags) orelse maps:is_key($p, Flags)) andalso
                    not maps:is_key(Pid, Members),
            case {Hidden, maps:is_key(Pid, Members), Rest} of
                {true, _, _} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"403">>, [Canonical], <<"No such channel">>
                    );
                {false, false, [_ | _]} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                {false, _, []} ->
                    topic_reply(effective_topic(Channel), Client, Server);
                {false, true, [_ | _]} when is_map_key($t, Flags), not Operator ->
                    briskd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    );
                {false, true, [Text | _]} ->
                    Origin = briskd_channel_mode:channel_origin_prefix(Channel, Client),
                    UpdatedTopic = Channel#channel{
                        topic = briskd_wire:retain(Text),
                        topic_by = iolist_to_binary(Origin),
                        topic_at = erlang:system_time(second)
                    },
                    mnesia:dirty_write(UpdatedTopic),
                    briskd_state_link:note_local_channel(UpdatedTopic),
                    {TopicTags, TopicMeta} = briskd_state_history:event_tags(),
                    briskd_state_history:note_event(
                        Channel#channel.key,
                        <<"TOPIC">>,
                        Origin,
                        [],
                        Text,
                        TopicMeta
                    ),
                    briskd_state_send:broadcast(
                        maps:keys(Members),
                        Origin,
                        <<"TOPIC">>,
                        [Canonical],
                        Text,
                        TopicTags
                    ),
                    briskd_state_link:propagate_topic(Client, Canonical, Text)
            end;
        [] ->
            case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
                [#remote_channel{name = Canonical, flags = RemoteFlags}] ->
                    case {maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags), Rest} of
                        {true, _} ->
                            briskd_state_send:numeric(
                                Client, Server, <<"403">>, [Canonical], <<"No such channel">>
                            );
                        {false, []} ->
                            topic_reply(
                                #channel{
                                    key = briskd_wire:fold(Canonical),
                                    name = Canonical,
                                    topic = maps:get(topic, RemoteFlags, <<>>)
                                },
                                Client,
                                Server
                            );
                        {false, [_ | _]} ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"442">>,
                                [Canonical],
                                <<"You're not on that channel">>
                            )
                    end;
                [] ->
                    briskd_state_send:numeric(
                        Client, Server, <<"403">>, [Name], <<"No such channel">>
                    )
            end
    end.

effective_topic(#channel{name = Name, topic = <<>>} = Channel) ->
    case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
        [#remote_channel{flags = RemoteFlags}] ->
            Channel#channel{topic = maps:get(topic, RemoteFlags, <<>>)};
        [] ->
            Channel
    end;
effective_topic(Channel) ->
    Channel.

-doc "Send the channel topic on `JOIN` if set.".
-spec join_topic(#channel{}, #client{}, binary()) -> ok.
join_topic(Channel, Client, Server) ->
    case effective_topic(Channel) of
        #channel{topic = <<>>} -> ok;
        WithTopic -> topic_reply(WithTopic, Client, Server)
    end.

topic_reply(#channel{name = Name, topic = <<>>}, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"331">>, [Name], <<"No topic is set">>);
topic_reply(#channel{name = Name, topic = Topic} = Channel, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"332">>, [Name], Topic),
    By =
        case Channel#channel.topic_by of
            undefined -> Server;
            Setter -> Setter
        end,
    At =
        case {Channel#channel.topic_at, Channel#channel.created} of
            {undefined, undefined} -> persistent_term:get({briskd_state, started_at_system}, 0);
            {undefined, Created} -> Created;
            {Time, _} -> Time
        end,
    briskd_state_send:numeric(Client, Server, <<"333">>, [Name, By, integer_to_binary(At)], none).

-doc """
Handle `NAMES` for one channel (RFC 2812 section 3.2.5).

Sends 353 RPL_NAMREPLY lines with local and remote members, sorted under the
RFC 1459 case mapping, then 366 RPL_ENDOFNAMES. A `+p` or `+s` channel the
requester is not on lists nobody; an anonymous `+a` channel lists only the
requester; members with `+i` are listed only to requesters sharing a channel.
Prefixes follow `multi-prefix`, and `userhost-in-names` adds `!user@host`.
An unknown channel still gets 366.
""".
-spec names(binary(), #client{}, binary()) -> ok.
names(Name, Client, Server) ->
    Canonical =
        case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
            [#channel{name = Existing, members = Members, flags = Flags}] ->
                LocalMember = maps:is_key(Client#client.pid, Members),
                RemoteFlags = briskd_state_link:remote_channel_flags(Name),
                Hidden =
                    (not LocalMember andalso
                        (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))) orelse
                        (not LocalMember andalso
                            (maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags))),
                case Hidden of
                    true ->
                        ok;
                    false ->
                        VisiblePids =
                            case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                                true ->
                                    case maps:is_key(Client#client.pid, Members) of
                                        true -> [Client#client.pid];
                                        false -> []
                                    end;
                                false ->
                                    maps:keys(Members)
                            end,
                        LocalEntries = [
                            display_nick(
                                briskd_state_client:client(Pid), maps:get(Pid, Members), Client
                            )
                         || Pid <- VisiblePids,
                            visible_member(Pid, Client, Members)
                        ],
                        RemoteEntries =
                            case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                                true ->
                                    [];
                                false ->
                                    briskd_state_link:remote_names_entries(
                                        Name, Client, LocalMember
                                    )
                            end,
                        Entries = lists:usort(fun nick_less/2, LocalEntries ++ RemoteEntries),
                        names_lines(Entries, [], 0, Existing, Client, Server)
                end,
                Existing;
            [] ->
                case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
                    [#remote_channel{name = Existing, flags = Flags}] ->
                        case
                            maps:is_key($p, Flags) orelse maps:is_key($s, Flags) orelse
                                maps:is_key($a, Flags)
                        of
                            true ->
                                ok;
                            false ->
                                names_lines(
                                    briskd_state_link:remote_names_entries(Name, Client, false),
                                    [],
                                    0,
                                    Existing,
                                    Client,
                                    Server
                                )
                        end,
                        Existing;
                    [] ->
                        Name
                end
        end,
    briskd_state_send:numeric(Client, Server, <<"366">>, [Canonical], <<"End of NAMES list">>).

-doc """
Send the 353 RPL_NAMREPLY lines for one local channel in an argument-less `NAMES`.

`Key` is the folded channel name. Applies the same visibility rules as
`names/3` but sends nothing for hidden channels and no 366; the caller ends
the listing.
""".
-spec names_listing(binary(), #client{}, binary()) -> ok.
names_listing(Key, Client, Server) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{name = Name, members = Members, flags = Flags}] ->
            RemoteFlags = briskd_state_link:remote_channel_flags(Name),
            LocalMember = maps:is_key(Client#client.pid, Members),
            Visible =
                LocalMember orelse
                    not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags) orelse
                        maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags)),

            case Visible of
                true ->
                    VisiblePids =
                        case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                            true ->
                                case maps:is_key(Client#client.pid, Members) of
                                    true -> [Client#client.pid];
                                    false -> []
                                end;
                            false ->
                                maps:keys(Members)
                        end,
                    LocalEntries = [
                        display_nick(
                            briskd_state_client:client(Pid), maps:get(Pid, Members), Client
                        )
                     || Pid <- VisiblePids,
                        visible_member(Pid, Client, Members)
                    ],
                    RemoteEntries =
                        case maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags) of
                            true ->
                                [];
                            false ->
                                briskd_state_link:remote_names_entries(Name, Client, LocalMember)
                        end,
                    Entries = lists:usort(fun nick_less/2, LocalEntries ++ RemoteEntries),
                    names_lines(Entries, [], 0, Name, Client, Server);
                false ->
                    ok
            end;
        [] ->
            ok
    end.

nick_less(Left, Right) -> briskd_wire:fold(Left) =< briskd_wire:fold(Right).

-doc """
List visible registered local users who are on no channel, under the `*` channel.

Part of an argument-less `NAMES`. A user who is only on secret or private
channels is not listed. Sends 353 RPL_NAMREPLY lines only.
""".
-spec names_unattached(#client{}, binary()) -> ok.
names_unattached(#client{pid = RequesterPid}, Server) ->
    Requester = briskd_state_client:client(RequesterPid),
    Entries = lists:sort([
        Member#client.nick
     || Pid <- briskd_state_client:pids(),
        [#client{} = Member] <- [mnesia:dirty_read(client, Pid)],
        briskd_state_client:ready(Member),
        briskd_state_client:user_visible(Member, Requester),
        %% Only users on no channel are listed under `*`; a user who is only
        %% in secret or private channels is not revealed.
        Member#client.channels =:= []
    ]),
    names_lines(Entries, [], 0, <<"*">>, Requester, Server).

-doc """
True when channel member `Pid` may be listed to `Requester`.

`Members` is the channel's local member map. A requester on the channel sees
every member; otherwise the rule of `briskd_state_client:user_visible/2`
applies.
""".
-spec visible_member(pid(), #client{}, #{pid() => [channel_role()]}) -> boolean().
visible_member(Pid, Requester, Members) ->
    maps:is_key(Requester#client.pid, Members) orelse
        case mnesia:dirty_read(client, Pid) of
            [#client{} = Member] -> briskd_state_client:user_visible(Member, Requester);
            [] -> false
        end.

-doc """
Send `Entries` as 353 RPL_NAMREPLY lines for channel `Name`.

Call with an empty accumulator and size 0. Entries are packed until a line
would carry about 370 octets of names, so each reply stays under the
512-octet line limit. The channel symbol is `@` for `+s`, `*` for `+p`
(including flags reported by peers), and `=` otherwise. Sends nothing for an
empty list.
""".
-spec names_lines([binary()], [binary()], non_neg_integer(), binary(), #client{}, binary()) -> ok.
names_lines([], [], _, _, _, _) ->
    ok;
names_lines([], Acc, _, Name, Client, Server) ->
    briskd_state_send:numeric(
        Client,
        Server,
        <<"353">>,
        [names_symbol(Name), Name],
        lists:join(<<" ">>, lists:reverse(Acc))
    );
names_lines([Entry | Rest], Acc, Size, Name, Client, Server) when Size + byte_size(Entry) < 370 ->
    names_lines(Rest, [Entry | Acc], Size + byte_size(Entry) + 1, Name, Client, Server);
names_lines(Entries, Acc, _, Name, Client, Server) ->
    names_lines([], Acc, 0, Name, Client, Server),
    names_lines(Entries, [], 0, Name, Client, Server).

names_symbol(<<"*">>) ->
    <<"*">>;
names_symbol(Name) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{flags = Flags}] when is_map_key($s, Flags) -> <<"@">>;
        [#channel{flags = Flags}] when is_map_key($p, Flags) -> <<"*">>;
        _ ->
            case briskd_state_link:remote_channel_flags(Name) of
                Flags when is_map_key($s, Flags) -> <<"@">>;
                Flags when is_map_key($p, Flags) -> <<"*">>;
                _ -> <<"=">>
            end
    end.

%% NAMES entry for a local member as seen by Requester: multi-prefix shows
%% every status prefix and userhost-in-names adds `!user@host`.
display_nick(#client{nick = Nick, user = User, host = Host}, Roles, #client{pid = Requester}) ->
    Name =
        case briskd_cap:enabled(Requester, <<"userhost-in-names">>) of
            true -> <<Nick/binary, "!", User/binary, "@", Host/binary>>;
            false -> Nick
        end,
    <<(briskd_channel_mode:role_prefix(Roles, Requester))/binary, Name/binary>>.
