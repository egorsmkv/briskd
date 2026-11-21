-module(briskd_search_tests).
-include_lib("eunit/include/eunit.hrl").

%% Message search (egorsmkv.github.io/search) against a fake briskd-search
%% service run by this test: an HTTP server that records POST /index
%% operations and answers POST /search by matching every query word in the
%% indexed text of the requested conversations, newest first. The Tantivy
%% service itself is tested in search/ (cargo test).

-define(FAKE, briskd_search_fake).

search_test_() ->
    {timeout, 90, fun run/0}.

run() ->
    Dir = filename:join(
        "/tmp", "briskd-search-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    {Listen, HttpPort} = start_fake(0),
    Config = filename:join(Dir, "briskd.json"),
    ok = file:write_file(Config, config_json(Db, HttpPort)),
    os:putenv("BRISKD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(briskd),
    try
        %% The indexer starts with a rebuild: the index is cleared.
        wait_until(fun() -> lists:member(clear, op_kinds()) end),
        Port = listener_port(),
        Alice = client(Port, <<"alice">>, [<<"batch">>, <<"egorsmkv.github.io/search">>]),
        Bob = client(Port, <<"bob">>, []),
        Carol = client(Port, <<"carol">>, [<<"egorsmkv.github.io/search">>]),
        cmd(Alice, <<"JOIN #s">>),
        cmd(Bob, <<"JOIN #s">>),
        mirrors_history(Bob),
        searches(Alice, Carol),
        skips_encrypted(),
        skips_encrypted_wire(Port, Alice),
        rewrites_conversations(),
        admin_controls(Alice),
        recovers(Alice, Listen, HttpPort)
    after
        _ = application:stop(briskd),
        os:unsetenv("BRISKD_CONFIG"),
        stop_fake(),
        _ = file:del_dir_r(Dir)
    end.

%% Four messages with history_limit 3: four adds and one delete of the
%% trimmed oldest, leaving the three newest in the index.
mirrors_history(Bob) ->
    [cmd(Bob, <<"PRIVMSG #s :alpha number ", (integer_to_binary(N))/binary>>) || N <- [1, 2, 3, 4]],
    cmd(Bob, <<"PRIVMSG #s :\x01ACTION waves at alpha\x01">>),
    wait_until(fun() -> length(docs(<<"c #s">>)) =:= 3 end),
    Texts = lists:sort([T || #{text := T} <- docs(<<"c #s">>)]),
    ?assertEqual([<<"alpha number 3">>, <<"alpha number 4">>, <<"waves at alpha">>], Texts).

searches(Alice, Carol) ->
    %% Newest first, as a batch naming the target and the total.
    %% Read the live channel lines first, so only the search reply follows.
    _ = cmd(Alice, <<"LUSERS">>),
    Reply = cmd(Alice, <<"SEARCH #s 10 :alpha">>),
    ?assert(has(Reply, <<"BATCH +">>)),
    ?assert(has(Reply, <<" egorsmkv.github.io/search #s 3">>)),
    Order = [
        binary:match(Reply, <<"waves at alpha">>),
        binary:match(Reply, <<":alpha number 4">>),
        binary:match(Reply, <<":alpha number 3">>)
    ],
    ?assertEqual(Order, lists:sort(Order)),
    ?assertNot(has(Reply, <<"alpha number 1">>)),
    %% Every word must match; `*` covers the client's channels; the limit applies.
    ?assert(has(cmd(Alice, <<"SEARCH * 10 :number 4">>), <<":alpha number 4">>)),
    Two = cmd(Alice, <<"SEARCH * 2 :alpha">>),
    ?assertEqual(2, count(Two, <<"PRIVMSG #s :">>)),
    ?assert(has(cmd(Alice, <<"SEARCH #s 10 :nothing-like-this">>), <<"#s 0">>)),
    %% Only members may search a channel.
    ?assert(has(cmd(Carol, <<"SEARCH #s 10 :alpha">>), <<"FAIL SEARCH INVALID_TARGET #s">>)),
    ?assertEqual(0, count(cmd(Carol, <<"SEARCH * 10 :alpha">>), <<"PRIVMSG">>)),
    %% Parameters.
    ?assert(has(cmd(Alice, <<"SEARCH #s">>), <<"FAIL SEARCH NEED_MORE_PARAMS">>)),
    ?assert(has(cmd(Alice, <<"SEARCH #s 0 :alpha">>), <<"FAIL SEARCH INVALID_PARAMS 0">>)),
    ?assert(has(cmd(Alice, <<"SEARCH #s 5 :  ">>), <<"FAIL SEARCH INVALID_PARAMS query">>)),
    ?assert(
        has(cmd(Alice, <<"SEARCH #s 5 yesterday :alpha">>), <<"INVALID_PARAMS yesterday">>)
    ),
    %% timestamp= pages back: only messages older than that time.
    [#{time := T4}] = [D || #{text := <<"alpha number 4">>} = D <- docs(<<"c #s">>)],
    Older = cmd(
        Alice,
        <<"SEARCH #s 10 timestamp=", (iso(T4))/binary, " :alpha">>
    ),
    ?assert(has(Older, <<":alpha number 3">>)),
    ?assertNot(has(Older, <<":alpha number 4">>)).

%% End-to-end encrypted bodies, TAGMSG, and events are never sent.
skips_encrypted() ->
    Before = length(ops()),
    Entry = #{
        cmd => <<"PRIVMSG">>,
        prefix => <<"x!x@x">>,
        text => <<"ciphertext">>,
        msgid => <<"m1">>,
        time => 1,
        tags => [{<<"+egorsmkv.github.io/e2ee-dst">>, <<"dev">>}],
        account => undefined
    },
    ok = briskd_search:note_add(channel_message, <<"#e">>, 1, Entry),
    ok = briskd_search:note_add(channel_message, <<"#e">>, 2, Entry#{
        cmd => <<"TAGMSG">>, tags => []
    }),
    ok = briskd_search:note_add(channel_message, <<"#e">>, 3, Entry#{text => none, tags => []}),
    ok = briskd_search:note_add(channel_message, <<"#e">>, 4, Entry#{tags => []}),
    wait_until(fun() -> docs(<<"c #e">>) =/= [] end),
    ?assertEqual([<<"ciphertext">>], [T || #{text := T} <- docs(<<"c #e">>)]),
    ?assertEqual(Before + 1, length(ops())).

%% Encrypted envelopes sent over real connections are stored in history,
%% with their E2EE tags, and never indexed: with message-tags, without it
%% (only the envelope tags are kept), as a draft/multiline batch, and as a
%% direct message between accounts. A plain message after them proves the
%% index changes were flushed.
skips_encrypted_wire(Port, Alice) ->
    Src = <<"+egorsmkv.github.io/e2ee-src=tagger:1">>,
    Type = <<"+egorsmkv.github.io/e2ee-type=msg">>,
    Dst = <<"+egorsmkv.github.io/e2ee-dst=2">>,
    {ok, _} = briskd_ctl:run([<<"create-account">>, <<"tagger">>, <<"tagger-pass-1">>]),
    Tagger = sasl_client(
        Port,
        <<"tagger">>,
        <<"tagger-pass-1">>,
        [<<"message-tags">>, <<"batch">>, <<"draft/multiline">>, <<"sasl">>]
    ),
    Plain = client(Port, <<"plainy">>, []),
    [
        cmd(C, <<"JOIN ", Ch/binary>>)
     || C <- [Tagger, Plain], Ch <- [<<"#e1">>, <<"#e2">>, <<"#e3">>]
    ],
    cmd(Tagger, <<"@", Src/binary, ";", Type/binary, " PRIVMSG #e1 :SECRETONE with tags">>),
    %% plainy did not negotiate message-tags.
    cmd(Plain, <<"@", Type/binary, " PRIVMSG #e2 :SECRETTWO without message-tags">>),
    send(Tagger, <<"@", Src/binary, ";", Type/binary, " BATCH +m1 draft/multiline #e3">>),
    send(Tagger, <<"@batch=m1 PRIVMSG #e3 :SECRETTHREE first line">>),
    send(Tagger, <<"@batch=m1 PRIVMSG #e3 :second line">>),
    cmd(Tagger, <<"BATCH -m1">>),
    cmd(
        Tagger,
        <<"@", Src/binary, ";", Type/binary, ";", Dst/binary, " PRIVMSG plainy :SECRETFOUR direct">>
    ),
    cmd(Tagger, <<"PRIVMSG #e1 :plain marker after the envelopes">>),
    wait_until(fun() -> docs(<<"c #e1">>) =/= [] end),
    %% Stored, as encrypted.
    Stored = lists:append([
        briskd_state_history:channel_history(C)
     || C <- [<<"#e1">>, <<"#e2">>, <<"#e3">>]
    ]),
    Secret = [
        E
     || #{text := T} = E <- Stored,
        binary:match(iolist_to_binary(body(T)), <<"SECRET">>) =/= nomatch
    ],
    ?assertEqual(3, length(Secret)),
    [?assert(briskd_e2ee:encrypted(Tags)) || #{tags := Tags} <- Secret],
    %% Never indexed: not in any document, not found by SEARCH.
    Indexed = [X || {{doc, _}, _, _, X} <- ets:tab2list(?FAKE)],
    ?assertEqual([], [X || X <- Indexed, binary:match(X, <<"SECRET">>) =/= nomatch]),
    ?assertEqual([<<"plain marker after the envelopes">>], [T || #{text := T} <- docs(<<"c #e1">>)]),
    ?assertEqual(0, count(cmd(Tagger, <<"SEARCH * 10 :SECRETONE">>), <<"PRIVMSG">>)),
    ?assertEqual(0, count(cmd(Tagger, <<"SEARCH plainy 10 :SECRETFOUR">>), <<"PRIVMSG">>)),
    %% A full rebuild applies the same rule.
    ok = briskd_search:rebuild_now(),
    #{rebuilds := R} = briskd_search:info(),
    wait_until(fun() ->
        maps:get(rebuilds, briskd_search:info()) >= R andalso
            maps:get(status, briskd_search:info()) =:= ready
    end),
    _ = cmd(Alice, <<"LUSERS">>),
    Rebuilt = [X || {{doc, _}, _, _, X} <- ets:tab2list(?FAKE)],
    ?assertEqual([], [X || X <- Rebuilt, binary:match(X, <<"SECRET">>) =/= nomatch]),
    gen_tcp:close(Tagger),
    gen_tcp:close(Plain).

body({multiline, Lines}) -> [L || {_, L} <- Lines];
body(Text) when is_binary(Text) -> Text;
body(_) -> <<>>.

sasl_client(Port, Nick, Password, Caps) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, line}]),
    send(S, [<<"CAP REQ :">>, lists:join(<<" ">>, Caps)]),
    send(S, [<<"NICK ">>, Nick]),
    send(S, [<<"USER ">>, Nick, <<" 0 * :T">>]),
    _ = recv_until(S, <<"ACK">>),
    send(S, <<"AUTHENTICATE PLAIN">>),
    _ = recv_until(S, <<"AUTHENTICATE +">>),
    send(S, [<<"AUTHENTICATE ">>, base64:encode(<<0, Nick/binary, 0, Password/binary>>)]),
    _ = recv_until(S, <<" 903 ">>),
    send(S, <<"CAP END">>),
    _ = recv_until(S, <<" 001 ">>),
    S.

%% A rewritten conversation (redaction, account erasure) is removed whole and
%% indexed again from what history keeps.
rewrites_conversations() ->
    Entries = briskd_state_history:channel_history(<<"#s">>),
    Kept = [E || #{text := T} = E <- Entries, T =/= <<"alpha number 3">>],
    ok = briskd_state_history:replace_channel(<<"#s">>, Kept),
    wait_until(fun() -> length(docs(<<"c #s">>)) =:= 2 end),
    ?assert(lists:member({delete_conv, <<"c #s">>}, [{K, C} || {K, C} <- conv_ops()])).

%% The admin panel's view (briskd_search:info/0, `briskdctl search`), a manual
%% rebuild, and the `search` switch: off withdraws SEARCH, on rebuilds.
admin_controls(Alice) ->
    #{status := ready, enabled := true, service := Service} = briskd_search:info(),
    ?assertMatch(#{reachable := true, docs := _, bytes := 4096}, Service),
    {ok, Json} = briskd_ctl:run([<<"search">>, <<"--json">>]),
    ?assertMatch(
        #{<<"status">> := <<"ready">>, <<"service">> := #{<<"reachable">> := true}},
        json:decode(Json)
    ),
    #{rebuilds := Rebuilds} = briskd_search:info(),
    Clears = length([clear || clear <- op_kinds()]),
    ok = briskd_search:rebuild_now(),
    wait_until(fun() -> maps:get(rebuilds, briskd_search:info()) =:= Rebuilds + 1 end),
    ?assertEqual(Clears + 1, length([clear || clear <- op_kinds()])),
    #{last_rebuild_docs := Docs, last_rebuild_at := At} = briskd_search:info(),
    ?assert(is_integer(Docs) andalso Docs > 0),
    ?assert(is_integer(At)),
    %% Switched off: the command is unknown and the indexer idles.
    {ok, _} = briskd_state:set_control(<<"search">>, <<"false">>),
    ?assertNot(briskd_search:enabled()),
    ?assert(has(cmd(Alice, <<"SEARCH #s 10 :alpha">>), <<" 421 ">>)),
    cmd(Alice, <<"PRIVMSG #s :gamma while off">>),
    wait_until(fun() -> maps:get(status, briskd_search:info()) =:= disabled end),
    ?assertMatch(#{enabled := false, service := #{reachable := false}}, briskd_search:info()),
    %% Back on: the index is rebuilt, including what was said meanwhile.
    {ok, _} = briskd_state:reset_control(<<"search">>),
    wait_until(
        fun() -> lists:member(<<"gamma while off">>, [T || #{text := T} <- docs(<<"c #s">>)]) end,
        300
    ),
    wait_until(fun() -> maps:get(status, briskd_search:info()) =:= ready end),
    ?assert(has(cmd(Alice, <<"SEARCH #s 10 :gamma">>), <<":gamma while off">>)).

%% With the service gone, SEARCH fails softly; once it answers again the
%% index is rebuilt from history.
recovers(Alice, Listen, HttpPort) ->
    stop_fake(),
    gen_tcp:close(Listen),
    ?assert(
        has(cmd(Alice, <<"SEARCH #s 10 :alpha">>), <<"FAIL SEARCH TEMPORARILY_UNAVAILABLE #s">>)
    ),
    %% A message while it is down marks the index for a rebuild.
    cmd(Alice, <<"PRIVMSG #s :beta while down">>),
    wait_until(fun() -> maps:get(status, gen_server:call(briskd_search, status)) =:= down end),
    {_, HttpPort} = start_fake(HttpPort),
    wait_until(
        fun() -> lists:member(<<"beta while down">>, [T || #{text := T} <- docs(<<"c #s">>)]) end,
        300
    ),
    ?assert(lists:member(clear, op_kinds())),
    ?assert(has(cmd(Alice, <<"SEARCH #s 10 :beta">>), <<":beta while down">>)).

%%% Fake briskd-search

start_fake(Port) ->
    case ets:whereis(?FAKE) of
        undefined -> ets:new(?FAKE, [named_table, public, ordered_set]);
        _ -> ets:delete_all_objects(?FAKE)
    end,
    {ok, Listen} = gen_tcp:listen(Port, [
        binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}, {packet, raw}
    ]),
    {ok, Bound} = inet:port(Listen),
    Pid = spawn(fun() -> accept(Listen) end),
    ok = gen_tcp:controlling_process(Listen, Pid),
    persistent_term:put({?MODULE, fake}, Pid),
    {Listen, Bound}.

stop_fake() ->
    case persistent_term:get({?MODULE, fake}, undefined) of
        undefined -> ok;
        Pid -> exit(Pid, kill)
    end,
    _ = persistent_term:erase({?MODULE, fake}),
    ok.

accept(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Sock} ->
            serve(Sock),
            accept(Listen);
        {error, _} ->
            ok
    end.

serve(Sock) ->
    case read_request(Sock, <<>>) of
        {ok, <<"/health">>, _} ->
            Docs = length([1 || {{doc, _}, _, _, _} <- ets:tab2list(?FAKE)]),
            respond(Sock, #{status => ok, docs => Docs, segments => 1, bytes => 4096});
        {ok, Path, Body} ->
            respond(Sock, handle(Path, json:decode(Body)));
        error ->
            ok
    end,
    gen_tcp:close(Sock).

respond(Sock, Reply) ->
    Json = iolist_to_binary(json:encode(Reply)),
    gen_tcp:send(Sock, [
        <<"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n">>,
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Json)),
        <<"\r\n\r\n">>,
        Json
    ]).

read_request(Sock, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            [RequestLine | Lines] = binary:split(Head, <<"\r\n">>, [global]),
            [_, Path | _] = binary:split(RequestLine, <<" ">>, [global]),
            Length = lists:foldl(
                fun(L, N) ->
                    case binary:split(L, <<":">>) of
                        [K, V] ->
                            case string:lowercase(string:trim(K)) of
                                <<"content-length">> -> binary_to_integer(string:trim(V));
                                _ -> N
                            end;
                        _ ->
                            N
                    end
                end,
                0,
                Lines
            ),
            read_body(Sock, Path, Rest, Length);
        [_] ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, <<_/binary>> = Data} -> read_request(Sock, <<Acc/binary, Data/binary>>);
                {error, _} -> error
            end
    end.

read_body(_Sock, Path, Body, Length) when byte_size(Body) >= Length ->
    {ok, Path, Body};
read_body(Sock, Path, Body, Length) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, <<_/binary>> = Data} -> read_body(Sock, Path, <<Body/binary, Data/binary>>, Length);
        {error, _} -> error
    end.

handle(<<"/index">>, #{<<"ops">> := Ops}) ->
    lists:foreach(fun apply_op/1, Ops),
    #{applied => length(Ops)};
handle(<<"/search">>, #{<<"q">> := Q, <<"convs">> := Convs, <<"limit">> := Limit} = Req) ->
    Before = maps:get(<<"before">>, Req, undefined),
    Words = string:lexemes(string:lowercase(Q), " "),
    Matches = lists:reverse(
        lists:keysort(1, [
            {Time, Id, Conv}
         || {{doc, Id}, Conv, Time, Text} <- ets:tab2list(?FAKE),
            lists:member(Conv, Convs),
            Before =:= undefined orelse Time < Before,
            lists:all(
                fun(W) -> binary:match(string:lowercase(Text), W) =/= nomatch end, Words
            )
        ])
    ),
    #{
        hits => [#{id => I, conv => C, time => T} || {T, I, C} <- lists:sublist(Matches, Limit)],
        total => length(Matches)
    }.

apply_op(#{<<"op">> := <<"add">>, <<"id">> := Id, <<"conv">> := C, <<"time">> := T, <<"text">> := X}) ->
    log_op(add, C),
    ets:insert(?FAKE, {{doc, Id}, C, T, X});
apply_op(#{<<"op">> := <<"delete">>, <<"id">> := Id}) ->
    log_op(delete, Id),
    ets:delete(?FAKE, {doc, Id});
apply_op(#{<<"op">> := <<"delete_conv">>, <<"conv">> := C}) ->
    log_op(delete_conv, C),
    ets:match_delete(?FAKE, {{doc, '_'}, C, '_', '_'});
apply_op(#{<<"op">> := <<"clear">>}) ->
    log_op(clear, <<>>),
    ets:match_delete(?FAKE, {{doc, '_'}, '_', '_', '_'}).

log_op(Kind, Arg) ->
    ets:insert(?FAKE, {{op, erlang:unique_integer([monotonic])}, Kind, Arg}).

ops() -> [{K, A} || {{op, _}, K, A} <- ets:tab2list(?FAKE)].
op_kinds() -> [K || {K, _} <- ops()].
conv_ops() -> [{K, A} || {K, A} <- ops(), K =:= delete_conv].

docs(Conv) ->
    [#{id => I, time => T, text => X} || {{doc, I}, C, T, X} <- ets:tab2list(?FAKE), C =:= Conv].

%%% IRC client

listener_port() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(briskd_sup)),
    true = is_pid(Pid),
    {ok, Port} = briskd_listener:port(Pid),
    Port.

client(Port, Nick, Caps) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, line}]),
    case Caps of
        [] -> ok;
        _ -> send(S, [<<"CAP REQ :">>, lists:join(<<" ">>, Caps)])
    end,
    send(S, [<<"NICK ">>, Nick]),
    send(S, [<<"USER ">>, Nick, <<" 0 * :T">>]),
    case Caps of
        [] -> ok;
        _ -> send(S, <<"CAP END">>)
    end,
    _ = recv_until(S, <<" 001 ">>),
    S.

send(S, Line) ->
    ok = gen_tcp:send(S, [Line, <<"\r\n">>]).

%% Send a line and return everything up to the PONG of a PING sent after it.
cmd(S, Line) ->
    send(S, Line),
    Token = <<"t", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    send(S, <<"PING ", Token/binary>>),
    recv_until(S, Token).

recv_until(S, Needle) ->
    recv_until(S, Needle, []).

-spec recv_until(gen_tcp:socket(), binary(), [binary()]) -> binary().
recv_until(S, Needle, Acc) ->
    case gen_tcp:recv(S, 0, 10000) of
        {ok, <<_/binary>> = Line} ->
            case binary:match(Line, Needle) of
                nomatch -> recv_until(S, Needle, [Line | Acc]);
                _ -> iolist_to_binary(lists:reverse([Line | Acc]))
            end;
        {error, Reason} ->
            erlang:error({recv, Reason, Needle, iolist_to_binary(lists:reverse(Acc))})
    end.

has(Bin, Needle) -> binary:match(Bin, Needle) =/= nomatch.

count(Bin, Needle) -> length(binary:matches(Bin, Needle)).

iso(Ms) ->
    case calendar:system_time_to_rfc3339(Ms, [{unit, millisecond}, {offset, "Z"}]) of
        Text when is_list(Text) -> unicode:characters_to_binary(Text);
        Text when is_binary(Text) -> Text
    end.

wait_until(Fun) -> wait_until(Fun, 100).

wait_until(_Fun, 0) ->
    erlang:error(timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, N - 1)
    end.

config_json(Db, HttpPort) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"error\",\"log_format\":\"text\",\"shutdown_grace\":2,">>,
        <<"\"history_limit\":3,\"chathistory\":true,">>,
        <<"\"search\":{\"url\":\"http://127.0.0.1:">>,
        integer_to_binary(HttpPort),
        <<"/\",\"timeout\":1000,\"max_results\":20},">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).
