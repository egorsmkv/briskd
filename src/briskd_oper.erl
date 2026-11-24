-module(briskd_oper).
-moduledoc """
Operator authentication, privileged commands (`OPER`, `KILL`, `WALLOPS`),
and explicit operator / `+w` subscriber ETS indexes.

Credentials are stored in `persistent_term` as a map keyed by RFC 1459 folded
account name (`briskd_wire:fold/1`) for O(1) lookup, with constant-time
password comparison via `briskd_config:secret_match/2`.

Live operator and `WALLOPS` recipient membership is maintained in dedicated ETS
sets (`briskd_local_opers`, `briskd_remote_opers`, `briskd_wallops`,
`briskd_admins`) so `LUSERS`, `WALLOPS`, and `SQUERY` never scan all sessions.
""".

-export([
    init/0,
    store_accounts/1,
    authenticate/2,
    operator_names/0,
    is_operator/1,
    administrator/1,
    operator_count/0,
    local_operators/0,
    wallops_recipients/0,
    sync_local_modes/3,
    remove_local/1,
    sync_remote_modes/2,
    rename_remote/3,
    remove_remote/1,
    server_wallops/2,
    wallops/3,
    oper/4,
    kill/3
]).

-include("briskd_state.hrl").

-define(ACCOUNTS_KEY, {?MODULE, accounts}).
-define(ORDER_KEY, {?MODULE, order}).
-define(LOCAL_OPERS, briskd_local_opers).
-define(REMOTE_OPERS, briskd_remote_opers).
-define(WALLOPS, briskd_wallops).
-define(ADMINS, briskd_admins).

-type oper_role() :: operator | administrator.
-type account_entry() :: #{
    name := binary(),
    secret := binary(),
    role := oper_role()
}.
-export_type([oper_role/0]).

-doc """
Create or clear the transient ETS indexes for local operators, remote
operators, `WALLOPS` (`+w`) subscribers, and session administrators.
""".
-spec init() -> ok.
init() ->
    ensure_set(?LOCAL_OPERS),
    ensure_set(?REMOTE_OPERS),
    ensure_set(?WALLOPS),
    ensure_set(?ADMINS),
    ok.

-doc """
Publish operator and administrator credentials from `Config` as an O(1)
folded-name map in `persistent_term`.
""".
-spec store_accounts(map()) -> ok.
store_accounts(Config) ->
    Operators = maps:get(operators, Config, []),
    Administrators = maps:get(administrators, Config, []),
    Entries =
        [
            {briskd_wire:fold(Name), #{name => Name, secret => Secret, role => operator}}
         || {Name, Secret} <- Operators
        ] ++
            [
                {briskd_wire:fold(Nick), #{name => Nick, secret => Secret, role => administrator}}
             || {Nick, Secret} <- Administrators
            ],
    AccountMap = maps:from_list(Entries),
    Order = [Name || {Name, _} <- Operators ++ Administrators],
    persistent_term:put(?ACCOUNTS_KEY, AccountMap),
    persistent_term:put(?ORDER_KEY, Order),
    persistent_term:put({briskd_state, operators}, Operators ++ Administrators),
    persistent_term:put({briskd_state, administrators}, [Nick || {Nick, _} <- Administrators]),
    ok.

-doc """
Authenticate an `OPER` account name (RFC 1459 folded) and password using
constant-time comparison (`briskd_config:secret_match/2`).
""".
-spec authenticate(binary(), binary()) ->
    {ok, oper_role()} | {error, unknown_account | bad_password}.
authenticate(Name, Password) ->
    Fold = briskd_wire:fold(Name),
    case accounts_map() of
        #{Fold := #{secret := Expected, role := Role}} ->
            case briskd_config:secret_match(Password, Expected) of
                true -> {ok, Role};
                false -> {error, bad_password}
            end;
        _ ->
            {error, unknown_account}
    end.

-doc "Configured operator and administrator account names in order (for `STATS o`).".
-spec operator_names() -> [binary()].
operator_names() ->
    case persistent_term:get(?ORDER_KEY, []) of
        List when is_list(List) -> [Name || Name <- List, is_binary(Name)];
        _ -> []
    end.

-doc "True when local session `Pid` holds user mode `+o`.".
-spec is_operator(pid()) -> boolean().
is_operator(Pid) ->
    maps:is_key($o, briskd_state_client:user_modes(Pid)).

-doc "True when local session `Pid` authenticated with an `administrators` entry.".
-spec administrator(pid()) -> boolean().
administrator(Pid) when is_pid(Pid) ->
    case ets:whereis(?ADMINS) of
        undefined -> false;
        _ -> ets:lookup(?ADMINS, Pid) =/= []
    end.

-doc "Total registered local and remote IRC operators (`252 RPL_LUSEROP`).".
-spec operator_count() -> non_neg_integer().
operator_count() ->
    ets_size(?LOCAL_OPERS) + ets_size(?REMOTE_OPERS).

-doc "Pids of ready local operators (`+o`).".
-spec local_operators() -> [pid()].
local_operators() ->
    case ets:whereis(?LOCAL_OPERS) of
        undefined -> [];
        _ -> [Pid || {Pid} <- ets:tab2list(?LOCAL_OPERS), is_pid(Pid)]
    end.

-doc "Pids of ready local clients subscribed to `WALLOPS` (`+w`).".
-spec wallops_recipients() -> [pid()].
wallops_recipients() ->
    case ets:whereis(?WALLOPS) of
        undefined -> [];
        _ -> [Pid || {Pid} <- ets:tab2list(?WALLOPS), is_pid(Pid)]
    end.

-doc "Update operator and `WALLOPS` indexes for local session `Pid`.".
-spec sync_local_modes(pid(), boolean(), #{char() => true}) -> ok.
sync_local_modes(Pid, Ready, Modes) ->
    sync_member(?LOCAL_OPERS, Pid, Ready andalso maps:is_key($o, Modes)),
    sync_member(?WALLOPS, Pid, Ready andalso maps:is_key($w, Modes)),
    ok.

-doc "Remove local session `Pid` from operator, `WALLOPS`, and administrator indexes.".
-spec remove_local(pid()) -> ok.
remove_local(Pid) ->
    delete_member(?LOCAL_OPERS, Pid),
    delete_member(?WALLOPS, Pid),
    delete_member(?ADMINS, Pid),
    ok.

-doc "Update remote operator index for folded nickname `Key`.".
-spec sync_remote_modes(binary(), #{char() => true}) -> ok.
sync_remote_modes(Key, Modes) ->
    sync_member(?REMOTE_OPERS, Key, maps:is_key($o, Modes)),
    ok.

-doc "Move a remote operator index entry when a remote user changes nickname.".
-spec rename_remote(binary(), binary(), #{char() => true}) -> ok.
rename_remote(OldKey, NewKey, Modes) ->
    delete_member(?REMOTE_OPERS, OldKey),
    sync_remote_modes(NewKey, Modes).

-doc "Remove folded remote nickname `Key` from the remote operator index.".
-spec remove_remote(binary()) -> ok.
remove_remote(Key) ->
    delete_member(?REMOTE_OPERS, Key),
    ok.

-doc "Send a server-prefixed `WALLOPS` notice to all local `+w` subscribers.".
-spec server_wallops(iodata(), binary()) -> ok.
server_wallops(Text, Server) ->
    briskd_state_send:broadcast(wallops_recipients(), Server, <<"WALLOPS">>, [], Text).

-doc """
Handle operator `WALLOPS <text>` (RFC 2812 section 3.7.1).

Requires user mode `+o` (481 ERR_NOPRIVILEGES) and a message parameter
(461 ERR_NEEDMOREPARAMS). Broadcasts to local `+w` subscribers and relays to
server peers.
""".
-spec wallops([binary()], #client{}, binary()) -> ok.
wallops([Text | _], #client{pid = Pid} = Client, Server) ->
    case is_operator(Pid) of
        true ->
            Prefix = briskd_state_send:prefix(Client),
            briskd_state_send:broadcast(wallops_recipients(), Prefix, <<"WALLOPS">>, [], Text),
            briskd_state_link:server_broadcast(
                briskd_wire:line(Prefix, <<"WALLOPS">>, [], Text)
            );
        false ->
            briskd_state_send:numeric(
                Client,
                Server,
                <<"481">>,
                [],
                <<"Permission Denied- You're not an IRC operator">>
            )
    end;
wallops([], Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"WALLOPS">>], <<"Not enough parameters">>
    ).

-doc """
Handle `OPER <name> <password>` (RFC 2812 section 3.1.4).
""".
-spec oper(binary(), binary(), #client{}, binary()) -> ok.
oper(Name, Password, #client{pid = Pid} = Client, Server) ->
    case authenticate(Name, Password) of
        {error, unknown_account} ->
            logger:warning(#{
                event => oper_rejected,
                nick => Client#client.nick,
                account => Name,
                reason => unknown
            }),
            briskd_state_send:numeric(
                Client, Server, <<"491">>, [], <<"No O-lines for your host">>
            );
        {error, bad_password} ->
            logger:warning(#{
                event => oper_rejected,
                nick => Client#client.nick,
                account => Name,
                reason => password
            }),
            briskd_state_send:numeric(
                Client, Server, <<"464">>, [], <<"Password incorrect">>
            );
        {ok, Role} ->
            case Role of
                administrator ->
                    case ets:whereis(?ADMINS) of
                        undefined -> ok;
                        _ -> true = ets:insert(?ADMINS, {Pid})
                    end;
                operator ->
                    ok
            end,
            Modes = (briskd_state_client:user_modes(Pid))#{$o => true},
            mnesia:dirty_write(#user_modes{pid = Pid, modes = Modes}),
            briskd_population:on_local_mode_change(Pid, briskd_state_client:ready(Client), Modes),
            briskd_state_channel:grant_predefined_operator(Client, Server),
            briskd_state_link:server_broadcast(
                briskd_wire:line(
                    briskd_state_send:prefix(Client),
                    <<"MODE">>,
                    [Client#client.nick, <<"+o">>],
                    none
                )
            ),
            logger:info(#{
                event => oper_accepted, nick => Client#client.nick, account => Name
            }),
            briskd_state_send:numeric(
                Client, Server, <<"381">>, [], <<"You are now an IRC operator">>
            ),
            briskd_state_send:send(
                Pid,
                briskd_state_send:prefix(Client),
                <<"MODE">>,
                [Client#client.nick, <<"+o">>],
                none
            )
    end.

-doc """
Handle `KILL <nickname> <comment>` (RFC 2812 section 3.7.1).
""".
-spec kill([binary()], #client{}, binary()) -> ok | quit.
kill(Params, #client{pid = Pid} = Client, Server) ->
    case is_operator(Pid) of
        false ->
            briskd_state_send:numeric(
                Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>
            );
        true ->
            kill_target(Params, Client, Server)
    end.

kill_target([Nick, Reason | _], Client, Server) ->
    case briskd_state_client:find_nick(Nick) of
        undefined ->
            briskd_state_send:numeric(
                Client, Server, <<"401">>, [Nick], <<"No such nick/channel">>
            );
        #client{pid = TargetPid, nick = Actual} = Target ->
            Line = briskd_wire:line(briskd_state_send:prefix(Client), <<"KILL">>, [Actual], Reason),
            TargetPid ! {irc_close, Line},
            server_wallops(
                [<<"Oper ">>, Client#client.nick, <<" used KILL on ">>, Actual, <<": ">>, Reason],
                Server
            ),
            logger:notice(#{
                event => oper_kill, nick => Client#client.nick, target => Actual
            }),
            briskd_state_client:disconnect(Target, Reason, Server),
            case TargetPid =:= Client#client.pid of
                true -> quit;
                false -> ok
            end
    end;
kill_target(_, Client, Server) ->
    briskd_state_send:numeric(Client, Server, <<"461">>, [<<"KILL">>], <<"Not enough parameters">>).

%% Internal helpers

-spec accounts_map() -> #{binary() => account_entry()}.
accounts_map() ->
    case persistent_term:get(?ACCOUNTS_KEY, #{}) of
        Map when is_map(Map) -> Map;
        _ -> #{}
    end.

sync_member(Table, Key, true) ->
    case ets:whereis(Table) of
        undefined -> ok;
        _ -> true = ets:insert(Table, {Key})
    end;
sync_member(Table, Key, false) ->
    delete_member(Table, Key).

delete_member(Table, Key) ->
    case ets:whereis(Table) of
        undefined -> ok;
        _ -> true = ets:delete(Table, Key)
    end.

ensure_set(Name) ->
    case ets:whereis(Name) of
        undefined ->
            _ = ets:new(Name, [named_table, public, set]),
            ok;
        _ ->
            true = ets:delete_all_objects(Name),
            ok
    end.

ets_size(Table) ->
    case ets:whereis(Table) of
        undefined ->
            0;
        _ ->
            case ets:info(Table, size) of
                N when is_integer(N), N >= 0 -> N;
                _ -> 0
            end
    end.
