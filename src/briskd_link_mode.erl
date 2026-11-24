-module(briskd_link_mode).
-moduledoc """
Server-link `MODE` updates for shared channels and remote users (RFC 2813).

Validates server or channel-operator origin, updates `remote_channel` and
synchronized `channel` state, applies role changes (`o`, `v`, `O`) to local
members, and updates remote user modes (`a`, `i`, `o`, `w`, `B`).
""".
-export([update_remote_modes/5]).
-include("briskd_client.hrl").
-include("briskd_channel.hrl").
-include("briskd_remote.hrl").

-doc """
Apply a `MODE` line received on the peer `Peer`.

For a channel target, `Prefix` must be a trusted server for `Peer` or a
remote user with operator or creator status on the channel through `Peer`.
Applies flags (`i m n p s t a q k`), list modes (`b e I`, each list capped at
the server's list limit), and `o`/`v`/`O <nick>`. The result is stored on the
remote channel, copied to the local channel of the same name, and relayed to
the other peers. An `o`/`v`/`O` target that is not a remote member may be a
local member of the local channel of the same name: its roles (or, for `O`,
the channel creator) are updated there, and the change is shown to local
members even when the source is a server.

For a user target, `Prefix` must be that remote user; letters `a i o w B` are
applied and others ignored, local users sharing a channel see the change, and
it is relayed.

Errors: `unknown_remote_channel`, `remote_mode_requires_operator`,
`missing_mode_argument`, `missing_channel_limit`, `invalid_channel_limit`,
`unknown_remote_mode_target`, `{unsupported_channel_mode, Char}`,
`{extra_mode_arguments, Args}`, `unknown_remote_source`, and
`remote_user_mode_source_mismatch`.
""".
-spec update_remote_modes(binary(), binary(), binary(), binary(), [binary()]) ->
    ok
    | {error,
        invalid_channel_limit
        | missing_channel_limit
        | missing_mode_argument
        | remote_mode_requires_operator
        | remote_user_mode_source_mismatch
        | unknown_remote_channel
        | unknown_remote_mode_target
        | unknown_remote_source
        | invalid_channel
        | {extra_mode_arguments, term()}
        | {unsupported_channel_mode, byte()}}.
update_remote_modes(Peer, Prefix, Name, ModeString, Args) ->
    case briskd_wire:channel(Name) of
        false -> update_remote_user_modes(Peer, Prefix, Name, ModeString);
        true -> update_remote_channel_modes(Peer, Prefix, Name, ModeString, Args)
    end.

update_remote_channel_modes(_Peer, _Prefix, <<$&, _/binary>>, _ModeString, _Args) ->
    {error, invalid_channel};
update_remote_channel_modes(Peer, Prefix, Name, ModeString, Args) ->
    Key = briskd_wire:fold(Name),
    %% A relayed MODE keeps the upstream server prefix. Trust that prefix when
    %% the named server is this link or was introduced through it.
    TrustedServer = briskd_state_link:trusted_server(Peer, Prefix),
    Channel =
        case mnesia:dirty_read(remote_channel, Key) of
            [#remote_channel{} = ExistingRecord] -> ExistingRecord;
            [] when TrustedServer -> briskd_link_channel:ensure_remote_channel(Key, Name);
            [] -> undefined
        end,
    case Channel of
        undefined ->
            {error, unknown_remote_channel};
        #remote_channel{members = Members} = ChannelRecord ->
            Authorized =
                case TrustedServer of
                    true ->
                        true;
                    false ->
                        case briskd_state_link:remote_source(Peer, Prefix) of
                            {ok, #remote_client{key = NickKey}} ->
                                case Members of
                                    #{NickKey := {Peer, Roles}} ->
                                        lists:member(operator, Roles) orelse
                                            lists:member(creator, Roles);
                                    #{} ->
                                        false
                                end;
                            error ->
                                false
                        end
                end,
            case Authorized of
                false ->
                    {error, remote_mode_requires_operator};
                true ->
                    case
                        %% Letters before any sign are additions, as in the
                        %% local MODE handler.
                        apply_remote_modes(
                            binary_to_list(ModeString), add, Args, ChannelRecord, []
                        )
                    of
                        {ok, Updated, [], LocalRoles} ->
                            mnesia:dirty_write(Updated),
                            briskd_population:on_channel_put(Key),
                            synchronize_local_channel(Updated),
                            apply_local_roles(Key, LocalRoles),
                            briskd_state_link:relay_except(
                                Peer,
                                briskd_wire:line(
                                    Prefix, <<"MODE">>, [Name, ModeString | Args], none
                                )
                            ),
                            %% A server MODE is stored silently, as in a burst,
                            %% unless it changes the status of a local member.
                            case not TrustedServer orelse LocalRoles =/= [] of
                                true -> broadcast_remote_mode(Name, Prefix, ModeString, Args);
                                false -> ok
                            end,
                            ok;
                        {ok, _Updated, Extra, _LocalRoles} ->
                            {error, {extra_mode_arguments, Extra}};
                        {error, _} = Error ->
                            Error
                    end
            end
    end.

synchronize_local_channel(#remote_channel{key = Key, flags = RemoteFlags}) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{} = Channel] ->
            ModeKeys = [$a, $i, $m, $n, $p, $q, $r, $s, $t, $K],
            Flags = #{M => true || M <- ModeKeys, is_map_key(M, RemoteFlags)},
            Lists = maps:with([ban, exception, invite], RemoteFlags),
            mnesia:dirty_write(Channel#channel{
                flags = Flags,
                password = maps:get(key, RemoteFlags, undefined),
                limit = maps:get(limit, RemoteFlags, undefined),
                lists = Lists
            });
        [] ->
            ok
    end.

apply_remote_modes([], _Action, Args, Channel, Local) ->
    {ok, Channel, Args, lists:reverse(Local)};
apply_remote_modes([$+ | Rest], _Action, Args, Channel, Local) ->
    apply_remote_modes(Rest, add, Args, Channel, Local);
apply_remote_modes([$- | Rest], _Action, Args, Channel, Local) ->
    apply_remote_modes(Rest, remove, Args, Channel, Local);
apply_remote_modes(
    [Mode | Rest], Action, Args, #remote_channel{flags = Flags} = Channel, Local
) when
    Mode =:= $i;
    Mode =:= $m;
    Mode =:= $n;
    Mode =:= $p;
    Mode =:= $s;
    Mode =:= $t;
    Mode =:= $a;
    Mode =:= $q
->
    NewFlags =
        case Action of
            add -> Flags#{Mode => true};
            remove -> maps:remove(Mode, Flags)
        end,
    apply_remote_modes(Rest, Action, Args, Channel#remote_channel{flags = NewFlags}, Local);
apply_remote_modes(
    [$k | Rest], add, [Password | Args], #remote_channel{flags = Flags} = Channel, Local
) ->
    apply_remote_modes(
        Rest,
        add,
        Args,
        Channel#remote_channel{flags = Flags#{key => briskd_wire:retain(Password)}},
        Local
    );
apply_remote_modes(
    [$k | Rest], remove, [_ | Args], #remote_channel{flags = Flags} = Channel, Local
) ->
    apply_remote_modes(
        Rest, remove, Args, Channel#remote_channel{flags = maps:remove(key, Flags)}, Local
    );
apply_remote_modes([$r | _Rest], _Action, _Args, _Channel, _Local) ->
    {error, {unsupported_channel_mode, $r}};
apply_remote_modes(
    [$l | Rest], add, [LimitBin | Args], #remote_channel{flags = Flags} = Channel, Local
) ->
    case
        try binary_to_integer(LimitBin) of
            Value when Value > 0 -> {ok, Value};
            _ -> error
        catch
            error:badarg -> error
        end
    of
        {ok, Limit} ->
            apply_remote_modes(
                Rest, add, Args, Channel#remote_channel{flags = Flags#{limit => Limit}}, Local
            );
        error ->
            {error, invalid_channel_limit}
    end;
apply_remote_modes([$l | _Rest], add, [], _Channel, _Local) ->
    {error, missing_channel_limit};
apply_remote_modes([$l | Rest], Action, Args, #remote_channel{flags = Flags} = Channel, Local) ->
    NewFlags =
        case Action of
            remove -> maps:remove(limit, Flags);
            _ -> Flags
        end,
    apply_remote_modes(Rest, Action, Args, Channel#remote_channel{flags = NewFlags}, Local);
apply_remote_modes(
    [Mode | Rest],
    Action,
    [Mask | Args],
    #remote_channel{flags = Flags} = Channel,
    Local
) when Mode =:= $b; Mode =:= $e; Mode =:= $I ->
    Type =
        case Mode of
            $b -> ban;
            $e -> exception;
            $I -> invite
        end,
    Current = maps:get(Type, Flags, []),
    Updated =
        case Action of
            add ->
                case lists:member(Mask, Current) orelse length(Current) >= ?MAX_LIST_ENTRIES of
                    true -> Current;
                    false -> Current ++ [briskd_wire:retain(Mask)]
                end;
            remove ->
                lists:delete(Mask, Current)
        end,
    apply_remote_modes(
        Rest, Action, Args, Channel#remote_channel{flags = Flags#{Type => Updated}}, Local
    );
apply_remote_modes(
    [Mode | Rest],
    Action,
    [Nick | Args],
    #remote_channel{key = ChannelKey, members = Members} = Channel,
    Local
) when
    Mode =:= $o; Mode =:= $v; Mode =:= $O
->
    Key = briskd_wire:fold(Nick),
    Role =
        case Mode of
            $o -> operator;
            $v -> voice;
            $O -> creator
        end,
    case maps:find(Key, Members) of
        {ok, {Owner, Roles}} ->
            NewRoles =
                case Action of
                    add -> lists:usort([Role | Roles]);
                    remove -> lists:delete(Role, Roles)
                end,
            apply_remote_modes(
                Rest,
                Action,
                Args,
                Channel#remote_channel{members = Members#{Key := {Owner, NewRoles}}},
                Local
            );
        error ->
            %% The target may be a member homed on this server.
            case local_member(ChannelKey, Nick) of
                {ok, Pid} ->
                    apply_remote_modes(Rest, Action, Args, Channel, [{Pid, Role, Action} | Local]);
                error ->
                    {error, unknown_remote_mode_target}
            end
    end;
apply_remote_modes([Mode | _], _Action, [], _Channel, _Local) when
    Mode =:= $k; Mode =:= $o; Mode =:= $v; Mode =:= $O; Mode =:= $b; Mode =:= $e; Mode =:= $I
->
    {error, missing_mode_argument};
apply_remote_modes([Mode | _], _Action, _Args, _Channel, _Local) ->
    {error, {unsupported_channel_mode, Mode}}.

%% The pid of local user Nick when it is a member of the local channel Key.
local_member(Key, Nick) ->
    case {briskd_state_client:find_nick(Nick), mnesia:dirty_read(channel, Key)} of
        {#client{pid = Pid}, [#channel{members = Members}]} when is_map_key(Pid, Members) ->
            {ok, Pid};
        _ ->
            error
    end.

%% Apply `o`, `v`, and `O` changes from a peer to local members of channel
%% Key, as a local MODE would: `o` and `v` edit the member's roles and `O`
%% sets or clears the channel creator. The reop deadline is kept current.
apply_local_roles(_Key, []) ->
    ok;
apply_local_roles(Key, Changes) ->
    case mnesia:dirty_read(channel, Key) of
        [#channel{} = Channel] ->
            Updated = lists:foldl(fun apply_local_role/2, Channel, Changes),
            mnesia:dirty_write(
                briskd_state_channel:track_opless(Updated, Updated#channel.members)
            );
        [] ->
            ok
    end.

apply_local_role({Pid, creator, add}, Channel) ->
    Channel#channel{creator = Pid};
apply_local_role({Pid, creator, remove}, #channel{creator = Pid} = Channel) ->
    Channel#channel{creator = undefined};
apply_local_role({_Pid, creator, remove}, Channel) ->
    Channel;
apply_local_role({Pid, Role, Action}, #channel{members = Members} = Channel) ->
    case Members of
        #{Pid := Roles} ->
            NewRoles =
                case Action of
                    add -> lists:usort([Role | Roles]);
                    remove -> lists:delete(Role, Roles)
                end,
            Channel#channel{members = Members#{Pid := NewRoles}};
        #{} ->
            Channel
    end.

broadcast_remote_mode(Name, Prefix, Modes, Args) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, flags = Flags}] ->
            EventPrefix =
                case maps:is_key($a, Flags) of
                    true -> <<"anonymous!anonymous@anonymous.">>;
                    false -> Prefix
                end,
            briskd_state_send:broadcast(
                maps:keys(Members), EventPrefix, <<"MODE">>, [Canonical, Modes | Args], none
            );
        [] ->
            ok
    end.

update_remote_user_modes(Peer, Prefix, Nick, ModeString) ->
    Key = briskd_wire:fold(Nick),
    case briskd_state_link:remote_source(Peer, Prefix) of
        {ok, #remote_client{key = Key, modes = Modes} = Remote} ->
            Updated = apply_remote_user_modes(binary_to_list(ModeString), undefined, Modes),
            mnesia:dirty_write(briskd_wire:retain_fields(Remote#remote_client{modes = Updated})),
            briskd_population:on_remote_user_put(Key, Updated),
            briskd_state_send:broadcast(
                briskd_state_link:remote_user_local_recipients(Key),
                Prefix,
                <<"MODE">>,
                [Nick, ModeString],
                none
            ),
            briskd_state_link:relay_except(
                Peer, briskd_wire:line(Prefix, <<"MODE">>, [Nick, ModeString], none)
            ),
            ok;
        {ok, _OtherRemote} ->
            {error, remote_user_mode_source_mismatch};
        error ->
            {error, unknown_remote_source}
    end.

apply_remote_user_modes([], _Action, Modes) ->
    Modes;
apply_remote_user_modes([$+ | Rest], _Action, Modes) ->
    apply_remote_user_modes(Rest, add, Modes);
apply_remote_user_modes([$- | Rest], _Action, Modes) ->
    apply_remote_user_modes(Rest, remove, Modes);
apply_remote_user_modes([Mode | Rest], Action, Modes) when
    Mode =:= $a; Mode =:= $i; Mode =:= $o; Mode =:= $w; Mode =:= $B
->
    NewModes =
        case Action of
            add -> Modes#{Mode => true};
            remove -> maps:remove(Mode, Modes);
            undefined -> Modes
        end,
    apply_remote_user_modes(Rest, Action, NewModes);
apply_remote_user_modes([_ | Rest], Action, Modes) ->
    apply_remote_user_modes(Rest, Action, Modes).
