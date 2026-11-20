# IRC Server Roadmap

This roadmap reflects the implementation in the repository today. Checked items
are present in the code; unchecked items are unfinished or need broader RFC
coverage. A checked item does not imply complete compliance with every edge case
in the referenced RFC.

## Runtime and configuration

- [x] Erlang/OTP application with supervised state, listener, session, and link
  processes.
- [x] JSON configuration loading and validation through `IRCD_CONFIG`.
- [x] Configurable server name, bind address, TCP/TLS ports, TLS certificate and
  key, log level and format, client limit, operator accounts, client password,
  MOTD, admin replies, reop delay, Mnesia directory, and peer links.
- [x] Predefined `administrators` and `channels` in JSON. Administrator
  accounts log in with `OPER` and receive channel operator on the configured
  channels. Those channels are created at startup when no row exists.
- [x] JSON logging by default, with text logging as a configuration option.
- [x] Direct TLS listener using TLS 1.2 and 1.3.
- [x] Mnesia disk-copy tables and configurable `mnesia_dir`.
- [x] `justfile` commands for build, format, format check, run, run with a
  selected config, dependency fetch, tests, and clean.
- [x] Add automated unit and integration coverage for configuration,
  registration, protocol behavior, persistence across restart, and peer links.

## Client protocol (RFC 1459 and RFC 2812)

- [x] TCP/TLS client sessions, IRC line framing, registration timeout, `PASS`,
  `NICK`, and `USER` registration.
- [x] Common messaging and channel commands: `PRIVMSG`, `NOTICE`, `JOIN`,
  `PART`, `TOPIC`, `NAMES`, `LIST`, `MODE`, `INVITE`, and `KICK`.
- [x] User and information commands including `AWAY`, `WHO`, `WHOIS`, `WHOWAS`,
  `ISON`, `USERHOST`, `LUSERS`, `MOTD`, `VERSION`, `TIME`, `INFO`, `ADMIN`,
  `LINKS`, `TRACE`, `STATS`, `SERVLIST`, and `SQUERY`.
- [x] Operator login with `OPER`; local operator `KILL` and `REHASH`.
- [x] Numerics for implemented commands, including local `WHOIS` idle time and
  registration replies.
- [x] RFC1459 nickname and channel case folding, nickname validation, and
  512-byte framing for lines that do not carry message tags.
- [x] Complete the RFC command and numeric surface. `SERVICE`, `SERVLIST`, and
  `SQUERY` register and reach services. `CONNECT` and `SQUIT` are operator
  commands. `SUMMON` and `USERS` stay disabled with numerics 445 and 446.
  Operator `DIE` stops the node and operator `RESTART` restarts it; other
  clients receive numeric 481. IRCv3 support is listed below.
- [x] Graceful shutdown on SIGTERM, `DIE`, `RESTART`, and application stop:
  listeners close, peers get `SQUIT`, clients get a NOTICE and `ERROR`, and the
  server waits up to `shutdown_grace` seconds (`ircd_shutdown`).
- [x] Audit parameter limits, error numerics, visibility, and command edge cases
  against the RFCs.

## Channels (RFC 2811)

- [x] Channel joins, parts, topics, membership queries, invitations, kicks,
  operator and voice roles, and channel keys and limits.
- [x] Ban, exception, and invite masks; moderation, member-only messaging,
  operator-only topics, private and secret channels.
- [x] Safe `!` channels, creator role, `+r` reop behavior, and configurable
  randomized reop delay.
- [x] Anonymous `+a` behavior on local `&` and safe `!` channels.
- [x] Channel operators can change `+o`/`+v` on, and kick, members homed on
  another server; the safe-channel reop is propagated to peers.
- [x] List visibility policy: ban list public, exception and invite lists for
  channel operators; bare `MODE #chan b|e|I` lists.
- [x] `KNOCK` numerics 713 (open channel) and 714 (already on channel), common
  ircd extensions rather than RFC numerics.
- [x] Complete RFC 2811 channel creation and abuse-window rules, nickname
  collision handling, and channel lifecycle edge cases.
- [x] Expand mode behavior and numeric coverage for all supported channel types
  and mode combinations.

## Persistence and state

- [x] Mnesia persists WHOWAS history and safe-channel state using disk copies.
- [x] The Mnesia database directory is configurable with `mnesia_dir` in JSON.
- [x] `retention` selects restart policy. The default `transient` clears
  ordinary channels. `channels` keeps ordinary channel state and a bounded
  `PRIVMSG`/`NOTICE` history (`history_limit`). Both policies clear client
  sessions, operator status, and peer-imported records on restart.
- [x] Define and document backup, restore, and schema migration procedures for
  long-lived Mnesia data in `docs/mnesia.md`.
- [x] Add restart-level verification for each state category that is intended
  to persist.
- [x] ACME certificates with lego (`docker-compose.lego.yml`,
  `deploy/lego/lego.sh`): issuance and renewal by HTTP-01, TLS-ALPN-01, or
  DNS-01, and live reload of renewed certificates (`ircd_certs`,
  `tls_reload_interval`) without dropping connections.
- [x] Resource bounds (implementation policy):
  - A client whose outgoing queue passes `max_sendq` lines is disconnected
    with `Max SendQ exceeded`. An outbound link that stops reading is
    dropped after a 30 s send timeout or 50000 queued lines and reconnects.
  - Outbound links reconnect with exponential backoff from 5 s to a 300 s cap
    (up to 10% jitter), reset after a successful handshake, logged at a low
    rate.
  - WHOWAS keeps the newest 10 entries per nickname and 10000 in all.
  - Ban, exception, and invite lists hold 100 masks each (`MAXLIST=beI:100`,
    ERR_BANLISTFULL 478); a peer's additions past that are dropped.
  - Expired nickname and channel holds are deleted.
  - `MARKREAD` targets must be a channel or a nickname.
  - Mask matching is linear in mask times value length.
  - PBKDF2 for SASL `PLAIN` and `REGISTER` runs in bounded worker processes
    (`ircd_deferred`, at most 32 at once; over that the attempt fails fast
    with 904 or `FAIL REGISTER TEMPORARILY_UNAVAILABLE`), so `ircd_state`
    keeps serving other clients while a password is checked.
  - Peer-supplied identities, topics, keys, and masks are copied before they
    are stored, so they do not keep receive buffers alive.
  - Client flood and spam control (`ircd_flood`, `flood` setting): per-client
    token buckets for lines (`lines_burst`, `lines_per_second`), messages
    (`messages_burst`, `messages_per_second`), channel joins (`join_burst`,
    `join_per_minute`), and nickname changes (`nick_burst`,
    `nick_per_minute`), disconnecting flooded sessions with `Excess Flood`
    (operators are exempt), plus a per-host `REGISTER` rate limit
    (`register_per_minute`).
- [x] Remaining bounds from the memory audit: an expiry (`empty_channel_ttl`)
  and cap (`max_empty_channels`) for empty safe and retained channels (with the
  `ircd_safe_channels` ETS short-name index for safe `JOIN`), `REGISTER` rate
  limits and an account cap (`max_accounts`), a per-account read-marker cap
  (`max_read_markers`), pruning of disconnected pids from `invited`, a cap,
  byte/target validation, and TTL cleanup for open peer batches, per-account
  direct-history conversation caps (`max_direct_conversations`), and per-peer
  caps on introduced users (`max_peer_users`), servers (`max_peer_servers`),
  services (`max_peer_services`), and metadata.

## Server protocol and linking (RFC 2813)

- [x] Outbound TCP/TLS peer connections with reconnect, RFC 2813 `PASS`/`SERVER`
  handshake, configured identity/password checks, and authenticated inbound
  handshakes.
- [x] Server-prefixed line parsing on links, periodic `PING`/`PONG` liveness
  checks, and handling of fatal peer `ERROR` messages.
- [x] Outbound client and channel snapshot generation; extended `NICK` and
  `NJOIN` use RFC server message forms.
- [x] Import server-prefixed extended `NICK` introductions and propagate new
  local registrations, nickname changes, quits, and away state to direct peers.
- [x] Propagate direct-peer channel joins and parts, including member roles in
  `NJOIN`, and reflect those changes in local channel membership queries.
- [x] Include channel topics in link bursts and propagate direct-peer topic
  changes while enforcing topic operator checks for remote users.
- [x] Propagate user modes and channel mode changes to direct peers, including
  channel flags, keys, limits, access lists, and operator/voice role updates.
- [x] Propagate KICK events between direct peers; enforce remote operator or
  creator membership and remove kicked local or imported users from channel state.
- [x] Import remote extended `NICK`, nickname changes, `QUIT`, `AWAY`, relevant
  user modes, `NJOIN` membership, and basic private/secret/anonymous channel
  flags into Mnesia.
- [x] Basic remote-user `WHOIS`, `WHO`, `ISON`, and `USERHOST` replies; remote
  users contribute to `LUSERS` and nickname collision checks.
- [x] Route direct `PRIVMSG` and `NOTICE` between local clients and users on a
  directly connected peer; validate the imported remote user's message prefix.
- [x] Route channel `PRIVMSG` and `NOTICE` between local members and directly
  connected peer members; require remote channel membership and apply available
  moderation and ban checks without returning messages to the ingress peer.
- [x] Propagate channel invitations to peers after the initial burst.
- [x] Route messages across multiple server hops with topology-aware loop
  prevention and correct source routing.
- [x] Complete channel-state synchronization for invitations and other channel
  events across the full server topology.
- [x] Support remote channel operations and complete visibility behavior across
  servers, including shared-channel checks for invisible users.
- [x] Track multiple server hops and tokens, introduce known servers in burst
  order, and prevent duplicate routes and nickname collisions safely.
- [x] Handle `SQUIT`, server-link loss propagation, netsplits, and cleanup of
  users and channels behind a disconnected server.
- [x] Add remote service support and the remaining server-only commands.

## IRCv3

Every specification on <https://ircv3.net/irc/> is implemented, including the
deprecated `STARTTLS`. The base protocol stays the RFC 1459 and RFC 2812
subset above, not the Modern IRC document. A checked item does not imply every
edge case of the specification.

Capabilities, tags, and batches:

- [x] Capability negotiation 302 with values, multi-line `CAP LS`, atomic
  `CAP REQ`, and implicit `cap-notify`. `CAP NEW` and `CAP DEL` are sent when a
  `REHASH` changes the offered set or a value (`sts` is never deleted). `sts`
  cannot be requested. Unknown subcommands return numeric 410.
- [x] Message tags and `TAGMSG`. Client-only `+` tags are relayed, which
  covers the `reply`, `react`, `typing`, and `channel-context` client tags.
  Tag data over 4094 bytes, or a tag section over 8191 bytes, returns 417.
- [x] Server tags filtered per recipient: `msgid` (message-ids, with
  `message-tags`), `time` (`server-time`, on every line), `account`
  (`account-tag`), `bot` (bot mode), and `draft/oper` (`draft/oper-tag`).
  Peers carry `msgid` and `time` so every server shows the same values.
- [x] `batch`: `labeled-response`, `netsplit`, `netjoin`, `chathistory`,
  `draft/chathistory-targets`, `draft/isupport`, `metadata`, `metadata-subs`,
  and `draft/multiline`. Nested batches keep their own reference.
- [x] Client-initiated batches (`client-batch`) of type `draft/multiline` with
  `max-bytes` and `max-lines`, `draft/multiline-concat`, the non-capable
  fallback, and the `FAIL BATCH` codes.
- [x] Labeled responses, including echoes under `echo-message` and the
  closing `BATCH` of a multiline message.
- [x] `standard-replies`: `FAIL`, `WARN`, and `NOTE` for the new commands.

Accounts:

- [x] SASL 3.1 and 3.2: `AUTHENTICATE` with `PLAIN`, `EXTERNAL` (TLS client
  certificate SHA-256 fingerprint), and `SCRAM-SHA-256`; numerics 900 to 908;
  400-byte chunking; reauthentication after registration.
- [x] `draft/account-registration`: `REGISTER` and `VERIFY` with
  `before-connect` and `custom-account-name`. With `account_verification`
  configured, registration needs an email address (`email-required`), a
  configured program delivers an expiring code, and `VERIFY` completes it.
  Accounts are Mnesia rows with SCRAM verifiers only.
- [x] `account-notify` (`ACCOUNT`), `account-tag`, `extended-join`, WHOIS 330,
  and account extbans (`$a:<account>`, `EXTBAN=$,a`, `ACCOUNTEXTBAN=a`).

Presence and identity:

- [x] `away-notify`, including `AWAY` after a JOIN; `draft/pre-away` with
  `AWAY *`.
- [x] `setname` (`SETNAME`, `NAMELEN`), `chghost` (operator `CHGHOST` with the
  QUIT and JOIN fallback), and bot mode (`+B`, `BOT=B`, WHOIS 335, WHO `B`).

Messages and history:

- [x] `echo-message`, `server-time`, and message IDs.
- [x] `draft/chathistory`: `BEFORE`, `AFTER`, `LATEST`, `AROUND`, `BETWEEN`,
  and `TARGETS`, by timestamp or msgid. Channel history is readable by
  members. Direct-message history is kept only between two logged-in accounts,
  in Mnesia with the same retention as channel history.
- [x] `draft/event-playback`: JOIN, PART, KICK, TOPIC, MODE, QUIT, NICK, and
  TAGMSG are recorded and replayed to clients with the capability. Events and
  messages each keep `history_limit` entries.
- [x] `draft/read-marker` (`MARKREAD`), stored per account.
- [x] `draft/message-redaction` (`REDACT`) by the sender's account or a
  channel operator.

Channels and queries:

- [x] `multi-prefix`, `userhost-in-names`, WHOX (`354`, tokens, `%acdfhilnorstu`),
  `no-implicit-names`, `invite-notify`, `draft/channel-rename` (`RENAME` with
  the PART and JOIN fallback), and `draft/metadata-2` (`METADATA` and numerics
  760 to 774).
- [x] `MONITOR` (730 to 734, `MONITOR=<limit>`) and `extended-monitor`.

Connection and transport:

- [x] `WEBIRC` from configured gateway addresses, with the `secure` option.
- [x] WebSocket listeners (`ws_port`, `wss_port`) with `binary.ircv3.net` and
  `text.ircv3.net`, and an optional origin allow list.
- [x] Deprecated `STARTTLS` (`tls` capability, 670 and 691) on plaintext TCP
  connections when TLS is configured.
- [x] STS (`sts` policy: upgrade port on plaintext, duration on TLS), SNI
  certificate selection (`sni`), `UTF8ONLY`, `draft/extended-isupport`
  (`ISUPPORT`), RPL_ISUPPORT 005, and `draft/ICON`.

Across server links:

- [x] Accounts (`ACCOUNTSYNC`, SCRAM verifiers only, the first-created copy
  wins), user and channel metadata (`METADATA`), read markers (`MARKREAD`),
  `ACCOUNT`, `SETNAME`, `CHGHOST`, `REDACT`, user mode `B`, and each message's
  `msgid` and `time` cross links in the burst and as live updates.
- [x] Interoperability gate: `test/ircd_interop_tests.erl` runs two separate
  ircd OS processes linked over RFC 2813 TCP and checks these paths.

Conformance: irctest (`test/irctest/ircd_controller.py`, one fresh server
per test) with irctest's standard selection for a server,
`-m "not implementation-specific and not deprecated"`: 491 passed, 0 failed
(IRCv3 and RFC 1459/2812/Modern together).

Tests irctest marks `deprecated`: 18 of 23 pass (legacy metadata 3.2 for
clients without `draft/metadata-2`, WHOWAS masks, INVITE with the channel
first, RPL_ENDOFWHOWAS after 431). The other five cannot pass together with
the passing tests: three RFC 1459 NAMES variants require 353 without the `=`
symbol that their RFC 2812 twins require; `testWhowasNoParamRfc` expects
`369 <nick> nick2` although no `nick2` is involved; and
`testSetGetZeroCharInValue` sends NUL inside a line, which the RFC 1459/2812
grammar forbids. Tests marked `implementation-specific` (61 failing) cover
Ergo and Sable features: NickServ, ChanServ, roleplay, RELAYMSG, proxy,
always-on bouncer details, and Sable's PostgreSQL history server.

- [x] Opt-in bouncer behaviour used by the read-marker tests: `multiclient`
  (a second connection of the same account shares the nickname) and
  `account_rejoin` (an account is rejoined to its channels on login).

## End-to-end encryption (server-specific extension)

- [x] Optional blind broker for Signal-style clients (`e2ee` configuration,
  `ircd_e2ee`, [guide](docs/e2ee.md)): vendor capability
  `egorsmkv.github.io/e2ee`, X3DH prekey directory bound to SASL accounts
  (`E2EE PUBLISH`, `PREKEYS`, `DEVICES`, `FETCH`, `REMOVE`), device binding
  (`BIND`), per-device offline queue with acknowledgement (`ACK`), and limits
  on devices, prekeys, queue size and age, and fetch rate.
- [x] Replicate bundles, prekey use, removals, queued envelopes,
  acknowledgements, and device bindings across server links (`E2EE` link
  lines, in the burst and as they change).
- [x] Queue `draft/multiline` envelopes for offline devices and replay them as
  one batch.
- [x] Deliver to a device bound under another nickname (a second device of
  the account), locally or across a link.
- [x] End-to-end tests with Python clients doing X3DH, the Double Ratchet, and
  Sender Keys against two linked servers (`test/e2ee/run`, in CI).

## Voice calls (server-specific extension)

- [x] `calls` configuration and vendor capability `egorsmkv.github.io/calls`
  ([guide](docs/calls.md)): one-to-one audio calls between local users.
- [x] `CALL OFFER|ANSWER|RINGING|REJECT|HANGUP` signalling with chunked
  base64 SDP (`ircd_call_proto`), relayed through rtpengine's NG protocol
  (`ircd_calls`, `ircd_bencode`) so peers never see each other's address.
- [x] Ring timeout, maximum duration, per-user and server limits, busy
  handling, and cleanup on disconnect.
- [x] WebIRC call button, incoming-call dialog, call dock with mute and
  hang-up, `/call` and `/hangup`.
- [x] rtpengine image (`docker/rtpengine`) in the development environment and
  an end-to-end test with WebRTC clients (`test/calls/run`, in CI).
- [ ] Calls to users on linked servers.
- [ ] Group calls and video.

## AI assistant bots (server-specific extension)

- [x] `ai_providers` and `bots` configuration (`ircd_config`,
  [guide](docs/bots.md)): OpenAI-compatible `chat/completions` endpoints with
  `api_key` or `api_key_env`, per-bot model, system prompt (inline or file),
  channels, and limits.
- [x] Bots as socketless local clients (`ircd_bot`, `ircd_bots`): `+B` bot
  mode, channel joins, answers to mentions, `+draft/reply` replies to its own
  messages (threaded answers), and private messages, typing
  indicators, conversation or channel context, per-target and per-minute
  limits, reconnect after `KILL`, rejoin after `KICK`.
- [x] Reply lines sized for the 512-octet limit without splitting UTF-8
  (`ircd_bot_ai`); no answers to `NOTICE`, CTCP, or `bot`-tagged messages.
- [ ] Apply `bots` changes on `REHASH` (today a restart is required).
- [ ] Bots on remote servers do not exist; a bot answers only from the
  server that configures it (remote users can still address it).

## Documentation and verification

- [x] README documents run instructions and links the guides in `docs/`:
  configuration, IRC and IRCv3 protocol coverage, deployment, development,
  persistence behavior, and conformance testing.
- [x] Erlang source formatting is available through `rebar3 fmt` and the
  `just format`/`just format-check` commands.
- [x] GitHub Actions builds the development image and runs `just format-check`
  and `just test`.
- [x] Maintain this roadmap as implementation and RFC coverage change.
- [x] Build an RFC-oriented verification matrix and exercise it with automated
  tests and two-server integration scenarios.
