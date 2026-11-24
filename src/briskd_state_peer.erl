-module(briskd_state_peer).
-moduledoc """
Server-link command routing, link-line batch execution, peer authentication,
and peer disconnect/DOWN cleanup (RFC 2813).

Runs inside the `m:briskd_state` process (except `authenticate_server_link/2`
and `peer_command/1`, which are read-only / pure).
""".
-export([
    apply_server_lines/3,
    authenticate_server_link/2,
    burst_command/1,
    disconnect_peer/2,
    handle_server_command/5,
    peer_command/1,
    peer_down/1
]).
-include("briskd_state.hrl").

-doc """
Check an inbound server's name (RFC 1459 folded) and shared password against
the configured `server_links`. Runs in the caller's process.
""".
-spec authenticate_server_link(binary(), binary()) -> boolean().
authenticate_server_link(Name, Password) ->
    Links = persistent_term:get({briskd_state, server_links}, []),
    lists:any(
        fun(#{name := Expected, password := Secret}) ->
            briskd_wire:fold(Name) =:= briskd_wire:fold(Expected) andalso
                briskd_config:secret_match(Password, Secret)
        end,
        Links
    ).

-doc """
Whether a command from an authenticated peer is applied by `m:briskd_state`.
""".
-spec peer_command(binary()) -> boolean().
peer_command(Command) ->
    lists:member(Command, [
        <<"NICK">>,
        <<"QUIT">>,
        <<"AWAY">>,
        <<"NJOIN">>,
        <<"JOIN">>,
        <<"PART">>,
        <<"TOPIC">>,
        <<"KICK">>,
        <<"MODE">>,
        <<"PRIVMSG">>,
        <<"NOTICE">>,
        <<"TAGMSG">>,
        <<"SERVER">>,
        <<"SQUIT">>,
        <<"INVITE">>,
        <<"SERVICE">>,
        <<"SQUERY">>,
        <<"KILL">>,
        <<"ACCOUNT">>,
        <<"SETNAME">>,
        <<"CHGHOST">>,
        <<"REDACT">>,
        <<"ACCOUNTSYNC">>,
        <<"METADATA">>,
        <<"MARKREAD">>,
        <<"E2EE">>,
        <<"CALL">>,
        <<"BATCH">>
    ]).

-doc """
Commands that may appear inside a peer's burst between `NJOIN` lines without
flushing the open `netjoin` batch.
""".
-spec burst_command(binary()) -> boolean().
burst_command(Command) ->
    lists:member(Command, [
        <<"NJOIN">>,
        <<"NICK">>,
        <<"SERVER">>,
        <<"MODE">>,
        <<"SERVICE">>,
        <<"ACCOUNT">>,
        <<"ACCOUNTSYNC">>,
        <<"METADATA">>,
        <<"MARKREAD">>,
        <<"E2EE">>,
        <<"AWAY">>
    ]).

-doc """
Apply consecutive messages from the authenticated peer `Peer` in order until
one returns `{error, Reason}` or the list is exhausted.
""".
-spec apply_server_lines(
    binary(),
    [{undefined | binary(), binary(), [binary()], [{binary(), undefined | binary()}]}],
    binary()
) -> ok | {error, term()}.
apply_server_lines(_Peer, [], _Server) ->
    ok;
apply_server_lines(Peer, [{Prefix, Command, Params, Tags} | Rest], Server) ->
    case handle_server_command(Peer, Prefix, Command, Params, Tags) of
        ok -> apply_server_lines(Peer, Rest, Server);
        Error -> Error
    end.

-doc """
Apply one command received from the authenticated peer `Peer` (RFC 2813).
""".
-spec handle_server_command(
    binary(), undefined | binary(), binary(), [binary()], [{binary(), undefined | binary()}]
) -> ok | {error, term()}.
handle_server_command(Peer, Prefix0, Command, Params, Tags) ->
    case burst_command(Command) of
        true -> ok;
        false -> briskd_state_link:flush_netjoin(Peer)
    end,
    %% RFC 2813 3.3: a line without a prefix comes from the link itself, so
    %% every handler below sees a binary source and never `undefined`.
    Prefix = link_source(Peer, Prefix0),
    briskd_state_send:set_source(briskd_state_v3:remote_source_info(Prefix)),
    %% UTF8ONLY: text from peers reaches local clients only as valid UTF-8;
    %% invalid bytes become U+FFFD.
    Safe =
        case maps:get(utf8_only, briskd_config:current(), false) of
            true -> [briskd_websocket:utf8_safe(P) || P <- Params];
            false -> Params
        end,
    try
        dispatch_tagged(Peer, Prefix, Command, Safe, Tags)
    after
        briskd_state_send:clear_source()
    end.

dispatch_tagged(Peer, Prefix, <<"BATCH">>, Params, Tags) when is_binary(Prefix) ->
    briskd_state_link:receive_remote_batch(Peer, Prefix, Params, Tags);
dispatch_tagged(Peer, Prefix, Command, Params, Tags) when
    is_binary(Prefix),
    (Command =:= <<"PRIVMSG">> orelse Command =:= <<"NOTICE">>),
    is_list(Tags),
    Tags =/= []
->
    case lists:keymember(<<"batch">>, 1, Tags) of
        true -> briskd_state_link:remote_batch_line(Peer, Prefix, Command, Params, Tags);
        false -> dispatch_plain(Peer, Prefix, Command, Params, Tags)
    end;
dispatch_tagged(Peer, Prefix, <<"ACCOUNT">>, Params, _Tags) when is_binary(Prefix) ->
    briskd_state_v3:receive_remote_account(Peer, Prefix, Params);
dispatch_tagged(Peer, Prefix, <<"SETNAME">>, Params, _Tags) when is_binary(Prefix) ->
    briskd_state_v3:receive_remote_setname(Peer, Prefix, Params);
dispatch_tagged(Peer, Prefix, <<"CHGHOST">>, Params, _Tags) when is_binary(Prefix) ->
    briskd_state_v3:receive_remote_chghost(Peer, Prefix, Params);
dispatch_tagged(Peer, Prefix, <<"REDACT">>, Params, _Tags) when is_binary(Prefix) ->
    briskd_state_history:receive_remote_redact(Peer, Prefix, Params);
dispatch_tagged(Peer, Prefix, <<"ACCOUNTSYNC">>, Params, _Tags) ->
    briskd_state_sync:receive_accountsync(Peer, link_source(Peer, Prefix), Params);
dispatch_tagged(Peer, Prefix, <<"METADATA">>, Params, _Tags) when is_binary(Prefix) ->
    briskd_state_sync:receive_metadata(Peer, Prefix, Params);
dispatch_tagged(Peer, Prefix, <<"E2EE">>, Params, Tags) ->
    briskd_e2ee:receive_link(Peer, link_source(Peer, Prefix), Params, Tags);
dispatch_tagged(Peer, Prefix, <<"CALL">>, Params, _Tags) when is_binary(Prefix) ->
    %% Voice-call signalling between users on different servers.
    briskd_calls:receive_link(Peer, Prefix, Params);
dispatch_tagged(Peer, Prefix, <<"MARKREAD">>, Params, _Tags) ->
    briskd_state_sync:receive_markread(Peer, link_source(Peer, Prefix), Params);
dispatch_tagged(Peer, Prefix, Command, Params, Tags) ->
    dispatch_plain(Peer, Prefix, Command, Params, Tags).

dispatch_plain(Peer, Prefix, Command, Params, Tags) when
    is_binary(Prefix),
    (Command =:= <<"PRIVMSG">> orelse Command =:= <<"NOTICE">> orelse Command =:= <<"TAGMSG">>)
->
    briskd_state_link:receive_remote_message(Peer, Prefix, Command, Params, Tags);
dispatch_plain(Peer, Prefix, Command, Params, _Tags) ->
    dispatch_untagged(Peer, Prefix, Command, Params).

dispatch_untagged(Peer, Prefix, <<"NJOIN">>, [Name, Members]) ->
    case briskd_state_link:trusted_server(Peer, link_source(Peer, Prefix)) of
        true -> briskd_state_link:import_remote_njoin(Peer, Name, Members);
        false -> {error, unknown_remote_source}
    end;
dispatch_untagged(Peer, Prefix, <<"JOIN">>, [Name | _]) when is_binary(Prefix) ->
    briskd_state_link:import_remote_join(Peer, Prefix, Name);
dispatch_untagged(Peer, Prefix, <<"PART">>, [Name | Rest]) when is_binary(Prefix) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    briskd_state_link:remove_remote_channel_member(Peer, Prefix, Name, Reason);
dispatch_untagged(Peer, Prefix, <<"TOPIC">>, [Name, Text]) when is_binary(Prefix) ->
    briskd_state_link:update_remote_topic(Peer, Prefix, Name, Text);
dispatch_untagged(Peer, Prefix, <<"KICK">>, [Name, Nick | Rest]) when is_binary(Prefix) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> none
        end,
    briskd_state_link:receive_remote_kick(Peer, Prefix, Name, Nick, Reason);
dispatch_untagged(Peer, Prefix, <<"NICK">>, [Nick]) when is_binary(Prefix) ->
    briskd_state_link:rename_remote_nick(Peer, Prefix, Nick);
dispatch_untagged(Peer, Prefix, <<"QUIT">>, Params) when is_binary(Prefix) ->
    Reason =
        case Params of
            [Text | _] -> Text;
            [] -> <<"QUIT">>
        end,
    briskd_state_link:remove_remote_nick(Peer, Prefix, Reason);
dispatch_untagged(Peer, Prefix, <<"AWAY">>, Params) when is_binary(Prefix) ->
    briskd_state_link:set_remote_away(Peer, Prefix, Params);
dispatch_untagged(Peer, Prefix, <<"NICK">>, Params) when
    is_binary(Prefix), length(Params) =:= 7
->
    briskd_state_link:import_remote_nick(Peer, Prefix, Params);
dispatch_untagged(Peer, Prefix, <<"MODE">>, [Name, Modes | Args]) ->
    briskd_state_link:update_remote_modes(Peer, Prefix, Name, Modes, Args);
dispatch_untagged(Peer, Prefix, <<"SERVER">>, [Name, Hop, Token, Info | _]) ->
    briskd_state_net:introduce_server(Peer, Prefix, Name, Hop, Token, Info);
dispatch_untagged(Peer, _Prefix, <<"SQUIT">>, [Target | Rest]) ->
    Reason =
        case Rest of
            [Text | _] -> Text;
            [] -> <<"SQUIT">>
        end,
    %% A peer may only split itself or a server it introduced (RFC 2813
    %% 4.1.6); any other target would let it remove servers it does not route.
    %% An unknown target is a stale SQUIT that crossed a split and is ignored.
    case behind_peer(Peer, Target) of
        true ->
            %% Close the adjacent socket when the target is that peer. The
            %% pids are captured inside drop_server before the rows go away.
            briskd_state_net:drop_server(Target, Reason, Peer),
            ok;
        unknown ->
            ok;
        false ->
            logger:warning(#{event => squit_rejected, peer => Peer, target => Target}),
            {error, squit_not_behind_peer}
    end;
dispatch_untagged(Peer, Prefix, <<"INVITE">>, [Nick, Name | _]) ->
    briskd_state_link:receive_remote_invite(Peer, Prefix, Nick, Name);
dispatch_untagged(Peer, Prefix, <<"SERVICE">>, Params) ->
    briskd_state_net:import_service(Peer, Prefix, Params);
dispatch_untagged(Peer, Prefix, <<"SQUERY">>, Params) when is_binary(Prefix) ->
    briskd_state_net:remote_squery(Peer, Prefix, Params);
dispatch_untagged(Peer, Prefix, <<"KILL">>, [Nick | Rest]) ->
    Source = link_source(Peer, Prefix),
    %% A server this peer may speak for can KILL. A user can KILL only with
    %% user mode +o, which an honest peer sets from OPER. Any nick on the
    %% link is not enough: that let a non-operator remove local users.
    Operator =
        case briskd_state_link:remote_source(Peer, Source) of
            {ok, #remote_client{modes = Modes}} -> maps:is_key($o, Modes);
            error -> false
        end,
    case briskd_state_link:trusted_server(Peer, Source) orelse Operator of
        true ->
            Reason =
                case Rest of
                    [Text | _] -> Text;
                    [] -> <<"KILL">>
                end,
            briskd_state_link:receive_remote_kill(Peer, Nick, Reason);
        false ->
            case briskd_state_link:remote_source(Peer, Source) of
                {ok, #remote_client{}} -> {error, remote_kill_requires_operator};
                error -> {error, unknown_remote_source}
            end
    end;
dispatch_untagged(_Peer, _Prefix, _Command, _Params) ->
    ok.

%% `true` when Target is the adjacent Peer or a known server reached through
%% it, `false` for the local server or a server routed through another link,
%% and `unknown` for a name that is not a known server.
behind_peer(Peer, Target) ->
    Folded = briskd_wire:fold(Peer),
    Local = briskd_wire:fold(maps:get(name, briskd_config:current())),
    case briskd_wire:fold(Target) of
        Folded ->
            true;
        Local ->
            false;
        Key ->
            case mnesia:dirty_read(known_server, Key) of
                [#known_server{adjacent = Adjacent}] -> briskd_wire:fold(Adjacent) =:= Folded;
                [] -> unknown
            end
    end.

%% A server message without a prefix comes from the link it arrived on
%% (RFC 2813 3.3), so relays name that server as the source.
link_source(Peer, undefined) -> Peer;
link_source(_Peer, Prefix) -> Prefix.

-doc """
Netsplit cleanup when `Caller` still owns a direction of `Peer`.
""".
-spec disconnect_peer(binary(), pid()) -> ok.
disconnect_peer(Peer, Caller) ->
    case briskd_state_net:release_link(Peer, Caller) of
        absent ->
            ok;
        kept ->
            ok;
        split ->
            briskd_state_link:flush_netjoin(Peer),
            briskd_state_link:forget_peer_batches(Peer),
            briskd_state_net:split(Peer, <<"Netsplit ", Peer/binary>>, Peer)
    end.

-doc """
Handle a link process that exited without calling `server_disconnect/1`.
""".
-spec peer_down(pid()) -> ok.
peer_down(Pid) ->
    Peers =
        [Name || {_, {P, Name}} <- ets:tab2list(briskd_inbound_peers), P =:= Pid] ++
            [Name || {_, {P, Name}} <- ets:tab2list(briskd_outbound_ready), P =:= Pid],
    lists:foreach(
        fun(Peer) ->
            logger:warning(#{event => link_process_down, peer => Peer}),
            disconnect_peer(Peer, Pid)
        end,
        Peers
    ).
