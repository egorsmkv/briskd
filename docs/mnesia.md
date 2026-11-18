# Mnesia backup, restore, and schema migration

The state process owns the Mnesia schema. Tables are `disc_copies` on the local
node. The directory is the `mnesia_dir` JSON setting. The application creates
that directory and the schema before it starts Mnesia.

## What survives a restart

| Data | Restart behavior |
| --- | --- |
| WHOWAS history | Kept |
| Safe `!` channels | Kept, with members, invitations, and the reop deadline cleared |
| Client sessions, presence, and user modes | Deleted |
| Ordinary and local `&` / `#` / `+` channels | Deleted |
| Imported peers, remote users, remote channels, and services | Deleted |

A restart therefore drops live sessions and peer state even when the table
files are still on disk. Safe-channel rows stay so the channel id and topic
can be restored, but nobody is a member until they join again.

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

Startup still clears client sessions, ordinary channels, and peer-imported
rows. Restoring a backup brings WHOWAS and safe channels back, then the same
startup rules apply. Do not restore a backup onto a node that is already
serving traffic.

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
node loads a newer module without a restart. WHOWAS and safe channels are the
rows an operator must be able to read after the new code starts.

Roll back by stopping the node and restoring the backup taken before the
upgrade. Do not mix a newer schema with an older beam without that restore.
