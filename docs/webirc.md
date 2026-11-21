# WebIRC

This page is for someone using the browser client: an account, channels and
private messages, files, calls, and encryption. It is not the operator
reference for the `webui` JSON key ([Configuration](configuration.md)), and
it is not the TypeScript layout ([Development](development.md)).

The `webirc` list in the configuration file is a different thing: trusted
gateways that connect on behalf of users. The pages below are the HTTP
service started by `webui`.

## Open the client

The operator turns on `webui` and at least one of `ws_port` or `wss_port`.
Without a WebSocket listener, `/` and the other chat paths respond with
404. The listen address and port are `bind` and `port` inside `webui`
(the sample is `127.0.0.1` port `8080`). Open that origin in a browser:

```text
http://127.0.0.1:8080/
```

Put the HTTP service behind TLS before anyone uses it from another machine.
Calls need a secure page (HTTPS, or `localhost`); see
[Voice and video calls](calls.md).

| Path | What it is |
| --- | --- |
| `/`, `/webirc` | Connect form, then the chat |
| `/status` | The server-status conversation |
| `/channel/<name>` | That channel. A name without `#`, `&`, `+`, or `!` is treated as `#<name>` |
| `/dm/<nick>` | A private conversation with that nickname |
| `/signup` | Create an account. Served only when `account_registration` is on |
| `/verify` | Enter an emailed verification code. Served only when `account_verification` is set |
| `/recover` | Reset a password by email. Served only when `account_verification` uses SMTP |
| `/admin/login` | Sign-in for the WebUI administrator, not for an IRC account |

Switching conversations rewrites the address (`/channel/lobby`, `/dm/alex`).
Reloading that address opens the same conversation after you are connected.
Moving from the chat to Sign up, Verify, or Recover in the same tab keeps
the IRC connection.

## Create an account

On the connect card, **Create account** goes to `/signup`. The server omits
that page when `account_registration` is off (the default is on). From an
already open chat tab the link then shows a not-found page.

1. Account name.
2. Email. The field says it is needed only when the server requires one
   (`account_registration_email_required`).
3. Password, twice. The server rejects a password shorter than
   `account_password_min` (8 bytes unless the operator changed it).
4. Accept the Terms of Use and Privacy Policy. Those links are `terms_url`
   and `privacy_url` on `webui`.
5. Complete the ALTCHA check ("I'm not a robot").
6. **Create Account**.

If the server is set up to verify email, the page tells you to check for a
link or a code. Otherwise it tells you the account can sign in with SASL.
How mail is sent is an operator setting; see `account_verification` in
[Configuration](configuration.md).

## Verify an account

**Verify account** on the connect card goes to `/verify`, and so does the
link in the verification email. The email link fills the account or the
email address and the code (`?account=` or `?email=`, and `?code=`). You
can also type them.

Enter the email (or leave the prefilled account), paste the code, complete
ALTCHA, and press **Verify Account**. The page then says the account can
sign in with SASL. A wrong or expired code is an error on the same form;
the code lifetime is the operator's `ttl` (900 seconds unless changed).

## Recover a password

**Recover password** goes to `/recover`. The page exists only when
`account_verification` is configured with SMTP. Otherwise the server
answers 404.

1. **Request Code.** Email address and ALTCHA, then **Send Recovery Code**.
   The reply does not say whether an account uses that address.
2. **Reset Password.** Email, the code from the message, and the new
   password twice, plus ALTCHA.

A link that already carries `?code=` opens the second step. After a
successful reset, sign in with SASL and the new password.

## Sign in

The connect card asks for:

| Field | Required | Meaning |
| --- | --- | --- |
| Nickname | yes | The name other people see. It has to pass the server's nickname rules (`nicklen`, 9 by default, up to 30) |
| Channels | no | Comma-separated channels to join. The box starts with up to five channels from the server configuration, or `#lobby` when none are set |
| SASL Account / SASL Password | no | Under **Account and server**. Leave them empty to chat without an account. Encryption, and calls when the operator set `require_account`, need an account |
| WebSocket URL | yes | Filled in from this page and the server's WebSocket ports. On an HTTPS page with no `wss_port` it is `wss://<this host>/ws`, which a TLS proxy forwards to the plain WebSocket port. Change it only if you were told to |

Complete ALTCHA and press **Connect**. A failed check or a bad WebSocket
URL stays on this card with an error.

The tab stores the nickname, account, password, channel list, and
WebSocket URL in `sessionStorage`. A reload connects again without ALTCHA.
**Disconnect** (the button at the right of the chat header) clears that
saved session, sends `QUIT`, and returns to the connect form. Closing the
tab drops the saved session as well. The password sits in that tab until
one of those happens; it is not a separate WebUI account.

If the socket drops and you did not press Disconnect, a bar above the
message box counts down and offers **Reconnect now** and **Cancel**. The
wait starts near one second and grows, up to about a minute. The header
button then means Reconnect instead of Disconnect. The sidebar shows
Connected or Offline.

## Channels and private messages

The left column lists **Channels** and **Direct Messages**, and your
nickname. **Join** accepts `#channel` (a name with no channel prefix is
joined as `#name`). The compass (**Browse public channels**) opens
**Discover Channels**: the server's channel list, a filter on names and
topics, and **Refresh**.

Click a member to open a private conversation, or type
`/msg <nick> <text>` (`/query` and `/pm` are the same). The members list
is the people icon in the header. On a narrow screen it is a drawer; on a
wide screen it is a column. Filter it by nickname. Operators, voiced
users, and everyone else are grouped. An away user is marked. A configured
assistant shows a bot badge; it is an ordinary user in the channel
([AI assistant bots](bots.md)).

The header shows the open target: **Server Status**, a channel (with its
topic), or a nickname. The message box:

- Enter sends. Shift+Enter starts a new line.
- Tab completes nicknames. `@` opens the same list.
- `/` opens the command list. `/help` prints that list. A message that
  should begin with `/` is sent by typing `//`.
- Commands that do not apply here (calls, search, encryption, operator
  commands) stay out of the list until the server offers them or you are
  an operator.

| Command | What it does |
| --- | --- |
| `/join #channel [key]`, `/j` | Join |
| `/part [#channel] [reason]`, `/leave` | Leave |
| `/msg <nick> <text>` | Private message |
| `/notice <target> <text>` | Notice |
| `/me <action>` | Action line |
| `/nick <new nick>` | Change nickname |
| `/topic [text]` | Show or set the topic of the open channel |
| `/mode <target> [modes]` | Show or change modes |
| `/kick <nick> [reason]` | Remove someone from the open channel |
| `/invite <nick> [#channel]` | Invite |
| `/whois <nick>`, `/whowas <nick>`, `/who [mask]`, `/names` | Look people up |
| `/list [filter]` | Channel list (same data as Discover) |
| `/away [message]`, `/back` | Away and return |
| `/history [limit]` | Load earlier lines of this conversation |
| `/quit [reason]` | Disconnect |
| `/clear` | Clear the lines shown in this conversation (not the server's history) |

When the server allows them, and the matching switch under
**Settings → General** is on, a message can be reacted to, replied to,
edited (your own plain text, not a file, a voice clip, or an encrypted
line), or deleted (yours, or any message if you are a channel operator). Hover the line, or tap it, for
those actions. A reply or an edit shows a banner above the box; the X
cancels it. A typing line can appear above the box. Links can show a
preview card. The operator can turn each of these off for the whole server
(`features` in the configuration, or **Features & Media** in the admin
panel). A switch the server has turned off stays off in the browser.
[Configuration](configuration.md) lists the keys.

If the server keeps history (`chathistory`, on by default), earlier
messages load as you scroll and `/history` asks for more. A reload of this
tab shows the conversations that were open and fetches only newer lines.
Private messages sent while you were not logged in are not stored on the
server as account history; the tab is what still has them.
[Configuration](configuration.md) describes `retention` and
`history_limit`.

**Edit topic** and **Moderate** appear in the header only when you are a
channel operator there (an IRC operator counts). **Set Channel Topic**
saves with **Save Topic**; an empty topic clears it. **Channel
Moderation** toggles moderated (`+m`), invite-only (`+i`), topic
restricted to operators (`+t`), no external messages (`+n`), and secret
(`+s`); invites a nickname; sends a channel notice; and adds or removes
ban masks. On a member row, an operator can also op, voice, kick, or kick
and ban.

## Files and voice messages

The **+** button on the message box is hidden until the server offers file
uploads or voice messages. Both are off until the operator configures
them. Each one is an S3-compatible bucket: `files` and `voice` in
[Configuration](configuration.md). An administrator can switch a
configured service off from **Features & Media** without deleting that
configuration.

| Choice | Needs | What you do |
| --- | --- | --- |
| **Attach file** | `files` | Pick files, drop them on the conversation, or paste them into the box. The menu shows the size limit from the server. At most 10 files go out together. Two or more images are sent as one album |
| **Share Code Snippet** | `files` | Paste source, pick a language, and an optional title, then **Send Snippet** |
| **Voice message** | `voice` | Records in the browser (Opus) after the microphone is allowed. The clip stops at 120 seconds. **Cancel** discards it; the timer button sends it |

These controls do nothing on **Server Status**; pick a channel or a person
first.

In a conversation whose lock is on, a file is encrypted in the browser
before it is uploaded, and the server stores ciphertext. A voice clip is
encrypted the same way only when file uploads are also enabled. If they
are not, the voice endpoint stores the audio. Files and voice messages
are not linked to an account: deleting the account does not delete them.

## Voice and video calls

Calls are one person to one person. They show up only when the operator
sets `calls` and rtpengine is reachable. Media is WebRTC to rtpengine, not
an IRC message; neither side learns the other's IP address. Setup, limits,
and what a call looks like on the wire are in
[Voice and video calls](calls.md).

Open a private conversation. The header shows **Call**, and **Video** when
the server allows video. The buttons are disabled while you are already in
a call or that person is offline. The other person gets a dialog:
**Decline**, **Accept** (a video call answers with your camera off), and
**Video** (camera on). During the call a bar shows who it is, the state
and duration, mute, hold, and hang up. A video call adds a camera button
and a picture over the conversation (**Minimize**, **Full screen**).
`/call [nick]`, `/videocall` or `/vcall`, and `/hangup` do the same.

**Settings → Calls** chooses the microphone, speakers, camera, volume,
ring sound, and audio processing. Those choices stay in this browser
(`localStorage`). They are not sent to the server. The
[calls guide](calls.md#using-calls-in-webirc) lists each control.

One call at a time. A second incoming call is declined as busy. The
conversation records how the call ended.

## Encryption

Encryption is off until the operator sets `e2ee`
([Configuration](configuration.md),
[End-to-end encryption](e2ee.md)). The lock in the header is one
conversation at a time. An open lock is off; a closed lock is on. Turning
it on requires a SASL account on a server that offers the capability.
Without either, the click explains why and the conversation stays in the
clear. `/e2ee on`, `off`, `status`, `rotate`, `verify`, and `reset` are
the same controls.

Cryptography runs in the browser. With the lock on, message bodies are
ciphertext. The server stores public keys, routes those bodies, and can
queue them for a device that is offline. It does not read them, and a
history copy of them is still ciphertext. It does see the nickname, the
account, the channel or the person you addressed, and that a message was
sent. With the lock off, the text is ordinary IRC: the server can store it
and deliver it to the other members. Message text is not written to the
log; see [Configuration](configuration.md).

**Settings → E2EE Keys** shows whether encryption is active, the account,
the device id, how many one-time prekeys are left, how many sessions
exist, and your identity fingerprint.

| Button | Effect |
| --- | --- |
| **Download Keys** | Saves a JSON backup encrypted with a passphrase of at least 6 characters |
| **Upload Keys** | Restores a backup. Asks for that passphrase, then binds the device again |
| **Upload Prekeys** | Sends 20 new one-time prekeys |
| **Rotate Channel Key** | Only for the channel you have open, and only once the device is bound |
| **Reset Device Keys** | New identity keys. People you already talk to see a new key. Asks you to confirm |

**Trusted Peer Devices** lists safety numbers pinned on first use. Compare
a number with the other person out of band. **Forget** drops that pin and
the session. Keys live in this browser. Another browser is a new device
unless you upload the backup there. The key agreement and what a lost
backup means are in [End-to-end encryption](e2ee.md).

## Settings and your data

The gear on the connect card and in the chat header opens **Workspace
Settings**.

**General** is stored in this browser: theme, language (English or
Hebrew), screen layout (auto, mobile, or desktop), message density
(avatars, or a compact IRC layout), font size, timestamps, join/part/quit
lines, desktop notifications on mentions, and the chat-feature switches
from the previous section. **Load avatars from other sites** is off until
you turn it on.

**Calls** and **E2EE Keys** are the sections above. **My Data**:

- **Clear this browser's data** removes settings, theme, language, the
  saved session, cached direct messages, and encryption keys stored here.
  The button asks you to confirm. Encrypted messages you cannot decrypt
  on another device stay unreadable. This does not delete the account.
- **Delete my account** needs the account name, the password, and the
  confirmation checkbox, then **Delete my account and data**. The server
  removes the account, its password, email, and client certificates;
  messages you sent while logged in, from channel and direct-message
  history; direct conversations with people who were not logged in; and
  read markers, encryption devices, and messages waiting for those
  devices. Every connection using the account is signed out. Not deleted:
  messages you sent without being logged in, shared files and voice
  messages, and copies on other servers of the network. This cannot be
  undone.

## Admin page

`/admin` is for the person who runs this server. It is not an IRC
operator login and not a SASL account. **Admin sign in** at
`/admin/login` asks for the `username` and `password` from the `webui`
object. A missing session is sent back to that form. After a successful
sign-in the browser opens `/admin` (or the admin path that sent you to
the form).

The panel tabs are Overview, Stats, Clients, Channels, Links, Accounts,
DroneBL, Features & Media, and Operations. From there an administrator
can see who is connected, change channels, turn configured features on
and off, rebuild search, and drain or stop the server. What each control
changes, how the session cookie works, and the lockout after repeated
failed sign-ins are in [Configuration](configuration.md) (`webui`,
"Server statistics in the admin panel", and "Changing features from the
admin panel"). Chat users do not need that page.
