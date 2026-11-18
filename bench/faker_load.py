#!/usr/bin/env python3
"""Bounded Faker IRC fan-out test; install bench/requirements-faker.txt first.

RFC 2812 sections 3.1 and 3.3: await registration and JOIN before PRIVMSG,
keep all lines below 512 bytes, and expect no sender echo. Latencies include
host event-loop scheduling, Docker networking, and server time. This measures
a development listener, not maximum server capacity. No server settings change.
"""
import argparse
import asyncio
from collections import Counter
from datetime import datetime, timezone
from importlib.metadata import version
import json
from pathlib import Path
import platform
import secrets
import subprocess
import time

from faker import Faker


def summary(values):
    ordered = sorted(values)
    if not ordered:
        return {}
    return {f'p{p:g}_ms': round(1000 * ordered[min(len(ordered)-1, int((len(ordered)-1)*p/100))], 3)
            for p in (50, 95, 99, 99.9)}


def command(*args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=10).strip()
    except (OSError, subprocess.SubprocessError) as exc:
        return f'unavailable: {exc}'


async def trial(args, members, repeat, token):
    fake = Faker('en_US')
    fake.seed_instance(args.seed + members)  # Same generated workload for each repeat.
    channel = f'#load{token}{members}r{repeat}'
    count = int(args.duration * args.rate)
    clients, tasks, delays, registrations = [], [], [], []
    errors, numerics = [], Counter()
    sent, received, duplicates, unexpected, disconnects = 0, 0, 0, 0, 0
    pending = {}
    done = asyncio.Event()
    sample_stop = asyncio.Event()
    samples = []
    all_delivered = asyncio.Event()
    expected = members * count * (members - 1)
    # Pre-generate text so Faker work is excluded from the timed phase.
    messages = [[fake.sentence(nb_words=18).encode('ascii')[:240] for _ in range(count)]
                for _ in range(members)]
    wire_sizes = []

    async def collect(c):
        nonlocal received, duplicates, unexpected, disconnects
        try:
            while True:
                raw = await c['reader'].readline()
                if not raw:
                    if not done.is_set():
                        disconnects += 1
                        errors.append(f"unexpected EOF: {c['nick']}")
                    return
                line = raw.rstrip(b'\r\n')
                if line.startswith(b'PING '):
                    c['writer'].write(b'PONG ' + line[5:] + b'\r\n')
                    await c['writer'].drain()
                    continue
                prefix, _, rest = line.partition(b' ')
                verb, _, tail = rest.partition(b' ')
                if verb.isdigit():
                    if 400 <= int(verb) <= 599:
                        numerics[verb.decode()] += 1
                        # Missing MOTD is expected in this development setup.
                        if verb != b'422':
                            errors.append(line.decode(errors='replace')[:200])
                    if verb == b'001':
                        c['registered'].set()
                    if verb == b'366' and channel.encode() in tail.split():
                        c['joined'].set()
                if verb == b'ERROR' or line.startswith(b'ERROR '):
                    errors.append(line.decode(errors='replace')[:200])
                if verb != b'PRIVMSG':
                    continue
                target, _, body = tail.partition(b' :')
                if target != channel.encode():
                    continue
                key, _, _text = body.partition(b' ')
                entry = pending.get(key)
                if entry is None:
                    unexpected += 1
                    continue
                started, sender, payload, mask = entry
                bit = 1 << c['index']
                if sender == c['index'] or body != payload or prefix[1:].split(b'!')[0] != clients[sender]['nick'].encode():
                    unexpected += 1
                elif mask & bit:
                    duplicates += 1
                else:
                    entry[3] |= bit
                    received += 1
                    delays.append(time.perf_counter() - started)
                    if received == expected:
                        all_delivered.set()
        except (OSError, ValueError) as exc:
            errors.append(f"reader {c['nick']}: {exc}")

    async def connect(index):
        started = time.perf_counter()
        reader, writer = await asyncio.wait_for(asyncio.open_connection(args.host, args.port), 10)
        nick = fake.first_name()[:2].lower() + token + f'{index:03x}'
        c = dict(reader=reader, writer=writer, nick=nick, index=index,
                 registered=asyncio.Event(), joined=asyncio.Event())
        clients.append(c)
        tasks.append(asyncio.create_task(collect(c)))
        realname = fake.name()
        writer.write(f'NICK {nick}\r\nUSER {nick} 0 * :{realname}\r\n'.encode('ascii'))
        await writer.drain()
        await asyncio.wait_for(c['registered'].wait(), 10)
        registrations.append(time.perf_counter()-started)
        writer.write(f'JOIN {channel}\r\n'.encode())
        await writer.drain()
        await asyncio.wait_for(c['joined'].wait(), 10)

    async def sample():
        while not sample_stop.is_set():
            value = await asyncio.to_thread(command, 'docker', 'stats', '--no-stream', '--format', '{{json .}}', args.container)
            try:
                samples.append({'elapsed_s': round(time.perf_counter()-started, 3), **json.loads(value)})
            except json.JSONDecodeError:
                samples.append({'error': value})
                return
            try:
                await asyncio.wait_for(sample_stop.wait(), 0.5)
            except TimeoutError:
                pass

    async def produce(c):
        nonlocal sent
        for seq, text in enumerate(messages[c['index']]):
            # Stagger users and schedule at an absolute rate; lag is reported.
            due = started + seq / args.rate + c['index'] / members / args.rate
            await asyncio.sleep(max(0, due-time.perf_counter()))
            key = f'{c["index"]}:{seq}'.encode()
            payload = key + b' ' + text
            wire = b'PRIVMSG ' + channel.encode() + b' :' + payload + b'\r\n'
            assert len(wire) <= 350  # Leave room for the relayed user prefix.
            pending[key] = [time.perf_counter(), c['index'], payload, 0]
            c['writer'].write(wire)
            await asyncio.wait_for(c['writer'].drain(), 10)
            wire_sizes.append(len(wire))
            sent += 1

    monitor = None
    started = time.perf_counter()
    try:
        # Sequential startup preserves the client index used for delivery checks.
        for index in range(members):
            await connect(index)
        started = time.perf_counter()
        monitor = asyncio.create_task(sample())
        await asyncio.wait_for(asyncio.gather(*(produce(c) for c in clients)), args.duration+20)
        send_elapsed = time.perf_counter()-started
        await asyncio.wait_for(all_delivered.wait(), 10)
        elapsed = time.perf_counter()-started
        result = dict(clients=members, repeat=repeat, channel=channel, sent=sent,
                      expected_deliveries=expected, received_deliveries=received,
                      missing_deliveries=expected-received, duplicates=duplicates,
                      unexpected=unexpected, disconnects=disconnects, errors=errors,
                      error_numerics=dict(numerics), elapsed_s=elapsed,
                      send_elapsed_s=send_elapsed, messages_per_s=sent/send_elapsed,
                      deliveries_per_s=received/elapsed, latency_samples=len(delays),
                      delivery_latency=summary(delays), registration_latency=summary(registrations),
                      client_wire_bytes={'min': min(wire_sizes), 'max': max(wire_sizes),
                                         'mean': sum(wire_sizes)/len(wire_sizes)},
                      resource_samples=samples)
    except Exception as exc:
        result = dict(clients=members, repeat=repeat, failed=f'{type(exc).__name__}: {exc}',
                      sent=sent, expected_deliveries=expected, received_deliveries=received,
                      errors=errors, error_numerics=dict(numerics), resource_samples=samples)
    finally:
        sample_stop.set()
        if monitor:
            await monitor
        done.set()
        for c in clients:
            try:
                c['writer'].write(b'QUIT :Faker load test complete\r\n')
                await asyncio.wait_for(c['writer'].drain(), 2)
            except (OSError, TimeoutError):
                pass
            c['writer'].close()
        for c in clients:
            try:
                await asyncio.wait_for(c['writer'].wait_closed(), 2)
            except (OSError, TimeoutError):
                pass
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    return result


async def main(args):
    report = dict(when=datetime.now(timezone.utc).isoformat(), target=f'{args.host}:{args.port}',
                  python=platform.python_version(), host=platform.platform(), faker=version('Faker'),
                  seed=args.seed, duration_s=args.duration, messages_per_client_s=args.rate,
                  tls_fraction=0, warmup='registration and JOIN; no traffic warmup',
                  environment=command('docker', 'info', '--format', '{{.OSType}} {{.Architecture}} CPUs={{.NCPU}} Memory={{.MemTotal}}'),
                  otp=command('docker', 'exec', args.container, 'cat', '/usr/local/lib/erlang/releases/29/OTP_VERSION'),
                  limitations=['Development server; host generator shares resources with Docker.',
                               'Scheduler utilization, Erlang mailbox lengths, GC and kernel socket drops were not instrumented.',
                               'No code/configuration changes or before/after optimization comparison; repeated identical workloads only.',
                               'Delivery latency is per recipient, from writer enqueue to reader processing; includes generator scheduling.',
                               'Docker CPU/memory are coarse container samples; no capacity or saturation claim.'], runs=[])
    for members in args.clients:
        for repeat in range(1, args.repeats+1):
            result = await trial(args, members, repeat, secrets.token_hex(2))
            report['runs'].append(result)
            print(json.dumps({k: v for k, v in result.items() if k != 'resource_samples'}), flush=True)
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            Path(args.output).write_text(json.dumps(report, indent=2)+'\n')
            if result.get('failed') or result.get('errors') or result.get('missing_deliveries') or result.get('duplicates') or result.get('unexpected'):
                raise SystemExit('Load test failed; see report')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=6667)
    parser.add_argument('--clients', type=int, nargs='+', default=[10, 25, 50])
    parser.add_argument('--duration', type=float, default=5)
    parser.add_argument('--rate', type=float, default=10)
    parser.add_argument('--repeats', type=int, default=2)
    parser.add_argument('--seed', type=int, default=20261118)
    parser.add_argument('--container', default='irc-server-ircd-dev-1')
    parser.add_argument('--output', default='bench/results/faker-load.json')
    args = parser.parse_args()
    if not all(2 <= n <= 100 for n in args.clients) or not (0 < args.duration <= 60 and 0 < args.rate <= 100 and 1 <= args.repeats <= 5) or int(args.duration*args.rate) < 1:
        parser.error('Require 2..100 clients, duration <=60s, rate <=100/s, repeats 1..5, at least one message/client')
    asyncio.run(main(args))
