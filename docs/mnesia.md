# Mnesia backup, restore, and schema migration

This page is for an operator deciding what a restart keeps and how to copy
`mnesia_dir` before a release change. `ircd_state` owns the Mnesia schema;
`ircd_app` creates the directory named by `mnesia_dir`
([Configuration](configuration.md)) and the schema before it starts Mnesia.
The table below is what survives; backup and restore copy that directory and
do not bypass the retention policy of the next start.

## What survives a restart

`retention` in the JSON configuration selects the policy. The default is
`channels`. `history_limit` (default 100, maximum 10000) is the number of
channel `PRIVMSG` and `NOTICE` bodies kept per channel when retention is
`channels`. Any other `retention` string, or a `history_limit` outside
1..10000, is rejected at startup. `REHASH` accepts a new `history_limit`,
and messages stored after that reload use it. A new `retention` value is
accepted at the same time; the next start is what applies it. Which rows
survive a restart is decided by the setting loaded at that start.

| Data | `transient` | `channels` (default) |
| --- | --- | --- |
| WHOWAS history | Kept | Kept |
| Safe `!` channels | Kept | Kept |
| Ordinary `#`, `&`, and `+` channels | Deleted | Kept |
| Channel history (`channel_message`: one row per message or event) | Deleted | Kept, newest `history_limit` messages and, separately, events |
| Client sessions, presence, away text, and user modes | Deleted | Deleted |
| Channel members and pid invitations | Cleared | Cleared |
| Imported peers, remote users, remote channels, and services | Deleted | Deleted |
| Accounts (`account`: SCRAM-SHA-256 verifiers, email, client certificate fingerprints, pending verification) | Kept | Kept |
| Read markers (`read_marker`, per account and target) | Kept | Kept |
| End-to-end encryption device bundles (`e2ee_device`, public keys only) | Kept | Kept |
| End-to-end encryption offline queue (`e2ee_queue`, ciphertext until acknowledged or `queue_ttl`) | Kept | Kept |
| Channel metadata (`channel_meta`, synced with `ircd_chan_meta`) | Kept for safe `!` channels; deleted for ordinary channels | Kept |
| IRCv3 connection state: capabilities, MONITOR lists, user metadata, SASL progress | Deleted | Deleted |
| Direct-message history between accounts (`direct_message`: one row per message) | Deleted | Kept, newest `history_limit` entries per pair |
| Admin feature overrides (`setting`: control key and value, set in the admin panel) | Kept | Kept |

A restart therefore drops live nick occupancy, operator status, and peer state
even when the table files are still on disk. Kept channel rows come back with
the same name, topic, modes, key, limit, and ban, exception, and invite masks,
and with no members until someone joins. A join still enforces the restored
key, limit, and masks.

With `chathistory` enabled (the default), an accepted channel `PRIVMSG` or
`NOTICE` is appended to that channel's history in both retention modes, with
its `msgid`, `time`, client-only tags, and the sender's account. The list does
not grow past `history_limit`; the oldest line is dropped. The body is not
written to the logger. `transient` retention clears the table at startup, so
history lasts until the next restart; `channels` retention keeps it. Members
read it with IRCv3 `CHATHISTORY`. Under `channels` retention a client without
`draft/chathistory` that joins after a restart receives the stored lines,
oldest first, in a `chathistory` batch when it negotiated `batch`. `REDACT`
deletes one entry. Entries written by an older version as
`{Command, Prefix, Text}` are still read; they have no `msgid` or time.
Channel events (JOIN, PART, KICK, TOPIC, MODE without the channel key, QUIT,
NICK, TAGMSG) are recorded for `draft/event-playback`; messages and events
each keep `history_limit` entries. Direct messages are kept when at least one
side is logged in, keyed by account (or by nickname for a side without an
account), in the `direct_history` table under the same retention rules. Set `"chathistory": false` to record nothing; the server then also stops
advertising `draft/chathistory`, `draft/event-playback`, and the
`CHATHISTORY` ISUPPORT token.

The `setting` table holds the admin panel's feature overrides
(`ircd_overrides`): one row per changed control, `{setting, Key, Value}`
with a boolean or an integer. It is created on first start and survives both
retention policies; deleting a row (or the table) returns those settings to
the configuration file's values.

Channel rows gained `created` (RPL_CREATIONTIME), `topic_by`, and
`topic_at` (RPL_TOPICWHOTIME). Older rows are migrated by appending
`undefined`; such a channel reports the server start time until its topic
changes. Channels remembered for `account_rejoin` live in memory only.

The `account` and `read_marker` tables are disc copies created at startup and
are never cleared. An account row created before the `pending` field existed is
migrated by appending `undefined`. A pending account whose code expired is
replaced by the next `REGISTER` of that name. Accounts and read markers are
also copied to linked servers, so deleting an account must be done on every
server. Removing an account means deleting its row while the server
is stopped, or from a shell with `mnesia:dirty_delete(account, FoldedName)`.

An empty ordinary channel is removed when its last member leaves under
`transient` retention. Under `channels` retention the empty channel and its
history stay, so a later restart can still restore them.

Channels listed in the JSON `channels` setting are an exception. Startup
creates one when no row exists, after the retention policy has cleared or
kept existing rows. An existing row is not replaced, so a topic or mode
change kept by `channels` retention survives the next start. `transient`
deletes that ordinary row and then creates it again from the configuration,
which restores the configured topic, modes, key, and limit. Either policy
keeps the channel when its last member leaves. Membership is still cleared
on restart.

## Backup

Stop the server, or use `mnesia:backup/1` for a consistent online checkpoint,
before copying data.

### Online backup via the release CLI (Docker Compose or systemd)

To write a consistent Mnesia backup file inside the `/var/lib/ircd` volume while
the production container is running:

```sh
docker-compose -f docker-compose.prod.yml exec -T ircd \
  /opt/ircd/bin/ircd eval 'ok = mnesia:backup("/var/lib/ircd/backup.bup").'
docker-compose -f docker-compose.prod.yml cp ircd:/var/lib/ircd/backup.bup ./backup-$(date -u +%Y%m%dT%H%M%SZ).bup
```

Or from an Erlang shell on the node that owns the tables:

```erlang
ok = mnesia:backup(BackupFile).
```

`BackupFile` is a path outside `mnesia_dir`. A raw filesystem or volume copy of
`mnesia_dir` is a valid backup **only when `ircd` is stopped** (`docker-compose
-f docker-compose.prod.yml stop ircd`). Copying `mnesia_dir` while the server is
writing can produce a corrupt schema that will not start.

Keep backups of `mnesia_dir` with the same access controls as the host. WHOWAS
rows contain nicknames, usernames, hosts, and real names, and `account` rows
contain SCRAM-SHA-256 verifiers and optional email addresses.

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

A restart is the supported upgrade. The server ships no `.appup` and its
modules do not implement `code_change`, so do not hot-load a new release
into a running node. Stop ircd, install the new release, and start it
again. That start clears client sessions, user modes, nick occupancy, and
imported peer state, then applies the `retention` policy of the
configuration that starts. WHOWAS, accounts, read markers, the `setting`
table, E2EE device and queue rows, safe `!` channels, and the ordinary
channel state and history that policy keeps are what must still be readable.

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
the new code starts.

Channel history moved from `channel_history` (one row per channel holding its
whole list, rewritten for every message) to `channel_message` (an ordered_set,
one row per entry keyed by `{Channel, Class, Seq}`), so recording a message
writes one small row instead of the channel's whole history. At startup
under `channels` retention, every `channel_history` row is converted into
`channel_message` rows and deleted; `channel_history` stays as an empty table.
`channel_message` is created empty when it is missing. Direct-message history
moved the same way, from `direct_history` to `direct_message` (keyed
`{PartyPair, Class, Seq}`), and is converted at the same time. Rolling back to
an older release after this conversion needs the backup taken before the
upgrade: older code reads only `channel_history` and `direct_history`.

The tables cleared on every start (`client`, `activity`, `user_modes`,
`remote_client`, `remote_channel`, `known_server`, `service`) are kept in
memory only (`ram_copies`); an existing disc copy from an earlier release is
converted at startup. As disc copies, every write to them went through the
transaction log, including the `activity` row written for every client
command, for data that no restart keeps. Mnesia's
`dump_log_write_threshold` defaults to 50,000 writes here (Mnesia's own
default is 1,000), so bursts of history writes do not start a log dump while
the previous one runs; a value set in `sys.config` is kept.

Roll back by stopping the node and restoring the backup taken before the
upgrade. Do not mix a newer schema with an older beam without that restore.
