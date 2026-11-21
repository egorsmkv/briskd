# Production deployment and DevOps runbook

This guide covers container and bare-metal deployment, network and firewall
planning, TLS and ACME automation, live configuration reload (`REHASH`),
structured logging and alerting, capacity tuning, and graceful shutdown.

## 1. Runtime architecture and release layout

`Dockerfile.prod` builds a self-contained OTP 29 release (`rebar3 as prod
release`, or `just release`) with the Erlang Run-Time System (ERTS) bundled and
runs it on `debian:trixie-slim` as an unprivileged user:

| Item | Production value | Notes |
| --- | --- | --- |
| User / group | `ircd:ircd` (`UID 10001`, `GID 10001`) | Fixed UID/GID so sidecars (`lego`) can write readable TLS keys |
| Release root | `/opt/ircd` | Entrypoint `/opt/ircd/bin/ircd foreground` |
| Configuration path | `IRCD_CONFIG=/etc/ircd/ircd.json` | Mounted read-only in `docker-compose.prod.yml` |
| Working / Mnesia directory | `/var/lib/ircd` (`/var/lib/ircd/mnesia`) | Persisted in the `ircd-data` volume |
| Distribution cookie | `IRCD_COOKIE` (required in prod release) | Substituted into `config/vm.prod.args.src` at boot |
| Distribution bind | `127.0.0.1` (`inet_dist_use_interface`) | Loopback only; never exposed on external interfaces |
| Stop signal | `SIGTERM` | Triggers `init:stop/0` and `ircd_shutdown` drain |

## 2. Quick start with Docker Compose

`docker-compose.prod.yml` runs the production image with `config/ircd.prod.json`
and `config/motd.txt` mounted read-only and Mnesia data in the `ircd-data`
volume:

```sh
echo "IRCD_COOKIE=$(openssl rand -hex 24)" > .env    # distribution cookie, loopback only
docker compose -f docker-compose.prod.yml up --build -d
```

Edit `config/ircd.prod.json` (`name`, `network`, `operators`, `administrators`,
`channels`, `flood`, and TLS or peer settings) and `config/motd.txt` before the
first start.

## 3. Network ports, firewalls, and gateways

Expose only the listeners enabled in your JSON configuration:

| Port | Setting | Protocol | Direction | Purpose |
| --- | --- | --- | --- | --- |
| `6667/tcp` | `tcp_port` | IRC over TCP (`STARTTLS` optional) | Inbound | Standard plaintext client port (RFC 1459 / RFC 2812) |
| `6697/tcp` | `tls_port` | IRC over implicit TLS 1.2 / 1.3 | Inbound | Standard TLS client port (RFC 7194) |
| `8080/tcp` | `ws_port` | IRCv3 WebSocket (`ws://`) | Inbound | Plaintext WebSocket (`binary.ircv3.net`, `text.ircv3.net`) |
| `8443/tcp` | `wss_port` | IRCv3 WebSocket over TLS (`wss://`) | Inbound | TLS WebSocket listener |
| `80/tcp` | `LEGO_HTTP=true` | HTTP (ACME HTTP-01) | Inbound | Used only by the optional `lego` ACME container |
| `443/tcp` | `LEGO_TLS=true` | TLS (ACME TLS-ALPN-01) | Inbound | Used only when `lego` is configured for TLS-ALPN-01 |
| Peer ports | `server_links` | RFC 2813 TCP or TLS | Inbound / Outbound | Direct server-to-server links; restrict to peer IPs in the firewall |

> [!IMPORTANT]
> Never expose the Erlang distribution port (`epmd` / dynamic distribution
> port) outside the host. `config/vm.prod.args.src` binds distribution to
> `{127,0,0,1}` and names the node `ircd@localhost`, so `/opt/ircd/bin/ircd
> ping`, `eval`, and `remote_console` work locally inside the container or host
> without listening on public interfaces. (Earlier images named the node after
> the container hostname, which resolves to the container's external address,
> and lacked `libsctp1`, whose warning corrupted the node name the release
> script reads: these commands then reported "Node is not running!".)

### WebSocket and WebIRC gateways

- **WebSocket origin validation:** When serving browser clients on `ws_port` or
  `wss_port`, set `"ws_origins": ["https://chat.example.org"]` in the JSON
  configuration so cross-origin connections without a matching `Origin` header
  receive HTTP `403 Forbidden`.
- **WebIRC reverse proxies / bouncers:** When a web gateway connects on behalf
  of users, list its IP addresses and shared secret under `"webirc"` in the
  configuration. Only connections from listed gateway IPs may send `WEBIRC` as
  their first command; a bad secret immediately closes the socket and logs
  `webirc_rejected`.

## 4. TLS certificates with lego (ACME) and live reload

[lego](https://github.com/go-acme/lego) obtains and renews certificates from
an ACME CA (Let's Encrypt by default). `docker-compose.lego.yml` adds it to
the production stack:

```sh
cp deploy/lego/lego.env.example lego.env    # set LEGO_DOMAINS, LEGO_EMAIL, the challenge
docker compose -f docker-compose.prod.yml -f docker-compose.lego.yml up -d --build
```

- The `lego` service (`goacme/lego:v5.6.0`) runs `deploy/lego/lego.sh`. Every
  `CHECK_INTERVAL` seconds (12 hours) it runs `lego run`, which obtains the
  certificate the first time and renews it when it is due. The certificate and
  key are then written to the `ircd-certs` volume as `fullchain.pem` (mode
  `0644`) and `privkey.pem` (mode `0640`, owned by `UID 10001`). Each file is
  written under a temporary name and renamed atomically, so `ircd` never reads a
  partially written file. The ACME account and lego's own copies stay in the
  `lego-data` volume.
- `ircd` starts after the first certificate exists, uses
  `config/ircd.prod.tls.json` (TLS on 6697), and mounts the volume read-only at
  `/etc/ircd/certs`.
- **Zero-downtime certificate reload:** `ircd_certs` polls `certfile`,
  `keyfile`, and every `sni` pair every `tls_reload_interval` seconds (default
  60), verifies that the private key matches the certificate, and restarts only
  the TLS listeners. Existing client and server-link TLS sessions stay connected;
  new handshakes and `STARTTLS` use the new certificate. The log records
  `cert_reloaded` (with subject names and expiry) or `cert_reload_rejected`
  (keeping the previous valid pair). Running `REHASH` triggers an immediate
  certificate check.

Challenges, chosen in `lego.env`:

| Challenge | Setting | Needs |
| --- | --- | --- |
| HTTP-01 (default) | `LEGO_HTTP=true` | Port 80 reachable from the internet; the compose file publishes it |
| TLS-ALPN-01 | `LEGO_TLS=true` | Port 443 reachable; publish `443:443` on the `lego` service |
| DNS-01 | `LEGO_DNS=<provider>` and its credentials | No inbound port; works for wildcard names. `docker run --rm goacme/lego:v5.6.0 dnshelp -c <provider>` lists the variables |

Start with `LEGO_SERVER=letsencrypt-staging`. Its certificates are not trusted
by clients, but it has much higher rate limits than production. When the
staging certificate is issued and served, set `LEGO_SERVER=letsencrypt` and
remove the `lego-data` volume (`docker volume rm <project>_lego-data`), so lego
registers with the production CA and issues a trusted certificate. Once TLS
works, configure an `sts` policy so plaintext clients automatically upgrade to
the TLS port (see [Configuration](configuration.md)).

## 5. Bare-metal / VM deployment with `systemd`

To deploy the release on a Linux host without Docker:

1. Build the release on an OTP 29.x build host (`rebar3 as prod release`) and
   install `_build/prod/rel/ircd` to `/opt/ircd`.
2. Create the system account and directories:
   ```sh
   groupadd --system --gid 10001 ircd
   useradd --system --uid 10001 --gid ircd --home-dir /var/lib/ircd --shell /usr/sbin/nologin ircd
   install -d -o ircd -g ircd -m 0750 /var/lib/ircd /var/lib/ircd/mnesia /etc/ircd
   ```
3. Place the configuration in `/etc/ircd/ircd.json` and the cookie in
   `/etc/ircd/ircd.env` (mode `0600`, owned by `ircd:ircd`):
   ```ini
   IRCD_CONFIG=/etc/ircd/ircd.json
   IRCD_COOKIE=<48-hex-char-random-cookie>
   ```
4. Install `/etc/systemd/system/ircd.service`:
   ```ini
   [Unit]
   Description=Erlang/OTP IRC Server (ircd)
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=simple
   User=ircd
   Group=ircd
   WorkingDirectory=/var/lib/ircd
   EnvironmentFile=/etc/ircd/ircd.env
   ExecStart=/opt/ircd/bin/ircd foreground
   ExecStop=/opt/ircd/bin/ircd stop
   KillMode=process
   TimeoutStopSec=30
   Restart=on-failure
   RestartSec=5
   LimitNOFILE=65536
   NoNewPrivileges=true
   PrivateTmp=true
   ProtectSystem=strict
   ProtectHome=true
   ReadWritePaths=/var/lib/ircd
   ReadOnlyPaths=/etc/ircd

   [Install]
   WantedBy=multi-user.target
   ```

## 6. Live configuration reload (`REHASH`) vs. restart

An authenticated IRC operator (`+o`) can reload `IRCD_CONFIG` without dropping
connections by sending `REHASH`. Validation runs before any change is applied:
if the JSON file has a syntax error or an out-of-range setting, `REHASH` returns
numeric `400`, logs `rehash_failed`, and keeps the running configuration.

| Reload behavior | Settings |
| --- | --- |
| **Applied live by `REHASH`** | `log_level`, `log_format`, `max_clients`, `max_sendq`, `flood`, `e2ee`, `operators`, `administrators`, `channels` (creates newly added predefined channels), `motd_file`, `admin_name`, `admin_location1`, `admin_location2`, `admin_email`, `server_info`, `reop_delay`, `resource_delay`, `retention`, `history_limit`, `chathistory`, `utf8_only`, `monitor_limit`, `nicklen`, `network`, `network_icon`, `sts`, `ws_origins`, `webirc`, `multiclient`, `account_rejoin`, `account_registration*`, `account_password_min`, `account_verification`, `tls_reload_interval`, `max_accounts`, `max_empty_channels`, `empty_channel_ttl`, `max_read_markers`, `max_direct_conversations`, `max_peer_users`, `max_peer_servers`, `max_peer_services`, and **contents** of existing `certfile`/`keyfile`/`sni` PEM files |
| **Requires a process restart** | `name`, `bind`, `tcp_port`, `tls_port`, `ws_port`, `wss_port`, `certfile`/`keyfile`/`sni` file **paths**, `mnesia_dir`, `client_password`, `server_links`, `ai_providers`, `bots`, `calls` |

When `REHASH` changes offered IRCv3 capabilities or `RPL_ISUPPORT` (`005`)
tokens (for example enabling `e2ee`, `sts`, or `utf8_only`), connected clients
with `cap-notify` or `draft/extended-isupport` are notified automatically.

## 7. Observability, logging, and healthchecks

### Structured logging and alerting

With `"log_format": "json"` (the default), every log entry is a single-line JSON
object with `time` (epoch microseconds), `level`, and the event's top-level
fields. Message bodies, passwords, verification codes, link secrets, and channel
keys (`+k`) are never logged.

Key operational and security events to index and alert on:

| `event` | Severity | Meaning and operator action |
| --- | --- | --- |
| `listener_started` | `info` | TCP/TLS/WS/WSS listener bound (`transport`, `ip`, `port`) |
| `accept_failed` | `error` | Listener socket accept error (check `ulimit -n` / `nofile` if `emfile`) |
| `session_rejected` | `warning` | Connection refused because `max_clients` was reached (`reason: max_clients`) |
| `sendq_exceeded` | `warning` | Slow client disconnected after exceeding `max_sendq` queued lines |
| `flood_exceeded` | `warning` | Client disconnected for exceeding `flood` token buckets (`category`: `lines`, `messages`, `join`, or `nick`) |
| `deferred_busy` | `warning` | 32 concurrent PBKDF2 authentication/registration workers are already in flight; extra attempts fail fast |
| `tls_handshake_failed` / `starttls_failed` | `warning` | Client TLS handshake failed (`peer`, `reason`) |
| `cert_reloaded` | `notice` | Renewed TLS certificate and key loaded live (`certfile`, `not_after`) |
| `cert_reload_rejected` | `warning` | Certificate file changed on disk but failed validation; previous certificate remains active |
| `oper_accepted` / `oper_rejected` | `info` / `warning` | `OPER` login succeeded or failed (`nick`, `account`, `reason`) |
| `oper_kill` / `oper_rehash` | `notice` | Audit log for operator `KILL` (`nick`, `target`) and `REHASH` (`nick`, `result`) |
| `rehash_failed` | `warning` | `REHASH` rejected an invalid configuration file (`reason`) |
| `webirc_accepted` / `webirc_rejected` | `info` / `warning` | WebIRC gateway accepted or rejected (`gateway`) |
| `inbound_server_link_authenticated` / `server_link_authenticated` | `notice` | Peer server link authenticated (`peer`) |
| `server_link_retry` / `link_ping_timeout` | `warning` | Outbound peer link failed or timed out (`peer`, `attempt`, `delay_ms`) |
| `invalid_remote_state` / `squit_rejected` | `warning` | Peer link sent a protocol violation and was dropped (`peer`, `reason`) |

### Healthchecks and runtime inspection

- **DevOps CLI (`ircdctl`):**
  The packaged release installs `/opt/ircd/bin/ircdctl` (also symlinked to
  `/usr/local/bin/ircdctl` in `Dockerfile.prod` and available at `bin/ircdctl`
  in the repository). It communicates with the running server over the local
  Unix domain control socket (`$IRCD_CTL_SOCKET` or `<mnesia_dir>/ircdctl.sock`,
  mode `0600`, owner-only) and supports `--json` on every command:
  ```sh
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl status
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl status --json
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl ping
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl check-config /etc/ircd/ircd.json
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl rehash
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl reload-certs
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl log-level debug
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl clients
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl kick-client spammer "Excess spam"
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl channels
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl links
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl accounts
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl create-account ops strongpass ops@example.org
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl delete-account olduser
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl set-email ops new@example.org
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl add-certfp ops <sha256-fingerprint>
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl create-channel '#help' "Ask here"
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl set-channel-modes '#help' +nt
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl set-channel-modes '#help' +b '*!*@203.0.113.*'
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl delete-channel '#old' "Channel closed"
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl backup /var/lib/ircd/backup.bup
  docker compose -f docker-compose.prod.yml exec -T ircd ircdctl drain "Maintenance"
  ```
- **Container TCP probe (`docker-compose.prod.yml`):**
  ```sh
  exec 3<>/dev/tcp/127.0.0.1/6667 && printf 'QUIT\r\n' >&3 && timeout 3 grep -q ERROR <&3
  ```
- **Release node liveness check:**
  ```sh
  docker compose -f docker-compose.prod.yml exec -T ircd /opt/ircd/bin/ircd ping
  ```
- **In-band IRC statistics:**
  - `LUSERS`: local/global users, invisible users, operators, services,servers, channels, and peak connection counts.
  - `STATS u`: server uptime.
  - `STATS m`: per-command execution count and cumulative byte volume.
  - `STATS l`: per-connection sent/received message and KiB counters and connection age (operators see all connections; non-operators see only their own).
  - `STATS o`: configured operator and administrator account names (operator-only).

## 8. Capacity planning and overload protection

- **File descriptors (`nofile`):** Size `ulimit -n` to at least
  `max_clients + 2048` to cover client sockets, listeners, peer links, Mnesia
  table files, and transient DNS/TLS sockets (`docker-compose.prod.yml` sets
  `65536`).
- **Connection and queue bounds:**
  - `max_clients` (default `10000`) rejects excess connections before allocating
    session state.
  - `max_sendq` (default `10000` lines) disconnects slow readers (`Max SendQ
    exceeded`) on both primary and attached `multiclient` sessions so stalled
    sockets cannot exhaust VM memory.
  - Outbound server links drop and reconnect with exponential backoff (5 s to
    300 s with jitter) if a peer stalls past a 30 s send timeout or 50,000
    queued lines.
  - The client listener queues up to 1024 pending connections (`backlog`,
    capped by the kernel's `net.core.somaxconn`). The previous default of 5
    made the kernel drop connection attempts when hundreds of clients
    connected at once, and their retries made registration take tens of
    seconds.
  - Each session sends one command at a time to the state process and stops
    reading its socket until it is applied, so a busy server slows clients
    down through TCP instead of queueing their input. A command not applied
    within 60 seconds means the server is overloaded: the client gets
    `ERROR :Closing Link: … (Server overloaded)` and a `command_timeout`
    warning is logged. (With the earlier 5-second default, sessions crashed
    instead, disconnecting their clients and adding work for the busy
    process.)
  - Measured with `bench/prod` (`bench/traffic.py` high-load phase): 10,000
    clients in channels of 50 sending a burst of 100,000 messages (4.9
    million deliveries) are all delivered at about 60,000 deliveries a second
    with no disconnects; delivery latency grows to tens of seconds during such
    a burst, and new clients register again about 12 seconds after it.
- **CPU and spam protection:**
  - `flood` token buckets (`ircd_flood`) cap per-client line rate, message
    fan-out, channel joins, and nickname changes, and rate-limit `REGISTER`
    per client IP/host.
  - `ircd_deferred` bounds concurrent PBKDF2 password hashing workers (SASL
    `PLAIN` and `REGISTER`) to 32 so CPU-intensive hashing never blocks the
    `ircd_state` command loop.
- **Storage and table bounds:**
  - WHOWAS is capped at 10 entries per nickname and 10,000 total.
  - Channel access lists (`+b`, `+e`, `+I`) are capped at 100 masks each.
  - Empty non-predefined channels are capped at `max_empty_channels` (default
    `1000`) and expire after `empty_channel_ttl` seconds (default `86400`).
  - Accounts (`max_accounts`), per-account read markers (`max_read_markers`),
    direct-history conversations (`max_direct_conversations`), E2EE devices/prekeys/offline queues (`e2ee`), and per-peer imported users/servers/services (`max_peer_*`) are all bounded in configuration.

## 9. Graceful shutdown

SIGTERM (`docker compose stop`, `systemctl stop`), operator `DIE` and
`RESTART`, and `application:stop(ircd)` all drain the server before it stops
(`ircd_shutdown`, called from `ircd_app:prep_stop/1`):

1. Every listener closes, so no new connection is accepted.
2. Directly linked servers receive `SQUIT <this server>` (RFC 2813 4.1.6).
3. Every client receives `NOTICE * :Server shutting down` and then
   `ERROR :Closing Link: <server> (Server shutting down)` (RFC 2812 3.7.4),
   and its socket is closed after the lines are flushed.
4. The server waits up to `shutdown_grace` seconds for sessions to finish;
   the supervisor stops any that remain. Mnesia stops after the application,
   so durable data stays consistent.

Keep the container `stop_grace_period` (or `systemd` `TimeoutStopSec`) at least
15–20 seconds higher than `shutdown_grace` (`docker-compose.prod.yml` sets
`stop_grace_period: 30s` for `shutdown_grace: 10`).
