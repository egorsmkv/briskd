%% State imported from a server link. These rows are cleared on startup.
%% `peer` is the adjacent link that delivered the row. `server` is the user's
%% home server, which may be several hops beyond that link.
%% `account` is the user's IRCv3 account name, learned from ACCOUNT messages.
-record(remote_client, {
    key :: binary(),
    peer :: binary(),
    nick :: binary(),
    user :: binary(),
    host :: binary(),
    token :: binary() | undefined,
    modes = #{} :: #{char() => true},
    real :: binary(),
    server :: binary() | undefined,
    hop = 1 :: non_neg_integer(),
    account :: binary() | undefined
}).
%% Mode letters a peer set on a channel, plus the topic, key, limit, and the
%% ban, exception, and invite-exception lists it reported.
-type remote_flags() :: #{
    topic => binary(),
    key => binary(),
    limit => pos_integer(),
    ban => [binary()],
    exception => [binary()],
    invite => [binary()],
    char() => true
}.

%% `members` maps a folded nick to {AdjacentPeer, Roles}; `flags` is what
%% peers reported about the channel. A row with no members is deleted
%% (ircd_state_link:sweep_remote_channels/0). `invited` is no longer used
%% (kept so the record keeps its shape) and is always empty.
-record(remote_channel, {
    key :: binary(),
    name :: binary(),
    members = #{} :: #{binary() => {binary(), [atom()]}},
    flags = #{} :: remote_flags(),
    invited = #{} :: #{binary() => true}
}).
%% One known server reached through an adjacent link. `hop` is the distance
%% from this server. `parent` is the previous server on that route.
-record(known_server, {
    key :: binary(),
    name :: binary(),
    hop :: non_neg_integer(),
    token :: binary() | undefined,
    adjacent :: binary(),
    parent :: binary(),
    info = <<>> :: binary()
}).
-record(service, {
    key :: binary(),
    name :: binary(),
    distribution :: binary(),
    type :: binary(),
    info = <<>> :: binary(),
    server :: binary(),
    %% undefined for a service registered on this server.
    peer :: binary() | undefined
}).
