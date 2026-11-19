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
- [x] Flatlog JSON logging by default, with text logging as a configuration
  option.
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

Conformance (irctest, `test/irctest/ircd_controller.py`, one fresh server per
test, `-m "IRCv3 and not deprecated and not implementation-specific"`):
174 passed. Two read-marker cases need bouncer-style shared sessions
(several connections on one nickname), which this server does not offer, and
one SASL case needs an 800-byte password that cannot fit in a 512-byte
`REGISTER` line. irctest's `metadata_3.py` targets an unpublished
`draft/metadata-3`; the published spec is `draft/metadata-2`.

Base-protocol gaps irctest reports outside IRCv3 (unchanged by this work):

- [ ] Channel key and limit argument validation (`chmodes/key.py`,
  `chmodes/limit.py`), RPL_CHANNELMODEIS layout, ban and invite-exception
  list numerics.
- [ ] WHOIS numeric set and order, LUSERS counts, LINKS, WALLOPS (server-only
  here), `NICK` to the identical nickname, an empty realname, and a
  non-UTF-8 username.

## Documentation and verification

- [x] README documents run instructions, configuration, current protocol
  coverage, persistence behavior, and known linking limitations.
- [x] Erlang source formatting is available through `rebar3 fmt` and the
  `just format`/`just format-check` commands.
- [x] GitHub Actions builds the development image and runs `just format-check`
  and `just test`.
- [x] Maintain this roadmap as implementation and RFC coverage change.
- [x] Build an RFC-oriented verification matrix and exercise it with automated
  tests and two-server integration scenarios.
