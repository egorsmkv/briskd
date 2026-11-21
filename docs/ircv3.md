# IRCv3

`CAP LS` advertises `account-notify`, `account-tag`, `away-notify`, `batch`,
`cap-notify`, `chghost`, `echo-message`, `extended-join`, `extended-monitor`,
`invite-notify`, `labeled-response`, `message-tags`, `multi-prefix`,
`no-implicit-names`, `sasl`, `server-time`, `setname`, `standard-replies`,
`userhost-in-names`, `sts` (when configured), `tls` (STARTTLS, on plaintext
TCP when TLS is configured), and the drafts
`draft/account-registration`, `draft/channel-rename`, `draft/chathistory`,
`draft/event-playback`, `draft/extended-isupport`, `draft/message-redaction`,
`draft/metadata-2`,
`draft/multiline`, `draft/oper-tag`, `draft/pre-away`, and
`draft/read-marker` (plus the vendor capability `egorsmkv.github.io/calls`
when `calls` is configured, see [Voice calls](calls.md), and
`egorsmkv.github.io/e2ee` when
`e2ee` is configured; see [End-to-end encryption](e2ee.md); and
`egorsmkv.github.io/search` when `search` is configured; see
[Message search](search.md)). `CAP LS 302` shows values (`sasl` mechanisms, multiline
and metadata limits, the STS policy) and uses `*` continuation lines. Version
302 makes `cap-notify` implicit. `CAP REQ` is atomic; an unknown or
unrequestable name (`sts`) is `NAK`, and an unknown subcommand is numeric 410.
`CAP LS` or `CAP REQ` during registration holds the welcome until `CAP END`;
until then the client is not registered: other commands get 451, it is
invisible to WHOIS, WHO, ISON, and messages, and peers do not see it. A
`CAP ACK` is sent with the capabilities in force before the request.
A `REHASH` that changes the offered set sends `CAP NEW` and `CAP DEL` to
`cap-notify` clients and an updated 005 batch to `draft/extended-isupport`
clients.

Tags: server tags are placed before client-only tags. Client-only `+` tags on
`PRIVMSG`, `NOTICE`, and `TAGMSG` are relayed to
`message-tags` clients and across server links. Every message gets a `msgid`
(sent with `message-tags`) and a `time` (sent with `server-time`, which also
stamps every other line). Lines from a logged-in user carry `account`
(`account-tag`), lines from a `+B` user carry `bot`, and lines from an IRC
operator carry `draft/oper` (`draft/oper-tag`). Tag data over 4094 bytes, or a
tag section over 8191 bytes, is numeric 417. Untagged lines stay within 512
octets. With `labeled-response`, `batch`, and `message-tags`, a `label` of 1 to
64 bytes gets one labeled line, a `labeled-response` batch, or an `ACK`.

Accounts: `AUTHENTICATE` supports `PLAIN`, `EXTERNAL` (TLS client certificate
fingerprint), and `SCRAM-SHA-256`, before or after registration. `REGISTER
<account|*> <email|*> <password>` creates an account and logs in (passwords of
8 to 300 bytes; only SCRAM verifiers are stored; a TLS client certificate
presented at registration is remembered for `EXTERNAL`). With
`account_verification` set, `REGISTER` answers `VERIFICATION_REQUIRED`, the
configured program sends the code, and `VERIFY <account> <code>` completes the
account and logs in; the code expires after `ttl` seconds and is never logged. Logins send `ACCOUNT` to `account-notify` clients, JOIN carries the
account with `extended-join`, WHOIS shows 330, WHOX shows the `a` field, and
`$a:<account>` works in ban, exception, and invite lists.

Presence: `AWAY` is sent to `away-notify` clients (and after a JOIN);
`draft/pre-away` allows `AWAY` before registration. `SETNAME :<realname>`
changes the realname (at most 200 bytes, `NAMELEN`). Operators can run
`CHGHOST <nick> <user> <host>`; `chghost` clients see `CHGHOST` and others see
QUIT and JOIN. User mode `+B` marks a bot (`BOT=B`, WHOIS 335, WHO flag `B`).
`MONITOR` (limit `monitor_limit`) reports online and offline nicknames;
`extended-monitor` adds away, account, host, and realname changes.

Messages: `echo-message` returns the sender's own messages with their
`msgid`. `draft/multiline` batches (up to 4096 bytes and 100 lines) are
delivered as batches to capable clients and as separate lines to others. WebIRC
sends a message with line breaks (Shift+Enter, or pasted text) as one batch,
cutting lines longer than about 400 bytes into `draft/multiline-concat`
continuations, and shows received batches as one message.
`CHATHISTORY` (`BEFORE`, `AFTER`, `LATEST`, `AROUND`, `BETWEEN`, `TARGETS`,
by `timestamp=` or `msgid=`) returns history in a `chathistory` batch.
`draft/chathistory`, `draft/event-playback`, and the `CHATHISTORY` token are
advertised only while history is recorded (`chathistory`, or the admin
panel's Message history switch).
Channel history is available to current members. Direct-message history is
kept when at least one side is logged in. Clients with `draft/event-playback`
also get JOIN, PART, KICK, TOPIC, MODE, QUIT, NICK, and TAGMSG events. `MARKREAD` stores read
markers per account and sends them after a JOIN. `REDACT <target> <msgid>
[:reason]` removes a message from history and tells
`draft/message-redaction` clients; the sender's account or a channel operator
may redact.

Channels and queries: `multi-prefix` and `userhost-in-names` change NAMES,
WHO, and WHOIS prefixes; `no-implicit-names` drops the NAMES after JOIN; WHOX
(`WHO <mask> %<fields>[,<token>]`) answers with numeric 354;
`invite-notify` tells channel members (operators only on `+i` channels) about
invitations. `RENAME <old> <new> [:reason]` renames a local channel (same
type prefix, not `!`, not shared with a peer); clients without
`draft/channel-rename` see PART and JOIN. `METADATA` stores public user and
channel keys (`draft/metadata-2`, synchronized across server links).

Connections: `WEBIRC <password> <gateway> <hostname> <ip> [:options]` is
accepted as the first command from a configured gateway address; a bad
password gets `ERROR` and the connection closes. The gateway's own TLS
certificate is never used for SASL `EXTERNAL`; a `certfp-sha-256=` option
from a `secure` gateway is. With `utf8_only`, invalid UTF-8 arriving from a
peer is replaced with U+FFFD before local delivery. `ws_port` and `wss_port`
serve IRC over WebSocket with the `binary.ircv3.net` and `text.ircv3.net`
subprotocols. Registration sends RPL_ISUPPORT (005) with `CASEMAPPING`,
`CHANTYPES`, `PREFIX`, `MONITOR`, `WHOX`, `BOT`, `CHATHISTORY`,
`MSGREFTYPES`, `EXTBAN`, `ACCOUNTEXTBAN`, `NAMELEN`, `UTF8ONLY` (when set),
and `draft/ICON` (when set). `ISUPPORT` returns the same list, also before
registration with `draft/extended-isupport`. A server split sends the QUITs in
one `netsplit` batch, and users that arrive in a peer burst appear in a
`netjoin` batch.

Over server links, accounts (SCRAM verifiers, not email addresses), user and
channel metadata, read markers, `ACCOUNT`, `SETNAME`, `CHGHOST`, `REDACT`,
user mode `B`, and the `msgid` and `time` of messages are propagated in the
burst and as they change. When two servers hold the same account name, the
one created first wins. `STARTTLS` (deprecated by IRCv3) upgrades a plaintext
TCP connection before registration; prefer `tls_port` and STS.
