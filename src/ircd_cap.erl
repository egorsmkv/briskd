-module(ircd_cap).
-export([
    client_tags/1,
    connect/1,
    disconnect/1,
    enabled/2,
    finish/2,
    hold/1,
    label/2,
    list_names/1,
    note_ls/2,
    offered/0,
    pack/2,
    request/2,
    state/1,
    welcomed/1
]).

%% Capability negotiation for one client connection.
%% The offered set is fixed for the life of the server. Version 302 is the
%% highest capability-negotiation version this server enables. `cap-notify` is
%% implicit at that version and cannot be removed.

-define(CAPS, [
    <<"batch">>, <<"cap-notify">>, <<"labeled-response">>, <<"message-tags">>
]).

%% @doc Capabilities advertised by `CAP LS`, in a stable order.
-spec offered() -> [binary()].
offered() -> ?CAPS.

%% @doc Remember a new connection that has not negotiated any capability.
-spec connect(pid()) -> true.
connect(Pid) ->
    ets:insert(ircd_caps, {Pid, initial()}).

%% @doc Drop capability state when the connection closes.
-spec disconnect(pid()) -> true.
disconnect(Pid) ->
    ets:delete(ircd_caps, Pid).

%% @doc Return whether the connection has the named capability enabled.
-spec enabled(pid(), binary()) -> boolean().
enabled(Pid, Name) ->
    maps:is_key(Name, effective(state(Pid))).

%% @doc Read the connection's negotiation state. A missing row is unnegotiated.
-spec state(pid()) -> map().
state(Pid) ->
    case ets:lookup(ircd_caps, Pid) of
        [{_, State}] -> State;
        [] -> initial()
    end.

%% @doc True after the registration welcome has been sent.
-spec welcomed(pid()) -> boolean().
welcomed(Pid) ->
    maps:get(welcomed, state(Pid)).

%% @doc Suspend registration until `CAP END` when the client is not yet welcomed.
-spec hold(pid()) -> ok.
hold(Pid) ->
    State = state(Pid),
    case maps:get(welcomed, State) of
        true -> ok;
        false -> store(Pid, State#{negotiating => true})
    end.

%% @doc Remember the highest CAP LS version the client has asked for.
%% A later unversioned or lower `CAP LS` does not reduce the stored version.
-spec note_ls(pid(), [binary()]) -> ok.
note_ls(Pid, Params) ->
    State = state(Pid),
    case requested_version(Params) of
        Version when is_integer(Version), Version >= 302 ->
            store(Pid, State#{version => 302});
        _ ->
            ok
    end.

%% @doc Enabled capability names in advertisement order.
-spec list_names(pid()) -> [binary()].
list_names(Pid) ->
    Enabled = effective(state(Pid)),
    [Name || Name <- ?CAPS, maps:is_key(Name, Enabled)].

%% @doc Apply one atomic `CAP REQ`. Unknown names reject the whole list.
-spec request(pid(), [binary()]) -> {ack | nak, binary()}.
request(Pid, Params) ->
    State = state(Pid),
    Tokens = tokens(Params),
    case apply_tokens(Tokens, effective(State), maps:get(version, State)) of
        {ok, Enabled} ->
            store(Pid, State#{enabled => without_implicit(Enabled, State)}),
            {ack, join(Tokens)};
        error ->
            {nak, join(Tokens)}
    end.

%% @doc End negotiation. `welcome` means the held registration reply is due.
-spec finish(pid(), boolean()) -> welcome | ignore | pending.
finish(Pid, Ready) ->
    State = state(Pid),
    case maps:get(welcomed, State) of
        true ->
            ignore;
        false when Ready ->
            store(Pid, State#{negotiating => false, welcomed => true}),
            welcome;
        false ->
            store(Pid, State#{negotiating => false}),
            pending
    end.

%% @doc Client-only tags, preserving last-key-wins order from the parser.
-spec client_tags([{binary(), undefined | binary()}]) -> [{binary(), undefined | binary()}].
client_tags(Tags) ->
    [{Key, Value} || {<<$+, _/binary>> = Key, Value} <- Tags].

%% @doc Label value when labeled responses are active for this connection.
%% The value is absent when it is empty or longer than 64 bytes.
-spec label(map(), [{binary(), undefined | binary()}]) -> undefined | binary().
label(State, Tags) ->
    Enabled = effective(State),
    Active =
        maps:is_key(<<"message-tags">>, Enabled) andalso
            maps:is_key(<<"batch">>, Enabled) andalso
            maps:is_key(<<"labeled-response">>, Enabled),
    case Active of
        true ->
            case lists:keyfind(<<"label">>, 1, Tags) of
                {_, Value} when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 64 ->
                    Value;
                _ ->
                    undefined
            end;
        false ->
            undefined
    end.

%% @doc Pack capability names into trailing parameters of at most `Max` bytes.
-spec pack([binary()], pos_integer()) -> [binary()].
pack([], _Max) ->
    [<<>>];
pack(Names, Max) ->
    pack_names(Names, Max, <<>>, []).

initial() ->
    #{version => 0, enabled => #{}, negotiating => false, welcomed => false}.

store(Pid, State) ->
    ets:insert(ircd_caps, {Pid, State}),
    ok.

effective(#{version := Version, enabled := Enabled}) when Version >= 302 ->
    Enabled#{<<"cap-notify">> => true};
effective(#{enabled := Enabled}) ->
    Enabled.

%% `cap-notify` is implicit at version 302, so it is not stored as a REQ bit.
without_implicit(Enabled, #{version := Version}) when Version >= 302 ->
    maps:remove(<<"cap-notify">>, Enabled);
without_implicit(Enabled, _) ->
    Enabled.

requested_version([<<"LS">>, Raw | _]) ->
    try binary_to_integer(Raw) of
        Version when Version > 0 -> Version;
        _ -> undefined
    catch
        error:badarg -> undefined
    end;
requested_version(_) ->
    undefined.

tokens(Params) ->
    [Token || Param <- Params, Token <- binary:split(Param, <<" ">>, [global, trim_all])].

join([]) ->
    <<>>;
join(Tokens) ->
    iolist_to_binary(lists:join(<<" ">>, Tokens)).

apply_tokens([], Enabled, _Version) ->
    {ok, Enabled};
apply_tokens([Token | Rest], Enabled, Version) ->
    case token(Token) of
        {disable, <<"cap-notify">>} when Version >= 302 ->
            error;
        {_, <<>>} ->
            error;
        {disable, Name} ->
            case known(Name) of
                true -> apply_tokens(Rest, maps:remove(Name, Enabled), Version);
                false -> error
            end;
        {enable, Name} ->
            case known(Name) of
                true -> apply_tokens(Rest, Enabled#{Name => true}, Version);
                false -> error
            end
    end.

token(<<$-, Name/binary>>) -> {disable, Name};
token(Name) -> {enable, Name}.

known(Name) ->
    lists:member(Name, ?CAPS).

pack_names([], _Max, <<>>, Acc) ->
    lists:reverse(Acc);
pack_names([], _Max, Current, Acc) ->
    lists:reverse([Current | Acc]);
pack_names([Name | Rest], Max, <<>>, Acc) ->
    pack_names(Rest, Max, Name, Acc);
pack_names([Name | Rest], Max, Current, Acc) ->
    Next = <<Current/binary, " ", Name/binary>>,
    case byte_size(Next) =< Max of
        true -> pack_names(Rest, Max, Next, Acc);
        false -> pack_names(Rest, Max, Name, [Current | Acc])
    end.
