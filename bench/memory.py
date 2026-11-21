#!/usr/bin/env python3
"""Measure the server's memory: per session, under traffic, and after churn.

Runs against a server in a Docker container (bench/memory-prod starts the
production image) and reads the node's own view of memory with erl_call
inside that container, after a full garbage collection, at each step:

1. idle baseline;
2. N registered clients connected, in channels of --members;
3. after each client sends --messages channel messages (fan-out);
4. after every client quit (what the server keeps: WHOWAS, history);
5. --rounds of connect/register/join/message/quit churn with fresh nicks;
   steady growth across rounds that is not explained by a bounded store
   (WHOWAS, history) points at a leak.

Each sample records erlang:memory/0, the session processes' total memory
and the off-heap (refc) binaries they reference, the largest registered
processes (memory, mailbox length), and the largest ETS tables. The report
is Markdown (--output) and the raw samples JSON (--json).
"""

import argparse
import asyncio
import json
import resource
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Erlang expression run in the node: GC everything, then sample. The result
# is written as JSON inside the container and read back with `cat`.
PROBE = r"""
[erlang:garbage_collect(P) || P <- erlang:processes()],
Sess = [P || {_, P, _, _} <- supervisor:which_children(briskd_sessions), is_pid(P)],
Info = fun(P, K) -> case erlang:process_info(P, K) of {K, V} -> V; _ -> undefined end end,
SessMem = [M || P <- Sess, M <- [Info(P, memory)], is_integer(M)],
SessBin = [lists:sum([S || {_, S, _} <- B]) || P <- Sess, B <- [Info(P, binary)], is_list(B)],
SessQueue = lists:sum([Q || P <- Sess, Q <- [Info(P, message_queue_len)], is_integer(Q)]),
Named = [#{name => atom_to_binary(N), memory => Info(P, memory),
           queue => Info(P, message_queue_len)}
         || N <- registered(), P <- [whereis(N)], is_pid(P), is_integer(Info(P, memory))],
Top = lists:sublist(lists:reverse(lists:sort([{maps:get(memory, X), X} || X <- Named])), 12),
Word = erlang:system_info(wordsize),
Tabs = [#{name => iolist_to_binary(io_lib:format("~p", [ets:info(T, name)])),
          size => ets:info(T, size), bytes => ets:info(T, memory) * Word}
        || T <- ets:all(), is_integer(ets:info(T, memory))],
TopTabs = lists:sublist(lists:reverse(lists:sort([{maps:get(bytes, X), X} || X <- Tabs])), 15),
R = #{memory => maps:from_list(erlang:memory()),
      processes => erlang:system_info(process_count),
      ports => erlang:system_info(port_count),
      sessions => length(Sess),
      session_memory => lists:sum(SessMem),
      session_binaries => lists:sum(SessBin),
      session_queue => SessQueue,
      top_processes => [X || {_, X} <- Top],
      top_tables => [X || {_, X} <- TopTabs]},
ok = file:write_file("/tmp/briskd-memprobe.json", json:encode(R)).
"""


def probe(container, cookie):
    erts = subprocess.check_output(
        ["docker", "exec", container, "sh", "-c", "ls -d /opt/briskd/erts-*"], text=True
    ).strip()
    subprocess.run(
        ["docker", "exec", "-i", container, f"{erts}/bin/erl_call", "-sname", "briskd@localhost",
         "-c", cookie, "-e"],
        input=PROBE, text=True, check=True, capture_output=True, timeout=120,
    )
    out = subprocess.check_output(
        ["docker", "exec", container, "cat", "/tmp/briskd-memprobe.json"], timeout=30
    )
    return json.loads(out)


class Client:
    def __init__(self, reader, writer, nick):
        self.reader, self.writer, self.nick = reader, writer, nick
        self.channel = ""
        self.task = None

    async def drain_forever(self):
        """Read and discard (answering PING) so the server never blocks on us."""
        try:
            while True:
                data = await self.reader.read(65536)
                if not data:
                    return
                for line in data.split(b"\r\n"):
                    if line.startswith(b"PING "):
                        self.writer.write(b"PONG " + line[5:] + b"\r\n")
        except (ConnectionError, asyncio.CancelledError):
            return


async def connect(host, port, nick, channel, timeout=20):
    reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
    writer.write(f"NICK {nick}\r\nUSER {nick} 0 * :memory bench\r\n".encode())
    await writer.drain()
    buf = b""
    deadline = time.monotonic() + timeout
    while b" 001 " not in buf:
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError(f"{nick}: no welcome")
        chunk = await asyncio.wait_for(reader.read(65536), left)
        if not chunk:
            raise ConnectionError(f"{nick}: closed during registration")
        buf += chunk
        for line in buf.split(b"\r\n"):
            if line.startswith(b"PING "):
                writer.write(b"PONG " + line[5:] + b"\r\n")
    writer.write(f"JOIN {channel}\r\n".encode())
    await writer.drain()
    client = Client(reader, writer, nick)
    client.channel = channel
    client.task = asyncio.create_task(client.drain_forever())
    return client


async def connect_all(args, prefix, count):
    sem = asyncio.Semaphore(args.concurrency)

    async def one(i):
        async with sem:
            return await connect(
                args.host, args.port, f"{prefix}{i:04d}", f"#mem{prefix}{i // args.members}"
            )

    return await asyncio.gather(*(one(i) for i in range(count)))


async def traffic(clients, messages, rate):
    """Each client sends `messages` messages to its channel at `rate` per second."""
    async def talk(c):
        for n in range(messages):
            c.writer.write(f"PRIVMSG {c.channel} :memory bench message {n} from {c.nick}\r\n".encode())
            await c.writer.drain()
            await asyncio.sleep(1 / rate)

    await asyncio.gather(*(talk(c) for c in clients))


async def quit_all(clients):
    for c in clients:
        try:
            c.writer.write(b"QUIT :memory bench\r\n")
            await c.writer.drain()
        except ConnectionError:
            pass
    await asyncio.sleep(1)
    for c in clients:
        c.task.cancel()
        c.writer.close()


def mib(n):
    return f"{n / 1048576:.1f} MiB"


def kib(n):
    return f"{n / 1024:.1f} KiB"


def report(args, samples, started):
    base = samples[0][1]
    held = samples[1][1]
    n = args.clients
    lines = [
        "# briskd memory",
        "",
        f"Measured {started} against `{args.host}:{args.port}` (container `{args.container}`).",
        f"{args.note}",
        "",
        f"Workload: {n} clients in channels of {args.members}, {args.messages} channel messages each "
        f"at {args.rate}/s per client, then {args.rounds} churn rounds of {args.churn} clients "
        "(connect, register, join, message, quit). Every sample follows a full garbage "
        "collection of all processes, taken once every session's mailbox is empty and the "
        f"expected sessions remain (at most {args.settle:g} s; otherwise marked not settled).",
        "",
        "| Step | Total | Processes | Binary | ETS | Atoms | Sessions | Session memory | Queued |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name, s in samples:
        m = s["memory"]
        lines.append(
            f"| {name} | {mib(m['total'])} | {mib(m['processes'])} | {mib(m['binary'])} | "
            f"{mib(m['ets'])} | {kib(m['atom'])} | {s['sessions']} | {mib(s['session_memory'])} | "
            f"{s['session_queue']}{'' if s.get('settled', True) else ' (not settled)'} |"
        )
    per_total = (held["memory"]["total"] - base["memory"]["total"]) / n
    per_proc = held["session_memory"] / max(1, held["sessions"])
    per_bin = held["session_binaries"] / max(1, held["sessions"])
    lines += [
        "",
        f"Per connected client: {kib(per_total)} of total node memory; the session process "
        f"itself {kib(per_proc)} (heap and stack), plus {kib(per_bin)} of off-heap binaries "
        "it references.",
        "",
        "Largest ETS tables at the last sample:",
        "",
        "| Table | Rows | Bytes |",
        "| --- | ---: | ---: |",
    ]
    for t in samples[-1][1]["top_tables"]:
        lines.append(f"| `{t['name']}` | {t['size']} | {kib(t['bytes'])} |")
    lines += ["", "Largest registered processes at the last sample:", "",
              "| Process | Memory | Mailbox |", "| --- | ---: | ---: |"]
    for p in samples[-1][1]["top_processes"]:
        lines.append(f"| `{p['name']}` | {kib(p['memory'])} | {p['queue']} |")
    lines.append("")
    return "\n".join(lines)


async def main(args):
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = min(hard, max(soft, args.clients + args.churn + 512))
    resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
    started = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    # Fresh nicks each run (a quit holds a nick for resource_delay): "m",
    # two characters from the clock, a round letter, and 4 digits (9 chars).
    tag = format(int(time.time()) % 1296, "02x")[-2:]
    samples = []

    def sample(name, sessions):
        """Sample once the server has caught up: `sessions` session processes
        and no queued messages in them (up to --settle seconds)."""
        deadline = time.monotonic() + args.settle
        while True:
            s = probe(args.container, args.cookie)
            if (s["sessions"] == sessions and s["session_queue"] == 0) or time.monotonic() > deadline:
                break
            time.sleep(1)
        s["settled"] = s["sessions"] == sessions and s["session_queue"] == 0
        samples.append((name, s))
        print(f"{name}: total={mib(s['memory']['total'])} sessions={s['sessions']} "
              f"queued={s['session_queue']} settled={s['settled']}", flush=True)

    sample("idle", 0)
    clients = await connect_all(args, f"m{tag}a", args.clients)
    await asyncio.sleep(2)
    sample(f"{args.clients} connected", args.clients)
    await traffic(clients, args.messages, args.rate)
    await asyncio.sleep(2)
    sample("after traffic", args.clients)
    await quit_all(clients)
    sample("all quit", 0)
    for r in range(1, args.rounds + 1):
        batch = await connect_all(args, f"m{tag}{chr(ord('b') + r)}", args.churn)
        await traffic(batch, 5, args.rate)
        await quit_all(batch)
        sample(f"churn round {r}", 0)
    text = report(args, samples, started)
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(text, encoding="utf-8")
        print(args.output)
    else:
        print(text)
    if args.json:
        Path(args.json).write_text(json.dumps(dict(samples), indent=2), encoding="utf-8")
        print(args.json)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=16668)
    parser.add_argument("--container", default="briskd-memory-bench")
    parser.add_argument("--cookie", required=True, help="the node's BRISKD_COOKIE")
    parser.add_argument("--clients", type=int, default=1000)
    parser.add_argument("--members", type=int, default=50)
    parser.add_argument("--messages", type=int, default=10)
    # 1000 clients x 0.5/s into channels of 50 is about 25,000 deliveries a
    # second: a sustained load, not an overload that measures queued mail.
    parser.add_argument("--rate", type=float, default=0.5, help="messages per second per client")
    parser.add_argument("--settle", type=float, default=60,
                        help="seconds to wait for sessions and mailboxes to settle before a sample")
    parser.add_argument("--churn", type=int, default=500)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--concurrency", type=int, default=50)
    parser.add_argument("--note", default="")
    parser.add_argument("--output", default="")
    parser.add_argument("--json", default="")
    args = parser.parse_args()
    if args.clients > 9999 or args.churn > 9999:
        parser.error("--clients and --churn are at most 9999")
    asyncio.run(main(args))
