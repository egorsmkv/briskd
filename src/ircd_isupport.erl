-module(ircd_isupport).
-export([tokens/0, send/3, send_tokens/4]).
-include("ircd_state.hrl").

%% RPL_ISUPPORT (005) tokens. The values describe what this server enforces:
%% RFC 1459 case mapping (`ircd_wire:fold/1`), the nickname length from
%% `ircd_wire:nickname/1` (9), channel names up to 50 bytes, the channel mode
%% classes from RFC 2811, and the IRCv3 tokens for MONITOR, WHOX, bot mode,
%% chathistory, account extbans, UTF8ONLY, and the network icon.

-define(PER_LINE, 13).

%% @doc Current ISUPPORT tokens in a stable order.
-spec tokens() -> [binary()].
tokens() ->
    Config = persistent_term:get({ircd_state, config}, #{}),
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
        <<"CHATHISTORY=", History/binary>>,
        <<"EXTBAN=$,a">>,
        <<"KICKLEN=390">>,
        <<"METADATA=50">>,
        <<"MONITOR=", (integer_to_binary(maps:get(monitor_limit, Config, 100)))/binary>>,
        <<"MSGREFTYPES=timestamp,msgid">>,
        <<"NAMELEN=200">>,
        <<"NETWORK=", (maps:get(network, Config, <<"IRC">>))/binary>>,
        <<"NICKLEN=", (integer_to_binary(ircd_state:nicklen()))/binary>>,
        <<"PREFIX=(ov)@+">>,
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
    lists:sort(Base ++ Utf8 ++ Icon).

%% @doc Send the 005 burst to one client. With `draft/extended-isupport` and
%% `batch` the lines are grouped in a `draft/isupport` batch.
-spec send(#client{}, binary(), [binary()]) -> ok.
send(Client, Server, Tokens) ->
    send_tokens(
        Client, Server, Tokens, ircd_cap:enabled(Client#client.pid, <<"draft/extended-isupport">>)
    ).

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
