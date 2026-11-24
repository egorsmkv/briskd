-module(briskd_link_batch).
-moduledoc """
Remote `draft/multiline` batch accumulation, timeout expiry, delivery, and
inter-server forwarding.

Open batches are keyed by peer and reference in the `briskd_peer_batches` ETS
table (with process-dictionary fallback when the table has not been created in
isolated unit tests).
""".
-export([
    expire_peer_batches/0,
    forget_peer_batches/1,
    receive_remote_batch/4,
    remote_batch_line/5
]).
-include("briskd_client.hrl").
-include("briskd_channel.hrl").
-include("briskd_remote.hrl").

%% Open draft/multiline batches kept per peer link.
-define(MAX_PEER_BATCHES, 10).

-doc """
Open or close a `draft/multiline` batch sent by a remote user.

`BATCH +<ref> draft/multiline <target>` opens a batch; the prefix must be a
remote user reached through `Peer`, otherwise the result is
`{error, unknown_remote_source}`. `BATCH -<ref>` closes it and delivers the
collected message to a local nickname or channel members, or forwards it
toward a remote target, never back to `Peer`. Closing an unknown or empty
batch does nothing. Other batch types are `{error, invalid_batch}`. Open
batches are kept per peer and reference in the state process, each bounded by
the multiline line limit. At most 10 batches may be open per peer; opening
another is `{error, too_many_batches}`. `forget_peer_batches/1` discards a
peer's open batches when its link is lost.
""".
-spec receive_remote_batch(binary(), binary(), [binary()], list()) -> ok | {error, term()}.
receive_remote_batch(Peer, Prefix, [<<"+", Ref/binary>>, <<"draft/multiline">>, Target | _], Tags) ->
    Open = peer_batch_refs(Peer),
    Full = length(Open) >= ?MAX_PEER_BATCHES andalso not lists:member(Ref, Open),
    case briskd_state_link:remote_source(Peer, Prefix) of
        {ok, _} when Full ->
            {error, too_many_batches};
        {ok, _} ->
            OpenedAt = erlang:monotonic_time(second),
            Batch = #{
                prefix => Prefix,
                target => briskd_wire:retain(Target),
                tags => briskd_link_msg:trusted_server_tags(Tags) ++ briskd_cap:client_tags(Tags),
                command => undefined,
                lines => [],
                bytes => 0,
                count => 0,
                opened_at => OpenedAt
            },
            put_peer_batch(Peer, briskd_wire:retain(Ref), OpenedAt, Batch),
            ok;
        error ->
            {error, unknown_remote_source}
    end;
receive_remote_batch(Peer, Prefix, [<<"-", Ref/binary>> | _], _Tags) ->
    case take_peer_batch(Peer, Ref) of
        #{prefix := Prefix, command := Command, lines := [_ | _] = Lines} = Batch when
            Command =/= undefined
        ->
            deliver_remote_multiline(Peer, Batch#{lines := lists:reverse(Lines)});
        #{prefix := Prefix} ->
            ok;
        #{} ->
            {error, invalid_batch};
        undefined ->
            ok
    end;
receive_remote_batch(_Peer, _Prefix, _Params, _Tags) ->
    {error, invalid_batch}.

-doc """
Discard every `draft/multiline` batch that `Peer` opened and did not close.

Called when the link to `Peer` is lost, so the state process does not keep
partial batches for a link that is gone.
""".
-spec forget_peer_batches(binary()) -> ok.
forget_peer_batches(Peer) ->
    case ets:whereis(briskd_peer_batches) of
        undefined ->
            lists:foreach(
                fun(Ref) -> erase({briskd_peer_batch, Peer, Ref}) end, peer_batch_refs(Peer)
            );
        _ ->
            _ = ets:select_delete(briskd_peer_batches, [
                {{{batch, Peer, '_'}, '_', '_'}, [], [true]}
            ]),
            ok
    end.

-doc """
Discard any peer `draft/multiline` batch left open for more than 60 seconds.
Called from `m:briskd_state`'s one-second tick.
""".
-spec expire_peer_batches() -> ok.
expire_peer_batches() ->
    Cutoff = erlang:monotonic_time(second) - 60,
    case ets:whereis(briskd_peer_batches) of
        undefined ->
            lists:foreach(
                fun
                    ({briskd_peer_batch, _, _} = Key) ->
                        case get(Key) of
                            #{opened_at := Opened} when Opened =< Cutoff -> erase(Key);
                            _ -> ok
                        end;
                    (_) ->
                        ok
                end,
                get_keys()
            );
        _ ->
            _ = ets:select_delete(briskd_peer_batches, [
                {{{batch, '_', '_'}, '$1', '_'}, [{'=<', '$1', Cutoff}], [true]}
            ]),
            ok
    end.

peer_batch_refs(Peer) ->
    case ets:whereis(briskd_peer_batches) of
        undefined ->
            [Ref || {briskd_peer_batch, P, Ref} <- get_keys(), P =:= Peer];
        _ ->
            ets:select(briskd_peer_batches, [
                {{{batch, Peer, '$1'}, '_', '_'}, [], ['$1']}
            ])
    end.

get_peer_batch(Peer, Ref) ->
    case ets:whereis(briskd_peer_batches) of
        undefined ->
            get({briskd_peer_batch, Peer, Ref});
        _ ->
            case ets:lookup(briskd_peer_batches, {batch, Peer, Ref}) of
                [{_, _OpenedAt, Batch}] -> Batch;
                [] -> undefined
            end
    end.

put_peer_batch(Peer, Ref, OpenedAt, Batch) ->
    case ets:whereis(briskd_peer_batches) of
        undefined ->
            put({briskd_peer_batch, Peer, Ref}, Batch);
        _ ->
            ets:insert(briskd_peer_batches, {{batch, Peer, Ref}, OpenedAt, Batch})
    end,
    ok.

take_peer_batch(Peer, Ref) ->
    case ets:whereis(briskd_peer_batches) of
        undefined ->
            erase({briskd_peer_batch, Peer, Ref});
        _ ->
            case ets:take(briskd_peer_batches, {batch, Peer, Ref}) of
                [{_, _OpenedAt, Batch}] -> Batch;
                [] -> undefined
            end
    end.

erase_peer_batch(Peer, Ref) ->
    case ets:whereis(briskd_peer_batches) of
        undefined -> erase({briskd_peer_batch, Peer, Ref});
        _ -> ets:delete(briskd_peer_batches, {batch, Peer, Ref})
    end,
    ok.

-doc """
Add one `PRIVMSG` or `NOTICE` line to an open peer `draft/multiline` batch.

The line's `batch` tag names the batch, and `Prefix` must match the prefix
that opened it. Returns `{error, unknown_batch}` when no such batch is open,
and `{error, invalid_multiline}` (discarding the batch) when the prefix,
command, or target differs, or the line or byte limit is exceeded.
""".
-spec remote_batch_line(binary(), binary(), binary(), [binary()], list()) -> ok | {error, term()}.
remote_batch_line(Peer, Prefix, Command, [Target, Text | _], Tags) when
    Command =:= <<"PRIVMSG">>; Command =:= <<"NOTICE">>
->
    {_, Ref} = lists:keyfind(<<"batch">>, 1, Tags),
    {MaxBytes, MaxLines} = briskd_cap:multiline_limits(),
    case get_peer_batch(Peer, Ref) of
        #{
            prefix := Prefix,
            target := BatchTarget,
            command := Previous,
            bytes := Bytes,
            count := Count,
            lines := Lines,
            opened_at := OpenedAt
        } = Batch when Count < MaxLines ->
            Concat = lists:keymember(<<"draft/multiline-concat">>, 1, Tags),
            Separator =
                case {Lines, Concat} of
                    {[], _} -> 0;
                    {_, true} -> 0;
                    {_, false} -> 1
                end,
            NewBytes = Bytes + Separator + byte_size(Text),
            SameTarget = briskd_wire:fold(Target) =:= briskd_wire:fold(BatchTarget),
            SameCommand = Previous =:= undefined orelse Previous =:= Command,
            case
                SameTarget andalso SameCommand andalso (not Concat orelse Text =/= <<>>) andalso
                    NewBytes =< MaxBytes
            of
                true ->
                    put_peer_batch(
                        Peer,
                        Ref,
                        OpenedAt,
                        Batch#{
                            command => Command,
                            lines => [{Concat, briskd_wire:retain(Text)} | Lines],
                            bytes => NewBytes,
                            count => Count + 1
                        }
                    ),
                    ok;
                false ->
                    erase_peer_batch(Peer, Ref),
                    {error, invalid_multiline}
            end;
        #{} ->
            erase_peer_batch(Peer, Ref),
            {error, invalid_multiline};
        undefined ->
            {error, unknown_batch}
    end;
remote_batch_line(_Peer, _Prefix, _Command, _Params, _Tags) ->
    {error, invalid_multiline}.

deliver_remote_multiline(
    Peer, #{prefix := Prefix, target := Target, tags := Tags, command := Command, lines := Lines}
) ->
    Body = {multiline, Lines},
    case briskd_state_client:find_nick(Target) of
        #client{pid = Pid, nick = Nick} ->
            briskd_state_batch:deliver_multiline(Pid, Prefix, Command, Nick, Lines, Tags, normal),
            [RemoteNick | _] = binary:split(Prefix, <<"!">>),
            case mnesia:dirty_read(remote_client, briskd_wire:fold(RemoteNick)) of
                [#remote_client{} = Remote] ->
                    briskd_link_msg:note_remote_direct(
                        Remote, Prefix, Command, Nick, Body, Tags, Pid
                    );
                [] ->
                    ok
            end;
        undefined ->
            case briskd_wire:channel(Target) of
                true ->
                    Key = briskd_wire:fold(Target),
                    [Nick | _] = binary:split(Prefix, <<"!">>),
                    NickKey = briskd_wire:fold(Nick),
                    case
                        {
                            mnesia:dirty_read(remote_channel, Key),
                            mnesia:dirty_read(channel, Key),
                            mnesia:dirty_read(remote_client, NickKey)
                        }
                    of
                        {
                            [#remote_channel{members = RM, flags = RF}],
                            [#channel{name = Name, members = LM, flags = LF} = Channel],
                            [#remote_client{} = Remote]
                        } ->
                            case RM of
                                #{NickKey := {Peer, Roles}} ->
                                    Flags = maps:merge(RF, LF),
                                    Banned =
                                        briskd_state_channel:mask_matches(Channel, ban, Remote) andalso
                                            not briskd_state_channel:mask_matches(
                                                Channel, exception, Remote
                                            ),
                                    Allowed =
                                        not maps:is_key($m, Flags) orelse
                                            lists:member(operator, Roles) orelse
                                            lists:member(voice, Roles),
                                    case Allowed andalso not Banned of
                                        true ->
                                            Origin =
                                                case maps:is_key($a, Flags) of
                                                    true -> <<"anonymous!anonymous@anonymous.">>;
                                                    false -> Prefix
                                                end,
                                            lists:foreach(
                                                fun(P) ->
                                                    briskd_state_batch:deliver_multiline(
                                                        P,
                                                        Origin,
                                                        Command,
                                                        Name,
                                                        Lines,
                                                        Tags,
                                                        normal
                                                    )
                                                end,
                                                maps:keys(LM)
                                            ),
                                            MsgId =
                                                case lists:keyfind(<<"msgid">>, 1, Tags) of
                                                    {_, Id} -> Id;
                                                    false -> undefined
                                                end,
                                            Account =
                                                case maps:is_key($a, Flags) of
                                                    true -> undefined;
                                                    false -> Remote#remote_client.account
                                                end,
                                            briskd_state_history:note_channel(
                                                Key,
                                                briskd_state_history:entry(
                                                    Command,
                                                    Origin,
                                                    Body,
                                                    MsgId,
                                                    erlang:system_time(millisecond),
                                                    briskd_cap:client_tags(Tags),
                                                    Account
                                                )
                                            );
                                        false ->
                                            ok
                                    end;
                                #{} ->
                                    ok
                            end;
                        _ ->
                            ok
                    end,
                    forward_lines_channel(
                        Peer,
                        Target,
                        briskd_state_batch:link_lines(Prefix, Command, Target, Body, Tags)
                    );
                false ->
                    case mnesia:dirty_read(remote_client, briskd_wire:fold(Target)) of
                        [#remote_client{peer = Dest}] ->
                            case briskd_route:should_forward(Peer, Dest) of
                                true ->
                                    lists:foreach(
                                        fun(Line) ->
                                            _ = briskd_links:send(Dest, iolist_to_binary(Line))
                                        end,
                                        briskd_state_batch:link_lines(
                                            Prefix, Command, Target, Body, Tags
                                        )
                                    );
                                false ->
                                    ok
                            end;
                        [] ->
                            ok
                    end
            end
    end,
    ok.

forward_lines_channel(Ingress, Name, Lines) ->
    case mnesia:dirty_read(remote_channel, briskd_wire:fold(Name)) of
        [#remote_channel{members = Members}] ->
            Bins = [iolist_to_binary(Line) || Line <- Lines],
            Peers = lists:usort([MemberPeer || _Nick := {MemberPeer, _} <- Members]),
            lists:foreach(
                fun(Dest) ->
                    case briskd_route:should_forward(Ingress, Dest) of
                        true ->
                            lists:foreach(fun(Bin) -> _ = briskd_links:send(Dest, Bin) end, Bins);
                        false ->
                            ok
                    end
                end,
                Peers
            );
        [] ->
            ok
    end.
