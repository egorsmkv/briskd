# Configuration

The default configuration is [`config/briskd.json`](https://github.com/egorsmkv/briskd/blob/main/config/briskd.json). Set
`BRISKD_CONFIG` to select another file. Paths in the file are resolved relative
to the process working directory unless they are absolute. The server reads
that file at startup and again on `REHASH`.

## Start here

1. Pick `name`. It is the name clients and linked servers see. If omitted it
   is `irc.local`. It must be a host-like token of at most 63 characters
   (`A-Z`, `a-z`, `0-9`, `.`, `-`, starting with a letter or digit).
2. Set at least one of `tcp_port` and `tls_port`. `null` turns that listener
   off. The sample file listens on TCP `6667` and leaves TLS off. `ws_port`
   or `wss_port` also counts as a listener. Startup fails when all four are
   `null`. Port `0` binds an ephemeral port and the startup log reports it.
3. A TLS listener (`tls_port` or `wss_port`) needs `certfile` and `keyfile`,
   PEM paths. Those listeners use TLS 1.2 and 1.3.
4. Set `operators` when someone must use `OPER`. Each entry needs `name` and
   `password`. Leave the list empty when you do not want operators.
   `administrators` is a separate list (`nick` and `password`) that can use
   the same operator commands and, after `OPER`, is a channel operator on
   the channels in `channels`.
5. List in `channels` the channels you want created at startup when no row
   exists yet. Each entry needs `name` (`#`, `&`, or `+`).
6. Set `server_links` only when this process should link to another briskd.
   Leave it `[]` otherwise.
7. Set `webui` only when you want the browser client (the same HTTP listener
   also serves the admin pages). Leave it `null` otherwise. How to use the
   client is [WebIRC](webirc.md); that guide is the user page.
8. `mnesia_dir` (default `data/mnesia`) is the database directory, and
   `retention` is `channels` or `transient`. `channels` keeps ordinary
   channel state and bounded message history across a restart; `transient`
   clears them. See [Mnesia](mnesia.md).
9. `log_level` defaults to `info`. `debug` and `trace` also log each accepted
   command. `PING` and `PONG` are not logged.

Invalid JSON, a missing required field, or a value of the wrong type or out
of range refuses startup: the process does not start. A rejected `REHASH`
keeps the configuration that is already running. An unrecognized string such
as `log_level` or `retention` is that kind of value. A key the loader does
not read is ignored, except an unknown key inside `flood` or `e2ee`, which
is rejected.

Operator passwords and link passwords come from this file. Command logs
replace `PASS` with `redacted` and record only the `OPER` account name, and
link and session status output drops the link password.

## Settings

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
| `ai_providers` | `{}` | OpenAI-compatible endpoints for AI assistant bots: `base_url`, `api_key` or `api_key_env`, `model`, `timeout`. See [AI assistant bots](bots.md) |
| `calls` | `null` | User-to-user voice and video calls relayed through rtpengine. `null` or `false` disables. See [Calls](#calls) and [Voice and video calls](calls.md) |
| `bots` | `[]` | AI assistant bots. See [Bots](#bots) and [AI assistant bots](bots.md) |
| `max_sendq` | `10000` | Lines queued for one client before it is disconnected with `ERROR :Closing Link: <server> (Max SendQ exceeded)` (100..1000000). Server links, inbound or outbound, allow a fixed 50000 |
| `flood` | See below | Client flood and spam token buckets (`lines_burst`, `lines_per_second`, `messages_burst`, `messages_per_second`, `join_burst`, `join_per_minute`, `nick_burst`, `nick_per_minute`, `register_per_minute`); `null` disables |
| `max_accounts` | `100000` | Maximum stored accounts (`REGISTER` and `ACCOUNTSYNC`) |
| `max_empty_channels` | `1000` | Maximum empty non-predefined safe or retained channels kept at once |
| `empty_channel_ttl` | `86400` | Seconds before an empty non-predefined safe or retained channel expires; `0` disables TTL expiry |
| `max_read_markers` | `500` | Maximum `MARKREAD` targets stored per account (or per unauthenticated connection) |
| `max_direct_conversations` | `200` | Maximum direct-message history conversations kept per account |
| `max_peer_users`, `max_peer_servers`, `max_peer_services` | `10000`, `100`, `100` | Maximum remote users, servers, and services accepted per peer link |
| `client_password` | `null` | Optional password required with IRC `PASS` before registration |
| `operators` | `[]` | Operator accounts, each with `name` and `password` |
| `administrators` | `[]` | Operator accounts, each with `nick` and `password`. `OPER` uses `nick`. A successful login also grants channel operator on predefined channels |
| `channels` | `[]` | Channels created at startup when absent. Each entry has `name` and optional `topic`, `key`, `limit`, and `modes` |
| `motd_file` | `null` | Text file served by `MOTD` |
| `shutdown_grace` | `5` | Seconds a graceful shutdown waits for sessions to close (0..300) |
| `e2ee` | `null` | End-to-end encryption broker. Only `null` disables it (`false` is rejected). See [End-to-end encryption settings](#end-to-end-encryption-settings) and [End-to-end encryption](e2ee.md) |
| `voice` | `null` | OPUS voice messages in S3-compatible storage. `null` or `false` disables. See [Voice messages](#voice-messages) |
| `files` | `null` | File uploads in S3-compatible storage. `null` or `false` disables. See [Files](#files) |
| `tls_reload_interval` | `60` | Seconds between checks of the TLS certificate and key files (including `sni` pairs); a changed, valid pair is reloaded without a restart. `0` disables; otherwise 5..86400 |
| `admin_name`, `admin_location1`, `admin_location2`, `admin_email` | `IRC server administrator`, `Not configured`, `Not configured`, `Not configured` | Values returned by `ADMIN` |
| `reop_delay` | `30` | Base delay in seconds before re-opping an operatorless safe channel |
| `resource_delay` | `60` | Seconds a nickname or channel released by a quit or netsplit stays unavailable (437); `0` disables. The same `RECLAIM` secret or account may take a local client's nickname back at once |
| `account_password_min` | `8` | Shortest password `REGISTER` accepts, in bytes |
| `server_info` | `Erlang/OTP IRC server` | Server description in LINKS |
| `multiclient` | `false` | Let a connection logged into the same account as a nickname's holder attach to that nickname; it mirrors the holder's traffic and its QUIT closes only itself |
| `account_rejoin` | `false` | Remember a logged-in client's channels on disconnect (in memory) and rejoin them at the account's next login |
| `account_registration_before_connect` | `true` | Allow `REGISTER` before connection registration completes (`before-connect`) |
| `account_registration_email_required` | `false` | Require an email address in `REGISTER` (`email-required`) |
| `nicklen` | `9` | Longest nickname (9 to 30). RFC 1459 uses 9; every linked server must use the same value |
| `mnesia_dir` | `data/mnesia` | Mnesia database directory |
| `retention` | `channels` | `channels` or `transient`. See [Retention](#retention) and [Mnesia](mnesia.md) |
| `history_limit` | `100` | Channel `PRIVMSG`/`NOTICE` lines kept per channel when `retention` is `channels` (1..10000) |
| `server_links` | `[]` | Direct peers this process dials. See [Server links](#server-links) and [Deployment](deployment.md) |
| `search` | `null` | Message search through briskd-search: `{"url": "http://briskd-search:7700", "token" or "token_env": ..., "timeout": 3000, "max_results": 50}`. See [Message search](search.md) |
| `ws_port`, `wss_port` | `null` | IRCv3 WebSocket listeners over TCP and TLS; `null` disables |
| `ws_origins` | `null` | Allowed WebSocket `Origin` values; `null` allows any origin |
| `network` | value of `name` | `NETWORK` ISUPPORT token |
| `network_icon` | `null` | `draft/ICON` ISUPPORT URL |
| `sts` | `null` | STS policy `{"port": P, "duration": seconds, "preload": false}`. `null` disables the `sts` capability |
| `sni` | `[]` | Extra TLS certificates chosen by SNI host name, each with `hostname`, `certfile`, and `keyfile` |
| `account_registration` | `true` | Allow `REGISTER` (draft/account-registration) |
| `chathistory` | `true` | Record channel and account-to-account messages for `CHATHISTORY` (bounded by `history_limit`) |
| `features` | all `true` | Booleans `reactions`, `replies`, `typing`, `editing`, `redaction`, and `link_previews`. Omit the object to leave them on. `null` is rejected. See [Features](#features) |
| `utf8_only` | `false` | Advertise `UTF8ONLY` and reject commands whose parameters are not UTF-8 |
| `monitor_limit` | `100` | Maximum `MONITOR` targets per client |
| `webirc` | `[]` | Trusted WebIRC gateways, each with `password` and a `hosts` list of IP addresses |
| `dronebl` | `false` | DroneBL DNSBL lookup and temporary IP banning. Set to `true` for defaults or an object (`enabled`, `zone`, `timeout_ms`, `ban_ttl`, `cache_ttl`, `types`, `skip_private`, `max_entries`, `max_in_flight`) |
| `webui` | `null` | HTTP server for the browser client, admin pages, and public `/signup` and `/verify`. `null` or `false` disables it. See [Web UI](#web-ui) |
| `account_verification` | `null` | Email verification for `REGISTER`. `null` disables it. See [Account verification](#account-verification) |

Set at least one of `tcp_port`, `tls_port`, `ws_port`, or `wss_port`. TLS
uses TLS 1.2 and 1.3; configure `certfile` and `keyfile` when enabling the TLS
or secure WebSocket listener. The TLS listeners ask for an optional client
certificate. A missing or self-signed one does not fail the handshake; its
SHA-256 fingerprint is only used by SASL `EXTERNAL`. Server certificate
handling is unchanged. Port `0` requests an ephemeral port, which is reported
in the startup log.

## Server links

`server_links` is a list of peers this process dials. Each object requires
`name`, `host`, `port`, and `password`. `tls` is optional and defaults to
`false`.

```json
"server_links": [
  {
    "name": "irc.example.net",
    "host": "203.0.113.10",
    "port": 6667,
    "password": "link-secret",
    "tls": false
  }
]
```

`name` is a host-like token of at most 63 characters. It must not be this
server's `name`, and two entries must not fold to the same name (RFC 1459
case mapping). `host` is 1 to 253 bytes and must not contain a space, NUL,
CR, or LF. `port` is 1 to 65535. `password` is 1 to 400 bytes. `tls` set to
`true` dials that host with TLS and verifies its certificate. Listener and
firewall placement for peer ports is in [Deployment](deployment.md).

The `server_links` entries are the only peers this process dials. A second
connection that introduces the same adjacent name is rejected.

## Web UI

`webui` set to `null` or `false` does not open the HTTP listener. An object
requires `port` and `password`. The browser client on this listener still
needs `ws_port` or `wss_port` for its IRC connection. Using that client is
described in [WebIRC](webirc.md), which is the user page.

| Field | Default | Required |
| --- | --- | --- |
| `port` | none | yes, integer 0 to 65535 (`0` is ephemeral) |
| `password` | none | yes, 1 to 256 bytes, no NUL, CR, or LF |
| `bind` | `127.0.0.1` | no; an IP address |
| `username` | `admin` | no; 1 to 128 bytes, no NUL, colon, CR, or LF |
| `terms_url` | `https://example.com/terms` | no; `http://` or `https://`, at most 2048 bytes |
| `privacy_url` | `https://example.com/privacy` | no; same rules as `terms_url` |

Administrators sign in at `/admin/login` with `username` and `password`. The
session cookie is `HttpOnly` and `SameSite=Strict`, lasts 12 hours, and is
marked `Secure` behind a proxy that sends `X-Forwarded-Proto: https`.
Changing `username` or `password` with `REHASH` signs everyone out. Five
failed sign-ins from one address in five minutes lock that address out for
the rest of the window. Scripts may still send HTTP Basic credentials
(`curl -u`). Put the listener behind a TLS reverse proxy before exposing it
beyond loopback. Public pages on the same listener include `/signup` and
`/verify`.

## Account verification

`account_verification` set to `null` leaves `REGISTER` without email
verification. `false` is rejected. An object must include `command`, `smtp`,
or both. `ttl` is optional and defaults to `900` seconds (1 to 86400).
`verify_url` is optional: an `http://` or `https://` URL of at most 2048
bytes, with no spaces. When `webui` is enabled, `GET /verify` serves the
same check.

`command` is a non-empty array of strings. The first element is an absolute
path to a program; the rest are its arguments. Every element must be
non-empty.

`smtp` is sent with `gen_smtp`. `relay` and `from` are required. `from` must
contain `@`. The other fields:

| Field | Default | Notes |
| --- | --- | --- |
| `port` | `587` | 1 to 65535 |
| `tls` | `if_available` | `always`, `if_available`, or `never` |
| `ssl` | `false` | boolean |
| `subject` | `Verify your IRC account` | non-empty text |
| `username`, `password` | both omitted | set both, or neither; each is 1 to 256 bytes with no NUL, CR, or LF |

## End-to-end encryption settings

`e2ee` set to `null` turns the broker off. Any other non-object, including
`false`, is rejected. Every field inside the object is optional. An unknown
field is rejected. The protocol is in [End-to-end encryption](e2ee.md).

| Field | Default | Range |
| --- | --- | --- |
| `max_devices` | `8` | 1 to 32 |
| `max_prekeys` | `100` | 1 to 1000 |
| `queue_limit` | `500` | 0 to 10000 (`0` stores no offline queue) |
| `queue_ttl` | `1209600` | 60 to 7776000 seconds |
| `fetch_rate` | `30` | 1 to 1000 `E2EE FETCH` requests per connection per minute |

```json
"e2ee": {
  "max_devices": 8,
  "max_prekeys": 100,
  "queue_limit": 500,
  "queue_ttl": 1209600,
  "fetch_rate": 30
}
```

## Calls

`calls` set to `null` or `false` disables calls. An object requires
`rtpengine`, a `host:port` string for rtpengine's NG control socket (UDP).
The host is a name or an IPv4 address, and the port is 1 to 65535. The other
fields are optional. Setup and the wire protocol are in
[Voice and video calls](calls.md).

| Field | Default | Range |
| --- | --- | --- |
| `rtpengine` | none | required, `host:port` |
| `ring_timeout` | `45` | 5 to 300 seconds |
| `max_duration` | `7200` | 0 to 86400 seconds (`0` means no limit) |
| `max_calls` | `100` | 1 to 10000 |
| `calls_per_minute` | `6` | 1 to 120 |
| `require_account` | `false` | boolean |
| `video` | `true` | boolean; `false` accepts audio only |

```json
"calls": { "rtpengine": "rtpengine:2223" }
```

## Voice messages

`voice` set to `null` or `false` disables OPUS voice messages. An object
requires `endpoint`, `access_key_id`, and `secret_access_key`. `endpoint` is
an `http://` or `https://` URL. The access key and the secret are 1 to 256
bytes with no NUL, CR, or LF.

| Field | Default | Notes |
| --- | --- | --- |
| `endpoint` | none | required URL |
| `access_key_id` | none | required |
| `secret_access_key` | none | required |
| `region` | `us-east-1` | 1 to 64 bytes, `[A-Za-z0-9._-]` |
| `bucket` | `briskd-voice` | 3 to 63 bytes, lowercase DNS-style name |
| `max_bytes` | `1048576` | 1024 to 20971520 |
| `max_duration` | `120` | 1 to 600 seconds |

## Files

`files` set to `null` or `false` disables file uploads. The object has the
same required fields and the same `region` and credential rules as `voice`.
`bucket` defaults to `briskd-files`. `max_bytes` defaults to `10485760` and
must be from 1024 to 104857600. There is no `max_duration`.

```json
"files": {
  "endpoint": "https://s3.example",
  "region": "us-east-1",
  "bucket": "briskd-files",
  "access_key_id": "key-id",
  "secret_access_key": "key-secret",
  "max_bytes": 10485760
}
```

## Bots

`ai_providers` maps a provider name to an OpenAI-compatible endpoint.
`bots` is a list of assistants. Both default to empty, which runs no bots.
Names, limits, and what a bot does on IRC are in [AI assistant bots](bots.md).

A provider name matches `[A-Za-z0-9_-]{1,32}`. At most 20 providers.
`base_url` and `model` are required. `base_url` is an `http://` or `https://`
URL; a trailing `/` is stripped and `/chat/completions` is appended.
`timeout` is optional and defaults to `60` seconds (1 to 600). Set at most
one of `api_key` and `api_key_env`. With neither, no `Authorization` header
is sent. An unset or empty `api_key_env` does not refuse startup: bots that
use that provider are not started.

A bot requires `nick` and `provider` (a name from `ai_providers`). At most
50 bots, and nicks must be unique under the RFC 1459 case map. Optional
fields and their defaults:

| Field | Default |
| --- | --- |
| `user` | `bot` |
| `realname` | `AI assistant` |
| `model` | the provider's `model` |
| `system_prompt` | empty; or `system_prompt_file` instead, not both (at most 16384 bytes) |
| `channels` | `[]` (at most 50 channel names) |
| `respond_to` | `mention` (`mention` or `all`) |
| `direct_messages` | `true` |
| `context` | `conversation` (`conversation` or `channel`) |
| `history_lines` | `20` (0 to 100) |
| `max_tokens` | `512` (1 to 32768) |
| `temperature` | `0.7` (0 to 2) |
| `max_reply_lines` | `6` (1 to 30) |
| `requests_per_minute` | `10` (1 to 600) |

```json
"ai_providers": {
  "local": {
    "base_url": "http://127.0.0.1:11434/v1",
    "model": "llama3.1",
    "timeout": 60
  }
},
"bots": [
  {
    "nick": "helper",
    "provider": "local",
    "channels": ["#lobby"]
  }
]
```

## Features

`features` is an object of booleans. Omitted, or `{}`, leaves every switch
on. `null` is rejected. A non-boolean value is rejected. Keys other than
these are ignored.

| Field | Default |
| --- | --- |
| `reactions` | `true` |
| `replies` | `true` |
| `typing` | `true` |
| `editing` | `true` |
| `redaction` | `true` |
| `link_previews` | `true` |

## Server statistics in the admin panel

The WebUI admin panel's **Stats** tab charts the last 15 minutes or hour of
the server: local sessions, registered and remote users, messages and bytes
per second, accepted and refused connections, the `briskd_state` message
queue, scheduler utilization, the run queue, and VM memory. `briskd_stats`
samples every 5 seconds and keeps 720 samples (one hour) in memory, so the
history starts empty after a restart; `GET /api/stats` returns it for
signed-in administrators. Sampling reads table sizes and VM statistics only,
so it keeps working while the state process is saturated. A sustained climb
of the state queue is the overload signal: see the capacity section of
[Deployment](deployment.md).

## Changing features from the admin panel

The WebUI admin panel's **Features & Media** tab changes a set of these
settings live, without editing the file: the chat features (`features.*`),
`chathistory` and `history_limit`, the account options
(`account_registration`, `account_registration_before_connect`,
`account_registration_email_required`, `multiclient`, `account_rejoin`,
`max_accounts`), the `e2ee`, `calls`, `voice`, and `files` subsystems, DroneBL
checks (`dronebl.enabled`), `utf8_only`, `monitor_limit`, and
`resource_delay`. A change takes effect at once the way `REHASH` does
(connected clients with `cap-notify` get `CAP NEW` or `CAP DEL`), is audited
as `admin_feature_changed`, and is announced to IRC operators. It is stored
in Mnesia (`setting`) and applied over the file at startup and on every
`REHASH`, so it lasts until it is reset to the file's value in the panel. A
subsystem can be turned on there only when the file configures it (an S3
endpoint, an rtpengine address, and so on); turning one off keeps its file
settings for when it is turned back on.

## Retention

The only accepted `retention` strings are `channels` (the default) and
`transient`. Any other value is rejected at startup, as is a `history_limit`
outside 1 to 10000.

`mnesia_dir` should point to writable storage. The default `retention` value
`channels` persists WHOWAS history, safe-channel state, accounts, read markers,
ordinary channel names, topics, modes, keys, limits, access masks, channel
metadata, and the bounded channel and direct-message `PRIVMSG`/`NOTICE` history
(`history_limit` lines, default 100). `transient` clears ordinary channels,
their metadata, and message history on restart. With `chathistory` enabled (the
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

`flood` configures client flood and spam protection (`briskd_flood`). Set `"flood": null` to disable all flood limits, or pass an object overriding any of these integer fields (unknown keys are rejected):

| `flood` key | Default | Range | Description |
| --- | --- | --- | --- |
| `lines_burst` | `500` | `1..100000` | Per-connection token bucket capacity for incoming lines |
| `lines_per_second` | `50` | `1..10000` | Line tokens restored per second (`QUIT` and `PONG` cost 0) |
| `messages_burst` | `200` | `1..100000` | Per-connection token bucket capacity for messages (`PRIVMSG`, `NOTICE`, `TAGMSG`, `INVITE`, `KNOCK`, and opening a `draft/multiline` batch) |
| `messages_per_second` | `20` | `1..10000` | Message tokens restored per second (multi-target messages cost one token per target) |
| `join_burst` | `50` | `1..10000` | Per-connection token bucket capacity for channel joins |
| `join_per_minute` | `60` | `1..100000` | Channel join tokens restored per minute (one token per channel in `JOIN`) |
| `nick_burst` | `50` | `1..10000` | Per-connection token bucket capacity for post-registration `NICK` changes |
| `nick_per_minute` | `60` | `1..100000` | Nickname change tokens restored per minute |
| `register_per_minute` | `30` | `1..10000` | Per-host `REGISTER` rate limit per minute (`FAIL REGISTER TEMPORARILY_UNAVAILABLE` when exceeded) |

Local IRC operators (`+o`) are exempt from per-connection flood disconnection. Changes to `flood` take effect immediately on `REHASH`.
