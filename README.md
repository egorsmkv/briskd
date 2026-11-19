# ircd

An IRC server written in Erlang/OTP, with TCP, TLS, and WebSocket listeners,
Mnesia-backed state, and server links that carry bursts, multi-hop routing,
and netsplit cleanup.

This is an implementation of the RFC 1459 and RFC 2810–2813 behavior listed in
the [roadmap](ROADMAP.md), plus the IRCv3 specifications on
<https://ircv3.net/irc/>.

## Features

- Supervised TCP, TLS, and WebSocket listeners, client sessions, and server
  links.
- IRCv3: capability negotiation 302, message tags and server tags, batches,
  labeled responses, SASL and account registration, account and presence
  notifications, echo-message, chathistory, read markers, redaction,
  multiline, metadata, MONITOR, WHOX, channel rename, WEBIRC, STS, and more.
- Client registration, messaging, user queries, and common channel commands.
- Channel modes, access lists, invitations, safe channels, and anonymous
  channels.
- Server-to-server links, including bursts, multi-hop routing, invitations,
  and netsplit cleanup.
- Mnesia disk-copy tables, with persistence for WHOWAS history and safe-channel state.
- JSON logging by default, with text logging available in configuration. At
  `debug` or `trace`, each client and peer command is logged with the nick,
  command, and target. Message text, passwords, and channel keys are omitted.

## Quick start

Requirements: Erlang/OTP 29.x and Rebar3.

From the repository root:

```sh
rebar3 compile
rebar3 shell
```

The default configuration listens on `127.0.0.1:6667`. Connect with an IRC
client or a TCP client such as `nc`:

```sh
nc 127.0.0.1 6667
```

To start with another JSON configuration file, set `IRCD_CONFIG`:

```sh
IRCD_CONFIG=config/ircd.json rebar3 shell
```

## Docker development environment

Docker Compose provides OTP 29, Rebar3, and `just`, and mounts the checkout at
`/workspace`:

```sh
docker compose -f docker-compose.dev.yml up --build
```

The development server is available at `localhost:6667`, and IRC over
WebSocket at `ws://localhost:8080`. To run the container
in the background, add `-d`; then run project commands inside it, for example:

```sh
docker compose -f docker-compose.dev.yml exec -T ircd-dev just build
docker compose -f docker-compose.dev.yml exec -T ircd-dev just format-check
```

Stop the container with `docker compose -f docker-compose.dev.yml down`. The
Rebar3 cache and development database persist in named volumes. Use `down -v`
to remove those volumes and their contents.

## Project commands

If `just` is installed, `just --list` shows the available commands:

| Command | Action |
| --- | --- |
| `just build` | Compile the application and dependencies |
| `just run` | Start with `config/ircd.json` |
| `just run-config path/to/file.json` | Start with a selected configuration |
| `just format` | Format Erlang source with erlfmt |
| `just format-check` | Check Erlang formatting |
| `just xref` | Check for undefined and deprecated calls |
| `just test` | Run the EUnit suite, including the two-server interop test |
| `just deps` | Fetch Rebar3 dependencies |
| `just clean` | Remove compiled build artifacts |

## Continuous integration

GitHub Actions builds the development image from the [Dockerfile](Dockerfile)
and runs `just format-check` and `just test` in that image. The image pins the
same OTP, Rebar3, and `just` versions as local development.

## Configuration

The default configuration is [`config/ircd.json`](config/ircd.json). Set
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
| `log_format` | `json` | `json` or `text` |
| `max_clients` | `10000` | Maximum active client sessions |
| `client_password` | `null` | Optional password required with IRC `PASS` before registration |
| `operators` | `[]` | Operator accounts, each with `name` and `password` |
| `administrators` | `[]` | Operator accounts, each with `nick` and `password`. `OPER` uses `nick`. A successful login also grants channel operator on predefined channels |
| `channels` | `[]` | Channels created at startup when absent. Each entry has `name` and optional `topic`, `key`, `limit`, and `modes` |
| `motd_file` | `null` | Text file served by `MOTD` |
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
[docs/mnesia.md](docs/mnesia.md). A restored directory follows the same
retention policy as a normal start.

## IRC support and limitations

Implemented client commands include `PASS`, `NICK`, `USER`, `JOIN`, `PART`,
`PRIVMSG`, `NOTICE`, `TOPIC`, `NAMES`, `LIST`, `MODE`, `INVITE`, `KICK`,
`AWAY`, `WHO`, `WHOIS`, `WHOWAS`, `ISON`, `USERHOST`, `LUSERS`, `MOTD`,
`VERSION`, `TIME`, `INFO`, `ADMIN`, `LINKS`, `TRACE`, `STATS`, `SERVLIST`,
`SQUERY`, `PING`, `PONG`, `QUIT`, `OPER`, `KILL`, `REHASH`, `CONNECT`,
`SQUIT`, `SERVICE`, `CAP`, `TAGMSG`, `KNOCK`, `SUMMON`, `USERS`, `DIE`, and
`RESTART`. `SUMMON` and `USERS` stay disabled and return numerics 445 and 446.
Operator `DIE` stops the node and operator `RESTART` restarts the runtime.
Other clients receive numeric 481.

A client may join at most ten channels (numeric 405). A nickname or channel
released by a quit or a netsplit stays unavailable for 60 seconds (numeric
437). A nickname introduced for an existing local or remote user kills both
sides, and both peers are sent `KILL` and `QUIT`. `WHO` and `WHOIS` name a
remote user's home server. Invisible users are hidden from `WHO`, `WHOIS`, and
`NAMES` unless the requester shares a channel, including when the other user
is on another server.

Server links speak the RFC 2813 `PASS` / `SERVER` handshake and accept further
`SERVER` introductions in hop order. Nick introductions, channel membership
changes, messages, and invitations are forwarded to the other peers and are
not sent back to the link that delivered them. A newly linked server receives
the known servers, local and remote users, and channel state. `SQUIT` and a
lost link remove the users, services, and channels that were reachable only
through the lost server and tell the remaining peers. Channel invitations are
stored and forwarded after the burst.

### IRCv3

`CAP LS` advertises `account-notify`, `account-tag`, `away-notify`, `batch`,
`cap-notify`, `chghost`, `echo-message`, `extended-join`, `extended-monitor`,
`invite-notify`, `labeled-response`, `message-tags`, `multi-prefix`,
`no-implicit-names`, `sasl`, `server-time`, `setname`, `standard-replies`,
`userhost-in-names`, `sts` (when configured), `tls` (STARTTLS, on plaintext
TCP when TLS is configured), and the drafts
`draft/account-registration`, `draft/channel-rename`, `draft/chathistory`,
`draft/event-playback`, `draft/extended-isupport`, `draft/message-redaction`,
`draft/metadata-2`,
`draft/multiline`, `draft/oper-tag`, `draft/pre-away`, and
`draft/read-marker`. `CAP LS 302` shows values (`sasl` mechanisms, multiline
and metadata limits, the STS policy) and uses `*` continuation lines. Version
302 makes `cap-notify` implicit. `CAP REQ` is atomic; an unknown or
unrequestable name (`sts`) is `NAK`, and an unknown subcommand is numeric 410.
`CAP LS` or `CAP REQ` during registration holds the welcome until `CAP END`;
until then the client is not registered: other commands get 451, it is
invisible to WHOIS, WHO, ISON, and messages, and peers do not see it. A
`CAP ACK` is sent with the capabilities in force before the request.
A `REHASH` that changes the offered set sends `CAP NEW` and `CAP DEL` to
`cap-notify` clients and an updated 005 batch to `draft/extended-isupport`
clients.

Tags: server tags are placed before client-only tags. Client-only `+` tags on
`PRIVMSG`, `NOTICE`, and `TAGMSG` are relayed to
`message-tags` clients and across server links. Every message gets a `msgid`
(sent with `message-tags`) and a `time` (sent with `server-time`, which also
stamps every other line). Lines from a logged-in user carry `account`
(`account-tag`), lines from a `+B` user carry `bot`, and lines from an IRC
operator carry `draft/oper` (`draft/oper-tag`). Tag data over 4094 bytes, or a
tag section over 8191 bytes, is numeric 417. Untagged lines stay within 512
octets. With `labeled-response`, `batch`, and `message-tags`, a `label` of 1 to
64 bytes gets one labeled line, a `labeled-response` batch, or an `ACK`.

Accounts: `AUTHENTICATE` supports `PLAIN`, `EXTERNAL` (TLS client certificate
fingerprint), and `SCRAM-SHA-256`, before or after registration. `REGISTER
<account|*> <email|*> <password>` creates an account and logs in (passwords of
8 to 300 bytes; only SCRAM verifiers are stored; a TLS client certificate
presented at registration is remembered for `EXTERNAL`). With
`account_verification` set, `REGISTER` answers `VERIFICATION_REQUIRED`, the
configured program sends the code, and `VERIFY <account> <code>` completes the
account and logs in; the code expires after `ttl` seconds and is never logged. Logins send `ACCOUNT` to `account-notify` clients, JOIN carries the
account with `extended-join`, WHOIS shows 330, WHOX shows the `a` field, and
`$a:<account>` works in ban, exception, and invite lists.

Presence: `AWAY` is sent to `away-notify` clients (and after a JOIN);
`draft/pre-away` allows `AWAY` before registration. `SETNAME :<realname>`
changes the realname (at most 200 bytes, `NAMELEN`). Operators can run
`CHGHOST <nick> <user> <host>`; `chghost` clients see `CHGHOST` and others see
QUIT and JOIN. User mode `+B` marks a bot (`BOT=B`, WHOIS 335, WHO flag `B`).
`MONITOR` (limit `monitor_limit`) reports online and offline nicknames;
`extended-monitor` adds away, account, host, and realname changes.

Messages: `echo-message` returns the sender's own messages with their
`msgid`. `draft/multiline` batches (up to 4096 bytes and 100 lines) are
delivered as batches to capable clients and as separate lines to others.
`CHATHISTORY` (`BEFORE`, `AFTER`, `LATEST`, `AROUND`, `BETWEEN`, `TARGETS`,
by `timestamp=` or `msgid=`) returns history in a `chathistory` batch.
Channel history is available to current members. Direct-message history is
kept only between two logged-in accounts. Clients with `draft/event-playback`
also get JOIN, PART, KICK, TOPIC, MODE, QUIT, NICK, and TAGMSG events. `MARKREAD` stores read
markers per account and sends them after a JOIN. `REDACT <target> <msgid>
[:reason]` removes a message from history and tells
`draft/message-redaction` clients; the sender's account or a channel operator
may redact.

Channels and queries: `multi-prefix` and `userhost-in-names` change NAMES,
WHO, and WHOIS prefixes; `no-implicit-names` drops the NAMES after JOIN; WHOX
(`WHO <mask> %<fields>[,<token>]`) answers with numeric 354;
`invite-notify` tells channel members (operators only on `+i` channels) about
invitations. `RENAME <old> <new> [:reason]` renames a local channel (same
type prefix, not `!`, not shared with a peer); clients without
`draft/channel-rename` see PART and JOIN. `METADATA` stores public user and
channel keys (`draft/metadata-2`, local to this server).

Connections: `WEBIRC <password> <gateway> <hostname> <ip> [:options]` is
accepted as the first command from a configured gateway address; a bad
password gets `ERROR` and the connection closes. The gateway's own TLS
certificate is never used for SASL `EXTERNAL`; a `certfp-sha-256=` option
from a `secure` gateway is. With `utf8_only`, invalid UTF-8 arriving from a
peer is replaced with U+FFFD before local delivery. `ws_port` and `wss_port`
serve IRC over WebSocket with the `binary.ircv3.net` and `text.ircv3.net`
subprotocols. Registration sends RPL_ISUPPORT (005) with `CASEMAPPING`,
`CHANTYPES`, `PREFIX`, `MONITOR`, `WHOX`, `BOT`, `CHATHISTORY`,
`MSGREFTYPES`, `EXTBAN`, `ACCOUNTEXTBAN`, `NAMELEN`, `UTF8ONLY` (when set),
and `draft/ICON` (when set). `ISUPPORT` returns the same list, also before
registration with `draft/extended-isupport`. A server split sends the QUITs in
one `netsplit` batch, and users that arrive in a peer burst appear in a
`netjoin` batch.

Over server links, accounts (SCRAM verifiers, not email addresses), user and
channel metadata, read markers, `ACCOUNT`, `SETNAME`, `CHGHOST`, `REDACT`,
user mode `B`, and the `msgid` and `time` of messages are propagated in the
burst and as they change. When two servers hold the same account name, the
one created first wins. `STARTTLS` (deprecated by IRCv3) upgrades a plaintext
TCP connection before registration; prefer `tls_port` and STS.

`SUMMON` and `USERS` are not available as working features. Consult the
[roadmap](ROADMAP.md) for the checked coverage list.

## IRCv3 conformance with irctest

`test/irctest/ircd_controller.py` runs [irctest](https://github.com/progval/irctest)
against this server, starting a fresh server for every test inside a helper
container with `test/irctest/ircd.json`:

```sh
docker compose -f docker-compose.dev.yml run -d --rm -p 6667:6667 \
    --name ircd-irctest ircd-dev sleep infinity
docker exec -w /workspace ircd-irctest rebar3 compile
cd /path/to/irctest
PYTHONPATH=/path/to/irc-server/test/irctest IRCTEST_SERVER_HOSTNAME=localhost \
    IRCTEST_SERVER_PORT=6667 pytest --controller ircd_controller \
    -m "not implementation-specific and not deprecated"
```

The controller stands in for services: it links a minimal
`My.Little.Services` peer over RFC 2813 and provisions test accounts with
`ACCOUNTSYNC`. `test/irctest/ircd.json` enables the opt-in `multiclient` and
`account_rejoin` features, a 30-character `nicklen`, and no nickname delay,
because irctest reuses nicknames between tests. With irctest's standard
selection (`-m "not implementation-specific and not deprecated"`) all 491
applicable tests pass.

## Protocol references

- [RFC 1459 — Internet Relay Chat Protocol](https://www.rfc-editor.org/rfc/rfc1459)
- [RFC 2810 — Internet Relay Chat: Architecture](https://www.rfc-editor.org/rfc/rfc2810)
- [RFC 2811 — Internet Relay Chat: Channel Management](https://www.rfc-editor.org/rfc/rfc2811)
- [RFC 2812 — Internet Relay Chat: Client Protocol](https://www.rfc-editor.org/rfc/rfc2812)
- [RFC 2813 — Internet Relay Chat: Server Protocol](https://www.rfc-editor.org/rfc/rfc2813)
- [RFC 7194 — Default Port for Internet Relay Chat](https://www.rfc-editor.org/rfc/rfc7194)
- [IRCv3 Capability Negotiation](https://ircv3.net/specs/extensions/capability-negotiation.html)
- [IRCv3 Message Tags](https://ircv3.net/specs/extensions/message-tags.html)
- [IRCv3 Labeled Responses](https://ircv3.net/specs/extensions/labeled-response.html)
- [IRCv3 specification index](https://ircv3.net/irc/)

## License

Licensed under the [Apache License 2.0](LICENSE.md).
