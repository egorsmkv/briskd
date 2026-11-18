%% Local channel record. With the default `transient` retention policy, ordinary
%% channels are removed on startup and safe `!` channels stay. `channels`
%% retention keeps every local channel row. Membership and pid invites are
%% cleared on startup in both policies.
-record(channel, {
    key,
    name,
    topic = <<>>,
    members = #{},
    flags = #{},
    lists = #{},
    invited = [],
    limit,
    password,
    creator,
    opless_since
}).
%% One row per channel. `entries` is newest-first `{Command, Prefix, Text}`
%% for accepted channel PRIVMSG and NOTICE. The list is capped by history_limit.
-record(channel_history, {channel, entries = []}).
