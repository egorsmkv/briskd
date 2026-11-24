-module(briskd_net_cap).
-moduledoc """
IRCv3 capability negotiation (`CAP`) command handling and `cap-notify`
announcements.
""".
-export([cap/3, notify_cap_changes/2]).
-include("briskd_client.hrl").

-doc """
Handle a client `CAP` command (IRCv3 capability negotiation).

- `LS [version]` records the requested version, suspends registration until
  `CAP END`, and lists the advertised capabilities from `m:briskd_cap`; values
  (`name=value`) are shown only to clients that asked for version 302.
- `LIST` lists the enabled capabilities.
- `REQ` applies the request atomically with `briskd_cap:request/2` and answers
  `ACK` or `NAK`. The reply is formatted with the capabilities in force before
  the request; the new set applies from the next line.
- `END` finishes negotiation and sends the welcome burst when registration is
  otherwise complete.

An unknown subcommand gets numeric 410 and a missing one 461. A reply that
does not fit one line continues with `*` only for `LS` and `LIST` at
version 302; an older client gets one line, and names that do not fit are
left out.
""".
-spec cap(#client{}, binary(), [binary()]) -> ok.
cap(#client{pid = Pid, nick = Nick} = Client, Server, [Sub | Rest]) ->
    case Sub of
        <<"LS">> ->
            briskd_cap:note_ls(Pid, [Sub | Rest]),
            briskd_cap:hold(Pid),
            send_cap_list(Pid, Nick, Server, <<"LS">>, ls_tokens(Pid));
        <<"LIST">> ->
            send_cap_list(Pid, Nick, Server, <<"LIST">>, briskd_cap:list_names(Pid));
        <<"REQ">> ->
            briskd_cap:hold(Pid),
            %% The ACK is sent with the capabilities in force before the
            %% request; the new set applies from the next line on.
            Before = briskd_cap:state(Pid),
            {Kind, Text} = briskd_cap:request(Pid, Rest),
            After = briskd_cap:state(Pid),
            Reply =
                case Kind of
                    ack -> <<"ACK">>;
                    nak -> <<"NAK">>
                end,
            briskd_cap:restore(Pid, Before),
            briskd_state_send:send(Pid, Server, <<"CAP">>, [Nick, Reply], Text),
            briskd_cap:restore(Pid, After);
        <<"END">> ->
            case briskd_cap:finish(Pid, briskd_state_client:identified(Client)) of
                welcome ->
                    briskd_state_client:send_welcome(briskd_state_client:client(Pid), Server);
                _ ->
                    ok
            end;
        _ ->
            briskd_state_send:numeric(Client, Server, <<"410">>, [Sub], <<"Invalid CAP command">>)
    end;
cap(Client, Server, []) ->
    briskd_state_send:numeric(Client, Server, <<"461">>, [<<"CAP">>], <<"Not enough parameters">>).

%% CAP LS tokens. Values are only shown to clients that asked for version 302.
ls_tokens(Pid) ->
    Values = maps:get(version, briskd_cap:state(Pid)) >= 302,
    [cap_token(Name, Value, Values) || {Name, Value} <- briskd_cap:advertised(Pid)].

cap_token(Name, undefined, _) -> Name;
cap_token(Name, _Value, false) -> Name;
cap_token(Name, Value, true) -> <<Name/binary, "=", Value/binary>>.

-doc """
Tell `cap-notify` clients about capabilities whose advertisement changed.

`Before` maps each client pid to its earlier advertised list, and `Server` is
the reply prefix. A capability that disappears is sent as `CAP DEL` (never for
`sts`) and is disabled. A new capability, or one whose value changed, is sent
as `CAP NEW`.
""".
-spec notify_cap_changes(#{pid() => [{binary(), undefined | binary()}]}, binary()) -> ok.
notify_cap_changes(Before, Server) ->
    maps:foreach(
        fun(Pid, Old) ->
            case briskd_cap:enabled(Pid, <<"cap-notify">>) of
                true -> notify_cap_change(Pid, Old, briskd_cap:advertised(Pid), Server);
                false -> ok
            end
        end,
        Before
    ).

notify_cap_change(Pid, Old, New, Server) ->
    Nick =
        case mnesia:dirty_read(client, Pid) of
            [#client{nick = N}] -> N;
            [] -> <<"*">>
        end,
    Removed = [
        Name
     || {Name, _} <- Old, not lists:keymember(Name, 1, New), Name =/= <<"sts">>
    ],
    Added = [Pair || Pair <- New, not lists:member(Pair, Old)],
    case Removed of
        [] ->
            ok;
        _ ->
            briskd_cap:disable(Pid, Removed),
            send_cap_list(Pid, Nick, Server, <<"DEL">>, Removed)
    end,
    case Added of
        [] ->
            ok;
        _ ->
            Values = maps:get(version, briskd_cap:state(Pid)) >= 302,
            send_cap_list(
                Pid, Nick, Server, <<"NEW">>, [cap_token(N, V, Values) || {N, V} <- Added]
            )
    end.

send_cap_list(Pid, Nick, Server, Sub, Names) ->
    %% The `*` continuation exists only for LS and LIST.
    Multiline =
        maps:get(version, briskd_cap:state(Pid)) >= 302 andalso
            (Sub =:= <<"LS">> orelse Sub =:= <<"LIST">>),
    Budget = cap_budget(Server, Nick, Sub, Multiline),
    Bodies =
        case Multiline orelse (Sub =/= <<"LS">> andalso Sub =/= <<"LIST">>) of
            true ->
                briskd_cap:pack(Names, Budget);
            false ->
                %% Before 302 a client reads one LS/LIST line only: names that
                %% do not fit are left out rather than sent on a second line.
                [hd(briskd_cap:pack(Names, Budget))]
        end,
    Last = length(Bodies),
    lists:foreach(
        fun({Index, Body}) ->
            Middle =
                case Multiline andalso Index < Last of
                    true -> [Nick, Sub, <<"*">>];
                    false -> [Nick, Sub]
                end,
            briskd_state_send:send(Pid, Server, <<"CAP">>, Middle, Body)
        end,
        lists:enumerate(Bodies)
    ).

%% Bytes left for the capability list after `:server CAP nick SUB [* ] :`.
cap_budget(Server, Nick, Sub, Multiline) ->
    Star =
        case Multiline of
            true -> 2;
            false -> 0
        end,
    512 - (11 + Star + byte_size(Server) + byte_size(Nick) + byte_size(Sub)).
