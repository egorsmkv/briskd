# Benchmarks

`bench/traffic.py` drives a running server with TCP clients and writes
`bench/results/<date>.md` (JSON with `--json`). Dependencies come from
`bench/uv.lock` through `uv run --project bench --locked`. The first run
creates `bench/.venv`.

```sh
bench/scripts/run.sh            # development server, port 6667
bench/scripts/release.sh        # packaged release, port 6668
bench/scripts/prod.sh           # production image, 127.0.0.1:16667
bench/scripts/memory-prod.sh    # production image, memory samples
```

`bench/scripts/run.sh --oper NAME:PASSWORD --json bench/results/run.json` is the same
as calling `traffic.py`. Extra arguments to `bench/scripts/prod.sh` and
`bench/scripts/release.sh` are passed through. The paced load test is separate: `bench/faker_load.py`,
described in `FAKER.md`.

A traffic run measures ping latency, a registration burst, channel fan-out,
a high-load phase (10,000 clients by default; `--clients 0` skips it), and
one client sending each command family. The report adds `STATS m`, `LUSERS`,
and `docker stats` for `--container` (default `irc-server_briskd-dev_1`).

Spread the high-load clients across the two development servers with
`--targets 127.0.0.1:6667,127.0.0.1:6668`. Drop the log level below `trace`
first, or the terminal is what gets measured. Use `bench/scripts/prod.sh` for high-load
numbers; the development server registers clients much more slowly.

`bench/scripts/prod.sh` builds `docker-compose.prod.yml` and runs that image with
`config/briskd.prod.json` read-only, the MOTD, `init`, and a 65536 `nofile`
limit. Web ports are not published, and the data volume is removed
afterwards (`PROD_BENCH_PORT` changes 16667). Flood limits stay at 50 lines
per second and a 500-line burst, so the command matrix is paced at 40 lines
per second and the pipelined `PING` phase sends 400. `--pace 0` lets that
limit disconnect the matrix client. The run raises only `max_clients`
(`PROD_BENCH_MAX_CLIENTS`, default 12,000).

`bench/scripts/memory-prod.sh` samples idle, connected clients, traffic, quit, and
churn. `MEMORY_BENCH_IMAGE` measures an image that is already built. Reports
are `bench/results/<date>-memory.md` and `.json`.

A quit holds a nickname for `resource_delay` seconds (60 by default).
Nicknames are random per run. One Python process drives every client, and
its CPU is in the report: near a full core means the generator set the pace.
`--loop rsloop` uses [rsloop](https://github.com/RustedBytes/rsloop) 0.1.69;
earlier versions dropped data when a read was cancelled. Numbers include
Docker port forwarding, so compare runs on the same machine with the same
flags.
