# ircd

An IRC server written in Erlang/OTP, with TCP and optional TLS listeners,
Mnesia-backed state, and server links that carry bursts, multi-hop routing,
and netsplit cleanup.

This is an implementation of the RFC 1459 and RFC 2810–2813 behavior listed in
the [roadmap](ROADMAP.md), plus a small IRCv3 subset: capability negotiation,
message tags, and labeled responses. The other specifications on
<https://ircv3.net/irc/> are not implemented.

## Features

- Supervised TCP and TLS listeners, client sessions, and server links.
- Client registration, messaging, user queries, and common channel commands.
- Channel modes, access lists, invitations, safe channels, and anonymous
  channels.
- Server-to-server links, including bursts, multi-hop routing, invitations,
  and netsplit cleanup.
- Mnesia disk-copy tables, with persistence for WHOWAS history and safe-channel state.
- JSON logging by default, with text logging available in configuration.

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

The development server is available at `localhost:6667`. To run the container
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
| `just test` | Run the EUnit suite |
| `just deps` | Fetch Rebar3 dependencies |
| `just clean` | Remove compiled build artifacts |

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
| `log_level` | `info` | OTP logger level |
| `log_format` | `json` | `json` or `text` |
| `max_clients` | `10000` | Maximum active client sessions |
| `client_password` | `null` | Optional password required with IRC `PASS` before registration |
| `operators` | `[]` | Operator accounts, each with `name` and `password` |
| `administrators` | `[]` | Operator accounts, each with `nick` and `password`. `OPER` uses `nick`. A successful login also grants channel operator on predefined channels |
| `channels` | `[]` | Channels created at startup when absent. Each entry has `name` and optional `topic`, `key`, `limit`, and `modes` |
| `motd_file` | `null` | Text file served by `MOTD` |
| `admin_name`, `admin_location1`, `admin_location2`, `admin_email` | See config | Values returned by `ADMIN` |
| `reop_delay` | `30` | Base delay in seconds before re-opping an operatorless safe channel |
| `mnesia_dir` | `data/mnesia` | Mnesia database directory |
| `retention` | `transient` | `transient` or `channels`. `channels` keeps ordinary channel state and channel message history across a restart |
| `history_limit` | `100` | Channel `PRIVMSG`/`NOTICE` lines kept per channel when `retention` is `channels` (1..10000) |
| `server_links` | `[]` | Direct peer definitions with `name`, `host`, `port`, `password`, and optional `tls` |

Set at least one of `tcp_port` or `tls_port`. TLS uses TLS 1.2 and 1.3; configure
`certfile` and `keyfile` when enabling the TLS listener. Port `0` requests an
ephemeral port, which is reported in the startup log.

`mnesia_dir` should point to writable storage. The default `retention` value
`transient` persists WHOWAS history and safe-channel state, and clears ordinary
channels on restart. `channels` also keeps ordinary channel names, topics,
modes, keys, limits, access masks, and a bounded channel `PRIVMSG`/`NOTICE`
history (`history_limit` lines, default 100). A joining client receives that
history after the restart. Client sessions, operator status, and imported peer
state are cleared on restart in both modes. Message bodies are not written to
the log. An invalid `retention` or `history_limit` is rejected at startup.

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

IRCv3 support is limited to capability negotiation, message tags, and labeled
responses. `CAP LS` and `CAP LIST` advertise only `batch`, `cap-notify`,
`labeled-response`, and `message-tags`. `CAP LS 302` (or any higher version)
keeps version 302 for the rest of the connection: `cap-notify` is implicit and
cannot be disabled, and a long list uses a `*` continuation. Clients that never
send version 302 may disable `cap-notify`. `CAP REQ` is atomic. An unknown
capability, including `sasl`, is `NAK`, and an unknown subcommand returns
numeric 410. `CAP LS` or `CAP REQ` during registration holds the welcome
numerics until `CAP END`.

A client that has negotiated `message-tags` may send client-only tags (keys
that begin with `+`) on `PRIVMSG`, `NOTICE`, and `TAGMSG`. Those tags are
relayed to other clients who also negotiated `message-tags`, including across
a direct server link. Tags without `+`, including `label`, are not relayed.
`TAGMSG` follows the same channel membership and mode rules as `PRIVMSG` and
is not sent to a client that did not negotiate `message-tags`. Tag data longer
than 4094 bytes, or a tag section longer than 8191 bytes, is rejected with
numeric 417 and is not delivered. Untagged lines stay at most 512 octets
including CRLF. A client that has `labeled-response`, `batch`, and
`message-tags` enabled can put a `label` tag of 1 to 64 bytes on a command.
One reply line carries that label; several reply lines are one
`labeled-response` batch; a command with no reply gets one labeled `ACK`.

`SUMMON` and `USERS` are not available as working features. SASL, accounts,
`server-time`, `echo-message`, and the other specifications on
<https://ircv3.net/irc/> are not implemented. Consult the
[roadmap](ROADMAP.md) for the checked coverage list.

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

## License

Licensed under the [Apache License 2.0](LICENSE.md).
