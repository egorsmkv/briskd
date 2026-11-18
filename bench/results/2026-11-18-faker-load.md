# Faker load test — 2026-11-18

Measured 2026-11-18T19:19:02.742018+00:00 against `127.0.0.1:6667`; all six runs passed.

Environment: OTP 29.1.2; linux aarch64 CPUs=2 Memory=4195151872; host macOS-26.6.2-arm64-arm-64bit-Mach-O; Python 3.15.2; Faker 40.54.0.
Development server using `config/ircd.dev.json`; plaintext TCP only, default transient retention. No server code, configuration, or wire behavior changed.

Two repetitions at each size, five seconds each, ten messages per client per second. Fixed Faker seed 20261118; synthetic names and sentences generated before timing. Independent channels prevent traffic in #lobby. The same size uses identical message text in both repetitions, with fresh nicks/channels. Registration and JOIN precede timing; no traffic warmup.

| Clients | Run | Sent | Deliveries | Deliveries/s | p50 ms | p95 ms | p99 ms | p99.9 ms |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 1 | 500 | 4500 | 901.3 | 1.532 | 2.969 | 5.586 | 12.883 |
| 10 | 2 | 500 | 4500 | 901.2 | 1.743 | 3.29 | 6.422 | 35.184 |
| 25 | 1 | 1250 | 30000 | 6001.8 | 1.368 | 2.527 | 4.594 | 9.232 |
| 25 | 2 | 1250 | 30000 | 6002.2 | 1.318 | 2.791 | 22.328 | 70.31 |
| 50 | 1 | 2500 | 122500 | 24501.9 | 0.952 | 2.565 | 34.731 | 63.4 |
| 50 | 2 | 2500 | 122500 | 24499.5 | 0.964 | 1.665 | 5.002 | 25.603 |

Totals: 8,500 sent messages; 314,000 per-recipient latency samples and validated deliveries. Expected deliveries = sent × (clients − 1). No missing, duplicate, unexpected, corrupted, or self-echoed deliveries; no unexpected disconnects or errors.
Numeric 422 (missing MOTD) occurred once per client, 170 times total, and was allowed. All clients quit and closed their sockets at the end. Synthetic WHOWAS entries may remain under the server retention policy.

Client wire sizes: 82–222 bytes including CRLF, with per-run means about 145–146 bytes. Each message fans out to 9, 24, or 49 recipients. No TLS clients or server-link workload.

Docker collected 30 CPU/memory samples during traffic. Observed CPU range 8.74–103.51% (100% = one core). Raw memory observations are included in the JSON; these are coarse samples, not instantaneous peaks.

| Clients | Run | CPU sample range | Memory sample range (MiB) |
| ---: | ---: | ---: | ---: |
| 10 | 1 | 8.74–13.69% | 88.82–89.46 |
| 10 | 2 | 11.30–14.10% | 89.35–89.58 |
| 25 | 1 | 52.34–65.08% | 89.33–91.31 |
| 25 | 2 | 33.87–43.03% | 89.32–89.67 |
| 50 | 1 | 77.44–102.28% | 89.62–92.45 |
| 50 | 2 | 84.78–103.51% | 92.46–94.34 |

Latency is measured from sender enqueue to recipient reader processing on the host. It includes generator scheduling and Docker networking. Percentiles use a floor-index order statistic; samples from one fan-out message are correlated. The five-second windows are short and tails vary between repetitions. Throughput reflects the offered rate; maximum capacity and saturation were not measured.

Scheduler utilization, Erlang mailbox growth, GC, and kernel socket drops were not instrumented. Application-level disconnects and delivery failures were checked. TLS, server-link interoperability, malformed input, and prolonged soak behavior were not exercised by this workload. There was no optimization, so no before/after improvement is claimed. A preliminary run that overlapped repository checks was excluded; the reported run started after those checks completed.

Executed commands:

```sh
/tmp/ircd-faker-venv/bin/pip install Faker
/tmp/ircd-faker-venv/bin/python bench/faker_load.py --output bench/results/2026-11-18-faker-load.json
docker compose -f docker-compose.dev.yml exec -T ircd-dev just build
docker compose -f docker-compose.dev.yml exec -T ircd-dev just format-check
docker compose -f docker-compose.dev.yml exec -T ircd-dev just test
git diff --check
```

Load command exited 0. Build and format-check passed; EUnit: 27 tests, 0 failures. Python AST syntax and CLI help checks passed. The server remained running. The reusable runner and pinned dependency are documented in `bench/FAKER.md`; raw observations are in `2026-11-18-faker-load.json`.
