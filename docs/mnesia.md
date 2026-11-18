# Mnesia backup, restore, and schema migration

The state process owns the Mnesia schema. Tables are `disc_copies` on the local
node. The directory is the `mnesia_dir` JSON setting. The application creates
that directory and the schema before it starts Mnesia.

## What survives a restart

`retention` in the JSON configuration selects the policy. The default is
`transient`. `history_limit` (default 100, maximum 10000) is the number of
channel `PRIVMSG` and `NOTICE` bodies kept per channel when retention is
`channels`. Any other `retention` string, or a `history_limit` outside
1..10000, is rejected at startup. `REHASH` accepts a new limit and retention
value for messages sent after the reload. Which rows survive a restart is
decided by the setting loaded at that start.

| Data | `transient` (default) | `channels` |
| --- | --- | --- |
| WHOWAS history | Kept | Kept |
| Safe `!` channels | Kept | Kept |
| Ordinary `#`, `&`, and `+` channels | Deleted | Kept |
| Channel `PRIVMSG` / `NOTICE` history | Deleted | Kept, newest `history_limit` lines |
| Client sessions, presence, away text, and user modes | Deleted | Deleted |
| Channel members and pid invitations | Cleared | Cleared |
| Imported peers, remote users, remote channels, and services | Deleted | Deleted |

A restart therefore drops live nick occupancy, operator status, and peer state
even when the table files are still on disk. Kept channel rows come back with
the same name, topic, modes, key, limit, and ban, exception, and invite masks,
and with no members until someone joins. A join still enforces the restored
key, limit, and masks.

With `channels` retention, an accepted channel `PRIVMSG` or `NOTICE` is
appended to that channel's history. The list does not grow past
`history_limit`; the oldest line is dropped. The body is not written to the
logger. After a restart, a registered client who successfully joins the
channel receives those lines, oldest first, as ordinary `PRIVMSG` and `NOTICE`
addressed to the channel. Clients who are not allowed to join do not receive
them. Private messages are not stored. This is not an IRCv3 capability and
does not change the offered `CAP LS` set.

An empty ordinary channel is removed when its last member leaves under
`transient` retention. Under `channels` retention the empty channel and its
history stay, so a later restart can still restore them.

## Backup

Stop the server, or at least stop writes, before copying the directory. From a
shell on the node that owns the tables:

```erlang
ok = mnesia:backup(BackupFile).
```

`BackupFile` is a path outside `mnesia_dir`. A filesystem copy of `mnesia_dir`
is a valid backup only when Mnesia is stopped. Copying the directory while the
server is writing can produce a schema that will not start.

Keep backups of `mnesia_dir` with the same access controls as the host. WHOWAS
rows contain nicknames, usernames, hosts, and real names.

## Restore

1. Stop ircd.
2. Move the current `mnesia_dir` aside.
3. Install the backup into an empty directory and point `mnesia_dir` at it, or
   restore on a stopped node:

```erlang
ok = mnesia:restore(BackupFile, [{default_op, recreate_tables}]).
```

4. Start ircd against that directory.

Startup applies the `retention` policy of the configuration that starts ircd.
A restored directory does not bypass that policy: `transient` still drops
ordinary channels and channel history, and `channels` keeps them. Both
policies clear client sessions and peer-imported rows. Do not restore a
backup onto a node that is already serving traffic.

`mnesia:install_fallback/1` is the alternative when the node must load the
backup at the next start. Use it only while ircd and Mnesia are stopped.

## Schema migration

Records live in `include/`. On startup, `ircd_state` compares each table's
stored attributes with `record_info(fields, ...)`.

- A missing table is created.
- A table that already matches is kept.
- `channel` and `client` rows that predate the current fields gain the new
  fields at the end (`undefined` unless a later transform says otherwise).
- `remote_channel` rows gain a map for each missing field. That covers channel
  flags and the invitation set.
- `remote_client` rows gain `server = undefined` and `hop = 1` when those
  fields are absent.
- `known_server` and `service` are created empty and cleared on every start,
  together with the other peer tables.

The transform only appends fields. Renaming or reordering a field needs a new
explicit transform and a backup taken before the upgrade. Remote and client
tables are cleared after migration, so their transforms matter when a running
node loads a newer module without a restart. WHOWAS and the channel rows kept
by the active retention policy are what an operator must be able to read after
the new code starts. `channel_history` is a separate table created empty when
it is missing.

Roll back by stopping the node and restoring the backup taken before the
upgrade. Do not mix a newer schema with an older beam without that restore.
