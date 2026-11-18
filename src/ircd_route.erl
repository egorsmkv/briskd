-module(ircd_route).
-export([
    accept_server/4,
    burst_order/1,
    channel_allowed/2,
    max_channels/0,
    nick_collision/2,
    nick_delay_blocked/3,
    resource_delay_seconds/0,
    servers_behind/2,
    should_forward/2
]).

%% Pure routing and numeric decisions for IRC server links.
%% Hop counts follow RFC 2813: a directly connected peer is one hop away, and
%% each introduced server is one hop beyond its parent.

-define(MAX_CHANNELS, 10).
%% RFC 2811 / RFC 2813 abuse window after a nick or channel is lost in a split.
-define(RESOURCE_DELAY_SECONDS, 60).

-spec max_channels() -> pos_integer().
max_channels() -> ?MAX_CHANNELS.

-spec resource_delay_seconds() -> pos_integer().
resource_delay_seconds() -> ?RESOURCE_DELAY_SECONDS.

%% A client may join another channel only while under the configured ceiling.
-spec channel_allowed(non_neg_integer(), pos_integer()) -> boolean().
channel_allowed(Joined, Max) when is_integer(Joined), Joined >= 0, is_integer(Max), Max > 0 ->
    Joined < Max.

%% True when a released nick or channel name is still inside its abuse window.
-spec nick_delay_blocked(term(), integer(), #{term() => integer()}) -> boolean().
nick_delay_blocked(Key, Now, Holds) when is_integer(Now), is_map(Holds) ->
    maps:get(Key, Holds, 0) > Now.

%% Both sides of a nickname collision are removed. A missing side is not.
-spec nick_collision(boolean(), boolean()) -> ok | kill_both.
nick_collision(false, false) ->
    ok;
nick_collision(LocalExists, RemoteExists) when
    is_boolean(LocalExists), is_boolean(RemoteExists)
->
    kill_both.

%% Do not send a routed message back to the link that delivered it.
-spec should_forward(binary(), binary()) -> boolean().
should_forward(Ingress, Adjacent) when is_binary(Ingress), is_binary(Adjacent) ->
    ircd_wire:fold(Ingress) =/= ircd_wire:fold(Adjacent).

%% Servers are introduced nearest-first so a parent exists before its children.
-spec burst_order([map()]) -> [map()].
burst_order(Servers) when is_list(Servers) ->
    lists:sort(
        fun(Left, Right) ->
            {maps:get(hop, Left), ircd_wire:fold(maps:get(name, Left))} =<
                {maps:get(hop, Right), ircd_wire:fold(maps:get(name, Right))}
        end,
        Servers
    ).

%% Names of Lost and every server whose parent chain reaches Lost.
-spec servers_behind(binary(), [map()]) -> [binary()].
servers_behind(Lost, Servers) when is_binary(Lost), is_list(Servers) ->
    [
        maps:get(name, Server)
     || Server <- Servers,
        reaches(maps:get(name, Server), Lost, Servers, #{})
    ].

%% Accept one SERVER introduction, or reject a loop, duplicate, or bad hop.
-spec accept_server(binary(), binary(), map(), [map()]) -> {ok, map()} | {error, atom()}.
accept_server(Local, Ingress, Intro, Servers) when
    is_binary(Local), is_binary(Ingress), is_map(Intro), is_list(Servers)
->
    Name = maps:get(name, Intro),
    Hop = maps:get(hop, Intro),
    Token = maps:get(token, Intro),
    ParentName = maps:get(parent, Intro, Ingress),
    Info = maps:get(info, Intro, <<>>),
    case valid_server_name(Name) andalso is_integer(Hop) andalso is_binary(Token) of
        false ->
            {error, invalid_server};
        true ->
            case ircd_wire:fold(Name) =:= ircd_wire:fold(Local) of
                true ->
                    {error, loop};
                false ->
                    case lookup(Name, Servers) of
                        {ok, _} ->
                            {error, duplicate_route};
                        error ->
                            place_server(
                                Local, Ingress, ParentName, Hop, Name, Token, Info, Servers
                            )
                    end
            end
    end.

place_server(Local, Ingress, ParentName, Hop, Name, Token, Info, Servers) ->
    case ircd_wire:fold(ParentName) =:= ircd_wire:fold(Local) of
        true ->
            {error, bad_hop};
        false ->
            case ircd_wire:fold(ParentName) =:= ircd_wire:fold(Ingress) of
                true when Hop =:= 2 ->
                    {ok, server_map(Name, 2, Token, Ingress, Ingress, Info)};
                true ->
                    {error, bad_hop};
                false ->
                    place_behind(Ingress, ParentName, Hop, Name, Token, Info, Servers)
            end
    end.

place_behind(Ingress, ParentName, Hop, Name, Token, Info, Servers) ->
    case lookup(ParentName, Servers) of
        error ->
            {error, unknown_parent};
        {ok, Parent} ->
            Adjacent = maps:get(adjacent, Parent),
            ViaIngress =
                ircd_wire:fold(Adjacent) =:= ircd_wire:fold(Ingress) orelse
                    ircd_wire:fold(maps:get(name, Parent)) =:= ircd_wire:fold(Ingress),
            case ViaIngress andalso Hop =:= maps:get(hop, Parent) + 1 of
                true ->
                    {ok, server_map(Name, Hop, Token, Adjacent, maps:get(name, Parent), Info)};
                false when ViaIngress ->
                    {error, bad_hop};
                false ->
                    {error, loop}
            end
    end.

reaches(Name, Lost, Servers, Seen) when is_binary(Name), is_binary(Lost) ->
    Fold = ircd_wire:fold(Name),
    case maps:is_key(Fold, Seen) of
        true ->
            false;
        false ->
            ircd_wire:fold(Name) =:= ircd_wire:fold(Lost) orelse
                case lookup(Name, Servers) of
                    {ok, #{parent := Parent}} when is_binary(Parent) ->
                        reaches(Parent, Lost, Servers, Seen#{Fold => true});
                    _ ->
                        false
                end
    end.

lookup(Name, Servers) ->
    Fold = ircd_wire:fold(Name),
    case [Server || Server <- Servers, ircd_wire:fold(maps:get(name, Server)) =:= Fold] of
        [Server | _] -> {ok, Server};
        [] -> error
    end.

server_map(Name, Hop, Token, Adjacent, Parent, Info) ->
    #{
        name => Name,
        hop => Hop,
        token => Token,
        adjacent => Adjacent,
        parent => Parent,
        info => Info
    }.

valid_server_name(Name) when is_binary(Name) ->
    case re:run(Name, <<"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$">>, [{capture, none}, dollar_endonly]) of
        match -> true;
        nomatch -> false
    end;
valid_server_name(_) ->
    false.
