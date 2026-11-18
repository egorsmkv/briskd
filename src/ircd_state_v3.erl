-module(ircd_state_v3).
-export([
    account/1,
    authenticate/3,
    away_on_join/3,
    burst_lines/1,
    chghost/3,
    disconnect/1,
    invite_notify/4,
    isupport/3,
    join_broadcast/5,
    logout/2,
    notify/6,
    notify_remote/6,
    pre_away/3,
    receive_remote_account/3,
    receive_remote_chghost/3,
    receive_remote_setname/3,
    register/3,
    registered/2,
    remote_account/1,
    setname/3,
    source_info/1,
    starttls/2,
    remote_source_info/1,
    valid_utf8/1,
    verify/3,
    webirc/3
]).
-include("ircd_state.hrl").
-include("ircd_account.hrl").

%% @doc IRCv3 identity, account, and notification commands.
%%
%% Accounts: SASL 3.1/3.2 (`AUTHENTICATE`), draft/account-registration
%% (`REGISTER`, `VERIFY`), account-notify (`ACCOUNT`), account-tag, and
%% extended-join. Presence: away-notify, draft/pre-away, setname, chghost, and
%% bot mode. Connection: WEBIRC and draft/extended-isupport (`ISUPPORT`).

%% Longest accepted realname for SETNAME, advertised as NAMELEN.
-define(NAMELEN, 200).

%% @doc Account of a local client, or `undefined`.
-spec account(pid()) -> undefined | binary().
account(Pid) ->
    ircd_conn:get(Pid, account).

%% @doc Account of a remote user by folded nick, or `undefined`.
-spec remote_account(binary()) -> undefined | binary().
remote_account(NickKey) ->
    case mnesia:dirty_read(remote_client, NickKey) of
        [#remote_client{account = Account}] -> Account;
        [] -> undefined
    end.

%% @doc Source-tag facts for a local client command.
-spec source_info(#client{}) -> map().
source_info(#client{pid = Pid, nick = Nick, user = User} = Client) when User =/= undefined ->
    Modes = ircd_state_client:user_modes(Pid),
    #{
        prefix => iolist_to_binary(ircd_state_send:prefix(Client)),
        account => account(Pid),
        bot => maps:is_key($B, Modes),
        oper =>
            case maps:is_key($o, Modes) of
                true -> Nick;
                false -> undefined
            end
    };
source_info(_Client) ->
    #{}.

%% @doc Source-tag facts for a remote user named by a `nick!user@host` prefix.
-spec remote_source_info(undefined | binary()) -> map().
remote_source_info(Prefix) when is_binary(Prefix) ->
    case binary:split(Prefix, <<"!">>) of
        [Nick, _] ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [#remote_client{nick = Actual, modes = Modes, account = Account}] ->
                    #{
                        prefix => Prefix,
                        account => Account,
                        bot => maps:is_key($B, Modes),
                        oper =>
                            case maps:is_key($o, Modes) of
                                true -> Actual;
                                false -> undefined
                            end
                    };
                [] ->
                    #{}
            end;
        _ ->
            #{}
    end;
remote_source_info(_) ->
    #{}.

%% @doc Send a notification about a local user to clients that share a channel
%% (and, with extended-monitor, to clients monitoring the nick) and have `Cap`.
-spec notify(#client{}, binary(), binary(), [iodata()], none | iodata(), boolean()) -> ok.
notify(#client{pid = Pid, nick = Nick} = Client, Cap, Command, Middle, Tail, IncludeSelf) ->
    Shared = ircd_state_channel:nick_recipients(Client),
    Recipients = recipients(Shared, Nick, Cap, Pid, IncludeSelf),
    ircd_state_send:broadcast(
        Recipients, ircd_state_send:prefix(Client), Command, Middle, Tail
    ).

%% @doc Send a notification about a remote user to local clients with `Cap`.
-spec notify_remote(#remote_client{}, binary(), binary(), binary(), [iodata()], none | iodata()) ->
    ok.
notify_remote(#remote_client{key = Key, nick = Nick}, Prefix, Cap, Command, Middle, Tail) ->
    Shared = ircd_state_link:remote_user_local_recipients(Key),
    Recipients = recipients(Shared, Nick, Cap, undefined, false),
    ircd_state_send:broadcast(Recipients, Prefix, Command, Middle, Tail).

recipients(Shared, Nick, Cap, Self, IncludeSelf) ->
    Watchers = [
        Watcher
     || Watcher <- ircd_state_monitor:watchers(Nick),
        ircd_cap:enabled(Watcher, <<"extended-monitor">>)
    ],
    [
        Pid
     || Pid <- lists:usort(Shared ++ Watchers),
        Pid =/= Self orelse IncludeSelf,
        ircd_cap:enabled(Pid, Cap)
    ].

%% @doc Show a local JOIN to channel members. Clients with extended-join get
%% the account (`*` when logged out) and realname.
-spec join_broadcast([pid()], iodata(), binary(), undefined | binary(), binary()) -> ok.
join_broadcast(Pids, Prefix, Channel, Account, Real) ->
    {Extended, Plain} = lists:partition(
        fun(Pid) -> ircd_cap:enabled(Pid, <<"extended-join">>) end, Pids
    ),
    AccountParam =
        case Account of
            undefined -> <<"*">>;
            _ -> Account
        end,
    ircd_state_send:broadcast(Plain, Prefix, <<"JOIN">>, [Channel], none),
    ircd_state_send:broadcast(Extended, Prefix, <<"JOIN">>, [Channel, AccountParam], Real),
    ok.

%% @doc After a JOIN, tell away-notify members that the joining user is away.
-spec away_on_join([pid()], iodata(), undefined | binary()) -> ok.
away_on_join(_Pids, _Prefix, undefined) ->
    ok;
away_on_join(Pids, Prefix, Away) ->
    ircd_state_send:broadcast(
        [Pid || Pid <- Pids, ircd_cap:enabled(Pid, <<"away-notify">>)],
        Prefix,
        <<"AWAY">>,
        [],
        Away
    ).

%% @doc invite-notify: tell channel members with the capability about an
%% INVITE. On an invite-only channel only channel operators are told.
-spec invite_notify(#channel{}, #client{}, binary(), {pid(), iodata()}) -> ok.
invite_notify(
    #channel{name = Name, members = Members, flags = Flags},
    #client{pid = TargetPid},
    TargetNick,
    {InviterPid, Prefix}
) ->
    Recipients = [
        Pid
     || {Pid, Roles} <- maps:to_list(Members),
        Pid =/= InviterPid,
        Pid =/= TargetPid,
        not maps:is_key($i, Flags) orelse lists:member(operator, Roles),
        ircd_cap:enabled(Pid, <<"invite-notify">>)
    ],
    ircd_state_send:broadcast(Recipients, Prefix, <<"INVITE">>, [TargetNick, Name], none).

%% @doc Called once when a local client completes registration: propagate the
%% account and away state, notify MONITOR watchers, and drop pending SASL.
-spec registered(#client{}, binary()) -> ok.
registered(#client{pid = Pid, away = Away} = Client, _Server) ->
    Prefix = ircd_state_send:prefix(Client),
    case account(Pid) of
        undefined ->
            ok;
        Account ->
            ircd_state_link:server_broadcast(ircd_wire:line(Prefix, <<"ACCOUNT">>, [Account], none))
    end,
    case Away of
        undefined -> ok;
        _ -> ircd_state_link:propagate_away(Client, Away)
    end,
    ircd_state_monitor:online(Client#client.nick, iolist_to_binary(Prefix)),
    ok.

%% @doc Release per-connection IRCv3 state when a client disconnects.
-spec disconnect(#client{}) -> ok.
disconnect(#client{pid = Pid, nick = Nick} = Client) ->
    case ircd_state_client:ready(Client) of
        true -> ircd_state_monitor:offline(Nick);
        false -> ok
    end,
    ircd_state_monitor:clear(Pid),
    ircd_state_meta:disconnect(Pid),
    ircd_conn:delete(Pid).

%% @doc Account and capability lines for a newly linked peer's burst.
-spec burst_lines(binary()) -> [binary()].
burst_lines(_Server) ->
    Local = [
        iolist_to_binary(
            ircd_wire:line(ircd_state_send:prefix(Client), <<"ACCOUNT">>, [Account], none)
        )
     || Pid <- mnesia:dirty_all_keys(client),
        [Client] <- [mnesia:dirty_read(client, Pid)],
        ircd_state_client:ready(Client),
        Account <- [account(Pid)],
        Account =/= undefined
    ],
    Remote = [
        iolist_to_binary(
            ircd_wire:line(
                <<Nick/binary, "!", User/binary, "@", Host/binary>>, <<"ACCOUNT">>, [Account], none
            )
        )
     || Key <- mnesia:dirty_all_keys(remote_client),
        [#remote_client{nick = Nick, user = User, host = Host, account = Account}] <-
            [mnesia:dirty_read(remote_client, Key)],
        Account =/= undefined
    ],
    Local ++ Remote.

%%% SASL

%% @doc AUTHENTICATE (SASL 3.1 and 3.2). Reauthentication is allowed.
-spec authenticate([binary()], #client{}, binary()) -> ok.
authenticate([], Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"AUTHENTICATE">>], <<"Not enough parameters">>
    );
authenticate([Param | _], #client{pid = Pid} = Client, Server) ->
    case {Param, ircd_conn:get(Pid, sasl)} of
        {<<"*">>, _} ->
            clear_sasl(Pid),
            sasl_numeric(Client, Server, <<"906">>, [], <<"SASL authentication aborted">>);
        {Mechanism, undefined} ->
            Context = #{certfp => maps:get(certfp, ircd_cap:info(Pid), undefined)},
            case ircd_sasl:start(Mechanism, Context) of
                {continue, Challenge, State} ->
                    ircd_conn:put(Pid, sasl, State),
                    ircd_conn:put(Pid, sasl_buf, <<>>),
                    send_challenge(Pid, Server, Challenge);
                {error, unknown_mechanism} ->
                    sasl_numeric(
                        Client,
                        Server,
                        <<"908">>,
                        [iolist_to_binary(lists:join(<<",">>, ircd_cap:sasl_mechanisms()))],
                        <<"are available SASL mechanisms">>
                    ),
                    sasl_numeric(Client, Server, <<"904">>, [], <<"SASL authentication failed">>)
            end;
        {Chunk, State} ->
            case ircd_sasl:decode_chunk(ircd_conn:get(Pid, sasl_buf, <<>>), Chunk) of
                {more, Buffer} ->
                    ircd_conn:put(Pid, sasl_buf, Buffer);
                {error, too_long} ->
                    clear_sasl(Pid),
                    sasl_numeric(Client, Server, <<"905">>, [], <<"SASL message too long">>);
                {error, invalid} ->
                    sasl_fail(Client, Server);
                {done, Data} ->
                    sasl_step(Client, Server, State, Data)
            end
    end.

sasl_step(#client{pid = Pid} = Client, Server, State, Data) ->
    case ircd_sasl:step(State, Data) of
        {continue, Challenge, Next} ->
            ircd_conn:put(Pid, sasl, Next),
            ircd_conn:put(Pid, sasl_buf, <<>>),
            send_challenge(Pid, Server, Challenge);
        {success, Account} ->
            clear_sasl(Pid),
            login(Client, Account, Server),
            sasl_numeric(Client, Server, <<"903">>, [], <<"SASL authentication successful">>);
        {error, _} ->
            sasl_fail(Client, Server)
    end.

sasl_fail(#client{pid = Pid, nick = Nick, host = Host} = Client, Server) ->
    clear_sasl(Pid),
    logger:info(#{event => sasl_failed, nick => Nick, host => Host}),
    sasl_numeric(Client, Server, <<"904">>, [], <<"SASL authentication failed">>).

clear_sasl(Pid) ->
    ircd_conn:remove(Pid, sasl),
    ircd_conn:remove(Pid, sasl_buf).

send_challenge(Pid, Server, Challenge) ->
    lists:foreach(
        fun(Chunk) -> ircd_state_send:send(Pid, Server, <<"AUTHENTICATE">>, [Chunk], none) end,
        ircd_sasl:encode_chunks(Challenge)
    ).

sasl_numeric(#client{pid = Pid, nick = Nick}, Server, Number, Params, Text) ->
    ircd_state_send:send(Pid, Server, Number, [Nick | Params], Text).

%% Log in and announce the account (RPL_LOGGEDIN, account-notify, peers).
login(#client{pid = Pid}, Account, Server) ->
    Client = ircd_state_client:client(Pid),
    Previous = account(Pid),
    ircd_conn:put(Pid, account, Account),
    logger:info(#{event => account_login, nick => Client#client.nick, account => Account}),
    ircd_state_send:send(
        Pid,
        Server,
        <<"900">>,
        [Client#client.nick, mask(Client), Account],
        [<<"You are now logged in as ">>, Account]
    ),
    case ircd_state_client:ready(Client) andalso Previous =/= Account of
        true -> account_changed(Client, Account);
        false -> ok
    end.

%% @doc Log out (used when an account is removed). Sends RPL_LOGGEDOUT.
-spec logout(#client{}, binary()) -> ok.
logout(#client{pid = Pid} = Client, Server) ->
    case account(Pid) of
        undefined ->
            ok;
        _ ->
            ircd_conn:remove(Pid, account),
            ircd_state_send:send(
                Pid,
                Server,
                <<"901">>,
                [Client#client.nick, mask(Client)],
                <<"You are now logged out">>
            ),
            account_changed(Client, undefined)
    end.

account_changed(Client, Account) ->
    Value =
        case Account of
            undefined -> <<"*">>;
            _ -> Account
        end,
    notify(Client, <<"account-notify">>, <<"ACCOUNT">>, [Value], none, true),
    ircd_state_link:server_broadcast(
        ircd_wire:line(ircd_state_send:prefix(Client), <<"ACCOUNT">>, [Value], none)
    ).

mask(#client{user = undefined}) -> <<"*">>;
mask(Client) -> iolist_to_binary(ircd_state_send:prefix(Client)).

%%% draft/account-registration

%% @doc `REGISTER <account|*> <email|*> <password>`. Allowed before
%% registration completes (`before-connect`). Success logs the client in.
-spec register([binary()], #client{}, binary()) -> ok.
register([Requested, Email, Password | _], #client{pid = Pid, nick = Nick} = Client, Server) ->
    Name =
        case Requested of
            <<"*">> -> Nick;
            _ -> Requested
        end,
    Enabled = maps:get(
        account_registration, persistent_term:get({ircd_state, config}), true
    ),
    Verification = maps:get(
        account_verification, persistent_term:get({ircd_state, config}), null
    ),
    EmailOk =
        valid_email(Email) andalso (Verification =:= null orelse Email =/= <<"*">>),
    case {Enabled, Nick, account(Pid), EmailOk} of
        {false, _, _, _} ->
            reg_fail(Pid, <<"TEMPORARILY_UNAVAILABLE">>, Name, <<"Registration is disabled">>);
        {_, <<"*">>, _, _} ->
            reg_fail(Pid, <<"NEED_NICK">>, <<"*">>, <<"Send NICK before REGISTER">>);
        {_, _, Logged, _} when Logged =/= undefined ->
            reg_fail(Pid, <<"ALREADY_AUTHENTICATED">>, Logged, <<"You are already logged in">>);
        {_, _, _, false} ->
            reg_fail(Pid, <<"INVALID_EMAIL">>, Name, <<"Invalid email address">>);
        {true, _, undefined, true} ->
            Stored =
                case Email of
                    <<"*">> -> undefined;
                    _ -> Email
                end,
            CertFps =
                case maps:get(certfp, ircd_cap:info(Pid), undefined) of
                    undefined -> [];
                    Fp -> [Fp]
                end,
            Pending =
                case Verification of
                    null -> undefined;
                    #{ttl := Ttl} -> {verification_code(), Ttl * 1000}
                end,
            case ircd_account:create(Name, Stored, Password, CertFps, Pending) of
                {ok, Account} when Pending =:= undefined ->
                    logger:info(#{event => account_registered, account => Name}),
                    ircd_state_sync:account_created(Account),
                    ircd_state_send:send(
                        Pid,
                        Server,
                        <<"REGISTER">>,
                        [<<"SUCCESS">>, Name],
                        <<"Account created">>
                    ),
                    login(Client, Name, Server);
                {ok, _} ->
                    {Code, _} = Pending,
                    logger:info(#{event => account_verification_sent, account => Name}),
                    send_verification(Verification, Name, Stored, Code),
                    ircd_state_send:send(
                        Pid,
                        Server,
                        <<"REGISTER">>,
                        [<<"VERIFICATION_REQUIRED">>, Name],
                        <<"Check your email for a verification code">>
                    );
                {error, account_exists} ->
                    reg_fail(Pid, <<"ACCOUNT_EXISTS">>, Name, <<"Account already exists">>);
                {error, bad_account_name} ->
                    reg_fail(Pid, <<"BAD_ACCOUNT_NAME">>, Name, <<"Invalid account name">>);
                {error, weak_password} ->
                    reg_fail(Pid, <<"WEAK_PASSWORD">>, Name, <<"Password is too short">>);
                {error, unacceptable_password} ->
                    reg_fail(Pid, <<"UNACCEPTABLE_PASSWORD">>, Name, <<"Password is too long">>)
            end
    end;
register(_, Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"REGISTER">>], <<"Not enough parameters">>
    ).

reg_fail(Pid, Code, Name, Text) ->
    ircd_state_send:fail(Pid, <<"REGISTER">>, Code, [Name], Text).

valid_email(<<"*">>) ->
    true;
valid_email(Email) ->
    byte_size(Email) =< 254 andalso
        case binary:split(Email, <<"@">>) of
            [Local, Domain] -> Local =/= <<>> andalso binary:match(Domain, <<".">>) =/= nomatch;
            _ -> false
        end.

%% Eight random characters from an unambiguous alphabet.
verification_code() ->
    Alphabet = <<"ABCDEFGHJKLMNPQRSTUVWXYZ23456789">>,
    <<<<(binary:at(Alphabet, B rem 32))>> || <<B>> <= crypto:strong_rand_bytes(8)>>.

%% Deliver a verification code with the configured program. The code, account,
%% and address are passed in the environment (IRCD_ACCOUNT, IRCD_EMAIL,
%% IRCD_CODE) rather than argv, so other users cannot read them from the
%% process list. The program runs in a short-lived process that owns the port
%% and is bounded by a timeout; the code is never logged.
send_verification(#{command := [Exe | Args]}, Account, Email, Code) ->
    spawn(fun() ->
        try
            Port = open_port({spawn_executable, Exe}, [
                {args, Args},
                {env, [
                    {"IRCD_ACCOUNT", binary_to_list(Account)},
                    {"IRCD_EMAIL", binary_to_list(Email)},
                    {"IRCD_CODE", binary_to_list(Code)}
                ]},
                exit_status,
                use_stdio,
                stderr_to_stdout
            ]),
            wait_sender(Port, Account)
        catch
            error:Reason ->
                logger:warning(#{
                    event => account_verification_failed, account => Account, reason => Reason
                })
        end
    end),
    ok.

wait_sender(Port, Account) ->
    receive
        {Port, {data, _}} ->
            wait_sender(Port, Account);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Status}} ->
            logger:warning(#{
                event => account_verification_failed, account => Account, reason => {exit, Status}
            })
    after 30000 ->
        port_close(Port),
        logger:warning(#{
            event => account_verification_failed, account => Account, reason => timeout
        })
    end.

%% @doc `VERIFY <account> <code>`. A correct code for a pending account logs
%% the client in, as SASL would.
-spec verify([binary()], #client{}, binary()) -> ok.
verify([Requested, Code | _], #client{pid = Pid, nick = Nick} = Client, Server) ->
    Name =
        case Requested of
            <<"*">> -> Nick;
            _ -> Requested
        end,
    case account(Pid) of
        undefined ->
            case ircd_account:verify(Name, Code) of
                {ok, Account} ->
                    logger:info(#{event => account_registered, account => Name}),
                    ircd_state_sync:account_created(Account),
                    ircd_state_send:send(
                        Pid, Server, <<"VERIFY">>, [<<"SUCCESS">>, Name], <<"Account verified">>
                    ),
                    login(Client, Account#account.name, Server);
                error ->
                    ircd_state_send:fail(
                        Pid,
                        <<"VERIFY">>,
                        <<"INVALID_CODE">>,
                        [Name],
                        <<"Invalid verification code">>
                    )
            end;
        Account ->
            ircd_state_send:fail(
                Pid,
                <<"VERIFY">>,
                <<"ALREADY_AUTHENTICATED">>,
                [Account],
                <<"You are already logged in">>
            )
    end;
verify(_, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"VERIFY">>], <<"Not enough parameters">>).

%%% setname, chghost, pre-away

%% @doc `SETNAME :<realname>`. The change is shown to setname clients that
%% share a channel and to the sender, and is propagated to peers.
-spec setname([binary()], #client{}, binary()) -> ok.
setname([Real | _], #client{pid = Pid} = Client, Server) ->
    case valid_realname(Real) of
        false ->
            ircd_state_send:fail(
                Pid, <<"SETNAME">>, <<"INVALID_REALNAME">>, [], <<"Realname is not valid">>
            );
        true ->
            Current = ircd_state_client:client(Pid),
            mnesia:dirty_write(Current#client{real = ircd_wire:retain(Real)}),
            notify(Current, <<"setname">>, <<"SETNAME">>, [], Real, true),
            ircd_state_link:server_broadcast(
                ircd_wire:line(ircd_state_send:prefix(Current), <<"SETNAME">>, [], Real)
            ),
            _ = Server,
            _ = Client,
            ok
    end;
setname([], Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"SETNAME">>], <<"Not enough parameters">>
    ).

valid_realname(Real) ->
    byte_size(Real) =< ?NAMELEN andalso valid_utf8_if_required(Real).

valid_utf8_if_required(Text) ->
    case maps:get(utf8_only, persistent_term:get({ircd_state, config}), false) of
        true -> valid_utf8(Text);
        false -> true
    end.

%% @doc True for well-formed UTF-8.
-spec valid_utf8(binary()) -> boolean().
valid_utf8(Text) ->
    case unicode:characters_to_binary(Text, utf8, utf8) of
        Bin when is_binary(Bin) -> true;
        _ -> false
    end.

%% @doc Operator `CHGHOST <nick> <user> <host>` (IRCv3 chghost). chghost
%% clients see `CHGHOST`; other members of shared channels see QUIT, JOIN, and
%% the member's channel modes, as the specification recommends.
-spec chghost([binary()], #client{}, binary()) -> ok.
chghost([Nick, User, Host | _], #client{pid = Pid} = Client, Server) ->
    case maps:is_key($o, ircd_state_client:user_modes(Pid)) of
        false ->
            ircd_state_send:numeric(
                Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>
            );
        true ->
            case {ircd_state_client:find_nick(Nick), valid_user(User), valid_host(Host)} of
                {undefined, _, _} ->
                    ircd_state_send:numeric(Client, Server, <<"401">>, [Nick], <<"No such nick">>);
                {_, false, _} ->
                    ircd_state_send:fail(
                        Pid, <<"CHGHOST">>, <<"INVALID_USERNAME">>, [User], <<"Invalid username">>
                    );
                {_, _, false} ->
                    ircd_state_send:fail(
                        Pid, <<"CHGHOST">>, <<"INVALID_HOSTNAME">>, [Host], <<"Invalid hostname">>
                    );
                {Target, true, true} ->
                    logger:notice(#{
                        event => oper_chghost, actor => Client#client.nick, target => Nick
                    }),
                    apply_chghost(Target, User, Host, Server)
            end
    end;
chghost(_, Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"CHGHOST">>], <<"Not enough parameters">>
    ).

valid_user(User) ->
    re:run(User, <<"^~?[A-Za-z0-9_.-]{1,32}$">>, [{capture, none}, dollar_endonly]) =:= match.

valid_host(Host) ->
    byte_size(Host) > 0 andalso byte_size(Host) =< 63 andalso
        re:run(Host, <<"^[A-Za-z0-9.:/-]+$">>, [{capture, none}, dollar_endonly]) =:= match andalso
        binary:first(Host) =/= $:.

apply_chghost(Target, User, Host, Server) ->
    %% CHGHOST and its fallback lines are the target's own, so they carry the
    %% target's account and oper tags, not the operator's.
    ircd_state_send:with_source(source_info(Target), fun() ->
        apply_chghost_as_target(Target, User, Host, Server)
    end).

apply_chghost_as_target(#client{pid = Pid} = Target, User, Host, Server) ->
    OldPrefix = iolist_to_binary(ircd_state_send:prefix(Target)),
    Updated = Target#client{user = ircd_wire:retain(User), host = ircd_wire:retain(Host)},
    mnesia:dirty_write(Updated),
    NewPrefix = iolist_to_binary(ircd_state_send:prefix(Updated)),
    Shared = ircd_state_channel:nick_recipients(Target),
    {Capable, Legacy} = lists:partition(
        fun(P) -> ircd_cap:enabled(P, <<"chghost">>) end, Shared
    ),
    Watchers = [
        W
     || W <- ircd_state_monitor:watchers(Target#client.nick),
        ircd_cap:enabled(W, <<"extended-monitor">>),
        ircd_cap:enabled(W, <<"chghost">>)
    ],
    ircd_state_send:broadcast(
        lists:usort(Capable ++ Watchers), OldPrefix, <<"CHGHOST">>, [User, Host], none
    ),
    simulate_reconnect(Updated, [P || P <- Legacy, P =/= Pid], OldPrefix, NewPrefix, Server),
    ircd_state_link:server_broadcast(
        ircd_wire:line(OldPrefix, <<"CHGHOST">>, [User, Host], none)
    ),
    ok.

%% Legacy clients see QUIT, then JOIN and mode restoration per shared channel.
simulate_reconnect(_Client, [], _Old, _New, _Server) ->
    ok;
simulate_reconnect(#client{pid = Pid, channels = Keys}, Legacy, OldPrefix, NewPrefix, Server) ->
    ircd_state_send:broadcast(Legacy, OldPrefix, <<"QUIT">>, [], <<"Changing hostname">>),
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{name = Name, members = Members, flags = Flags}] ->
                    case maps:is_key($a, Flags) orelse maps:is_key($q, Flags) of
                        true ->
                            ok;
                        false ->
                            Viewers = [P || P <- maps:keys(Members), lists:member(P, Legacy)],
                            ircd_state_send:broadcast(Viewers, NewPrefix, <<"JOIN">>, [Name], none),
                            Roles = maps:get(Pid, Members, []),
                            Nick = hd(binary:split(NewPrefix, <<"!">>)),
                            Letters = [
                                L
                             || {Role, L} <- [{operator, $o}, {voice, $v}],
                                lists:member(Role, Roles)
                            ],
                            case Letters of
                                [] ->
                                    ok;
                                _ ->
                                    ircd_state_send:broadcast(
                                        Viewers,
                                        Server,
                                        <<"MODE">>,
                                        [Name, <<$+, (list_to_binary(Letters))/binary>>],
                                        [lists:join(<<" ">>, [Nick || _ <- Letters])]
                                    )
                            end
                    end;
                [] ->
                    ok
            end
        end,
        Keys
    ).

%% @doc draft/pre-away: AWAY before registration completes. `AWAY *` means
%% away for an unspecified reason; this server substitutes readable text.
-spec pre_away([binary()], #client{}, binary()) -> ok.
pre_away(Params, #client{pid = Pid} = Client, Server) ->
    case ircd_cap:enabled(Pid, <<"draft/pre-away">>) of
        false ->
            ircd_state_send:numeric(Client, Server, <<"451">>, [], <<"You have not registered">>);
        true ->
            case Params of
                Back when Back =:= []; Back =:= [<<>>] ->
                    mnesia:dirty_write(Client#client{away = undefined}),
                    ircd_state_send:numeric(
                        Client, Server, <<"305">>, [], <<"You are no longer marked as being away">>
                    );
                [Message | _] ->
                    mnesia:dirty_write(Client#client{away = ircd_wire:retain(away_text(Message))}),
                    ircd_state_send:numeric(
                        Client, Server, <<"306">>, [], <<"You have been marked as being away">>
                    )
            end
    end.

away_text(<<"*">>) -> <<"Away">>;
away_text(Message) -> Message.

%%% Remote identity updates from server links

%% @doc `:nick!user@host ACCOUNT <name|*>` from a peer.
-spec receive_remote_account(binary(), binary(), [binary()]) -> ok | {error, term()}.
receive_remote_account(Peer, Prefix, [Value | _]) ->
    case remote_user(Peer, Prefix) of
        {ok, Remote} ->
            Account =
                case Value of
                    <<"*">> -> undefined;
                    _ -> ircd_wire:retain(Value)
                end,
            mnesia:dirty_write(Remote#remote_client{account = Account}),
            notify_remote(Remote, Prefix, <<"account-notify">>, <<"ACCOUNT">>, [Value], none),
            ircd_state_link:relay_except(
                Peer, ircd_wire:line(Prefix, <<"ACCOUNT">>, [Value], none)
            ),
            ok;
        error ->
            {error, unknown_remote_source}
    end;
receive_remote_account(_, _, _) ->
    {error, invalid_account_message}.

%% @doc `:nick!user@host SETNAME :<realname>` from a peer.
-spec receive_remote_setname(binary(), binary(), [binary()]) -> ok | {error, term()}.
receive_remote_setname(Peer, Prefix, [Real | _]) ->
    case remote_user(Peer, Prefix) of
        {ok, Remote} ->
            mnesia:dirty_write(Remote#remote_client{real = ircd_wire:retain(Real)}),
            notify_remote(Remote, Prefix, <<"setname">>, <<"SETNAME">>, [], Real),
            ircd_state_link:relay_except(Peer, ircd_wire:line(Prefix, <<"SETNAME">>, [], Real)),
            ok;
        error ->
            {error, unknown_remote_source}
    end;
receive_remote_setname(_, _, _) ->
    {error, invalid_setname_message}.

%% @doc `:nick!old_user@old_host CHGHOST <user> <host>` from a peer.
-spec receive_remote_chghost(binary(), binary(), [binary()]) -> ok | {error, term()}.
receive_remote_chghost(Peer, Prefix, [User, Host | _]) ->
    case {remote_user(Peer, Prefix), valid_user(User), valid_host(Host)} of
        {{ok, #remote_client{key = Key, nick = Nick} = Remote}, true, true} ->
            mnesia:dirty_write(Remote#remote_client{
                user = ircd_wire:retain(User), host = ircd_wire:retain(Host)
            }),
            Shared = ircd_state_link:remote_user_local_recipients(Key),
            {Capable, Legacy} = lists:partition(
                fun(P) -> ircd_cap:enabled(P, <<"chghost">>) end, Shared
            ),
            Watchers = [
                W
             || W <- ircd_state_monitor:watchers(Nick),
                ircd_cap:enabled(W, <<"extended-monitor">>),
                ircd_cap:enabled(W, <<"chghost">>)
            ],
            ircd_state_send:broadcast(
                lists:usort(Capable ++ Watchers), Prefix, <<"CHGHOST">>, [User, Host], none
            ),
            NewPrefix = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
            ircd_state_send:broadcast(Legacy, Prefix, <<"QUIT">>, [], <<"Changing hostname">>),
            lists:foreach(
                fun(ChannelKey) ->
                    case
                        {
                            mnesia:dirty_read(remote_channel, ChannelKey),
                            mnesia:dirty_read(channel, ChannelKey)
                        }
                    of
                        {[#remote_channel{members = RM}], [#channel{name = Name, members = LM}]} when
                            is_map_key(Key, RM)
                        ->
                            Viewers = [P || P <- maps:keys(LM), lists:member(P, Legacy)],
                            ircd_state_send:broadcast(Viewers, NewPrefix, <<"JOIN">>, [Name], none);
                        _ ->
                            ok
                    end
                end,
                mnesia:dirty_all_keys(remote_channel)
            ),
            ircd_state_link:relay_except(
                Peer, ircd_wire:line(Prefix, <<"CHGHOST">>, [User, Host], none)
            ),
            ok;
        {error, _, _} ->
            {error, unknown_remote_source};
        _ ->
            {error, invalid_chghost_message}
    end;
receive_remote_chghost(_, _, _) ->
    {error, invalid_chghost_message}.

remote_user(Peer, Prefix) ->
    case binary:split(Prefix, <<"!">>) of
        [Nick, _] ->
            case mnesia:dirty_read(remote_client, ircd_wire:fold(Nick)) of
                [#remote_client{peer = Peer, nick = Nick, user = U, host = H} = Remote] ->
                    case Prefix =:= <<Nick/binary, "!", U/binary, "@", H/binary>> of
                        true -> {ok, Remote};
                        false -> error
                    end;
                _ ->
                    error
            end;
        _ ->
            error
    end.

%%% WEBIRC and ISUPPORT

%% @doc `WEBIRC <password> <gateway> <hostname> <ip> [:<options>]`. Accepted
%% only as the first command from a configured gateway address. A failure sends
%% ERROR and closes the connection.
-spec webirc([binary()], #client{}, binary()) -> ok.
webirc(
    [Password, _Gateway, Hostname, Ip | Rest],
    #client{pid = Pid, host = GatewayHost} = Client,
    Server
) ->
    Fresh =
        Client#client.nick =:= <<"*">> andalso Client#client.user =:= undefined andalso
            not maps:get(webirc, ircd_cap:info(Pid), false) andalso
            maps:get(version, ircd_cap:state(Pid)) =:= 0 andalso
            map_size(maps:get(enabled, ircd_cap:state(Pid))) =:= 0,
    Gateways = maps:get(webirc, persistent_term:get({ircd_state, config}), []),
    Trusted =
        case inet:parse_address(binary_to_list(GatewayHost)) of
            {ok, Address} ->
                lists:any(
                    fun(#{password := Secret, hosts := Hosts}) ->
                        lists:member(Address, Hosts) andalso
                            ircd_config:secret_match(Password, Secret)
                    end,
                    Gateways
                );
            _ ->
                false
        end,
    case {Fresh, Trusted, inet:parse_address(binary_to_list(Ip))} of
        {true, true, {ok, _}} ->
            %% A leading ':' would turn a WHO field into the trailing parameter.
            SafeIp =
                case Ip of
                    <<":", _/binary>> -> <<"0", Ip/binary>>;
                    _ -> Ip
                end,
            Host =
                case valid_host(Hostname) of
                    true -> Hostname;
                    false -> SafeIp
                end,
            Options =
                case Rest of
                    [Opts | _] -> binary:split(Opts, <<" ">>, [global, trim_all]);
                    [] -> []
                end,
            Secure =
                lists:any(fun(Opt) -> hd(binary:split(Opt, <<"=">>)) =:= <<"secure">> end, Options) andalso
                    maps:get(secure, ircd_cap:info(Pid), false),
            mnesia:dirty_write(Client#client{host = ircd_wire:retain(Host)}),
            ircd_cap:set_info(Pid, webirc, true),
            ircd_cap:set_info(Pid, secure, Secure),
            %% The gateway's own TLS certificate is not the user's identity.
            %% A `certfp-sha-256=` option from a secure gateway is.
            ircd_cap:set_info(Pid, certfp, webirc_certfp(Options, Secure)),
            ircd_cap:set_info(Pid, ip, ircd_wire:retain(SafeIp)),
            logger:info(#{event => webirc_accepted, gateway => GatewayHost, host => Host}),
            ok;
        _ ->
            logger:warning(#{event => webirc_rejected, gateway => GatewayHost}),
            %% The session sends ERROR and closes; its DOWN removes the client.
            Pid !
                {irc_close, ircd_wire:line(Server, <<"ERROR">>, [], <<"Invalid WebIRC password">>)},
            ok
    end;
webirc(_, Client, Server) ->
    ircd_state_send:numeric(Client, Server, <<"461">>, [<<"WEBIRC">>], <<"Not enough parameters">>).

webirc_certfp(_Options, false) ->
    undefined;
webirc_certfp(Options, true) ->
    case [V || <<"certfp-sha-256=", V/binary>> <- Options] of
        [Fp | _] when byte_size(Fp) =:= 64 -> string:lowercase(Fp);
        _ -> undefined
    end.

%% @doc `ISUPPORT` (draft/extended-isupport). Before registration the client
%% must have negotiated the capability.
-spec isupport([binary()], #client{}, binary()) -> ok.
isupport(_Params, #client{pid = Pid} = Client, Server) ->
    case
        ircd_state_client:ready(Client) orelse ircd_cap:enabled(Pid, <<"draft/extended-isupport">>)
    of
        true ->
            ircd_isupport:send(Client, Server, ircd_isupport:tokens());
        false ->
            ircd_state_send:numeric(Client, Server, <<"451">>, [], <<"You have not registered">>)
    end.

%% @doc STARTTLS (deprecated IRCv3 `tls` extension). Allowed once, before
%% registration, on a plaintext TCP connection when TLS is configured. The
%% session performs the handshake after the 670 reply.
-spec starttls(#client{}, binary()) -> ok | starttls.
starttls(#client{pid = Pid} = Client, Server) ->
    Info = ircd_cap:info(Pid),
    Configured = maps:get(tls_options, persistent_term:get({ircd_state, config}), []) =/= [],
    case
        Configured andalso maps:get(transport, Info, undefined) =:= tcp andalso
            not maps:get(secure, Info, false) andalso not ircd_state_client:ready(Client)
    of
        true ->
            ircd_state_send:numeric(
                Client, Server, <<"670">>, [], <<"STARTTLS successful, proceed with TLS handshake">>
            ),
            starttls;
        false ->
            ircd_state_send:numeric(Client, Server, <<"691">>, [], <<"STARTTLS failed">>)
    end.
