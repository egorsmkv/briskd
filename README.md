# ircd

An IRC server written in Erlang/OTP, with TCP and optional TLS listeners,
Mnesia-backed state, and support for direct server links.

This is an actively developed implementation of selected parts of RFC 1459 and
RFC 2810–2813. It is not a complete implementation of those specifications.
See the [roadmap](ROADMAP.md) for current coverage and unfinished work.

## Features

- Supervised TCP and TLS listeners, client sessions, and server links.
- Client registration, messaging, user queries, and common channel commands.
- Channel modes, access lists, invitations, safe channels, and anonymous
  channels.
- Optional direct server-to-server links, including state bursts and message
  routing between directly connected servers.
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
ordinary channels are cleared on restart.

## IRC support and limitations

Implemented client commands include `PASS`, `NICK`, `USER`, `JOIN`, `PART`,
`PRIVMSG`, `NOTICE`, `TOPIC`, `NAMES`, `LIST`, `MODE`, `INVITE`, `KICK`,
`AWAY`, `WHO`, `WHOIS`, `WHOWAS`, `ISON`, `USERHOST`, `LUSERS`, `MOTD`,
`VERSION`, `TIME`, `INFO`, `ADMIN`, `LINKS`, `TRACE`, `STATS`, `SERVLIST`,
`SQUERY`, `PING`, `PONG`, `QUIT`, `OPER`, `KILL`, and `REHASH`. Capability
negotiation is limited to `CAP LS` and `CAP END`.

Channel support includes operator and voice roles, keys, limits, ban/exception/
invite masks, moderation, member-only messaging, operator-only topics, private
and secret channels, and safe `!` channels. Anonymous mode is supported on
local `&` and safe `!` channels. Visibility rules are applied to `WHO`,
`WHOIS`, and `NAMES`; user mode `+i` hides users from queries unless the
requester shares a channel.

Automated test coverage is limited. Server linking is limited to directly
connected peers. Basic bursts, selected user and channel state propagation, and
direct-peer message routing are implemented. Multi-hop routing, netsplit
handling, complete synchronization, and several remote-user operations are
still in progress. Full command, numeric, and edge-case coverage is also
unfinished; consult the [roadmap](ROADMAP.md) before relying on a specific RFC
behavior.

## Protocol references

- [RFC 1459 — Internet Relay Chat Protocol](https://www.rfc-editor.org/rfc/rfc1459)
- [RFC 2810 — Internet Relay Chat: Architecture](https://www.rfc-editor.org/rfc/rfc2810)
- [RFC 2811 — Internet Relay Chat: Channel Management](https://www.rfc-editor.org/rfc/rfc2811)
- [RFC 2812 — Internet Relay Chat: Client Protocol](https://www.rfc-editor.org/rfc/rfc2812)
- [RFC 2813 — Internet Relay Chat: Server Protocol](https://www.rfc-editor.org/rfc/rfc2813)
- [RFC 7194 — Default Port for Internet Relay Chat](https://www.rfc-editor.org/rfc/rfc7194)

## License

Licensed under the [Apache License 2.0](LICENSE.md).
