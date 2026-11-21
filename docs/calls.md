# Voice and video calls

The server can relay one-to-one voice and video calls between WebIRC users
(or any client that implements the protocol below). Media goes through
[rtpengine](https://github.com/sipwise/rtpengine): each browser talks WebRTC
(ICE, DTLS-SRTP, Opus audio, VP8/H.264 video) to rtpengine, and rtpengine
forwards the media to the other side without transcoding. Neither user
learns the other's IP address.

Calls are a server extension, not part of RFC 1459/2812 or IRCv3. They are
user-to-user only (no group calls). Users on linked servers
can call each other (see [Calls across linked servers](#calls-across-linked-servers)).

## Setup

1. Run rtpengine (12.x was tested) where browsers can reach it over UDP. The
   repository has an image built from Debian's `rtpengine-daemon` package in
   [`docker/rtpengine`](https://github.com/egorsmkv/irc-server/tree/main/docker/rtpengine).
   It runs in userspace mode (no kernel module) and takes:

   | Variable | Default | Meaning |
   | --- | --- | --- |
   | `RTPENGINE_ADVERTISE` | container address | Address put in SDP; must be reachable by browsers (your public IP in production) |
   | `RTPENGINE_NG_PORT` | `2223` | NG control port (UDP); keep it private |
   | `RTPENGINE_PORT_MIN`, `RTPENGINE_PORT_MAX` | `30000`, `30100` | Media port range (UDP); open it in the firewall. A voice call uses two ports, a video call four |
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
| `video` | `true` | Allow video calls: a description may carry one video section next to its audio. `false` accepts audio only (`INVALID_SDP` for video) and leaves `video` out of the capability value |

With `calls` set, the server advertises the capability
`egorsmkv.github.io/calls=v=1,ring=<ring_timeout>,hold,video` (`video` only
when `video` is on). Changes need a restart (`REHASH` does not apply them).

Video goes through rtpengine like audio: budget about 1 to 2.5 Mbit/s in each
direction per video call on the rtpengine host (the browsers adapt to the
network), against tens of kbit/s for voice. `max_calls` caps both.

WebRTC needs a secure context: serve WebIRC over HTTPS (`wss_port` or a TLS
proxy) except on `localhost`. No STUN or TURN server is needed, since
rtpengine terminates ICE on each leg; it must have an address that browsers
can reach directly.

## Using calls in WebIRC

Open a private conversation and press **Call** in the header (or type
`/call nick`). The other user sees an incoming-call dialog with **Accept** and
**Decline**, a ring tone, and, when the tab is in the background and
notifications are allowed, a desktop notification. During a call a floating
bar shows the other user, the call state and duration, a mute button, a
hold button, and a hang-up button. **Hold** sends a generated music loop to
the other side in place of your microphone and silences their audio for you;
they see "… put you on hold". **Resume** brings your microphone back (mute is
kept). The call stays connected on hold, so its duration and `max_duration`
keep counting. `/hangup` ends the call. The conversation records how each
call ended ("Call ended (3:12)", "Missed call from alice", "Line busy").

A user can be in one call at a time; a second caller is rejected as busy.

### Video calls

When the server allows video, the header also shows **Video** (or type
`/videocall nick`, `/vcall`). The other user sees "Incoming video call" with
**Decline**, **Accept** (without video: their camera stays off), and
**Video** (with the camera). During a video call:

- A video stage covers the conversation: the other side's picture, your own
  camera in the corner (mirrored), and their avatar with "Camera off" while
  no picture arrives (camera off, on hold, or the network stalled).
  **Minimize** shrinks it to a corner so you can read and write in the
  conversation; click it to bring it back. **Full screen** fills the screen.
- The call bar gains a camera button. Off releases the camera (its light goes
  out) and sends no picture; on opens it again. No renegotiation is needed,
  so the other side sees the change within about a second.
- Hold sends no picture (and the hold audio), and resumes the camera after.
- A camera that is missing, refused, or in use does not fail the call: the
  call goes on with the camera off and the conversation says why.

A video call always negotiates video on both sides, so a user who answered
without video can switch the camera on later. A voice call stays a voice call.

**Settings → Calls** holds the audio preferences. They are stored in the
browser (`localStorage`) and never sent to the server:

- **Microphone** and **Speakers**: the input and output device. A device that
  is unplugged falls back to the system default. Choosing the output needs
  `setSinkId` (Chromium and Firefox); other browsers use the system output.
  Device names appear after the page is allowed to use the microphone.
- **Test microphone** shows a live level meter; **Play test sound** plays a
  short tone on the chosen speakers at the call volume.
- **Call volume**, and **Ring sound for incoming calls**.
- **Audio processing**: echo cancellation, noise suppression, and automatic
  microphone volume (the browser's `getUserMedia` constraints).
- **Audio quality**: an Opus send bitrate cap of 16, 32, 64, or 128 kbit/s,
  or automatic. It is set with `RTCRtpSender.setParameters` and limits what
  this browser sends; the other side chooses its own.

- **Camera** (shown when the server allows video): the camera for video
  calls. A camera that is unplugged falls back to the default one.

Changes apply to a call in progress: a new microphone or processing setting
replaces the sent track without renegotiation, and mute is kept; a new
camera replaces the sent picture.

## Protocol

Clients request the `egorsmkv.github.io/calls` capability. Session
descriptions do not fit an IRC line and contain line breaks, so they travel
base64-encoded in numbered chunks of at most 400 characters (at most 82
chunks and 24 KiB decoded; a browser's video offer lists many codecs).
Descriptions must be complete (gather ICE candidates before sending) and have
one or more audio sections and, when the capability value has `video`, at
most one video section; no other media. A call whose offer has a video
section is a video call; nothing else in the protocol changes. Servers before
video calls accept at most 40 chunks and 12 KiB, and audio only. Lines end in CRLF or LF; a
description with any other CR or a NUL byte is refused.

```text
CALL OFFER   <nick> <token> <part> <total> :<chunk>   caller → callee
CALL RINGING <nick> <token>                           callee → caller
CALL ANSWER  <nick> <token> <part> <total> :<chunk>   callee → caller
CALL REJECT  <nick> <token> [:<reason>]               callee → caller
CALL HANGUP  <nick> <token> [:<reason>]               either side
CALL HOLD    <nick> <token>                           either side
CALL RESUME  <nick> <token>                           either side
```

`<token>` (8 to 32 letters and digits) is chosen by the caller and names the
call for both sides. `<nick>` is the other party. The server rewrites each
description through rtpengine and delivers it to the other party with the
sender's prefix:

```text
:alice!a@host CALL OFFER bob Xk2r9QmT41 1 3 :dj0wDQpvPS0gNDYx...
```

`HOLD` and `RESUME` are accepted only in an active call and relayed to the
other party. They are notices: the hold audio itself is ordinary media that
the client sends instead of its microphone (`RTCRtpSender.replaceTrack`), so
rtpengine and the media path are unchanged. A server whose capability value
lacks `hold` does not relay them; WebIRC then still sends the hold audio.

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
| `NO_SUCH_NICK`, `TARGET_UNSUPPORTED` | The callee is offline, or lacks the capability (also reported by the callee's server for a user on a linked server) |
| `TARGET_REMOTE` | Sent only by older releases: the callee is on another server |
| `TARGET_BUSY` | The callee is in another call |
| `ALREADY_IN_CALL` | The caller is in another call |
| `LIMIT_REACHED`, `RATE_LIMITED` | `max_calls` or `calls_per_minute` exceeded |
| `INVALID_SDP` | The description is not valid base64 SDP with audio and, where allowed, one video section (`not_audio`, `too_many_video`, `too_large`) |
| `TIMEOUT` | A chunked description was not completed within 10 seconds |
| `INVALID_STATE`, `UNKNOWN_CALL` | The command does not fit the call's state (for example `HOLD` before the call is answered), or no such call |
| `MEDIA_ERROR` | rtpengine refused the description or did not answer |

## Calls across linked servers

A user can call a user on another server of the network. The servers
carry the same `CALL` lines over their RFC 2813 link, with the sending
user's prefix, routed hop by hop toward the other user's server like a
private message:

```text
:alice!u@h CALL OFFER bob <token> <part> <total> :<chunk>   any subcommand, user to user
:alpha.example CALL HANGUP bob <token> :<reason>            timeout, disconnect, media failure
:beta.example CALL FAIL alice <token> <code> :<text>        the callee's server refuses
```

- **The caller's server is the media anchor.** It passes the offer, and
  later the callee's answer, through its own rtpengine, so each browser
  still sees only that rtpengine's address. The callee's server never
  contacts its rtpengine for the call; it checks its user (capability,
  `require_account`, busy, `max_calls`, `calls_per_minute`) and relays.
  rtpengine on the caller's server must therefore be reachable from the
  callee's browser, as it is for local calls.
- **Both servers need `calls`.** A callee whose server has no `calls`
  configuration is refused with `TARGET_UNSUPPORTED`. With
  `require_account`, the caller's server requires the callee to be logged
  in, and the callee's server requires the caller to be.
- **Leaving ends the call.** When either user quits, is killed, or is split
  away, the other server ends the call with `HANGUP … :disconnected`. A nick
  change keeps the call. Each server applies its own `ring_timeout` and
  `max_duration`; whichever fires first ends the call on both.
- **Older servers.** A server that does not know `CALL` on a link ignores
  it, so the caller hears no answer and the call ends at `ring_timeout`.
  Upgrade every server on the path.
- Malformed `CALL` lines from a peer, or lines from a source the link may
  not speak for, are logged (`call_link_dropped`) and dropped; the link
  stays up.

## Server behavior

`ircd_calls` owns the call table and a UDP socket to rtpengine. For each call
it sends an NG `offer` (with `ICE=force`, `UDP/TLS/RTP/SAVPF`, `rtcp-mux`
required, SDES off) and later an `answer`, and a `delete` when the call ends.
NG requests are retried twice, one second apart; after that the call fails
with `media-error`. Requests still in flight when a call ends are dropped, so
a retry never reaches rtpengine after the `delete`. The `rtpengine` host is
resolved when the server starts and again for each new call, and NG replies
are accepted only from that address and port; rtpengine must answer from the
address it is configured on (the default). A call ends when either user disconnects, and the other is
told. Call state is kept in memory, so a server restart ends all calls.

Logs contain `call_started`, `call_answered` (with setup time), `call_ended`
(with reason and duration), and `call_media_error`, identified by an internal
call id. Nicknames, descriptions, and addresses are not logged, and `CALL`
lines are not included in command logging.

## Security notes

- Each description is checked for shape and media type only. rtpengine runs
  ICE connectivity checks (STUN) towards the candidates a client sends, so a
  client can make rtpengine send STUN packets to an address of its choosing.
  Media flows only after ICE succeeds. Run rtpengine where its outbound UDP is
  limited to what browsers need, and keep the NG port private.
- There is no per-user call block list: any user who negotiated the
  capability can ring any other one. `calls_per_minute` applies per
  connection, so a user who reconnects gets a fresh allowance; client flood
  and connection limits still apply. `require_account` restricts calls to
  logged-in users.
- `TARGET_BUSY` tells a caller that the callee is in a call.

## Testing

`test/calls/run` starts ircd, the rtpengine image, and two Python WebRTC
clients (aiortc) on a Docker network. The clients call each other over IRC,
check that neither sees the other's address, and require two seconds of audio
to arrive in each direction through rtpengine; a second test makes a video
call and requires audio and video frames in both directions. WebIRC's call
manager is unit-tested with fake devices (`webui/src/calls_lifecycle_test.ts`:
camera on, off, hold, missing camera, answering with or without video, device
changes, and release on every way a call ends). CI runs it. The unit and
protocol tests (`test/ircd_call_tests.erl`) use a fake rtpengine.

`test/calls/browser/run` makes a real WebIRC video call: ircd (with the
assets built from the checkout), rtpengine, and two headless Chromium tabs
with fake cameras and microphones on one Docker network. alice starts the
call with `/videocall`, bob answers with video, and the test requires each
side to decode the other's video, "Camera off" and the picture's return when
either side switches the camera, the minimized stage, and the hang-up closing
both stages and recording the call, with no page or console errors. It keeps
screenshots in `test/calls/browser/shots/`. CI runs it.

The development compose file includes rtpengine, advertising `127.0.0.1` with
UDP ports 30000–30100 published, and `config/ircd.dev.json` enables calls, so
two browser windows on the same machine can call each other. For calls from
other devices (HTTPS and a reachable media address), see "Using the
development server from other devices" in [Development](development.md).
