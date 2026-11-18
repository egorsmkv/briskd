%% State imported from a server link. These rows are cleared on startup.
%% `peer` is the adjacent link that delivered the row. `server` is the user's
%% home server, which may be several hops beyond that link.
%% `account` is the user's IRCv3 account name, learned from ACCOUNT messages.
-record(remote_client, {
    key, peer, nick, user, host, token, modes = #{}, real, server, hop = 1, account
}).
-record(remote_channel, {key, name, members = #{}, flags = #{}, invited = #{}}).
%% One known server reached through an adjacent link. `hop` is the distance
%% from this server. `parent` is the previous server on that route.
-record(known_server, {key, name, hop, token, adjacent, parent, info = <<>>}).
-record(service, {key, name, distribution, type, info = <<>>, server, peer}).
