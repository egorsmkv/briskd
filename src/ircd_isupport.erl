-module(ircd_isupport).
-export([tokens/0, send/3, send_tokens/4]).
-include("ircd_state.hrl").

-moduledoc """
`RPL_ISUPPORT` (005) tokens and their delivery.

The values describe what this server enforces: RFC 1459 case mapping
(`ircd_wire:fold/1`), the configured nickname length
(`ircd_state:nicklen/0`, default 9), channel names up to 50 bytes, the
channel mode classes from RFC 2811, and the IRCv3 tokens for MONITOR
(`monitor_limit`), WHOX, bot mode, chathistory (`history_limit`), metadata,
account extbans, `UTF8ONLY` (with `utf8_only`), and the network icon
(`draft/ICON`, with `network_icon`).

Token values are read from the configuration in `persistent_term`; sending
runs in `m:ircd_state`. With
[draft/extended-isupport](https://ircv3.net/specs/extensions/extended-isupport)
and `batch`, the burst is wrapped in a `draft/isupport` batch.
""".

-define(PER_LINE, 13).

-doc """
Current ISUPPORT tokens, sorted, built from the live configuration.
""".
-spec tokens() -> [binary()].
tokens() ->
    Config = ircd_config:current_or_empty(),
    Limit = integer_to_binary(ircd_route:max_channels()),
    History = integer_to_binary(maps:get(history_limit, Config, 100)),
    Base = [
        <<"ACCOUNTEXTBAN=a">>,
        <<"AWAYLEN=390">>,
        <<"BOT=B">>,
        <<"CASEMAPPING=rfc1459">>,
        <<"CHANLIMIT=#&+!:", Limit/binary>>,
        <<"CHANMODES=beI,k,l,aimnpqrstK">>,
        <<"CHANNELLEN=50">>,
        <<"CHANTYPES=#&+!">>,
        <<"EXTBAN=$,a">>,
        <<"KICKLEN=390">>,
        <<"MAXLIST=beI:", (integer_to_binary(?MAX_LIST_ENTRIES))/binary>>,
        <<"METADATA=50">>,
        <<"MONITOR=", (integer_to_binary(maps:get(monitor_limit, Config, 100)))/binary>>,
        <<"MSGREFTYPES=timestamp,msgid">>,
        <<"NAMELEN=200">>,
        <<"NETWORK=", (maps:get(network, Config, <<"IRC">>))/binary>>,
        <<"NICKLEN=", (integer_to_binary(ircd_state:nicklen()))/binary>>,
        <<"PREFIX=(ov)@+">>,
        <<"SAFELIST">>,
        <<"TARGMAX=NOTICE:4,PRIVMSG:4,TAGMSG:4">>,
        <<"TOPICLEN=390">>,
        <<"USERLEN=32">>,
        <<"WHOX">>
    ],
    Utf8 =
        case maps:get(utf8_only, Config, false) of
            true -> [<<"UTF8ONLY">>];
            false -> []
        end,
    Icon =
        case maps:get(network_icon, Config, null) of
            null -> [];
            Url -> [<<"draft/ICON=", Url/binary>>]
        end,
    %% Only while history is recorded (`chathistory`).
    ChatHistory =
        case maps:get(chathistory, Config, true) of
            true -> [<<"CHATHISTORY=", History/binary>>];
            false -> []
        end,
    lists:sort(Base ++ ChatHistory ++ Utf8 ++ Icon).

-doc """
Send `Tokens` as 005 lines (13 tokens per line) from `Server` to one client.
With `draft/extended-isupport` and `batch` the lines are grouped in a
`draft/isupport` batch.
""".
-spec send(#client{}, binary(), [binary()]) -> ok.
send(Client, Server, Tokens) ->
    send_tokens(
        Client, Server, Tokens, ircd_cap:enabled(Client#client.pid, <<"draft/extended-isupport">>)
    ).

-doc """
Send `Tokens` as 005 lines (13 tokens per line) to one client. When
`Batched` is true and the client has `batch`, the lines are wrapped in a
`draft/isupport` batch; `send/3` passes whether the client negotiated
`draft/extended-isupport`.
""".
-spec send_tokens(#client{}, binary(), [binary()], boolean()) -> ok.
send_tokens(#client{pid = Pid} = Client, Server, Tokens, Batched) ->
    Emit = fun() ->
        lists:foreach(
            fun(Chunk) ->
                ircd_state_send:numeric(
                    Client, Server, <<"005">>, Chunk, <<"are supported by this server">>
                )
            end,
            chunks(Tokens)
        )
    end,
    case Batched of
        true -> ircd_state_send:with_batch(Pid, <<"draft/isupport">>, [], [], Emit);
        false -> Emit()
    end,
    ok.

chunks([]) ->
    [];
chunks(Tokens) when length(Tokens) =< ?PER_LINE ->
    [Tokens];
chunks(Tokens) ->
    {Head, Tail} = lists:split(?PER_LINE, Tokens),
    [Head | chunks(Tail)].
