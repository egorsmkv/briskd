# AGENTS.md — Erlang/OTP 29 IRC Server Engineering Standard

> Instructions for coding agents working in this repository.
> Target: **Erlang/OTP 29.x** IRC server (`ircd`): TCP/TLS client sessions, channel state, and direct server links.
> Apply the stricter of this file, existing repository conventions, applicable IRC specifications, and the task's explicit requirements. Do not invent protocol semantics or benchmark results.

## 1. Mission and priorities

Build a **correct, interoperable, secure, observable, fault-contained, and operable** IRC server. Prefer measured efficiency to clever micro-optimizations. Optimize in this order:

1. Protocol conformance and safety for untrusted client and server-link input.
2. Correctness of registration, channel membership, modes, timers, and link lifecycle.
3. Availability, bounded resource use, and overload behavior.
4. Operability: logs, configuration, persistence, and upgrades.
5. Throughput, tail latency, and memory efficiency based on profiling.
6. Maintainable, idiomatic OTP code.

Do not trade off a MUST-level requirement of the implemented IRC specifications for speed. When a task is ambiguous, inspect the code, [README.md](README.md), [ROADMAP.md](ROADMAP.md), and the relevant RFC, then document the assumption. Never silently reinterpret wire formats. Explicitly distinguish **standards compliance**, **implementation policy**, and **operator configuration**.

This tree implements **selected parts** of RFC 1459 and RFC 2810–2813. It is not a complete IRC daemon. `ROADMAP.md` is the coverage record: a checked item is present, and it does not mean every edge case in the cited RFC is done. Extend behavior only when the task asks for it, and update the roadmap and README when coverage changes.

Where RFC 1459 and RFC 2812 disagree, keep the choice already encoded in this server and name it in the change. Identity comparison uses the **RFC 1459** case mapping in `ircd_wire:fold/1` (`[\]^` fold to `{|}~`). IRCv3 support covers the specifications on <https://ircv3.net/irc/>, including the deprecated `STARTTLS`; `ROADMAP.md` lists each one. `CAP LS` advertises the set in `ircd_cap`, `CAP REQ` is atomic, and an unknown subcommand returns 410. Server tags are filtered per recipient in `ircd_state_send`. Keep draft capability names prefixed exactly as the specification publishes them, and change a draft only when the published draft changes.

## 2. Working protocol for the agent

1. Inspect `README.md`, `ROADMAP.md`, `rebar.config`, `rebar.lock`, `src/`, `include/`, `test/`, `config/`, and CI before changing code.
2. Treat ingress as two trust classes: **unregistered or registered clients** on the TCP/TLS listener, and **configured server peers** on direct links. Name the RFC section the change follows (client protocol RFC 2812 / RFC 1459, channels RFC 2811, server protocol RFC 2813, or the default port in RFC 7194).
3. Write down invariants and failure modes for changes to the wire codec, registration, channel modes, numerics, timers, server-link routing, Mnesia persistence, or socket IO.
4. Make the smallest coherent change. Preserve public APIs and on-wire behavior unless the task explicitly requires a breaking change.
5. Add or update regression tests for malformed lines, registration, channel rules, timeouts, admission limits, and link behavior in proportion to the change.
6. Run the project checks. Report exact commands and results. Never claim tests or performance measurements that were not performed.
7. For performance work, record an identical baseline and after measurement: client count, message rate and size, channel fan-out, TLS mix, environment, OTP version, sample count, throughput, p50/p95/p99/p99.9 latency, CPU and scheduler utilization, memory, mailbox growth, GC, socket drops, and error numerics.
8. End with concise changes, wire and operational impact, tested behavior, remaining risks, and any skipped checks.

Do not perform unrelated refactors. Do not suppress warnings or relax TLS or protocol validation to get a green build. Do not change production defaults for timeouts, ports, client limits, or queue sizes without documenting rollout and fallback.

### Repository development environment

- Use the repository's Docker development environment as the standard Erlang setup. It pins the OTP 29 image and provides `rebar3` and `just`. Avoid relying on a host Erlang installation.
- Start it from the repository root with `docker compose -f docker-compose.dev.yml up --build -d`. The checkout is mounted at `/workspace`. The container runs the server with `config/ircd.dev.json` and publishes IRC on host port 6667.
- Run repository commands in the running container:

  ```sh
  docker compose -f docker-compose.dev.yml exec -T ircd-dev just build
  docker compose -f docker-compose.dev.yml exec -T ircd-dev just format-check
  docker compose -f docker-compose.dev.yml exec -T ircd-dev just test
  ```

  Use `docker compose -f docker-compose.dev.yml exec ircd-dev sh` for an interactive shell.
- Stop the environment with `docker compose -f docker-compose.dev.yml down`. Its named Rebar3 cache and Mnesia development database persist across restarts. Use `down -v` only when intentionally deleting both volumes and their contents.
- Keep development settings in `config/ircd.dev.json`. Do not point the dev container at production configuration or host Mnesia data.

## 3. Erlang/OTP 29 rules

- Support **OTP 29.x**. Build and test against the latest approved, security-patched 29.x release available to the deployment, not an assumed exact patch version. Keep CI and release version pins aligned. Never use features requiring OTP 30.
- Prefer `gen_server`, `gen_statem`, `supervisor`, `application`, `proc_lib` (only for specialized infrastructure), `ets`, `persistent_term` (only for rarely updated immutable configuration), `logger`, and standard OTP networking (`gen_tcp`, `ssl`) before custom infrastructure.
- Use `gen_statem` when a connection has a nontrivial timed automaton (registration timeout, link handshake, reconnect, ping/pong liveness) and the extra states make the transitions clearer. Use `gen_server` for straightforward serialized ownership, which is how `ircd_session`, `ircd_listener`, `ircd_link`, and `ircd_state` are written today. Use pure functions for the wire codec, case folding, mask matching, and other deterministic decisions.
- Prefer `try ... catch` to the deprecated old-style `catch` operator. Keep compiler warnings enabled. `rebar.config` sets `warnings_as_errors`. Fix OTP 29 warnings, including unsafe-function warnings, rather than globally muting them.
- OTP 29's `is_integer(Value, Min, Max)` guard BIF is appropriate for validated bounded integer fields such as ports and channel limits. Make clear whether bounds are inclusive and test both edges.
- OTP 29's multi-valued comprehensions may simplify clear transformations. Skip novelty syntax when an ordinary comprehension is easier to review. `compr_assign` is opt-in; use it only if enabled deliberately, documented, and supported by the formatter and CI.
- `maybe ... else ... end` is supported. Use it when successive `{ok, Value}` / error steps are easier to read. Keep protocol branches explicit.
- **Native records in OTP 29 are experimental.** Do not use them for Mnesia rows, external APIs, hot-upgrade state, or long-lived session state. Stable traditional records (in `include/*.hrl` when shared), maps at boundaries, or explicit versioned tuples are the right tools. Any native-record use needs a documented reason, a migration strategy, and compatibility tests.
- Use OTP 29 compiler and `xref` safety diagnostics to catch risky calls. `ignore_xref` is for a narrowly justified false positive. Do not call untrusted `binary_to_term/1` or create atoms from network data.
- OTP 29 provides `ct_doctest` for executable documentation examples. Use it for public wire helpers when the project's test runner can invoke it.
- OTP 29 changed security-related defaults, including SSH shell/exec and SFTP services. Do not re-enable interactive code execution as a convenience. Pin TLS versions and crypto options from this server's configuration and peer interoperability policy (TLS 1.2 and 1.3 on the direct TLS listener). Do not assume runtime defaults.
- Prefer modern `format_status/1` for redacting process state exposed by OTP system/status output when the callback fits the behaviour. Redact passwords, link secrets, and message bodies.
- Consult the installed runtime docs for each API and verify OTP 29 compatibility before introducing a new BIF, socket option, compile flag, or release feature.

## 4. Project structure and naming

This repository is one Rebar3 application, `ircd`. Keep that shape. Do not introduce an umbrella or split apps unless the task asks for it.

```text
src/ircd.app.src
src/ircd_app.erl             # application callback
src/ircd_sup.erl             # rest_for_one: state, sessions, links, listeners
src/ircd_config.erl          # JSON config load and validation (IRCD_CONFIG)
src/ircd_wire.erl            # line parse/encode, message tags, RFC 1459 case fold
src/ircd_cap.erl             # per-connection capability negotiation and values
src/ircd_conn.erl            # per-connection IRCv3 state (account, MONITOR, metadata, batch)
src/ircd_isupport.erl        # RPL_ISUPPORT (005) tokens
src/ircd_account.erl         # accounts and SCRAM-SHA-256 verifiers
src/ircd_sasl.erl            # SASL PLAIN, EXTERNAL, SCRAM-SHA-256 (pure)
src/ircd_websocket.erl       # RFC 6455 handshake and framing (pure)
src/ircd_state.erl           # state process, command dispatch, public API
src/ircd_state_client.erl    # registration, identity, visibility, connection stats
src/ircd_state_channel.erl   # membership, modes, names, and safe-channel reop
src/ircd_state_link.erl      # burst, import, propagation, and multi-hop delivery
src/ircd_state_net.erl       # known servers, services, netsplits, and holds
src/ircd_route.erl           # pure hop, loop, burst-order, and numeric decisions
src/ircd_state_info.erl      # operator, statistics, and server query commands
src/ircd_state_send.erl      # numeric replies, tag filtering, batches, client delivery
src/ircd_state_v3.erl        # IRCv3 accounts, SASL, identity, and notifications
src/ircd_state_monitor.erl   # MONITOR and extended-monitor
src/ircd_state_history.erl   # chathistory, read markers, redaction
src/ircd_state_batch.erl     # client batches and draft/multiline
src/ircd_state_meta.erl      # draft/metadata-2
src/ircd_state_sync.erl      # accounts, metadata, read markers across server links
src/ircd_state_queries.erl   # WHO/WHOIS/WHOWAS and related numerics
src/ircd_listener.erl        # TCP or TLS accept loop
src/ircd_session.erl         # one client connection
src/ircd_sessions.erl        # client supervisor and max_clients admission
src/ircd_link.erl            # one direct server peer
src/ircd_links.erl           # link supervisor
src/ircd_log.erl
include/ircd_state.hrl       # includes the records below
include/ircd_client.hrl
include/ircd_channel.hrl
include/ircd_remote.hrl
include/ircd_account.hrl     # account and read_marker records
include/ircd_wire.hrl        # wire buffer limit
config/ircd.json             # sample/operator config
config/ircd.dev.json         # development container config
test/
justfile
rebar.config
rebar.lock
```

- `snake_case` filenames and functions. Module names stay prefixed with `ircd_`. Erlang variables use the usual capitalised form (`Nick`, `Channel`).
- The runtime application declares its `.app.src` dependencies, starts through `ircd_app`, and builds its supervision tree in `ircd_sup`. Avoid hidden startup side effects.
- Keep the wire codec free of process calls. Sessions and links own sockets and turn lines into calls on `ircd_state`. State owns nick, channel, and peer records.
- `-export` only intentionally public functions and required callbacks. `-export_type` public types. `-spec` public and meaningful internal functions. Treat Dialyzer as discrepancy detection, not a proof of type safety.
- A new module is a process only when it owns a socket, a timer set, or exclusive mutable state. Parsers, serializers, mask matchers, and numeric formatting stay pure.
- Commands, numerics, nicknames, channel names, server names, and mode flags travel as **binaries**. Convert to atoms only from a fixed compile-time whitelist (listener kind, known internal reasons). Never create an atom from a line on the wire.

## 5. Style, formatting, and error contracts

- Format with the pinned **erlfmt** plugin (`erlfmt` 1.3.0 in `rebar.config`). Check with `just format-check` and write with `just format`. The print width is 100.
- Let the formatter decide layout. Leave out trailing whitespace, unexplained numeric literals, giant functions, and speculative abstractions.
- Prefer pattern matching and explicit clauses over deep nested `case` or `if`. Match only validated data. External input gets a clear error branch and, where the RFC requires it, a numeric reply.
- Use `ok`, `{ok, Value}`, and `{error, Reason}` for expected API results. `ircd_wire` also returns `empty` and `error` for lines; keep that contract stable. Reasons are stable atoms, tuples, or maps, and they carry diagnostic context without secrets.
- Invalid client or peer data is an expected protocol event. Reject it with a bounded log and the appropriate numeric or `ERROR`, and keep the process alive when the session can continue. A broken internal invariant may fail the owning process so supervision restores a clean state.
- No blanket `catch _:_ -> ok`, no `exit(Pid, kill)` as routine control flow, no infinite retry loops, no silent drops of registered-user commands, and no unbounded list accumulation of lines or members.
- Log with `logger` through `ircd_log`: JSON (default; a map report becomes top-level fields) or `text` (OTP `logger_formatter`). The application has no third-party runtime dependencies. Log events, not every channel message.
- Document non-obvious functions with `-doc` or `%% @doc`, including timer units and the RFC section for wire constants (512-octet line, RFC 1459 case map, nickname length, channel name limits).

## 6. OTP process model and fault containment

Current ownership:

- `ircd_state` owns Mnesia-backed nick, channel, whowas, and peer records, and applies command effects.
- `ircd_session` owns one client socket, its read buffer, registration status, and per-connection timers.
- `ircd_sessions` admits clients up to `max_clients` and supervises sessions.
- `ircd_listener` owns one TCP or TLS listen socket.
- `ircd_link` owns one direct peer connection, its handshake, ping/pong, and burst/routing for that hop.
- `ircd_sup` uses `rest_for_one`: state, then the session supervisor, then the link supervisor, then listeners. Listeners exist only for configured non-`null` ports.

Follow that ownership. Choose `one_for_one`, `rest_for_one`, or `one_for_all` from real dependency semantics. Set restart intensity and shutdown periods deliberately.

- Prefer `start_link` under supervisors. Use `temporary` for work that must not restart, `transient` when only abnormal termination should restart, and `permanent` for the enduring state, listener, and link infrastructure.
- The process that mutates a resource owns it: the socket, that connection's timers, and writes to its session fields. Do not mutate another session's socket from a helper process.
- One process per client connection and per server link is the model. One process per `PRIVMSG` or per channel member is not.
- Keep `handle_call`, `handle_cast`, and event handlers short. DNS lookups for peer hosts, TLS handshake work, and large bursts stay off the path that must also answer unrelated clients. Bound any worker and carry a correlation reference.
- Avoid cyclic synchronous `gen_server:call`s between `ircd_state`, sessions, and links. Set explicit call deadlines. Handle late replies and monitor `DOWN`. A request identifier from one connection must not apply to another.
- On `'EXIT'`, `'DOWN'`, socket close, peer timeout, and supervisor shutdown, drop the nick registration, channel membership, timers, and Mnesia rows that belong to that connection. Use `monitor` when the watcher must survive the watchee.
- Timeouts use monotonic time and a stored reference so a stale `ping`, registration, or reop timer cannot fire for a newer generation. Wall clock is for `TIME` and externally visible timestamps only.
- `ircd_state` is a single writer for protocol state. If a change makes its mailbox the bottleneck, shard only with a measured plan and preserved IRC ordering for a given nick and channel. Erlang mailboxes are unbounded; admission (`max_clients`, line buffering, per-connection read limits) happens before more state is allocated.
- Document unknown `handle_info` messages, shutdown, and overload for any high-volume handler. Use `process_flag(trap_exit, true)` only with a stated lifecycle reason.

## 7. Networking, binaries, and hot-path performance

- Clients and server links are **TCP or TLS streams**. Frame by IRC lines, not by read size. A read may contain a partial line, one line, or many lines. Buffer the remainder, cap the buffer, and close the connection that exceeds it (slow senders, missing CRLF).
- An untagged IRC line is at most **512 octets including the trailing CRLF** (at most 510 octets of content). A tagged line may add a tag section of at most 8191 bytes (`@`, tag data, and the separating space) and still keeps the non-tag portion at 512 octets. Tag data over 4094 bytes is numeric 417 on a client socket and a dropped link for a peer. The absolute read cap is `?MAX_WIRE_LINE` in `include/ircd_wire.hrl`. NUL, bare CR, or bare LF inside the line is malformed. Encoding goes through `ircd_wire:line/4` and `ircd_wire:message/5`. `line/4` drops a line that cannot fit rather than splitting one logical message across illegal extra lines.
- Client input uses `parse_client/1`. A client-supplied prefix is rejected. `parse/1` is the untagged client helper and rejects tags. Server-link input uses `parse_server/1` and may carry a source prefix and client-only tags. Keep that split: a client must not inject a nick or server prefix.
- Commands are a letter run or a three-digit numeric. Parameters stop at 15. A colon introduces the trailing parameter, which may contain spaces. Preserve trailing-parameter semantics when echoing text into `PRIVMSG`, `NOTICE`, `TOPIC`, `KICK`, or a numeric.
- Configure listen sockets with explicit active mode, backlog, and timeouts. `{active, once}` (or an equivalently bounded active-N loop) rearms only after the current lines are accepted. Set `nodelay` on interactive client sockets when measuring shows it helps, and document the choice.
- Prefer binaries and iodata for lines and nick/channel names. Avoid `binary_to_list` and repeated concatenation on the send path. Copy a sub-binary when retaining a small nick or topic would pin a large receive buffer.
- Validate size and shape before channel joins, mode changes, or Mnesia writes. Do not build atoms, run unbounded regexes, or scan all channels on every line.
- TLS is the OTP `ssl` listener on `tls_port` with `certfile` and `keyfile`, versions TLS 1.2 and 1.3. Peer-link TLS follows the peer's `tls` flag. State the verify and cipher policy in the change that touches it. Do not weaken verification to make a link come up.
- Mnesia holds durable **WHOWAS** history and **safe-channel** state. Ordinary channels, client sessions, and imported peer state are transient and disappear on restart. ETS remains appropriate for ephemeral indexes if a measured change needs them. `persistent_term` is for rarely replaced immutable configuration, never for nick or membership tables.
- Load-shed before allocating session state. `max_clients` is the configured cap. Further limits (per-connection line rate, nick-change rate, join rate) need an explicit operator-facing behavior and a numeric or disconnect reason. This protocol has no HTTP 429; do not invent a fake status code.

### 7.1 Allocation, lists, and binary construction

Apply the [Efficiency Guide](https://www.erlang.org/docs/23/efficiency_guide/users_guide.html) as background reading. It describes OTP 23, while this repository targets OTP 29. Verify compiler optimizations, binary representation details, timer implementation, system limits, and profiler availability against the installed OTP 29 documentation and measurements. Do not copy historical memory sizes, speed ratios, or emulator flags into sizing rules.

- `Left ++ Right` copies the left list. Avoid repeatedly appending to a growing accumulator; prepend and reverse once, or use `lists:reverse/2` when attaching a tail. A short, bounded left operand is acceptable; do not ban `++` categorically.
- Keep nested iodata through APIs that accept it, including socket sends. Avoid `lists:flatten/1` merely to send a line. Use `iolist_size/1` for byte counts and `iolist_to_binary/1` when a contiguous binary is actually required. Preserve the codec's line limits and public return contracts.
- `length/1` traverses a list. Avoid repeated full traversals of growing member or recipient lists; use an existing count or a bounded traversal when appropriate. Pattern matching for a minimum length must not accidentally admit improper lists previously rejected by validation. Prefer `byte_size/1`, `bit_size/1`, and `tuple_size/1` over ambiguous `size/1`.
- Use bit syntax for binary decomposition. When optimizing binary builders, examine whether matching, sending, storing, or retaining earlier accumulator versions forces later appends to copy on OTP 29. Do not assume every binary append copies, or that every append is free. Keep the existing receive-buffer cap.
- Review binary lifetime as well as allocation: small retained slices can retain their backing receive binary. Copy at a long-lived ownership boundary when needed, rather than copying every parsed field.
- For long scalar reductions over lists, prefer a tail-recursive accumulator to avoid stack growth. Do not replace list subtraction (`--`) with set conversions based on pre-OTP-22 complexity claims; preserve duplicate and ordering semantics and measure on OTP 29.
- Prefer a single traditional-record update for related field changes over a loop of `setelement/3` calls on a large tuple. Verify compiler behavior before attempting tuple update micro-optimizations; do not adopt historical index-order tricks or tuple/list conversions as a general rule.
- Keep dispatch clauses explicit and preserve first-match behavior. Do not rearrange overlapping clauses or replace direct calls with dynamic `apply/3` for presumed speed. Compiler diagnostics for binary optimizations may help a focused investigation, but verify OTP 29 support and keep diagnostic flags out of committed build settings.
- Choose clear body recursion, tail recursion, comprehensions, and funs without blanket speed claims. Long-running custom process loops must be tail-recursive; keep ordinary connection lifecycle handling in OTP behaviours. Do not introduce NIFs or drivers as a presumed speedup: require profiling evidence and account for scheduler blocking and VM-wide failure risk.

### 7.2 Message, timer, and table costs

- Process messaging generally copies ordinary terms; reference-counted binary payloads can be shared within a node. Keep session and link messages small. Pass only needed fields to workers and avoid fun closures that capture entire state records. Channel fan-out still allocates message envelopes and recipient queues even when payload bytes are shared.
- Selective receives can scan queued messages. Use OTP request/reply mechanisms and fresh correlation references for bounded workers; do not add nested receive loops inside callbacks to wait for unrelated work. Inspect mailbox growth before changing concurrency.
- Prefer `erlang:send_after/3` or `erlang:start_timer/3` for connection timers, with the stale-timer protections in section 6. Do not apply historical timer-server bottleneck claims to all OTP 29 `timer` functions; `timer:tc` is also suitable for local timing.
- Prefer keyed ETS/Mnesia lookups and justified indexes to whole-table materialization. When a scan is necessary, consider match specifications that return only required fields and bounded selection batches. Batch size bounds returned data, not necessarily total scan work; preserve query completeness and IRC reply ordering.
- Reuse records already fetched within a command when ownership guarantees they remain valid. Account for copying and loss of term sharing across ETS and process boundaries. Do not replace Mnesia transactions with dirty operations, change durability, or bypass the state owner solely for speed; preserve existing consistency semantics.
- Change heap sizes, mailbox storage options, ETS concurrency options, or scheduler settings only after measuring the affected workload. Include aggregate memory at the configured client cap and retained binary memory; fewer GCs alone do not establish an improvement.

### 7.3 Capacity and native boundaries

- More schedulers cannot make a single busy state owner execute commands in parallel. Measure runnable work and scheduler utilization before adding processes; a benchmark with many waiting clients may still exercise a sequential bottleneck. Preserve section 6's ownership and ordering rules.
- Budget `max_clients` against measured per-session memory, TLS overhead, peer workers, runtime process/port limits, and OS file-descriptor/socket limits, leaving capacity for supervision, logging, and reconnects. Inspect actual deployment limits rather than taking numeric defaults from the old guide. Raising VM or OS limits does not replace admission control.
- Keep `gen_tcp` and `ssl` as the networking interfaces. If an explicitly scoped task introduces a native driver, review driver/port locking, callback scheduling, binary ownership, reference counts, and cleanup against OTP 29 driver documentation. Iodata support alone does not guarantee zero copying; callback/API choice matters. Splitting one logical operation into multiple port calls requires an owner that prevents interleaving. Do not add a driver solely to apply this guide's C examples.

## 8. IRC protocol engineering

### 8.1 Specifications in force

| Area | Specification | This server |
| --- | --- | --- |
| Original protocol and RFC 1459 case mapping | RFC 1459 | Case folding, nickname checks, and legacy command behavior where the code follows 1459 |
| Architecture | RFC 2810 | Clients, channels, and directly connected servers |
| Channel management | RFC 2811 | Implemented subset: membership, modes, masks, safe `!` channels, local `&` channels |
| Client protocol | RFC 2812 | Implemented commands and numerics listed in the README |
| Server protocol | RFC 2813 | Direct and multi-hop peers, `PASS`/`SERVER`, burst, routing, and netsplit cleanup |
| Default port | RFC 7194 | TCP `6667` unless configured otherwise |

Check errata and IANA IRC numeric/mode assignments before adding a numeric or a mode letter. Update `ROADMAP.md` and the README command list in the same change. Interoperability with a second `ircd` (or another RFC 2813 peer) is a separate gate from unit tests.

Parsers accept the grammar they claim and reject the rest with `error` or the RFC numeric for that command. Test legal variants that differ in spacing and trailing-parameter shape, plus truncated, overlong, empty, and prefix-spoofed lines.

### 8.2 Client connection and registration

- A session is unregistered until the required `NICK` and `USER` (and `PASS` when `client_password` is set) complete. Registration has a timeout. Commands that require a registered user receive the numeric the RFC specifies for that state (`451` where applicable).
- Nickname character set and length follow `ircd_wire:nickname/1` (RFC 1459 length and the implemented character set). Collisions use folded identity. Channel names follow `ircd_wire:channel/1`: `#`, `&`, `+`, and safe `!` names.
- Compare nicknames, channel names, and ban masks with `ircd_wire:fold/1`. Do not use Unicode case fold or RFC 2812 ASCII-only fold for stored identities.
- Successful registration produces the welcome numeric sequence this server already sends. Failures use the erroneous-nickname, nickname-in-use, or password numerics already implemented. Keep numeric text stable when clients match on it, and keep the numeric code correct even if the human text changes.
- `PING`/`PONG` liveness uses the connection's own token. A `QUIT` or socket drop removes the nick everywhere it is visible, including direct peers when propagation for that event exists.
- `OPER` checks the configured `operators` and `administrators` lists. `KILL` and `REHASH` stay operator-only. A successful administrator login also grants channel operator on channels named in `channels`. Operator and link passwords are compared without early-exit leaks where the code path can do so, and they are never logged or placed in replies.

### 8.3 Channels

- Apply membership, key, limit, invite, ban, exception, moderation, and member-only checks in the order the existing command handlers use, and extend that order only with the RFC rule cited in the change.
- Channel types in this tree: `#` standard, `&` local (not sent to peers as a shared channel), `+` modeless where accepted by `ircd_wire`, `!` safe channels with the five-character id and creator/`+r` reop behavior. Anonymous `+a` is defined for local `&` and safe `!` channels. Preserve those visibility rules in `NAMES`, `WHO`, `WHOIS`, `PRIVMSG`, and `NOTICE`.
- User mode `+i` hides a user from queries unless the requester shares a channel. That shared-channel check includes remote members. Do not show an invisible remote user who does not share a channel with the requester.
- Op, voice, and creator privileges are per-channel membership. A mode change, kick, topic, or invite from a peer still requires the remote member to hold the privilege the local handler enforces.
- Reop delay for an operatorless safe channel comes from `reop_delay` (seconds, with the implemented jitter). Use a monotonic timer and cancel it when an operator returns or the channel is destroyed.

### 8.4 Server links

Linking is RFC 2813 over configured direct peers, with introductions of servers behind those peers. Loop prevention, burst order, hop counts, and nickname collision live in `ircd_route` and `ircd_state_net`. Do not send a routed message back to the ingress link.

- Handshake is RFC 2813 `PASS` / `SERVER` with the configured name and password, on TCP or TLS as the peer entry says. Inbound links accept the same class of check. A failed handshake closes the link and does not import state.
- Bursts include known servers in hop order, local and remote users, and channel state. Later `NICK`, membership, mode, topic, kick, and message events are forwarded to the other peers. Source prefixes on ingress must name a user or server the link is allowed to speak for. Drop or reject a prefix that would let a peer impersonate a local user.
- A nickname collision kills both copies and sends `KILL` and `QUIT` to the peers. `WHO` and `WHOIS` name the user's home server, not the adjacent link.
- `SQUIT` and link loss remove users, services, and channels reachable only through the lost server, and tell the remaining peers. Imported records are transient across local restart.
- Operator `DIE` calls `init:stop/0`. Operator `RESTART` calls `init:restart/0`. Other clients receive numeric 481. `SUMMON` and `USERS` stay disabled with numerics 445 and 446.
- Peer reconnect uses the link worker's backoff. Backoff is bounded and logged at a low rate. A connector that has not authenticated must not clear an inbound session that uses the same peer name.

### 8.5 Numerics and compatibility

- Reply with the numeric assigned by RFC 1459 / RFC 2812 for that condition. Add a numeric only when the command being implemented requires it, and list it in the roadmap note for that command.
- Format replies with the server name as prefix. Parameters that are nicknames or channels stay in their wire spelling; comparison still uses the folded form.
- Unknown commands and unknown mode letters receive the error numeric for that case. Ignore only when the RFC says the message is silently ignored (`NOTICE` delivery failures are the usual example).
- A change that alters a line clients or peer servers already parse is a wire compatibility change. Call that out in the summary, including which IRC clients or which `ircd` link path was considered.

## 9. Security, privacy, and abuse resistance

- Every client line and every server-link line is untrusted. Enforce the untagged 512-octet cap, the message-tag 4094/8191 caps, parameter count, nickname and channel syntax, mode-argument counts, and mask length before joining a channel or inserting Mnesia rows.
- Bound unauthenticated work: registration timeout, `max_clients`, and a capped read buffer. Connection floods, nick cycling, join/part floods, and `PRIVMSG` fan-out to large channels are the abuse cases to account for when touching those paths.
- Privileged commands (`OPER`, `KILL`, `REHASH`, and any new operator command) check the operator flag on the **local** session after registration. A prefix on a client socket never grants privilege.
- Server-link passwords and the optional client `PASS` secret come from configuration, not from source. Never commit live passwords, private keys, or real user traffic. TLS private keys stay in the paths `certfile` and `keyfile` point at.
- Redact `PASS`, `OPER` passwords, link passwords, and TLS key material in logs and `format_status`. Do not log full `PRIVMSG` or `NOTICE` bodies by default. Nicknames can identify people; keep them out of high-cardinality metric labels.
- Do not expose Erlang distribution, EPMD, a remote shell, or debug endpoints on the IRC listen port. The IRC port speaks IRC only.
- Reject open relay: a message to a nick, channel, or peer is sent only when the sender is allowed to address that target under the current membership, mode, and link rules.
- Do not add traffic interception, quiet logging of message content, or surveillance features unless the task explicitly requires them and names the access control and retention behavior.

## 10. Configuration, persistence, and operations

- Runtime configuration is JSON, selected with `IRCD_CONFIG`, loaded by `ircd_config`. Reject invalid configuration at startup. Paths are relative to the process working directory unless absolute. Defaults and keys are documented in the README table (`name`, `bind`, `tcp_port`, `tls_port`, certificates, log level and format, `max_clients`, `client_password`, `operators`, `administrators`, `channels`, MOTD, admin fields, `reop_delay`, `mnesia_dir`, `retention`, `history_limit`, `server_links`).
- At least one of `tcp_port` and `tls_port` is set. Port `0` means an ephemeral port reported in the startup log. The development container uses `config/ircd.dev.json`.
- Mnesia disk copies store WHOWAS history and safe-channel state under `mnesia_dir`. JSON `retention` is `transient` (default: ordinary channels are cleared on startup, then any `channels` entries that are missing are created) or `channels` (ordinary channel rows and a bounded channel `PRIVMSG`/`NOTICE` history survive; a configured channel is created only when its row is absent). Both policies clear client sessions, user modes, and imported peer state. A configured channel is kept when its last member leaves. `history_limit` caps that history. Backup, restore, and schema migration are documented in `docs/mnesia.md`. Document any new persisted record with its durability and what restart does to it.
- Shutdown stops listeners, closes client and link sockets, and leaves durable Mnesia data consistent. Do not drop safe-channel rows on a normal stop.
- Readiness means the configured listeners are bound and state is initialized. A down peer link is a degraded link, not by itself a dead process. Liveness stays up while a configured peer is disconnected and the link worker is retrying.
- Hot upgrade is unsupported unless `.appup` files, `code_change` callbacks, and Mnesia schema migration are added and tested. Prefer a restart, and state in the change notes that ordinary channels and sessions do not survive it.
- Distributed Erlang is not the clustering mechanism. Topology is IRC server links (RFC 2813), including servers introduced behind a direct peer.

## 11. Observability

- Log at the level `log_level` configures, through the JSON (or text) formatter. Accepted values are `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`, and `trace`. `trace` is the OTP primary level `all`. Startup sets both the primary level and the default handler, because the VM primary level otherwise drops `info` and `debug`. Startup logs the bound address and port. Connect, registration, disconnect, operator success and failure, link up, link down, handshake failure, and overload rejection are info or warning events. At `debug` or `trace`, each client and peer command is one line with nick, command, and target. `PING` and `PONG` are not logged. Message text, passwords, and channel keys are not logged. Per-recipient send success is not.
- Structured fields use bounded cardinality: command, numeric, transport (`tcp` or `tls`), local versus peer, result. Do not label metrics or log fields with a nickname, channel name, or message body as a metric key.
- Useful signals for this process model are session count against `max_clients`, link connection state, `ircd_state` mailbox length, listener accept errors, TLS handshake failures, registration timeouts, and supervisor restarts.
- Operator actions (`OPER` success or failure without the password, `KILL`, `REHASH`) are audit-worthy events. Log the actor nickname and the target, not the secret.
- An alert represents saturation or sustained protocol failure (client cap reached, state mailbox growing, link flapping), with a pointer to the configuration knob that addresses it.

## 12. Tests and quality gates

### What to test

- **EUnit** is the suite `just test` runs today. Use it for `ircd_wire`, config validation, mode and mask decisions, and other pure functions. Use **Common Test** when a change needs two sockets, a live listener, or two linked servers.
- Round-trip lines that the encoder accepts, including a trailing parameter. Cover empty input, a missing CRLF, a line of 512 octets, a line of 513 octets, embedded NUL, a client line with a fake prefix, 15 parameters, and a 16th parameter.
- Cover registration order (`PASS`, `NICK`, `USER`), bad nicknames, collisions under RFC 1459 case folding, the registration timeout, and commands issued before registration.
- Cover channel key, limit, ban, exception, invite-only, moderation, op and voice, safe-channel id syntax, and anonymous-channel visibility for the modes the change touches.
- Cover TCP partial lines and several lines in one recv, TLS handshake failure when the TLS listener is enabled, client disconnect mid-registration, and peer disconnect after a burst.
- For link changes, drive a peer through `PASS`/`SERVER`, a burst, and one propagated command. Assert a multi-hop nick or membership event is forwarded once and is not echoed to the ingress peer. Cover `SQUIT` or link loss for a user who exists only behind the lost server.
- Timer tests inject a monotonic deadline or a controllable timer where the code allows it. Avoid `timer:sleep` as the only synchronization.

### Commands

Run these in the development container when Docker is the environment in use:

```sh
just build
just format-check
just test
```

GitHub Actions (`.github/workflows/ci.yml`) builds the development image and runs `just format-check` and `just test`. `just test` includes `ircd_interop_tests`, which starts two ircd OS processes linked over TCP; keep it green for link changes. Keep that workflow on the same OTP image as the Dockerfile.

Add `rebar3 dialyzer`, `rebar3 xref`, Common Test, and a release smoke test when those providers exist for the change. `rebar.config` enables `warnings_as_errors` and erlfmt. A new warning or format drift is a defect. Say so when a check is skipped because the container or a plugin is absent.

## 13. Benchmarking

- Define the load before tuning: concurrent clients, joins per second, `PRIVMSG` fan-out (channel size times message rate), average line size, TLS fraction, and number of direct peers.
- Measure a packaged or release-mode node after warmup. Record OTP/ERTS, CPU, and the load generator. The generator must not be the bottleneck being reported.
- Compare matched before and after runs. Report p99 and error numerics alongside throughput. A faster path that drops memberships, mis-folds nicknames, or leaks sessions is not an improvement.
- Gate wire changes on malformed-line tests and the 512-octet ceiling. Gate state changes on membership invariants. Gate link changes on prefix checks, loop prevention, and a multi-hop forward that is not echoed to the ingress peer.

### Profiling procedure

- State the bottleneck hypothesis and reproduce it under section 2's matched workload before editing. Start with bounded samples of `erlang:memory/0`, `process_info/2` (memory, reductions, queue length, GC), and `ets:info/2`; inspect the state owner, sessions, and links separately. Avoid dumping mailbox contents or state containing secrets and message bodies.
- Choose tools by the question: `cprof` for call counts, `eprof` for function time, and `fprof` for detailed call relationships. Verify tool support on the deployed OTP 29 build. Trace only necessary processes/functions for a bounded interval and remove tracing afterward. Profiling overhead changes timing; report final throughput and latency from runs without profiling enabled.
- Keep benchmark setup, compilation, logging configuration, and warmup comparable. Repeat samples and report variation. Isolated microbenchmarks can explain a hot function, but acceptance requires the full IRC workload and correctness gates above. Diagnose lock contention only with a supported instrumented runtime/tool, and disclose that environment difference.
- Distinguish elapsed time from VM CPU time: socket I/O and scheduling waits affect client latency even when CPU time is low. Give microbenchmark samples enough duration to exceed clock noise and use fresh processes or equivalent heap/GC starting conditions for alternatives. Report distributions; a best-case sample alone cannot establish service latency.
- If OS memory and `erlang:memory/0` disagree, investigate allocator retention/fragmentation and native allocations before calling it a leak. Use supported OTP 29 allocator and crash-dump tools when needed, and treat dumps as sensitive data. Do not enable Erlang distribution or expose a remote observer merely to profile this server.

## 14. Agent completion checklist

A change is done only when the agent can answer **yes**, or explicitly report why not, for each item:

- Did I check the modules involved and pin the RFC 1459 / 2810–2813 behavior, including the RFC 1459 case map where identity matters?
- Did I keep the change inside the implemented subset, or update `ROADMAP.md` and the README when coverage grew?
- Are line length, read buffers, session count, timers, and Mnesia writes bounded?
- Are socket ownership, `ircd_state` ownership, supervision, and shutdown still coherent?
- Are OTP 29 features used only when stable and useful on OTP 29, with experimental native records avoided?
- Are operator and link secrets, message-body logging, privilege checks, and prefix spoofing reviewed?
- Are erlfmt, specs, and config defaults maintained?
- Did I run the applicable `just build`, `just format-check`, and `just test` commands and report the results?
- Did I measure any performance claim with a stated load and tail latency, and verify historical efficiency advice against OTP 29?
- Did I note wire compatibility, persistence across restart, and remaining link or RFC gaps?

## 15. Authoritative references

This file is engineering policy for the repository. The RFCs and the code win on wire behavior. If they disagree with each other, follow the code's documented choice when it is an intentional subset, and follow the RFC when the code is trying to implement that clause and gets it wrong. Flag the conflict in the change summary.

- RFC 1459, Internet Relay Chat Protocol: https://www.rfc-editor.org/rfc/rfc1459
- RFC 2810, IRC architecture: https://www.rfc-editor.org/rfc/rfc2810
- RFC 2811, IRC channel management: https://www.rfc-editor.org/rfc/rfc2811
- RFC 2812, IRC client protocol: https://www.rfc-editor.org/rfc/rfc2812
- RFC 2813, IRC server protocol: https://www.rfc-editor.org/rfc/rfc2813
- RFC 7194, default IRC port: https://www.rfc-editor.org/rfc/rfc7194
- Repository coverage: [README.md](README.md), [ROADMAP.md](ROADMAP.md)
- OTP 23 Efficiency Guide (historical background; verify against OTP 29): https://www.erlang.org/docs/23/efficiency_guide/users_guide.html
- OTP 29 docs: https://www.erlang.org/docs/29/
- `gen_server` and `gen_statem`: https://www.erlang.org/docs/29/apps/stdlib/gen_server.html and https://www.erlang.org/docs/29/apps/stdlib/gen_statem.html
- `ssl`: https://www.erlang.org/docs/29/apps/ssl/ssl.html
- `logger`: https://www.erlang.org/docs/29/apps/kernel/logger.html
- Rebar3: https://rebar3.org/docs/

### Efficiency Guide review coverage

All twelve chapter pages and their subsections were reviewed. This table records their application, not a claim that historical implementation details were validated on OTP 29.

| Chapter | Application in this standard |
| --- | --- |
| [Introduction](https://www.erlang.org/docs/23/efficiency_guide/introduction.html) | Sections 1, 7, 13: clear architecture first; optimize measured bottlenecks. |
| [Seven Myths](https://www.erlang.org/docs/23/efficiency_guide/myths.html) | Section 7.1: avoid blanket recursion, concatenation, and NIF speed claims; historical DETS and interpreter details are not tuning rules. |
| [Common Caveats](https://www.erlang.org/docs/23/efficiency_guide/commoncaveats.html) | Sections 3, 7.1–7.2: atom safety, traversal costs, tuple updates, size BIFs, timers. |
| [Binaries](https://www.erlang.org/docs/23/efficiency_guide/binaryhandling.html) | Section 7.1: construction, matching, diagnostics, and retained buffers. |
| [List Handling](https://www.erlang.org/docs/23/efficiency_guide/listHandling.html) | Section 7.1: accumulators, iodata, comprehensions, and recursion. |
| [Functions](https://www.erlang.org/docs/23/efficiency_guide/functions.html) | Section 7.1: clause semantics, direct calls, scalar recursion; old call-cost ratios are not accepted evidence. |
| [Tables and Databases](https://www.erlang.org/docs/23/efficiency_guide/tablesDatabases.html) | Sections 7.2, 10: keyed access, scan costs, consistency, and durability. |
| [Processes](https://www.erlang.org/docs/23/efficiency_guide/processes.html) | Sections 6, 7.2–7.3: loops, messages, sharing, heap tuning, and scheduler scaling. |
| [Drivers](https://www.erlang.org/docs/23/efficiency_guide/drivers.html) | Section 7.3: conditional native-boundary review; retain OTP networking. |
| [Advanced](https://www.erlang.org/docs/23/efficiency_guide/advanced.html) | Section 7.3: measure memory and deployment limits instead of adopting historical tables. |
| [Profiling](https://www.erlang.org/docs/23/efficiency_guide/profiling.html) | Section 13: tool selection, memory diagnosis, representative workloads, and fair timing. |
| [Retired Myths](https://www.erlang.org/docs/23/efficiency_guide/retired_myths.html) | Section 7.1: funs, comprehensions, and list subtraction require no folklore-driven rewrites. |
