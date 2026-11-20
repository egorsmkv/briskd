"""Per-command benchmark and server statistics for bench/traffic.py.

Each command family is sent `iterations` times by one dedicated client. Every
iteration is followed by `PING <marker>`; the server handles one connection's
lines in order, so the time until `PONG <marker>` is the time to process the
command and send all of its replies. That measures commands that have no reply
too. Error numerics (400-599) and IRCv3 `FAIL` replies are counted per command.

Server-side statistics come from the server itself: `STATS m` (per-command
count and bytes, read before and after so the report shows the delta of this
run), `STATS u` (uptime), and `LUSERS`. Container CPU and memory are sampled
with `docker stats` once per second for the whole run.
"""

import asyncio
import base64
import re
import subprocess
import threading
import time

ACTOR_CAPS = (
    "message-tags batch labeled-response echo-message server-time draft/multiline "
    "draft/chathistory draft/event-playback draft/metadata-2 draft/read-marker "
    "draft/message-redaction draft/channel-rename setname sasl draft/account-registration "
    "account-tag extended-join away-notify invite-notify multi-prefix userhost-in-names"
)

ERROR_NUMERIC = re.compile(rb"^(?:@\S+ )?:\S+ ([45]\d\d) ")
# Informational "errors" that are not failures of the command under test:
# 422 ERR_NOMOTD (no MOTD file configured).
IGNORED_NUMERICS = {b"422"}
FAIL_LINE = re.compile(rb"^(?:@\S+ )?:\S+ FAIL ")
MSGID = re.compile(rb"msgid=([^; ]+)")


class Conn:
    """One client connection with a line buffer."""

    def __init__(self, reader, writer, nick):
        self.reader = reader
        self.writer = writer
        self.nick = nick
        self.buf = b""

    async def send(self, *lines):
        self.writer.write(b"".join(line.encode() + b"\r\n" for line in lines))
        await self.writer.drain()

    async def lines_until(self, needle, timeout=10):
        """Read lines until one contains `needle`; return all of them."""
        out = []
        deadline = time.perf_counter() + timeout
        while True:
            while b"\r\n" in self.buf:
                line, self.buf = self.buf.split(b"\r\n", 1)
                out.append(line)
                if line.startswith(b"PING "):
                    self.writer.write(b"PONG " + line[5:] + b"\r\n")
                if needle in line:
                    return out
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                raise TimeoutError(f"{self.nick}: no {needle!r}")
            chunk = await asyncio.wait_for(self.reader.read(65536), remaining)
            if not chunk:
                raise EOFError(f"{self.nick}: connection closed")
            self.buf += chunk

    async def sync(self, marker, timeout=10):
        """Send PING <marker> and return every line up to its PONG."""
        await self.send(f"PING {marker}")
        return await self.lines_until(marker.encode(), timeout)

    async def close(self):
        try:
            self.writer.write(b"QUIT :bench\r\n")
            await self.writer.drain()
            self.writer.close()
            await self.writer.wait_closed()
        except Exception:
            pass


async def connect(host, port, nick, caps="", timeout=10):
    reader, writer = await asyncio.open_connection(host, port)
    conn = Conn(reader, writer, nick)
    if caps:
        await conn.send("CAP LS 302", f"CAP REQ :{caps}")
    await conn.send(f"NICK {nick}", f"USER {nick} 0 * :bench {nick}")
    if caps:
        await conn.send("CAP END")
    await conn.lines_until(b" 001 ", timeout)
    await conn.sync("ready", timeout)
    return conn


async def drain_forever(conn, stop):
    """Keep a passive client's socket empty and answer server PINGs."""
    while not stop.is_set():
        try:
            chunk = await asyncio.wait_for(conn.reader.read(65536), 0.2)
        except (TimeoutError, asyncio.TimeoutError):
            continue
        except Exception:
            return
        if not chunk:
            return
        conn.buf += chunk
        while b"\r\n" in conn.buf:
            line, conn.buf = conn.buf.split(b"\r\n", 1)
            if line.startswith(b"PING "):
                conn.writer.write(b"PONG " + line[5:] + b"\r\n")


def percentile(samples, pct):
    if not samples:
        return None
    ordered = sorted(samples)
    index = min(len(ordered) - 1, max(0, round((pct / 100) * (len(ordered) - 1))))
    return ordered[index]


class Sampler:
    """Sample `docker stats` for one container in a background thread."""

    def __init__(self, container, interval=1.0):
        self.container = container
        self.interval = interval
        self.samples = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=15)
        return self.summary()

    def _run(self):
        while not self._stop.is_set():
            try:
                text = subprocess.check_output(
                    [
                        "docker",
                        "stats",
                        "--no-stream",
                        "--format",
                        "{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}|{{.PIDs}}",
                        self.container,
                    ],
                    text=True,
                    stderr=subprocess.DEVNULL,
                    timeout=10,
                ).strip()
                cpu, mem, net, pids = text.split("|")
                self.samples.append(
                    {
                        "t": time.time(),
                        "cpu": float(cpu.rstrip("%")),
                        "mem_mib": to_mib(mem.split("/")[0].strip()),
                        "net": net.strip(),
                        "pids": int(pids),
                    }
                )
            except (subprocess.SubprocessError, OSError, ValueError):
                pass
            self._stop.wait(self.interval)

    def summary(self):
        if not self.samples:
            return {"samples": 0}
        cpus = [s["cpu"] for s in self.samples]
        mems = [s["mem_mib"] for s in self.samples]
        return {
            "samples": len(self.samples),
            "cpu_min": min(cpus),
            "cpu_avg": sum(cpus) / len(cpus),
            "cpu_max": max(cpus),
            "mem_min_mib": min(mems),
            "mem_avg_mib": sum(mems) / len(mems),
            "mem_max_mib": max(mems),
            "net_last": self.samples[-1]["net"],
            "pids_max": max(s["pids"] for s in self.samples),
        }


def to_mib(text):
    units = {"B": 1 / 1048576, "KiB": 1 / 1024, "MiB": 1, "GiB": 1024, "kB": 1 / 1024, "MB": 1}
    match = re.match(r"([\d.]+)\s*([A-Za-z]+)", text)
    if not match:
        return 0.0
    return float(match.group(1)) * units.get(match.group(2), 1)


async def server_stats(host, port, nick, oper):
    """Read STATS m, STATS u, and LUSERS from the server."""
    conn = await connect(host, port, nick)
    try:
        if oper:
            name, password = oper
            await conn.send(f"OPER {name} {password}")
        await conn.send("STATS m", "STATS u", "LUSERS")
        lines = await conn.sync("statsdone")
    finally:
        await conn.close()
    commands = {}
    uptime = None
    lusers = []
    for raw in lines:
        line = raw.decode("utf-8", "replace")
        parts = line.split(" ")
        if len(parts) >= 7 and parts[1] == "212":
            commands[parts[3]] = {"count": int(parts[4]), "bytes": int(parts[5])}
        elif len(parts) > 3 and parts[1] == "242":
            uptime = line.split(" :", 1)[-1]
        elif len(parts) > 2 and parts[1] in ("251", "252", "253", "254", "255", "265", "266"):
            # Keep middle parameters (counts) and the trailing text.
            body = line.split(" ", 3)[3] if len(parts) > 3 else ""
            lusers.append(f"{parts[1]} " + body.replace(" :", " ", 1).lstrip(":"))
    return {"commands": commands, "uptime": uptime, "lusers": lusers}


def stats_delta(before, after):
    delta = {}
    for command, now in after["commands"].items():
        prev = before["commands"].get(command, {"count": 0, "bytes": 0})
        count = now["count"] - prev["count"]
        if count:
            delta[command] = {"count": count, "bytes": now["bytes"] - prev["bytes"]}
    return delta


async def command_matrix(host, port, nick_for, iterations, oper, timeout, pace=0.0):
    """Run every command family and return per-command results.

    `pace` caps the actor's send rate in lines per second (0: no cap), so a
    server's flood limit does not disconnect it; the wait happens before
    each timed iteration and is not part of the latency. If the server
    closes the connection anyway, the family records the error and the
    remaining families are reported as skipped.
    """
    actor = await connect(host, port, nick_for(1), ACTOR_CAPS, timeout)
    peer = await connect(host, port, nick_for(2), "", timeout)
    outsider = await connect(host, port, nick_for(3), "", timeout)
    stop = asyncio.Event()
    drains = [asyncio.create_task(drain_forever(c, stop)) for c in (peer, outsider)]
    chan = f"#c{nick_for(0)[1:]}"
    alt = f"#d{nick_for(0)[1:]}"
    account = f"a{nick_for(4)[1:]}"[:9]
    password = "benchpass"
    state = {"counter": 0, "msgid": None, "away": False, "mode": False, "renamed": False}

    # Shared setup: the actor and the peer share a channel the actor operates.
    await actor.send(f"JOIN {chan}")
    await actor.sync("setup1")
    await peer.send(f"JOIN {chan}")
    await asyncio.sleep(0.2)
    await actor.send(f"REGISTER {account} * {password}")
    await actor.sync("setup2")
    # A nickname that has quit, so WHOWAS has history to return.
    gone = await connect(host, port, nick_for(5), "", timeout)
    await gone.close()
    await asyncio.sleep(0.2)

    def fresh_nick():
        state["counter"] += 1
        return nick_for(10_000 + state["counter"])

    def privmsg_capture(lines):
        for line in lines:
            match = MSGID.search(line)
            if match and b"PRIVMSG" in line:
                state["msgid"] = match.group(1).decode()

    def away(_):
        state["away"] = not state["away"]
        return ["AWAY :bench away"] if state["away"] else ["AWAY"]

    def mode_toggle(_):
        state["mode"] = not state["mode"]
        return [f"MODE {chan} {'+' if state['mode'] else '-'}m"]

    def rename(_):
        state["renamed"] = not state["renamed"]
        return [f"RENAME {chan} {alt}"] if state["renamed"] else [f"RENAME {alt} {chan}"]

    def current_chan():
        return alt if state["renamed"] else chan

    sasl_blob = base64.b64encode(f"\0{account}\0{password}".encode()).decode()

    families = [
        ("PING", lambda i: [f"PING x{i}"]),
        ("CAP LS", lambda i: ["CAP LS 302"]),
        ("CAP LIST", lambda i: ["CAP LIST"]),
        ("ISUPPORT", lambda i: ["ISUPPORT"]),
        ("PRIVMSG user", lambda i: [f"PRIVMSG {peer.nick} :direct {i}"]),
        ("NOTICE user", lambda i: [f"NOTICE {peer.nick} :notice {i}"]),
        ("TAGMSG user", lambda i: [f"@+typing=active TAGMSG {peer.nick}"]),
        ("PRIVMSG channel", lambda i: [f"PRIVMSG {current_chan()} :channel {i}"]),
        ("NOTICE channel", lambda i: [f"NOTICE {current_chan()} :channel {i}"]),
        (
            "BATCH multiline",
            lambda i: [
                f"BATCH +m{i} draft/multiline {current_chan()}",
                f"@batch=m{i} PRIVMSG {current_chan()} :line one {i}",
                f"@batch=m{i} PRIVMSG {current_chan()} :line two {i}",
                f"@batch=m{i};draft/multiline-concat PRIVMSG {current_chan()} : concat",
                f"BATCH -m{i}",
            ],
        ),
        ("JOIN+PART", lambda i: [f"JOIN #j{i % 10}{chan[2:7]}", f"PART #j{i % 10}{chan[2:7]}"]),
        ("TOPIC set", lambda i: [f"TOPIC {current_chan()} :topic {i}"]),
        ("TOPIC query", lambda i: [f"TOPIC {current_chan()}"]),
        ("NAMES", lambda i: [f"NAMES {current_chan()}"]),
        ("LIST", lambda i: [f"LIST {current_chan()}"]),
        ("MODE channel query", lambda i: [f"MODE {current_chan()}"]),
        ("MODE channel set", mode_toggle),
        ("MODE ban list", lambda i: [f"MODE {current_chan()} +b"]),
        ("MODE user", lambda i: [f"MODE {actor.nick}"]),
        ("INVITE", lambda i: [f"INVITE {outsider.nick} {current_chan()}"]),
        ("WHO channel", lambda i: [f"WHO {current_chan()}"]),
        ("WHOX", lambda i: [f"WHO {current_chan()} %tcnuhfar,7"]),
        ("WHOIS", lambda i: [f"WHOIS {peer.nick}"]),
        ("WHOWAS", lambda i: [f"WHOWAS {gone.nick}"]),
        ("ISON", lambda i: [f"ISON {peer.nick} {outsider.nick} nobody"]),
        ("USERHOST", lambda i: [f"USERHOST {peer.nick} {outsider.nick}"]),
        ("AWAY", away),
        ("SETNAME", lambda i: [f"SETNAME :bench name {i}"]),
        ("NICK change", lambda i: [f"NICK {fresh_nick()}"]),
        ("MONITOR", lambda i: [f"MONITOR + {peer.nick}", f"MONITOR - {peer.nick}"]),
        ("METADATA set+get", lambda i: [f"METADATA * SET color :c{i}", "METADATA * GET color"]),
        ("CHATHISTORY LATEST", lambda i: [f"CHATHISTORY LATEST {current_chan()} * 20"]),
        ("MARKREAD", lambda i: [f"MARKREAD {current_chan()}"]),
        ("RENAME", rename),
        ("LUSERS", lambda i: ["LUSERS"]),
        ("MOTD", lambda i: ["MOTD"]),
        ("VERSION", lambda i: ["VERSION"]),
        ("TIME", lambda i: ["TIME"]),
        ("INFO", lambda i: ["INFO"]),
        ("ADMIN", lambda i: ["ADMIN"]),
        ("LINKS", lambda i: ["LINKS"]),
        ("STATS u", lambda i: ["STATS u"]),
        ("STATS m", lambda i: ["STATS m"]),
        ("SERVLIST", lambda i: ["SERVLIST"]),
        ("AUTHENTICATE PLAIN", lambda i: ["AUTHENTICATE PLAIN", f"AUTHENTICATE {sasl_blob}"]),
        (
            "PRIVMSG+REDACT",
            lambda i: [f"PRIVMSG {current_chan()} :to redact {i}"],
        ),
    ]
    if oper:
        oper_name, oper_password = oper
        families += [
            ("OPER", lambda i: [f"OPER {oper_name} {oper_password}"]),
            ("WALLOPS", lambda i: [f"WALLOPS :bench {i}"]),
            ("TRACE", lambda i: ["TRACE"]),
            ("STATS l", lambda i: ["STATS l"]),
        ]

    results = []
    lost = None
    next_send = time.perf_counter()
    try:
        for name, build in families:
            delays, errors, examples = [], 0, []
            if lost:
                results.append(skipped(name, lost))
                continue
            started = time.perf_counter()
            for i in range(iterations):
                lines_out = build(i)
                marker = f"k{len(results)}x{i}"
                if pace:
                    # One PING per iteration, plus a REDACT after PRIVMSG+REDACT.
                    extra = 2 if name == "PRIVMSG+REDACT" else 1
                    wait = next_send - time.perf_counter()
                    if wait > 0:
                        await asyncio.sleep(wait)
                    next_send = max(next_send, time.perf_counter()) + (len(lines_out) + extra) / pace
                begin = time.perf_counter()
                try:
                    await actor.send(*lines_out, f"PING {marker}")
                    got = await actor.lines_until(marker.encode(), timeout)
                except (TimeoutError, EOFError, asyncio.TimeoutError) as exc:
                    errors += 1
                    examples.append(f"{type(exc).__name__}: {exc}")
                    if isinstance(exc, EOFError):
                        lost = "connection closed by the server"
                    break
                except (ConnectionError, OSError) as exc:
                    errors += 1
                    lost = f"connection closed by the server ({type(exc).__name__})"
                    examples.append(lost)
                    break
                delays.append(time.perf_counter() - begin)
                if name == "PRIVMSG+REDACT":
                    privmsg_capture(got)
                    if state["msgid"]:
                        await actor.send(f"REDACT {current_chan()} {state['msgid']}")
                for line in got:
                    numeric = ERROR_NUMERIC.match(line)
                    if numeric and numeric.group(1) in IGNORED_NUMERICS:
                        continue
                    if numeric or FAIL_LINE.match(line):
                        errors += 1
                        if len(examples) < 2:
                            examples.append(line.decode("utf-8", "replace")[:160])
            elapsed = time.perf_counter() - started
            results.append(
                {
                    "command": name,
                    "iterations": len(delays),
                    "elapsed": elapsed,
                    "ops_per_s": len(delays) / elapsed if elapsed > 0 else 0.0,
                    "p50": percentile(delays, 50),
                    "p95": percentile(delays, 95),
                    "p99": percentile(delays, 99),
                    "max": max(delays) if delays else None,
                    "errors": errors,
                    "examples": examples,
                }
            )
    finally:
        stop.set()
        await asyncio.gather(*drains, return_exceptions=True)
        for conn in (actor, peer, outsider):
            try:
                await conn.close()
            except (ConnectionError, OSError):
                pass
    return results


def skipped(name, why):
    """A family that did not run because the actor's connection was lost."""
    return {
        "command": name,
        "iterations": 0,
        "elapsed": 0.0,
        "ops_per_s": 0.0,
        "p50": None,
        "p95": None,
        "p99": None,
        "max": None,
        "errors": 0,
        "examples": [f"skipped: {why}"],
    }
