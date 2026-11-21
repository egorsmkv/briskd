-module(ircd_accept_exhaustion_tests).
-include_lib("eunit/include/eunit.hrl").
-export([log/2]).

%% Running out of file descriptors must not stop the server. Accept fails
%% with emfile; the listener used to exit, ircd_sup restarted it into the same
%% error, and the restart intensity then stopped the application. Now the
%% listener backs off, logs accept_exhausted, and accepts again once
%% descriptors are free.
%%
%% The test lowers this VM's soft RLIMIT_NOFILE with prlimit(1), fills the
%% remaining descriptors with client connections, and restores the limit.

exhaustion_test_() ->
    case os:find_executable("prlimit") of
        false -> [];
        _ -> {timeout, 60, fun run/0}
    end.

run() ->
    Dir = filename:join(
        "/tmp", "ircd-emfile-" ++ integer_to_list(erlang:system_time(nanosecond))
    ),
    Db = filename:join(Dir, "db"),
    ok = filelib:ensure_dir(filename:join(Db, "x")),
    Config = filename:join(Dir, "ircd.json"),
    ok = file:write_file(Config, config_json(Db)),
    os:putenv("IRCD_CONFIG", Config),
    {ok, _} = application:ensure_all_started(ircd),
    ok = logger:add_handler(?MODULE, ?MODULE, #{level => warning, config => #{test => self()}}),
    {Soft, Hard} = nofile_limit(),
    try
        exhaust_and_recover(Soft, Hard)
    after
        set_nofile(Soft, Hard),
        _ = logger:remove_handler(?MODULE),
        _ = application:stop(ircd),
        os:unsetenv("IRCD_CONFIG"),
        _ = file:del_dir_r(Dir)
    end.

exhaust_and_recover(Soft, Hard) ->
    Port = listener_port(),
    Listener = listener_pid(),
    Used = length(element(2, {ok, _} = file:list_dir("/proc/self/fd"))),
    set_nofile(Used + 40, Hard),
    Socks = fill(Port, []),
    ?assert(length(Socks) > 0),
    %% Each client takes one descriptor here and its accepted socket another,
    %% so the listener hit emfile before the last connect did.
    receive
        {accept_exhausted, emfile} -> ok
    after 5000 -> error(no_accept_exhausted)
    end,
    timer:sleep(300),
    ?assertEqual(Listener, listener_pid()),
    ?assert(lists:keymember(ircd, 1, application:which_applications())),
    [gen_tcp:close(S) || S <- Socks],
    set_nofile(Soft, Hard),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Sock, <<"NICK after\r\nUSER after 0 * :T\r\n">>),
    ?assertNotEqual(nomatch, binary:match(recv_until(Sock, <<" 001 ">>, <<>>), <<" 001 ">>)),
    gen_tcp:close(Sock).

%% Connect until this VM runs out of descriptors.
fill(Port, Acc) when length(Acc) < 200 ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 2000) of
        {ok, Sock} -> fill(Port, [Sock | Acc]);
        {error, _} -> Acc
    end;
fill(_Port, Acc) ->
    Acc.

nofile_limit() ->
    Out = os:cmd("prlimit --pid " ++ os:getpid() ++ " --nofile --raw --noheadings"),
    [_, _, SoftText, HardText | _] = string:lexemes(Out, " \n"),
    {list_to_integer(SoftText), list_to_integer(HardText)}.

set_nofile(Soft, Hard) ->
    Cmd = io_lib:format("prlimit --pid ~s --nofile=~b:~b", [os:getpid(), Soft, Hard]),
    "" = os:cmd(lists:flatten(Cmd)),
    ok.

%% logger handler: forward accept_exhausted reports to the test process.
-spec log(logger:log_event(), logger:handler_config()) -> ok.
log(#{msg := {report, #{event := accept_exhausted, reason := Reason}}}, #{config := #{test := Pid}}) when
    is_pid(Pid)
->
    Pid ! {accept_exhausted, Reason},
    ok;
log(_Event, _Config) ->
    ok.

listener_pid() ->
    {_, Pid, _, _} = lists:keyfind(tcp, 1, supervisor:which_children(ircd_sup)),
    Pid.

listener_port() ->
    {ok, Port} = ircd_listener:port(listener_pid()),
    Port.

recv_until(Sock, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            {ok, <<_/binary>> = Bin} = gen_tcp:recv(Sock, 0, 5000),
            recv_until(Sock, Needle, <<Acc/binary, Bin/binary>>);
        _ ->
            Acc
    end.

config_json(Db) ->
    iolist_to_binary([
        <<"{\"name\":\"irc.test\",\"bind\":\"127.0.0.1\",\"tcp_port\":0,\"tls_port\":null,">>,
        <<"\"log_level\":\"warning\",\"log_format\":\"text\",\"shutdown_grace\":2,">>,
        <<"\"mnesia_dir\":\"">>,
        list_to_binary(Db),
        <<"\"}">>
    ]).
