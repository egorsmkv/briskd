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
