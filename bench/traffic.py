#!/usr/bin/env python3
"""Drive a running briskd with real TCP clients and write a short result note.

Usage, from the repository root, while the server is listening:

    python3 bench/traffic.py
    python3 bench/traffic.py --host 127.0.0.1 --port 6667
    python3 bench/traffic.py --oper yehor:devpass --json bench/results/run.json

Phases: sequential and pipelined PING, a registration burst, channel fan-out,
a high-load phase (by default 10,000 connected clients in channels of 50
sending 100,000 channel messages, about 4.9 million deliveries), and a
per-command matrix (see bench/commands.py) that times every client command
family. The report also carries the server's own statistics for the
run: the `STATS m` per-command delta, uptime, LUSERS, and container CPU and
memory sampled once per second. `--oper` adds operator-only commands.

The default target is the development listener on port 6667. `bench/scripts/release.sh`
starts a packaged release on port 6668 and passes `--kind release`. Each run
uses a fresh nick prefix because a quit holds that nick for 60 seconds.

The event loop is the standard asyncio loop; `--loop rsloop` uses rsloop (a
Rust asyncio loop, io_uring on Linux) instead, which lost connections and
deliveries in these runs (bench/README.md). The report names the loop and the
generator's own CPU use, so a saturated generator is not mistaken for a slow
server.
"""

import argparse
import asyncio
import json
import re
import resource
import secrets
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
    # A channel of this run only: a server that keeps channel history
    # (`retention: channels`) replays a reused channel's earlier messages on
    # JOIN, which would count as deliveries.
    chan = f"#bench{base % 1_000_000}".encode()
    clients = []
    try:
        for index in range(members):
            nick = nick_for(base, 50_000_000 + index)
            reader, writer, _delay, _buf = await register(host, port, nick, timeout)
            writer.write(b"JOIN " + chan + b"\r\n")
            await writer.drain()
            await read_until(reader, b" 366 ", timeout)
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
                found = buf.count(b"PRIVMSG " + chan + b" ")
                if found:
                    async with lock:
                        received += found
                    buf = b""

        tasks = [asyncio.create_task(collect(reader)) for reader, _writer in clients]
        payload = b"".join(b"PRIVMSG " + chan + b" :x\r\n" for _ in range(each))
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


# One delivered channel message; and the send time carried by sampled ones.
DELIVERY = b" PRIVMSG #ld"
SAMPLE = re.compile(rb" PRIVMSG #ld\S* :L(\d+)")
ERROR_NUMERIC = re.compile(rb"^:\S+ ([45]\d\d) ", re.M)


async def welcome_or_retry(reader, writer, timeout):
    """Wait for 001. A nick still held from an earlier run (the server keeps a
    quit user's nick for `resource_delay`, 60 s by default) gets 433: take a
    random one instead of waiting for the registration timeout to close us."""
    buf = b""
    deadline = time.perf_counter() + timeout
    while b" 001 " not in buf:
        remaining = deadline - time.perf_counter()
        if remaining <= 0:
            raise TimeoutError("no welcome")
        chunk = await asyncio.wait_for(reader.read(65536), remaining)
        if not chunk:
            raise EOFError("closed before the welcome")
        buf += chunk
        if b" 433 " in buf or b" 437 " in buf:
            writer.write(f"NICK r{secrets.randbelow(10**8):08d}\r\n".encode())
            await writer.drain()
            buf = buf.replace(b" 433 ", b" ").replace(b" 437 ", b" ")


async def high_load(args, base):
    """10k-scale load: hold `clients` registered connections in channels of
    `members`, send `messages` channel messages, and count every delivery.

    Each sender's message reaches the other members of its channel, so the
    expected deliveries are sum(messages sent in a channel x (size - 1)).
    One message in `sample_every` carries its send time (perf_counter_ns) for
    latency; the rest are a short constant text. Rate 0 sends each client's
    share at once (a burst), otherwise `rate` messages per second in total.
    """
    n, members = args.clients, args.members
    targets = args.target_list
    # Channel names unique to this run: with `channels` retention the server
    # keeps history and replays it on JOIN to clients without
    # draft/chathistory, which would count an earlier run's messages here.
    prefix = f"#ld{base % 1_000_000}x"
    conns = [None] * n
    welcome = []
    refused = 0
    failures = {}
    per_target = {}
    sem = asyncio.Semaphore(args.load_concurrency)

    async def connect(i):
        nonlocal refused
        async with sem:
            nick = nick_for(base, 60_000_000 + i)
            writer = None
            started = time.perf_counter()
            # Round-robin over the targets: consecutive clients share a
            # channel, so with two linked servers every channel has members on
            # both and each message crosses the link.
            host, port = targets[i % len(targets)]
            try:
                reader, writer = await asyncio.wait_for(
                    open_client(host, port), args.connect_timeout
                )
                writer.write(f"NICK {nick}\r\nUSER {nick} 0 * :bench\r\n".encode())
                await writer.drain()
                await welcome_or_retry(reader, writer, args.connect_timeout)
                welcome.append(time.perf_counter() - started)
                writer.write(f"JOIN {prefix}{i // members}\r\n".encode())
                await writer.drain()
                # Only a confirmed member (end of NAMES) counts towards the
                # expected deliveries: a JOIN still queued when the messages
                # go out would miss them without any error.
                await read_until(reader, b" 366 ", args.connect_timeout)
                conns[i] = (reader, writer)
                per_target[f"{host}:{port}"] = per_target.get(f"{host}:{port}", 0) + 1
            except Exception as exc:  # noqa: BLE001 - counted by kind
                if isinstance(exc, EOFError):
                    refused += 1
                else:
                    key = type(exc).__name__
                    failures[key] = failures.get(key, 0) + 1
                # A client that did not make it must not stay connected.
                if writer is not None:
                    writer.close()

    t0 = time.perf_counter()
    await asyncio.gather(*(connect(i) for i in range(n)))
    connect_elapsed = time.perf_counter() - t0
    live = [i for i in range(n) if conns[i] is not None]

    # Messages per client (spread evenly) and the deliveries they should make.
    share = [args.messages // n + (1 if i < args.messages % n else 0) for i in range(n)]
    group_size = {}
    for i in live:
        group_size[i // members] = group_size.get(i // members, 0) + 1
    expected = sum(share[i] * (group_size[i // members] - 1) for i in live)

    # With linked servers, a JOIN confirmed by the client's own server may not
    # have reached the others yet, and a server forwards a channel message
    # only to servers it knows have members there. Wait until every server
    # lists every member of every channel, so the phase counts delivery, not
    # this propagation race.
    propagation = None
    if len(targets) > 1:
        t_prop = time.perf_counter()
        holders = {}
        for i in live:
            holders.setdefault((i // members, targets[i % len(targets)]), i)

        async def visible(group, i):
            chan = f"{prefix}{group}"
            reader, writer = conns[i]
            deadline = time.perf_counter() + args.connect_timeout * 4
            while time.perf_counter() < deadline:
                writer.write(f"NAMES {chan}\r\n".encode())
                await writer.drain()
                end = re.compile(rb" 366 \S+ " + re.escape(chan.encode()) + rb" ")
                buf = b""
                stop_at = time.perf_counter() + args.connect_timeout
                while not end.search(buf):
                    left = stop_at - time.perf_counter()
                    if left <= 0:
                        raise TimeoutError(f"no NAMES end for {chan}")
                    chunk = await asyncio.wait_for(reader.read(65536), left)
                    if not chunk:
                        raise EOFError("closed during NAMES")
                    buf += chunk
                names = 0
                for line in buf.split(b"\r\n"):
                    if b" 353 " in line and f" {chan} :".encode() in line:
                        names += len(line.split(b" :", 1)[1].split())
                if names >= group_size[group]:
                    return True
                await asyncio.sleep(0.5)
            return False

        seen = await asyncio.gather(*(visible(g, i) for (g, _t), i in holders.items()))
        propagation = {
            "seconds": round(time.perf_counter() - t_prop, 2),
            "incomplete": sum(1 for ok in seen if not ok),
        }

    received = 0
    latencies = []
    disconnects = 0
    numerics = {}
    stop = asyncio.Event()
    progress = asyncio.Event()

    async def drain(i):
        nonlocal received, disconnects
        reader, writer = conns[i]
        rest = b""
        while not stop.is_set():
            try:
                chunk = await asyncio.wait_for(reader.read(65536), 0.5)
            except (TimeoutError, asyncio.TimeoutError):
                continue
            except (ConnectionError, OSError):
                disconnects += 1
                return
            if not chunk:
                disconnects += 1
                return
            data = rest + chunk
            cut = data.rfind(b"\r\n")
            if cut < 0:
                rest = data
                continue
            whole, rest = data[: cut + 2], data[cut + 2 :]
            found = whole.count(DELIVERY)
            if found:
                received += found
                now = time.perf_counter_ns()
                for m in SAMPLE.finditer(whole):
                    latencies.append((now - int(m.group(1))) / 1e9)
                progress.set()
            if b"PING " in whole:
                for line in whole.split(b"\r\n"):
                    if line.startswith(b"PING "):
                        writer.write(b"PONG " + line[5:] + b"\r\n")
            if b" 4" in whole or b" 5" in whole:
                for code in ERROR_NUMERIC.findall(whole):
                    numerics[code.decode()] = numerics.get(code.decode(), 0) + 1

    readers = [asyncio.create_task(drain(i)) for i in live]
    cpu0 = time.process_time()
    started = time.perf_counter()

    def lines(i):
        chan = f"{prefix}{i // members}"
        out = []
        for k in range(share[i]):
            if (i + k * n) % args.sample_every == 0:
                out.append(f"PRIVMSG {chan} :L{time.perf_counter_ns()}\r\n")
            else:
                out.append(f"PRIVMSG {chan} :x\r\n")
        return "".join(out).encode()

    sent = 0
    if args.rate <= 0:
        for i in live:
            conns[i][1].write(lines(i))
            sent += share[i]
        await asyncio.gather(*(conns[i][1].drain() for i in live), return_exceptions=True)
    else:
        # Round-robin, one message per client per pass, in 10 ms ticks.
        queue = [(i, k) for k in range(max(share, default=0)) for i in live if k < share[i]]
        per_tick = max(1, round(args.rate / 100))
        tick = started
        for pos in range(0, len(queue), per_tick):
            for i, k in queue[pos : pos + per_tick]:
                chan = f"{prefix}{i // members}"
                text = f"L{time.perf_counter_ns()}" if (i + k * n) % args.sample_every == 0 else "x"
                conns[i][1].write(f"PRIVMSG {chan} :{text}\r\n".encode())
                sent += 1
            tick += 0.01
            delay = tick - time.perf_counter()
            if delay > 0:
                await asyncio.sleep(delay)
    send_elapsed = time.perf_counter() - started

    # Wait for every delivery, or until nothing has arrived for the timeout.
    last = time.perf_counter()
    while received < expected:
        progress.clear()
        try:
            await asyncio.wait_for(progress.wait(), 1.0)
            last = time.perf_counter()
        except (TimeoutError, asyncio.TimeoutError):
            if time.perf_counter() - last > args.load_timeout:
                break
    elapsed = time.perf_counter() - started
    cpu = time.process_time() - cpu0
    stop.set()
    await asyncio.gather(*readers, return_exceptions=True)
    sem_quit = asyncio.Semaphore(1000)

    async def leave(i):
        async with sem_quit:
            await quit_client(conns[i][1])

    await asyncio.gather(*(leave(i) for i in live))
    return {
        "clients": n,
        "connected": len(live),
        "per_target": per_target,
        "propagation": propagation,
        "refused": refused,
        "failures": failures,
        "connect_elapsed": connect_elapsed,
        "welcome": welcome,
        "members": members,
        "channels": len(group_size),
        "messages": args.messages,
        "sent": sent,
        "rate": args.rate,
        "expected": expected,
        "received": received,
        "send_elapsed": send_elapsed,
        "elapsed": elapsed,
        "latencies": latencies,
        "disconnects": disconnects,
        "numerics": numerics,
        "generator_cpu": cpu,
    }


async def wait_responsive(args, base, limit=300.0):
    """Seconds until a fresh client registers (None if not within `limit`)."""
    started = time.perf_counter()
    attempt = 0
    while time.perf_counter() - started < limit:
        attempt += 1
        try:
            _r, writer, _d, _b = await register(
                args.host, args.port, nick_for(base, 93_000_000 + attempt), 10
            )
            await quit_client(writer)
            return time.perf_counter() - started
        except Exception:  # noqa: BLE001 - still busy: try again
            await asyncio.sleep(1)
    return None


def load_section(load):
    if not load:
        return []
    lat = load["latencies"]
    lost = load["expected"] - load["received"]
    util = load["generator_cpu"] / load["elapsed"] * 100 if load["elapsed"] else 0
    welcome = load["welcome"]
    lines = [
        "## High load",
        "",
        f"{load['connected']} of {load['clients']} clients connected and registered in "
        f"{load['connect_elapsed']:.1f} s ({fmt_rate(load['connected'], load['connect_elapsed'])}); "
        f"welcome p50 {fmt_ms(percentile(welcome, 50))}, p99 {fmt_ms(percentile(welcome, 99))}.",
    ]
    if len(load.get("per_target", {})) > 1:
        lines.append(
            "Clients per server (round-robin, so channels span the servers and every "
            "message crosses the link): "
            + ", ".join(f"`{t}` {c}" for t, c in sorted(load["per_target"].items()))
            + "."
        )
    if load.get("propagation"):
        prop = load["propagation"]
        lines.append(
            f"Every server listed every channel member {prop['seconds']} s after the joins "
            "(the send phase waits for this)"
            + (f"; **{prop['incomplete']} channel views incomplete** at the timeout." if prop["incomplete"] else ".")
        )
    if load["refused"] or load["failures"]:
        lines.append(
            f"Not connected: {load['refused']} closed before the welcome (the server's "
            f"`max_clients` refuses by closing), other failures {load['failures'] or 'none'}."
        )
    lines += [
        "",
        f"{load['sent']:,} channel messages from {load['connected']:,} clients in "
        f"{load['channels']} channels of up to {load['members']}, "
        + ("sent as one burst per client" if load["rate"] <= 0 else f"paced at {load['rate']:g}/s")
        + f" in {load['send_elapsed']:.2f} s.",
        f"Deliveries: {load['received']:,} of {load['expected']:,} expected"
        + (f" (**{lost:,} missing**)" if lost > 0 else "")
        + f" in {load['elapsed']:.2f} s, {fmt_rate(load['received'], load['elapsed'])}.",
        f"Delivery latency from send to receipt ({len(lat):,} sampled messages): "
        f"p50 {fmt_ms(percentile(lat, 50))}, p95 {fmt_ms(percentile(lat, 95))}, "
        f"p99 {fmt_ms(percentile(lat, 99))}, p99.9 {fmt_ms(percentile(lat, 99.9))}, "
        f"max {fmt_ms(max(lat) if lat else None)}.",
        f"Disconnects during the phase: {load['disconnects']}; error numerics: "
        f"{load['numerics'] or 'none'}.",
        (
            f"After the phase a new client registered within {load['recovery']:.1f} s."
            if load.get("recovery") is not None
            else "After the phase no new client could register within 300 s."
        ),
        f"Load generator CPU during the phase: {util:.0f}% of one core "
        + ("(near 100%: the generator may be the limit, not the server)." if util >= 90 else "."),
        "",
    ]
    return lines


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
        # The production image runs the release from /opt/briskd; its
        # start_erl.data names the bundled ERTS and the release version.
        return [
            "docker",
            "exec",
            container,
            "sh",
            "-c",
            'set -- $(cat /opt/briskd/releases/start_erl.data); echo "ERTS $1, release $2"',
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
            "BINDIR=$(echo /workspace/_build/prod/rel/briskd/erts-*/bin); "
            "ROOTDIR=/workspace/_build/prod/rel/briskd; "
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
        "briskd-dev",
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
            "`config/briskd.prod.json` (flood limits, DroneBL, `channels` retention,",
            "JSON info logging) with only `max_clients` raised so the high-load",
            "clients fit, `ulimit -n` 65536, `init`, and a fresh data volume, on",
            "another host port (`bench/scripts/prod.sh`).",
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
            "started with `_build/prod/rel/briskd/bin/briskd foreground`.",
            "`BRISKD_CONFIG` is the release copy of `bench/release.json` (port 6668,",
            "Mnesia directory `/tmp/briskd-release-mnesia`).",
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
        "# briskd bench",
        "",
        f"Measured {report['when']} against `{report['host']}:{report['port']}`.",
        f"Welcome numeric: `{report['welcome'].strip()}`.",
        f"Load generator event loop: `{report.get('loop', 'asyncio')}`.",
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
    lines.extend(load_section(report.get("load")))
    lines.extend(command_section(report))
    lines.extend(server_section(report))
    path.write_text("\n".join(lines), encoding="utf-8")


def command_section(report):
    rows = report.get("commands") or []
    if report.get("commands_error"):
        return [
            "## Commands",
            "",
            f"The command matrix did not run: `{report['commands_error']}`.",
            "",
        ]
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
    # A random base: a time-based one made back-to-back runs reuse each
    # other's nicks, which the server still holds for `resource_delay` (60 s)
    # after a quit, so their clients never registered.
    base = secrets.randbelow(40_000_000)
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
        args.host, args.port, base, args.fanout_members, args.each, args.timeout
    )
    load = None
    if args.clients > 0:
        load = await high_load(args, base)
        # After a burst the server may still be working through it: wait
        # until a fresh client registers again, and report how long it took.
        load["recovery"] = await wait_responsive(args, base)
    matrix = []
    matrix_error = None
    if args.commands:
        try:
            matrix = await bench_commands.command_matrix(
                args.host,
                args.port,
                lambda index: nick_for(base, 80_000_000 + index),
                args.commands,
                oper,
                args.timeout,
                args.pace,
            )
        except Exception as exc:  # noqa: BLE001 - reported, the run still writes its report
            matrix_error = f"{type(exc).__name__}: {exc}"
    try:
        stats_after = await bench_commands.server_stats(
            args.host, args.port, nick_for(base, 92_000_000), oper
        )
    except Exception:  # noqa: BLE001 - the server could not answer: no statistics
        stats_after = stats_before
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
        "load": load,
        "loop": args.loop,
        "commands": matrix,
        "commands_error": matrix_error,
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
    parser = argparse.ArgumentParser(description="Measure a running briskd")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6667)
    parser.add_argument("--pings", type=int, default=100)
    parser.add_argument("--flood", type=int, default=1000)
    parser.add_argument("--registrations", type=int, default=200)
    parser.add_argument("--concurrency", type=int, default=32)
    parser.add_argument(
        "--fanout-members", type=int, default=8, help="members of the small fan-out phase"
    )
    parser.add_argument("--each", type=int, default=100)
    parser.add_argument(
        "--clients",
        type=int,
        default=10_000,
        help="clients held connected in the high-load phase (0 skips it); the server's "
        "max_clients must leave room for them",
    )
    parser.add_argument(
        "--messages", type=int, default=100_000, help="channel messages sent in the high-load phase"
    )
    parser.add_argument("--members", type=int, default=50, help="clients per high-load channel")
    parser.add_argument(
        "--rate",
        type=float,
        default=0.0,
        help="high-load messages per second in total (0: each client sends its share at once)",
    )
    parser.add_argument(
        "--load-concurrency", type=int, default=500, help="high-load connections opened at once"
    )
    parser.add_argument(
        "--connect-timeout",
        type=float,
        default=120.0,
        help="seconds a high-load client may take to connect and get its welcome",
    )
    parser.add_argument(
        "--load-timeout",
        type=float,
        default=30.0,
        help="seconds without a delivery before the high-load phase gives up waiting",
    )
    parser.add_argument(
        "--sample-every", type=int, default=100, help="one high-load message in N carries a timestamp"
    )
    parser.add_argument(
        "--targets",
        default="",
        help="comma-separated host:port servers for the high-load clients, round-robin "
        "(default: --host:--port); with linked servers, channels span them",
    )
    parser.add_argument(
        "--loop",
        choices=("asyncio", "rsloop"),
        default="asyncio",
        help="event loop: the standard asyncio loop, or rsloop (Rust, io_uring on Linux; "
        "unreliable at high load, see bench/README.md)",
    )
    parser.add_argument("--timeout", type=float, default=8)
    parser.add_argument("--output", default="")
    parser.add_argument("--container", default="irc-server_briskd-dev_1")
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
    try:
        args.target_list = [
            (host, int(port))
            for host, port in (t.strip().rsplit(":", 1) for t in args.targets.split(",") if t.strip())
        ] or [(args.host, args.port)]
    except ValueError:
        parser.error("--targets takes host:port[,host:port...]")
    if args.clients < 0 or args.messages < 0 or args.members < 2 or args.sample_every < 1:
        parser.error("--clients/--messages must be >= 0, --members >= 2, --sample-every >= 1")
    # One descriptor per client socket, plus the other phases'.
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = args.clients + 4096
    if soft < want:
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(want, hard), hard))
    if args.loop == "rsloop":
        import rsloop

        rsloop.run(main_async(args))
    else:
        asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
