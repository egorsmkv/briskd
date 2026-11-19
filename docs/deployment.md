# Production deployment

`Dockerfile.prod` builds the release (ERTS included) and runs it as an
unprivileged `ircd` user on `debian:trixie-slim`. `docker-compose.prod.yml`
runs that image with `config/ircd.prod.json` and `config/motd.txt` mounted
read-only and Mnesia data in the `ircd-data` volume.

```sh
echo "IRCD_COOKIE=$(openssl rand -hex 24)" > .env    # distribution cookie, loopback only
docker compose -f docker-compose.prod.yml up --build -d
```

Set the server name, operators, channels, and (for TLS) certificate paths in
`config/ircd.prod.json` before the first start. The healthcheck connects and
expects `ERROR` after `QUIT`.

## TLS certificates with lego

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
  key are then written to the `ircd-certs` volume as `fullchain.pem` and
  `privkey.pem` (mode 0640, owned by the `ircd` user, UID 10001). Each file is
  written under a temporary name and renamed, so ircd never reads half a file.
  The ACME account and lego's own copies stay in the `lego-data` volume.
- `ircd` starts after the first certificate exists, uses
  `config/ircd.prod.tls.json` (TLS on 6697), and mounts the volume read-only at
  `/etc/ircd/certs`.
- A renewed certificate is loaded without a restart: `ircd_certs` checks the
  files every `tls_reload_interval` seconds (60), checks that the key matches
  the certificate, and restarts only the TLS listeners. Established connections
  stay up; new handshakes and `STARTTLS` get the new certificate. The log shows
  `cert_reloaded` with the names and expiry, or `cert_reload_rejected` when the
  new files do not form a valid pair (the old certificate stays in use).
  `REHASH` checks at once.

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
works, consider an `sts` policy in the server configuration so clients upgrade
to the TLS port (see [Configuration](configuration.md)).

## Graceful shutdown

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

The compose file allows 30 seconds (`stop_grace_period`), more than the
`shutdown_grace` of 10 in `ircd.prod.json`.
