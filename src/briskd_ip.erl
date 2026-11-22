-module(briskd_ip).
-moduledoc """
CIDR membership for `inet` address tuples.

Prefix lengths count bits from the top of the address: 0..32 for IPv4 and
0..128 for IPv6. An address of the other family does not match.
""".

-export([any/2, in_cidr/2]).

-export_type([cidr/0]).

-doc """
One network. The tuple is the first address of the network, and the integer
is the prefix length.
""".
-type cidr() :: {inet:ip4_address(), 0..32} | {inet:ip6_address(), 0..128}.

-doc """
Return `true` when `IP` is inside any network in `Cidrs`.
""".
-spec any(inet:ip_address(), [cidr()]) -> boolean().
any(IP, Cidrs) ->
    lists:any(fun(Cidr) -> in_cidr(IP, Cidr) end, Cidrs).

-doc """
Return `true` when `IP` is inside `CIDR`. A family mismatch, or a prefix
outside 0..32 for IPv4 and 0..128 for IPv6, is `false`.
""".
-spec in_cidr(inet:ip_address(), cidr()) -> boolean().
in_cidr({A, B, C, D}, {{W, X, Y, Z}, Prefix}) when is_integer(Prefix), Prefix >= 0, Prefix =< 32 ->
    ip4_int({A, B, C, D}) bsr (32 - Prefix) =:= ip4_int({W, X, Y, Z}) bsr (32 - Prefix);
in_cidr({A, B, C, D, E, F, G, H}, {{N1, N2, N3, N4, N5, N6, N7, N8}, Prefix}) when
    is_integer(Prefix), Prefix >= 0, Prefix =< 128
->
    ip6_int({A, B, C, D, E, F, G, H}) bsr (128 - Prefix) =:=
        ip6_int({N1, N2, N3, N4, N5, N6, N7, N8}) bsr (128 - Prefix);
in_cidr(_, _) ->
    false.

ip4_int({A, B, C, D}) ->
    (A bsl 24) bor (B bsl 16) bor (C bsl 8) bor D.

ip6_int({A, B, C, D, E, F, G, H}) ->
    (A bsl 112) bor (B bsl 96) bor (C bsl 80) bor (D bsl 64) bor (E bsl 48) bor (F bsl 32) bor
        (G bsl 16) bor H.
