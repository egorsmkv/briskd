-module(briskd_motd).
-moduledoc """
Cached, immutable message-of-the-day (`MOTD`) snapshots.

Reads, validates, normalizes, and wraps the configured `motd_file` at startup
and on `REHASH` (`reload/1`), publishing the resulting snapshot in
`persistent_term`. Client `MOTD` requests and registration welcomes (`motd/3`)
read only the cached snapshot, avoiding filesystem I/O inside `m:briskd_state`.

Lines are split on LF, CR and NUL octets are stripped to prevent protocol
injection, files larger than 64 KiB are treated as `missing`, and lines longer
than 80 octets are wrapped on valid UTF-8 character boundaries. Because the
snapshot is cached, edits to the MOTD file take effect after `REHASH` (or
restart).
""".

-export([
    current/0,
    publish/1,
    load/1,
    reload/1,
    lines/1,
    wrap_line/1,
    motd/3
]).

-include("briskd_state.hrl").

-define(MAX_MOTD_BYTES, 65536).
-define(LINE_LIMIT, 80).

-doc "Cached MOTD state: either `missing` or `{ok, Lines}` ready for 372 replies.".
-type snapshot() :: missing | {ok, [binary()]}.
-export_type([snapshot/0]).

-doc "Return the currently cached MOTD snapshot.".
-spec current() -> snapshot().
current() ->
    case persistent_term:get(?MODULE, missing) of
        {ok, Lines} when is_list(Lines) -> {ok, Lines};
        _ -> missing
    end.

-doc "Publish an immutable MOTD snapshot in `persistent_term`.".
-spec publish(snapshot()) -> ok.
publish(Snapshot) ->
    persistent_term:put(?MODULE, Snapshot).

-doc """
Read and normalize the MOTD file at `Path`, returning `missing` when `Path`
is `null`, unreadable, or exceeds 64 KiB.
""".
-spec load(null | file:filename_all()) -> snapshot().
load(null) ->
    missing;
load(Path) ->
    case file:read_file(Path) of
        {ok, Contents} when byte_size(Contents) =< ?MAX_MOTD_BYTES ->
            {ok, lines(Contents)};
        _ ->
            missing
    end.

-doc "Load `Path` and publish the resulting snapshot.".
-spec reload(null | file:filename_all()) -> snapshot().
reload(Path) ->
    Snapshot = load(Path),
    ok = publish(Snapshot),
    Snapshot.

-doc """
Normalize raw MOTD file bytes into wrapped 80-octet-bounded lines.

Strips CR and NUL bytes to prevent CRLF injection, preserves intentional
blank lines, and drops a single trailing empty element after a final LF.
""".
-spec lines(binary()) -> [binary()].
lines(<<>>) ->
    [];
lines(Contents) ->
    RawLines = binary:split(Contents, <<"\n">>, [global]),
    ContentLines =
        case lists:last(RawLines) of
            <<>> -> lists:sublist(RawLines, length(RawLines) - 1);
            _ -> RawLines
        end,
    lists:append([wrap_line(sanitize(Line)) || Line <- ContentLines]).

-doc """
Wrap a single MOTD line into chunks of at most 80 octets without splitting
valid multibyte UTF-8 characters.
""".
-spec wrap_line(binary()) -> [binary()].
wrap_line(<<>>) ->
    [<<>>];
wrap_line(Line) when byte_size(Line) =< ?LINE_LIMIT ->
    [Line];
wrap_line(Line) ->
    Len = utf8_split_pos(Line, ?LINE_LIMIT),
    <<Chunk:Len/binary, Rest/binary>> = Line,
    [Chunk | wrap_line(Rest)].

-doc """
Handle `MOTD [<target>]` (RFC 2812 section 3.4.1) from the cached snapshot.

Sends 402 ERR_NOSUCHSERVER when `Params` names another server, 422 ERR_NOMOTD
when no valid MOTD snapshot is cached, or 375 RPL_MOTDSTART, 372 RPL_MOTD per
line, and 376 RPL_ENDOFMOTD.
""".
-spec motd([binary()], #client{}, binary()) -> ok.
motd(Params, Client, Server) ->
    case briskd_info:query_local_server(Params, Server) of
        {false, Target} ->
            briskd_state_send:numeric(Client, Server, <<"402">>, [Target], <<"No such server">>);
        true ->
            case current() of
                missing ->
                    briskd_state_send:numeric(
                        Client, Server, <<"422">>, [], <<"MOTD File is missing">>
                    );
                {ok, Lines} ->
                    briskd_state_send:numeric(
                        Client, Server, <<"375">>, [], <<"- Message of the day -">>
                    ),
                    lists:foreach(
                        fun(Line) ->
                            briskd_state_send:numeric(Client, Server, <<"372">>, [], [
                                <<"- ">>, Line
                            ])
                        end,
                        Lines
                    ),
                    briskd_state_send:numeric(
                        Client, Server, <<"376">>, [], <<"End of MOTD command">>
                    )
            end
    end.

%% Strip CR and NUL bytes from a line so raw file content cannot inject frames.
sanitize(Line) ->
    binary:replace(Line, [<<"\r">>, <<0>>], <<>>, [global]).

%% Find a split point =< Limit that does not bisect a valid UTF-8 sequence.
utf8_split_pos(Bin, Limit) ->
    case binary:at(Bin, Limit) band 16#C0 of
        16#80 ->
            find_utf8_lead(Bin, Limit, 1);
        _ ->
            Limit
    end.

find_utf8_lead(_Bin, Limit, Back) when Back > 3; Limit - Back =< 0 ->
    Limit;
find_utf8_lead(Bin, Limit, Back) ->
    Pos = Limit - Back,
    Byte = binary:at(Bin, Pos),
    case Byte band 16#C0 of
        16#80 ->
            find_utf8_lead(Bin, Limit, Back + 1);
        _ ->
            SeqLen = utf8_seq_len(Byte),
            case SeqLen > 1 andalso Pos + SeqLen =< byte_size(Bin) of
                true ->
                    Slice = binary:part(Bin, Pos, SeqLen),
                    case unicode:characters_to_binary(Slice) of
                        Slice -> Pos;
                        _ -> Limit
                    end;
                false ->
                    Limit
            end
    end.

utf8_seq_len(B) when B >= 16#C2, B =< 16#DF -> 2;
utf8_seq_len(B) when B >= 16#E0, B =< 16#EF -> 3;
utf8_seq_len(B) when B >= 16#F0, B =< 16#F4 -> 4;
utf8_seq_len(_) -> 1.
