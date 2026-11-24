-module(briskd_state_queries).
-moduledoc """
User queries: `WHO` (with IRCv3 WHOX), `WHOIS`, `WHOWAS`, `ISON`, and `USERHOST`.

Implements RFC 2812 sections 3.6.1 to 3.6.3 and 4.8 to 4.9. Every function
runs inside the single `m:briskd_state` gen_server process and reads the
Mnesia `client`, `channel`, `remote_client`, `remote_channel`, `activity`, and
`whowas` tables that process owns. Nothing here writes state. In every handler
`Client` is the requesting `client` record and `Server` is this server's name,
used as the numeric prefix.

Visibility rules shared by the queries:

- A user with mode `+i` appears in mask searches and `WHOIS` only to a
  requester sharing a channel with them; for remote users that check includes
  remote membership (`briskd_state:remote_user_visible_to_requester/3`). `WHO`
  for an exact local nickname answers even for `+i` users.
- A channel with `+p` or `+s` (locally or as reported by a peer) is listed only
  to its members, and a channel with `+a` (anonymous) never reveals members.
- Users are always named with their home server, not the adjacent link.

Nicknames are compared with the RFC 1459 case mapping of `briskd_wire:fold/1`.
WHOWAS history is written by `m:briskd_state_client` and bounded there.
""".
-export([ison/3, userhost/3, who/3, whois/3, whowas_options/1, whowas_reply/4]).
-include("briskd_state.hrl").

-doc """
Handle `WHO [<mask> [<flags>]]` (RFC 2812 section 3.6.1, IRCv3 WHOX).

`Params` are the command parameters. The mask resolves, in order, to a local
channel (its visible local members, then its remote members), a channel known
only through a server link, an exact local nickname, or a wildcard matched
against nickname, user, host, real name, and `nick!user@host` of every visible
local and remote user. No mask means `*`.

A second parameter of `o` limits the reply to IRC operators. A second
parameter of the form `<flags>%<fields>[,<token>]` selects WHOX: each row is
354 RPL_WHOSPCRPL carrying only the requested fields in the fixed order
`t c u i h s n f d l a o r`, where the token is 1 to 3 digits (an invalid token
falls back to plain WHO). Otherwise each row is 352 RPL_WHOREPLY with status
`H`/`G`, `*` for operators, `B` for bots, and the channel prefix. The IP field
is shown only to the user itself and to IRC operators. The reply always ends
with 315 RPL_ENDOFWHO.
""".
-spec who([binary()], #client{}, binary()) -> ok.
who(Params, Client, Server) ->
    who_command(Params, Client, Server).

-doc """
Handle `ISON <nickname> ...` (RFC 2812 section 4.9).

`Nicks` are the requested nicknames. Replies with one 303 RPL_ISON listing,
in their current spelling, each nickname held by a registered local user or a
known remote user.
""".
-spec ison([binary()], #client{}, binary()) -> ok.
ison(Nicks, Client, Server) ->
    Existing = [
        Actual
     || Nick <- Nicks,
        Actual <- [ison_nick(Nick)],
        Actual =/= undefined
    ],
    briskd_state:numeric(Client, Server, <<"303">>, [], lists:join(<<" ">>, Existing)).

-doc """
Handle `USERHOST <nickname> ...` (RFC 2812 section 4.8).

Only the first five nicknames are considered. Replies with one 302
RPL_USERHOST of `nick[*]=(+|-)host` entries for registered local and known
remote users, where `*` marks an IRC operator and `-` an away user.
""".
-spec userhost([term()], #client{}, binary()) -> ok.
userhost(Nicks, Client, Server) ->
    Entries = lists:filtermap(
        fun(Nick) ->
            case registered_nick(Nick) of
                #client{pid = Pid, nick = Actual, host = Host, away = Away} ->
                    AwayMarker =
                        case Away of
                            undefined -> <<"+">>;
                            _ -> <<"-">>
                        end,
                    OperatorMarker =
                        case maps:is_key($o, briskd_state:user_modes(Pid)) of
                            true -> <<"*">>;
                            false -> <<>>
                        end,
                    {
                        true,
                        <<Actual/binary, OperatorMarker/binary, $=, AwayMarker/binary, Host/binary>>
                    };
                undefined ->
                    remote_userhost(Nick)
            end
        end,
        lists:sublist(Nicks, 5)
    ),
    briskd_state:numeric(Client, Server, <<"302">>, [], lists:join(<<" ">>, Entries)).

%% A local client only counts once its registration has completed.
registered_nick(Nick) ->
    case briskd_state:find_nick(Nick) of
        #client{} = Client ->
            case briskd_state:ready(Client) of
                true -> Client;
                false -> undefined
            end;
        undefined ->
            undefined
    end.

ison_nick(Nick) ->
    case registered_nick(Nick) of
        #client{nick = Actual} ->
            Actual;
        undefined ->
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
                [#remote_client{nick = Actual}] -> Actual;
                [] -> undefined
            end
    end.

remote_userhost(Nick) ->
    case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
        [#remote_client{nick = Actual, host = Host, modes = Modes}] ->
            OperatorMarker =
                case maps:is_key($o, Modes) of
                    true -> <<"*">>;
                    false -> <<>>
                end,
            AwayMarker =
                case maps:is_key($a, Modes) of
                    true -> $-;
                    false -> $+
                end,
            {true, <<Actual/binary, OperatorMarker/binary, $=, AwayMarker, Host/binary>>};
        [] ->
            false
    end.

%% Select WHO matches and format RFC 2812 WHO replies (352), or IRCv3 WHOX
%% replies (354) when the second parameter carries `%<fields>[,<token>]`.
who_command([], Client, Server) ->
    who_mask(<<"*">>, false, undefined, Client, Server);
who_command([Mask, Filter | _], Client, Server) ->
    case binary:split(Filter, <<"%">>) of
        [Flags, Spec] ->
            case whox_spec(Spec) of
                {ok, Fields, Token} ->
                    who_mask(
                        Mask,
                        binary:match(Flags, <<"o">>) =/= nomatch,
                        {Fields, Token},
                        Client,
                        Server
                    );
                error ->
                    who_mask(Mask, false, undefined, Client, Server)
            end;
        [_] ->
            who_mask(Mask, briskd_wire:fold(Filter) =:= <<"o">>, undefined, Client, Server)
    end;
who_command([Mask], Client, Server) ->
    who_mask(Mask, false, undefined, Client, Server).

%% `%<fields>[,<token>]`. The token is 1 to 3 digits. Unknown field letters
%% are ignored, as WHOX requires.
whox_spec(Spec) ->
    {FieldPart, Token} =
        case binary:split(Spec, <<",">>) of
            [F, T] -> {F, T};
            [F] -> {F, undefined}
        end,
    Fields = [C || <<C>> <= FieldPart, lists:member(C, "tcuihsnfdlaor")],
    TokenOk =
        Token =:= undefined orelse
            (byte_size(Token) >= 1 andalso byte_size(Token) =< 3 andalso
                re:run(Token, <<"^[0-9]+$">>, [{capture, none}]) =:= match),
    case TokenOk of
        true -> {ok, Fields, Token};
        false -> error
    end.

%% Emit one WHO row as 352, or as 354 with only the requested WHOX fields in
%% the fixed order t c u i h s n f d l a o r.
emit_who(Requester, Server, Row, undefined) ->
    #{
        channel := C,
        user := U,
        host := H,
        server := S,
        nick := N,
        flags := F,
        hop := D,
        real := R
    } = Row,
    briskd_state:numeric(
        Requester, Server, <<"352">>, [C, U, H, S, N, F], [integer_to_binary(D), <<" ">>, R]
    );
emit_who(Requester, Server, Row, {Fields, Token}) ->
    Order = "tcuihsnfdlaor",
    Wanted = [Field || Field <- Order, lists:member(Field, Fields)],
    {Middle, Trailing} = lists:foldl(
        fun
            ($r, {Acc, _}) -> {Acc, maps:get(real, Row)};
            ($t, {Acc, T}) when Token =:= undefined -> {Acc, T};
            ($t, {Acc, T}) -> {[Token | Acc], T};
            (Field, {Acc, T}) -> {[whox_field(Field, Row) | Acc], T}
        end,
        {[], none},
        Wanted
    ),
    briskd_state:numeric(Requester, Server, <<"354">>, lists:reverse(Middle), Trailing).

whox_field($c, #{channel := V}) -> V;
whox_field($u, #{user := V}) -> V;
whox_field($i, #{ip := V}) -> V;
whox_field($h, #{host := V}) -> V;
whox_field($s, #{server := V}) -> V;
whox_field($n, #{nick := V}) -> V;
whox_field($f, #{flags := V}) -> V;
whox_field($d, #{hop := V}) -> integer_to_binary(V);
whox_field($l, #{idle := V}) -> integer_to_binary(V);
whox_field($a, #{account := undefined}) -> <<"0">>;
whox_field($a, #{account := V}) -> V;
whox_field($o, _) -> <<"n/a">>.

who_mask(Mask, OperatorsOnly, Whox, Client, Server) ->
    ChannelKey = briskd_wire:fold(Mask),
    case mnesia:dirty_read(channel, ChannelKey) of
        [#channel{name = Name, members = Members, flags = Flags}] ->
            RemoteFlags = briskd_state:remote_channel_flags(Name),
            LocalMember = maps:is_key(Client#client.pid, Members),
            Visible =
                not (maps:is_key($a, Flags) orelse maps:is_key($a, RemoteFlags)) andalso
                    (LocalMember orelse
                        not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags) orelse
                            maps:is_key($p, RemoteFlags) orelse maps:is_key($s, RemoteFlags))),
            lists:foreach(
                fun(Pid) ->
                    case {Visible, mnesia:dirty_read(client, Pid)} of
                        {true, [Member]} ->
                            case
                                briskd_state:visible_member(Pid, Client, Members) andalso
                                    who_operator_matches(Pid, OperatorsOnly)
                            of
                                true -> who_reply(Member, Name, Client, Server, Whox);
                                false -> ok
                            end;
                        _ ->
                            ok
                    end
                end,
                maps:keys(Members)
            ),
            case Visible of
                true -> remote_who_channel(Name, Client, OperatorsOnly, Server, Whox);
                false -> ok
            end;
        [] ->
            case mnesia:dirty_read(remote_channel, ChannelKey) of
                [#remote_channel{name = Name}] ->
                    remote_who_channel(Name, Client, OperatorsOnly, Server, Whox);
                [] ->
                    who_mask_nonchannel(Mask, OperatorsOnly, Client, Server, Whox)
            end
    end,
    briskd_state:numeric(Client, Server, <<"315">>, [Mask], <<"End of WHO list">>).

who_mask_nonchannel(Mask, OperatorsOnly, Client, Server, Whox) ->
    case briskd_state:find_nick(Mask) of
        #client{} = Member ->
            %% An exact nickname is answered even for +i users; invisibility
            %% only hides users from mask searches.
            case
                briskd_state:ready(Member) andalso
                    who_operator_matches(Member#client.pid, OperatorsOnly)
            of
                true -> who_reply(Member, <<"*">>, Client, Server, Whox);
                false -> ok
            end;
        undefined ->
            lists:foreach(
                fun(Pid) ->
                    case mnesia:dirty_read(client, Pid) of
                        [#client{} = Member] ->
                            case
                                briskd_state:ready(Member) andalso who_matches(Mask, Member) andalso
                                    briskd_state:user_visible(Member, Client) andalso
                                    who_operator_matches(Member#client.pid, OperatorsOnly)
                            of
                                true ->
                                    who_reply(
                                        Member, who_channel(Member, Client), Client, Server, Whox
                                    );
                                false ->
                                    ok
                            end;
                        [] ->
                            ok
                    end
                end,
                briskd_state_client:pids()
            ),
            remote_who_mask(Mask, OperatorsOnly, Client, Server, Whox)
    end.

remote_who_channel(Name, Client, OperatorsOnly, Server, Whox) ->
    case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
        [#remote_channel{name = Canonical, members = Members, flags = Flags}] ->
            LocalMember =
                case mnesia:dirty_read(channel, briskd_wire:fold(Name)) of
                    [#channel{members = LocalMembers}] ->
                        maps:is_key(Client#client.pid, LocalMembers);
                    [] ->
                        false
                end,
            Visible =
                not maps:is_key($a, Flags) andalso
                    (LocalMember orelse not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))),
            case Visible of
                false ->
                    ok;
                true ->
                    lists:foreach(
                        fun({NickKey, {_Peer, Roles}}) ->
                            case mnesia:dirty_read(remote_client, NickKey) of
                                [
                                    #remote_client{
                                        nick = Nick,
                                        user = User,
                                        host = Host,
                                        real = Real,
                                        server = Home,
                                        peer = Peer,
                                        modes = Modes
                                    }
                                ] ->
                                    IsOperator = maps:is_key($o, Modes),
                                    case
                                        briskd_state:remote_user_visible_to_requester(
                                            NickKey, Modes, Client
                                        ) andalso
                                            (not OperatorsOnly orelse IsOperator)
                                    of
                                        true ->
                                            Away =
                                                case maps:is_key($a, Modes) of
                                                    true -> $G;
                                                    false -> $H
                                                end,
                                            UserOperator =
                                                case IsOperator of
                                                    true -> $*;
                                                    false -> <<>>
                                                end,
                                            ChannelStatus = briskd_state_channel:role_prefix(
                                                Roles, Client#client.pid
                                            ),
                                            Status = list_to_binary([
                                                Away, UserOperator, bot_flag(Modes), ChannelStatus
                                            ]),
                                            emit_who(
                                                Client,
                                                Server,
                                                remote_row(
                                                    NickKey,
                                                    Canonical,
                                                    Status,
                                                    Home,
                                                    Peer,
                                                    Nick,
                                                    User,
                                                    Host,
                                                    Real
                                                ),
                                                Whox
                                            );
                                        false ->
                                            ok
                                    end;
                                [] ->
                                    ok
                            end
                        end,
                        maps:to_list(Members)
                    )
            end;
        [] ->
            ok
    end.

who_operator_matches(_Pid, false) ->
    true;
who_operator_matches(Pid, true) ->
    maps:is_key($o, briskd_state:user_modes(Pid)).

remote_who_mask(Mask, OperatorsOnly, Client, Server, Whox) ->
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(remote_client, Key) of
                [
                    #remote_client{
                        nick = Nick,
                        user = User,
                        host = Host,
                        real = Real,
                        server = Home,
                        peer = Peer,
                        modes = Modes
                    }
                ] ->
                    Matches =
                        (Mask =:= <<"*">> orelse briskd_state:wildcard_match(Mask, Nick) orelse
                            briskd_state:wildcard_match(Mask, User) orelse
                            briskd_state:wildcard_match(Mask, Host) orelse
                            briskd_state:wildcard_match(Mask, Real)),
                    Visible = briskd_state:remote_user_visible_to_requester(
                        briskd_wire:fold(Nick), Modes, Client
                    ),
                    Operator = maps:is_key($o, Modes),
                    Away = maps:is_key($a, Modes),
                    case Matches andalso Visible andalso (not OperatorsOnly orelse Operator) of
                        true ->
                            Status =
                                list_to_binary([
                                    case Away of
                                        true -> $G;
                                        false -> $H
                                    end,
                                    case Operator of
                                        true -> $*;
                                        false -> <<>>
                                    end,
                                    bot_flag(Modes)
                                ]),
                            emit_who(
                                Client,
                                Server,
                                remote_row(
                                    Key, <<"*">>, Status, Home, Peer, Nick, User, Host, Real
                                ),
                                Whox
                            );
                        false ->
                            ok
                    end;
                [] ->
                    ok
            end
        end,
        briskd_state:table_keys(remote_client)
    ).

bot_flag(Modes) ->
    case maps:is_key($B, Modes) of
        true -> <<"B">>;
        false -> <<>>
    end.

remote_row(NickKey, Channel, Status, Home, Peer, Nick, User, Host, Real) ->
    Hop =
        case mnesia:dirty_read(remote_client, NickKey) of
            [#remote_client{hop = H}] when is_integer(H) -> H;
            _ -> 1
        end,
    #{
        channel => Channel,
        user => User,
        ip => <<"255.255.255.255">>,
        host => Host,
        server => home_server_name(Home, Peer),
        nick => Nick,
        flags => Status,
        hop => Hop,
        idle => 0,
        account => briskd_state_v3:remote_account(NickKey),
        real => Real
    }.

who_matches(<<"*">>, _) ->
    true;
who_matches(Mask, #client{nick = Nick, user = User, host = Host, real = Real}) ->
    Identity = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
    briskd_state:wildcard_match(Mask, Nick) orelse briskd_state:wildcard_match(Mask, User) orelse
        briskd_state:wildcard_match(Mask, Host) orelse briskd_state:wildcard_match(Mask, Real) orelse
        briskd_state:wildcard_match(Mask, Identity).

who_channel(#client{channels = Keys}, #client{pid = RequesterPid}) ->
    case
        [
            Name
         || Key <- Keys,
            [#channel{name = Name, members = Members, flags = Flags}] <-
                [mnesia:dirty_read(channel, Key)],
            not maps:is_key($a, Flags),
            maps:is_key(RequesterPid, Members) orelse
                not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))
        ]
    of
        [Name | _] -> Name;
        [] -> <<"*">>
    end.

who_reply(
    #client{nick = Nick, user = User, host = Host, real = Real} = Member,
    Channel,
    Requester,
    Server,
    Whox
) ->
    Away =
        case Member#client.away of
            undefined -> <<"H">>;
            _ -> <<"G">>
        end,
    Roles =
        case mnesia:dirty_read(channel, briskd_wire:fold(Channel)) of
            [#channel{members = Members}] -> maps:get(Member#client.pid, Members, []);
            [] -> []
        end,
    ChannelStatus = briskd_state_channel:role_prefix(Roles, Requester#client.pid),
    Modes = briskd_state:user_modes(Member#client.pid),
    UserOperator =
        case maps:is_key($o, Modes) of
            true -> <<"*">>;
            false -> <<>>
        end,
    Bot =
        case maps:is_key($B, Modes) of
            true -> <<"B">>;
            false -> <<>>
        end,
    Status = <<Away/binary, UserOperator/binary, Bot/binary, ChannelStatus/binary>>,
    Idle =
        case mnesia:dirty_read(activity, Member#client.pid) of
            [#activity{last = Last}] -> max(0, erlang:system_time(second) - Last);
            [] -> 0
        end,
    emit_who(
        Requester,
        Server,
        #{
            channel => Channel,
            user => User,
            ip => visible_ip(Member, Requester),
            host => Host,
            server => Server,
            nick => Nick,
            flags => Status,
            hop => 0,
            idle => Idle,
            account => briskd_state_v3:account(Member#client.pid),
            real => Real
        },
        Whox
    ).

%% WHOX `i`: the address is shown to the user and to IRC operators only.
visible_ip(#client{pid = Pid, host = Host}, #client{pid = Requester}) ->
    case Pid =:= Requester orelse maps:is_key($o, briskd_state:user_modes(Requester)) of
        true ->
            case maps:get(ip, briskd_cap:info(Pid), undefined) of
                undefined ->
                    case inet:parse_address(binary_to_list(Host)) of
                        {ok, _} -> Host;
                        _ -> <<"255.255.255.255">>
                    end;
                Ip ->
                    Ip
            end;
        false ->
            <<"255.255.255.255">>
    end.

whois_operator(Nick, Pid, Client, Server) ->
    case maps:is_key($o, briskd_state:user_modes(Pid)) of
        false ->
            ok;
        true ->
            Text =
                case briskd_state:administrator(Pid) of
                    true -> <<"is an IRC administrator">>;
                    false -> <<"is an IRC operator">>
                end,
            briskd_state:numeric(Client, Server, <<"313">>, [Nick], Text)
    end.

-doc """
Answer `WHOIS` for one exact nickname (RFC 2812 section 3.6.2).

`Nick` is a single nickname; the caller splits the comma list. For a visible
local user the reply is 311 RPL_WHOISUSER, 301 RPL_AWAY when away, 319
RPL_WHOISCHANNELS (wrapped into several lines, omitting `+a` channels and
`+p`/`+s` channels the requester is not on), 312 RPL_WHOISSERVER, 313
RPL_WHOISOPERATOR (administrators are named as such), 330 RPL_WHOISACCOUNT
when logged in, 335 RPL_WHOISBOT for `+B`, and 317 RPL_WHOISIDLE. A remote
user gets 311, 312 with the home server, 301, 313, 330, and 335 as they apply.
An unknown or invisible nickname gets 401 ERR_NOSUCHNICK. Every reply ends
with 318 RPL_ENDOFWHOIS.
""".
-spec whois(binary(), #client{}, binary()) -> ok.
whois(Nick, Client, Server) ->
    case briskd_state:find_nick(Nick) of
        #client{
            pid = TargetPid,
            nick = Actual,
            user = User,
            host = Host,
            real = Real,
            away = Away,
            channels = Channels
        } = Target when is_binary(User), is_binary(Real) ->
            case briskd_state:user_visible(Target, Client) of
                true ->
                    briskd_state:numeric(
                        Client, Server, <<"311">>, [Actual, User, Host, <<"*">>], Real
                    ),
                    case Away of
                        undefined -> ok;
                        _ -> briskd_state:numeric(Client, Server, <<"301">>, [Actual], Away)
                    end,
                    whois_channels(Channels, TargetPid, Actual, Client, Server),
                    briskd_state:numeric(
                        Client, Server, <<"312">>, [Actual, Server], <<"IRC server">>
                    ),
                    whois_operator(Actual, TargetPid, Client, Server),
                    whois_v3(
                        Actual,
                        briskd_state_v3:account(TargetPid),
                        maps:is_key($B, briskd_state:user_modes(TargetPid)),
                        Client,
                        Server
                    ),
                    Idle =
                        case mnesia:dirty_read(activity, TargetPid) of
                            [#activity{last = Last}] ->
                                max(0, erlang:system_time(second) - Last);
                            [] ->
                                0
                        end,
                    %% RPL_WHOISIDLE: <nick> <idle seconds> <signon time>
                    Signon = briskd_conn:get(TargetPid, signon, erlang:system_time(second)),
                    briskd_state:numeric(
                        Client,
                        Server,
                        <<"317">>,
                        [Actual, integer_to_binary(Idle), integer_to_binary(Signon)],
                        <<"seconds idle, signon time">>
                    );
                false ->
                    briskd_state:numeric(
                        Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>
                    )
            end;
        _ ->
            remote_whois(Nick, Client, Server)
    end,
    briskd_state:numeric(Client, Server, <<"318">>, [Nick], <<"End of WHOIS list">>).

%% WHO and WHOIS name the user's home server. `peer` is only the adjacent link.
home_server_name(Server, _Peer) when is_binary(Server) ->
    Server;
home_server_name(_Server, Peer) ->
    Peer.

remote_whois(Nick, Client, Server) ->
    case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
        [#remote_client{} = Remote] ->
            Actual = Remote#remote_client.nick,
            User = Remote#remote_client.user,
            Host = Remote#remote_client.host,
            Peer = home_server_name(Remote#remote_client.server, Remote#remote_client.peer),
            Real = Remote#remote_client.real,
            Modes = Remote#remote_client.modes,
            case
                briskd_state:remote_user_visible_to_requester(
                    briskd_wire:fold(Actual), Modes, Client
                )
            of
                false ->
                    briskd_state:numeric(
                        Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>
                    );
                true ->
                    briskd_state:numeric(
                        Client, Server, <<"311">>, [Actual, User, Host, <<"*">>], Real
                    ),
                    briskd_state:numeric(
                        Client, Server, <<"312">>, [Actual, Peer], <<"IRC server">>
                    ),
                    case maps:is_key($a, Modes) of
                        true ->
                            briskd_state:numeric(
                                Client, Server, <<"301">>, [Actual], <<"is away">>
                            );
                        false ->
                            ok
                    end,
                    case maps:is_key($o, Modes) of
                        true ->
                            briskd_state:numeric(
                                Client,
                                Server,
                                <<"313">>,
                                [Actual],
                                <<"is an IRC operator">>
                            );
                        false ->
                            ok
                    end,
                    whois_v3(
                        Actual, Remote#remote_client.account, maps:is_key($B, Modes), Client, Server
                    )
            end;
        [] ->
            briskd_state:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>)
    end.

%% RPL_WHOISACCOUNT (330) and RPL_WHOISBOT (335, IRCv3 bot mode).
whois_v3(Nick, Account, Bot, Client, Server) ->
    case Account of
        undefined -> ok;
        _ -> briskd_state:numeric(Client, Server, <<"330">>, [Nick, Account], <<"is logged in as">>)
    end,
    case Bot of
        true -> briskd_state:numeric(Client, Server, <<"335">>, [Nick], <<"is a bot">>);
        false -> ok
    end.

whois_channels(Keys, Pid, Nick, Client, Server) ->
    Entries = lists:filtermap(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{name = Name, members = Members, flags = Flags}] ->
                    Roles = maps:get(Pid, Members, []),
                    Visible =
                        not maps:is_key($a, Flags) andalso
                            (maps:is_key(Client#client.pid, Members) orelse
                                not (maps:is_key($p, Flags) orelse maps:is_key($s, Flags))),
                    case Visible of
                        false ->
                            false;
                        true ->
                            Prefix = briskd_state_channel:role_prefix(Roles, Client#client.pid),
                            {true, <<Prefix/binary, Name/binary>>}
                    end;
                [] ->
                    false
            end
        end,
        Keys
    ),
    case Entries of
        [] -> ok;
        _ -> whois_channel_lines(Entries, [], 0, Nick, Client, Server)
    end.

whois_channel_lines([], [], _, _, _, _) ->
    ok;
whois_channel_lines([], Acc, _, Nick, Client, Server) ->
    emit_whois_channels(lists:reverse(Acc), Nick, Client, Server);
whois_channel_lines([Entry | Rest], [], _, Nick, Client, Server) ->
    whois_channel_lines(Rest, [Entry], byte_size(Entry), Nick, Client, Server);
whois_channel_lines([Entry | Rest], Acc, Size, Nick, Client, Server) when
    Size + byte_size(Entry) + 1 =< 350
->
    whois_channel_lines(
        Rest,
        [Entry | Acc],
        Size + byte_size(Entry) + 1,
        Nick,
        Client,
        Server
    );
whois_channel_lines([Entry | Rest], Acc, _, Nick, Client, Server) ->
    emit_whois_channels(lists:reverse(Acc), Nick, Client, Server),
    whois_channel_lines([Entry | Rest], [], 0, Nick, Client, Server).

emit_whois_channels(Entries, Nick, Client, Server) ->
    briskd_state:numeric(Client, Server, <<"319">>, [Nick], lists:join(<<" ">>, Entries)).

-doc """
Parse the optional `[<count> [<target>]]` parameters of `WHOWAS`.

Returns `{Count, Target}`. A missing or non-numeric count is `all`, and a
missing target is `undefined`.
""".
-spec whowas_options([binary()]) -> {all | integer(), undefined | binary()}.
whowas_options([]) ->
    {all, undefined};
whowas_options([Count | Rest]) ->
    Target =
        case Rest of
            [Value | _] -> Value;
            [] -> undefined
        end,
    try binary_to_integer(Count) of
        Limit -> {Limit, Target}
    catch
        error:badarg -> {all, Target}
    end.

-doc """
Send the WHOWAS entries for one nickname or nickname mask (RFC 2812 section 3.6.3).

`Nick` may contain `*` and `?`. Entries are sent newest first, each as 314
RPL_WHOWASUSER followed by 312 RPL_WHOISSERVER; a positive `Count` limits how
many are sent, and `all` or a non-positive count sends every match. With no
match the reply is 406 ERR_WASNOSUCHNICK. Returns the nicknames that were
reported. The caller sends 369 RPL_ENDOFWHOWAS.
""".
-spec whowas_reply(binary(), all | integer(), #client{}, binary()) -> [binary()].
whowas_reply(Nick, Count, Client, Server) ->
    Folded = briskd_wire:fold(Nick),
    Matched =
        case binary:match(Nick, [<<"*">>, <<"?">>]) of
            nomatch ->
                mnesia:dirty_select(whowas, [
                    {{whowas, {Folded, '_', '_'}, '_', '_', '_', '_', '_', '_'}, [], ['$_']}
                ]);
            _ ->
                [
                    Entry
                 || Key <- mnesia:dirty_all_keys(whowas),
                    [Entry = #whowas{nick = StoredNick}] <- [mnesia:dirty_read(whowas, Key)],
                    briskd_wire:fold(StoredNick) =:= Folded orelse
                        briskd_state:wildcard_match(Nick, StoredNick)
                ]
        end,
    History = lists:sort(
        fun(#whowas{time = Left}, #whowas{time = Right}) -> Left > Right end,
        Matched
    ),
    Results =
        case Count of
            Limit when is_integer(Limit), Limit > 0 -> lists:sublist(History, Limit);
            _ -> History
        end,
    case Results of
        [] ->
            briskd_state:numeric(
                Client, Server, <<"406">>, [Nick], <<"There was no such nickname">>
            ),
            [];
        _ ->
            lists:foreach(
                fun(Entry) ->
                    #whowas{
                        nick = OldNick,
                        user = User,
                        host = Host,
                        real = Real,
                        server = OldServer
                    } = Entry,
                    briskd_state:numeric(
                        Client,
                        Server,
                        <<"314">>,
                        [OldNick, User, Host, <<"*">>],
                        Real
                    ),
                    briskd_state:numeric(
                        Client,
                        Server,
                        <<"312">>,
                        [OldNick, OldServer],
                        <<"IRC server">>
                    )
                end,
                Results
            ),
            [OldNick || #whowas{nick = OldNick} <- Results]
    end.
