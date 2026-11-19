# Benchmarks

`bench/traffic.py` drives a running server with real TCP clients and writes a
Markdown report to `bench/results/<date>.md` (and JSON with `--json`).

```sh
python3 bench/traffic.py                                   # dev server, port 6667
python3 bench/traffic.py --oper yehor:devpass --json bench/results/run.json
bench/run                                                  # same as the first line
bench/release                                              # packaged release on port 6668
```

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
`--container`, `--kind development|release`, `--warmup`.

## Notes

- Nicknames come from a time-based range because a quit holds a nickname for
  `resource_delay` seconds (60 by default).
- The bench registers one account per run (`REGISTER`) for the SASL family.
- Numbers include Docker port forwarding and the Python asyncio generator.
  Compare runs on the same machine with the same flags.
- `bench/faker_load.py` is a separate paced multi-client load test; see
  `FAKER.md`.
