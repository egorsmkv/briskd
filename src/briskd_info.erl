-module(briskd_info).
-moduledoc """
Server information and O(1) population query handlers.

Implements `INFO`, `ADMIN`, `LINKS`, `LUSERS`, `MOTD` (delegated to
`m:briskd_motd`), `USERS` (446 ERR_USERSDISABLED), `TIME`, and `VERSION`
(RFC 2812 sections 3.4 and 4.5).

`LUSERS` reads a single coherent `#population{}` snapshot from
`briskd_population:snapshot/0` in O(1) without scanning users or channels.
`ADMIN`, `LINKS`, and `INFO` read the versioned configuration snapshot in
`m:briskd_rehash` and cached compile metadata (`init_info/0`).
""".

-export([
    init_info/0,
    query_local_server/2,
    admin/3,
    info/3,
    links/3,
    lusers/3,
    motd/3,
    users_disabled/3,
    time/3,
    version/3
]).

-include("briskd_state.hrl").
-include("briskd_population.hrl").

-define(COMPILED_KEY, {?MODULE, compiled}).

-doc """
Cache the formatted compile timestamp of `briskd_state` in `persistent_term`.
Handles missing (`undefined`) compile time metadata safely.
""".
-spec init_info() -> ok.
init_info() ->
    CompileTime = proplists:get_value(time, briskd_state:module_info(compile)),
    CompileText = format_compile_time(CompileTime),
    persistent_term:put(?COMPILED_KEY, CompileText).

-doc """
Check an optional server argument against this server's name.

`Params` is the remaining parameter list; its first element, when present, is
a wildcard mask matched against `Server`. Returns `true` for no argument or a
match, otherwise `{false, Target}` so the caller can send 402 ERR_NOSUCHSERVER.
""".
-spec query_local_server([binary()], binary()) -> true | {false, binary()}.
query_local_server([], _) ->
    true;
query_local_server([Target | _], Server) ->
    case briskd_state_channel:wildcard_match(Target, Server) of
        true -> true;
        false -> {false, Target}
    end.

-doc """
Handle `ADMIN [<target>]` (RFC 2812 section 3.4.9).
""".
-spec admin([binary()], #client{}, binary()) -> ok.
admin(Params, Client, Server) ->
    case admin_target(Params, Server) of
        {false, Target} ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            #{admin := Info} = briskd_rehash:current(),
            briskd_state_send:numeric(
                Client,
                Server,
                <<"256">>,
                [Server],
                maps:get(name, Info, <<"IRC server administrator">>)
            ),
            briskd_state_send:numeric(
                Client, Server, <<"257">>, [], maps:get(location1, Info, <<"Not configured">>)
            ),
            briskd_state_send:numeric(
                Client, Server, <<"258">>, [], maps:get(location2, Info, <<"Not configured">>)
            ),
            briskd_state_send:numeric(
                Client, Server, <<"259">>, [], maps:get(email, Info, <<"Not configured">>)
            )
    end.

-doc """
Handle `INFO [<target>]` (RFC 2812 section 3.4.10).
""".
-spec info([binary()], #client{}, binary()) -> ok.
info(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        {false, Target} ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            CompileText = compiled_text(),
            Started = started_text(),
            briskd_state_send:numeric(
                Client,
                Server,
                <<"371">>,
                [],
                <<"briskd-", (briskd_app:vsn())/binary, ", Erlang/OTP IRC server">>
            ),
            briskd_state_send:numeric(Client, Server, <<"371">>, [], [<<"Compiled: ">>, CompileText]),
            briskd_state_send:numeric(Client, Server, <<"371">>, [], <<"Patch level: 0">>),
            briskd_state_send:numeric(Client, Server, <<"371">>, [], [<<"Started: ">>, Started]),
            briskd_state_send:numeric(
                Client,
                Server,
                <<"371">>,
                [],
                <<"Protocol references: RFC 1459, 2810, 2811, 2812, 2813, 7194">>
            ),
            briskd_state_send:numeric(Client, Server, <<"374">>, [], <<"End of INFO list">>)
    end.

-doc """
Handle `LINKS [[<remote server>] <server mask>]` (RFC 2812 section 3.4.5).
""".
-spec links([binary()], #client{}, binary()) -> ok.
links(Params, Client, Server) ->
    {Remotes, Mask} =
        case Params of
            [] -> {[], <<"*">>};
            [GivenMask] -> {[], GivenMask};
            [GivenRemote, GivenMask | _] -> {[GivenRemote], GivenMask}
        end,
    case query_local_server(Remotes, Server) of
        {false, Remote} ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Remote], <<"No such server">>);
        true ->
            #{server_info := ServerInfo} = briskd_rehash:current(),
            case briskd_state_channel:wildcard_match(Mask, Server) of
                true ->
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"364">>,
                        [Server, Server],
                        [<<"0 ">>, ServerInfo]
                    );
                false ->
                    ok
            end,
            lists:foreach(
                fun({Name, Hop, Info}) ->
                    case briskd_state_channel:wildcard_match(Mask, Name) of
                        true ->
                            briskd_state_send:numeric(
                                Client,
                                Server,
                                <<"364">>,
                                [Name, Server],
                                [integer_to_binary(Hop), <<" ">>, Info]
                            );
                        false ->
                            ok
                    end
                end,
                briskd_state_net:links_entries()
            ),
            briskd_state_send:numeric(Client, Server, <<"365">>, [Mask], <<"End of LINKS list">>)
    end.

-doc """
Handle `LUSERS [<mask> [<target>]]` (RFC 2812 section 3.4.2) in O(1).

Reads a single coherent `#population{}` snapshot from `m:briskd_population`.
""".
-spec lusers([binary()], #client{}, binary()) -> ok.
lusers(Params, Client, Server) ->
    {Mask, Target} =
        case Params of
            [] -> {<<"*">>, Server};
            [GivenMask] -> {GivenMask, Server};
            [GivenMask, GivenTarget | _] -> {GivenMask, GivenTarget}
        end,
    case briskd_state_channel:wildcard_match(Target, Server) of
        false ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            Pop = briskd_population:publish(),
            LocalUsers = Pop#population.local_users,
            GlobalUsers = LocalUsers + Pop#population.remote_users,
            MaxLocal = Pop#population.max_local,
            MaxGlobal = Pop#population.max_global,
            Included = briskd_state_channel:wildcard_match(Mask, Server),
            {Users, Invisible, Operators, Unknown, Channels, Servers} =
                case Included of
                    true ->
                        {
                            GlobalUsers,
                            Pop#population.invisible_users,
                            Pop#population.operators,
                            Pop#population.unknown_users,
                            Pop#population.channels,
                            Pop#population.servers
                        };
                    false ->
                        {0, 0, 0, 0, 0, 0}
                end,
            briskd_state_send:numeric(
                Client,
                Server,
                <<"251">>,
                [],
                [
                    <<"There are ">>,
                    integer_to_binary(max(0, Users - Invisible)),
                    <<" users and ">>,
                    integer_to_binary(Invisible),
                    <<" invisible on ">>,
                    integer_to_binary(Servers),
                    <<" servers">>
                ]
            ),
            case Operators of
                0 ->
                    ok;
                _ ->
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"252">>,
                        [integer_to_binary(Operators)],
                        <<"operator(s) online">>
                    )
            end,
            case Unknown of
                0 ->
                    ok;
                _ ->
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"253">>,
                        [integer_to_binary(Unknown)],
                        <<"unknown connection(s)">>
                    )
            end,
            case Channels of
                0 ->
                    ok;
                _ ->
                    briskd_state_send:numeric(
                        Client,
                        Server,
                        <<"254">>,
                        [integer_to_binary(Channels)],
                        <<"channels formed">>
                    )
            end,
            briskd_state_send:numeric(
                Client,
                Server,
                <<"255">>,
                [],
                [
                    <<"I have ">>,
                    integer_to_binary(LocalUsers),
                    <<" clients and ">>,
                    integer_to_binary(max(0, Servers - 1)),
                    <<" servers">>
                ]
            ),
            briskd_state_send:numeric(
                Client,
                Server,
                <<"265">>,
                [integer_to_binary(LocalUsers), integer_to_binary(MaxLocal)],
                [
                    <<"Current local users ">>,
                    integer_to_binary(LocalUsers),
                    <<", max ">>,
                    integer_to_binary(MaxLocal)
                ]
            ),
            briskd_state_send:numeric(
                Client,
                Server,
                <<"266">>,
                [integer_to_binary(GlobalUsers), integer_to_binary(MaxGlobal)],
                [
                    <<"Current global users ">>,
                    integer_to_binary(GlobalUsers),
                    <<", max ">>,
                    integer_to_binary(MaxGlobal)
                ]
            )
    end.

-doc "Handle `MOTD [<target>]` using `m:briskd_motd`.".
-spec motd([binary()], #client{}, binary()) -> ok.
motd(Params, Client, Server) ->
    briskd_motd:motd(Params, Client, Server).

-doc "Handle `USERS [<target>]` (446 ERR_USERSDISABLED, RFC 2812 section 4.5).".
-spec users_disabled([binary()], #client{}, binary()) -> ok.
users_disabled(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        true ->
            briskd_state_send:numeric(Client, Server, <<"446">>, [], <<"USERS has been disabled">>);
        {false, Target} ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end.

-doc "Handle `TIME [<target>]` (391 RPL_TIME, RFC 2812 section 3.4.6).".
-spec time([binary()], #client{}, binary()) -> ok.
time(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        true ->
            briskd_state_send:numeric(
                Client,
                Server,
                <<"391">>,
                [Server],
                calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}])
            );
        {false, Target} ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end.

-doc "Handle `VERSION [<target>]` (351 RPL_VERSION, RFC 2812 section 3.4.3).".
-spec version([binary()], #client{}, binary()) -> ok.
version(Params, Client, Server) ->
    case query_local_server(Params, Server) of
        true ->
            briskd_state_send:numeric(
                Client, Server, <<"351">>, [briskd_app:vsn(), Server], <<"Erlang/OTP IRC server">>
            );
        {false, Target} ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>)
    end.

%% Internal helpers

admin_target([], _) ->
    true;
admin_target([Target | _], Server) ->
    case
        briskd_state_channel:wildcard_match(Target, Server) orelse
            briskd_state_client:find_nick(Target) =/= undefined
    of
        true -> true;
        false -> {false, Target}
    end.

format_compile_time(undefined) ->
    <<"unknown">>;
format_compile_time({Y, Mo, D, H, Mi, S}) ->
    iolist_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B UTC", [Y, Mo, D, H, Mi, S])
    );
format_compile_time(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

compiled_text() ->
    case persistent_term:get(?COMPILED_KEY, undefined) of
        Bin when is_binary(Bin) -> Bin;
        _ -> format_compile_time(proplists:get_value(time, briskd_state:module_info(compile)))
    end.

started_text() ->
    case persistent_term:get({briskd_state, started}, undefined) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<"unknown">>
    end.
