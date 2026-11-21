-module(briskd_wire_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("briskd/include/briskd_wire.hrl").

append_pending_joins_a_partial_line_test() ->
    ?assertEqual({ok, <<"NICK">>}, briskd_wire:append_pending(<<"NI">>, <<"CK">>)).

append_pending_accepts_the_buffer_ceiling_test() ->
    Packet = binary:copy(<<$a>>, ?MAX_PENDING_BYTES),
    ?assertEqual({ok, Packet}, briskd_wire:append_pending(<<>>, Packet)).

append_pending_rejects_oversized_input_test() ->
    Packet = binary:copy(<<$a>>, ?MAX_PENDING_BYTES + 1),
    ?assertEqual(error, briskd_wire:append_pending(<<>>, Packet)).

tag_escape_round_trip_test() ->
    Value = <<"raw+:=,escaped; \\">>,
    Line = iolist_to_binary(
        briskd_wire:message(
            [{<<"+draft">>, Value}], <<"n!u@h">>, <<"PRIVMSG">>, [<<"#a">>], <<"x">>
        )
    ),
    ?assert(has(Line, <<"@+draft=raw+:=,escaped\\:\\s\\\\ ">>)),
    ?assertMatch(
        {ok, [{<<"+draft">>, Value}], <<"n!u@h">>, <<"PRIVMSG">>, [<<"#a">>, <<"x">>]},
        briskd_wire:parse_server(Line)
    ),
    {ok, [{<<"+demo">>, <<"a;b">>}], <<"PRIVMSG">>, _} =
        briskd_wire:parse_client(<<"@+demo=a\\:b PRIVMSG #a :hi\r\n">>),
    Again = iolist_to_binary(
        briskd_wire:message(
            [{<<"+demo">>, <<"a;b">>}], <<"n!u@h">>, <<"PRIVMSG">>, [<<"#a">>], <<"hi">>
        )
    ),
    ?assert(has(Again, <<"@+demo=a\\:b ">>)).

tag_last_key_and_empty_value_test() ->
    {ok, Tags, <<"PRIVMSG">>, _} =
        briskd_wire:parse_client(<<"@k=1;+a=1;+b;+a=2;+b=;k=2;=drop PRIVMSG #a :z\r\n">>),
    ?assertEqual(
        [{<<"k">>, <<"2">>}, {<<"+a">>, <<"2">>}, {<<"+b">>, undefined}], Tags
    ),
    {ok, [{<<"+a">>, undefined}], _, _} =
        briskd_wire:parse_client(<<"@+a= PRIVMSG #a :z\r\n">>),
    {ok, [{<<"+a">>, undefined}], _, _} =
        briskd_wire:parse_client(<<"@+a PRIVMSG #a :z\r\n">>),
    Encoded = iolist_to_binary(
        briskd_wire:message(
            [{<<"+a">>, undefined}], <<"n!u@h">>, <<"PRIVMSG">>, [<<"#a">>], <<"z">>
        )
    ),
    ?assert(has(Encoded, <<"@+a ">>)),
    ?assertNot(has(Encoded, <<"@+a=">>)),
    {ok, [{<<"+a">>, <<"b">>}], _, _} =
        briskd_wire:parse_client(<<"@+a=b\\ PRIVMSG #a :z\r\n">>),
    {ok, [{<<"+a">>, <<"b">>}], _, _} =
        briskd_wire:parse_client(<<"@+a=\\b PRIVMSG #a :z\r\n">>),
    ?assertEqual(
        [{<<"+a">>, <<"2">>}, {<<"+b">>, undefined}], briskd_cap:client_tags(Tags)
    ).

tag_prefix_and_size_test() ->
    ?assertEqual(error, briskd_wire:parse_client(<<":evil PRIVMSG #a :z\r\n">>)),
    ?assertEqual(error, briskd_wire:parse_client(<<"@+a=1 :evil PRIVMSG #a :z\r\n">>)),
    ?assertEqual(error, briskd_wire:parse(<<"@+a=1 PRIVMSG #a :z\r\n">>)),
    ?assertEqual(error, briskd_wire:parse_client(<<"PRIVMSG #a :a\0b\r\n">>)),
    OkText = binary:copy(<<"m">>, 498),
    Ok = <<"PRIVMSG #a :", OkText/binary, "\r\n">>,
    ?assertEqual(512, byte_size(Ok)),
    ?assertMatch({ok, <<"PRIVMSG">>, [<<"#a">>, OkText]}, briskd_wire:parse(Ok)),
    BadText = binary:copy(<<"m">>, 499),
    Bad = <<"PRIVMSG #a :", BadText/binary, "\r\n">>,
    ?assertEqual(error, briskd_wire:parse(Bad)),
    ?assertEqual({error, input_too_long, []}, briskd_wire:parse_client(Bad)),
    Tagged = <<"@+a=b PRIVMSG #a :", BadText/binary, "\r\n">>,
    ?assertMatch(
        {error, input_too_long, [{<<"+a">>, <<"b">>}]}, briskd_wire:parse_client(Tagged)
    ),
    Within = binary:copy(<<"k">>, ?MAX_TAG_DATA),
    Over = binary:copy(<<"k">>, ?MAX_TAG_DATA + 1),
    ?assertMatch(
        {ok, [{Within, undefined}], <<"PRIVMSG">>, [<<"#a">>, <<"z">>]},
        briskd_wire:parse_client(<<"@", Within/binary, " PRIVMSG #a :z\r\n">>)
    ),
    ?assertMatch(
        {error, input_too_long, [{Over, undefined}]},
        briskd_wire:parse_client(<<"@", Over/binary, " PRIVMSG #a :z\r\n">>)
    ),
    ?assertMatch(
        {error, input_too_long, []},
        briskd_wire:parse_client(<<$@, Over/binary, "\r\n">>)
    ).

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.
