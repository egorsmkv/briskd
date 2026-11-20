# Faker load test, production image — 2026-11-20

Measured 2026-11-20T20:32:51.855554+00:00 against `127.0.0.1:16667` with `bench/prod`; all 6 runs passed.

Environment: ERTS 17.1.1, release 0.1.0; Docker host linux x86_64 CPUs=8 Memory=33562640384; Python 3.14.3 (uv, `bench/uv.lock`); Faker 40.54.0.
Production image (`Dockerfile.prod`) with `config/ircd.prod.json` unchanged (flood limits, DroneBL,
`channels` retention, JSON info logging) and a fresh data volume; plaintext TCP only.

2 repetitions at each size, 5 seconds each, 10 messages per client per second
(below the 20 messages per second flood limit). Seed 20261118. Registration and JOIN precede timing.

| Clients | Run | Sent | Deliveries | Deliveries/s | p50 ms | p95 ms | p99 ms | p99.9 ms |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 1 | 500 | 4500 | 901.2 | 1.269 | 1.803 | 2.346 | 2.917 |
| 10 | 2 | 500 | 4500 | 901.2 | 1.298 | 1.599 | 1.802 | 2.336 |
| 25 | 1 | 1250 | 30000 | 6002.6 | 1.724 | 2.406 | 2.77 | 3.242 |
| 25 | 2 | 1250 | 30000 | 6001.9 | 1.756 | 2.413 | 2.734 | 3.506 |
| 50 | 1 | 2500 | 122500 | 24497.9 | 1.189 | 1.83 | 3.088 | 4.7 |
| 50 | 2 | 2500 | 122500 | 24499.9 | 1.183 | 1.698 | 2.7 | 4.322 |

Totals: 8,500 sent messages; 314,000 validated per-recipient deliveries. No missing, duplicate,
unexpected, or self-echoed deliveries; no disconnects or error numerics. The server logged no
warnings or errors during the run.

Traffic is paced, so throughput is the offered workload, not capacity. These numbers come from a
different machine (x86_64, 8 CPUs) than the 2026-11-18 runs (aarch64, 2 CPUs) and are not a
before/after comparison with them.
