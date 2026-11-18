# ircd

An IRC server written in Erlang/OTP, with TCP and optional TLS listeners,
Mnesia-backed state, and support for direct server links.

This is an implementation of the RFC 1459 and RFC 2810–2813 behavior listed in
the [roadmap](ROADMAP.md). It does not implement IRCv3 message tags, labeled
responses, or capability families.

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
| `motd_file` | `null` | Text file served by `MOTD` |
| `admin_name`, `admin_location1`, `admin_location2`, `admin_email` | See config | Values returned by `ADMIN` |
| `reop_delay` | `30` | Base delay in seconds before re-opping an operatorless safe channel |
| `mnesia_dir` | `data/mnesia` | Mnesia database directory |
| `server_links` | `[]` | Direct peer definitions with `name`, `host`, `port`, `password`, and optional `tls` |

Set at least one of `tcp_port` or `tls_port`. TLS uses TLS 1.2 and 1.3; configure
`certfile` and `keyfile` when enabling the TLS listener. Port `0` requests an
ephemeral port, which is reported in the startup log.

`mnesia_dir` should point to writable storage. Mnesia persists WHOWAS history
and safe-channel state. Client sessions and imported peer state are transient;
ordinary channels are cleared on restart. Backup, restore, and schema
migration are described in [docs/mnesia.md](docs/mnesia.md).

## IRC support and limitations

Implemented client commands include `PASS`, `NICK`, `USER`, `JOIN`, `PART`,
`PRIVMSG`, `NOTICE`, `TOPIC`, `NAMES`, `LIST`, `MODE`, `INVITE`, `KICK`,
`AWAY`, `WHO`, `WHOIS`, `WHOWAS`, `ISON`, `USERHOST`, `LUSERS`, `MOTD`,
`VERSION`, `TIME`, `INFO`, `ADMIN`, `LINKS`, `TRACE`, `STATS`, `SERVLIST`,
`SQUERY`, `PING`, `PONG`, `QUIT`, `OPER`, `KILL`, `REHASH`, `CONNECT`,
`SQUIT`, `SERVICE`, `CAP`, `KNOCK`, `SUMMON`, `USERS`, `DIE`, and `RESTART`.
`CAP LS` and `CAP LIST` report an empty capability set, `CAP REQ` is rejected
with `NAK`, and an unknown `CAP` subcommand returns numeric 410. `SUMMON` and
`USERS` stay disabled and return numerics 445 and 446. Operator `DIE` stops
the node and operator `RESTART` restarts the runtime. Other clients receive
numeric 481.

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

This server does not implement IRCv3 message tags, labeled responses, or
capability families. `SUMMON` and `USERS` are not available as working
features. Consult the [roadmap](ROADMAP.md) for the checked coverage list.

## Protocol references

- [RFC 1459 — Internet Relay Chat Protocol](https://www.rfc-editor.org/rfc/rfc1459)
- [RFC 2810 — Internet Relay Chat: Architecture](https://www.rfc-editor.org/rfc/rfc2810)
- [RFC 2811 — Internet Relay Chat: Channel Management](https://www.rfc-editor.org/rfc/rfc2811)
- [RFC 2812 — Internet Relay Chat: Client Protocol](https://www.rfc-editor.org/rfc/rfc2812)
- [RFC 2813 — Internet Relay Chat: Server Protocol](https://www.rfc-editor.org/rfc/rfc2813)
- [RFC 7194 — Default Port for Internet Relay Chat](https://www.rfc-editor.org/rfc/rfc7194)

## License

Licensed under the [Apache License 2.0](LICENSE.md).
