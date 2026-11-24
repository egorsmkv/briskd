-module(briskd_state_info).
-moduledoc """
Backwards-compatible facade for server queries, operator commands, and
configuration reload.

The implementations live in dedicated modules separating protocol information
(`m:briskd_info`), cached MOTD (`m:briskd_motd`), incremental population
accounting (`m:briskd_population`), bounded query workers (`m:briskd_query`),
operator authorization (`m:briskd_oper`), and versioned configuration reloads
(`m:briskd_rehash`).
""".
-export([
    admin/3,
    info/3,
    kill/3,
    links/3,
    lusers/3,
    motd/3,
    oper/4,
    query_local_server/2,
    rehash/2,
    rehash_server/1,
    apply_effective/4,
    note_user_counts/0,
    stats/3,
    trace/3,
    users_disabled/3
]).
-include("briskd_state.hrl").

-doc "Check an optional server argument against this server's name. See `briskd_info:query_local_server/2`.".
-spec query_local_server([binary()], binary()) -> true | {false, binary()}.
query_local_server(Params, Server) ->
    briskd_info:query_local_server(Params, Server).

-doc "Handle `TRACE [<target>]`. See `briskd_query:trace/3`.".
-spec trace([binary()], #client{}, binary()) -> ok.
trace(Params, Client, Server) ->
    briskd_query:trace(Params, Client, Server).

-doc "Handle `USERS [<target>]`. See `briskd_info:users_disabled/3`.".
-spec users_disabled([binary()], #client{}, binary()) -> ok.
users_disabled(Params, Client, Server) ->
    briskd_info:users_disabled(Params, Client, Server).

-doc "Handle `STATS [<query> [<target>]]`. See `briskd_query:stats/3`.".
-spec stats([binary()], #client{}, binary()) -> ok.
stats(Params, Client, Server) ->
    briskd_query:stats(Params, Client, Server).

-doc "Handle `OPER <name> <password>`. See `briskd_oper:oper/4`.".
-spec oper(binary(), binary(), #client{}, binary()) -> ok.
oper(Name, Password, Client, Server) ->
    briskd_oper:oper(Name, Password, Client, Server).

-doc "Handle `KILL <nickname> <comment>`. See `briskd_oper:kill/3`.".
-spec kill([binary()], #client{}, binary()) -> ok | quit.
kill(Params, Client, Server) ->
    briskd_oper:kill(Params, Client, Server).

-doc "Handle `REHASH`. See `briskd_rehash:rehash/2`.".
-spec rehash(#client{}, binary()) -> ok.
rehash(Client, Server) ->
    briskd_rehash:rehash(Client, Server).

-doc "Reload configuration from `m:briskd_ctl`. See `briskd_rehash:rehash_server/1`.".
-spec rehash_server(binary()) -> {ok, binary()} | {error, term()}.
rehash_server(Server) ->
    briskd_rehash:rehash_server(Server).

-doc "Apply an effective configuration snapshot. See `briskd_rehash:apply_effective/4`.".
-spec apply_effective(briskd_config:config(), map(), iodata(), binary()) -> ok.
apply_effective(NewConfig, Audit, Wallops, Server) ->
    briskd_rehash:apply_effective(NewConfig, Audit, Wallops, Server).

-doc "Handle `ADMIN [<target>]`. See `briskd_info:admin/3`.".
-spec admin([binary()], #client{}, binary()) -> ok.
admin(Params, Client, Server) ->
    briskd_info:admin(Params, Client, Server).

-doc "Handle `MOTD [<target>]`. See `briskd_motd:motd/3`.".
-spec motd([binary()], #client{}, binary()) -> ok.
motd(Params, Client, Server) ->
    briskd_motd:motd(Params, Client, Server).

-doc "Handle `INFO [<target>]`. See `briskd_info:info/3`.".
-spec info([binary()], #client{}, binary()) -> ok.
info(Params, Client, Server) ->
    briskd_info:info(Params, Client, Server).

-doc "Handle `LINKS [[<remote server>] <server mask>]`. See `briskd_info:links/3`.".
-spec links([binary()], #client{}, binary()) -> ok.
links(Params, Client, Server) ->
    briskd_info:links(Params, Client, Server).

-doc "Publish and return `{LocalUsers, GlobalUsers}`. See `briskd_population:note_user_counts/0`.".
-spec note_user_counts() -> {non_neg_integer(), non_neg_integer()}.
note_user_counts() ->
    briskd_population:note_user_counts().

-doc "Handle `LUSERS [<mask> [<target>]]`. See `briskd_info:lusers/3`.".
-spec lusers([binary()], #client{}, binary()) -> ok.
lusers(Params, Client, Server) ->
    briskd_info:lusers(Params, Client, Server).
