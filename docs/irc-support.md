# IRC support and limitations

Implemented client commands include `PASS`, `NICK`, `USER`, `JOIN`, `PART`,
`PRIVMSG`, `NOTICE`, `TOPIC`, `NAMES`, `LIST`, `MODE`, `INVITE`, `KICK`,
`AWAY`, `WHO`, `WHOIS`, `WHOWAS`, `ISON`, `USERHOST`, `LUSERS`, `MOTD`,
`VERSION`, `TIME`, `INFO`, `ADMIN`, `LINKS`, `TRACE`, `STATS`, `SERVLIST`,
`SQUERY`, `PING`, `PONG`, `QUIT`, `OPER`, `KILL`, `REHASH`, `CONNECT`,
`SQUIT`, `SERVICE`, `CAP`, `TAGMSG`, `KNOCK`, `SUMMON`, `USERS`, `DIE`, and
`RESTART`. `SUMMON` and `USERS` stay disabled and return numerics 445 and 446.
Operator `DIE` stops the node and operator `RESTART` restarts the runtime.
Other clients receive numeric 481.

Implementation policies on queries and channel lists:

- `STATS u` and `STATS m` are public. `STATS l` shows a non-operator only their
  own connection, and `STATS o` is operator-only (481); both end with 219.
- The ban list (`MODE #chan b` or `+b`) is visible to anyone who can see the
  channel. The exception (`e`) and invite-exception (`I`) lists need channel
  operator status (482). Each list holds 100 masks (`MAXLIST=beI:100`, 478).
- A non-member asking for the `TOPIC` of a `+s` or `+p` channel gets 403.
- `KNOCK` answers 714 when the sender is already on the channel, 713 when the
  channel is open, and 480 for other refusals. These are the common ircd
  extension numerics; RFC 2812 does not define `KNOCK`.
- A channel operator may change `+o`/`+v` on, and `KICK`, members who are on
  another server; the change is propagated to the peers.
- Successful `KILL` and `REHASH` are logged as `oper_kill` and `oper_rehash`
  audit events (actor and target, never the reason text or secrets).

A client may join at most ten channels (numeric 405). A nickname or channel
released by a quit or a netsplit stays unavailable for 60 seconds (numeric
437). A nickname introduced for an existing local or remote user kills both
sides, and both peers are sent `KILL` and `QUIT`. `WHO` and `WHOIS` name a
remote user's home server. Invisible users are hidden from `WHO`, `WHOIS`, and
`NAMES` unless the requester shares a channel, including when the other user
is on another server.

Server links speak the RFC 2813 `PASS` / `SERVER` handshake and accept further
`SERVER` introductions in hop order. Nick introductions, channel membership
changes, messages, and invitations are forwarded to the other peers and are
not sent back to the link that delivered them. A newly linked server receives
the known servers, local and remote users, and channel state. `SQUIT` and a
lost link remove the users, services, and channels that were reachable only
through the lost server and tell the remaining peers. Channel invitations are
stored and forwarded after the burst.

IRCv3 support is described in [IRCv3](ircv3.md).

`SUMMON` and `USERS` are not available as working features. Consult the
[roadmap](../ROADMAP.md) for the checked coverage list.
