-module(briskd_link_burst).
-moduledoc """
Server-link state burst generation (`SERVER`, `NICK`, `NJOIN`, `MODE`, `TOPIC`)
for newly authenticated peers (RFC 2813 section 5.3.2).
""".
-export([
    channel_mode_burst/6,
    njoin_member/2,
    remote_nick_line/8,
    server_burst_lines/1
]).
-include("briskd_client.hrl").
-include("briskd_channel.hrl").
-include("briskd_remote.hrl").

-doc """
Every line of the state burst sent to a newly authenticated peer (RFC 2813
section 5.3.2).

`Server` is the local server name, used as the prefix of server-generated
lines. The order is: known servers nearest first, registered local users as
`NICK`, remote users (prefixed by their home server), IRCv3 account state
from `briskd_state_v3:burst_lines/1`, local channels (`NJOIN`, modes, list
entries, `+O` creator, topic), accounts, metadata, and read markers from
`briskd_state_sync:burst_lines/1`, and finally remote channels. Members are
packed into as few `NJOIN` lines as fit in 512 octets.
""".
-spec server_burst_lines(binary()) -> [iodata()].
server_burst_lines(Server) ->
    ServerLines = briskd_state_net:burst_server_lines(Server),
    ClientLines =
        lists:flatmap(
            fun(Pid) ->
                case mnesia:dirty_read(client, Pid) of
                    [#client{} = Client] ->
                        case briskd_state_client:ready(Client) of
                            true -> client_burst_lines(Client, Server);
                            false -> []
                        end;
                    _ ->
                        []
                end
            end,
            briskd_state_client:pids()
        ),
    ChannelLines =
        lists:flatmap(
            fun(Key) ->
                case mnesia:dirty_read(channel, Key) of
                    %% `&` channels are local to this server (RFC 2811).
                    [#channel{name = <<$&, _/binary>>}] -> [];
                    [#channel{} = Channel] -> channel_burst_lines(Channel, Server);
                    [] -> []
                end
            end,
            briskd_state:table_keys(channel)
        ),
    ServerLines ++ ClientLines ++ remote_client_burst_lines() ++
        briskd_state_v3:burst_lines(Server) ++ ChannelLines ++ briskd_state_sync:burst_lines(Server) ++
        remote_channel_burst_lines(Server) ++ briskd_e2ee:burst_lines().

client_burst_lines(
    #client{nick = Nick, user = User, host = Host, real = Real, pid = Pid}, Server
) ->
    Modes = briskd_state_channel:user_mode_string(briskd_state_client:user_modes(Pid)),
    [
        iolist_to_binary(
            briskd_wire:line(
                Server,
                <<"NICK">>,
                [Nick, <<"0">>, User, Host, <<"1">>, Modes],
                Real
            )
        )
    ].

remote_client_burst_lines() ->
    lists:flatmap(
        fun(Key) ->
            case mnesia:dirty_read(remote_client, Key) of
                [#remote_client{server = Home, peer = Peer} = Remote] ->
                    Prefix =
                        case Home of
                            undefined -> Peer;
                            _ -> Home
                        end,
                    [iolist_to_binary(stored_nick_line(Prefix, Remote))];
                [] ->
                    []
            end
        end,
        briskd_state:table_keys(remote_client)
    ).

stored_nick_line(
    Prefix,
    #remote_client{
        nick = Nick, hop = Hop, user = User, host = Host, token = Token, modes = Modes, real = Real
    }
) ->
    remote_nick_line(Prefix, Nick, Hop, User, Host, Token, Modes, Real).

-doc """
Format a 7-parameter `NICK` server-link line for a remote user.
""".
-spec remote_nick_line(
    binary(),
    binary(),
    non_neg_integer(),
    binary(),
    binary(),
    binary(),
    #{byte() => true},
    binary()
) -> iodata().
remote_nick_line(Prefix, Nick, Hop, User, Host, Token, Modes, Real) ->
    briskd_wire:line(
        Prefix,
        <<"NICK">>,
        [
            Nick,
            integer_to_binary(Hop),
            User,
            Host,
            Token,
            briskd_state_channel:user_mode_string(Modes)
        ],
        Real
    ).

remote_channel_burst_lines(Server) ->
    lists:flatmap(
        fun(Key) ->
            case mnesia:dirty_read(remote_channel, Key) of
                [#remote_channel{} = Channel] -> remote_channel_lines(Channel, Server);
                [] -> []
            end
        end,
        briskd_state:table_keys(remote_channel)
    ).

remote_channel_lines(#remote_channel{name = Name, members = Members, flags = Flags}, Server) ->
    Tokens = [
        remote_njoin_token(Remote#remote_client.nick, Roles)
     || {NickKey, {_Peer, Roles}} <- maps:to_list(Members),
        [#remote_client{} = Remote] <- [mnesia:dirty_read(remote_client, NickKey)]
    ],
    ModeFlags = maps:from_keys([Key || Key <- maps:keys(Flags), is_integer(Key)], true),
    TopicLines =
        case maps:get(topic, Flags, <<>>) of
            <<>> -> [];
            Topic -> [briskd_wire:line(Server, <<"TOPIC">>, [Name], Topic)]
        end,
    njoin_lines(Name, Tokens, Server) ++
        channel_mode_burst(
            Name,
            ModeFlags,
            maps:get(key, Flags, undefined),
            maps:get(limit, Flags, undefined),
            maps:with([ban, exception, invite], Flags),
            Server
        ) ++ TopicLines.

remote_njoin_token(Nick, Roles) ->
    case
        {lists:member(creator, Roles), lists:member(operator, Roles), lists:member(voice, Roles)}
    of
        {true, _, true} -> <<"@@+", Nick/binary>>;
        {true, _, false} -> <<"@@", Nick/binary>>;
        {false, true, true} -> <<"@+", Nick/binary>>;
        {false, true, false} -> <<$@, Nick/binary>>;
        {false, false, true} -> <<$+, Nick/binary>>;
        _ -> Nick
    end.

channel_burst_lines(
    #channel{
        name = Name,
        members = Members,
        flags = Flags,
        lists = Lists,
        creator = Creator,
        password = Password,
        limit = Limit,
        topic = Topic
    },
    Server
) ->
    LiveMembers =
        [
            {Pid, Client, Roles}
         || {Pid, Roles} <- maps:to_list(Members),
            [#client{} = Client] <- [mnesia:dirty_read(client, Pid)],
            briskd_state_client:ready(Client)
        ],
    NjoinLines =
        njoin_lines(
            Name,
            [njoin_member(Client, Roles) || {_Pid, Client, Roles} <- LiveMembers],
            Server
        ),
    CreatorLines =
        case lists:keyfind(Creator, 1, LiveMembers) of
            {Creator, CreatorClient, _} ->
                [
                    briskd_wire:line(
                        Server,
                        <<"MODE">>,
                        [Name, <<"+O">>, CreatorClient#client.nick],
                        none
                    )
                ];
            false ->
                []
        end,
    TopicLines =
        case Topic of
            <<>> -> [];
            _ -> [briskd_wire:line(Server, <<"TOPIC">>, [Name], Topic)]
        end,
    NjoinLines ++ channel_mode_burst(Name, Flags, Password, Limit, Lists, Server) ++
        CreatorLines ++ TopicLines.

-doc """
Format a client nickname with its `NJOIN` role prefixes (`@@`, `@`, `+`).
""".
-spec njoin_member(#client{}, [channel_role()]) -> binary().
njoin_member(#client{nick = Nick}, Roles) ->
    remote_njoin_token(Nick, Roles).

njoin_lines(_Name, [], _Server) ->
    [];
njoin_lines(Name, Members, Server) ->
    PrefixSize = byte_size(Server) + byte_size(Name) + 11,
    MaxMembers = max(1, 510 - PrefixSize),
    Batches = member_batches(Members, MaxMembers, [], 0, []),
    [briskd_wire:line(Server, <<"NJOIN">>, [Name], lists:join(<<$,>>, Batch)) || Batch <- Batches].

member_batches([], _Max, [], _Size, Batches) ->
    lists:reverse(Batches);
member_batches([], _Max, Current, _Size, Batches) ->
    lists:reverse([lists:reverse(Current) | Batches]);
member_batches([Member | Rest], Max, Current, Size, Batches) ->
    AddedSize =
        byte_size(Member) +
            case Current of
                [] -> 0;
                _ -> 1
            end,
    case Size + AddedSize =< Max of
        true ->
            member_batches(Rest, Max, [Member | Current], Size + AddedSize, Batches);
        false when Current =:= [] ->
            member_batches(Rest, Max, [Member], byte_size(Member), Batches);
        false ->
            member_batches(
                [Member | Rest], Max, [], 0, [lists:reverse(Current) | Batches]
            )
    end.

-doc """
Format channel `MODE` lines for flags, key, limit, and mask lists in a burst or
outbound `JOIN` sync.
""".
-spec channel_mode_burst(
    binary(),
    #{byte() => true},
    undefined | binary(),
    undefined | pos_integer(),
    #{atom() => [binary()]},
    binary()
) -> [iodata()].
channel_mode_burst(Name, Flags, Password, Limit, Lists, Server) ->
    KeyMode =
        case Password of
            undefined -> [];
            _ -> [$k]
        end,
    LimitMode =
        case Limit of
            undefined -> [];
            _ -> [$l]
        end,
    Modes = lists:sort(maps:keys(Flags)) ++ KeyMode ++ LimitMode,
    Args =
        (case Password of
            undefined -> [];
            _ -> [Password]
        end) ++
            (case Limit of
                undefined -> [];
                _ -> [integer_to_binary(Limit)]
            end),
    FlagLines =
        case Modes of
            [] ->
                [];
            _ ->
                [
                    briskd_wire:line(
                        Server, <<"MODE">>, [Name, list_to_binary([$+ | Modes]) | Args], none
                    )
                ]
        end,
    AccessLines =
        lists:flatmap(
            fun({Type, Mode}) ->
                [
                    briskd_wire:line(Server, <<"MODE">>, [Name, <<$+, Mode>>, Mask], none)
                 || Mask <- maps:get(Type, Lists, [])
                ]
            end,
            [{ban, $b}, {exception, $e}, {invite, $I}]
        ),
    FlagLines ++ AccessLines.
