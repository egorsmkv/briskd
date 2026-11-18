# Faker load test

Run against an already running development server on localhost:6667:

```sh
python3 -m venv /tmp/ircd-faker-venv
/tmp/ircd-faker-venv/bin/pip install -r bench/requirements-faker.txt
/tmp/ircd-faker-venv/bin/python bench/faker_load.py --output bench/results/faker-load.json
```

Defaults: 10, 25, and 50 simultaneous TCP clients, two repetitions per size,
five seconds per repetition, ten messages per client per second. Faker supplies
synthetic names and sentences with seed 20261118. Nicknames contain a fresh
random suffix to avoid the server's nickname hold. Each repetition uses its own
`#load...` channel; clients quit and sockets close at completion or failure.
No server configuration changes are made. Synthetic WHOWAS records can remain
under the configured retention policy.

The runner waits for registration and the end of NAMES before sending. It
answers server PING and checks each message's sender, content, and recipient
exactly once. Sender echo is excluded. It fails on missing, duplicate, or
unexpected deliveries, disconnects, and unexpected error numerics. Numeric 422
(missing MOTD) is counted and allowed. Lines are ASCII and capped below the IRC
512-byte limit, including room for the server-added source prefix.

JSON records per-recipient p50/p95/p99/p99.9 latency, registration latency,
message sizes, counts, throughput, error numerics, and Docker resource samples.
Latency starts just before the generator queues a message and ends when a
recipient reader processes it. It includes generator scheduling and Docker
networking. Traffic is paced, so throughput is an achieved offered workload,
not a maximum capacity measurement. Run without concurrent builds or tests.
Docker CPU is reported relative to one core and can exceed 100%.

Optional flags include `--clients 10 25 50`, `--duration 5`, `--rate 10`,
`--repeats 2`, `--seed 20261118`, `--host`, `--port`, and `--container`.
This runner targets plaintext client sessions only; TLS, direct server links,
malformed input, saturation, and prolonged soak behavior are outside its scope.
Scheduler utilization, mailbox lengths, GC, and kernel socket drops are not
instrumented. The JSON report states these limitations explicitly.
