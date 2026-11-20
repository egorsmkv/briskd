#!/usr/bin/env python3
"""Drive a running ircd with real TCP clients and write a short result note.

Usage, from the repository root, while the server is listening:

    python3 bench/traffic.py
    python3 bench/traffic.py --host 127.0.0.1 --port 6667
    python3 bench/traffic.py --oper yehor:devpass --json bench/results/run.json

Phases: sequential and pipelined PING, a registration burst, channel fan-out,
and a per-command matrix (see bench/commands.py) that times every client
command family. The report also carries the server's own statistics for the
run: the `STATS m` per-command delta, uptime, LUSERS, and container CPU and
memory sampled once per second. `--oper` adds operator-only commands.

The default target is the development listener on port 6667. `bench/release`
starts a packaged release on port 6668 and passes `--kind release`. Each run
uses a fresh nick prefix because a quit holds that nick for 60 seconds.
"""

import argparse
import asyncio
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

import commands as bench_commands  # noqa: E402  (bench/commands.py, same directory)


def percentile(samples, pct):
    if not samples:
        return None
    ordered = sorted(samples)
    index = min(len(ordered) - 1, max(0, round((pct / 100) * (len(ordered) - 1))))
    return ordered[index]


def fmt_ms(seconds):
    if seconds is None:
        return "n/a"
    return f"{seconds * 1000:.2f} ms"


def fmt_rate(count, elapsed):
    if elapsed <= 0:
        return "n/a"
    return f"{count / elapsed:.1f}/s"


async def open_client(host, port):
    return await asyncio.open_connection(host, port)


async def read_until(reader, needle, timeout):
    buf = b""
    deadline = time.perf_counter() + timeout
    while needle not in buf:
        remaining = deadline - time.perf_counter()
        if remaining <= 0:
            raise TimeoutError(f"missing {needle!r} in {buf[:180]!r}")
        chunk = await asyncio.wait_for(reader.read(65536), remaining)
        if not chunk:
            raise EOFError(f"closed before {needle!r}")
        buf += chunk
    return buf


async def register(host, port, nick, timeout):
    started = time.perf_counter()
    reader, writer = await open_client(host, port)
    writer.write(f"NICK {nick}\r\nUSER {nick} 0 * :bench\r\n".encode())
    await writer.drain()
    buf = await read_until(reader, b" 001 ", timeout)
    return reader, writer, time.perf_counter() - started, buf


async def quit_client(writer):
    try:
        writer.write(b"QUIT :bench\r\n")
        await writer.drain()
        writer.close()
        await writer.wait_closed()
    except Exception:
        pass


def nick_for(base, index):
    # Nine-character RFC 1459 nick: a letter plus eight digits.
    return f"b{(base + index) % 100_000_000:08d}"


async def ping_latency(reader, writer, samples):
    delays = []
    errors = 0
    for index in range(samples):
        token = f"t{index}"
        started = time.perf_counter()
        writer.write(f"PING {token}\r\n".encode())
        await writer.drain()
        try:
            await read_until(reader, token.encode(), 5)
            delays.append(time.perf_counter() - started)
        except (TimeoutError, EOFError, asyncio.TimeoutError):
            errors += 1
            break
    return delays, errors


async def ping_flood(reader, writer, count):
    started = time.perf_counter()
    payload = b"".join(f"PING f{index}\r\n".encode() for index in range(count))
    writer.write(payload)
    await writer.drain()
    seen = 0
    buf = b""
    deadline = time.perf_counter() + 30
    while seen < count:
        remaining = deadline - time.perf_counter()
        if remaining <= 0:
            break
        try:
            chunk = await asyncio.wait_for(reader.read(65536), remaining)
        except (TimeoutError, asyncio.TimeoutError):
            break
        if not chunk:
            break
        buf += chunk
        seen = buf.count(b"PONG")
    return seen, time.perf_counter() - started


async def registration_burst(host, port, base, count, concurrency, timeout, index_offset=0):
    delays = []
    errors = []
    semaphore = asyncio.Semaphore(concurrency)
    started = time.perf_counter()

    async def one(index):
        async with semaphore:
            nick = nick_for(base, index_offset + index)
            try:
                _reader, writer, delay, _buf = await register(host, port, nick, timeout)
                delays.append(delay)
                await quit_client(writer)
            except Exception as exc:
                errors.append(f"{nick}: {type(exc).__name__}: {exc}")

    await asyncio.gather(*(one(index) for index in range(count)))
    return delays, errors, time.perf_counter() - started


async def channel_fanout(host, port, base, members, each, timeout):
    clients = []
    try:
        for index in range(members):
            nick = nick_for(base, 50_000_000 + index)
            reader, writer, _delay, _buf = await register(host, port, nick, timeout)
            writer.write(b"JOIN #bench\r\n")
            await writer.drain()
            await read_until(reader, b"JOIN #bench", timeout)
            clients.append((reader, writer))
        received = 0
        lock = asyncio.Lock()
        stop = asyncio.Event()

        async def collect(reader):
            nonlocal received
            buf = b""
            while not stop.is_set():
                try:
                    chunk = await asyncio.wait_for(reader.read(65536), 0.2)
                except (TimeoutError, asyncio.TimeoutError):
                    continue
                if not chunk:
                    return
                buf += chunk
                found = buf.count(b"PRIVMSG #bench")
                if found:
                    async with lock:
                        received += found
                    buf = b""

        tasks = [asyncio.create_task(collect(reader)) for reader, _writer in clients]
        payload = b"".join(b"PRIVMSG #bench :x\r\n" for _ in range(each))
        started = time.perf_counter()
        for _reader, writer in clients:
            writer.write(payload)
            await writer.drain()
        expected = members * each * (members - 1)
        deadline = time.perf_counter() + 30
        while received < expected and time.perf_counter() < deadline:
            await asyncio.sleep(0.05)
        elapsed = time.perf_counter() - started
        stop.set()
        await asyncio.gather(*tasks, return_exceptions=True)
        return {
            "members": members,
            "sent": members * each,
            "expected": expected,
            "received": received,
            "elapsed": elapsed,
        }
    finally:
        for _reader, writer in clients:
            await quit_client(writer)


def container_sample(name):
    try:
        text = subprocess.check_output(
            [
                "docker",
                "stats",
                "--no-stream",
                "--format",
                "{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}",
                name,
            ],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=10,
        ).strip()
        return text or "container sample unavailable"
    except (subprocess.SubprocessError, OSError):
        return "container sample unavailable"


def otp_command(kind, container):
    evaluate = (
        'io:format("~s ~s~n",[erlang:system_info(otp_release), '
        "erlang:system_info(version)]), halt()."
    )
    if kind == "production":
        # The production image runs the release from /opt/ircd; its
        # start_erl.data names the bundled ERTS and the release version.
        return [
            "docker",
            "exec",
            container,
            "sh",
            "-c",
            'set -- $(cat /opt/ircd/releases/start_erl.data); echo "ERTS $1, release $2"',
        ]
    if kind == "release":
        # A second emulator in the release container. halt/0 stops only that one.
        # Distribution rpc is not used: the release binds distribution to loopback
        # and the generated nodetool ping does not reach it.
        return [
            "docker",
            "exec",
            container,
            "sh",
            "-c",
            "BINDIR=$(echo /workspace/_build/prod/rel/ircd/erts-*/bin); "
            "ROOTDIR=/workspace/_build/prod/rel/ircd; "
            "export ROOTDIR BINDIR EMU=beam PROGNAME=erl; "
            '"$BINDIR/erlexec" -noshell -boot /usr/local/lib/erlang/bin/start_clean '
            "-eval 'io:format(\"~s ~s~n\",[erlang:system_info(otp_release), "
            "erlang:system_info(version)]), halt().'",
        ]
    return [
        "docker-compose",
        "-f",
        "docker-compose.dev.yml",
        "exec",
        "-T",
        "ircd-dev",
        "erl",
        "-noshell",
        "-eval",
        evaluate,
    ]


def otp_version(kind, container):
    try:
        text = subprocess.check_output(
            otp_command(kind, container),
            text=True,
            cwd=ROOT,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
        return " ".join(text.split())
    except (subprocess.SubprocessError, OSError, IndexError):
        return "unavailable"


def preamble(report):
    stats = f"One container sample taken during registration: `{report['stats']}`."
    otp = f"OTP/ERTS: `{report['otp']}`."
    if report["kind"] == "production":
        lines = [
            "This is the production image (`Dockerfile.prod`: the release with",
            "ERTS included, on Debian slim) run as `docker-compose.prod.yml` runs it:",
            "`config/ircd.prod.json` unchanged (flood limits, DroneBL, `channels`",
            "retention, JSON info logging), `ulimit -n` 65536, `init`, and a fresh",
            "data volume. Only the published host port differs (`bench/prod`).",
            "Load generator: host CPython asyncio through the published port.",
            stats,
            otp,
        ]
        if report["warmup"]:
            lines.append(
                f"Warmed up with {report['warmup']} registrations before the measured phases."
            )
        return lines
    if report["kind"] == "release":
        lines = [
            "This is a packaged release (`rebar3 as prod release`, ERTS included),",
            "started with `_build/prod/rel/ircd/bin/ircd foreground`.",
            "`IRCD_CONFIG` is the release copy of `bench/release.json` (port 6668,",
            "Mnesia directory `/tmp/ircd-release-mnesia`).",
            "Load generator: host CPython asyncio through the published port.",
            stats,
            otp,
        ]
        if report["warmup"]:
            lines.append(
                f"Warmed up with {report['warmup']} registrations before the measured phases."
            )
        return lines
    return [
        "This is the development server (`rebar3 shell` in the OTP 29 container),",
        "not a packaged release. One container sample taken during registration:",
        f"`{report['stats']}`. OTP: `{report['otp']}`.",
    ]


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    ping = report["ping"]
    flood = report["flood"]
    regs = report["regs"]
    channel = report["channel"]
    lines = [
        "# ircd bench",
        "",
        f"Measured {report['when']} against `{report['host']}:{report['port']}`.",
        f"Welcome numeric: `{report['welcome'].strip()}`.",
        "",
        *preamble(report),
        "",
        "## Traffic",
        "",
        f"- Sequential `PING`/`PONG`, {len(ping['delays'])} samples, {ping['errors']} errors.",
        f"  p50 {fmt_ms(percentile(ping['delays'], 50))}, "
        f"p95 {fmt_ms(percentile(ping['delays'], 95))}, "
        f"p99 {fmt_ms(percentile(ping['delays'], 99))}.",
        f"- Pipelined `PING`, {flood['seen']} of {flood['count']} `PONG` replies "
        f"in {flood['elapsed']:.3f}s ({fmt_rate(flood['seen'], flood['elapsed'])}).",
        f"- Registration, {len(regs['delays'])} welcomes of {regs['count']} attempts, "
        f"concurrency {regs['concurrency']}, {regs['elapsed']:.3f}s "
        f"({fmt_rate(len(regs['delays']), regs['elapsed'])}). "
        f"Welcome p50 {fmt_ms(percentile(regs['delays'], 50))}, "
        f"p95 {fmt_ms(percentile(regs['delays'], 95))}. "
        f"Errors: {len(regs['errors'])}.",
        f"- Channel `PRIVMSG`: {channel['members']} members, {channel['sent']} messages sent, "
        f"{channel['received']} of {channel['expected']} deliveries "
        f"in {channel['elapsed']:.3f}s "
        f"({fmt_rate(channel['received'], channel['elapsed'])} deliveries).",
        "",
        "A sender does not receive its own channel message, so the expected",
        "delivery count is `members * messages_each * (members - 1)`.",
        "Clients quit at the end of each phase. Nicks stay reserved for 60 seconds.",
        "",
    ]
    if regs["errors"]:
        lines.extend(["## Registration errors", "", "```", *regs["errors"][:8], "```", ""])
    lines.extend(command_section(report))
    lines.extend(server_section(report))
    path.write_text("\n".join(lines), encoding="utf-8")


def command_section(report):
    rows = report.get("commands") or []
    if not rows:
        return []
    out = [
        "## Commands",
        "",
        f"Each family runs {report['iterations']} times on one client, each followed by",
        "`PING <marker>`; latency is the time until that PONG, so it covers the whole",
        "reply. Errors count 4xx/5xx numerics, `FAIL` replies, and timeouts.",
        *(
            [
                f"The client is paced to at most {report['pace']:g} lines per second (below",
                "the server's flood limit); the pause is outside the measured latency, so",
                "ops/s reflects the pacing, not the server's capacity.",
            ]
            if report.get("pace")
            else []
        ),
        "",
        "| Command | Runs | ops/s | p50 | p95 | p99 | max | Errors |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        out.append(
            f"| {row['command']} | {row['iterations']} | {row['ops_per_s']:.1f} | "
            f"{fmt_ms(row['p50'])} | {fmt_ms(row['p95'])} | {fmt_ms(row['p99'])} | "
            f"{fmt_ms(row['max'])} | {row['errors']} |"
        )
    failing = [row for row in rows if row["examples"]]
    if failing:
        out.extend(["", "Error examples:", ""])
        for row in failing:
            for example in row["examples"]:
                out.append(f"- {row['command']}: `{example}`")
    out.append("")
    return out


def server_section(report):
    server = report.get("server")
    if not server:
        return []
    out = ["## Server statistics", ""]
    if server.get("uptime"):
        out.append(f"- Uptime (`STATS u`): {server['uptime']}.")
    for line in server.get("lusers", []):
        out.append(f"- LUSERS {line}")
    container = server.get("container", {})
    if container.get("samples"):
        out.append(
            f"- Container over the run ({container['samples']} samples): CPU "
            f"avg {container['cpu_avg']:.1f}%, max {container['cpu_max']:.1f}%; memory "
            f"min {container['mem_min_mib']:.1f} MiB, max {container['mem_max_mib']:.1f} MiB; "
            f"processes max {container['pids_max']}; network I/O at end {container['net_last']}."
        )
    delta = server.get("delta", {})
    if delta:
        total = sum(v["count"] for v in delta.values())
        total_bytes = sum(v["bytes"] for v in delta.values())
        out.extend(
            [
                "",
                f"`STATS m` delta for this run: {total} commands, {total_bytes} bytes received.",
                "",
                "| Command | Count | Bytes | Avg bytes |",
                "| --- | ---: | ---: | ---: |",
            ]
        )
        for command, values in sorted(delta.items(), key=lambda kv: -kv[1]["count"]):
            avg = values["bytes"] / values["count"] if values["count"] else 0
            out.append(f"| {command} | {values['count']} | {values['bytes']} | {avg:.1f} |")
    out.append("")
    return out


async def main_async(args):
    # Step well clear of nicks a previous run may still be holding.
    base = (int(time.time()) + 20_000) % 40_000_000
    oper = tuple(args.oper.split(":", 1)) if args.oper else None
    sampler = bench_commands.Sampler(args.container).start()
    stats_before = await bench_commands.server_stats(
        args.host, args.port, nick_for(base, 91_000_000), oper
    )
    if args.warmup:
        _warm_delays, warm_errors, _warm_elapsed = await registration_burst(
            args.host,
            args.port,
            base,
            args.warmup,
            args.concurrency,
            args.timeout,
            index_offset=70_000_000,
        )
        if warm_errors:
            raise RuntimeError(f"warmup failed: {warm_errors[:3]}")
    reader, writer, _delay, welcome = await register(
        args.host, args.port, nick_for(base, 90_000_000), args.timeout
    )
    welcome_line = next(
        (line for line in welcome.decode("utf-8", "replace").split("\r\n") if " 001 " in line),
        welcome.decode("utf-8", "replace").split("\r\n")[0],
    )
    ping = {}
    delays, errors = await ping_latency(reader, writer, args.pings)
    ping["delays"] = delays
    ping["errors"] = errors
    flood_seen, flood_elapsed = await ping_flood(reader, writer, args.flood)
    await quit_client(writer)
    stats_task = asyncio.create_task(asyncio.to_thread(container_sample, args.container))
    reg_delays, reg_errors, reg_elapsed = await registration_burst(
        args.host, args.port, base, args.registrations, args.concurrency, args.timeout
    )
    stats = await stats_task
    channel = await channel_fanout(
        args.host, args.port, base, args.members, args.each, args.timeout
    )
    matrix = []
    if args.commands:
        matrix = await bench_commands.command_matrix(
            args.host,
            args.port,
            lambda index: nick_for(base, 80_000_000 + index),
            args.commands,
            oper,
            args.timeout,
            args.pace,
        )
    stats_after = await bench_commands.server_stats(
        args.host, args.port, nick_for(base, 92_000_000), oper
    )
    container = await asyncio.to_thread(sampler.stop)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    out = Path(args.output) if args.output else ROOT / "bench" / "results" / f"{stamp}.md"
    report = {
        "when": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        "host": args.host,
        "port": args.port,
        "welcome": welcome_line,
        "stats": stats,
        "otp": otp_version(args.kind, args.container),
        "kind": args.kind,
        "warmup": args.warmup,
        "ping": ping,
        "flood": {"seen": flood_seen, "count": args.flood, "elapsed": flood_elapsed},
        "regs": {
            "delays": reg_delays,
            "errors": reg_errors,
            "count": args.registrations,
            "concurrency": args.concurrency,
            "elapsed": reg_elapsed,
        },
        "channel": channel,
        "commands": matrix,
        "iterations": args.commands,
        "pace": args.pace,
        "server": {
            "uptime": stats_after["uptime"],
            "lusers": stats_after["lusers"],
            "delta": bench_commands.stats_delta(stats_before, stats_after),
            "container": container,
        },
    }
    write_report(out, report)
    print(out)
    if args.json:
        Path(args.json).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json).write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")
        print(args.json)


def main():
    parser = argparse.ArgumentParser(description="Measure a running ircd")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6667)
    parser.add_argument("--pings", type=int, default=100)
    parser.add_argument("--flood", type=int, default=1000)
    parser.add_argument("--registrations", type=int, default=200)
    parser.add_argument("--concurrency", type=int, default=32)
    parser.add_argument("--members", type=int, default=8)
    parser.add_argument("--each", type=int, default=100)
    parser.add_argument("--timeout", type=float, default=8)
    parser.add_argument("--output", default="")
    parser.add_argument("--container", default="irc-server_ircd-dev_1")
    parser.add_argument(
        "--kind", choices=("development", "release", "production"), default="development"
    )
    parser.add_argument("--warmup", type=int, default=0)
    parser.add_argument(
        "--commands",
        type=int,
        default=30,
        help="iterations per command family in the command matrix (0 skips it)",
    )
    parser.add_argument(
        "--oper",
        default="",
        help="NAME:PASSWORD for OPER; adds operator commands and operator-only stats",
    )
    parser.add_argument(
        "--pace",
        type=float,
        default=0.0,
        help="cap the command matrix client at this many lines per second (0: no cap)",
    )
    parser.add_argument("--json", default="", help="also write the full report as JSON")
    args = parser.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
