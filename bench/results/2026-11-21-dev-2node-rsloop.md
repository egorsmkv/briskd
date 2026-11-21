# briskd bench

Measured 2026-11-21 14:56:54 UTC against `127.0.0.1:6667`.
Welcome numeric: `:irc.dev 001 b98007712 :Welcome to IRC b98007712!b98007712@172.20.0.1`.
Load generator event loop: `rsloop`.

This is the development server (`rebar3 shell` in the OTP 29 container),
not a packaged release. One container sample taken during registration:
`irc-server_briskd-dev_1 cpu=1.68% mem=328.5MiB / 31.26GiB`. OTP: `29 17.1.1`.

Same setup as `2026-11-21-dev-2node.md` (two linked development servers,
both switched from `trace` to `info` logging at runtime; container samples
cover `irc-server_briskd-dev_1` only), with the load generator on rsloop
0.1.69.

## Traffic

- Sequential `PING`/`PONG`, 100 samples, 0 errors.
  p50 0.18 ms, p95 0.23 ms, p99 0.70 ms.
- Pipelined `PING`, 400 of 1000 `PONG` replies in 0.024s (16641.0/s).
- Registration, 200 welcomes of 200 attempts, concurrency 32, 0.407s (491.2/s). Welcome p50 59.68 ms, p95 80.70 ms. Errors: 0.
- Channel `PRIVMSG`: 8 members, 800 messages sent, 5600 of 5600 deliveries in 0.150s (37242.6/s deliveries).

A sender does not receive its own channel message, so the expected
delivery count is `members * messages_each * (members - 1)`.
Clients quit at the end of each phase. Nicks stay reserved for 60 seconds.

## High load

10000 of 10000 clients connected and registered in 33.2 s (301.4/s); welcome p50 425.07 ms, p99 5211.89 ms.
Clients per server (round-robin, so channels span the servers and every message crosses the link): `127.0.0.1:6667` 5000, `127.0.0.1:6668` 5000.
Every server listed every channel member 0.2 s after the joins (the send phase waits for this).

100,000 channel messages from 10,000 clients in 200 channels of up to 50, sent as one burst per client in 0.27 s.
Deliveries: 4,900,000 of 4,900,000 expected in 52.01 s, 94214.2/s.
Delivery latency from send to receipt (49,000 sampled messages): p50 31297.97 ms, p95 50717.48 ms, p99 51616.12 ms, p99.9 51753.90 ms, max 51762.49 ms.
Disconnects during the phase: 0; error numerics: none.
After the phase a new client registered within 21.0 s.
Load generator CPU during the phase: 88% of one core .

## Commands

Each family runs 30 times on one client, each followed by
`PING <marker>`; latency is the time until that PONG, so it covers the whole
reply. Errors count 4xx/5xx numerics, `FAIL` replies, and timeouts.

| Command | Runs | ops/s | p50 | p95 | p99 | max | Errors |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PING | 30 | 1569.7 | 0.58 ms | 0.85 ms | 1.01 ms | 1.01 ms | 0 |
| CAP LS | 30 | 1358.8 | 0.72 ms | 0.80 ms | 0.82 ms | 0.82 ms | 0 |
| CAP LIST | 30 | 1664.7 | 0.58 ms | 0.68 ms | 0.73 ms | 0.73 ms | 0 |
| ISUPPORT | 30 | 1601.7 | 0.61 ms | 0.69 ms | 0.69 ms | 0.69 ms | 0 |
| PRIVMSG user | 30 | 1780.8 | 0.53 ms | 0.72 ms | 0.76 ms | 0.76 ms | 0 |
| NOTICE user | 30 | 1627.4 | 0.59 ms | 0.78 ms | 0.81 ms | 0.81 ms | 0 |
| TAGMSG user | 30 | 1850.7 | 0.52 ms | 0.64 ms | 0.71 ms | 0.71 ms | 0 |
| PRIVMSG channel | 30 | 1760.4 | 0.55 ms | 0.65 ms | 0.69 ms | 0.69 ms | 0 |
| NOTICE channel | 13 | 1000.3 | 0.61 ms | 0.67 ms | 0.67 ms | 0.67 ms | 1 |
| BATCH multiline | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| JOIN+PART | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| TOPIC set | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| TOPIC query | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| NAMES | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| LIST | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| MODE channel query | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| MODE channel set | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| MODE ban list | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| MODE user | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| INVITE | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| WHO channel | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| WHOX | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| WHOIS | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| WHOWAS | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| ISON | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| USERHOST | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| AWAY | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| SETNAME | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| NICK change | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| MONITOR | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| METADATA set+get | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| CHATHISTORY LATEST | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| MARKREAD | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| RENAME | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| LUSERS | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| MOTD | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| VERSION | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| TIME | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| INFO | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| ADMIN | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| LINKS | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| STATS u | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| STATS m | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| SERVLIST | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| AUTHENTICATE PLAIN | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |
| PRIVMSG+REDACT | 0 | 0.0 | n/a | n/a | n/a | n/a | 0 |

Error examples:

- NOTICE channel: `EOFError: b88007713: connection closed`
- BATCH multiline: `skipped: connection closed by the server`
- JOIN+PART: `skipped: connection closed by the server`
- TOPIC set: `skipped: connection closed by the server`
- TOPIC query: `skipped: connection closed by the server`
- NAMES: `skipped: connection closed by the server`
- LIST: `skipped: connection closed by the server`
- MODE channel query: `skipped: connection closed by the server`
- MODE channel set: `skipped: connection closed by the server`
- MODE ban list: `skipped: connection closed by the server`
- MODE user: `skipped: connection closed by the server`
- INVITE: `skipped: connection closed by the server`
- WHO channel: `skipped: connection closed by the server`
- WHOX: `skipped: connection closed by the server`
- WHOIS: `skipped: connection closed by the server`
- WHOWAS: `skipped: connection closed by the server`
- ISON: `skipped: connection closed by the server`
- USERHOST: `skipped: connection closed by the server`
- AWAY: `skipped: connection closed by the server`
- SETNAME: `skipped: connection closed by the server`
- NICK change: `skipped: connection closed by the server`
- MONITOR: `skipped: connection closed by the server`
- METADATA set+get: `skipped: connection closed by the server`
- CHATHISTORY LATEST: `skipped: connection closed by the server`
- MARKREAD: `skipped: connection closed by the server`
- RENAME: `skipped: connection closed by the server`
- LUSERS: `skipped: connection closed by the server`
- MOTD: `skipped: connection closed by the server`
- VERSION: `skipped: connection closed by the server`
- TIME: `skipped: connection closed by the server`
- INFO: `skipped: connection closed by the server`
- ADMIN: `skipped: connection closed by the server`
- LINKS: `skipped: connection closed by the server`
- STATS u: `skipped: connection closed by the server`
- STATS m: `skipped: connection closed by the server`
- SERVLIST: `skipped: connection closed by the server`
- AUTHENTICATE PLAIN: `skipped: connection closed by the server`
- PRIVMSG+REDACT: `skipped: connection closed by the server`

## Server statistics

- Uptime (`STATS u`): Server Up 0 days 00:24:21.
- LUSERS 251 There are 2 users and 0 invisible on 1 servers
- LUSERS 254 1013 channels formed
- LUSERS 255 I have 2 clients and 0 servers
- LUSERS 265 2 5000 Current local users 2, max 5000
- LUSERS 266 2 10000 Current global users 2, max 10000
- Container over the run (54 samples): CPU avg 200.5%, max 347.7%; memory min 336.1 MiB, max 1059.8 MiB; processes max 39; network I/O at end 631MB / 1.44GB.

`STATS m` delta for this run: 72537 commands, 1601424 bytes received.

| Command | Count | Bytes | Avg bytes |
| --- | ---: | ---: | ---: |
| PRIVMSG | 50860 | 1207740 | 23.7 |
| NICK | 5216 | 83456 | 16.0 |
| USER | 5216 | 140882 | 27.0 |
| QUIT | 5071 | 65923 | 13.0 |
| JOIN | 5010 | 87420 | 17.4 |
| PING | 793 | 8641 | 10.9 |
| NAMES | 200 | 3690 | 18.4 |
| CAP | 63 | 1010 | 16.0 |
| NOTICE | 44 | 1284 | 29.2 |
| ISUPPORT | 30 | 300 | 10.0 |
| TAGMSG | 30 | 1020 | 34.0 |
| STATS | 2 | 18 | 9.0 |
| LUSERS | 1 | 8 | 8.0 |
| REGISTER | 1 | 32 | 32.0 |
