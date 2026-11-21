%% Local channel record. With the default `transient` retention policy, ordinary
%% channels are removed on startup and safe `!` channels stay. `channels`
%% retention keeps every local channel row. Membership and pid invites are
%% cleared on startup in both policies.
%% `members` maps a local session pid to its roles. `flags` holds set mode
%% letters. `lists` maps ban, exception, and invite to sorted mask lists.
%% Entries per ban, exception, or invite list (ISUPPORT MAXLIST=beI:100).
%% A full list answers ERR_BANLISTFULL (478, RFC 2812 5.2); a peer's addition
%% beyond it is dropped. Implementation policy, not an RFC value.
-define(MAX_LIST_ENTRIES, 100).
-type channel_role() :: operator | creator | voice | member.
-record(channel, {
    key :: binary(),
    name :: binary(),
    topic = <<>> :: binary(),
    members = #{} :: #{pid() => [channel_role()]},
    flags = #{} :: #{char() => true},
    lists = #{} :: #{atom() => [binary()]},
    invited = [] :: [pid()],
    limit :: pos_integer() | undefined,
    password :: binary() | undefined,
    creator :: pid() | undefined,
    %% Reop deadline for an operatorless safe channel.
    opless_since :: integer() | undefined,
    %% Creation time in seconds since the epoch (RPL_CREATIONTIME, 329).
    created :: integer() | undefined,
    %% Who set the topic and when, in seconds (RPL_TOPICWHOTIME, 333).
    topic_by :: binary() | undefined,
    topic_at :: integer() | undefined
}).
%% One row per channel. `entries` is newest-first `{Command, Prefix, Text}`
%% for accepted channel PRIVMSG and NOTICE. The list is capped by history_limit.
%% Entries are maps; rows written by older releases may still hold tuples.
-record(channel_history, {channel :: binary(), entries = [] :: [map() | tuple()]}).
%% Channel history, one row per entry (ordered_set, briskd_state_history). The
%% key is {FoldedChannel, Class, Seq}: Class is `msg` (PRIVMSG, NOTICE,
%% TAGMSG) or `event` (JOIN, MODE, ...), each kept to `history_limit` newest;
%% Seq orders a channel's entries across both classes. Appending writes one
%% small row, where the older `channel_history` row (one list per channel,
%% now only read to migrate it) was rewritten whole for every message.
-type history_class() :: msg | event.
-record(channel_message, {
    key :: {binary(), history_class(), pos_integer()},
    entry :: map() | tuple()
}).
%% Durable channel metadata (draft/metadata-2), kept alongside the channel row.
-record(channel_meta, {channel :: binary(), entries = #{} :: map()}).
