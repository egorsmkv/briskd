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
%% `members` maps a folded nick to {AdjacentPeer, Roles}. `flags` holds mode
%% letters and the key, limit, topic, and list entries learned from peers.
-record(remote_channel, {
    key :: binary(),
    name :: binary(),
    members = #{} :: #{binary() => {binary(), [atom()]}},
    flags = #{} :: #{char() | atom() => term()},
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
