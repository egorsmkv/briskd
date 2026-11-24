-module(briskd_channel_mode).
-moduledoc """
User and channel `MODE` parsing/application, list-mode (`b`/`e`/`I`) queries,
wildcard/extban matching, status prefixes, and administrator predefined-channel
opping (RFC 2811, RFC 2812 sections 3.1.5 and 3.2.3).

Runs inside the `m:briskd_state` process.
""".
-export([
    apply_mode/4,
    channel_origin_prefix/2,
    grant_predefined_operator/2,
    mask_matches/3,
    mode_command/4,
    mode_line/1,
    remote_target/2,
    role_prefix/2,
    user_mode_string/1,
    wildcard_match/2
]).
-include("briskd_state.hrl").

-doc """
Give channel operator to an administrator on the predefined channels it is in
after a successful `OPER`.
""".
-spec grant_predefined_operator(#client{}, binary()) -> ok.
grant_predefined_operator(#client{pid = Pid}, Server) ->
    case briskd_state:administrator(Pid) of
        false ->
            ok;
        true ->
            Client = briskd_state_client:client(Pid),
            lists:foreach(
                fun(Key) -> grant_predefined_one(Key, Client, Server) end,
                Client#client.channels
            )
    end.

grant_predefined_one(Key, Client, Server) ->
    case briskd_state:predefined_channel(Key) of
        false -> ok;
        true -> grant_predefined_row(mnesia:dirty_read(channel, Key), Client, Server)
    end.

grant_predefined_row([], _Client, _Server) ->
    ok;
grant_predefined_row([#channel{name = <<$+, _/binary>>}], _Client, _Server) ->
    ok;
grant_predefined_row(
    [#channel{members = Members} = Channel], #client{pid = Pid, nick = Nick} = Client, _Server
) ->
    Roles = maps:get(Pid, Members, []),
    case is_map_key(Pid, Members) andalso not lists:member(operator, Roles) of
        false ->
            ok;
        true ->
            Updated = Channel#channel{members = Members#{Pid => lists:usort([operator | Roles])}},
            mnesia:dirty_write(Updated),
            briskd_state_send:broadcast(
                maps:keys(Members),
                briskd_state_send:prefix(Client),
                <<"MODE">>,
                [Channel#channel.name, <<"+o">>, Nick],
                none
            ),
            briskd_state_link:propagate_channel_mode(Client, Channel#channel.name, <<"+o">>, [Nick])
    end.

-doc """
Origin prefix for a local channel event: `anonymous!anonymous@anonymous.` when
the channel has mode `+a`, otherwise `Client`'s `nick!user@host`.
""".
-spec channel_origin_prefix(#channel{}, #client{}) -> iodata().
channel_origin_prefix(#channel{flags = Flags}, _Client) when is_map_key($a, Flags) ->
    <<"anonymous!anonymous@anonymous.">>;
channel_origin_prefix(_, Client) ->
    briskd_state_send:prefix(Client).

-doc """
Status prefix for a member's channel roles as shown to `Requester`.
""".
-spec role_prefix([atom()], pid()) -> binary().
role_prefix(Roles, Requester) ->
    Operator = lists:member(operator, Roles) orelse lists:member(creator, Roles),
    Voice = lists:member(voice, Roles),
    case {Operator, Voice, briskd_cap:enabled(Requester, <<"multi-prefix">>)} of
        {true, true, true} -> <<"@+">>;
        {true, _, _} -> <<"@">>;
        {false, true, _} -> <<"+">>;
        _ -> <<>>
    end.

-doc """
True when a local or remote user matches the channel's ban, exception, or
invite list (plain masks or `$a:<account>` extban).
""".
-spec mask_matches(#channel{}, ban | exception | invite, #client{} | #remote_client{}) ->
    boolean().
mask_matches(Channel, Type, #client{pid = Pid, nick = Nick, user = User, host = Host}) ->
    identity_matches(Channel, Type, Nick, User, Host, fun() -> briskd_state_v3:account(Pid) end);
mask_matches(Channel, Type, #remote_client{key = Key, nick = Nick, user = User, host = Host}) ->
    identity_matches(Channel, Type, Nick, User, Host, fun() ->
        briskd_state_v3:remote_account(Key)
    end).

identity_matches(#channel{lists = Lists}, Type, Nick, User, Host, Account) ->
    Identity = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
    lists:any(
        fun
            (<<"$a:", AccountMask/binary>>) ->
                case Account() of
                    undefined -> false;
                    Name -> wildcard_match(AccountMask, Name)
                end;
            (<<"$a">>) ->
                Account() =/= undefined;
            (Mask) ->
                wildcard_match(Mask, Identity)
        end,
        maps:get(Type, Lists, [])
    ).

-doc """
Match an IRC mask (`*` any run, `?` one octet) against a value under the
RFC 1459 case mapping in bounded time (no exponential backtracking).
""".
-spec wildcard_match(binary(), binary()) -> boolean().
wildcard_match(Mask, Value) ->
    glob(briskd_wire:fold(Mask), briskd_wire:fold(Value), none).

glob(<<>>, <<>>, _Star) ->
    true;
glob(<<$*, Mask/binary>>, Value, _Star) ->
    glob(Mask, Value, {Mask, Value});
glob(<<$?, Mask/binary>>, <<_, Value/binary>>, Star) ->
    glob(Mask, Value, Star);
glob(<<Char, Mask/binary>>, <<Char, Value/binary>>, Star) ->
    glob(Mask, Value, Star);
glob(_Mask, _Value, {StarMask, <<_, StarValue/binary>>}) ->
    glob(StarMask, StarValue, {StarMask, StarValue});
glob(_Mask, _Value, _Star) ->
    false.

-doc """
Handle `MODE` for a channel or for the requester's own user modes.
""".
-spec mode_command(binary(), [binary()], #client{}, binary()) -> ok.
mode_command(Target, Rest, Client, Server) ->
    case briskd_wire:channel(Target) of
        true -> channel_mode(Target, Rest, Client, Server);
        false -> user_mode(Target, Rest, Client, Server)
    end.

user_mode(Target, Rest, #client{pid = Pid} = Client, Server) ->
    case briskd_state_client:find_nick(Target) of
        undefined ->
            briskd_state_send:numeric(
                Client, Server, <<"401">>, [Target], <<"No such nick/channel">>
            );
        #client{pid = Other} when Other =/= Pid ->
            briskd_state_send:numeric(
                Client, Server, <<"502">>, [], <<"Cannot change mode for other users">>
            );
        #client{nick = Nick} ->
            Modes = briskd_state_client:user_modes(Pid),
            case Rest of
                [] ->
                    briskd_state_send:numeric(
                        Client, Server, <<"221">>, [user_mode_string(Modes)], none
                    );
                [ModeSpec | _] ->
                    change_user_modes(
                        binary_to_list(ModeSpec),
                        undefined,
                        Modes,
                        Nick,
                        Client,
                        Server
                    )
            end
    end.

-doc """
Format a user-mode map as `+` followed by the sorted mode letters.
""".
-spec user_mode_string(map()) -> binary().
user_mode_string(Modes) ->
    list_to_binary([$+ | lists:sort(maps:keys(Modes))]).

change_user_modes([], _, Modes, _, Client, _Server) ->
    mnesia:dirty_write(#user_modes{pid = Client#client.pid, modes = Modes});
change_user_modes([$+ | Rest], _, Modes, Nick, Client, Server) ->
    change_user_modes(Rest, add, Modes, Nick, Client, Server);
change_user_modes([$- | Rest], _, Modes, Nick, Client, Server) ->
    change_user_modes(Rest, remove, Modes, Nick, Client, Server);
change_user_modes([_Mode | Rest], undefined, Modes, Nick, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"501">>, [], <<"Unknown MODE flag">>),
    change_user_modes(Rest, undefined, Modes, Nick, Client, Server);
change_user_modes([Mode | Rest], Action, Modes, Nick, Client, Server) when
    Mode =:= $i; Mode =:= $w; Mode =:= $B
->
    New =
        case Action of
            add -> Modes#{Mode => true};
            remove -> maps:remove(Mode, Modes)
        end,
    case New =/= Modes of
        true ->
            mnesia:dirty_write(#user_modes{pid = Client#client.pid, modes = New}),
            briskd_population:on_local_mode_change(
                Client#client.pid, briskd_state_client:ready(Client), New
            ),
            Sign =
                case Action of
                    add -> $+;
                    remove -> $-
                end,
            briskd_state_send:send(
                Client#client.pid,
                briskd_state_send:prefix(Client),
                <<"MODE">>,
                [Nick, <<Sign, Mode>>],
                none
            ),
            briskd_state_link:server_broadcast(
                briskd_wire:line(
                    briskd_state_send:prefix(Client), <<"MODE">>, [Nick, <<Sign, Mode>>], none
                )
            );
        false ->
            ok
    end,
    change_user_modes(Rest, Action, New, Nick, Client, Server);
%% RFC 2812 3.1.5: a user may de-op themselves; +o only comes from OPER.
%% Losing +o also ends administrator status.
change_user_modes([$o | Rest], remove, Modes, Nick, #client{pid = Pid} = Client, Server) ->
    New = maps:remove($o, Modes),
    case New =/= Modes of
        true ->
            mnesia:dirty_write(#user_modes{pid = Pid, modes = New}),
            _ = ets:whereis(briskd_admins) =/= undefined andalso ets:delete(briskd_admins, Pid),
            briskd_population:on_local_mode_change(Pid, briskd_state_client:ready(Client), New),
            logger:info(#{event => oper_dropped, nick => Nick}),
            Prefix = briskd_state_send:prefix(Client),
            briskd_state_send:send(Pid, Prefix, <<"MODE">>, [Nick, <<"-o">>], none),
            briskd_state_link:server_broadcast(
                briskd_wire:line(Prefix, <<"MODE">>, [Nick, <<"-o">>], none)
            );
        false ->
            ok
    end,
    change_user_modes(Rest, remove, New, Nick, Client, Server);
change_user_modes([$o | Rest], Action, Modes, Nick, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>
    ),
    change_user_modes(Rest, Action, Modes, Nick, Client, Server);
change_user_modes([_Mode | Rest], Action, Modes, Nick, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"501">>, [], <<"Unknown MODE flag">>),
    change_user_modes(Rest, Action, Modes, Nick, Client, Server).

channel_mode(Name, [Mode], #client{pid = Pid} = Client, Server) when
    Mode =:= <<"+b">>;
    Mode =:= <<"+e">>;
    Mode =:= <<"+I">>;
    Mode =:= <<"b">>;
    Mode =:= <<"e">>;
    Mode =:= <<"I">>
->
    Type =
        case Mode of
            <<"+b">> -> ban;
            <<"b">> -> ban;
            <<"+e">> -> exception;
            <<"e">> -> exception;
            <<"+I">> -> invite;
            <<"I">> -> invite
        end,
    list_mode(Type, Name, Pid, Client, Server);
channel_mode(Name, Rest, #client{pid = Pid} = Client, Server) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members} = Channel] ->
            IsCreator = Channel#channel.creator =:= Pid andalso maps:is_key(Pid, Members),
            IsOperator = lists:member(operator, maps:get(Pid, Members, [])),
            case {Rest, IsOperator orelse IsCreator} of
                {[], _} ->
                    report_modes_of(Channel, Client, Server);
                {[Modes | Args], true} ->
                    Changes = change_modes(
                        binary_to_list(Modes), add, Args, Channel, Client, Server, []
                    ),
                    announce_mode_changes(Channel, Client, Changes);
                {_, false} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    )
            end;
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>)
    end.

list_mode(Type, Name, Pid, Client, Server) ->
    case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
        [#channel{name = Canonical, members = Members, lists = Lists, flags = Flags}] ->
            Member = maps:is_key(Pid, Members),
            Operator = lists:member(operator, maps:get(Pid, Members, [])),
            Hidden = not Member andalso (maps:is_key($s, Flags) orelse maps:is_key($p, Flags)),
            case Type =:= ban orelse Operator of
                false ->
                    briskd_state_send:numeric(
                        Client, Server, <<"482">>, [Canonical], <<"You're not channel operator">>
                    );
                true ->
                    {Item, End, Text} =
                        case Type of
                            ban ->
                                {<<"367">>, <<"368">>, <<"End of channel ban list">>};
                            exception ->
                                {<<"348">>, <<"349">>, <<"End of channel exception list">>};
                            invite ->
                                {<<"346">>, <<"347">>, <<"End of channel invite list">>}
                        end,
                    Entries =
                        case Hidden of
                            true -> [];
                            false -> maps:get(Type, Lists, [])
                        end,
                    lists:foreach(
                        fun(Entry) ->
                            briskd_state_send:numeric(
                                Client, Server, Item, [Canonical, Entry], none
                            )
                        end,
                        Entries
                    ),
                    briskd_state_send:numeric(Client, Server, End, [Canonical], Text)
            end;
        [] ->
            briskd_state_send:numeric(Client, Server, <<"403">>, [Name], <<"No such channel">>)
    end.

report_modes_of(
    #channel{
        name = Name,
        flags = Flags,
        limit = Limit,
        password = Password,
        members = Members
    } = Channel,
    #client{pid = Pid} = Client,
    Server
) ->
    KeyFields =
        case Password of
            undefined ->
                {[], []};
            _ ->
                Display =
                    case maps:is_key(Pid, Members) of
                        true -> Password;
                        false -> <<"*">>
                    end,
                {"k", [Display]}
        end,
    LimitFields =
        case Limit of
            undefined -> {[], []};
            _ -> {"l", [integer_to_binary(Limit)]}
        end,
    {KeyMode, KeyArgs} = KeyFields,
    {LimitMode, LimitArgs} = LimitFields,
    Modes = list_to_binary([$+ | lists:sort(maps:keys(Flags)) ++ KeyMode ++ LimitMode]),
    briskd_state_send:numeric(
        Client, Server, <<"324">>, [Name, Modes | KeyArgs ++ LimitArgs], none
    ),
    Created =
        case Channel#channel.created of
            undefined -> persistent_term:get({briskd_state, started_at_system}, 0);
            Seconds -> Seconds
        end,
    briskd_state_send:numeric(Client, Server, <<"329">>, [Name, integer_to_binary(Created)], none).

change_modes([], _, _, _, _, _, Changes) ->
    lists:reverse(Changes);
change_modes([$+ | Rest], _, Args, Channel, Client, Server, Changes) ->
    change_modes(Rest, add, Args, Channel, Client, Server, Changes);
change_modes([$- | Rest], _, Args, Channel, Client, Server, Changes) ->
    change_modes(Rest, remove, Args, Channel, Client, Server, Changes);
change_modes([Mode | Rest], Action, Args, Channel, Client, Server, Changes) ->
    #channel{name = Name} = Channel,
    Authorized = mode_authorized(Mode, Action, Channel, Client),
    case {Mode, Authorized, apply_mode(Mode, Action, Args, Channel)} of
        {$q, _, _} ->
            briskd_state_send:numeric(
                Client,
                Server,
                <<"481">>,
                [],
                <<"Permission Denied- Quiet mode is server only">>
            ),
            change_modes(Rest, Action, Args, Channel, Client, Server, Changes);
        {_, false, _} ->
            briskd_state_send:numeric(
                Client, Server, <<"482">>, [Name], <<"You're not channel creator">>
            ),
            change_modes(Rest, Action, Args, Channel, Client, Server, Changes);
        {_, true, {ok, New, Tail, Parameters}} ->
            NextChanges =
                case New =/= Channel of
                    true ->
                        mnesia:dirty_write(New),
                        Sign =
                            case Action of
                                add -> $+;
                                remove -> $-
                            end,
                        [{Sign, Mode, Parameters} | Changes];
                    false ->
                        Changes
                end,
            change_modes(Rest, Action, Tail, New, Client, Server, NextChanges);
        {_, true, {remote, Updated, Tail, Parameters}} ->
            NextChanges =
                case mnesia:dirty_read(remote_channel, Updated#remote_channel.key) of
                    [#remote_channel{} = Updated] ->
                        Changes;
                    _ ->
                        mnesia:dirty_write(Updated),
                        Sign =
                            case Action of
                                add -> $+;
                                remove -> $-
                            end,
                        [{Sign, Mode, Parameters} | Changes]
                end,
            change_modes(Rest, Action, Tail, Channel, Client, Server, NextChanges);
        {_, true, {error, Code, Params, Message, Tail}} ->
            briskd_state_send:numeric(Client, Server, Code, Params, Message),
            change_modes(Rest, Action, Tail, Channel, Client, Server, Changes)
    end.

-doc """
Look up a remote member target on `Name` by folded nickname `NickKey`.
""".
-spec remote_target(binary(), binary()) ->
    no_such_nick | not_on_channel | {ok, binary(), #remote_channel{}}.
remote_target(NickKey, Name) ->
    case mnesia:dirty_read(remote_client, NickKey) of
        [] ->
            no_such_nick;
        [#remote_client{nick = Actual}] ->
            case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
                [#remote_channel{members = Remote} = RemoteChannel] when
                    is_map_key(NickKey, Remote)
                ->
                    {ok, Actual, RemoteChannel};
                _ ->
                    not_on_channel
            end
    end.

announce_mode_changes(_Channel, _Client, []) ->
    ok;
announce_mode_changes(
    #channel{key = Key, name = Name, members = Members} = Channel, Client, Changes
) ->
    {ModeString, Params} = mode_line(Changes),
    Origin = channel_origin_prefix(Channel, Client),
    {Tags, Meta} = briskd_state_history:event_tags(),
    briskd_state_send:broadcast(
        maps:keys(Members), Origin, <<"MODE">>, [Name, ModeString | Params], none, Tags
    ),
    case lists:keymember($k, 2, Changes) of
        true ->
            ok;
        false ->
            briskd_state_history:note_event(
                Key, <<"MODE">>, Origin, [ModeString | Params], none, Meta
            )
    end,
    briskd_state_link:propagate_channel_mode(Client, Name, ModeString, Params),
    case mnesia:dirty_read(channel, Key) of
        [#channel{} = Current] -> briskd_state_link:note_local_channel(Current);
        [] -> ok
    end.

mode_authorized($r, _Action, #channel{name = <<$!, _/binary>>} = Channel, Client) ->
    Channel#channel.creator =:= Client#client.pid;
mode_authorized($r, _Action, _, _) ->
    true;
mode_authorized($a, _Action, #channel{name = <<$!, _/binary>>} = Channel, Client) ->
    Channel#channel.creator =:= Client#client.pid;
mode_authorized($a, _Action, #channel{name = <<$&, _/binary>>}, _) ->
    true;
mode_authorized($a, _Action, _, _) ->
    true;
mode_authorized(_, _, _, _) ->
    true.

-doc """
Apply one channel mode flag (`Mode`, `add` | `remove`) using `Args` onto `Channel`.
""".
-spec apply_mode(char(), add | remove, [binary()], #channel{}) ->
    {ok, #channel{}, [binary()], [binary()]}
    | {remote, #remote_channel{}, [binary()], [binary()]}
    | {error, binary(), [binary()], binary(), [binary()]}.
apply_mode(Mode, Action, Args, #channel{name = Name, lists = Lists} = Channel) when
    Mode =:= $b; Mode =:= $e; Mode =:= $I
->
    Type =
        case Mode of
            $b -> ban;
            $e -> exception;
            $I -> invite
        end,
    Existing = maps:get(Type, Lists, []),
    case Args of
        [Mask | Tail] when Action =:= add, length(Existing) >= ?MAX_LIST_ENTRIES ->
            case lists:member(Mask, Existing) of
                true ->
                    {ok, Channel, Tail, []};
                false ->
                    {error, <<"478">>, [Name, <<Mode>>], <<"Channel list is full">>, Tail}
            end;
        [Mask | Tail] ->
            StoredMask = briskd_wire:retain(Mask),
            NewList =
                case Action of
                    add -> lists:usort([StoredMask | Existing]);
                    remove -> lists:delete(Mask, Existing)
                end,
            {ok, Channel#channel{lists = Lists#{Type => NewList}}, Tail, [Mask]};
        [] ->
            {ok, Channel, [], []}
    end;
apply_mode($a, Action, Args, #channel{name = <<$&, _/binary>>, flags = Flags} = Channel) ->
    New =
        case Action of
            add -> Flags#{$a => true};
            remove -> maps:remove($a, Flags)
        end,
    {ok, Channel#channel{flags = New}, Args, []};
apply_mode($a, add, Args, #channel{name = <<$!, _/binary>>, flags = Flags} = Channel) ->
    {ok, Channel#channel{flags = Flags#{$a => true}}, Args, []};
apply_mode($a, remove, Args, #channel{name = <<$!, _/binary>>} = Channel) ->
    {error, <<"482">>, [Channel#channel.name], <<"Cannot unset anonymous mode on a safe channel">>,
        Args};
apply_mode($a, _, Args, _) ->
    {error, <<"472">>, [<<"a">>], <<"Anonymous mode is only available on local and safe channels">>,
        Args};
apply_mode($r, Action, Args, #channel{name = <<$!, _/binary>>, flags = Flags} = Channel) ->
    New =
        case Action of
            add -> Flags#{$r => true};
            remove -> maps:remove($r, Flags)
        end,
    {ok, Channel#channel{flags = New, opless_since = undefined}, Args, []};
apply_mode($r, _, Args, _) ->
    {error, <<"472">>, [<<"r">>], <<"Reop mode is only available on safe channels">>, Args};
apply_mode(Mode, Action, Args, #channel{flags = Flags} = Channel) when
    Mode =:= $i; Mode =:= $m; Mode =:= $n; Mode =:= $q; Mode =:= $t; Mode =:= $K
->
    New =
        case Action of
            add -> Flags#{Mode => true};
            remove -> maps:remove(Mode, Flags)
        end,
    {ok, Channel#channel{flags = New}, Args, []};
apply_mode(Mode, add, Args, #channel{flags = Flags} = Channel) when
    Mode =:= $p; Mode =:= $s
->
    Other =
        case Mode of
            $p -> $s;
            $s -> $p
        end,
    New = (maps:remove(Other, Flags))#{Mode => true},
    {ok, Channel#channel{flags = New}, Args, []};
apply_mode(Mode, remove, Args, #channel{flags = Flags} = Channel) when
    Mode =:= $p; Mode =:= $s
->
    {ok, Channel#channel{flags = maps:remove(Mode, Flags)}, Args, []};
apply_mode($l, remove, Args, Channel) ->
    {ok, Channel#channel{limit = undefined}, Args, []};
apply_mode($l, add, [Value | Args], Channel) ->
    case string:to_integer(Value) of
        {Limit, <<>>} when Limit > 0, Limit =< 2147483647 ->
            {ok, Channel#channel{limit = Limit}, Args, [integer_to_binary(Limit)]};
        _ ->
            {error, <<"696">>, [Channel#channel.name, <<"l">>, param_token(Value)],
                <<"Invalid channel limit">>, Args}
    end;
apply_mode($k, add, [Key | Args], Channel) when byte_size(Key) > 0, byte_size(Key) =< 64 ->
    case binary:match(Key, [<<" ">>, <<",">>, <<":">>]) of
        nomatch -> {ok, Channel#channel{password = briskd_wire:retain(Key)}, Args, [Key]};
        _ -> invalid_key(Key, Args, Channel)
    end;
apply_mode($k, add, [Key | Args], Channel) ->
    invalid_key(Key, Args, Channel);
apply_mode($k, remove, [_ | Args], Channel) ->
    {ok, Channel#channel{password = undefined}, Args, [<<"*">>]};
apply_mode(Mode, Action, [Nick | Args], #channel{name = Name, members = Members} = Channel) when
    Mode =:= $o; Mode =:= $v
->
    Role =
        case Mode of
            $o -> operator;
            $v -> voice
        end,
    case briskd_state_client:find_nick(Nick) of
        #client{pid = Pid, nick = Actual} when is_map_key(Pid, Members) ->
            Roles = maps:get(Pid, Members),
            New =
                case Action of
                    add -> lists:usort([Role | Roles]);
                    remove -> lists:delete(Role, Roles)
                end,
            {ok, Channel#channel{members = Members#{Pid := New}}, Args, [Actual]};
        undefined ->
            NickKey = briskd_wire:fold(Nick),
            case remote_target(NickKey, Name) of
                no_such_nick ->
                    {error, <<"401">>, [Nick], <<"No such nick/channel">>, Args};
                not_on_channel ->
                    {error, <<"441">>, [Nick, Name], <<"They aren't on that channel">>, Args};
                {ok, Actual, #remote_channel{members = Remote} = RemoteChannel} ->
                    {Peer, Roles} = maps:get(NickKey, Remote),
                    New =
                        case Action of
                            add -> lists:usort([Role | Roles]);
                            remove -> lists:delete(Role, Roles)
                        end,
                    Updated = RemoteChannel#remote_channel{
                        members = Remote#{NickKey := {Peer, New}}
                    },
                    {remote, Updated, Args, [Actual]}
            end;
        _ ->
            {error, <<"441">>, [Nick, Name], <<"They aren't on that channel">>, Args}
    end;
apply_mode(Mode, _, [], _) when Mode =:= $k; Mode =:= $l; Mode =:= $o; Mode =:= $v ->
    {error, <<"461">>, [<<"MODE">>], <<"Not enough parameters">>, []};
apply_mode(Mode, _, Args, _) ->
    {error, <<"472">>, [<<Mode>>], <<"Unknown mode character">>, Args}.

-doc """
Collapse a list of `{Sign, Mode, Params}` tuples into `{ModeString, Args}`.
""".
-spec mode_line([{char(), char(), [binary()]}]) -> {binary(), [binary()]}.
mode_line(Changes) ->
    {Letters, _} = lists:foldl(
        fun
            ({Sign, Mode, _}, {Acc, Sign}) -> {[Mode | Acc], Sign};
            ({Sign, Mode, _}, {Acc, _}) -> {[Mode, Sign | Acc], Sign}
        end,
        {[], none},
        Changes
    ),
    {list_to_binary(lists:reverse(Letters)), lists:append([P || {_, _, P} <- Changes])}.

invalid_key(_Key, Args, #channel{name = Name}) ->
    {error, <<"696">>, [Name, <<"k">>, <<"*">>], <<"Invalid channel key">>, Args}.

param_token(Value) ->
    case
        Value =:= <<>> orelse binary:match(Value, [<<" ">>]) =/= nomatch orelse
            binary:first(Value) =:= $:
    of
        true -> <<"*">>;
        false -> Value
    end.
