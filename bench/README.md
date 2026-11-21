# Benchmarks

`bench/traffic.py` drives a running server with real TCP clients and writes a
Markdown report to `bench/results/<date>.md` (and JSON with `--json`).

The bench is a [uv](https://docs.astral.sh/uv/) project: `pyproject.toml`
pins its dependencies, `uv.lock` pins every version and hash, and
`.python-version` pins the interpreter (uv downloads it when missing). The
scripts run everything through `uv run --project bench --locked`, which
creates `bench/.venv` on first use; there is nothing to install by hand.

```sh
bench/run                                                  # dev server, port 6667
bench/run --oper yehor:devpass --json bench/results/run.json
bench/release                                              # packaged release on port 6668
bench/prod                                                 # production image on port 16667
uv run --project bench python bench/faker_load.py          # paced load test (FAKER.md)
```

`bench/prod` builds the production image from `docker-compose.prod.yml`
(`Dockerfile.prod`) and runs it as that compose file does: the same image,
`config/ircd.prod.json` unchanged and read-only, the MOTD, `init`, and a
65536 `nofile` limit. The only differences keep a running dev server
undisturbed: the IRC port is published on `127.0.0.1:16667`
(`PROD_BENCH_PORT`), the web ports are not published, and the data volume is
a fresh one removed afterwards. It runs `traffic.py --kind production
--warmup 50` and then `faker_load.py --kind production`, writes
`bench/results/<date>-prod.md`, `-prod.json`, and `-prod-faker-load.json`,
and prints the server's warning and error events by name. Extra arguments
go to `traffic.py`. The production configuration's flood limits stay in
force (50 lines per second per client, 500-line burst), so `bench/prod`
paces the command matrix at 40 lines per second (`--pace 40`; the pause is
outside the measured latency) and sends 400 pipelined `PING`s
(`--flood 400`). With `--pace 0` the limit disconnects the matrix client;
its family is reported with the error and the rest as skipped.

## Phases

1. Sequential `PING`/`PONG` latency and pipelined `PING` throughput.
2. A registration burst (`NICK`/`USER` to `001`) at the given concurrency.
3. Channel `PRIVMSG` fan-out between `--members` clients.
4. The command matrix (`bench/commands.py`): every client command family is
   sent `--commands` times by one client, each followed by `PING <marker>`.
   The latency is the time until that `PONG`, so it covers the server fully
   processing the command and sending all replies, including commands that
   have no reply. Families: PING, CAP, ISUPPORT, PRIVMSG/NOTICE/TAGMSG to a
   user and a channel, a `draft/multiline` batch, JOIN+PART, TOPIC, NAMES,
   LIST, channel and user MODE, INVITE, WHO, WHOX, WHOIS, WHOWAS, ISON,
   USERHOST, AWAY, SETNAME, NICK, MONITOR, METADATA, CHATHISTORY, MARKREAD,
   RENAME, LUSERS, MOTD, VERSION, TIME, INFO, ADMIN, LINKS, STATS, SERVLIST,
   SASL `AUTHENTICATE PLAIN`, and PRIVMSG followed by REDACT. With `--oper
   NAME:PASSWORD` also OPER, WALLOPS, TRACE, and `STATS l`.
   Errors count 4xx/5xx numerics, `FAIL` replies, and timeouts; 422 (no MOTD
   file) is not counted. The first examples are listed under the table.

## Server statistics

The report ends with the server's own view of the run:

- `STATS m` read before and after, shown as a per-command delta (count,
  bytes received, average size). This includes every client the bench used.
- `STATS u` uptime and the `LUSERS` replies (users, operators, channels, local
  and global current and maximum users).
- Container CPU, memory, processes, and network I/O from `docker stats`,
  sampled once per second for the whole run (`--container`, default
  `irc-server_ircd-dev_1`).

## Flags

`--host`, `--port`, `--pings`, `--flood`, `--registrations`, `--concurrency`,
`--members`, `--each`, `--commands` (iterations per family, 0 skips the
matrix), `--oper NAME:PASSWORD`, `--timeout`, `--output`, `--json`,
`--container`, `--kind development|release|production`, `--warmup`,
`--pace` (lines per second for the command matrix client; 0, the default,
does not pace).

## Notes

- Nicknames come from a time-based range because a quit holds a nickname for
  `resource_delay` seconds (60 by default).
- The bench registers one account per run (`REGISTER`) for the SASL family.
- Numbers include Docker port forwarding and the Python asyncio generator.
  Compare runs on the same machine with the same flags.
- `bench/faker_load.py` is a separate paced multi-client load test; see
  `FAKER.md`.

## Memory

`bench/memory-prod` builds the production image (or measures
`MEMORY_BENCH_IMAGE`) and runs `bench/memory.py` against it: idle, N
registered clients in channels, after channel traffic, after everyone quits,
and churn rounds of connect/join/message/quit. Each sample is the node's own
view (`erlang:memory/0`, session processes and the binaries they reference,
the largest ETS tables and registered processes), read with `erl_call` after a
full garbage collection, once the sessions' mailboxes are empty. Process
memory that does not return to idle after churn points at a leak; ETS growth
across rounds is retained history and WHOWAS, which are capped. Defaults:
1000 clients, channels of 50, 10 messages each at 0.5 per second (a sustained
load, about 25,000 deliveries a second), 3 rounds of 500. Reports go to
`bench/results/<date>-memory.md` and `.json`.
