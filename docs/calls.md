# Voice calls

The server can relay one-to-one voice calls between WebIRC users (or any
client that implements the protocol below). Media goes through
[rtpengine](https://github.com/sipwise/rtpengine): each browser talks
WebRTC (ICE, DTLS-SRTP, Opus) to rtpengine, and rtpengine forwards the audio
to the other side. Neither user learns the other's IP address.

Calls are a server extension, not part of RFC 1459/2812 or IRCv3. They are
user-to-user only (no group calls), audio only, and between users on the same
server: a user on a linked server cannot be called.

## Setup

1. Run rtpengine (12.x was tested) where browsers can reach it over UDP. The
   repository has an image built from Debian's `rtpengine-daemon` package in
   [`docker/rtpengine`](https://github.com/egorsmkv/irc-server/tree/main/docker/rtpengine).
   It runs in userspace mode (no kernel module) and takes:

   | Variable | Default | Meaning |
   | --- | --- | --- |
   | `RTPENGINE_ADVERTISE` | container address | Address put in SDP; must be reachable by browsers (your public IP in production) |
   | `RTPENGINE_NG_PORT` | `2223` | NG control port (UDP); keep it private |
   | `RTPENGINE_PORT_MIN`, `RTPENGINE_PORT_MAX` | `30000`, `30100` | Media port range (UDP); open it in the firewall. Each call uses two ports |
   | `RTPENGINE_LOG_LEVEL` | `6` | syslog level |

   A native installation works the same way, for example
   `rtpengine --interface=10.0.0.5!203.0.113.7 --listen-ng=10.0.0.5:2223 --port-min=30000 --port-max=30100`.

2. Point the server at the NG control port:

   ```json
   "calls": { "rtpengine": "rtpengine:2223" }
   ```

| Key | Default | Description |
| --- | --- | --- |
| `rtpengine` | required | `host:port` of rtpengine's NG control socket (UDP) |
| `ring_timeout` | `45` | Seconds a call may ring before it ends as `no-answer` (5..300) |
| `max_duration` | `7200` | Longest call in seconds (0..86400; `0` means no limit) |
| `max_calls` | `100` | Calls (ringing or active) at once on this server (1..10000) |
| `calls_per_minute` | `6` | New calls a user may start per minute (1..120) |
| `require_account` | `false` | Only users logged in to an account may use `CALL`; calling a user who is not logged in fails with `TARGET_UNSUPPORTED` |

With `calls` set, the server advertises the capability
`egorsmkv.github.io/calls=v=1,ring=<ring_timeout>`. Changes need a restart
(`REHASH` does not apply them).

WebRTC needs a secure context: serve WebIRC over HTTPS (`wss_port` or a TLS
proxy) except on `localhost`. No STUN or TURN server is needed, since
rtpengine terminates ICE on each leg; it must have an address that browsers
can reach directly.

## Using calls in WebIRC

Open a private conversation and press **Call** in the header (or type
`/call nick`). The other user sees an incoming-call dialog with **Accept** and
**Decline**, a ring tone, and, when the tab is in the background and
notifications are allowed, a desktop notification. During a call a floating
bar shows the other user, the call state and duration, a mute button, and a
hang-up button. `/hangup` ends the call. The conversation records how each
call ended ("Call ended (3:12)", "Missed call from alice", "Line busy").

A user can be in one call at a time; a second caller is rejected as busy.

## Protocol

Clients request the `egorsmkv.github.io/calls` capability. Session
descriptions do not fit an IRC line and contain line breaks, so they travel
base64-encoded in numbered chunks of at most 400 characters (at most 40
chunks and 12 KiB decoded). Descriptions must be complete (gather ICE
candidates before sending) and contain only audio.

```text
CALL OFFER   <nick> <token> <part> <total> :<chunk>   caller → callee
CALL RINGING <nick> <token>                           callee → caller
CALL ANSWER  <nick> <token> <part> <total> :<chunk>   callee → caller
CALL REJECT  <nick> <token> [:<reason>]               callee → caller
CALL HANGUP  <nick> <token> [:<reason>]               either side
```

`<token>` (8 to 32 letters and digits) is chosen by the caller and names the
call for both sides. `<nick>` is the other party. The server rewrites each
description through rtpengine and delivers it to the other party with the
sender's prefix:

```text
:alice!a@host CALL OFFER bob Xk2r9QmT41 1 3 :dj0wDQpvPS0gNDYx...
```

The server ends calls itself with a `HANGUP` from the server name and one of
these reasons: `no-answer` (ring timeout), `max-duration`, `disconnected`
(the other side quit), or `media-error`. Clients use `declined`, `busy`,
`cancelled`, `normal`, and `failed`.

Errors are standard replies, `FAIL CALL <code> [<token>] :<text>`:

| Code | Meaning |
| --- | --- |
| `NEED_CAPABILITY` | The client did not negotiate the capability |
| `ACCOUNT_REQUIRED` | `require_account` is set and the client is not logged in |
| `INVALID_PARAMS`, `UNKNOWN_SUBCOMMAND` | Malformed command, token, or chunk; chunks out of order |
| `INVALID_TARGET` | Calling yourself |
| `NO_SUCH_NICK`, `TARGET_REMOTE`, `TARGET_UNSUPPORTED` | The callee is offline, on another server, or lacks the capability |
| `TARGET_BUSY` | The callee is in another call |
| `ALREADY_IN_CALL` | The caller is in another call |
| `LIMIT_REACHED`, `RATE_LIMITED` | `max_calls` or `calls_per_minute` exceeded |
| `INVALID_SDP` | The description is not valid base64 SDP with audio only |
| `TIMEOUT` | A chunked description was not completed within 10 seconds |
| `INVALID_STATE`, `UNKNOWN_CALL` | The command does not fit the call's state, or no such call |
| `MEDIA_ERROR` | rtpengine refused the description or did not answer |

## Server behavior

`ircd_calls` owns the call table and a UDP socket to rtpengine. For each call
it sends an NG `offer` (with `ICE=force`, `UDP/TLS/RTP/SAVPF`, `rtcp-mux`
required, SDES off) and later an `answer`, and a `delete` when the call ends.
NG requests are retried twice, one second apart; after that the call fails
with `media-error`. A call ends when either user disconnects, and the other is
told. Call state is kept in memory, so a server restart ends all calls.

Logs contain `call_started`, `call_answered` (with setup time), `call_ended`
(with reason and duration), and `call_media_error`, identified by an internal
call id. Nicknames, descriptions, and addresses are not logged, and `CALL`
lines are not included in command logging.

## Testing

`test/calls/run` starts ircd, the rtpengine image, and two Python WebRTC
clients (aiortc) on a Docker network. The clients call each other over IRC,
check that neither sees the other's address, and require two seconds of audio
to arrive in each direction through rtpengine. CI runs it. The unit and
protocol tests (`test/ircd_call_tests.erl`) use a fake rtpengine.

The development compose file includes rtpengine, advertising `127.0.0.1` with
UDP ports 30000–30100 published, and `config/ircd.dev.json` enables calls, so
two browser windows on the same machine can call each other.
