-module(briskd_bencode).
-moduledoc """
Bencode encoding and decoding for the rtpengine NG control protocol
(`m:briskd_calls`).

Encoding accepts maps (keys are atoms or binaries, written in sorted byte
order as bencode requires), lists, binaries, atoms (written as strings), and
integers. Decoding returns maps with binary keys, lists, binaries, and
integers. Decoding is bounded: nesting deeper than 16 levels, a string longer
than the remaining input, or trailing bytes return `error` rather than
raising, since NG replies arrive over UDP.
""".
-export([encode/1, decode/1]).

-define(MAX_DEPTH, 16).

-type value() :: integer() | binary() | atom() | [value()] | #{atom() | binary() => value()}.
-export_type([value/0]).

-doc "Encode a term as bencode iodata.".
-spec encode(value()) -> iolist().
encode(Int) when is_integer(Int) ->
    [$i, integer_to_binary(Int), $e];
encode(Bin) when is_binary(Bin) ->
    [integer_to_binary(byte_size(Bin)), $:, Bin];
encode(Atom) when is_atom(Atom) ->
    encode(atom_to_binary(Atom));
encode(List) when is_list(List) ->
    [$l, [encode(V) || V <- List], $e];
encode(Map) when is_map(Map) ->
    Pairs = lists:sort([{key(K), V} || K := V <- Map]),
    [$d, [[encode(K), encode(V)] || {K, V} <- Pairs], $e].

key(K) when is_atom(K) -> atom_to_binary(K);
key(K) when is_binary(K) -> K.

-doc "Decode one complete bencoded value. Returns `error` for malformed input.".
-spec decode(binary()) -> {ok, value()} | error.
decode(Bin) when is_binary(Bin) ->
    case value(Bin, 0) of
        {ok, Value, <<>>} -> {ok, Value};
        _ -> error
    end.

value(_, Depth) when Depth > ?MAX_DEPTH ->
    error;
value(<<$i, Rest/binary>>, _) ->
    case binary:split(Rest, <<"e">>) of
        [Digits, Tail] ->
            try binary_to_integer(Digits) of
                Int -> {ok, Int, Tail}
            catch
                error:badarg -> error
            end;
        _ ->
            error
    end;
value(<<$l, Rest/binary>>, Depth) ->
    list(Rest, Depth + 1, []);
value(<<$d, Rest/binary>>, Depth) ->
    dict(Rest, Depth + 1, #{});
value(<<C, _/binary>> = Bin, _) when C >= $0, C =< $9 ->
    case binary:split(Bin, <<":">>) of
        [LenBin, Tail] when byte_size(LenBin) =< 9 ->
            try binary_to_integer(LenBin) of
                Len when Len >= 0, Len =< byte_size(Tail) ->
                    <<Str:Len/binary, More/binary>> = Tail,
                    {ok, Str, More};
                _ ->
                    error
            catch
                error:badarg -> error
            end;
        _ ->
            error
    end;
value(_, _) ->
    error.

list(<<$e, Rest/binary>>, _, Acc) ->
    {ok, lists:reverse(Acc), Rest};
list(Bin, Depth, Acc) ->
    case value(Bin, Depth) of
        {ok, V, Rest} -> list(Rest, Depth, [V | Acc]);
        error -> error
    end.

dict(<<$e, Rest/binary>>, _, Acc) ->
    {ok, Acc, Rest};
dict(Bin, Depth, Acc) ->
    case value(Bin, Depth) of
        {ok, K, Rest} when is_binary(K) ->
            case value(Rest, Depth) of
                {ok, V, Rest1} -> dict(Rest1, Depth, Acc#{K => V});
                error -> error
            end;
        _ ->
            error
    end.
