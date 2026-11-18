# AGENTS.md — Erlang/OTP 29 Telecom Engineering Standard

> Instructions for Codex and other coding agents working in this repository.
> Target: **Erlang/OTP 29.x**, production-grade, high-availability telecom/network services.
> Apply the stricter of this file, existing repository conventions, applicable protocol specifications, and the task's explicit requirements. Do not invent protocol semantics or benchmark results.

## 1. Mission and priorities

Build **correct, interoperable, secure, observable, fault-contained, low-latency, and operable** network services. Prefer measured efficiency to clever micro-optimizations. Optimize in this order:

1. Protocol conformance and safety (including untrusted inputs).
2. Correctness of state transitions, timers, transactions, and lifecycle.
3. Availability, bounded resource use, and overload behavior.
4. Operability: logs, metrics, tracing, configuration, and upgrades.
5. Throughput, tail latency, and memory efficiency based on profiling.
6. Maintainable, idiomatic OTP code and reproducible releases.

Do not trade off a MUST-level requirement of a protocol for speed. When a task is ambiguous, inspect the project and relevant normative RFC/3GPP/ETSI/ITU-T specification and document the assumption; never silently reinterpret wire formats. Explicitly distinguish **standards compliance**, **implementation policy**, and **operator configuration**.

## 2. Working protocol for the agent

1. Inspect `README*`, `rebar.config`, `rebar.lock`, `apps/`, `src/`, `test/`, `config/`, `rel/`, existing `AGENTS.md` in subordinate directories, and CI before changing code.
2. Determine the service role (SIP proxy/registrar/B2BUA, RTP relay, SBC, Diameter peer, SIGTRAN gateway, SS7, MQTT/IoT signaling, etc.), ingress transport, trust boundary, and authoritative protocol specification/version.
3. Write down invariants and failure modes for changes to parsers, codecs, transactions, state machines, timers, routing, persistence, or network IO.
4. Make the smallest coherent change; preserve public APIs and on-wire behavior unless the task explicitly requires a breaking change.
5. Add or update regression, malformed-input, timeout, overload, and interop tests proportionate to the change.
6. Run the project checks. Report exact commands and results; never claim tests or performance measurements that were not performed.
7. For performance work, record an identical baseline and after measurement, traffic shape, environment, OTP version, sample count, throughput, p50/p95/p99/p99.9 latency, CPU and scheduler utilization, memory, mailbox growth, GC, socket drops, and error counts.
8. End with concise changes, compatibility/operational impact, tested behavior, remaining risks, and any skipped checks.

Do not perform unrelated refactors. Do not suppress warnings or relax TLS/protocol validation merely to get a green build. Do not change production defaults for timeouts, transport, thread/scheduler counts, or queue sizes without documenting rollout and fallback.

### Repository development environment

- Use the repository's Docker development environment as the standard Erlang setup. It pins the OTP 29 image and provides `rebar3` and `just`; avoid relying on a host Erlang installation.
- Start it from the repository root with `docker compose -f docker-compose.dev.yml up --build -d`. The checkout is mounted at `/workspace`; the container runs the server with `config/ircd.dev.json` and publishes IRC on host port 6667.
- Run repository commands in the running container:

  ```sh
  docker compose -f docker-compose.dev.yml exec -T ircd-dev just build
  docker compose -f docker-compose.dev.yml exec -T ircd-dev just format-check
  docker compose -f docker-compose.dev.yml exec -T ircd-dev just test
  ```

  Use `docker compose -f docker-compose.dev.yml exec ircd-dev sh` for an interactive shell.
- Stop the environment with `docker compose -f docker-compose.dev.yml down`. Its named Rebar3 cache and Mnesia development database persist across restarts. Use `down -v` only when intentionally deleting both volumes and their contents.
- Keep development settings in `config/ircd.dev.json`; do not point the dev container at production configuration or host Mnesia data.

## 3. Erlang/OTP 29 rules

- Support **OTP 29.x**; build and test against the latest *approved, security-patched* 29.x release available to the deployment, not an assumed exact patch version. Keep CI and release version pins aligned. Never use features requiring OTP 30.
- Prefer `gen_server`, `gen_statem`, `supervisor`, `application`, `proc_lib` (only for specialized infrastructure), `ets`, `persistent_term` (only for rarely updated immutable configuration), `logger`, `telemetry` where dependency policy allows, and standard OTP networking components before custom infrastructure.
- Use `gen_statem` with `state_functions` or `handle_event_function` for SIP transactions, dialogs, handshakes, Diameter peer lifecycle, transport connection setup, registration expiry, retry/failover, and any nontrivial timed protocol automaton. Use `gen_server` for straightforward serialized resource ownership and coordination. Use pure functions for codecs, routing decisions, policy evaluation, and deterministic transformations.
- Prefer `try ... catch` to the deprecated old-style `catch` operator. Keep compiler warnings enabled; fix OTP 29 warnings, including unsafe-function warnings, rather than globally muting them.
- OTP 29's `is_integer(Value, Min, Max)` guard BIF is appropriate for validated bounded integer fields. Make clear whether bounds are inclusive and test both edges.
- OTP 29's multi-valued comprehensions may simplify *clear* transformations; do not use novelty syntax if loops, generators, or comprehensions are easier to review. `compr_assign` is opt-in; only use if enabled deliberately, documented, and supported by formatter/static analysis/CI.
- `maybe ... else ... end` is supported; use when it makes successive `{ok, Value}`/error steps easier to read, not to obscure protocol branches.
- **Native records in OTP 29 are experimental.** Do **not** use them by default for persisted data, external APIs, hot-upgrade state, cross-node messages, or long-lived telecom sessions. Stable traditional records (in `.hrl` only if shared), maps at appropriate boundaries, or explicit versioned tuples are safer. Any native-record use requires a documented reason, migration strategy, and compatibility tests.
- Use OTP 29 `-unsafe`/compiler and `xref` safety diagnostics to catch risky calls. `ignore_xref` is for narrowly justified false positives, never a blanket exemption. Do not call untrusted `binary_to_term/1` or create atoms from network data.
- OTP 29 provides `ct_doctest` for executable documentation examples; use it for applicable documented public codecs/APIs when the project's test runner can invoke it.
- OTP 29 changed security-related defaults (including SSH shell/exec and SFTP services); do not re-enable interactive code execution as a convenience. Pin/verify TLS and crypto options based on peers' interoperability and security policy, not assumptions about runtime defaults.
- Prefer modern `format_status/1` for redacting process state exposed by OTP system/status output, when the callback is appropriate for the chosen behaviour.
- Consult the installed runtime docs for each API and verify OTP-29 compatibility before introducing a new BIF, socket option, compile flag, or release feature.

## 4. Project structure and naming

For a new multi-service system, prefer a Rebar3 **umbrella project** with separate OTP applications for protocols and operational concerns; for a compact service, use one app. An example (adapt, do not force onto an existing tree):

```text
apps/
  telecom_core/              # identifiers, common errors, configuration, routing primitives
    src/telecom_core.app.src
    src/telecom_core_app.erl
    src/telecom_core_sup.erl
  telecom_sip/               # SIP codec, transport, transactions, registrar/dialogs
    src/telecom_sip.app.src
    src/telecom_sip_app.erl
    src/telecom_sip_sup.erl
    src/telecom_sip_parser.erl
    src/telecom_sip_transaction.erl
    test/telecom_sip_parser_tests.erl
    test/telecom_sip_SUITE.erl
  telecom_media/             # RTP/RTCP/SRTP only if product owns media plane
config/
  sys.config
  vm.args
rel/
test/                        # cross-application integration and soak suites
bench/                       # reproducible load generation, fixtures and reports
priv/                        # bounded immutable assets, protocol dictionaries
rebar.config
rebar.lock
AGENTS.md
```

- `snake_case` filenames, functions, variables (`RequestId` uses Erlang variable case), module names with application prefix, descriptive function names, and coherent one-module-one-responsibility scope.
- Every runtime application must declare its `.app.src` dependencies correctly, have an `application` callback and supervision tree when stateful, and avoid hidden startup side effects.
- Keep dependency direction acyclic: codec/domain libraries do not reach into transport processes; transports emit normalized data to protocol engines. Media and signaling are independently scalable when architecture warrants it.
- Define narrow public APIs. `-export` only intentionally public functions and required callbacks; `-export_type` public types. `-spec` on public and meaningful internal functions; use `-type`/`-opaque` for domain values. Treat Dialyzer as discrepancy detection, not a proof of type safety.
- Do not make every module a process. Use pure stateless functions for parsers, serializers, validators, and protocol decision tables.
- Do not use dynamic atoms for tenant IDs, SIP methods, hostnames, subscriber identifiers, header names, or received enum strings. Use binaries and bounded atom conversion only from a fixed compile-time whitelist.

## 5. Style, formatting, and error contracts

- Use the existing formatter/configuration. If none exists, adopt **erlfmt** (or a compatible Rebar3 formatting integration) and pin its version; do not assume `rebar3 fmt` exists without configuring the plugin/provider. CI must enforce formatting with the installed tool's verified check command.
- Consistently indent and let the formatter decide layout. No trailing whitespace, unexplained numeric literals, giant functions, mixed naming styles, or speculative abstractions.
- Prefer pattern matching and explicit clauses over deep nested `case` or `if`. Match only validated data; use clear error branches for external input.
- Use `ok`, `{ok, Value}`, `{error, Reason}` for expected API results; make `Reason` a stable, documented, machine-readable atom/tuple/map and preserve diagnostic context without exposing secrets.
- Invalid peer/network data is **not** an unexpected programmer error; reject or discard safely with a bounded metric/log and appropriate protocol response. Broken internal invariants can fail the owning process so supervision restores a clean state.
- No blanket `catch _:_ -> ok`, no `exit(Pid, kill)` as routine control flow, no infinite retry loops, no silent message drops, no unbounded list accumulation.
- Prefer `logger` structured metadata and lazy/bounded formatting; never synchronously print per RTP packet or per SIP retransmit in the hot path.
- Include documentation (`-moduledoc`/`-doc` where supported), units, semantics of timer values, protocol references, and operational rationale for unusual decisions. Wire constants must name their specification and section where possible.

## 6. OTP process model and fault containment

- Use explicit supervision trees: listener supervisors, connection supervisors, transaction/session supervisors, per-peer supervisors, and separate workers for storage/metrics where needed. Choose `one_for_one`, `rest_for_one`, or `one_for_all` based on **actual** dependency semantics. Set restart intensity and shutdown periods deliberately.
- Prefer `start_link` under supervisors. Use `temporary` for finite transactions that must not restart, `transient` when only abnormal termination should restart, and `permanent` for enduring service infrastructure. Prevent stale supervisors and restart storms.
- A process owns the state/resources it mutates: socket, transaction timers, per-connection ordering, ETS write ownership, and session-specific counters. Avoid concurrent uncoordinated mutation through global ETS.
- A process per call/dialog/transaction/peer can be reasonable; **a process per media packet is not**. Validate memory footprint and process churn at realistic concurrency.
- Keep `handle_call`, `handle_cast`, and state-machine event handlers nonblocking and short. No slow storage, DNS lookup, TLS handshake, external HTTP call, or high-cost codec work in a central scheduler-critical process; offload with supervised, bounded workers and correlation references.
- Do not issue cyclic synchronous `gen_server:call`s. Set explicit call deadlines; handle late replies and monitor `DOWN` cleanly. Use asynchronous request patterns when helpful and ensure request IDs cannot cross sessions.
- Handle `'EXIT'`, `'DOWN'`, socket close/error, peer timeout, and supervisor shutdown without leaking registrations/timers/ETS rows/sockets. Use `monitor` rather than links when the failure relationship requires monitoring without shared fate.
- Use `send_after`, `start_timer`, `gen_statem` timeouts or state timeouts as appropriate. Explicitly cancel and disambiguate stale timeouts (reference/generation IDs). Timeouts must use **monotonic** time; wall clocks only for external timestamps/accounting. Use absolute deadlines to avoid repeated-work drift.
- Avoid a single process for all tenants/sessions/calls. Shard hot ownership by peer/session/key where necessary; benchmark ETS contention and mailbox pressure.
- Enforce mailbox bounds by design: explicit admission control, demand/credit, receiver backpressure, selective-message-flow discipline, and operational thresholds. Erlang mailboxes are not intrinsically bounded.
- For high-volume message handlers, document handling of unknown messages (`handle_info`), shutdown and overload. Do not use `process_flag(trap_exit, true)` without lifecycle reasoning.

## 7. Networking, binaries, and hot-path performance

- Choose `gen_tcp`/`gen_udp`/`ssl` for mature APIs and portability. Evaluate OTP `socket` API for advanced socket controls, batching, or measured performance gains (e.g. platform-supported `sendmmsg`) with OS support and fallback documented. Do not assume every transport supports identical active-mode or ownership semantics.
- For TCP/TLS, explicitly handle message framing, `packet` settings, partial reads, coalesced frames, size limits, slowloris behavior, high-water marks, timeouts, and backpressure. For SIP over stream transports, parse by the RFC framing rules, **not** arbitrary read boundaries.
- For UDP, assume loss, duplication, reordering, datagram-size limits, and spoofing. Keep receiver work bounded; schedule expensive decode/transaction processing across workers. Define routing and socket ownership strategy; validate `recvmmsg`/`sendmmsg` availability before using batched syscalls.
- On listeners and per-peer sockets, configure and document buffer sizes, active/passive flow mode, `nodelay` (when suitable), keepalive and OS resource limits. Use `{active, once}` or a carefully reasoned active-N receive loop if compatible with transport APIs and demand; rearm only when consumer capacity exists.
- Prefer **binaries** for on-wire messages and externally supplied text. Use binary pattern matching and iodata (`iolist()`/`iodata()`) to avoid repeated concatenations and copies. Use bounded `binary:copy/1` only when retaining a tiny slice would otherwise pin a huge reference-counted binary.
- Avoid unnecessary `binary_to_list`, `list_to_binary`, `iolist_to_binary`, `binary:split` allocations, regexes, repeated scanning, and serialization in hot paths; profile before replacing readable code.
- Decode incrementally when needed. Validate lengths, maximum nesting, extension counts, integer ranges, checksums and unknown fields **before** allocations or expensive work. Do not create atoms from input or deserialize untrusted external Erlang terms.
- Do not block schedulers with long NIFs, spin loops, or CPU-heavy crypto. Prefer standard OTP crypto/SSL; if native code is unavoidable, use dirty schedulers or ports with failure and backpressure contracts, and benchmark under contention.
- Use ETS where concurrent, ephemeral indexed state benefits from it; select table type (`set`, `ordered_set`, `bag`) and `read_concurrency`/`write_concurrency` only after profiling. Avoid full-table scans in request path. `persistent_term` updates are globally expensive—never use for frequently changing subscriber/session state.
- Avoid unbounded process dictionaries, per-packet heap churn, timer churn, and unnecessary copying across process boundaries. Do not set scheduler flags, heap settings, GC thresholds, or `+P`/`+Q` blindly; profile release-mode VM under representative traffic first.
- Load-shed **before** state allocation where possible. Use per-IP/peer/tenant/session quotas, bounded decode buffers, rate limits, deadlines, and fair work scheduling. Define explicit policies for 429/503 or protocol-equivalent overload behavior; include `Retry-After` only where appropriate.

## 8. Telecom-specific protocol engineering

### 8.1 Standards and interoperability

- Identify the exact protocol and revision. Relevant examples: SIP RFC 3261 plus applicable extension RFCs; SDP RFC 8866 and relevant offer/answer rules; RTP/RTCP RFC 3550/3551; SRTP RFC 3711/5764 as applicable; STUN/TURN/ICE RFC 8489/8656/8445; Diameter RFC 6733 with specific application dictionaries; SCTP RFC 9260; SIGTRAN/M3UA RFC 4666; 3GPP TS 29.xxx interfaces. **These are examples, not a claim that every service implements them.**
- Keep a `docs/protocols.md` (or equivalent) list of exact implemented specs, versions, optional extensions, compliance gaps, feature flags, and interop peers. Check IANA registries and errata when adding values.
- Parsers and encoders must preserve semantics of unknown-but-legal extension fields and reject malformed input safely. Do not normalize case-sensitive parameters or assume extension ordering when protocol defines otherwise. Explicitly test canonical and noncanonical legal variants.
- Enforce transaction IDs, routing, dialog identity, branch/tag semantics, sequence numbers, and authentication replay resistance according to the *specific* protocol. Do not generalize SIP transaction rules to Diameter or RTP.
- Distinguish **request deduplication**, **retransmission**, **idempotency**, and **at-most-once processing**; UDP retransmissions and failovers can change each independently.

### 8.2 SIP, SDP, and signaling (when applicable)

- Separate message codec, transport connection, transaction state machine, dialog/session logic, registrar/location service, proxy/B2BUA policy, and routing. Do not conflate a SIP transaction with a dialog or media session.
- Implement client/server transaction state machines, retransmission timers, ACK/CANCEL handling, forked responses, provisional/final responses, and transport-dependent behavior from the applicable RFC. Name timers using RFC notation and test their precise triggers and termination.
- Apply RFC-compliant `Content-Length` framing over TCP/TLS and check declared body length against configured caps. Handle duplicate headers, compact forms, folded lines if supported by the chosen specification/compatibility policy, weird whitespace, and malformed or conflicting framing deterministically.
- Validate `Via`, `Max-Forwards`, `Call-ID`, CSeq, tags, `Contact`, `Route`/`Record-Route`, `Expires`, `Authorization` and digest parameters as relevant. Avoid open relay, request smuggling, unsafe header reflection, and accidental amplification.
- SIP digest auth requires correct algorithm/qop/nonce handling, expiry, nonce-count/replay prevention and constant-time comparison where relevant; do not store plaintext credentials or leak auth material.
- SDP negotiation is explicit: codec/payload mappings, fmtp, ptime, direction, address family, ICE and DTLS-SRTP attributes, renegotiation and hold/resume. Do not assume PT 96 means the same codec in both directions.

### 8.3 RTP/RTCP and real-time media (when applicable)

- Keep media-plane packet handling free of blocking calls and verbose logs; use appropriately bounded socket/event-loop workers. Avoid a gen_server synchronous hop per packet unless benchmarked as acceptable for the target.
- Parse RTP header, CSRC/extension/padding and sequence/timestamp/SSRC correctly; validate lengths before reads. Support SSRC collision/change/restart, sequence wraparound and reorder windows where the product requires them.
- Jitter buffers must have defined capacity, adaptive policy, loss/late/drop behavior, clock-rate conversion and packetization constraints. Use monotonic deadlines; avoid treating RTP timestamps as wall-clock time.
- RTCP reporting, NACK/feedback, congestion control and pacing are implementation- and protocol-dependent; avoid assumptions of guaranteed delivery. SRTP must include replay-window, rollover counter, key lifecycle, authentication and rekey testing when used.
- Measure packet loss, jitter, one-way/round-trip latency (where measurable), MOS or R-factor only when methodology is declared, RTP gap/reorder, CPU per stream, and p99 packet-processing delay. Do not claim accurate one-way delay without clock synchronization.

### 8.4 Diameter, SS7/SIGTRAN and 3GPP (when applicable)

- Prefer the OTP `diameter`/`asn1`/`megaco`/`snmp` applications where they fit the required protocols rather than writing a new stack; validate feature coverage and peer interoperability first.
- Diameter: validate command/application IDs, end-to-end and hop-by-hop identifiers, AVP vendor flags/length/padding, session lifecycle, peer watchdog, duplicate handling, failover, capability negotiation and overload policy. Keep AVP dictionary generation deterministic and tested.
- SCTP/M3UA/SS7: test stream/association restart, point-code and routing-context mapping, network-byte-order encodings, malformed parameters, failover and multi-homing; clearly separate MTP/M3UA layer from application semantics.
- 3GPP messages: pin exact TS version/release, feature-support bits and vendor extensions. Generate ASN.1/codec artifacts reproducibly and test captured (sanitized) real peer traces where legally available.

## 9. Security, privacy, and abuse resistance

- All ingress is untrusted: validate sizes, encodings, integer bounds, nesting, resource impact, header multiplicity, and compressed/padded content before state allocation. Fuzz parsers and transaction sequences.
- Use TLS/DTLS/mTLS/SRTP/IPsec where the interface and threat model require them. Verify peer identities, hostname/SAN, certificate lifetime, trust roots, protocol version, and cipher/group policy; never set `verify_none` for production endpoints.
- OTP 29 TLS defaults may evolve. State explicit policy where interoperability matters; validate current OTP documentation and peer behavior. Document fallback behavior without silent downgrade.
- Do not expose Erlang distribution/EPMD, remote shell, debug endpoints, or internal metrics to public ingress; isolate control and management planes. Secure node cookies and evaluate TLS distribution if distributed Erlang is used.
- Protect against SIP scanning, credential stuffing, INVITE floods, registration hijack, toll fraud, transaction/state exhaustion, UDP amplification, parser bombs and malformed-media attacks. Per-tenant isolation and fraud thresholds must be explicit.
- Redact or tokenize phone numbers (E.164/MSISDN), IMSI/SUPI, IMEI, IPs where personal data, SIP URIs, auth headers, session keys, SDP credentials, recordings, and subscriber records according to data policy. Keep raw packets out of default logs.
- Secret management via injected configuration/secret store; never commit passwords, cookies, private keys, or real customer PCAPs. Enforce rotation and least privilege.
- Handle regulatory and lawful-intercept obligations only under explicit, documented requirements and access controls; do not silently build surveillance features.

## 10. Configuration, releases, and operations

- Use Rebar3 and `rebar.lock` for reproducibility. Keep runtime configuration in `sys.config`/environment-provider mechanism and `vm.args`, with schema validation at startup; reject invalid configuration early.
- Package **OTP releases** for services (`rebar3 release`, or existing release tooling). Define applications, dependencies, start types, ERTS inclusion policy, boot scripts, runtime config, and container/systemd lifecycle. Do not ship a development shell as the normal production launcher.
- `application:start/2`/`prep_stop/1`/`stop/1` and graceful shutdown must stop accepting, drain or reject in-flight work within a fixed deadline, flush accounting/CDRs when applicable, and close sockets cleanly.
- Define readiness distinct from liveness: readiness requires configured listener, dependency/peer state as product policy dictates, available capacity, and initialized routing; liveness should not flap simply because an upstream peer is down.
- Provide deployment runbooks: startup/shutdown, drain, emergency rollback, certificate rotation, disaster recovery, overload recovery, log redaction, backup/restore, and release verification.
- If hot-code upgrades are required, write and test `.appup`/`.relup`, `code_change/3`, supervision spec changes and schema migration, including rollback and mixed-version node/serialization compatibility. Do not claim hot upgrade support merely because BEAM supports code loading.
- Rolling replacement is usually simpler than hot upgrades; decide based on actual call/session continuity requirements and quantify interruption. Never silently drop live calls on rollout.
- Avoid distributed Erlang across untrusted networks by default. If clustering is needed, specify discovery, partition behavior, ownership fencing, quorum/consistency, idempotent reconciliation, failover semantics, and what happens to active dialogs/transactions during node loss.
- Storage design must declare durability, partitioning, migration, index strategy, backup, failure mode, and consistency level. Choose ETS for ephemeral local cache, persistent backing stores for authoritative subscriber/charging/session records; do not assume Mnesia alone is a universal carrier-grade durable database.

## 11. Observability and SLOs

- Make service-level SLOs explicit: request success, setup completion, signaling latency by procedure, sustained CPS/TPS, concurrent calls/sessions, media packet loss and jitter, availability and recovery time.
- Record rates and distributions by operation/status/transport/peer/region; include p50/p95/p99/p99.9 where relevant. Cardinality must be bounded: never label metrics with Call-ID, IMSI, phone number, transaction ID, or dynamic user/session identifier.
- Instrument queue depth, oldest mailbox age where measurable, process count, reductions, per-scheduler utilization, run queue, GC, memory/binary allocator use, ETS size, socket receive/drop counts, TCP retries, TLS handshake failures, transaction retransmits, timeout rates, overload rejects and supervisor restarts.
- Use `logger` levels correctly, structured fields, redaction, and overload-resistant handlers. Logs are diagnostic events, not an audit substitute; audit high-risk configuration/admin changes separately.
- Propagate correlation across signaling hops with privacy-safe IDs; preserve telecom trace context without changing standards wire fields improperly. Packet captures only with controlled sampling, explicit retention, and sanitization.
- An alert must represent impact or imminent saturation; provide actionable runbook references and avoid high-cardinality or high-volume alerts.

## 12. Tests, simulation, and quality gates

### Unit and property tests

- Use **EUnit** for pure functions and compact module tests; **Common Test** for multi-process/network scenarios and integration; **PropEr** or another explicitly approved property-based tool for codecs, state-machine commands, and adversarial sequences.
- Verify parse/encode round trips subject to canonicalization rules. Cover empty, max-size, truncated, extra bytes, unknown extensions, duplicate/conflicting fields, integer min/max, invalid UTF-8 where relevant, address edge cases, and malformed length/padding.
- Property tests must constrain generation to manageable resource use and shrink failing cases into retained fixtures. Test valid and invalid grammar separately; never assert an arbitrary invalid byte stream must always produce a single specific error unless contract requires it.
- Test timer, retry and race semantics using injected monotonic clock/deadline or controlled timers where practical instead of brittle `timer:sleep` assertions. Assert invariants, not scheduling luck.

### Network/protocol and resilience tests

- Include TCP partial frames, multiple messages in one read, UDP duplicates/loss/reorder, TLS handshake failure, peer disconnect, half-open connection, NAT/rebinding if relevant, backpressure, DNS failures, authentication replay, flood protection, and large concurrent sessions.
- Test supervisor restart, process death, stale timer delivery, connection churn, node crash/rejoin, split brain (if clustered), ETS ownership transfer if used, storage unavailability, resource exhaustion, and graceful drain.
- Use SIPp or comparable SIP traffic generation where applicable; use packet/stream simulators, protocol-specific test harnesses, and reproducible PCAPs stripped of subscriber data. External interoperability is a **separate** gate from local unit test success.
- Add long-running soak, steady-state concurrency, spike, brownout, and recovery tests. Assert bounded mailbox, memory, latency, drop/error rates and service recovery, not only request throughput.
- Exercise IPv4 and IPv6, TCP/UDP/TLS/DTLS/SCTP as implemented, and fragmentation limits under realistic network emulation.

### Minimum checks (adjust to actual project tools)

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
rebar3 release
```

Run configured formatter check, property/fuzz suites, docs checks, integration tests and release smoke tests where available. Verify whether a selected provider or plugin exists before invoking it. Prefer CI profiles that keep production dependencies separate from test-only tools. Treat new compilation, Dialyzer, Xref and formatting errors as defects; explain inherited warnings separately.

## 13. Benchmarking and acceptance criteria

- Define load model before tuning: signaling CPS/TPS, requests/s, call duration and concurrent sessions, codec mix, packet sizes/pps, payload distributions, peer count, TLS percentage, auth mix, retransmission/loss, and geographic RTT.
- Measure in packaged **release mode**, warmed up, with exact OTP/ERTS, CPU topology, OS/kernel, NIC, scheduler settings and protocol load generator version. Load generators and monitoring must not become the bottleneck.
- Baseline and modified tests must use matched conditions and repeated samples; report variance/CI as appropriate. Look at p99/p99.9 and saturation knees, not averages alone.
- For optimization proposals, include flamegraphs/profiling where supported, scheduler/run-queue and mailbox metrics, GC/binary memory, context switches, socket/kernel counters and before/after accuracy checks.
- Define acceptance thresholds in the task/SLO; do not invent universal telecom performance numbers. Reject throughput improvements that introduce parse errors, dropped transactions, leaked sessions, degraded tail latency or unstable overload recovery.
- Gate new network parsers against fuzzing and memory ceilings, codecs against deterministic golden vectors, transaction engines against model/state tests, and transports against loss/reorder/failover tests.

## 14. Agent completion checklist

A change is done only when the agent can answer **yes**, or explicitly report why not, for each item:

- Did I check the existing architecture and pin the protocol revision and relevant RFC/3GPP clauses?
- Are ingress input, size, state, timers, resource budgets, and failure handling bounded?
- Are correct OTP behaviour, ownership, supervision and shutdown semantics preserved?
- Are OTP 29 features used only when stable, compatible and useful; are experimental features guarded?
- Are security, secrets, privacy, rate limits and fraud/abuse implications reviewed?
- Are formatting, specs, documentation, dependencies and release packaging maintained?
- Did I run applicable compile, unit, integration, static analysis, protocol, and release checks?
- Did I benchmark any performance claim with reproducible baseline and tail-latency metrics?
- Did I document API/wire compatibility, rollout, operational metrics and remaining risks?

## 15. Authoritative references

Consult primary sources for details and current errata; this file sets engineering policy, not a replacement for the specifications.

- OTP 29 release/highlights: https://www.erlang.org/news/188 and https://www.erlang.org/blog/highlights-otp-29/
- OTP 29 docs and release notes: https://www.erlang.org/docs/29/ and https://www.erlang.org/downloads/29
- `gen_statem`: https://www.erlang.org/docs/29/apps/stdlib/gen_statem.html
- Socket: https://www.erlang.org/docs/29/apps/kernel/socket.html
- SSL: https://www.erlang.org/docs/29/apps/ssl/ssl.html
- Logger: https://www.erlang.org/docs/29/apps/kernel/logger.html
- Rebar3: https://rebar3.org/docs/
- RFC Editor: https://www.rfc-editor.org/ ; IANA: https://www.iana.org/protocols
- 3GPP specifications: https://www.3gpp.org/specifications

**If a source conflicts with this file on normative protocol semantics, follow the applicable published standard and flag the conflict.**
