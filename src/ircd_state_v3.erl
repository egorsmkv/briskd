-module(ircd_state_v3).
-export([
    account/1,
    attachable/2,
    finish_attach/2,
    prepare_attach/3,
    rejoin_on_login/2,
    remember_channels/1,
    rename_channel/2,
    authenticate/3,
    away_on_join/3,
    burst_lines/1,
    chghost/3,
    disconnect/1,
    invite_notify/4,
    isupport/3,
    join_broadcast/5,
    join_broadcast/6,
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
    verify_account_web/2,
    verify_account_email_web/2,
    signup_account_web/4,
    request_password_reset_web/3,
    complete_password_reset_web/4,
    webirc/3
]).
-include("ircd_state.hrl").
-include("ircd_account.hrl").

-moduledoc """
IRCv3 identity, account, and notification commands, and their link
propagation.

Runs inside `m:ircd_state`. Implements:

- Accounts: [SASL 3.1 / 3.2](https://ircv3.net/specs/extensions/sasl-3.2)
  (`AUTHENTICATE`, mechanisms in `m:ircd_sasl`),
  [draft/account-registration](https://ircv3.net/specs/extensions/account-registration)
  (`REGISTER`, `VERIFY`, storage in `m:ircd_account`),
  [account-notify](https://ircv3.net/specs/extensions/account-notify)
  (`ACCOUNT`), [account-tag](https://ircv3.net/specs/extensions/account-tag),
  and [extended-join](https://ircv3.net/specs/extensions/extended-join).
- Presence: [away-notify](https://ircv3.net/specs/extensions/away-notify),
  [draft/pre-away](https://ircv3.net/specs/extensions/pre-away),
  [setname](https://ircv3.net/specs/extensions/setname),
  [chghost](https://ircv3.net/specs/extensions/chghost),
  [invite-notify](https://ircv3.net/specs/extensions/invite-notify), and the
  [bot mode](https://ircv3.net/specs/extensions/bot-mode) source tag.
- Connection: [WEBIRC](https://ircv3.net/specs/extensions/webirc),
  [STARTTLS](https://ircv3.net/specs/deprecated/tls) (deprecated), and
  [draft/extended-isupport](https://ircv3.net/specs/extensions/extended-isupport)
  (`ISUPPORT`).
- The opt-in `multiclient` and `account_rejoin` operator features.

The logged-in account of a connection is the `account` key in
`m:ircd_conn`; it is dropped on disconnect. Account changes, `SETNAME`, and
`CHGHOST` are sent to peers as prefixed `ACCOUNT`, `SETNAME`, and `CHGHOST`
lines, and the matching `receive_remote_*` functions accept them only from
the link that owns the user.
""".

%% Longest accepted realname for SETNAME, advertised as NAMELEN.
-define(NAMELEN, 200).

-doc """
Account the local connection `Pid` is logged in to, or `undefined`.
""".
-spec account(pid()) -> undefined | binary().
account(Pid) ->
    ircd_conn:get(Pid, account).

-doc """
Account of a remote user by folded nick (`ircd_wire:fold/1`), or
`undefined` when not logged in or unknown.
""".
-spec remote_account(binary()) -> undefined | binary().
remote_account(NickKey) ->
    case mnesia:dirty_read(remote_client, NickKey) of
        [#remote_client{account = Account}] -> Account;
        [] -> undefined
    end.

-doc """
Source-tag facts for a local client, for `ircd_state_send:set_source/1`:
`prefix`, `account`, `bot` (user mode `+B`), and `oper` (the nick when
`+o`). Returns `#{}` before `USER` is accepted.
""".
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

-doc """
Source-tag facts for a remote user named by a `nick!user@host` prefix, in
the same shape as `source_info/1`. Returns `#{}` for a server prefix,
`undefined`, or an unknown nick.
""".
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

-doc """
Send a notification line about a local user, with the user's prefix, to
clients that share a channel with it (and, with
[extended-monitor](https://ircv3.net/specs/extensions/extended-monitor), to
clients monitoring the nick) and negotiated `Cap`.

The user itself is included only when `IncludeSelf` is true and it has `Cap`.
""".
-spec notify(#client{}, binary(), binary(), [iodata()], none | iodata(), boolean()) -> ok.
notify(#client{pid = Pid, nick = Nick} = Client, Cap, Command, Middle, Tail, IncludeSelf) ->
    Shared = ircd_state_channel:nick_recipients(Client),
    Recipients = recipients(Shared, Nick, Cap, Pid, IncludeSelf),
    ircd_state_send:broadcast(
        Recipients, ircd_state_send:prefix(Client), Command, Middle, Tail
    ).

-doc """
Send a notification line about a remote user, with `Prefix`, to local
clients with `Cap` that share a channel with it or (with extended-monitor)
monitor its nick.
""".
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

-doc """
Show a JOIN to channel members. Same as `join_broadcast/6` with no tags.
""".
-spec join_broadcast([pid()], iodata(), binary(), undefined | binary(), binary()) -> ok.
join_broadcast(Pids, Prefix, Channel, Account, Real) ->
    join_broadcast(Pids, Prefix, Channel, Account, Real, []).

-doc """
Show a JOIN of `Channel` with `Tags` to `Pids`.

Clients with extended-join get `JOIN <channel> <account> :<realname>`,
with `*` as the account when logged out; others get `JOIN <channel>`.
""".
-spec join_broadcast([pid()], iodata(), binary(), undefined | binary(), binary(), list()) -> ok.
join_broadcast(Pids, Prefix, Channel, Account, Real, Tags) ->
    {Extended, Plain} = lists:partition(
        fun(Pid) -> ircd_cap:enabled(Pid, <<"extended-join">>) end, Pids
    ),
    AccountParam =
        case Account of
            undefined -> <<"*">>;
            _ -> Account
        end,
    ircd_state_send:broadcast(Plain, Prefix, <<"JOIN">>, [Channel], none, Tags),
    ircd_state_send:broadcast(Extended, Prefix, <<"JOIN">>, [Channel, AccountParam], Real, Tags),
    ok.

-doc """
After a JOIN, tell members with away-notify that the joining user is away
(`AWAY :<message>`). A no-op when `Away` is `undefined`.
""".
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

-doc """
invite-notify: tell channel members with the capability about an `INVITE`
(`:inviter INVITE <target> <channel>`). The inviter and the target are
skipped. On an invite-only (`+i`) channel only channel operators are told.
""".
-spec invite_notify(#channel{}, #client{}, binary(), {pid(), iodata()}) -> ok.
invite_notify(
    #channel{name = Name, members = Members, flags = Flags},
    #client{pid = TargetPid},
    TargetNick,
    {InviterPid, Prefix}
) ->
    Recipients = [
        Pid
     || Pid := Roles <- Members,
        Pid =/= InviterPid,
        Pid =/= TargetPid,
        not maps:is_key($i, Flags) orelse lists:member(operator, Roles),
        ircd_cap:enabled(Pid, <<"invite-notify">>)
    ],
    ircd_state_send:broadcast(Recipients, Prefix, <<"INVITE">>, [TargetNick, Name], none).

-doc """
Called once when a local client completes registration: send its account
(`ACCOUNT`) and away state to peers, and tell MONITOR watchers it is online
(730).
""".
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

-doc """
Release per-connection IRCv3 state when a client disconnects: tell MONITOR
watchers a registered nick went offline (731), drop its MONITOR list and
metadata, and delete its `m:ircd_conn` row.
""".
-spec disconnect(#client{}) -> ok.
disconnect(#client{pid = Pid, nick = Nick} = Client) ->
    case ircd_state_client:ready(Client) of
        true -> ircd_state_monitor:offline(Nick);
        false -> ok
    end,
    ircd_state_monitor:clear(Pid),
    ircd_state_meta:disconnect(Pid),
    ircd_conn:delete(Pid).

-doc """
Burst lines for a newly linked peer: one prefixed `ACCOUNT <name>` line
for every logged-in registered local user and every logged-in remote user.
""".
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

-doc """
`AUTHENTICATE` (SASL 3.1 and 3.2). Reauthentication is allowed.

The first parameter names the mechanism (see `ircd_sasl:start/2`); later
ones are base64 chunks of up to 400 bytes, reassembled with
`ircd_sasl:decode_chunk/2`. `AUTHENTICATE *` aborts with 906. Success logs
in (900 RPL_LOGGEDIN, account-notify, peers) and sends 903. An unknown
mechanism gets 908 with the available list, then 904; a bad exchange gets
904 and an over-long response 905. Failures are logged without credentials.
""".
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
                        [binary:join(ircd_cap:sasl_mechanisms(), <<",">>)],
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
                {error, overflow} ->
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
            sasl_success(Client, Account, Server);
        {check_password, Name, Password} ->
            %% PLAIN: derive the candidate key in a worker (ircd_deferred) so
            %% the PBKDF2 rounds never block ircd_state. Only the worker sees
            %% the password; the continuation gets the derived key.
            {Salt, Iterations} = ircd_account:password_params(Name),
            ircd_deferred:request(
                fun() -> ircd_account:derive_stored_key(Password, Salt, Iterations) end,
                fun(Result) -> plain_checked(Pid, Server, Name, Salt, Iterations, Result) end
            );
        {error, _} ->
            sasl_fail(Client, Server)
    end.

plain_checked(Pid, Server, Name, Salt, Iterations, Result) ->
    Client = ircd_state_client:client(Pid),
    case Result of
        {ok, Candidate} ->
            case ircd_account:password_matches(Name, Salt, Iterations, Candidate) of
                {ok, #account{name = Account}} -> sasl_success(Client, Account, Server);
                error -> sasl_fail(Client, Server)
            end;
        {error, _} ->
            sasl_fail(Client, Server)
    end.

sasl_success(#client{pid = Pid} = Client, Account, Server) ->
    clear_sasl(Pid),
    login(Client, Account, Server),
    sasl_numeric(Client, Server, <<"903">>, [], <<"SASL authentication successful">>).

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
    case
        Previous =/= undefined andalso
            ircd_wire:fold(Previous) =/= ircd_wire:fold(Account)
    of
        true -> ok = ircd_e2ee:session_down(Pid);
        false -> ok
    end,
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

-doc """
Log the client out (used when its account is removed). When it was logged
in, sends 901 RPL_LOGGEDOUT, `ACCOUNT *` to account-notify clients, and
`ACCOUNT *` to peers.
""".
-spec logout(#client{}, binary()) -> ok.
logout(#client{pid = Pid} = Client, Server) ->
    case account(Pid) of
        undefined ->
            ok;
        _ ->
            ok = ircd_e2ee:session_down(Pid),
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

-doc """
`REGISTER <account|*> <email|*> <password>` (draft/account-registration).

`*` as the account means the current (or, before registration, the last
refused) nickname. Allowed before registration completes unless
`account_registration_before_connect` is false. Without verification the
account is created and the client logged in (`REGISTER SUCCESS`). With
`account_verification` configured, a code is generated and handed to the
configured program, and the reply is `REGISTER VERIFICATION_REQUIRED`.

Failures are `FAIL REGISTER` with `TEMPORARILY_UNAVAILABLE`,
`COMPLETE_CONNECTION_REQUIRED`, `NEED_NICK`, `ALREADY_AUTHENTICATED`,
`ACCOUNT_EXISTS` (also when another client uses the nickname),
`INVALID_EMAIL`, `BAD_ACCOUNT_NAME`, `WEAK_PASSWORD`, or
`UNACCEPTABLE_PASSWORD`; missing parameters get 461. Only a SCRAM-SHA-256
verifier of the password is stored (`ircd_account:create/5`).
""".
-spec register([binary()], #client{}, binary()) -> ok.
register([Requested, Email, Password | _], #client{pid = Pid, nick = Current} = Client, Server) ->
    Nick =
        case Current of
            <<"*">> -> ircd_conn:get(Pid, wanted_nick, <<"*">>);
            _ -> Current
        end,
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
    Config = persistent_term:get({ircd_state, config}),
    EmailRequired =
        Verification =/= null orelse maps:get(account_registration_email_required, Config, false),
    EmailOk = valid_email(Email) andalso (not EmailRequired orelse Email =/= <<"*">>),
    %% Without `before-connect`, REGISTER needs a completed connection.
    TooEarly =
        not maps:get(account_registration_before_connect, Config, true) andalso
            not ircd_state_client:ready(Client),
    Held = Nick =/= <<"*">> andalso nick_held_by_other(Name, Pid),
    case {Enabled, Nick, account(Pid), EmailOk} of
        {false, _, _, _} ->
            reg_fail(Pid, <<"TEMPORARILY_UNAVAILABLE">>, Name, <<"Registration is disabled">>);
        _ when TooEarly ->
            ircd_state_send:fail(
                Pid,
                <<"REGISTER">>,
                <<"COMPLETE_CONNECTION_REQUIRED">>,
                [Name],
                <<"Finish connecting before registering">>
            );
        {_, <<"*">>, _, _} ->
            reg_fail(Pid, <<"NEED_NICK">>, <<"*">>, <<"Send NICK before REGISTER">>);
        {_, _, Logged, _} when Logged =/= undefined ->
            reg_fail(Pid, <<"ALREADY_AUTHENTICATED">>, Logged, <<"You are already logged in">>);
        {_, _, _, _} when Held ->
            %% No land grabs: an account cannot take a nickname that another
            %% client is using.
            reg_fail(Pid, <<"ACCOUNT_EXISTS">>, Name, <<"Account already exists">>);
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
            case ircd_account:validate_new(Name, Password) of
                ok ->
                    case ircd_flood:allow_register(Client#client.host) of
                        false ->
                            reg_fail(
                                Pid,
                                <<"TEMPORARILY_UNAVAILABLE">>,
                                Name,
                                <<"Registration rate limit exceeded, try again">>
                            );
                        true ->
                            %% The SCRAM verifier (PBKDF2) is derived in a worker
                            %% (ircd_deferred); the account is written when it is done.
                            ircd_deferred:request(
                                fun() -> ircd_account:new_verifier(Password) end,
                                fun(Result) ->
                                    register_derived(
                                        Result, Pid, Name, Stored, CertFps, Verification, Server
                                    )
                                end
                            )
                    end;
                {error, _} = Invalid ->
                    register_result(Invalid, Pid, Name, Stored, Verification, undefined, Server)
            end
    end;
register(_, Client, Server) ->
    ircd_state_send:numeric(
        Client, Server, <<"461">>, [<<"REGISTER">>], <<"Not enough parameters">>
    ).

register_derived({ok, Verifier}, Pid, Name, Stored, CertFps, Verification, Server) ->
    Pending =
        case Verification of
            null -> undefined;
            #{ttl := Ttl} -> {verification_code(), Ttl * 1000}
        end,
    Result = ircd_account:store_new(Name, Stored, Verifier, CertFps, Pending),
    register_result(Result, Pid, Name, Stored, Verification, Pending, Server);
register_derived({error, _}, Pid, Name, _Stored, _CertFps, _Verification, _Server) ->
    reg_fail(Pid, <<"TEMPORARILY_UNAVAILABLE">>, Name, <<"Registration is busy, try again">>).

register_result(Result, Pid, Name, Stored, Verification, Pending, Server) ->
    Client = ircd_state_client:client(Pid),
    case Result of
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
            reg_fail(Pid, <<"UNACCEPTABLE_PASSWORD">>, Name, <<"Password is too long">>);
        {error, account_limit_reached} ->
            reg_fail(Pid, <<"TEMPORARILY_UNAVAILABLE">>, Name, <<"Account limit reached">>)
    end.

%% True when another local or remote client currently uses the nickname.
nick_held_by_other(Name, Pid) ->
    case ircd_state_client:find_nick(Name) of
        #client{pid = Other} when Other =/= Pid ->
            true;
        _ ->
            mnesia:dirty_read(remote_client, ircd_wire:fold(Name)) =/= []
    end.

reg_fail(Pid, Code, Name, Text) ->
    ircd_state_send:fail(Pid, <<"REGISTER">>, Code, [Name], Text).

valid_email(<<"*">>) ->
    true;
valid_email(Email) ->
    %% UTF-8 is required: emails are later trimmed and lower-cased with
    %% `string` functions, which raise on invalid UTF-8 (REGISTER is exempt
    %% from the UTF8ONLY check).
    byte_size(Email) =< 254 andalso valid_utf8(Email) andalso
        case binary:split(Email, <<"@">>) of
            [Local, Domain] -> Local =/= <<>> andalso binary:match(Domain, <<".">>) =/= nomatch;
            _ -> false
        end.

%% Eight random characters from an unambiguous alphabet.
verification_code() ->
    Alphabet = <<"ABCDEFGHJKLMNPQRSTUVWXYZ23456789">>,
    <<<<(binary:at(Alphabet, B rem 32))>> || <<B>> <= crypto:strong_rand_bytes(8)>>.

%% Deliver a verification code via configured `smtp` (gen_smtp) and/or external
%% `command` program. For `command`, the code, account, address, and optional
%% web link are passed in the environment (IRCD_ACCOUNT, IRCD_EMAIL, IRCD_CODE,
%% IRCD_VERIFY_URL) rather than argv. The code is never logged.
send_verification(Verification, Account, Email, Code) ->
    case maps:is_key(smtp, Verification) of
        true -> ircd_mail:send_verification(Verification, Account, Email, Code);
        false -> ok
    end,
    case maps:find(command, Verification) of
        {ok, [Exe | Args]} ->
            ExtraEnv =
                case maps:get(verify_url, Verification, null) of
                    BaseUrl when is_binary(BaseUrl), byte_size(BaseUrl) > 0 ->
                        [
                            {
                                "IRCD_VERIFY_URL",
                                binary_to_list(ircd_mail:verify_link(BaseUrl, Account, Code))
                            }
                        ];
                    _ ->
                        []
                end,
            _ = spawn(fun() ->
                try
                    Port = open_port({spawn_executable, Exe}, [
                        {args, Args},
                        {env, [
                            {"IRCD_ACCOUNT", binary_to_list(Account)},
                            {"IRCD_EMAIL", binary_to_list(Email)},
                            {"IRCD_CODE", binary_to_list(Code)}
                            | ExtraEnv
                        ]},
                        exit_status,
                        use_stdio,
                        stderr_to_stdout
                    ]),
                    wait_sender(Port, Account)
                catch
                    error:Reason ->
                        logger:warning(#{
                            event => account_verification_failed,
                            account => Account,
                            reason => Reason
                        })
                end
            end),
            ok;
        error ->
            ok
    end.

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

-doc """
`VERIFY <account> <code>` (draft/account-registration). A correct,
unexpired code for a pending account activates it, replies
`VERIFY SUCCESS`, and logs the client in, as SASL would.

A wrong code gets `FAIL VERIFY INVALID_CODE`; a logged-in client gets
`FAIL VERIFY ALREADY_AUTHENTICATED`; missing parameters get 461.
""".
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

-doc """
Activate a pending account via the web verification link.
Runs inside `m:ircd_state`; returns `{ok, AccountName}` or `error`.
""".
-spec verify_account_web(binary(), binary()) -> {ok, binary()} | error.
verify_account_web(Name, Code) when is_binary(Name), is_binary(Code) ->
    case ircd_account:verify(string:trim(Name), string:trim(Code)) of
        {ok, #account{name = Actual} = Account} ->
            logger:info(#{event => account_registered, account => Actual, via => web}),
            ircd_state_sync:account_created(Account),
            {ok, Actual};
        error ->
            error
    end.

-doc """
Activate a pending account via email address and verification code from `/verify`.
Runs inside `m:ircd_state`; returns `{ok, AccountName}` or `error`.
""".
-spec verify_account_email_web(binary(), binary()) -> {ok, binary()} | error.
verify_account_email_web(Email, Code) when is_binary(Email), is_binary(Code) ->
    case ircd_account:verify_by_email(Email, Code) of
        {ok, #account{name = Actual} = Account} ->
            logger:info(#{event => account_registered, account => Actual, via => web}),
            ircd_state_sync:account_created(Account),
            {ok, Actual};
        error ->
            error
    end.

-doc """
Initiate email password recovery for a verified account. Runs inside
`m:ircd_state`. Always returns `ok` for valid email addresses even when no
account matches (to prevent email enumeration).
""".
-spec request_password_reset_web(binary(), binary() | null, binary()) ->
    ok | {error, disabled | rate_limited | bad_email}.
request_password_reset_web(Email0, RecoveryUrl, PeerIP) when is_binary(Email0) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(account_verification, Config, null) of
        #{ttl := Ttl, smtp := _} = Verification ->
            case ircd_flood:allow_register(PeerIP) of
                false ->
                    {error, rate_limited};
                true ->
                    case normalize_web_email(Email0, true) of
                        {error, _} ->
                            {error, bad_email};
                        {ok, Email} ->
                            maybe_send_reset(Verification, Ttl, Email, RecoveryUrl),
                            ok
                    end
            end;
        _ ->
            {error, disabled}
    end;
request_password_reset_web(_, _, _) ->
    {error, bad_email}.

maybe_send_reset(Verification, Ttl, Email, RecoveryUrl) ->
    case ircd_account:find_by_email(Email) of
        {ok, #account{key = Folded, name = AccountName, email = StoredEmail}} ->
            _ = ensure_reset_table(),
            Code = verification_code(),
            Hash = crypto:hash(sha256, Code),
            Expires = erlang:system_time(millisecond) + Ttl * 1000,
            EmailKey = ircd_account:email_key(StoredEmail),
            ets:insert(ircd_password_reset, {EmailKey, Folded, AccountName, Hash, Expires}),
            logger:info(#{event => password_reset_requested, account => AccountName}),
            ircd_mail:send_password_reset(
                Verification, AccountName, StoredEmail, Code, RecoveryUrl
            );
        error ->
            ok
    end.

-doc """
Complete email password recovery by checking the single-use reset code and
updating the account's SCRAM-SHA-256 password verifier. Runs inside
`m:ircd_state`.
""".
-spec complete_password_reset_web(binary(), binary(), binary(), binary()) ->
    {ok, binary()} | {error, disabled | rate_limited | invalid_code | bad_password}.
complete_password_reset_web(Email0, Code0, NewPassword, PeerIP) when
    is_binary(Email0), is_binary(Code0), is_binary(NewPassword)
->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(account_verification, Config, null) of
        #{smtp := _} ->
            case ircd_flood:allow_register(PeerIP) of
                false ->
                    {error, rate_limited};
                true ->
                    EmailKey = ircd_account:email_key(Email0),
                    CodeHash = crypto:hash(sha256, string:trim(Code0)),
                    Now = erlang:system_time(millisecond),
                    _ = ensure_reset_table(),
                    case ets:lookup(ircd_password_reset, EmailKey) of
                        [{EmailKey, _Folded, AccountName, StoredHash, Expires}] when
                            Now =< Expires
                        ->
                            case crypto:hash_equals(CodeHash, StoredHash) of
                                true ->
                                    case ircd_account:set_password(AccountName, NewPassword) of
                                        {ok, #account{name = Actual} = Updated} ->
                                            ets:delete(ircd_password_reset, EmailKey),
                                            logger:info(#{
                                                event => password_reset_completed,
                                                account => Actual
                                            }),
                                            ircd_state_sync:account_created(Updated),
                                            {ok, Actual};
                                        {error, bad_password} ->
                                            {error, bad_password};
                                        {error, no_such_account} ->
                                            ets:delete(ircd_password_reset, EmailKey),
                                            {error, invalid_code}
                                    end;
                                false ->
                                    {error, invalid_code}
                            end;
                        [{EmailKey, _, _, _, _}] ->
                            ets:delete(ircd_password_reset, EmailKey),
                            {error, invalid_code};
                        [] ->
                            {error, invalid_code}
                    end
            end;
        _ ->
            {error, disabled}
    end;
complete_password_reset_web(_, _, _, _) ->
    {error, invalid_code}.

ensure_reset_table() ->
    case ets:whereis(ircd_password_reset) of
        undefined ->
            ets:new(ircd_password_reset, [named_table, set, public]);
        _ ->
            ok
    end.

-doc """
Create an IRC account from the public WebUI sign-up page.

Runs inside `m:ircd_state`. Enforces `account_registration`, per-IP
`ircd_flood:allow_register/1`, email requirements, and optional
`account_verification` (sending the verification email/link when enabled).
Returns `{ok, created | verification_required, AccountName}` or `{error, Reason}`.
""".
-spec signup_account_web(binary(), undefined | binary(), binary(), binary()) ->
    {ok, created | verification_required, binary()} | {error, atom()}.
signup_account_web(Name, Email0, Password, PeerIP) ->
    Config = persistent_term:get({ircd_state, config}, #{}),
    case maps:get(account_registration, Config, true) of
        false ->
            {error, registration_disabled};
        true ->
            case ircd_flood:allow_register(PeerIP) of
                false ->
                    {error, rate_limited};
                true ->
                    Verification = maps:get(account_verification, Config, null),
                    EmailRequired =
                        Verification =/= null orelse
                            maps:get(account_registration_email_required, Config, false),
                    case normalize_web_email(Email0, EmailRequired) of
                        {error, Reason} ->
                            {error, Reason};
                        {ok, StoredEmail} ->
                            Pending =
                                case Verification of
                                    #{ttl := Ttl} ->
                                        {verification_code(), Ttl * 1000};
                                    null ->
                                        undefined
                                end,
                            case ircd_account:create(Name, StoredEmail, Password, [], Pending) of
                                {ok, #account{name = Actual} = Account} when
                                    Pending =:= undefined
                                ->
                                    logger:info(#{
                                        event => account_registered, account => Actual, via => web
                                    }),
                                    ircd_state_sync:account_created(Account),
                                    {ok, created, Actual};
                                {ok, #account{name = Actual}} ->
                                    {Code, _} = Pending,
                                    logger:info(#{
                                        event => account_verification_sent,
                                        account => Actual,
                                        via => web
                                    }),
                                    send_verification(Verification, Actual, StoredEmail, Code),
                                    {ok, verification_required, Actual};
                                {error, Reason} ->
                                    {error, Reason}
                            end
                    end
            end
    end.

normalize_web_email(undefined, true) ->
    {error, email_required};
normalize_web_email(<<>>, true) ->
    {error, email_required};
normalize_web_email(undefined, false) ->
    {ok, undefined};
normalize_web_email(<<>>, false) ->
    {ok, undefined};
normalize_web_email(<<"*">>, _) ->
    {error, invalid_email};
normalize_web_email(Email, _) when is_binary(Email) ->
    case valid_email(Email) of
        true -> {ok, Email};
        false -> {error, invalid_email}
    end;
normalize_web_email(_, _) ->
    {error, invalid_email}.

%%% setname, chghost, pre-away

-doc """
`SETNAME :<realname>`. The change is shown to setname clients that
share a channel (and to the sender when it has `setname`), and is
propagated to peers.

A realname over 200 bytes (`NAMELEN`), or invalid UTF-8 with `utf8_only`,
gets `FAIL SETNAME INVALID_REALNAME`.
""".
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

-doc """
True when `Text` is well-formed UTF-8. Used for the `UTF8ONLY` checks.
""".
-spec valid_utf8(binary()) -> boolean().
valid_utf8(Text) ->
    case unicode:characters_to_binary(Text, utf8, utf8) of
        Bin when is_binary(Bin) -> true;
        _ -> false
    end.

-doc """
Operator `CHGHOST <nick> <user> <host>` (IRCv3 chghost) for a local user.

chghost clients (and extended-monitor watchers with chghost) see
`CHGHOST`; other members of shared channels see QUIT, JOIN, and the member's
channel modes, as the specification recommends. The change goes to peers.
Non-operators get 481; an unknown nick 401; a bad user or host
`FAIL CHGHOST INVALID_USERNAME` / `INVALID_HOSTNAME`.
""".
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

-doc """
draft/pre-away: `AWAY` before registration completes, for a client that
negotiated `draft/pre-away` (others get 451). Replies 305 or 306. `AWAY *`
means away for an unspecified reason; this server stores `Away` as the text.
""".
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

-doc """
`:nick!user@host ACCOUNT <name|*>` from a peer: store the remote user's
account, tell local account-notify clients, and relay to the other peers.

Returns `{error, unknown_remote_source}` when the prefix does not exactly
match a user behind `Peer`.
""".
-spec receive_remote_account(binary(), binary(), [binary()]) -> ok | {error, term()}.
receive_remote_account(Peer, Prefix, [Value | _]) ->
    case ircd_state_link:remote_source(Peer, Prefix) of
        {ok, #remote_client{key = Key, account = Previous} = Remote} ->
            Account =
                case Value of
                    <<"*">> -> undefined;
                    _ -> ircd_wire:retain(Value)
                end,
            case
                Previous =/= undefined andalso
                    (Account =:= undefined orelse
                        ircd_wire:fold(Previous) =/= ircd_wire:fold(Account))
            of
                true -> ok = ircd_e2ee:forget_remote(Key);
                false -> ok
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

-doc """
`:nick!user@host SETNAME :<realname>` from a peer: store the realname,
tell local setname clients, and relay to the other peers.

Returns `{error, unknown_remote_source}` when the prefix does not exactly
match a user behind `Peer`.
""".
-spec receive_remote_setname(binary(), binary(), [binary()]) -> ok | {error, term()}.
receive_remote_setname(Peer, Prefix, [Real | _]) ->
    case ircd_state_link:remote_source(Peer, Prefix) of
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

-doc """
`:nick!old_user@old_host CHGHOST <user> <host>` from a peer: store the new
user and host, show `CHGHOST` (or QUIT and JOIN to legacy clients), and
relay to the other peers.

Returns `{error, unknown_remote_source}` for a prefix not owned by `Peer`
and `{error, invalid_chghost_message}` for a bad user or host.
""".
-spec receive_remote_chghost(binary(), binary(), [binary()]) -> ok | {error, term()}.
receive_remote_chghost(Peer, Prefix, [User, Host | _]) ->
    case {ircd_state_link:remote_source(Peer, Prefix), valid_user(User), valid_host(Host)} of
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

%%% WEBIRC and ISUPPORT

-doc """
`WEBIRC <password> <gateway> <hostname> <ip> [:<options>]`.

Accepted only as the first command (before `NICK`, `USER`, and `CAP`) from a
configured gateway address with its password. The client's host becomes
`hostname` (or the IP when the hostname is not valid). The `secure` option
counts only on a TLS gateway connection, and then `certfp-sha-256=` replaces
the certificate fingerprint. A failure sends `ERROR` and closes the
connection.
""".
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
    %% Strict parsing: legacy short forms such as `127.1` are not addresses a
    %% gateway should send.
    case {Fresh, Trusted, inet:parse_strict_address(binary_to_list(Ip))} of
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
        [Fp | _] when byte_size(Fp) =:= 64 ->
            %% Normalize the hex digits to lowercase; anything that is not hex
            %% (which `string:lowercase/1` would raise on if it was invalid
            %% UTF-8) cannot match a certificate fingerprint.
            try
                binary:encode_hex(binary:decode_hex(Fp), lowercase)
            catch
                error:badarg -> undefined
            end;
        _ ->
            undefined
    end.

-doc """
`ISUPPORT` (draft/extended-isupport): resend the 005 tokens. Before
registration the client must have negotiated the capability, otherwise
it gets 451.
""".
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

-doc """
`STARTTLS` (deprecated IRCv3 `tls` extension). Allowed once, before
registration, on a plaintext TCP connection when TLS is configured.

Returns `starttls` after the 670 reply; the session then performs the
handshake. Otherwise sends 691 and returns `ok`.
""".
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

%%% multiclient and account rejoin (opt-in operator features)

-doc """
True when, with `multiclient` enabled, the unregistered `Client` is logged
in to the same account (RFC 1459 folded) as the registered `Holder`, so it
may attach to that client's nickname instead of getting 433.
""".
-spec attachable(#client{}, #client{}) -> boolean().
attachable(#client{pid = Pid} = Client, #client{pid = Holder} = HolderClient) ->
    Config = persistent_term:get({ircd_state, config}),
    Account = account(Pid),
    maps:get(multiclient, Config, false) andalso Account =/= undefined andalso
        not ircd_state_client:ready(Client) andalso ircd_state_client:ready(HolderClient) andalso
        ircd_wire:fold(Account) =:= ircd_wire:fold(fold_or_empty(account(Holder))).

fold_or_empty(undefined) -> <<>>;
fold_or_empty(Value) -> Value.

-doc """
Take the nickname for this connection without indexing it; the
connection attaches to `Holder` once its registration completes.
""".
-spec prepare_attach(#client{}, #client{}, binary()) -> ok.
prepare_attach(#client{pid = Pid} = Client, #client{pid = Holder}, Nick) ->
    ircd_conn:put(Pid, attach_to, Holder),
    mnesia:dirty_write(Client#client{nick = ircd_wire:retain(Nick)}),
    ok.

-doc """
Finish an attach after the welcome burst: route this connection's
commands to `Holder`, drop its own client, activity, user mode, capability,
and `m:ircd_conn` records, and send `{attached_session, Pid}` to the
holder and `{attach, Holder}` to the connection.
""".
-spec finish_attach(#client{}, pid()) -> ok.
finish_attach(#client{pid = Pid, nick = Nick}, Holder) ->
    ets:insert(ircd_attached, {Pid, Holder}),
    logger:info(#{event => session_attached, nick => Nick}),
    mnesia:dirty_delete(client, Pid),
    mnesia:dirty_delete(activity, Pid),
    mnesia:dirty_delete(user_modes, Pid),
    ircd_cap:disconnect(Pid),
    ircd_conn:delete(Pid),
    ok = ircd_flood:disconnect(Pid),
    ircd_state_client:remove_connection_stats(Pid),
    %% The holder learns of the new connection first: replies to lines the new
    %% connection already pipelined (run as the holder) are then mirrored to it.
    Holder ! {attached_session, Pid},
    Pid ! {attach, Holder},
    ok.

-doc """
With `account_rejoin`, remember a logged-in client's channels when it
disconnects (in memory, until the next login or restart).
""".
-spec remember_channels(#client{}) -> ok.
remember_channels(#client{pid = Pid, channels = Keys}) ->
    case
        {maps:get(account_rejoin, persistent_term:get({ircd_state, config}), false), account(Pid)}
    of
        {true, Account} when is_binary(Account), Keys =/= [] ->
            Names = [
                Name
             || Key <- Keys, [#channel{name = Name}] <- [mnesia:dirty_read(channel, Key)]
            ],
            ets:insert(ircd_account_channels, {ircd_wire:fold(Account), Names}),
            ok;
        _ ->
            ok
    end.

-doc """
With `account_rejoin`, join the channels remembered for this client's
account by `remember_channels/1`, after the welcome. The entry is consumed.
""".
-spec rejoin_on_login(#client{}, binary()) -> ok.
rejoin_on_login(#client{pid = Pid}, Server) ->
    case account(Pid) of
        undefined ->
            ok;
        Account ->
            case ets:take(ircd_account_channels, ircd_wire:fold(Account)) of
                [{_, Names}] -> ircd_state_channel:join_channels(Names, [], Pid, Server);
                [] -> ok
            end
    end.

-doc """
Update any `account_rejoin` entry that lists `OldKey` to use the renamed
channel `NewName`.
""".
-spec rename_channel(binary(), binary()) -> ok.
rename_channel(OldKey, NewName) ->
    case ets:whereis(ircd_account_channels) of
        undefined ->
            ok;
        _ ->
            Kept = ircd_wire:retain(NewName),
            lists:foreach(
                fun({Account, Names}) ->
                    Updated = [
                        case ircd_wire:fold(N) =:= OldKey of
                            true -> Kept;
                            false -> N
                        end
                     || N <- Names
                    ],
                    case Updated =:= Names of
                        true -> ok;
                        false -> ets:insert(ircd_account_channels, {Account, Updated})
                    end
                end,
                ets:tab2list(ircd_account_channels)
            )
    end.
