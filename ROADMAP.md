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
- [x] Flatlog JSON logging by default, with text logging as a configuration
  option.
- [x] Direct TLS listener using TLS 1.2 and 1.3.
- [x] Mnesia disk-copy tables and configurable `mnesia_dir`.
- [x] `justfile` commands for build, format, format check, run, run with a
  selected config, dependency fetch, tests, and clean.
- [ ] Add automated unit and integration coverage for configuration,
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
  512-byte message framing.
- [ ] Complete the RFC command and numeric surface; for example, capability
  negotiation currently only handles a limited `CAP LS`/`CAP END` path, and
  service and several optional commands are incomplete or disabled.
- [ ] Audit parameter limits, error numerics, visibility, and command edge cases
  against the RFCs.

## Channels (RFC 2811)

- [x] Channel joins, parts, topics, membership queries, invitations, kicks,
  operator and voice roles, and channel keys and limits.
- [x] Ban, exception, and invite masks; moderation, member-only messaging,
  operator-only topics, private and secret channels.
- [x] Safe `!` channels, creator role, `+r` reop behavior, and configurable
  randomized reop delay.
- [x] Anonymous `+a` behavior on local `&` and safe `!` channels.
- [ ] Complete RFC 2811 channel creation and abuse-window rules, nickname
  collision handling, and channel lifecycle edge cases.
- [ ] Expand mode behavior and numeric coverage for all supported channel types
  and mode combinations.

## Persistence and state

- [x] Mnesia persists WHOWAS history and safe-channel state using disk copies.
- [x] The Mnesia database directory is configurable with `mnesia_dir` in JSON.
- [x] Transient client sessions and peer-imported records are cleared when the
  server restarts; non-safe channels expire on restart.
- [ ] Define and document backup, restore, and schema migration procedures for
  long-lived Mnesia data.
- [ ] Add restart-level verification for each state category that is intended
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
- [ ] Propagate channel invitations to peers after the initial burst.
- [ ] Route messages across multiple server hops with topology-aware loop
  prevention and correct source routing.
- [ ] Complete channel-state synchronization for invitations and other channel
  events across the full server topology.
- [ ] Support remote channel operations and complete visibility behavior across
  servers, including shared-channel checks for invisible users.
- [ ] Track multiple server hops and tokens, introduce known servers in burst
  order, and prevent duplicate routes and nickname collisions safely.
- [ ] Handle `SQUIT`, server-link loss propagation, netsplits, and cleanup of
  users and channels behind a disconnected server.
- [ ] Add remote service support and the remaining server-only commands.

## Documentation and verification

- [x] README documents run instructions, configuration, current protocol
  coverage, persistence behavior, and known linking limitations.
- [x] Erlang source formatting is available through `rebar3 fmt` and the
  `just format`/`just format-check` commands.
- [ ] Maintain this roadmap as implementation and RFC coverage change.
- [ ] Build an RFC-oriented verification matrix and exercise it with automated
  tests and two-server integration scenarios.
