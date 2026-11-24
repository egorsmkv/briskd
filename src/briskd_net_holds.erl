-module(briskd_net_holds).
-moduledoc """
Temporary nickname and channel holds (RFC 2811 / RFC 2813 section 5.7) and
`RECLAIM` secret handling.

Holds are stored in the `briskd_holds` ETS table in monotonic seconds and
cleaned up periodically by `expire_holds/0`.
""".
-export([
    channel_blocked/1,
    expire_holds/0,
    hold_channel/1,
    hold_nick/1,
    hold_nick/2,
    nick_blocked/1,
    nick_blocked/2,
    reclaim/3
]).
-include("briskd_client.hrl").

-define(HOLDS, briskd_holds).

-doc """
Hold a nickname lost in a split or collision so it cannot be taken at once
(RFC 2813 section 5.7).

The hold lasts `resource_delay` seconds from the configuration, defaulting
to `briskd_route:resource_delay_seconds/0`; a delay of 0 disables holds. The
deadline is stored in the `briskd_holds` ETS table under the folded name, in
monotonic seconds.
""".
-spec hold_nick(binary()) -> ok.
hold_nick(Nick) ->
    hold(nick, Nick).

-doc """
Hold the nickname a local client gave up (quit, lost connection, or nick
change), like `hold_nick/1`, but owned by that client: a later connection
that presents the same `RECLAIM` secret, or is logged in to the same
account, may take it back at once (`nick_blocked/2`). Everyone else waits
out the delay. This is what lets a WebIRC page reload keep its nickname.
""".
-spec hold_nick(binary(), #client{}) -> ok.
hold_nick(Nick, Client) ->
    hold(nick, Nick, hold_owner(Client)).

%% Who may take back a nickname held for a local client: the hash of its
%% RECLAIM secret, and its account, if logged in. Without either, the hold
%% has no owner.
hold_owner(#client{pid = Pid}) ->
    case {briskd_conn:get(Pid, reclaim), briskd_state_v3:account(Pid)} of
        {undefined, undefined} -> undefined;
        {Token, Account} -> #{token => Token, account => Account}
    end.

-doc """
Handle `RECLAIM <secret>`: remember the SHA-256 of a client-chosen secret
for this connection, so a nickname it later gives up can be taken back by a
connection presenting the same secret (`hold_nick/2`). A server extension
used by WebIRC, which keeps the secret for the browser tab; send it before
`NICK`. The secret is 16 to 64 characters of letters, digits, `-`, and `_`.
A missing secret gets 461; an invalid one `FAIL RECLAIM INVALID_SECRET`.
Success has no reply. The secret is never stored or logged.
""".
-spec reclaim([binary()], #client{}, binary()) -> ok.
reclaim([Secret | _], #client{pid = Pid}, _Server) ->
    case valid_secret(Secret) of
        true ->
            briskd_conn:put(Pid, reclaim, crypto:hash(sha256, Secret));
        false ->
            briskd_state_send:fail(
                Pid, <<"RECLAIM">>, <<"INVALID_SECRET">>, [], <<"Invalid reclaim secret">>
            )
    end;
reclaim([], Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"RECLAIM">>], <<"Not enough parameters">>
    ).

valid_secret(Secret) ->
    byte_size(Secret) >= 16 andalso byte_size(Secret) =< 64 andalso
        lists:all(
            fun(C) ->
                (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
                    (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $_
            end,
            binary_to_list(Secret)
        ).

-doc """
Hold a channel name whose last remote member was lost, under the same rules
as `hold_nick/1` (the RFC 2811 channel delay).
""".
-spec hold_channel(binary()) -> ok.
hold_channel(Name) ->
    hold(channel, Name).

-doc """
True while a hold set by `hold_nick/1` is still in force for `Nick`.

An expired hold found here is deleted.
""".
-spec nick_blocked(binary()) -> boolean().
nick_blocked(Nick) ->
    blocked(nick, Nick).

-doc """
True while `Nick` is held against `Client` (numeric 437). A hold owned by
the same `RECLAIM` secret or account (`hold_nick/2`) does not block
`Client`; it is released instead, so the nickname is theirs again.
""".
-spec nick_blocked(binary(), #client{}) -> boolean().
nick_blocked(Nick, #client{pid = Pid}) ->
    Key = {nick, briskd_wire:fold(Nick)},
    case ets:lookup(?HOLDS, Key) of
        [{_, _Until, #{token := OwnerToken, account := OwnerAccount}}] ->
            Token = briskd_conn:get(Pid, reclaim),
            SameToken =
                is_binary(OwnerToken) andalso is_binary(Token) andalso
                    crypto:hash_equals(OwnerToken, Token),
            Account = briskd_state_v3:account(Pid),
            SameAccount =
                is_binary(OwnerAccount) andalso is_binary(Account) andalso
                    briskd_wire:fold(OwnerAccount) =:= briskd_wire:fold(Account),
            case SameToken orelse SameAccount of
                true ->
                    true = ets:delete(?HOLDS, Key),
                    false;
                false ->
                    blocked(nick, Nick)
            end;
        _ ->
            blocked(nick, Nick)
    end.

-doc """
True while a hold set by `hold_channel/1` is still in force for `Name`.

An expired hold found here is deleted.
""".
-spec channel_blocked(binary()) -> boolean().
channel_blocked(Name) ->
    blocked(channel, Name).

%% `resource_delay` (seconds) overrides the default delay; 0 disables holds.
%% A hold is {{Kind, Folded}, Until} in monotonic seconds, or
%% {{Kind, Folded}, Until, Owner} when a local client owns it (hold/3).
hold(Kind, Name) ->
    hold(Kind, Name, undefined).

hold(Kind, Name, Owner) ->
    Delay = maps:get(
        resource_delay,
        briskd_config:current_or_empty(),
        briskd_route:resource_delay_seconds()
    ),
    case Delay of
        0 ->
            ok;
        _ ->
            Until = erlang:monotonic_time(second) + Delay,
            Key = {Kind, briskd_wire:fold(Name)},
            case Owner of
                undefined -> ets:insert(?HOLDS, {Key, Until});
                _ -> ets:insert(?HOLDS, {Key, Until, Owner})
            end,
            ok
    end.

blocked(Kind, Name) ->
    Key = {Kind, briskd_wire:fold(Name)},
    Now = erlang:monotonic_time(second),
    case ets:lookup(?HOLDS, Key) of
        [Hold] ->
            Until = element(2, Hold),
            case briskd_route:nick_delay_blocked(Key, Now, #{Key => Until}) of
                true ->
                    true;
                false ->
                    true = ets:delete(?HOLDS, Key),
                    false
            end;
        [] ->
            false
    end.

-doc """
Drop nickname and channel holds whose delay has passed.

Called from the state process's one-second tick so that holds nobody asks
about again do not accumulate.
""".
-spec expire_holds() -> ok.
expire_holds() ->
    Now = erlang:monotonic_time(second),
    _ = ets:select_delete(?HOLDS, [
        {{'_', '$1'}, [{'=<', '$1', Now}], [true]},
        {{'_', '$1', '_'}, [{'=<', '$1', Now}], [true]}
    ]),
    ok.
