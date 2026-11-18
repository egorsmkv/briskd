-module(ircd_wire_tests).
-include_lib("eunit/include/eunit.hrl").

append_pending_joins_a_partial_line_test() ->
    ?assertEqual({ok, <<"NICK">>}, ircd_wire:append_pending(<<"NI">>, <<"CK">>)).

append_pending_accepts_the_buffer_ceiling_test() ->
    Packet = binary:copy(<<$a>>, 1048576),
    ?assertEqual({ok, Packet}, ircd_wire:append_pending(<<>>, Packet)).

append_pending_rejects_oversized_input_test() ->
    Packet = binary:copy(<<$a>>, 1048577),
    ?assertEqual(error, ircd_wire:append_pending(<<>>, Packet)).
