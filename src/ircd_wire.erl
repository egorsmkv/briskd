-module(ircd_wire).
-export([
    append_pending/2,
    channel/1,
    fold/1,
    line/4,
    message/5,
    nickname/1,
    nickname/2,
    parse/1,
    parse_client/1,
    parse_server/1,
    partial/1,
    retain/1,
    retain_fields/1,
    safe_channel/1
]).

-include("ircd_wire.hrl").

%% @doc Append one socket delivery to the unfinished line, or reject an oversized buffer.
-spec append_pending(binary(), binary()) -> {ok, binary()} | error.
append_pending(Buffer, Packet) when
    is_binary(Buffer),
    is_binary(Packet),
    byte_size(Buffer) + byte_size(Packet) =< ?MAX_PENDING_BYTES
->
    {ok, <<Buffer/binary, Packet/binary>>};
append_pending(Buffer, Packet) when is_binary(Buffer), is_binary(Packet) ->
    error.

%% @doc Parse one untagged client line into a command and binary parameters.
%% A client prefix or message tags make the line `error`. Oversized untagged
%% lines are `error`. Use parse_client/1 when tags are in scope.
-spec parse(binary()) -> {ok, binary(), [binary()]} | empty | error.
parse(Packet) ->
    case parse_client(Packet) of
        {ok, [], Command, Params} -> {ok, Command, Params};
        {ok, _Tags, _Command, _Params} -> error;
        {error, input_too_long, _Tags} -> error;
        Other -> Other
    end.

%% @doc Parse a client line, including IRCv3 message tags.
%% `{error, input_too_long, Tags}' means numeric 417: the tag data exceeds
%% 4094 bytes, the tag section exceeds 8191 bytes, or the command part exceeds
%% 512 octets. The command must not be processed. A client-supplied prefix is
%% `error`.
-spec parse_client(binary()) ->
    {ok, [{binary(), undefined | binary()}], binary(), [binary()]}
    | {error, input_too_long, [{binary(), undefined | binary()}]}
    | empty
    | error.
parse_client(Packet) ->
    case frame(Packet) of
        {ok, _Tags, <<$:, _/binary>>} ->
            error;
        {ok, Tags, Body} ->
            case parse_command(Body) of
                {ok, Command, Params} -> {ok, Tags, Command, Params};
                Other -> Other
            end;
        {error, input_too_long, Tags} ->
            {error, input_too_long, Tags};
        error ->
            error
    end.

%% @doc Parse a server-link line, retaining tags and an optional source prefix.
%% An over-long tagged line is `error` here. Client sessions map that case to
%% numeric 417 themselves.
-spec parse_server(binary()) ->
    {ok, [{binary(), undefined | binary()}], undefined | binary(), binary(), [binary()]}
    | empty
    | error.
parse_server(Packet) ->
    case frame(Packet) of
        {ok, Tags, Body} ->
            case parse_server_command(Body) of
                {ok, Prefix, Command, Params} -> {ok, Tags, Prefix, Command, Params};
                Other -> Other
            end;
        {error, input_too_long, _Tags} ->
            error;
        error ->
            error
    end.

%% @doc Accept a partial line that can still grow into one valid IRC message.
-spec partial(binary()) -> ok | error.
partial(Data) when is_binary(Data), byte_size(Data) < ?MAX_WIRE_LINE ->
    case {binary:match(Data, <<"\n">>), binary:match(Data, <<"\r">>)} of
        {nomatch, nomatch} -> ok;
        {nomatch, {Offset, 1}} when Offset =:= byte_size(Data) - 1 -> ok;
        _ -> error
    end;
partial(Data) when is_binary(Data) ->
    error.

frame(Packet) when is_binary(Packet), byte_size(Packet) >= 2, byte_size(Packet) =< ?MAX_WIRE_LINE ->
    Size = byte_size(Packet) - 2,
    case Packet of
        <<Body:Size/binary, "\r\n">> ->
            case binary:match(Body, [<<0>>, <<"\r">>, <<"\n">>]) of
                nomatch -> split_tags(Body);
                _ -> error
            end;
        _ ->
            error
    end;
frame(_) ->
    error.

split_tags(<<$@, _/binary>> = Body) ->
    case binary:split(Body, <<" ">>) of
        [TagBin, Rest] ->
            TagData = byte_size(TagBin) - 1,
            TagSection = byte_size(TagBin) + 1,
            Tags = decode_tags(binary:part(TagBin, 1, TagData)),
            case TagData > 4094 orelse TagSection > 8191 orelse byte_size(Rest) + 2 > 512 of
                true -> {error, input_too_long, Tags};
                false -> {ok, Tags, Rest}
            end;
        _ ->
            TagData = byte_size(Body) - 1,
            case TagData > 4094 orelse byte_size(Body) + 1 > 8191 of
                true -> {error, input_too_long, []};
                false -> error
            end
    end;
split_tags(Body) ->
    case byte_size(Body) + 2 > 512 of
        %% A complete line over 512 octets is answered with 417 on a client
        %% socket; parse/1 and parse_server/1 still treat it as an error.
        true -> {error, input_too_long, []};
        false -> {ok, [], Body}
    end.

%% Last value wins and the first occurrence keeps its position. A map avoids
%% scanning the accumulated list once per tag.
decode_tags(Bin) ->
    {Order, Values} = lists:foldl(
        fun(Part, {Keys, Map}) ->
            case tag_pair(Part) of
                {<<>>, _} ->
                    {Keys, Map};
                {Key, Value} ->
                    case maps:is_key(Key, Map) of
                        true -> {Keys, Map#{Key => Value}};
                        false -> {[Key | Keys], Map#{Key => Value}}
                    end
            end
        end,
        {[], #{}},
        binary:split(Bin, <<";">>, [global])
    ),
    [{Key, map_get(Key, Values)} || Key <- lists:reverse(Order)].

tag_pair(<<>>) ->
    {<<>>, undefined};
tag_pair(Part) ->
    case binary:split(Part, <<"=">>) of
        [Key] ->
            {Key, undefined};
        [Key, Raw] ->
            case unescape(Raw) of
                <<>> -> {Key, undefined};
                Value -> {Key, Value}
            end
    end.

unescape(Bin) ->
    unescape(Bin, <<>>).

unescape(<<>>, Acc) ->
    Acc;
unescape(<<$\\>>, Acc) ->
    Acc;
unescape(<<$\\, $:, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, $;>>);
unescape(<<$\\, $s, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, " ">>);
unescape(<<$\\, $\\, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, $\\>>);
unescape(<<$\\, $r, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, $\r>>);
unescape(<<$\\, $n, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, $\n>>);
unescape(<<$\\, Other, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, Other>>);
unescape(<<Char, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, Char>>).

encode_tags([]) ->
    <<>>;
encode_tags(Tags) ->
    [<<"@">>, lists:join(<<";">>, [encode_tag(Tag) || Tag <- Tags]), <<" ">>].

encode_tag({Key, undefined}) ->
    Key;
encode_tag({Key, Value}) ->
    [Key, <<"=">>, escape(Value)].

escape(Bin) ->
    escape(Bin, <<>>).

escape(<<>>, Acc) ->
    Acc;
escape(<<$;, Rest/binary>>, Acc) ->
    escape(Rest, <<Acc/binary, "\\:">>);
escape(<<$\s, Rest/binary>>, Acc) ->
    escape(Rest, <<Acc/binary, "\\s">>);
escape(<<$\\, Rest/binary>>, Acc) ->
    escape(Rest, <<Acc/binary, "\\\\">>);
escape(<<$\r, Rest/binary>>, Acc) ->
    escape(Rest, <<Acc/binary, "\\r">>);
escape(<<$\n, Rest/binary>>, Acc) ->
    escape(Rest, <<Acc/binary, "\\n">>);
escape(<<Char, Rest/binary>>, Acc) ->
    escape(Rest, <<Acc/binary, Char>>).

parse_server_command(<<$:, Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [<<>>, _] ->
            error;
        [_Prefix, <<>>] ->
            error;
        [Prefix, CommandLine] ->
            case parse_command(CommandLine) of
                {ok, Command, Params} -> {ok, Prefix, Command, Params};
                Other -> Other
            end
    end;
parse_server_command(Body) ->
    case parse_command(Body) of
        {ok, Command, Params} -> {ok, undefined, Command, Params};
        Other -> Other
    end.

parse_command(<<>>) ->
    empty;
%% RFC 1459 commands are letters or a three-digit numeric. Other word-like
%% tokens (letters, digits, `_`, `.`, `-`) still parse so the server can
%% answer 421 ERR_UNKNOWNCOMMAND instead of closing the connection.
parse_command(Body) ->
    [Command | Rest] = binary:split(Body, <<" ">>),
    case re:run(Command, <<"^[A-Za-z0-9_.-]{1,64}$">>, [{capture, none}]) of
        match -> params(Rest, string:uppercase(Command), []);
        nomatch -> error
    end.

params([], Command, Acc) ->
    {ok, Command, lists:reverse(Acc)};
params([<<>>], Command, Acc) ->
    params([], Command, Acc);
params([<<" ", Rest/binary>>], Command, Acc) ->
    params([Rest], Command, Acc);
params([<<":", Rest/binary>>], Command, Acc) when length(Acc) < 15 ->
    params([], Command, [Rest | Acc]);
params([Rest], Command, Acc) when length(Acc) =:= 14 ->
    params([], Command, [Rest | Acc]);
params([Rest], Command, Acc) when length(Acc) < 14 ->
    [Param | Tail] = binary:split(Rest, <<" ">>),
    params(Tail, Command, [Param | Acc]);
params(_, _, _) ->
    error.

%% @doc Encode an IRC message with optional IRCv3 tags in front of the 512-octet line.
%% An empty tag list is the classic line. Tags are not truncated.
-spec message(
    [{binary(), undefined | binary()}], iodata(), iodata(), [iodata()], none | iodata()
) ->
    iolist().
message([], Prefix, Command, Middle, Trailing) ->
    line(Prefix, Command, Middle, Trailing);
message(Tags, Prefix, Command, Middle, Trailing) ->
    [encode_tags(Tags), line(Prefix, Command, Middle, Trailing)].

%% @doc Encode an IRC message, enforcing the protocol's 512-byte line limit.
-spec line(iodata(), iodata(), [iodata()], none | iodata()) -> iolist().
line(Prefix, Command, Middle, Trailing) ->
    Head = iolist_to_binary([
        <<":">>,
        Prefix,
        <<" ">>,
        Command,
        [[<<" ">>, Item] || Item <- Middle]
    ]),
    case {byte_size(Head), Trailing} of
        {Size, none} when Size =< 510 -> [Head, <<"\r\n">>];
        {Size, Tail} when Size =< 508 ->
            Bytes = iolist_to_binary(Tail),
            [
                Head,
                <<" :">>,
                binary:part(Bytes, 0, min(508 - Size, byte_size(Bytes))),
                <<"\r\n">>
            ];
        _ ->
            []
    end.

%% @doc Copy a binary that will outlive the socket buffer it was sliced from.
%% Other terms are returned unchanged. Short-lived relay text should not be copied.
%% @doc Copy every top-level binary field of a record (or other tuple), so a
%% row built from a parsed peer line does not keep the receive buffer alive.
%% Nested maps and lists are left as they are; copy those at insertion.
-spec retain_fields(T) -> T when T :: tuple().
retain_fields(Record) when is_tuple(Record) ->
    list_to_tuple([retain(Field) || Field <- tuple_to_list(Record)]).

-spec retain(term()) -> term().
retain(Value) when is_binary(Value) -> binary:copy(Value);
retain(Value) -> Value.

%% @doc Fold an IRC identifier according to the RFC1459 case mapping.
-spec fold(binary()) -> binary().
fold(Value) -> <<<<(lower(C))>> || <<C>> <= Value>>.
lower(C) when C >= $A, C =< $Z -> C + 32;
lower($[) -> ${;
lower($]) -> $};
lower(92) -> $|;
lower($^) -> $~;
lower(C) -> C.

%% @doc Check whether a nickname uses the server's supported RFC character set.
-spec nickname(binary()) -> boolean().
nickname(Nick) ->
    nickname(Nick, 9).

%% @doc Like nickname/1 with an operator-configured maximum length (`nicklen`).
%% RFC 1459 sets 9; the character set is the same at any length.
-spec nickname(binary(), pos_integer()) -> boolean().
nickname(Nick, Max) when is_binary(Nick), byte_size(Nick) =< Max ->
    re:run(
        Nick,
        <<"^[A-Za-z\\x5b-\\x60\\x7b-\\x7d][A-Za-z0-9\\x5b-\\x60\\x7b-\\x7d-]*$">>,
        [{capture, none}, dollar_endonly]
    ) =:= match;
nickname(_Nick, _Max) ->
    false.

%% @doc Validate a regular or safe channel name accepted by this server.
-spec channel(binary()) -> boolean().
channel(<<Type, Rest/binary>>) when Type =:= $#; Type =:= $&; Type =:= $+ ->
    byte_size(Rest) > 0 andalso byte_size(Rest) < 50 andalso
        binary:match(Rest, [<<0>>, <<7>>, <<" ">>, <<",">>, <<":">>]) =:= nomatch;
channel(<<$!, _/binary>> = Name) ->
    safe_channel(Name);
channel(_) ->
    false.

%% @doc Validate the server-generated identifier and short name in a safe channel.
-spec safe_channel(binary()) -> boolean().
safe_channel(<<$!, Id:5/binary, Short/binary>>) when
    byte_size(Short) > 0,
    byte_size(Short) =< 44
->
    safe_id(Id) andalso binary:match(Short, [<<0>>, <<7>>, <<" ">>, <<",">>, <<":">>]) =:= nomatch;
safe_channel(_) ->
    false.

safe_id(<<>>) ->
    true;
safe_id(<<Char, Rest/binary>>) ->
    (Char >= $A andalso Char =< $Z orelse Char >= $1 andalso Char =< $9 orelse Char =:= $0) andalso
        safe_id(Rest).
