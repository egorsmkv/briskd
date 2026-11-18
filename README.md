# ircd

IRC server written in Erlang/OTP. It uses supervised TCP and TLS listeners,
Mnesia disk-copy tables for client and channel state, and Flatlog to render OTP
Logger events inside newline-delimited JSON records.

## Run

Install Erlang/OTP 27 or later and rebar3. From the project root, run
`rebar3 shell`. The default listener is `127.0.0.1:6667`.

If `just` is installed, `just --list` shows project commands: `just build`,
`just format`, `just format-check`, `just test`, `just run`, and
`just run-config path/to/config.json`. The Erlang formatter is `erlfmt`,
available as `rebar3 fmt` after dependencies are fetched.

## Docker development environment

Build and start the development environment with Docker Compose:

```sh
docker compose -f docker-compose.dev.yml up --build
```

The container uses Erlang/OTP 29, `rebar3`, and `just`. It mounts this checkout
at `/workspace`, starts the server with `config/ircd.dev.json`, and publishes
IRC on `localhost:6667`. Rebar3's cache and the development Mnesia database use
separate named volumes. Stop the environment with `docker compose -f
docker-compose.dev.yml down`; source changes remain in the checkout.

Set `IRCD_CONFIG` to load another JSON file. The default is
`config/ircd.json`. Set either port to `null` to disable that listener.
Use `tls_port: 6697` and supply PEM certificate and key paths through
`certfile` and `keyfile` to enable direct TLS on the port registered by
[RFC 7194](https://www.rfc-editor.org/info/rfc7194/). Paths are relative to
the working directory unless absolute. The listener accepts TLS 1.2 and
1.3. A port of zero requests an ephemeral port, reported in the startup log.
`max_clients` sets the maximum number of active client sessions (default
10000). Set `client_password` to a non-empty string to require a pre-registration
`PASS` from clients; `null` disables the connection password. Changing it requires
a restart.
`reop_delay` sets the minimum number of seconds an operatorless safe channel
with `+r` waits before the server randomly grants operator status to a member
(default 30); the server adds a random delay of up to the same interval.
Configure IRC operator accounts with `operators`, an array of objects with
`name` and `password` fields. An empty array disables `OPER` authentication.
`server_links` is an array of peer definitions with `name`, `host`, `port`,
`password`, and optional `tls` fields. The server attempts outbound RFC 2813
PASS/SERVER handshakes, verifies the configured peer identity, and sends its
current client and channel snapshot. Inbound handshakes are accepted only when
the peer name and shared password match a configured `server_links` entry.
Links exchange liveness PINGs and close on a missed reply or a peer `ERROR`.
Extended peer `NICK` introductions are imported for `LUSERS` counts,
nickname collision checks, and basic `WHOIS`, `WHO`, `ISON`, and `USERHOST`
replies. New local registrations, nickname changes, `QUIT`, and `AWAY` are
propagated to directly connected peers; peer nickname changes, `QUIT`, and
`AWAY` update the imported records. Peer state is cleared when its link closes.
Invisible remote users are hidden
unless the requester shares a channel. RFC 2813 `NJOIN` membership and basic
private/secret/anonymous channel flags are imported for `NAMES` and `LUSERS`.
Channel joins, parts, topics, modes, access lists, member roles, and KICK events
propagate to directly connected peers; topics and current channel modes are
included in bursts. Direct `PRIVMSG` and `NOTICE` between local clients and
users on a directly connected peer are supported, and channel messages route
to members on direct peers with source membership checks. Multi-hop routing,
channel invitations, and other remote-user commands remain in progress.
`mnesia_dir` selects the on-disk Mnesia database directory (default
`data/mnesia`); relative paths are resolved from the working directory. Set it
to a writable persistent location to keep database files across deployments.
State tables use disk copies. Nickname history and safe channel settings persist
across restarts; transient client sessions are cleared, and non-safe channels
expire when the server restarts.
`admin_name`, `admin_location1`, `admin_location2`, and `admin_email` configure
the values returned by the local `ADMIN` query.
Set `motd_file` to a text file path to serve its lines with `MOTD`; long lines
are wrapped to 80 bytes. `null` or an unreadable path returns numeric `422`.
Paths use the same working-directory rules as TLS certificate paths.

## Protocol coverage

Client registration, nickname changes, channel joins and parts, topics,
names and channel lists, private and channel messages, WHOIS, WHOWAS, INFO, VERSION,
TIME, TRACE, STATS (`l` connections, `m` command counts, `o` operator accounts,
`u` uptime), LINKS, SERVLIST/SQUERY, ADMIN, PING/PONG,
INVITE, KICK, LUSERS, and QUIT are implemented for one server.
Transient client state lasts for a session; Mnesia persists WHOWAS history and
empty safe-channel state. Channel MODE supports operator, voice, the server-only
quiet flag, ban masks, moderation, member-only messages, operator-only topics,
keys, and limits.
Anonymous mode `+a` is supported on local `&` and safe `!` channels; only a safe
channel creator can set it, and it cannot be removed there. Messages use the RFC
anonymous prefix, and WHO, WHOIS, and NAMES avoid disclosing channel membership.
User mode `+i` hides a client from `WHO` and `NAMES` unless the requester shares
a channel with that client.
`NAMES` includes users without a visible channel and uses RFC visibility markers.
`WHO mask o` restricts results to IRC operators. `USER` honors the RFC user mode
mask for invisible (`i`) and wallops (`w`) modes; server-generated wallops for
operator KILL and REHASH actions reach clients with `+w`.
`WHOIS` reports client idle time using the RFC 2812 `317` reply.
Ban masks prevent ordinary members from speaking; operator and voice roles can
speak despite a ban. Private and secret channel modes conceal channels from
nonmember queries.
Safe channels follow RFC 2811: `JOIN !shortname` creates or finds the server's
time-identified channel name. The creator can set `+r`; the server restores an
operator after the configured delay if the channel has no operators. Clients
can use `OPER name password` with a configured account to become server
operators; operators can use `KILL nick :reason` to disconnect a local user
and `REHASH` to reload dynamic settings. `LUSERS` reports the operator count.
Listener address/port, TLS certificate, server name, and Mnesia path changes
require a restart.
Channels beginning with `+` have only the RFC-required topic restriction mode
enabled, and do not grant channel-operator status.

The remaining protocol work includes complete client command and numeric
coverage, safe-channel abuse-window rules, and server linking and
synchronization.
[RFC 1459](https://www.rfc-editor.org/info/rfc1459/)
[RFC 2810](https://www.rfc-editor.org/info/rfc2810/)
[RFC 2811](https://www.rfc-editor.org/info/rfc2811/)
[RFC 2812](https://www.rfc-editor.org/info/rfc2812/)
[RFC 2813](https://www.rfc-editor.org/info/rfc2813/)
