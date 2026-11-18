%% Local client, presence, and WHOWAS records owned by the state process.
-record(client, {pid, host, nick = <<"*">>, user, real, channels = [], away, pass}).
-record(activity, {pid, last}).
-record(whowas, {key, nick, user, host, real, server, time}).
-record(user_modes, {pid, modes = #{}}).
