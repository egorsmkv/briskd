-module(briskd_channel_admin).
-moduledoc """
Administrative channel operations (`admin_create/3`, `admin_destroy/3`,
`admin_mode/4`) and `draft/channel-rename` (`RENAME`) handler.

Runs inside the `m:briskd_state` process.
""".
-export([
    admin_create/3,
    admin_destroy/3,
    admin_mode/4,
    rename/3
]).
-include("briskd_state.hrl").

-doc """
Create the empty channel `Name` with `Topic` for the admin panel
(`briskdctl create-channel`).
""".
-spec admin_create(binary(), binary(), binary()) ->
    {ok, binary()} | {error, invalid_channel | channel_exists}.
admin_create(Name, Topic, Server) ->
    Key = briskd_wire:fold(Name),
    case briskd_wire:channel(Name) andalso binary:first(Name) =/= $! of
        false ->
            {error, invalid_channel};
        true ->
            case mnesia:dirty_read(channel, Key) of
                [_] ->
                    {error, channel_exists};
                [] ->
                    Now = erlang:system_time(second),
                    {TopicBy, TopicAt} =
                        case Topic of
                            <<>> -> {undefined, undefined};
                            _ -> {Server, Now}
                        end,
                    mnesia:dirty_write(#channel{
                        key = Key,
                        name = briskd_wire:retain(Name),
                        topic = briskd_wire:retain(Topic),
                        flags =
                            case binary:first(Name) of
                                $+ -> #{$t => true};
                                _ -> #{}
                            end,
                        created = Now,
                        topic_by = TopicBy,
                        topic_at = TopicAt
                    }),
                    briskd_population:on_channel_put(Key),
                    briskd_channel_safe:note_channel_empty(Key),
                    {ok, Name}
            end
    end.

-doc """
Remove the channel `Name` for the admin panel (`briskdctl delete-channel`):
every local member is kicked by the server with `Reason`, peers are told of
each kick, and the channel's row, history, and metadata are deleted.
""".
-spec admin_destroy(binary(), binary(), binary()) ->
    {ok, binary(), non_neg_integer()} | {error, no_such_channel | predefined_channel}.
admin_destroy(Name, Reason, Server) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            {error, no_such_channel};
        [#channel{name = Canonical, members = Members} = Channel] ->
            case briskd_state:predefined_channel(Key) of
                true ->
                    {error, predefined_channel};
                false ->
                    Pids = maps:keys(Members),
                    Kicked = [
                        Client
                     || Pid <- Pids, [#client{} = Client] <- [mnesia:dirty_read(client, Pid)]
                    ],
                    lists:foreach(
                        fun(#client{nick = Nick} = Client) ->
                            briskd_state_send:broadcast(
                                Pids, Server, <<"KICK">>, [Canonical, Nick], Reason
                            ),
                            admin_propagate(
                                Canonical,
                                briskd_wire:line(Server, <<"KICK">>, [Canonical, Nick], Reason)
                            ),
                            mnesia:dirty_write(Client#client{
                                channels = lists:delete(Key, Client#client.channels)
                            })
                        end,
                        Kicked
                    ),
                    briskd_channel_safe:drop_channel_row(Channel),
                    {ok, Canonical, length(Kicked)}
            end
    end.

-doc """
Apply the channel modes `ModeString` with `Args` to `Name` as the server for
`briskdctl set-channel-modes`.
""".
-spec admin_mode(binary(), binary(), [binary()], binary()) ->
    {ok, binary(), binary(), [binary()], [binary()]} | {error, no_such_channel}.
admin_mode(Name, ModeString, Args, Server) ->
    Key = briskd_wire:fold(Name),
    case mnesia:dirty_read(channel, Key) of
        [] ->
            {error, no_such_channel};
        [#channel{name = Canonical} = Channel] ->
            {Final, Changes, Errors} = admin_modes(
                binary_to_list(ModeString), add, Args, Channel, [], []
            ),
            case Final =/= Channel of
                true -> mnesia:dirty_write(Final);
                false -> ok
            end,
            {Applied, Params} = briskd_channel_mode:mode_line(Changes),
            case Changes of
                [] ->
                    ok;
                _ ->
                    #channel{members = Members} = Final,
                    {Tags, Meta} = briskd_state_history:event_tags(),
                    briskd_state_send:broadcast(
                        maps:keys(Members),
                        Server,
                        <<"MODE">>,
                        [Canonical, Applied | Params],
                        none,
                        Tags
                    ),
                    case lists:keymember($k, 2, Changes) of
                        true ->
                            ok;
                        false ->
                            briskd_state_history:note_event(
                                Key, <<"MODE">>, Server, [Applied | Params], none, Meta
                            )
                    end,
                    admin_propagate(
                        Canonical,
                        briskd_wire:line(Server, <<"MODE">>, [Canonical, Applied | Params], none)
                    )
            end,
            Shown = lists:append([
                case M of
                    $k -> [<<"*">> || _ <- P];
                    _ -> P
                end
             || {_, M, P} <- Changes
            ]),
            {ok, Canonical, Applied, Shown, lists:reverse(Errors)}
    end.

admin_modes([], _Action, _Args, Channel, Changes, Errors) ->
    {Channel, lists:reverse(Changes), Errors};
admin_modes([$+ | Rest], _, Args, Channel, Changes, Errors) ->
    admin_modes(Rest, add, Args, Channel, Changes, Errors);
admin_modes([$- | Rest], _, Args, Channel, Changes, Errors) ->
    admin_modes(Rest, remove, Args, Channel, Changes, Errors);
admin_modes([Mode | Rest], Action, Args, Channel, Changes, Errors) ->
    Sign =
        case Action of
            add -> $+;
            remove -> $-
        end,
    case briskd_channel_mode:apply_mode(Mode, Action, Args, Channel) of
        {ok, New, Tail, Params} when New =:= Channel, Params =:= [] ->
            admin_modes(Rest, Action, Tail, Channel, Changes, Errors);
        {ok, New, Tail, Params} ->
            admin_modes(Rest, Action, Tail, New, [{Sign, Mode, Params} | Changes], Errors);
        {remote, Updated, Tail, Params} ->
            mnesia:dirty_write(Updated),
            admin_modes(Rest, Action, Tail, Channel, [{Sign, Mode, Params} | Changes], Errors);
        {error, _Code, _Params, Message, Tail} ->
            Error = <<Sign, Mode, ": ", Message/binary>>,
            admin_modes(Rest, Action, Tail, Channel, Changes, [Error | Errors])
    end.

admin_propagate(<<$&, _/binary>>, _Line) -> ok;
admin_propagate(_Name, Line) -> briskd_state_link:server_broadcast(Line).

-doc """
Handle `RENAME <old> <new> [:reason]` (draft/channel-rename).
""".
-spec rename([binary()], #client{}, binary()) -> ok.
rename([Old, New | Rest], #client{pid = Pid} = Client, Server) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> <<>>
        end,
    OldKey = briskd_wire:fold(Old),
    NewKey = briskd_wire:fold(New),
    case mnesia:dirty_read(channel, OldKey) of
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Old], <<"No such channel">>);
        [#channel{name = Canonical, members = Members} = Channel] ->
            Roles = maps:get(Pid, Members, undefined),
            CaseOnly = OldKey =:= NewKey,
            Shared =
                mnesia:dirty_read(remote_channel, OldKey) =/= [] orelse
                    mnesia:dirty_read(remote_channel, NewKey) =/= [],
            Taken =
                not CaseOnly andalso
                    (mnesia:dirty_read(channel, NewKey) =/= [] orelse
                        mnesia:dirty_read(remote_channel, NewKey) =/= []),
            case Roles of
                undefined ->
                    briskd_state_send:numeric(
                        Client, Server, <<"442">>, [Canonical], <<"You're not on that channel">>
                    );
                _ ->
                    case lists:member(operator, Roles) of
                        false ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"482">>,
                                [Canonical],
                                <<"You're not channel operator">>
                            );
                        true ->
                            Valid =
                                briskd_wire:channel(New) andalso
                                    binary:first(New) =:= binary:first(Canonical) andalso
                                    binary:first(New) =/= $! andalso not Shared,
                            case {Valid, Taken} of
                                {false, _} ->
                                    briskd_state_send:fail(
                                        Pid,
                                        <<"RENAME">>,
                                        <<"CANNOT_RENAME">>,
                                        [Canonical, New],
                                        <<"The channel cannot be renamed">>
                                    );
                                {true, true} ->
                                    briskd_state_send:fail(
                                        Pid,
                                        <<"RENAME">>,
                                        <<"CHANNEL_NAME_IN_USE">>,
                                        [Canonical, New],
                                        <<"The channel name is already taken">>
                                    );
                                {true, false} ->
                                    apply_rename(Channel, New, Reason, Client, Server, CaseOnly)
                            end
                    end
            end
    end;
rename(_, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"RENAME">>], <<"Not enough parameters">>
    ).

apply_rename(
    #channel{key = OldKey, name = OldName, members = Members} = Channel,
    New,
    Reason,
    Client,
    Server,
    CaseOnly
) ->
    NewKey = briskd_wire:fold(New),
    Name = briskd_wire:retain(New),
    Renamed = Channel#channel{key = NewKey, name = Name},
    case CaseOnly of
        true ->
            mnesia:dirty_write(Renamed);
        false ->
            mnesia:dirty_delete(channel, OldKey),
            mnesia:dirty_write(Renamed),
            briskd_population:on_channel_delete(OldKey),
            briskd_population:on_channel_put(NewKey),
            lists:foreach(
                fun(Pid) ->
                    case mnesia:dirty_read(client, Pid) of
                        [#client{channels = Keys} = Member] ->
                            mnesia:dirty_write(Member#client{
                                channels = [
                                    case K of
                                        OldKey -> NewKey;
                                        _ -> K
                                    end
                                 || K <- Keys
                                ]
                            });
                        [] ->
                            ok
                    end
                end,
                maps:keys(Members)
            ),
            case mnesia:dirty_read(channel_history, OldKey) of
                [#channel_history{} = History] ->
                    mnesia:dirty_delete(channel_history, OldKey),
                    mnesia:dirty_write(History#channel_history{channel = NewKey});
                [] ->
                    ok
            end,
            briskd_state_meta:rename_channel(OldKey, NewKey),
            briskd_state_history:rename_markers(OldKey, NewKey),
            briskd_state_v3:rename_channel(OldKey, Name)
    end,
    logger:info(#{event => channel_renamed, actor => Client#client.nick}),
    Origin = briskd_channel_mode:channel_origin_prefix(Channel, Client),
    {Capable, Legacy} = lists:partition(
        fun(P) -> briskd_cap:enabled(P, <<"draft/channel-rename">>) end, maps:keys(Members)
    ),
    briskd_state_send:broadcast(Capable, Origin, <<"RENAME">>, [OldName, Name], Reason),
    case CaseOnly of
        true ->
            ok;
        false ->
            PartReason =
                case Reason of
                    <<>> -> none;
                    _ -> Reason
                end,
            lists:foreach(
                fun(Pid) ->
                    case mnesia:dirty_read(client, Pid) of
                        [#client{real = Real} = Member] when is_binary(Real) ->
                            Self = briskd_state_send:prefix(Member),
                            briskd_state_send:send(Pid, Self, <<"PART">>, [OldName], PartReason),
                            briskd_state_v3:join_broadcast(
                                [Pid],
                                Self,
                                Name,
                                briskd_state_v3:account(Pid),
                                Real
                            ),
                            briskd_state_channel:join_topic(Renamed, Member, Server),
                            briskd_state_history:markread_on_join(Pid, Name, Server),
                            case briskd_cap:enabled(Pid, <<"no-implicit-names">>) of
                                true -> ok;
                                false -> briskd_state_channel:names(Name, Member, Server)
                            end;
                        [] ->
                            ok
                    end
                end,
                Legacy
            )
    end,
    ok.
