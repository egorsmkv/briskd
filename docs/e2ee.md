# End-to-end encryption

This page is for an operator deciding whether to offer end-to-end encryption,
and for a client author implementing the `E2EE` commands and envelope tags
below.

The feature is off unless the configuration has an `e2ee` object. The default
is `null`, which does not offer the capability and treats `E2EE` as an unknown
command (421). Keys and their ranges are in
[Configuration](configuration.md); every key in the object is optional, and an
empty object turns the broker on with the defaults below.

With `e2ee` set, the server is a broker for Signal-style encryption: X3DH and
the Double Ratchet for direct messages, OMEMO-style devices per account, and
Sender Keys for channels. Clients do that cryptography. The server stores
device public keys and forwards and queues ciphertext. It does not decrypt
message bodies, and it does not log them (a published or removed device is
logged by account and device id only). The implementation is `briskd_e2ee`.

Turn it on with an `e2ee` object (all keys optional):

```json
"e2ee": {
  "max_devices": 8,
  "max_prekeys": 100,
  "queue_limit": 500,
  "queue_ttl": 1209600,
  "fetch_rate": 30
}
```

| Key | Default | Range | Meaning |
| --- | --- | --- | --- |
| `max_devices` | 8 | 1..32 | Devices per account |
| `max_prekeys` | 100 | 1..1000 | Stored one-time prekeys per device |
| `queue_limit` | 500 | 0..10000 | Queued envelopes per offline device (0: no offline queue) |
| `queue_ttl` | 1209600 | 60..7776000 | Seconds an envelope waits before it expires (14 days) |
| `fetch_rate` | 30 | 1..1000 | `E2EE FETCH` requests per connection per minute |

Unknown keys are rejected at startup. Without `e2ee`, the capability is not
offered and `E2EE` is an unknown command (421).

## Names

This extension is specific to this server, so its names use a vendor prefix,
as IRCv3 requires for non-standard extensions. The `draft/` prefix is reserved
for IRCv3 drafts, and there is no published one for end-to-end encryption.

| Name | Kind | Use |
| --- | --- | --- |
| `egorsmkv.github.io/e2ee` | capability | Value `v=1,max-devices=N,max-prekeys=N,queue=N` |
| `+egorsmkv.github.io/e2ee-src` | client-only tag | Sender, for clients; the test clients use `<account>:<device>` |
| `+egorsmkv.github.io/e2ee-dst` | client-only tag | Recipient device id; the server queues by it |
| `+egorsmkv.github.io/e2ee-type` | client-only tag | Envelope type, such as `prekey`, `msg`, `skdist` (clients) |
| `egorsmkv.github.io/e2ee-qid` | server tag | Queue id on a replayed envelope, for `ACK` |

The client needs `message-tags` (for the tags) and the e2ee capability. If a
client sends the three envelope tags without having negotiated
`message-tags`, the server still keeps those tags (and no other client-only
tags), so the message is stored and relayed as an encrypted envelope and
never treated as text, for example by [message search](search.md). All
`E2EE` subcommands need the capability; replies are `E2EE` lines from the
server, and errors are IRCv3 standard replies, `FAIL E2EE <code>`.

## Identity

Keys belong to SASL accounts, not nicknames. Publishing keys, binding a
device, and acknowledging envelopes need a logged-in client
(`FAIL E2EE ACCOUNT_REQUIRED`), so someone who takes over a nickname after a
disconnect cannot publish keys for its owner. A bundle is fetched by nickname,
resolved to the account of the logged-in user who has it now, or by account
name. The server does not verify keys or signatures: clients must check the
signed prekey's signature, pin identity keys on first use (TOFU), and let
users compare safety numbers.

## Key directory (X3DH)

Keys and signatures travel as standard base64 without whitespace: identity
keys, signed prekeys, and one-time prekeys must decode to 32 bytes (Curve25519
/ Ed25519 public keys), and the signed-prekey signature must decode to 64
bytes (Ed25519 signature); any other value is rejected with
`FAIL E2EE INVALID_KEY`. Device ids are
1 to 2147483647. Prekey ids are 0 to 4294967295.

```text
C: E2EE PUBLISH <device> <identity-key> <spk-id>:<signed-prekey> <signature>
S: :server E2EE PUBLISHED <device>

C: E2EE PREKEYS <device> <id>:<key> [<id>:<key> ...]
S: :server E2EE PREKEYS <device> <stored-count>
```

`PUBLISH` stores or replaces a device's identity key and signed prekey and
keeps its one-time prekeys. `PREKEYS` adds one-time prekeys (a key with an
existing id replaces it). About ten keys fit on one line, so send several
lines. `PREKEYS <device>` with no keys reports the count.

```text
C: E2EE DEVICES alice
S: :server E2EE DEVICES alice :481516 102938

C: E2EE FETCH alice [<device>]
S: :server E2EE BUNDLE alice 481516 <identity> <spk-id>:<spk> <signature> <opk-id>:<opk>
S: :server E2EE FETCHED alice 1
```

`FETCH` returns one `BUNDLE` per device (or for the named device), then
`FETCHED <account> <count>`. Each one-time prekey is handed out once. When a
device has none left, its bundle ends after the signature, which X3DH allows.
When fewer than ten remain, the connection bound to that device gets
`E2EE PREKEYS <device> <count>` and should upload more. `FETCH` is limited to
`fetch_rate` per minute per connection (`RATE_LIMITED`), because each call uses
up prekeys.

`E2EE REMOVE <device>` deletes a device and its queue (`E2EE REMOVED <device>`).

## Direct messages and the offline queue

Ciphertext goes in an ordinary `PRIVMSG` (or `NOTICE`, or `TAGMSG` with the
ciphertext in a client tag), addressed to the nickname, with the device tags:

```text
C: @+egorsmkv.github.io/e2ee-src=102938;+egorsmkv.github.io/e2ee-dst=481516;+egorsmkv.github.io/e2ee-type=prekey PRIVMSG alice :<base64 ciphertext>
```

Long ciphertext can go in a `draft/multiline` batch with the E2EE tags on
the `BATCH` line. Batches are queued whole and replayed as one batch, with
the `qid` on the opening `BATCH` line.

A client says which device a connection is:

```text
C: E2EE BIND 481516
S: :server E2EE BOUND 481516 <queued-count>
S: @egorsmkv.github.io/e2ee-qid=<qid>;+egorsmkv.github.io/e2ee-src=102938;... :bob!b@host PRIVMSG alice :<ciphertext>
C: E2EE ACK <qid>[,<qid>...]
```

The server routes a message that carries the `dst` tag as follows:

- **The device is bound to a live connection:** normal delivery. When that
  connection uses another nickname than the target, for example a second
  device of the same account, it also gets its own copy, on this server or
  across a link.
- **The recipient is online, but not on that device:** normal delivery to the
  recipient's connections, and the envelope is also queued for the device.
  The sender gets `E2EE QUEUED <target> <device> <qid>`.
- **The recipient is offline (the target names an account):** the envelope is
  queued. There is no 401 and no other delivery.
- **Not queued:** an unknown device (`UNKNOWN_DEVICE`), a full queue
  (`QUEUE_FULL`), or a sender who is not logged in (`ACCOUNT_REQUIRED`). In
  these cases the server does not queue the envelope and replies with that
  error.

On `BIND`, queued envelopes are sent oldest first, each with its original
sender, command, target, and tags, plus the `qid` server tag. `ACK` removes
them. Unacknowledged envelopes are sent again on the next `BIND`, so a client
should acknowledge only after it has decrypted and stored a message. Queued
envelopes expire after `queue_ttl` seconds.

Messages without the `dst` tag are not affected: an offline nickname still
gets 401.

## Channels (Sender Keys)

The server needs nothing special for channels. A client sends its Sender Key
to each member over the direct-message path (for example with
`e2ee-type=skdist`, queued for offline devices like any envelope), then
encrypts each channel message once and sends one `PRIVMSG #channel`. Members
must rotate and redistribute their Sender Keys when anyone leaves, is kicked,
or quits. Clients see this through normal `PART`, `KICK`, and `QUIT`, and
`extended-join` and `account-notify` give the accounts involved.

## Server links

Every server in the network keeps the whole directory and every queue, so a
device can fetch from, queue for, and bind on any server. Changes are sent
to the peers and relayed onward, never back to the link they came from.
A newly linked server gets everything in its burst. The lines come from the
server, except `BIND`, which comes from the user:

```text
:<server> E2EE DEVICE <account> <device> <updated-us> <identity> <spk-id>:<spk> <sig>
:<server> E2EE PREKEYS <account> <device> <id>:<key> ...
:<server> E2EE USE <account> <device> <prekey-id>
:<server> E2EE DELETE <account> <device>
@egorsmkv.github.io/e2ee-body=<b64 json>;egorsmkv.github.io/e2ee-tags=<b64 json> :<server> E2EE QUEUE <account> <device> <qid> <expires> <command> <target> <sender>
:<server> E2EE ACK <account> <device> <qid>[,<qid>...]
:<nick!user@host> E2EE BIND <device>
```

A queued envelope's body and tags travel in server tags, so they are not
limited by the 512-octet line. An envelope too large for the 8191-byte tag
section stays on the server where it was queued. Replication is eventually
consistent:

- **Bundles:** the bundle with the newer `updated` time wins.
- **One-time prekeys:** a server remembers the ids it has handed out, so a
  burst cannot bring one back.
- **Splits:** two servers that are split can still hand out the same prekey.
  The second X3DH session then fails, and that client fetches again.
- **Bindings:** a `BIND` is valid while that user is still logged into the
  same account and owns the device. Publish the device (`E2EE PUBLISH`, which
  the server replicates as `E2EE DEVICE`) before a peer binds it. A remote
  `BIND` for a device this server has no row for is rejected
  (`e2ee_unknown_device` from `briskd_e2ee:receive_link/4`) and drops the link.
  A remote `BIND` cannot take over a device this server has already bound to
  a local connection (`e2ee_device_bound_locally`, also a link drop); the
  local binding is left in place. A binding follows nickname changes and is
  cleared when the user logs out, switches accounts, or quits.
- **Link ingress validation:** a peer's `E2EE` lines must carry a trusted
  server prefix (or a verified remote user prefix for `BIND`), and `E2EE QUEUE`
  verifies that the envelope sender is a remote user behind that peer.

## Testing with real clients

`test/e2ee/` holds Python clients that do the cryptography for real:
- `e2ee_crypto.py`: X3DH, the Double Ratchet with skipped message keys, and
  Sender Keys, using the `cryptography` package.
- `device.py`: one device. It publishes and binds its keys, keeps sessions
  with identity keys pinned on first use (TOFU), and handles multiline
  envelopes and channel sender keys.
- `test_e2ee.py`: the tests.

`test/e2ee/run` starts two linked servers (`hub` and `leaf`) and runs the
tests in Docker Compose. CI runs it as well. The tests cover:

- the crypto alone
- direct messages
- the offline queue with `ACK`
- long multiline messages
- two devices of one account
- bundles and queues across the link
- channel Sender Keys with rotation when a member leaves
- TOFU detecting a changed identity key
- refusal of keys without an account

## Limits and notes

- **Line length.** The tag section has its own budget of 8191 bytes, but the
  rest of a line stays within 512 octets. In
  `PRIVMSG alice :<ciphertext>` that leaves about 470 bytes of base64, about
  350 bytes of raw ciphertext. Longer messages need a `draft/multiline` batch
  (up to 4096 bytes, queued like any envelope), or several envelopes.
  The pasted proposal's claim that message tags extend the message length is
  incorrect. Key bundles use several plain IRC lines for the same reason,
  instead of one JSON blob.
- **Numerics.** The proposal's 900 and 901 replies are not used: 900 is
  RPL_LOGGEDIN, which SASL already sends.
- **Persistence.** Bundles and queued envelopes are Mnesia disc copies and
  survive a restart (see [Mnesia operations](mnesia.md)). Chat history, when
  enabled, also records the ciphertext of direct messages. It cannot read it.
- **Bouncers.** A bouncer must either hold the keys (which ends
  end-to-end encryption) or pass ciphertext to the client that holds them.
- **Legacy clients.** These see the base64 ciphertext. A sending client may put
  a short notice such as `[encrypted message]` in a plain `NOTICE` for them.
