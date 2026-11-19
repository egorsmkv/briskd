# Configuration

The default configuration is [`config/ircd.json`](https://github.com/egorsmkv/irc-server/blob/main/config/ircd.json). Set
`IRCD_CONFIG` to select another file. Paths in the file are resolved relative
to the process working directory unless they are absolute.

| Setting | Default | Description |
| --- | --- | --- |
| `name` | `irc.local` | Server name |
| `bind` | `127.0.0.1` | Listener address |
| `tcp_port` | `6667` | TCP port; `null` disables TCP |
| `tls_port` | `null` | Direct TLS port; `null` disables TLS |
| `certfile`, `keyfile` | `null` | PEM certificate and private key for TLS |
| `log_level` | `info` | `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`, or `trace`. `trace` shows every event |
| `log_format` | `json` | `json` (one object per line: `level`, `time` in microseconds, and the event's fields, or `message` for plain text) or `text` |
| `max_clients` | `10000` | Maximum active client sessions |
| `max_sendq` | `10000` | Lines queued for one client before it is disconnected with `ERROR :Closing Link: <server> (Max SendQ exceeded)` (100..1000000) |
| `client_password` | `null` | Optional password required with IRC `PASS` before registration |
| `operators` | `[]` | Operator accounts, each with `name` and `password` |
| `administrators` | `[]` | Operator accounts, each with `nick` and `password`. `OPER` uses `nick`. A successful login also grants channel operator on predefined channels |
| `channels` | `[]` | Channels created at startup when absent. Each entry has `name` and optional `topic`, `key`, `limit`, and `modes` |
| `motd_file` | `null` | Text file served by `MOTD` |
| `shutdown_grace` | `5` | Seconds a graceful shutdown waits for sessions to close (0..300) |
| `e2ee` | `null` | End-to-end encryption broker: `max_devices`, `max_prekeys`, `queue_limit`, `queue_ttl`, `fetch_rate`. `null` disables it. See [End-to-end encryption](e2ee.md) |
| `tls_reload_interval` | `60` | Seconds between checks of the TLS certificate and key files (including `sni` pairs); a changed, valid pair is reloaded without a restart. `0` disables; otherwise 5..86400 |
| `admin_name`, `admin_location1`, `admin_location2`, `admin_email` | See config | Values returned by `ADMIN` |
| `reop_delay` | `30` | Base delay in seconds before re-opping an operatorless safe channel |
| `resource_delay` | `60` | Seconds a nickname or channel released by a quit or netsplit stays unavailable (437); `0` disables |
| `account_password_min` | `8` | Shortest password `REGISTER` accepts, in bytes |
| `server_info` | `Erlang/OTP IRC server` | Server description in LINKS |
| `multiclient` | `false` | Let a connection logged into the same account as a nickname's holder attach to that nickname; it mirrors the holder's traffic and its QUIT closes only itself |
| `account_rejoin` | `false` | Remember a logged-in client's channels on disconnect (in memory) and rejoin them at the account's next login |
| `account_registration_before_connect` | `true` | Allow `REGISTER` before connection registration completes (`before-connect`) |
| `account_registration_email_required` | `false` | Require an email address in `REGISTER` (`email-required`) |
| `nicklen` | `9` | Longest nickname (9 to 30). RFC 1459 uses 9; every linked server must use the same value |
| `mnesia_dir` | `data/mnesia` | Mnesia database directory |
| `retention` | `transient` | `transient` or `channels`. `channels` keeps ordinary channel state and channel message history across a restart |
| `history_limit` | `100` | Channel `PRIVMSG`/`NOTICE` lines kept per channel when `retention` is `channels` (1..10000) |
| `server_links` | `[]` | Direct peer definitions with `name`, `host`, `port`, `password`, and optional `tls` |
| `ws_port`, `wss_port` | `null` | IRCv3 WebSocket listeners over TCP and TLS; `null` disables |
| `ws_origins` | `null` | Allowed WebSocket `Origin` values; `null` allows any origin |
| `network` | value of `name` | `NETWORK` ISUPPORT token |
| `network_icon` | `null` | `draft/ICON` ISUPPORT URL |
| `sts` | `null` | STS policy `{"port": P, "duration": seconds, "preload": false}`. `null` disables the `sts` capability |
| `sni` | `[]` | Extra TLS certificates chosen by SNI host name, each with `hostname`, `certfile`, and `keyfile` |
| `account_registration` | `true` | Allow `REGISTER` (draft/account-registration) |
| `chathistory` | `true` | Record channel and account-to-account messages for `CHATHISTORY` (bounded by `history_limit`) |
| `utf8_only` | `false` | Advertise `UTF8ONLY` and reject commands whose parameters are not UTF-8 |
| `monitor_limit` | `100` | Maximum `MONITOR` targets per client |
| `webirc` | `[]` | Trusted WebIRC gateways, each with `password` and a `hosts` list of IP addresses |
| `account_verification` | `null` | `{"command": ["/abs/program", "args"...], "ttl": 900}`. When set, `REGISTER` needs an email address and the program delivers a verification code (environment `IRCD_ACCOUNT`, `IRCD_EMAIL`, `IRCD_CODE`) |

Set at least one of `tcp_port`, `tls_port`, `ws_port`, or `wss_port`. TLS
uses TLS 1.2 and 1.3; configure `certfile` and `keyfile` when enabling the TLS
or secure WebSocket listener. The TLS listeners ask for an optional client
certificate. A missing or self-signed one does not fail the handshake; its
SHA-256 fingerprint is only used by SASL `EXTERNAL`. Server certificate
handling is unchanged. Port `0` requests an ephemeral port, which is reported
in the startup log.

`mnesia_dir` should point to writable storage. The default `retention` value
`transient` persists WHOWAS history, safe-channel state, accounts, and read
markers, and clears ordinary channels and channel history on restart.
`channels` also keeps ordinary channel names, topics, modes, keys, limits,
access masks, and the bounded channel `PRIVMSG`/`NOTICE` history
(`history_limit` lines, default 100). With `chathistory` enabled (the
default) that history is recorded in both modes for `CHATHISTORY`; under
`transient` retention it lasts until the next restart. A joining client
without `draft/chathistory` receives it after a restart under `channels`
retention. Client sessions, operator status, and imported peer state are
cleared on restart in both modes. Message bodies are not written to the log.
An invalid `retention` or `history_limit` is rejected at startup.

`administrators` are additional `OPER` accounts. `nick` is the name passed to
`OPER` and is a nickname under this server's nickname rules. It is compared
with RFC 1459 case folding and does not need to equal the client's current
nickname. These accounts can use the same operator commands as `operators`.
After a successful `OPER`, and when they later join, they are channel
operators on channels listed in `channels`. An ordinary operator account is
not. The same folded name cannot appear in both lists. `ADMIN` contact
strings are unrelated.

`channels` entries use a `#`, `&`, or `+` name. Optional `topic` is at most
390 bytes. Optional `key` follows channel-key rules. Optional `limit` is an
integer from 1 to 2147483647. Optional `modes` is a set of `i`, `m`, `n`,
`p`, `s`, `t`, `q`, and `K` flags (`a` is allowed on `&` only). `p` and `s`
cannot both be set. A `+` channel always has `t`. Startup creates a missing
channel with no members. A channel row that already exists, including one
kept by `channels` retention, is not overwritten. With `transient` retention
the row is still removed and created again from this list on the next start,
so later topic and mode changes do not survive that restart. The channel
stays when its last member leaves. `REHASH` adds newly configured channels
and does not delete a channel that was removed from the list. Invalid
entries are rejected at startup.
Backup, restore, and schema migration are described in
[docs/mnesia.md](mnesia.md). A restored directory follows the same
retention policy as a normal start.
