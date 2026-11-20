-module(ircd_wire).
-moduledoc """
Pure IRC wire codec: line framing, parsing, encoding, IRCv3 message tags,
and the RFC 1459 case mapping.

This module makes no process calls and keeps no state. `m:ircd_session` and
`m:ircd_link` own the sockets: they buffer unterminated input with
`append_pending/2` and `partial/1`, and pass each complete line to
`parse_client/1` (client sockets) or `parse_server/1` (server links). Replies
and relayed messages are built with `line/4` and `message/5`.

Wire limits and grammar:

- An untagged line is at most 512 octets including the trailing CR LF
  (RFC 1459 section 2.3, RFC 2812 section 2.3). NUL, a bare CR, or a bare LF
  inside a line makes it malformed.
- The IRCv3 message-tags specification allows at most 4094 bytes of tag data
  and a tag section (`@`, the tags, and the separating space) of at most 8191
  bytes in front of that 512-octet message. The absolute size of one line is
  `MAX_WIRE_LINE` (8703 octets) in `include/ircd_wire.hrl`, and buffered input
  without a line end is capped at `MAX_PENDING_BYTES` (1 MiB).
- A command is a letter run or a three-digit numeric. Other word-like tokens
  of up to 64 characters (letters, digits, `_`, `.`, `-`) also parse, so the
  server can answer 421 instead of closing the connection. Commands are
  returned upper-cased.
- At most 15 parameters. A `:` introduces the trailing parameter, which may
  contain spaces. After 14 middle parameters the rest of the line is the 15th
  parameter even without a `:`, as in the RFC 2812 grammar.

Parsers return `{ok, ...}` for a well-formed line, `empty` for a line with no
command, and `error` for malformed input. `parse_client/1` also returns
`{error, input_too_long, Tags}` so the session can answer numeric 417.

Identities (nicknames, channel names, masks) are compared after `fold/1`,
the RFC 1459 case mapping.
""".
-export([
    append_pending/2,
    channel/1,
    fold/1,
    ip_text/1,
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
    lower/1,
    safe_channel/1,
    upper/1
]).

-include("ircd_wire.hrl").

%% IRCv3 message-tags: the tag section (`@`, the tags, and the separating
%% space) of a server-sent line is at most 8191 bytes.
-define(MAX_TAG_SECTION, 8191).

-doc """
Append one socket read to the buffered input that has no line end yet.

`Buffer` holds the bytes kept from earlier reads after the last CR LF, and
`Packet` is the new read. Returns `{ok, Combined}` while the total stays within
`MAX_PENDING_BYTES` (1 MiB, `include/ircd_wire.hrl`) and `error` otherwise; the
caller then closes the connection. The per-line limit is enforced separately by
`partial/1` and the parsers.
""".
-spec append_pending(binary(), binary()) -> {ok, binary()} | error.
append_pending(Buffer, Packet) when
    is_binary(Buffer),
    is_binary(Packet),
    byte_size(Buffer) + byte_size(Packet) =< ?MAX_PENDING_BYTES
->
    {ok, <<Buffer/binary, Packet/binary>>};
append_pending(Buffer, Packet) when is_binary(Buffer), is_binary(Packet) ->
    error.

-doc """
Parse one untagged client line into `{ok, Command, Params}`.

`Packet` is one complete line ending in CR LF. Returns `empty` for a line with
no command and `error` for malformed input, including a client-supplied prefix,
any message tags, and a line over 512 octets. This is the strict RFC 1459 and
RFC 2812 form; client sessions use `parse_client/1`, which accepts IRCv3 tags
and reports over-long lines separately.

```erlang
1> ircd_wire:parse(<<"JOIN #a key\r\n">>).
{ok,<<"JOIN">>,[<<"#a">>,<<"key">>]}
2> ircd_wire:parse(<<"@a=1 PING x\r\n">>).
error
```
""".
-spec parse(binary()) -> {ok, binary(), [binary()]} | empty | error.
parse(Packet) ->
    case parse_client(Packet) of
        {ok, [], Command, Params} -> {ok, Command, Params};
        {ok, _Tags, _Command, _Params} -> error;
        {error, input_too_long, _Tags} -> error;
        Other -> Other
    end.

-doc """
Parse one client line, including an optional IRCv3 message-tag section.

`Packet` is one complete line ending in CR LF. Results:

- `{ok, Tags, Command, Params}`: `Command` is upper-cased. `Tags` lists
  `{Key, Value}` pairs in first-seen order with escaped values decoded; a
  missing or empty value is `undefined`, and the last value wins for a
  repeated key.
- `{error, input_too_long, Tags}`: the tag data exceeds 4094 bytes, the tag
  section exceeds 8191 bytes, or the message after the tags exceeds 512 octets
  including CR LF. The caller answers numeric 417 (`ERR_INPUTTOOLONG`) and must
  not run the command.
- `empty`: the line holds no command.
- `error`: malformed input, including a source prefix (a client may not name
  its own source), NUL, a bare CR or LF, a missing CR LF, or more than
  `MAX_WIRE_LINE` octets.

```erlang
1> ircd_wire:parse_client(<<"privmsg #chan :hello world\r\n">>).
{ok,[],<<"PRIVMSG">>,[<<"#chan">>,<<"hello world">>]}
2> ircd_wire:parse_client(<<"@label=1 PING tok\r\n">>).
{ok,[{<<"label">>,<<"1">>}],<<"PING">>,[<<"tok">>]}
3> ircd_wire:parse_client(<<":nick PRIVMSG #c :hi\r\n">>).
error
4> ircd_wire:parse_client(<<"\r\n">>).
empty
```
""".
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

-doc """
Parse one server-link line into `{ok, Tags, Prefix, Command, Params}`.

Unlike `parse_client/1`, an optional `:prefix` naming the source is accepted
and returned as `Prefix`, or `undefined` when absent (RFC 2813 section 3.3).
The caller must still check that the peer may speak for that source. Tags are
decoded as in `parse_client/1`. Returns `empty` for a line with no command and
`error` for malformed input, an empty prefix, a prefix with no command, or any
over-long line; a server link has no 417 reply.

```erlang
1> ircd_wire:parse_server(<<":irc.example NICK bob 1\r\n">>).
{ok,[],<<"irc.example">>,<<"NICK">>,[<<"bob">>,<<"1">>]}
```
""".
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

-doc """
Check that unterminated input can still grow into one valid line.

`Data` is the buffered bytes after the last CR LF. Returns `ok` when it is
shorter than `MAX_WIRE_LINE` octets, contains no LF, and contains no CR except
as its last byte (a CR LF split across two reads). Returns `error` otherwise;
`m:ircd_session` then answers 417 for an over-long tagged client line and
closes the connection in the other cases.
""".
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

-doc """
Encode one IRC message with an optional IRCv3 tag section in front of it.

`Tags` is a list of `{Key, Value}` pairs. `undefined` writes the key alone, and
values are escaped as the message-tags specification requires (`;`, space,
`\`, CR, LF). With `[]` the result is exactly `line/4`. The part after the tags
follows `line/4`, including its 512-octet limit. The tag section is never
truncated: when it would exceed 8191 bytes (`@`, the tags, and the separating
space, the IRCv3 message-tags limit), or when `line/4` drops the message, the
result is `[]` and nothing should be sent, so a tag section is never written
without its message. Per-recipient tag filtering happens in
`m:ircd_state_send`.

```erlang
1> Tags = [{<<"time">>, <<"2026-01-01T00:00:00.000Z">>}].
[{<<"time">>,<<"2026-01-01T00:00:00.000Z">>}]
2> iolist_to_binary(ircd_wire:message(Tags, <<"n!u@h">>, <<"PRIVMSG">>, [<<"#c">>], <<"hi">>)).
<<"@time=2026-01-01T00:00:00.000Z :n!u@h PRIVMSG #c :hi\r\n">>
3> ircd_wire:message(Tags, <<"n!u@h">>, <<"PRIVMSG">>, [binary:copy(<<"x">>, 600)], none).
[]
```
""".
-spec message(
    [{binary(), undefined | binary()}], iodata(), iodata(), [iodata()], none | iodata()
) ->
    iolist().
message([], Prefix, Command, Middle, Trailing) ->
    line(Prefix, Command, Middle, Trailing);
message(Tags, Prefix, Command, Middle, Trailing) ->
    TagSection = iolist_to_binary(encode_tags(Tags)),
    case line(Prefix, Command, Middle, Trailing) of
        [] -> [];
        _ when byte_size(TagSection) > ?MAX_TAG_SECTION -> [];
        Line -> [TagSection, Line]
    end.

-doc """
Encode one prefixed IRC line within the 512-octet limit (RFC 2812 section 2.3).

The result is `:Prefix Command Middle...`, then ` :Trailing` unless `Trailing`
is `none`, then CR LF. `Middle` parameters are written as given, so they must
not contain spaces or start with `:`. A trailing parameter that does not fit is
cut so the whole line, CR LF included, is at most 512 octets; the cut counts
bytes and can split a UTF-8 sequence. When the prefix, command, and middle
parameters alone do not fit (over 510 octets, or 508 with a trailing
parameter), the result is `[]` and nothing should be sent: one logical message
is never split across lines.

```erlang
1> iolist_to_binary(ircd_wire:line(<<"irc.local">>, <<"001">>, [<<"alice">>], <<"Welcome">>)).
<<":irc.local 001 alice :Welcome\r\n">>
2> iolist_to_binary(ircd_wire:line(<<"irc.local">>, <<"PING">>, [<<"tok">>], none)).
<<":irc.local PING tok\r\n">>
```
""".
-spec line(iodata(), iodata(), [iodata()], none | iodata()) -> iolist().
line(Prefix, Command, Middle, Trailing) ->
    Head = iolist_to_binary([
        <<":">>,
        Prefix,
        <<" ">>,
        Command,
        [[<<" ">>, Item] || Item <- Middle]
    ]),
    Size = byte_size(Head),
    case Trailing of
        none when Size =< 510 ->
            [Head, <<"\r\n">>];
        none ->
            [];
        Tail when Size =< 508 ->
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

-doc """
Apply `retain/1` to every top-level field of a record or other tuple.

Use it on a row built from a parsed peer line before it is stored, so the row
does not keep the receive buffer alive. Nested maps and lists are left as they
are; copy those at insertion.
""".
-spec retain_fields(T) -> T when T :: tuple().
retain_fields(Record) when is_tuple(Record) ->
    list_to_tuple([retain(Field) || Field <- tuple_to_list(Record)]).

-doc """
The text form of an IP address, as a binary.

```erlang
1> ircd_wire:ip_text({127, 0, 0, 1}).
<<"127.0.0.1">>
2> ircd_wire:ip_text({0, 0, 0, 0, 0, 0, 0, 1}).
<<"::1">>
```
""".
-spec ip_text(inet:ip_address()) -> binary().
ip_text(IP) ->
    case inet:ntoa(IP) of
        Text when is_list(Text) -> list_to_binary(Text);
        {error, einval} -> erlang:error({badarg, IP})
    end.

-doc """
Copy `Value` if it is a binary, so it no longer references a larger buffer.

A sub-binary sliced from a socket read keeps the whole read alive. Copy at a
long-lived ownership boundary, such as a Mnesia or ETS insert. Any other term
is returned unchanged. Short-lived relay text should not be copied.
""".
-spec retain(T) -> T.
%% binary:copy/1 of a binary is a binary, so the result has the type of Value;
%% eqWAlizer cannot relate the two.
% elp:ignore W0074 (generic identity over binaries)
% eqwalizer:ignore incompatible_types
retain(Value) when is_binary(Value) -> binary:copy(Value);
retain(Value) -> Value.

-doc """
Fold an identifier with the RFC 1459 case mapping (RFC 1459 section 2.2).

ASCII `A`-`Z` become `a`-`z`, and `[`, `]`, `\`, `^` become `{`, `}`, `|`,
`~`. Other bytes, including non-ASCII ones, are unchanged. Stored nickname,
channel, and mask identities are compared in this form; replies keep the wire
spelling.

```erlang
1> ircd_wire:fold(<<"Nick[1]^">>).
<<"nick{1}~">>
```
""".
-spec fold(binary()) -> binary().
fold(Value) -> <<<<(fold_byte(C))>> || <<C>> <= Value>>.
fold_byte(C) when C >= $A, C =< $Z -> C + 32;
fold_byte($[) -> ${;
fold_byte($]) -> $};
fold_byte(92) -> $|;
fold_byte($^) -> $~;
fold_byte(C) -> C.

-doc """
Upper-case ASCII letters `a`-`z`; every other byte is unchanged.

Use it for command words and subcommands from the wire. Unlike
`string:uppercase/1`, it accepts any bytes: `string:uppercase/1` raises
`badarg` on invalid UTF-8, which in `m:ircd_state` would take down the state
process.

```erlang
1> ircd_wire:upper(<<"hangup", 255>>).
<<"HANGUP", 255>>
```
""".
-spec upper(binary()) -> binary().
upper(Value) -> <<<<(upper_byte(C))>> || <<C>> <= Value>>.
upper_byte(C) when C >= $a, C =< $z -> C - 32;
upper_byte(C) -> C.

-doc """
Lower-case ASCII letters `A`-`Z`; every other byte is unchanged.

The counterpart of `upper/1` for case-insensitive ASCII tokens from the
network, such as HTTP header names (RFC 9110 section 5.1). It is not the IRC
identity fold: use `fold/1` for nicknames and channels.

```erlang
1> ircd_wire:lower(<<"Content-Type", 255>>).
<<"content-type", 255>>
```
""".
-spec lower(binary()) -> binary().
lower(Value) -> <<<<(lower_byte(C))>> || <<C>> <= Value>>.
lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.

-doc """
Check a nickname with the RFC 1459 length limit of 9 octets.

Same as `nickname(Nick, 9)`; see `nickname/2` for the character set.

```erlang
1> ircd_wire:nickname(<<"[bot]">>).
true
2> ircd_wire:nickname(<<"9lives">>).
false
3> ircd_wire:nickname(<<"averylongnick">>).
false
```
""".
-spec nickname(binary()) -> boolean().
nickname(Nick) ->
    nickname(Nick, 9).

-doc """
Check a nickname's syntax with a maximum length of `Max` octets.

The first character is a letter or one of the RFC 2812 special characters
`[`, `]`, `\`, `` ` ``, `_`, `^`, `{`, `|`, `}` (RFC 2812 section 2.3.1).
Later characters may also be digits or `-`. `Max` is the configured `nicklen`
(9 to 30, default 9); RFC 1459 sets 9, and the character set is the same at any
length. Anything else, including an empty nickname, is `false`.

```erlang
1> ircd_wire:nickname(<<"averylongnick">>, 30).
true
```
""".
-spec nickname(binary(), pos_integer()) -> boolean().
nickname(Nick, Max) when is_binary(Nick), byte_size(Nick) =< Max ->
    re:run(
        Nick,
        <<"^[A-Za-z\\x5b-\\x60\\x7b-\\x7d][A-Za-z0-9\\x5b-\\x60\\x7b-\\x7d-]*$">>,
        [{capture, none}, dollar_endonly]
    ) =:= match;
nickname(_Nick, _Max) ->
    false.

-doc """
Check that a channel name is valid on this server (RFC 2811 section 2.1).

`#` (network-wide), `&` (local), and `+` (modeless) names take 1 to 49
octets after the prefix, so at most 50 in total, and must not contain NUL,
BEL (Ctrl-G), space, comma, or colon. Names starting with `!` are safe
channels and are checked by `safe_channel/1`. Case is not checked; compare
names with `fold/1`.

```erlang
1> ircd_wire:channel(<<"#erlang">>).
true
2> ircd_wire:channel(<<"#a,b">>).
false
3> ircd_wire:channel(<<"!ABC12chat">>).
true
```
""".
-spec channel(binary()) -> boolean().
channel(<<Type, Rest/binary>>) when Type =:= $#; Type =:= $&; Type =:= $+ ->
    byte_size(Rest) > 0 andalso byte_size(Rest) < 50 andalso
        binary:match(Rest, [<<0>>, <<7>>, <<" ">>, <<",">>, <<":">>]) =:= nomatch;
channel(<<$!, _/binary>> = Name) ->
    safe_channel(Name);
channel(_) ->
    false.

-doc """
Check a safe channel name (RFC 2811 section 3.2).

The name is `!`, a five-character channel id of `A`-`Z` and `0`-`9`, and a
short name of 1 to 44 octets with the same forbidden characters as
`channel/1`, so the whole name is at most 50 octets. This checks syntax only;
whether the id belongs to an existing channel is decided by the caller.

```erlang
1> ircd_wire:safe_channel(<<"!abc12chat">>).
false
```
""".
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
