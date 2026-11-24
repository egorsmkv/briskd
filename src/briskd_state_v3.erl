-module(briskd_state_v3).
-export([
    expire_password_resets/0,
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
    valid_email/1,
    valid_utf8/1,
    verify/3,
    verify_account_web/2,
    verify_account_email_web/2,
    signup_account_web/4,
    request_password_reset_web/3,
    complete_password_reset_web/4,
    valid_host/1,
    webirc/3
]).
-include("briskd_state.hrl").

-moduledoc """
IRCv3 identity, account, and notification commands, and their link
propagation.

Runs inside `m:briskd_state`. Implements:

- Accounts: [SASL 3.1 / 3.2](https://ircv3.net/specs/extensions/sasl-3.2)
  (`AUTHENTICATE`, mechanisms in `m:briskd_sasl`),
  [draft/account-registration](https://ircv3.net/specs/extensions/account-registration)
  (`REGISTER`, `VERIFY`, storage in `m:briskd_account`),
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
`m:briskd_conn`; it is dropped on disconnect. Account changes, `SETNAME`, and
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
    briskd_conn:get(Pid, account).

-doc """
Account of a remote user by folded nick (`briskd_wire:fold/1`), or
`undefined` when not logged in or unknown.
""".
-spec remote_account(binary()) -> undefined | binary().
remote_account(NickKey) ->
    case mnesia:dirty_read(remote_client, NickKey) of
        [#remote_client{account = Account}] -> Account;
        [] -> undefined
    end.

-doc """
Source-tag facts for a local client, for `briskd_state_send:set_source/1`:
`prefix`, `account`, `bot` (user mode `+B`), and `oper` (the nick when
`+o`). Returns `#{}` before `USER` is accepted.
""".
-spec source_info(#client{}) -> map().
source_info(#client{pid = Pid, nick = Nick, user = User} = Client) when User =/= undefined ->
    Modes = briskd_state_client:user_modes(Pid),
    #{
        prefix => iolist_to_binary(briskd_state_send:prefix(Client)),
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
            case mnesia:dirty_read(remote_client, briskd_wire:fold(Nick)) of
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
    Shared = briskd_state_channel:nick_recipients(Client),
    Recipients = recipients(Shared, Nick, Cap, Pid, IncludeSelf),
    briskd_state_send:broadcast(
        Recipients, briskd_state_send:prefix(Client), Command, Middle, Tail
    ).

-doc """
Send a notification line about a remote user, with `Prefix`, to local
clients with `Cap` that share a channel with it or (with extended-monitor)
monitor its nick.
""".
-spec notify_remote(#remote_client{}, binary(), binary(), binary(), [iodata()], none | iodata()) ->
    ok.
notify_remote(#remote_client{key = Key, nick = Nick}, Prefix, Cap, Command, Middle, Tail) ->
    Shared = briskd_state_link:remote_user_local_recipients(Key),
    Recipients = recipients(Shared, Nick, Cap, undefined, false),
    briskd_state_send:broadcast(Recipients, Prefix, Command, Middle, Tail).

recipients(Shared, Nick, Cap, Self, IncludeSelf) ->
    Watchers = [
        Watcher
     || Watcher <- briskd_state_monitor:watchers(Nick),
        briskd_cap:enabled(Watcher, <<"extended-monitor">>)
    ],
    [
        Pid
     || Pid <- lists:usort(Shared ++ Watchers),
        Pid =/= Self orelse IncludeSelf,
        briskd_cap:enabled(Pid, Cap)
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
        fun(Pid) -> briskd_cap:enabled(Pid, <<"extended-join">>) end, Pids
    ),
    AccountParam =
        case Account of
            undefined -> <<"*">>;
            _ -> Account
        end,
    briskd_state_send:broadcast(Plain, Prefix, <<"JOIN">>, [Channel], none, Tags),
    briskd_state_send:broadcast(Extended, Prefix, <<"JOIN">>, [Channel, AccountParam], Real, Tags),
    ok.

-doc """
After a JOIN, tell members with away-notify that the joining user is away
(`AWAY :<message>`). A no-op when `Away` is `undefined`.
""".
-spec away_on_join([pid()], iodata(), undefined | binary()) -> ok.
away_on_join(_Pids, _Prefix, undefined) ->
    ok;
away_on_join(Pids, Prefix, Away) ->
    briskd_state_send:broadcast(
        [Pid || Pid <- Pids, briskd_cap:enabled(Pid, <<"away-notify">>)],
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
        briskd_cap:enabled(Pid, <<"invite-notify">>)
    ],
    briskd_state_send:broadcast(Recipients, Prefix, <<"INVITE">>, [TargetNick, Name], none).

-doc """
Called once when a local client completes registration: send its account
(`ACCOUNT`) and away state to peers, and tell MONITOR watchers it is online
(730).
""".
-spec registered(#client{}, binary()) -> ok.
registered(#client{pid = Pid, away = Away} = Client, _Server) ->
    Prefix = briskd_state_send:prefix(Client),
    case account(Pid) of
        undefined ->
            ok;
        Account ->
            briskd_state_link:server_broadcast(
                briskd_wire:line(Prefix, <<"ACCOUNT">>, [Account], none)
            )
    end,
    case Away of
        undefined -> ok;
        _ -> briskd_state_link:propagate_away(Client, Away)
    end,
    briskd_state_monitor:online(Client#client.nick, iolist_to_binary(Prefix)),
    ok.

-doc """
Release per-connection IRCv3 state when a client disconnects: tell MONITOR
watchers a registered nick went offline (731), drop its MONITOR list and
metadata, and delete its `m:briskd_conn` row.
""".
-spec disconnect(#client{}) -> ok.
disconnect(#client{pid = Pid, nick = Nick} = Client) ->
    case briskd_state_client:ready(Client) of
        true -> briskd_state_monitor:offline(Nick);
        false -> ok
    end,
    briskd_state_monitor:clear(Pid),
    briskd_state_meta:disconnect(Pid),
    briskd_conn:delete(Pid).

-doc """
Burst lines for a newly linked peer: one prefixed `ACCOUNT <name>` line
for every logged-in registered local user and every logged-in remote user.
""".
-spec burst_lines(binary()) -> [binary()].
burst_lines(_Server) ->
    Local = [
        iolist_to_binary(
            briskd_wire:line(briskd_state_send:prefix(Client), <<"ACCOUNT">>, [Account], none)
        )
     || Pid <- briskd_state_client:pids(),
        [#client{} = Client] <- [mnesia:dirty_read(client, Pid)],
        briskd_state_client:ready(Client),
        Account <- [account(Pid)],
        Account =/= undefined
    ],
    Remote = [
        iolist_to_binary(
            briskd_wire:line(
                <<Nick/binary, "!", User/binary, "@", Host/binary>>, <<"ACCOUNT">>, [Account], none
            )
        )
     || Key <- briskd_state:table_keys(remote_client),
        [#remote_client{nick = Nick, user = User, host = Host, account = Account}] <-
            [mnesia:dirty_read(remote_client, Key)],
        Account =/= undefined
    ],
    Local ++ Remote.

-doc "`AUTHENTICATE` (SASL 3.1 and 3.2).".
-spec authenticate([binary()], #client{}, binary()) -> ok.
authenticate(Params, Client, Server) ->
    briskd_v3_auth:authenticate(Params, Client, Server).

-doc "Log the client out (901 RPL_LOGGEDOUT and `ACCOUNT *`).".
-spec logout(#client{}, binary()) -> ok.
logout(Client, Server) ->
    briskd_v3_auth:logout(Client, Server).

-doc "`REGISTER <account|*> <email|*> <password>` (draft/account-registration).".
-spec register([binary()], #client{}, binary()) -> ok.
register(Params, Client, Server) ->
    briskd_v3_auth:register(Params, Client, Server).

-doc "Whether `Email` is an acceptable email address.".
-spec valid_email(binary()) -> boolean().
valid_email(Email) ->
    briskd_v3_auth:valid_email(Email).

-doc "`VERIFY <account> <code>` (draft/account-registration).".
-spec verify([binary()], #client{}, binary()) -> ok.
verify(Params, Client, Server) ->
    briskd_v3_auth:verify(Params, Client, Server).

-doc "Activate a pending account via the web verification link.".
-spec verify_account_web(binary(), binary()) -> {ok, binary()} | error.
verify_account_web(Name, Code) ->
    briskd_v3_auth:verify_account_web(Name, Code).

-doc "Activate a pending account via email address and code from `/verify`.".
-spec verify_account_email_web(binary(), binary()) -> {ok, binary()} | error.
verify_account_email_web(Email, Code) ->
    briskd_v3_auth:verify_account_email_web(Email, Code).

-doc "Initiate email password recovery for a verified account.".
-spec request_password_reset_web(binary(), binary() | null, binary()) ->
    ok | {error, disabled | rate_limited | bad_email}.
request_password_reset_web(Email, RecoveryUrl, PeerIP) ->
    briskd_v3_auth:request_password_reset_web(Email, RecoveryUrl, PeerIP).

-doc "Delete expired password-reset codes.".
-spec expire_password_resets() -> ok.
expire_password_resets() ->
    briskd_v3_auth:expire_password_resets().

-doc "Complete email password recovery and update SCRAM-SHA-256 verifier.".
-spec complete_password_reset_web(binary(), binary(), binary(), binary()) ->
    {ok, binary()} | {error, disabled | rate_limited | invalid_code | bad_password}.
complete_password_reset_web(Email, Code, NewPassword, PeerIP) ->
    briskd_v3_auth:complete_password_reset_web(Email, Code, NewPassword, PeerIP).

-doc "Create an IRC account from the public WebUI sign-up page.".
-spec signup_account_web(binary(), undefined | binary(), binary(), binary()) ->
    {ok, created | verification_required, binary()} | {error, atom()}.
signup_account_web(Name, Email, Password, PeerIP) ->
    briskd_v3_auth:signup_account_web(Name, Email, Password, PeerIP).

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
            briskd_state_send:fail(
                Pid, <<"SETNAME">>, <<"INVALID_REALNAME">>, [], <<"Realname is not valid">>
            );
        true ->
            Current = briskd_state_client:client(Pid),
            mnesia:dirty_write(Current#client{real = briskd_wire:retain(Real)}),
            notify(Current, <<"setname">>, <<"SETNAME">>, [], Real, true),
            briskd_state_link:server_broadcast(
                briskd_wire:line(briskd_state_send:prefix(Current), <<"SETNAME">>, [], Real)
            ),
            _ = Server,
            _ = Client,
            ok
    end;
setname([], Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"SETNAME">>], <<"Not enough parameters">>
    ).

valid_realname(Real) ->
    byte_size(Real) =< ?NAMELEN andalso valid_utf8_if_required(Real).

valid_utf8_if_required(Text) ->
    case maps:get(utf8_only, briskd_config:current(), false) of
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
    case maps:is_key($o, briskd_state_client:user_modes(Pid)) of
        false ->
            briskd_state_send:numeric(
                Client, Server, <<"481">>, [], <<"Permission Denied- You're not an IRC operator">>
            );
        true ->
            case {briskd_state_client:find_nick(Nick), valid_user(User), valid_host(Host)} of
                {undefined, _, _} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"401">>, [Nick], <<"No such nick">>
                    );
                {_, false, _} ->
                    briskd_state_send:fail(
                        Pid, <<"CHGHOST">>, <<"INVALID_USERNAME">>, [User], <<"Invalid username">>
                    );
                {_, _, false} ->
                    briskd_state_send:fail(
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
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"CHGHOST">>], <<"Not enough parameters">>
    ).

valid_user(User) ->
    re:run(User, <<"^~?[A-Za-z0-9_.-]{1,32}$">>, [{capture, none}, dollar_endonly]) =:= match.

-doc "True when `Host` is a syntactically valid IRC hostname.".
-spec valid_host(binary()) -> boolean().
valid_host(Host) ->
    byte_size(Host) > 0 andalso byte_size(Host) =< 63 andalso
        re:run(Host, <<"^[A-Za-z0-9.:/-]+$">>, [{capture, none}, dollar_endonly]) =:= match andalso
        binary:first(Host) =/= $:.

apply_chghost(Target, User, Host, Server) ->
    %% CHGHOST and its fallback lines are the target's own, so they carry the
    %% target's account and oper tags, not the operator's.
    briskd_state_send:with_source(source_info(Target), fun() ->
        apply_chghost_as_target(Target, User, Host, Server)
    end).

apply_chghost_as_target(#client{pid = Pid} = Target, User, Host, Server) ->
    OldPrefix = iolist_to_binary(briskd_state_send:prefix(Target)),
    Updated = Target#client{user = briskd_wire:retain(User), host = briskd_wire:retain(Host)},
    mnesia:dirty_write(Updated),
    NewPrefix = iolist_to_binary(briskd_state_send:prefix(Updated)),
    Shared = briskd_state_channel:nick_recipients(Target),
    {Capable, Legacy} = lists:partition(
        fun(P) -> briskd_cap:enabled(P, <<"chghost">>) end, Shared
    ),
    Watchers = [
        W
     || W <- briskd_state_monitor:watchers(Target#client.nick),
        briskd_cap:enabled(W, <<"extended-monitor">>),
        briskd_cap:enabled(W, <<"chghost">>)
    ],
    briskd_state_send:broadcast(
        lists:usort(Capable ++ Watchers), OldPrefix, <<"CHGHOST">>, [User, Host], none
    ),
    simulate_reconnect(Updated, [P || P <- Legacy, P =/= Pid], OldPrefix, NewPrefix, Server),
    briskd_state_link:server_broadcast(
        briskd_wire:line(OldPrefix, <<"CHGHOST">>, [User, Host], none)
    ),
    ok.

%% Legacy clients see QUIT, then JOIN and mode restoration per shared channel.
simulate_reconnect(_Client, [], _Old, _New, _Server) ->
    ok;
simulate_reconnect(#client{pid = Pid, channels = Keys}, Legacy, OldPrefix, NewPrefix, Server) ->
    briskd_state_send:broadcast(Legacy, OldPrefix, <<"QUIT">>, [], <<"Changing hostname">>),
    lists:foreach(
        fun(Key) ->
            case mnesia:dirty_read(channel, Key) of
                [#channel{name = Name, members = Members, flags = Flags}] ->
                    case maps:is_key($a, Flags) orelse maps:is_key($q, Flags) of
                        true ->
                            ok;
                        false ->
                            Viewers = [P || P <- maps:keys(Members), lists:member(P, Legacy)],
                            briskd_state_send:broadcast(
                                Viewers, NewPrefix, <<"JOIN">>, [Name], none
                            ),
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
                                    briskd_state_send:broadcast(
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
    case briskd_cap:enabled(Pid, <<"draft/pre-away">>) of
        false ->
            briskd_state_send:numeric(Client, Server, <<"451">>, [], <<"You have not registered">>);
        true ->
            case Params of
                Back when Back =:= []; Back =:= [<<>>] ->
                    mnesia:dirty_write(Client#client{away = undefined}),
                    briskd_state_send:numeric(
                        Client, Server, <<"305">>, [], <<"You are no longer marked as being away">>
                    );
                [Message | _] ->
                    mnesia:dirty_write(Client#client{away = briskd_wire:retain(away_text(Message))}),
                    briskd_state_send:numeric(
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
    case briskd_state_link:remote_source(Peer, Prefix) of
        {ok, #remote_client{key = Key, account = Previous} = Remote} ->
            Account =
                case Value of
                    <<"*">> -> undefined;
                    _ -> briskd_wire:retain(Value)
                end,
            case
                Previous =/= undefined andalso
                    (Account =:= undefined orelse
                        briskd_wire:fold(Previous) =/= briskd_wire:fold(Account))
            of
                true -> ok = briskd_e2ee:forget_remote(Key);
                false -> ok
            end,
            mnesia:dirty_write(Remote#remote_client{account = Account}),
            notify_remote(Remote, Prefix, <<"account-notify">>, <<"ACCOUNT">>, [Value], none),
            briskd_state_link:relay_except(
                Peer, briskd_wire:line(Prefix, <<"ACCOUNT">>, [Value], none)
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
    case briskd_state_link:remote_source(Peer, Prefix) of
        {ok, Remote} ->
            mnesia:dirty_write(Remote#remote_client{real = briskd_wire:retain(Real)}),
            notify_remote(Remote, Prefix, <<"setname">>, <<"SETNAME">>, [], Real),
            briskd_state_link:relay_except(Peer, briskd_wire:line(Prefix, <<"SETNAME">>, [], Real)),
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
    case {briskd_state_link:remote_source(Peer, Prefix), valid_user(User), valid_host(Host)} of
        {{ok, #remote_client{key = Key, nick = Nick} = Remote}, true, true} ->
            mnesia:dirty_write(Remote#remote_client{
                user = briskd_wire:retain(User), host = briskd_wire:retain(Host)
            }),
            Shared = briskd_state_link:remote_user_local_recipients(Key),
            {Capable, Legacy} = lists:partition(
                fun(P) -> briskd_cap:enabled(P, <<"chghost">>) end, Shared
            ),
            Watchers = [
                W
             || W <- briskd_state_monitor:watchers(Nick),
                briskd_cap:enabled(W, <<"extended-monitor">>),
                briskd_cap:enabled(W, <<"chghost">>)
            ],
            briskd_state_send:broadcast(
                lists:usort(Capable ++ Watchers), Prefix, <<"CHGHOST">>, [User, Host], none
            ),
            NewPrefix = <<Nick/binary, "!", User/binary, "@", Host/binary>>,
            briskd_state_send:broadcast(Legacy, Prefix, <<"QUIT">>, [], <<"Changing hostname">>),
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
                            briskd_state_send:broadcast(
                                Viewers, NewPrefix, <<"JOIN">>, [Name], none
                            );
                        _ ->
                            ok
                    end
                end,
                briskd_state:table_keys(remote_channel)
            ),
            briskd_state_link:relay_except(
                Peer, briskd_wire:line(Prefix, <<"CHGHOST">>, [User, Host], none)
            ),
            ok;
        {error, _, _} ->
            {error, unknown_remote_source};
        _ ->
            {error, invalid_chghost_message}
    end;
receive_remote_chghost(_, _, _) ->
    {error, invalid_chghost_message}.

-doc "`WEBIRC <password> <gateway> <hostname> <ip> [:<options>]`.".
-spec webirc([binary()], #client{}, binary()) -> ok.
webirc(Params, Client, Server) ->
    briskd_v3_multiclient:webirc(Params, Client, Server).

-doc "`ISUPPORT` (draft/extended-isupport): resend the 005 tokens.".
-spec isupport([binary()], #client{}, binary()) -> ok.
isupport(Params, Client, Server) ->
    briskd_v3_multiclient:isupport(Params, Client, Server).

-doc "`STARTTLS` (deprecated IRCv3 `tls` extension).".
-spec starttls(#client{}, binary()) -> ok | starttls.
starttls(Client, Server) ->
    briskd_v3_multiclient:starttls(Client, Server).

-doc "True when `Client` may attach to `HolderClient`'s nickname under `multiclient`.".
-spec attachable(#client{}, #client{}) -> boolean().
attachable(Client, HolderClient) ->
    briskd_v3_multiclient:attachable(Client, HolderClient).

-doc "Prepare this connection to attach to `Holder` once registration completes.".
-spec prepare_attach(#client{}, #client{}, binary()) -> ok.
prepare_attach(Client, Holder, Nick) ->
    briskd_v3_multiclient:prepare_attach(Client, Holder, Nick).

-doc "Finish attaching this connection to `Holder` after the welcome burst.".
-spec finish_attach(#client{}, pid()) -> ok.
finish_attach(Client, Holder) ->
    briskd_v3_multiclient:finish_attach(Client, Holder).

-doc "With `account_rejoin`, remember a logged-in client's channels on disconnect.".
-spec remember_channels(#client{}) -> ok.
remember_channels(Client) ->
    briskd_v3_multiclient:remember_channels(Client).

-doc "With `account_rejoin`, rejoin channels remembered for this account.".
-spec rejoin_on_login(#client{}, binary()) -> ok.
rejoin_on_login(Client, Server) ->
    briskd_v3_multiclient:rejoin_on_login(Client, Server).

-doc "Update any `account_rejoin` entry that lists `OldKey` to `NewName`.".
-spec rename_channel(binary(), binary()) -> ok.
rename_channel(OldKey, NewName) ->
    briskd_v3_multiclient:rename_channel(OldKey, NewName).
