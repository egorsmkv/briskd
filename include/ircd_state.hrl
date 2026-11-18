-record(client, {pid, host, nick = <<"*">>, user, real, channels = [], away, pass}).
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
-record(activity, {pid, last}).
-record(whowas, {key, nick, user, host, real, server, time}).
-record(user_modes, {pid, modes = #{}}).
-record(remote_client, {key, peer, nick, user, host, token, modes = #{}, real}).
-record(remote_channel, {key, name, members = #{}, flags = #{}}).
