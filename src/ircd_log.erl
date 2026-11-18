-module(ircd_log).
-export([format/2]).

%% @doc Format an OTP Logger event as one newline-terminated JSON object.
%% Flatlog renders the message field; invalid Unicode falls back to Erlang term text.
-spec format(map(), term()) -> iodata().
format(#{level := Level, meta := Meta} = Event, _) ->
    Line = flatlog:format(Event, #{template => [msg]}),
    Message =
        case unicode:characters_to_binary(Line) of
            Binary when is_binary(Binary) -> Binary;
            _ -> iolist_to_binary(io_lib:format("~tp", [Line]))
        end,
    [
        json:encode(#{
            level => Level,
            time => maps:get(time, Meta, 0),
            message => Message
        }),
        $\n
    ].
