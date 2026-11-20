-module(ircd_stdlib_fix_tests).
-moduledoc """
Regression tests for helpers replaced by OTP standard-library calls and for
the crash fixes found alongside them (invalid UTF-8 reaching `string`
functions inside `ircd_state` or request handlers).
""".
-include_lib("eunit/include/eunit.hrl").

ascii_lower_test() ->
    ?assertEqual(<<"content-type">>, ircd_wire:lower(<<"Content-Type">>)),
    %% Non-ASCII bytes, including invalid UTF-8, pass through unchanged.
    ?assertEqual(<<"x", 255, 16#C3, 16#84>>, ircd_wire:lower(<<"X", 255, 16#C3, 16#84>>)),
    %% Not the IRC fold: brackets are left alone.
    ?assertEqual(<<"[a]">>, ircd_wire:lower(<<"[A]">>)),
    ?assertEqual(<<"{a}">>, ircd_wire:fold(<<"[A]">>)).

trim_ows_test() ->
    ?assertEqual(<<"a b">>, ircd_websocket:trim_ows(<<" \ta b\t ">>)),
    ?assertEqual(<<>>, ircd_websocket:trim_ows(<<"  ">>)),
    ?assertEqual(<<>>, ircd_websocket:trim_ows(<<>>)),
    ?assertEqual(<<255>>, ircd_websocket:trim_ows(<<" ", 255, " ">>)).

%% `inet:ntoa/1` leaves a leading zero group uncompressed for these; the old
%% `0:` stripping turned them into invalid text and skipped the DNSBL check.
dronebl_peer_test() ->
    lists:foreach(
        fun(IP) ->
            Text = ircd_wire:ip_text(IP),
            ?assertEqual({ok, IP}, ircd_dronebl:parse_peer(Text)),
            ?assertEqual({ok, IP}, ircd_dronebl:parse_peer(IP))
        end,
        [{0, 1, 0, 0, 0, 0, 0, 0}, {0, 1, 2, 3, 4, 5, 6, 7}, {0, 0, 1, 0, 0, 0, 0, 1}]
    ),
    ?assertEqual(error, ircd_dronebl:parse_peer({256, 0, 0, 1})),
    ?assertEqual(error, ircd_dronebl:parse_peer({0, 0, 0, 0, 0, 0, 0, 65536})),
    ?assertEqual(error, ircd_dronebl:parse_peer({0, 0, 0, 0, 0, 0, 0, -1})).

email_key_test() ->
    ?assertEqual(<<"a@b.example">>, ircd_account:email_key(<<"  A@B.Example ">>)),
    %% Invalid UTF-8 (stored before REGISTER checked it) must not raise.
    ?assertEqual(<<"a", 255, "@b.c">>, ircd_account:email_key(<<"a", 255, "@b.c">>)).

valid_decimal_test() ->
    ?assert(ircd_route:valid_decimal(<<"0">>)),
    ?assert(ircd_route:valid_decimal(<<"12">>)),
    ?assertNot(ircd_route:valid_decimal(<<"-1">>)),
    ?assertNot(ircd_route:valid_decimal(<<"x">>)),
    ?assertNot(ircd_route:valid_decimal(<<>>)),
    ?assertNot(ircd_route:valid_decimal(undefined)).

log_level_test() ->
    ?assertEqual({ok, trace}, ircd_config:parse_log_level(<<"trace">>)),
    ?assertEqual({ok, emergency}, ircd_config:parse_log_level(<<"emergency">>)),
    ?assertEqual(error, ircd_config:parse_log_level(<<"loud">>)),
    ?assertEqual(error, ircd_config:parse_log_level(info)).

%% Masked frames of every tail length decode to the original payload.
websocket_unmask_test() ->
    Mask = <<1, 2, 3, 250>>,
    lists:foreach(
        fun(Len) ->
            Payload = crypto:strong_rand_bytes(Len),
            Masked = crypto:exor(
                Payload, binary:part(binary:copy(Mask, Len div 4 + 1), 0, Len)
            ),
            Frame = <<1:1, 0:3, 2:4, 1:1, Len:7, Mask/binary, Masked/binary>>,
            ?assertMatch({ok, [{binary, Payload}], <<>>}, decode_all(Frame))
        end,
        lists:seq(0, 13)
    ).

decode_all(Frame) ->
    ircd_websocket:decode(Frame, 1 bsl 20).
