%% State imported from a directly connected server. These rows are not durable.
-record(remote_client, {key, peer, nick, user, host, token, modes = #{}, real}).
-record(remote_channel, {key, name, members = #{}, flags = #{}}).
