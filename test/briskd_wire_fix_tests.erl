-module(briskd_wire_fix_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("briskd/include/briskd_account.hrl").

%% Regression tests for fixes in briskd_wire:message/5 (no tag section without
%% its line), briskd_websocket:decode/2 (RFC 6455 sections 5.2, 5.4, 5.5), and
%% briskd_account:check_password/2 (unknown accounts run the same derivation).

%%% briskd_wire:message/5

message_drops_tags_when_line_is_dropped_test() ->
    Tags = [{<<"time">>, <<"2026-01-01T00:00:00.000Z">>}, {<<"a">>, <<"1">>}],
    Big = binary:copy(<<"x">>, 600),
    %% Middle parameters that cannot fit in 512 octets drop the whole message.
    ?assertEqual([], briskd_wire:line(<<"n!u@h">>, <<"PRIVMSG">>, [Big], none)),
    ?assertEqual([], briskd_wire:message(Tags, <<"n!u@h">>, <<"PRIVMSG">>, [Big], none)),
    ?assertEqual([], briskd_wire:message(Tags, <<"n!u@h">>, <<"PRIVMSG">>, [Big], <<"t">>)),
    ?assertEqual(<<>>, iolist_to_binary(briskd_wire:message(Tags, Big, <<"X">>, [], none))).

message_tag_section_limit_test() ->
    %% "@" + "k=" + Value + " " is the tag section; 8191 bytes is the IRCv3 cap.
    Fits = [{<<"k">>, binary:copy(<<"v">>, 8187)}],
    Line = iolist_to_binary(briskd_wire:message(Fits, <<"srv">>, <<"X">>, [], none)),
    [TagSection, <<":srv X\r\n">>] = binary:split(Line, <<" ">>),
    ?assertEqual(8191, byte_size(TagSection) + 1),
    Over = [{<<"k">>, binary:copy(<<"v">>, 8188)}],
    ?assertEqual([], briskd_wire:message(Over, <<"srv">>, <<"X">>, [], none)),
    %% Escaping counts toward the limit: each ";" is written as two bytes.
    Escaped = [{<<"k">>, binary:copy(<<";">>, 4094)}],
    ?assertEqual([], briskd_wire:message(Escaped, <<"srv">>, <<"X">>, [], none)),
    %% Untagged messages are unchanged.
    ?assertEqual(
        <<":srv X\r\n">>, iolist_to_binary(briskd_wire:message([], <<"srv">>, <<"X">>, [], none))
    ).

%%% briskd_websocket:decode/2

frame(Opcode, Fin, Payload) ->
    Mask = <<16#11, 16#22, 16#33, 16#44>>,
    Len = byte_size(Payload),
    Masked = <<
        <<(B bxor binary:at(Mask, I rem 4))>>
     || {B, I} <- lists:zip(binary_to_list(Payload), lists:seq(0, Len - 1))
    >>,
    true = Len < 126,
    <<Fin:1, 0:3, Opcode:4, 1:1, Len:7, Mask/binary, Masked/binary>>.

ping_between_fragments_is_returned_test() ->
    First = frame(1, 0, <<"PRIV">>),
    Ping = frame(9, 1, <<"hb">>),
    Last = frame(0, 1, <<"MSG x :y">>),
    %% Same read: the ping comes first and the message still completes.
    ?assertEqual(
        {ok, [{ping, <<"hb">>}, {text, <<"PRIVMSG x :y">>}], <<>>},
        briskd_websocket:decode(<<First/binary, Ping/binary, Last/binary>>, 8703)
    ),
    %% Split reads: the ping is returned at once and not repeated later.
    {ok, [{ping, <<"hb">>}], Kept} =
        briskd_websocket:decode(<<First/binary, Ping/binary>>, 8703),
    ?assertEqual(
        {ok, [{text, <<"PRIVMSG x :y">>}], <<>>},
        briskd_websocket:decode(<<Kept/binary, Last/binary>>, 8703)
    ),
    %% A partial frame after the ping stays buffered too.
    Head = binary:part(Last, 0, 3),
    Tail = binary:part(Last, 3, byte_size(Last) - 3),
    {ok, [{ping, <<"hb">>}], Kept2} =
        briskd_websocket:decode(<<First/binary, Ping/binary, Head/binary>>, 8703),
    ?assertEqual(
        {ok, [{text, <<"PRIVMSG x :y">>}], <<>>},
        briskd_websocket:decode(<<Kept2/binary, Tail/binary>>, 8703)
    ).

close_between_fragments_is_returned_test() ->
    Data = <<(frame(2, 0, <<"ab">>))/binary, (frame(8, 1, <<1000:16>>))/binary>>,
    ?assertMatch({ok, [{close, <<1000:16>>}], _}, briskd_websocket:decode(Data, 8703)).

fragmented_control_frame_is_rejected_test() ->
    lists:foreach(
        fun(Opcode) ->
            ?assertEqual(
                {error, fragmented_control},
                briskd_websocket:decode(frame(Opcode, 0, <<"x">>), 8703)
            ),
            Mid = <<(frame(1, 0, <<"a">>))/binary, (frame(Opcode, 0, <<"x">>))/binary>>,
            ?assertEqual({error, fragmented_control}, briskd_websocket:decode(Mid, 8703))
        end,
        [8, 9, 10]
    ).

reserved_opcodes_are_rejected_test() ->
    lists:foreach(
        fun(Opcode) ->
            ?assertEqual(
                {error, bad_opcode}, briskd_websocket:decode(frame(Opcode, 1, <<"x">>), 8703)
            ),
            Mid = <<(frame(1, 0, <<"a">>))/binary, (frame(Opcode, 1, <<"x">>))/binary>>,
            ?assertEqual({error, bad_opcode}, briskd_websocket:decode(Mid, 8703))
        end,
        [3, 4, 5, 6, 7, 11, 12, 13, 14, 15]
    ).

control_payload_limit_test() ->
    ?assertMatch(
        {ok, [{ping, _}], <<>>},
        briskd_websocket:decode(frame(9, 1, binary:copy(<<"p">>, 125)), 8703)
    ),
    %% 126 bytes needs the 16-bit length form.
    Mask = <<0:32>>,
    Big = <<1:1, 0:3, 9:4, 1:1, 126:7, 126:16, Mask/binary, (binary:copy(<<"p">>, 126))/binary>>,
    ?assertEqual({error, control_too_large}, briskd_websocket:decode(Big, 8703)).

%%% briskd_account:check_password/2

unknown_account_runs_the_same_derivation_test_() ->
    {setup, fun start_mnesia/0, fun stop_mnesia/1, fun(_) ->
        ?_test(unknown_account_derivation())
    end}.

unknown_account_derivation() ->
    {ok, #account{iterations = Iterations, salt = Salt}} =
        briskd_account:create(<<"fixacct">>, undefined, <<"password1">>, [], undefined),
    Known = traced_pbkdf2(fun() -> briskd_account:check_password(<<"fixacct">>, <<"wrongpass">>) end),
    Unknown = traced_pbkdf2(fun() ->
        briskd_account:check_password(<<"nosuchacct">>, <<"wrongpass">>)
    end),
    {error, [{sha256, <<"wrongpass">>, Salt, Iterations, 32}]} = Known,
    {error, [{sha256, <<"wrongpass">>, DummySalt, DummyIterations, 32}]} = Unknown,
    %% Same iteration count as a new account and a salt of the same size.
    ?assertEqual(Iterations, DummyIterations),
    ?assertEqual(byte_size(Salt), byte_size(DummySalt)),
    ?assertMatch(
        {ok, _}, briskd_account:check_password(<<"fixacct">>, <<"password1">>)
    ).

%% Run Fun in a fresh process traced by this one and return its result with
%% the crypto:pbkdf2_hmac/5 calls it made.
traced_pbkdf2(Fun) ->
    MFA = {crypto, pbkdf2_hmac, 5},
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        receive
            go -> Parent ! {self(), Fun()}
        end
    end),
    1 = erlang:trace(Pid, true, [call]),
    _ = erlang:trace_pattern(MFA, true, [global]),
    try
        Pid ! go,
        Result =
            receive
                {Pid, Value} -> Value
            end,
        receive
            {'DOWN', Mon, process, Pid, _} -> ok
        end,
        Ref = erlang:trace_delivered(Pid),
        receive
            {trace_delivered, _, Ref} -> ok
        end,
        {Result, collect_calls()}
    after
        erlang:trace_pattern(MFA, false, [global])
    end.

collect_calls() ->
    receive
        {trace, _, call, {crypto, pbkdf2_hmac, [Digest, Password, Salt, Iterations, Len]}} ->
            [{Digest, Password, Salt, Iterations, Len} | collect_calls()]
    after 0 -> []
    end.

start_mnesia() ->
    case lists:keymember(mnesia, 1, application:which_applications()) of
        true ->
            ok = ensure_table(),
            running;
        false ->
            ok = mnesia:start(),
            ok = ensure_table(),
            started
    end.

ensure_table() ->
    case
        mnesia:create_table(account, [
            {attributes, record_info(fields, account)}, {ram_copies, [node()]}
        ])
    of
        {atomic, ok} -> ok;
        {aborted, {already_exists, account}} -> ok
    end,
    ok = mnesia:wait_for_tables([account], 5000),
    _ = mnesia:dirty_delete(account, briskd_wire:fold(<<"fixacct">>)),
    ok.

stop_mnesia(running) ->
    _ = mnesia:dirty_delete(account, briskd_wire:fold(<<"fixacct">>)),
    ok;
stop_mnesia(started) ->
    _ = mnesia:delete_table(account),
    stopped = mnesia:stop(),
    ok.
