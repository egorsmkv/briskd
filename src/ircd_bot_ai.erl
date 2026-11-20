-module(ircd_bot_ai).
-moduledoc """
Pure helpers for AI assistant bots (`m:ircd_bot`): deciding whether a message
addresses the bot, building an OpenAI-compatible `chat/completions` request,
reading the reply, and turning reply text into IRC message lines.

Nothing here performs IO except the HTTP call, `complete/3` (or
`request/3`), which a bot runs in a short-lived worker process.

Some models reject parameters other OpenAI-compatible providers accept: newer
OpenAI models refuse `max_tokens` (they take `max_completion_tokens`) and any
`temperature` but the default. When a provider answers HTTP 400 with a
structured error naming one of those parameters (`error.param` with
`error.code` `unsupported_parameter` or `unsupported_value`), `complete/3`
adapts the request and retries, at most once per parameter, and returns the
adaptations so the bot can send the right request first next time.

Reply lines respect the RFC 1459 512-octet line limit: each chunk is sized so
the line the server delivers (`:nick!user@host PRIVMSG target :text` plus
CRLF) stays within 512 octets, and splits never cut a UTF-8 sequence.
""".
-export([
    addressed/2,
    build_request/5,
    parse_reply/1,
    reply_lines/3,
    text_budget/4,
    clean_input/1,
    clean_reply/2,
    complete/3,
    request/3
]).

%% A request change a provider asked for: send `max_completion_tokens` in
%% place of `max_tokens`, or leave `temperature` at the provider default.
-type adaptation() :: max_completion_tokens | default_temperature.
%% What complete/3 builds the request from.
-type request() :: #{
    settings := #{model := binary(), max_tokens := pos_integer(), temperature := number()},
    system := binary(),
    context := binary(),
    turns := [{user | assistant, binary()}],
    question := binary(),
    adapt := [adaptation()]
}.
-export_type([adaptation/0, request/0]).

%% Largest provider reply body read, in bytes.
-define(MAX_RESPONSE_BYTES, 1048576).
%% Longest single message forwarded to the provider, in bytes.
-define(MAX_INPUT_BYTES, 2000).
%% Bytes kept free in each line for anything the server adds to the prefix.
-define(LINE_SLACK, 16).

-doc """
Decide whether `Text` addresses the bot named `Nick`.

A message addresses the bot when it starts with the nickname followed by
`:` or `,` (the usual IRC convention, e.g. `helper: hi`), or when it
contains `@nick` as a word. Comparison uses the RFC 1459 case mapping
(`ircd_wire:fold/1`). Returns `{true, Question}` with the addressing prefix
removed, or `false`.
""".
-spec addressed(binary(), binary()) -> {true, binary()} | false.
addressed(Nick, Text) ->
    Folded = ircd_wire:fold(Text),
    FoldedNick = ircd_wire:fold(Nick),
    Size = byte_size(FoldedNick),
    case Folded of
        <<FoldedNick:Size/binary, Sep, _/binary>> when Sep =:= $:; Sep =:= $, ->
            {true, trim(binary:part(Text, Size + 1, byte_size(Text) - Size - 1))};
        _ ->
            case at_mention(Folded, <<"@", FoldedNick/binary>>) of
                true -> {true, trim(Text)};
                false -> false
            end
    end.

at_mention(Folded, Needle) ->
    lists:any(
        fun({Pos, Len}) ->
            before_ok(Folded, Pos) andalso after_ok(Folded, Pos + Len)
        end,
        binary:matches(Folded, Needle)
    ).

before_ok(_Bin, 0) -> true;
before_ok(Bin, Pos) -> not word_char(binary:at(Bin, Pos - 1)).

after_ok(Bin, Pos) when Pos >= byte_size(Bin) -> true;
after_ok(Bin, Pos) -> not word_char(binary:at(Bin, Pos)).

%% Nickname characters (RFC 2812 2.3.1) count as part of a word.
word_char(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse lists:member(C, "-_[]\\`^{}|").

-doc """
Prepare a user message for the provider: strip IRC formatting and other C0
control characters, replace invalid UTF-8, and cap it at 2000 bytes.
""".
-spec clean_input(binary()) -> binary().
clean_input(Text) ->
    Valid = valid_utf8(Text),
    Stripped = <<<<C>> || <<C>> <= Valid, C >= 32 orelse C =:= $\t>>,
    utf8_prefix(trim(Stripped), ?MAX_INPUT_BYTES).

-doc """
Prepare a model reply for conversation memory: like `clean_input/1`, but
line breaks are kept and the cap is `Max` bytes.
""".
-spec clean_reply(binary(), pos_integer()) -> binary().
clean_reply(Text, Max) ->
    Valid = valid_utf8(Text),
    Stripped = <<<<C>> || <<C>> <= Valid, C >= 32 orelse C =:= $\t orelse C =:= $\n>>,
    iolist_to_binary(string:trim(utf8_prefix(Stripped, Max), both, " \t\n")).

-doc """
Build the JSON body of a `chat/completions` request.

`Settings` holds `model`, `max_tokens`, and `temperature`, and may hold
`adapt`, the `t:adaptation/0` list a provider asked for. `System` is the
operator's system prompt and `Context` a short description of where the bot
is speaking. `Turns` are earlier exchanges, oldest first, as
`{user | assistant, Content}`.
""".
-spec build_request(map(), binary(), binary(), [{user | assistant, binary()}], binary()) ->
    binary().
build_request(Settings, System, Context, Turns, Question) ->
    Adapt = maps:get(adapt, Settings, []),
    Messages =
        [#{role => <<"system">>, content => System} || System =/= <<>>] ++
            [#{role => <<"system">>, content => Context}] ++
            [#{role => atom_to_binary(Role), content => Content} || {Role, Content} <- Turns] ++
            [#{role => <<"user">>, content => Question}],
    TokenKey =
        case lists:member(max_completion_tokens, Adapt) of
            true -> max_completion_tokens;
            false -> max_tokens
        end,
    Base = #{
        model => maps:get(model, Settings),
        messages => Messages,
        TokenKey => maps:get(max_tokens, Settings)
    },
    Request =
        case lists:member(default_temperature, Adapt) of
            true -> Base;
            false -> Base#{temperature => maps:get(temperature, Settings)}
        end,
    iolist_to_binary(json:encode(Request)).

-doc """
Read the assistant text from a `chat/completions` response body:
`choices[0].message.content`. Returns `{error, Reason}` for malformed JSON,
an `error` object, or an empty reply.
""".
-spec parse_reply(binary()) -> {ok, binary()} | {error, term()}.
parse_reply(Body) ->
    try json:decode(Body) of
        #{<<"choices">> := [#{<<"message">> := #{<<"content">> := Content}} | _]} when
            is_binary(Content)
        ->
            case trim(Content) of
                <<>> -> {error, empty_reply};
                Text -> {ok, Text}
            end;
        #{<<"error">> := #{<<"message">> := Message}} when is_binary(Message) ->
            {error, {provider_error, utf8_prefix(Message, 200)}};
        _ ->
            {error, unexpected_response}
    catch
        error:_ -> {error, invalid_json}
    end.

%% The structured parts of an OpenAI-style error body: `message` (at most 200
%% bytes), `code` and `param` (at most 64 bytes each), and `adapt` when the
%% error names a parameter complete/3 can adapt.
-spec provider_error(binary()) ->
    #{message => binary(), code => binary(), param => binary(), adapt => adaptation()}.
provider_error(Body) ->
    try json:decode(Body) of
        #{<<"error">> := #{} = Error} ->
            Fields = maps:from_list(
                [
                    {Key, utf8_prefix(Value, Max)}
                 || {Key, Name, Max} <- [
                        {message, <<"message">>, 200},
                        {code, <<"code">>, 64},
                        {param, <<"param">>, 64}
                    ],
                    Value <- [maps:get(Name, Error, undefined)],
                    is_binary(Value)
                ]
            ),
            case adaptation(Fields) of
                {ok, Adapt} -> Fields#{adapt => Adapt};
                none -> Fields
            end;
        _ ->
            #{}
    catch
        error:_ -> #{}
    end.

adaptation(#{code := Code, param := Param}) when
    Code =:= <<"unsupported_parameter">>; Code =:= <<"unsupported_value">>
->
    case Param of
        <<"max_tokens">> -> {ok, max_completion_tokens};
        <<"temperature">> -> {ok, default_temperature};
        _ -> none
    end;
adaptation(_) ->
    none.

-doc """
Bytes of message text that fit in one delivered line from `Nick!User@Host`
to `Target`: 510 octets of content minus the prefix, command, target, and a
small safety margin.
""".
-spec text_budget(binary(), binary(), binary(), binary()) -> pos_integer().
text_budget(Nick, User, Host, Target) ->
    Overhead =
        1 + byte_size(Nick) + 1 + byte_size(User) + 1 + byte_size(Host) +
            byte_size(<<" PRIVMSG ">>) + byte_size(Target) + byte_size(<<" :">>),
    max(64, 510 - Overhead - ?LINE_SLACK).

-doc """
Split reply text into at most `MaxLines` IRC message texts of at most
`Budget` bytes each.

Control characters are removed, blank lines dropped, long lines wrapped at
the last space when one is near the end of the chunk, and UTF-8 sequences
never split. When the reply is longer than `MaxLines`, the last line ends
with ` […]`.
""".
-spec reply_lines(binary(), pos_integer(), pos_integer()) -> [binary()].
reply_lines(Text, Budget, MaxLines) ->
    Valid = valid_utf8(Text),
    Paragraphs = [
        trim(<<<<C>> || <<C>> <= P, C >= 32 orelse C =:= $\t>>)
     || P <- binary:split(Valid, [<<"\r\n">>, <<"\n">>, <<"\r">>], [global])
    ],
    Chunks = lists:append([wrap(P, Budget) || P <- Paragraphs, P =/= <<>>]),
    case length(Chunks) > MaxLines of
        false ->
            Chunks;
        true ->
            Kept = lists:sublist(Chunks, MaxLines),
            Marker = <<" […]"/utf8>>,
            Last = lists:last(Kept),
            Room = Budget - byte_size(Marker),
            Cut = utf8_prefix(Last, Room),
            lists:droplast(Kept) ++ [<<(trim(Cut))/binary, Marker/binary>>]
    end.

wrap(Text, Budget) when byte_size(Text) =< Budget ->
    [Text];
wrap(Text, Budget) ->
    Head = utf8_prefix(Text, Budget),
    Cut =
        case binary:matches(Head, <<" ">>) of
            [] ->
                byte_size(Head);
            Spaces ->
                {Pos, _} = lists:last(Spaces),
                case Pos > Budget div 2 of
                    true -> Pos;
                    false -> byte_size(Head)
                end
        end,
    Line = trim(binary:part(Text, 0, Cut)),
    Rest = trim(binary:part(Text, Cut, byte_size(Text) - Cut)),
    case Rest of
        <<>> -> [Line];
        _ -> [Line | wrap(Rest, Budget)]
    end.

%% The longest prefix of at most Max bytes that ends on a UTF-8 boundary.
utf8_prefix(Bin, Max) when byte_size(Bin) =< Max ->
    Bin;
utf8_prefix(Bin, Max) ->
    utf8_back(Bin, Max).

utf8_back(Bin, 0) ->
    binary:part(Bin, 0, 0);
utf8_back(Bin, Len) ->
    case binary:at(Bin, Len) band 16#C0 of
        16#80 -> utf8_back(Bin, Len - 1);
        _ -> binary:part(Bin, 0, Len)
    end.

valid_utf8(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Valid when is_binary(Valid) -> Valid;
        _ -> ircd_websocket:utf8_safe(Bin)
    end.

trim(Bin) ->
    iolist_to_binary(string:trim(Bin, both, " \t")).

-doc """
Ask `Provider` for a reply to `Request`, adapting the request when the
provider rejects `max_tokens` or `temperature` (see the module docs).

Returns the result and the adaptations in force, including any learned here.
At most one retry per adaptation, so a request makes at most three calls.
""".
-spec complete(map(), request(), non_neg_integer()) ->
    {{ok, binary()} | {error, term()}, [adaptation()]}.
complete(Provider, Request, Timeout) ->
    #{settings := Settings, adapt := Adapt} = Request,
    Body = build_request(
        Settings#{adapt => Adapt},
        maps:get(system, Request),
        maps:get(context, Request),
        maps:get(turns, Request),
        maps:get(question, Request)
    ),
    case request(Provider, Body, Timeout) of
        {error, {http_status, 400, #{adapt := Needed}}} = Error when
            Needed =:= max_completion_tokens; Needed =:= default_temperature
        ->
            case lists:member(Needed, Adapt) of
                true -> {Error, Adapt};
                false -> complete(Provider, Request#{adapt := [Needed | Adapt]}, Timeout)
            end;
        Result ->
            {Result, Adapt}
    end.

-doc """
POST `Body` to `<base_url>/chat/completions` of `Provider` and return the
reply text.

`Provider` holds `base_url`, `api_key` (or `undefined`), and `timeout`
(milliseconds). TLS certificates are verified by hackney's defaults
(`verify_peer` with hostname checking). Redirects are not followed, and the
response body is capped at 1 MiB.
""".
-spec request(map(), binary(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
request(Provider, Body, Timeout) ->
    Url = <<(maps:get(base_url, Provider))/binary, "/chat/completions">>,
    Auth =
        case maps:get(api_key, Provider, undefined) of
            undefined -> [];
            Key -> [{<<"authorization">>, <<"Bearer ", Key/binary>>}]
        end,
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json">>},
        {<<"user-agent">>, <<"ircd-bot/1.0">>}
        | Auth
    ],
    Opts = [
        {recv_timeout, Timeout},
        {connect_timeout, min(Timeout, 10000)},
        {follow_redirect, false},
        {max_body_size, ?MAX_RESPONSE_BYTES}
    ],
    case hackney:request(post, Url, Headers, Body, Opts) of
        {ok, Status, _Headers, Resp} when Status >= 200, Status < 300, is_binary(Resp) ->
            parse_reply(Resp);
        {ok, Status, _Headers, Resp} when is_binary(Resp) ->
            case provider_error(Resp) of
                #{} = Detail when map_size(Detail) > 0 -> {error, {http_status, Status, Detail}};
                #{} -> {error, {http_status, Status}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
