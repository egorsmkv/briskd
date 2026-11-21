# briskd memory

Measured 2026-11-21 10:23:00 UTC against `127.0.0.1:16668` (container `briskd-memory-bench`).
Production image `briskd:latest` (Dockerfile.prod, config/briskd.prod.json), started by bench/memory-prod.

Workload: 1000 clients in channels of 50, 10 channel messages each at 0.5/s per client, then 3 churn rounds of 500 clients (connect, register, join, message, quit). Every sample follows a full garbage collection of all processes, taken once every session's mailbox is empty and the expected sessions remain (at most 60 s; otherwise marked not settled).

| Step | Total | Processes | Binary | ETS | Atoms | Sessions | Session memory | Queued |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| idle | 71.5 MiB | 13.2 MiB | 0.8 MiB | 1.5 MiB | 1274.4 KiB | 0 | 0.0 MiB | 0 |
| 1000 connected | 80.8 MiB | 16.8 MiB | 2.9 MiB | 3.5 MiB | 1274.4 KiB | 1000 | 2.8 MiB | 0 |
| after traffic | 83.1 MiB | 15.8 MiB | 3.1 MiB | 6.6 MiB | 1274.4 KiB | 1000 | 1.4 MiB | 0 |
| all quit | 78.3 MiB | 14.6 MiB | 1.5 MiB | 5.9 MiB | 1274.4 KiB | 0 | 0.0 MiB | 0 |
| churn round 1 | 79.3 MiB | 14.4 MiB | 1.2 MiB | 7.3 MiB | 1274.4 KiB | 0 | 0.0 MiB | 0 |
| churn round 2 | 80.7 MiB | 14.4 MiB | 1.3 MiB | 8.6 MiB | 1274.4 KiB | 0 | 0.0 MiB | 0 |
| churn round 3 | 82.2 MiB | 14.4 MiB | 1.3 MiB | 10.0 MiB | 1274.4 KiB | 0 | 0.0 MiB | 0 |

Per connected client: 9.5 KiB of total node memory; the session process itself 2.8 KiB (heap and stack), plus 0.0 KiB of off-heap binaries it references.

Largest ETS tables at the last sample:

| Table | Rows | Bytes |
| --- | ---: | ---: |
| `channel_history` | 50 | 7176.6 KiB |
| `whowas` | 2500 | 876.3 KiB |
| `code_server` | 888 | 743.0 KiB |
| `briskd_holds` | 2500 | 388.0 KiB |
| `mnesia_gvar` | 703 | 97.9 KiB |
| `logger` | 4 | 53.1 KiB |
| `instrument_series` | 0 | 51.7 KiB |
| `livery_ratelimit` | 0 | 51.0 KiB |
| `instrument_span_exporters` | 0 | 51.0 KiB |
| `hackney_host_limits` | 0 | 51.0 KiB |
| `ac_tab` | 59 | 45.1 KiB |
| `briskd_connection_stats` | 0 | 29.1 KiB |
| `code_names` | 25 | 21.6 KiB |
| `user_modes` | 0 | 20.4 KiB |
| `briskd_nicks` | 0 | 20.4 KiB |

Largest registered processes at the last sample:

| Process | Memory | Mailbox |
| --- | ---: | ---: |
| `erl_prim_loader` | 21.1 KiB | 0 |
| `code_server` | 21.1 KiB | 0 |
| `release_handler` | 21.1 KiB | 0 |
| `briskd_sup` | 7.1 KiB | 0 |
| `application_controller` | 6.4 KiB | 0 |
| `init` | 5.7 KiB | 0 |
| `briskd_links` | 5.3 KiB | 0 |
| `briskd_webui` | 5.2 KiB | 0 |
| `net_kernel` | 4.2 KiB | 0 |
| `logger_std_h_default` | 3.9 KiB | 0 |
| `user_drv` | 3.9 KiB | 0 |
| `kernel_sup` | 3.7 KiB | 0 |
