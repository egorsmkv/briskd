%% Local client, presence, and WHOWAS records owned by the state process.
%% `channels` holds folded channel keys. `pass` is true once a required
%% client PASS matched, false when it did not, and undefined before PASS.
-record(client, {
    pid :: pid(),
    host :: binary(),
    nick = <<"*">> :: binary(),
    user :: binary() | undefined,
    real :: binary() | undefined,
    channels = [] :: [binary()],
    away :: binary() | undefined,
    pass :: boolean() | binary() | undefined
}).
%% `last` is the last activity time in seconds since the epoch.
-record(activity, {pid :: pid(), last :: integer()}).
%% `key` is {FoldedNick, -SecondsSinceEpoch, Unique}, so a key range scan is
%% newest-first per nickname.
-record(whowas, {
    key :: {binary(), integer(), pos_integer()},
    nick :: binary(),
    user :: binary() | undefined,
    host :: binary(),
    real :: binary() | undefined,
    server :: binary(),
    time :: integer()
}).
%% WHOWAS keeps the newest WHOWAS_PER_NICK entries per nickname and at most
%% WHOWAS_MAX rows in all (implementation policy; RFC 2812 3.6.3 leaves the
%% history size to the server). Over the total cap the oldest tenth goes.
-define(WHOWAS_PER_NICK, 10).
-define(WHOWAS_MAX, 10000).
%% User mode letters that are set (for example $i, $o, $w).
-record(user_modes, {pid :: pid(), modes = #{} :: #{char() => true}}).
