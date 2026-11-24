-module(briskd_v3_multiclient).
-moduledoc """
`WEBIRC`, `ISUPPORT`, deprecated `STARTTLS`, `multiclient` session attachment,
and `account_rejoin` channel memory.
""".
-export([
    attachable/2,
    finish_attach/2,
    isupport/3,
    prepare_attach/3,
    rejoin_on_login/2,
    remember_channels/1,
    rename_channel/2,
    starttls/2,
    webirc/3
]).
-include("briskd_client.hrl").
-include("briskd_channel.hrl").

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
            not maps:get(webirc, briskd_cap:info(Pid), false) andalso
            maps:get(version, briskd_cap:state(Pid)) =:= 0 andalso
            map_size(maps:get(enabled, briskd_cap:state(Pid))) =:= 0,
    Gateways = maps:get(webirc, briskd_config:current(), []),
    Trusted =
        case inet:parse_address(binary_to_list(GatewayHost)) of
            {ok, Address} ->
                lists:any(
                    fun(#{password := Secret, hosts := Hosts}) ->
                        lists:member(Address, Hosts) andalso
                            briskd_config:secret_match(Password, Secret)
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
                case briskd_state_v3:valid_host(Hostname) of
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
                    maps:get(secure, briskd_cap:info(Pid), false),
            mnesia:dirty_write(Client#client{host = briskd_wire:retain(Host)}),
            briskd_cap:set_info(Pid, webirc, true),
            briskd_cap:set_info(Pid, secure, Secure),
            %% The gateway's own TLS certificate is not the user's identity.
            %% A `certfp-sha-256=` option from a secure gateway is.
            briskd_cap:set_info(Pid, certfp, webirc_certfp(Options, Secure)),
            briskd_cap:set_info(Pid, ip, briskd_wire:retain(SafeIp)),
            logger:info(#{event => webirc_accepted, gateway => GatewayHost, host => Host}),
            ok;
        _ ->
            logger:warning(#{event => webirc_rejected, gateway => GatewayHost}),
            %% The session sends ERROR and closes; its DOWN removes the client.
            Pid !
                {irc_close,
                    briskd_wire:line(Server, <<"ERROR">>, [], <<"Invalid WebIRC password">>)},
            ok
    end;
webirc(_, Client, Server) ->
    briskd_state_send:numeric(
        Client, Server, <<"461">>, [<<"WEBIRC">>], <<"Not enough parameters">>
    ).

webirc_certfp(_Options, false) ->
    undefined;
webirc_certfp(Options, true) ->
    case [V || <<"certfp-sha-256=", V/binary>> <- Options] of
        [Fp | _] when byte_size(Fp) =:= 64 ->
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
        briskd_state_client:ready(Client) orelse
            briskd_cap:enabled(Pid, <<"draft/extended-isupport">>)
    of
        true ->
            briskd_isupport:send(Client, Server, briskd_isupport:tokens());
        false ->
            briskd_state_send:numeric(Client, Server, <<"451">>, [], <<"You have not registered">>)
    end.

-doc """
`STARTTLS` (deprecated IRCv3 `tls` extension). Allowed once, before
registration, on a plaintext TCP connection when TLS is configured.
""".
-spec starttls(#client{}, binary()) -> ok | starttls.
starttls(#client{pid = Pid} = Client, Server) ->
    Info = briskd_cap:info(Pid),
    Configured = maps:get(tls_options, briskd_config:current(), []) =/= [],
    case
        Configured andalso maps:get(transport, Info, undefined) =:= tcp andalso
            not maps:get(secure, Info, false) andalso not briskd_state_client:ready(Client)
    of
        true ->
            briskd_state_send:numeric(
                Client, Server, <<"670">>, [], <<"STARTTLS successful, proceed with TLS handshake">>
            ),
            starttls;
        false ->
            briskd_state_send:numeric(Client, Server, <<"691">>, [], <<"STARTTLS failed">>)
    end.

%%% multiclient and account rejoin (opt-in operator features)

-doc """
True when, with `multiclient` enabled, the unregistered `Client` is logged
in to the same account (RFC 1459 folded) as the registered `Holder`, so it
may attach to that client's nickname instead of getting 433.
""".
-spec attachable(#client{}, #client{}) -> boolean().
attachable(#client{pid = Pid} = Client, #client{pid = Holder} = HolderClient) ->
    Config = briskd_config:current(),
    Account = briskd_state_v3:account(Pid),
    maps:get(multiclient, Config, false) andalso Account =/= undefined andalso
        not briskd_state_client:ready(Client) andalso briskd_state_client:ready(HolderClient) andalso
        briskd_wire:fold(Account) =:=
            briskd_wire:fold(fold_or_empty(briskd_state_v3:account(Holder))).

fold_or_empty(undefined) -> <<>>;
fold_or_empty(Value) -> Value.

-doc """
Take the nickname for this connection without indexing it; the
connection attaches to `Holder` once its registration completes.
""".
-spec prepare_attach(#client{}, #client{}, binary()) -> ok.
prepare_attach(#client{pid = Pid} = Client, #client{pid = Holder}, Nick) ->
    briskd_conn:put(Pid, attach_to, Holder),
    mnesia:dirty_write(Client#client{nick = briskd_wire:retain(Nick)}),
    ok.

-doc """
Finish an attach after the welcome burst: route this connection's
commands to `Holder`, drop its own client, activity, user mode, capability,
and `m:briskd_conn` records, and send `{attached_session, Pid}` to the
holder and `{attach, Holder}` to the connection.
""".
-spec finish_attach(#client{}, pid()) -> ok.
finish_attach(#client{pid = Pid, nick = Nick}, Holder) ->
    ets:insert(briskd_attached, {Pid, Holder}),
    logger:info(#{event => session_attached, nick => Nick}),
    mnesia:dirty_delete(client, Pid),
    mnesia:dirty_delete(activity, Pid),
    mnesia:dirty_delete(user_modes, Pid),
    briskd_population:on_client_disconnect(Pid),
    briskd_cap:disconnect(Pid),
    briskd_conn:delete(Pid),
    ok = briskd_flood:disconnect(Pid),
    briskd_state_client:remove_connection_stats(Pid),
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
    case {maps:get(account_rejoin, briskd_config:current(), false), briskd_state_v3:account(Pid)} of
        {true, Account} when is_binary(Account), Keys =/= [] ->
            Names = [
                Name
             || Key <- Keys, [#channel{name = Name}] <- [mnesia:dirty_read(channel, Key)]
            ],
            ets:insert(briskd_account_channels, {briskd_wire:fold(Account), Names}),
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
    case briskd_state_v3:account(Pid) of
        undefined ->
            ok;
        Account ->
            case ets:take(briskd_account_channels, briskd_wire:fold(Account)) of
                [{_, Names}] -> briskd_state_channel:join_channels(Names, [], Pid, Server);
                [] -> ok
            end
    end.

-doc """
Update any `account_rejoin` entry that lists `OldKey` to use the renamed
channel `NewName`.
""".
-spec rename_channel(binary(), binary()) -> ok.
rename_channel(OldKey, NewName) ->
    case ets:whereis(briskd_account_channels) of
        undefined ->
            ok;
        _ ->
            Kept = briskd_wire:retain(NewName),
            lists:foreach(
                fun({Account, Names}) ->
                    Updated = [
                        case briskd_wire:fold(N) =:= OldKey of
                            true -> Kept;
                            false -> N
                        end
                     || N <- Names
                    ],
                    case Updated =:= Names of
                        true -> ok;
                        false -> ets:insert(briskd_account_channels, {Account, Updated})
                    end
                end,
                ets:tab2list(briskd_account_channels)
            )
    end.
