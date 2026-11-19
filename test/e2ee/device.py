"""One E2EE device for the end-to-end tests: an IRC connection logged into a
SASL account, its keys, its pairwise Double Ratchet sessions, and its channel
sender keys. It speaks the server's E2EE extension (docs/e2ee.md).

Client conventions (the server does not interpret these):

- `+egorsmkv.github.io/e2ee-src` is `<account>:<device>`, so a recipient can
  find the session even for a queued message replayed without other context.
- `+egorsmkv.github.io/e2ee-type` is `prekey`, `msg`, or `sk` (channel).
- The plaintext of a pairwise message is JSON: {"t": text} for a message,
  {"skd": {...}} to hand over a channel sender key.
- An envelope longer than 400 base64 characters is sent as a draft/multiline
  batch of concatenated lines, with the E2EE tags on the BATCH line.
"""

import base64
import itertools
import json
import os
import time

from e2ee_crypto import (
    NO_OPK,
    CryptoError,
    DoubleRatchet,
    Identity,
    PreKeys,
    SenderKey,
    message_envelope,
    parse_envelope,
    prekey_envelope,
    raw,
    x3dh_initiate,
    x3dh_respond,
)
from irc import Connection

VENDOR = "egorsmkv.github.io"
CAP = f"{VENDOR}/e2ee"
SRC, DST, TYPE = f"+{VENDOR}/e2ee-src", f"+{VENDOR}/e2ee-dst", f"+{VENDOR}/e2ee-type"
QID = f"{VENDOR}/e2ee-qid"
CHUNK = 400
_refs = itertools.count(1)


class IdentityChanged(Exception):
    """A device's identity key differs from the one pinned on first use."""


class ServerError(Exception):
    def __init__(self, msg):
        super().__init__(msg.raw)
        self.msg = msg


def b64(data):
    return base64.b64encode(data).decode()


def unb64(text):
    return base64.b64decode(text)


class Device:
    def __init__(self, host, port, nick, account, password, device_id, register=False, prekeys=20):
        self.nick, self.account, self.device_id = nick, account, device_id
        self.conn = Connection(host, port)
        self.identity = Identity()
        self.prekeys = PreKeys(self.identity, prekeys)
        self.sessions = {}
        self.awaiting_reply = {}
        self.trusted = {}
        self.sender_keys = {}
        self.received_keys = {}
        self.inbox = []
        self.fails = []
        self.errors = []
        self.batches = {}
        self.acks = []
        self.replayed = 0
        self.prekeys_low = None
        self._login(password, register)

    # IRC plumbing -------------------------------------------------------

    def _expect(self, predicate, what, timeout=15):
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            msg = self.conn.read(max(left, 0))
            if msg is None:
                raise AssertionError(f"{self.nick}: timed out waiting for {what}")
            self._handle(msg)
            if predicate(msg):
                return msg

    def sync(self):
        token = f"sync{next(_refs)}"
        self.conn.send(f"PING :{token}")
        self._expect(lambda m: m.command == "PONG" and m.params[-1] == token, "PONG")

    def _login(self, password, register):
        caps = f"sasl message-tags batch draft/multiline draft/account-registration {CAP}"
        self.conn.send(f"CAP REQ :{caps}")
        ack = self._expect(lambda m: m.command == "CAP" and m.params[1] in ("ACK", "NAK"), "CAP ACK")
        if ack.params[1] == "NAK":
            raise AssertionError(f"capabilities refused: {ack.raw}")
        self.conn.send(f"NICK {self.nick}")
        self.conn.send(f"USER {self.nick} 0 * :{self.nick}")
        if register:
            self.conn.send(f"REGISTER {self.account} * {password}")
            reply = self._expect(lambda m: m.command in ("REGISTER", "FAIL"), "REGISTER")
            if reply.command == "FAIL":
                raise ServerError(reply)
        else:
            self.conn.send("AUTHENTICATE PLAIN")
            self._expect(lambda m: m.command == "AUTHENTICATE", "AUTHENTICATE +")
            self.conn.send("AUTHENTICATE " + b64(f"\0{self.account}\0{password}".encode()))
            reply = self._expect(lambda m: m.command in ("903", "904"), "SASL result")
            if reply.command == "904":
                raise ServerError(reply)
        self.conn.send("CAP END")
        self._expect(lambda m: m.command == "001", "welcome")

    def e2ee(self, line, done, what):
        """Send an E2EE command; return the reply that satisfies `done`, or
        raise on a FAIL E2EE reply."""
        self.conn.send(f"E2EE {line}")
        reply = self._expect(
            lambda m: done(m) or (m.command == "FAIL" and m.params[:1] == ["E2EE"]), what
        )
        if reply.command == "FAIL":
            raise ServerError(reply)
        return reply

    def close(self):
        self.conn.close()

    # Keys ---------------------------------------------------------------

    def publish(self):
        spk = raw(self.prekeys.spk.public_key())
        self.e2ee(
            f"PUBLISH {self.device_id} {b64(self.identity.public)} "
            f"{self.prekeys.spk_id}:{b64(spk)} {b64(self.prekeys.signature)}",
            lambda m: m.command == "E2EE" and m.params[:2] == ["PUBLISHED", str(self.device_id)],
            "PUBLISHED",
        )
        self.upload_prekeys({k: raw(v.public_key()) for k, v in self.prekeys.one_time.items()})

    def upload_prekeys(self, keys):
        items = sorted(keys.items())
        for i in range(0, len(items), 8):
            chunk = " ".join(f"{k}:{b64(v)}" for k, v in items[i : i + 8])
            self.e2ee(
                f"PREKEYS {self.device_id} {chunk}",
                lambda m: m.command == "E2EE" and m.params[:2] == ["PREKEYS", str(self.device_id)],
                "PREKEYS",
            )

    def fetch(self, target):
        """Bundles of `target`'s devices, checked against pinned identities."""
        self.conn.send(f"E2EE FETCH {target}")
        bundles = []
        while True:
            msg = self._expect(
                lambda m: (m.command == "E2EE" and m.params[0] in ("BUNDLE", "FETCHED"))
                or (m.command == "FAIL" and m.params[:1] == ["E2EE"]),
                "bundles",
            )
            if msg.command == "FAIL":
                raise ServerError(msg)
            if msg.params[0] == "FETCHED":
                return bundles
            _, account, dev, ik, spk, sig, *opk = msg.params
            spk_id, spk_key = spk.split(":", 1)
            bundle = {
                "account": account.lower(),
                "device": int(dev),
                "identity": unb64(ik),
                "spk_id": int(spk_id),
                "spk": unb64(spk_key),
                "signature": unb64(sig),
                "opk_id": None,
                "opk": None,
            }
            if opk:
                opk_id, opk_key = opk[0].split(":", 1)
                bundle["opk_id"], bundle["opk"] = int(opk_id), unb64(opk_key)
            self._pin(bundle["account"], bundle["device"], bundle["identity"])
            bundles.append(bundle)

    def _pin(self, account, device, identity):
        known = self.trusted.setdefault((account, device), identity)
        if known != identity:
            raise IdentityChanged(f"{account}/{device} changed identity key")

    def bind(self, timeout=15):
        """BIND this device; decrypt every queued envelope, then ACK them."""
        reply = self.e2ee(
            f"BIND {self.device_id}",
            lambda m: m.command == "E2EE" and m.params[:2] == ["BOUND", str(self.device_id)],
            "BOUND",
        )
        queued = int(reply.params[2])
        self.replayed = 0
        deadline = time.monotonic() + timeout
        while self.replayed < queued:
            msg = self.conn.read(max(deadline - time.monotonic(), 0))
            if msg is None:
                raise AssertionError(f"{self.nick}: {self.replayed}/{queued} queued envelopes")
            self._handle(msg)
        self.ack()
        return queued

    def ack(self):
        while self.acks:
            batch, self.acks = self.acks[:20], self.acks[20:]
            self.conn.send(f"E2EE ACK {','.join(batch)}")
        self.sync()

    # Pairwise messages --------------------------------------------------

    def send_text(self, nick, account, text):
        self._send_payload(nick, account, {"t": text})

    def _send_payload(self, nick, account, payload, refresh=False):
        account = account.lower()
        devices = sorted(d for (a, d) in self.sessions if a == account)
        if refresh or not devices:
            for bundle in self.fetch(account):
                key = (account, bundle["device"])
                if key not in self.sessions:
                    shared, ad, header = x3dh_initiate(self.identity, bundle)
                    self.sessions[key] = DoubleRatchet.initiator(shared, ad, bundle["spk"])
                    self.awaiting_reply[key] = header
            devices = sorted(d for (a, d) in self.sessions if a == account)
        plaintext = json.dumps(payload).encode()
        for dev in devices:
            key = (account, dev)
            ratchet = self.sessions[key].encrypt(plaintext)
            if key in self.awaiting_reply:
                self._send_envelope(nick, dev, prekey_envelope(self.awaiting_reply[key], ratchet), "prekey")
            else:
                self._send_envelope(nick, dev, message_envelope(ratchet), "msg")

    def _send_envelope(self, target, dev, envelope, kind):
        text = b64(envelope)
        tags = {SRC: f"{self.account}:{self.device_id}", TYPE: kind}
        if dev is not None:
            tags[DST] = str(dev)
        if len(text) <= CHUNK:
            self.conn.send(f"PRIVMSG {target} :{text}", tags)
            return
        ref = f"m{next(_refs)}"
        self.conn.send(f"BATCH +{ref} draft/multiline {target}", tags)
        for i in range(0, len(text), CHUNK):
            line_tags = {"batch": ref}
            if i:
                line_tags["draft/multiline-concat"] = None
            self.conn.send(f"PRIVMSG {target} :{text[i : i + CHUNK]}", line_tags)
        self.conn.send(f"BATCH -{ref}")

    # Channels (Sender Keys) ---------------------------------------------

    def join(self, channel):
        self.conn.send(f"JOIN {channel}")
        self._expect(lambda m: m.command == "JOIN" and m.nick == self.nick, f"JOIN {channel}")
        self.sync()

    def members(self, channel):
        """(nick, account) of the other members, from WHOX."""
        self.conn.send(f"WHO {channel} %tna,42")
        found = []
        while True:
            msg = self._expect(lambda m: m.command in ("354", "315"), "WHO")
            if msg.command == "315":
                return [(n, a) for n, a in found if n != self.nick and a != "0"]
            if msg.params[1] == "42":
                found.append((msg.params[2], msg.params[3]))

    def share_sender_key(self, channel, rotate=False):
        """Create (or rotate) our sender key and hand it to every member."""
        if rotate or channel not in self.sender_keys:
            self.sender_keys[channel] = SenderKey.create()
        handover = {"skd": dict(self.sender_keys[channel].distribution(), channel=channel)}
        for nick, account in self.members(channel):
            self._send_payload(nick, account, handover)
        self.sync()

    def send_channel(self, channel, text):
        data = self.sender_keys[channel].encrypt(json.dumps({"t": text}).encode(), channel)
        self._send_envelope(channel, None, data, "sk")

    # Receiving ----------------------------------------------------------

    def _handle(self, msg):
        if msg.command == "FAIL":
            self.fails.append(msg)
        elif msg.command == "E2EE" and msg.params[:1] == ["PREKEYS"] and len(msg.params) == 3:
            self.prekeys_low = int(msg.params[2])
        elif msg.command == "BATCH" and msg.params and msg.params[0].startswith("+"):
            if len(msg.params) > 1 and msg.params[1] == "draft/multiline":
                self.batches[msg.params[0][1:]] = (msg, [])
        elif msg.command == "BATCH" and msg.params and msg.params[0].startswith("-"):
            opened = self.batches.pop(msg.params[0][1:], None)
            if opened:
                start, lines = opened
                text = "".join(lines)
                self._receive(start.tags, start.prefix, start.params[2], text)
        elif msg.command in ("PRIVMSG", "NOTICE") and msg.tags.get("batch") in self.batches:
            self.batches[msg.tags["batch"]][1].append(msg.params[-1])
        elif msg.command == "PRIVMSG" and TYPE in msg.tags:
            self._receive(msg.tags, msg.prefix, msg.params[0], msg.params[-1])

    def _receive(self, tags, prefix, target, text):
        qid = tags.get(QID)
        try:
            account, dev = tags[SRC].rsplit(":", 1)
            account, dev = account.lower(), int(dev)
            if tags.get(TYPE) == "sk":
                self._receive_channel(target, account, dev, text, queued=qid is not None)
            elif tags.get(DST) == str(self.device_id):
                self._receive_pairwise(account, dev, text, queued=qid is not None)
            else:
                return  # an envelope for another device of this account
            if qid:
                self.acks.append(qid)
        except (CryptoError, KeyError, ValueError) as exc:
            self.errors.append((prefix, str(exc)))
        finally:
            if qid:
                self.replayed += 1

    def _receive_pairwise(self, account, dev, text, queued):
        kind, header, ratchet = parse_envelope(unb64(text))
        key = (account, dev)
        plaintext = None
        if key in self.sessions:
            try:
                plaintext = self.sessions[key].decrypt(ratchet)
            except CryptoError:
                if kind != "prekey":
                    raise
        if plaintext is None:
            if kind != "prekey":
                raise CryptoError("no session for message envelope")
            shared, ad, their_identity, opk_id = x3dh_respond(self.identity, self.prekeys, header)
            self._pin(account, dev, their_identity)
            session = DoubleRatchet.responder(shared, ad, self.prekeys.spk)
            plaintext = session.decrypt(ratchet)
            if opk_id != NO_OPK:
                self.prekeys.one_time.pop(opk_id, None)
            self.sessions[key] = session
        self.awaiting_reply.pop(key, None)
        payload = json.loads(plaintext)
        if "skd" in payload:
            data = payload["skd"]
            self.received_keys[(data["channel"], account, dev)] = SenderKey.from_distribution(data)
        else:
            self.inbox.append(
                {"from": account, "device": dev, "text": payload["t"], "channel": None, "queued": queued}
            )

    def _receive_channel(self, channel, account, dev, text, queued):
        state = self.received_keys.get((channel, account, dev))
        if state is None:
            raise CryptoError("no sender key")
        payload = json.loads(state.decrypt(unb64(text), channel))
        self.inbox.append({"from": account, "device": dev, "text": payload["t"], "channel": channel, "queued": queued})

    def wait_text(self, text, timeout=15):
        """Read until a message with `text` has been decrypted."""
        deadline = time.monotonic() + timeout
        while not any(m["text"] == text for m in self.inbox):
            msg = self.conn.read(max(deadline - time.monotonic(), 0))
            if msg is None:
                raise AssertionError(f"{self.nick}: never decrypted {text!r}; errors={self.errors}")
            self._handle(msg)
        return next(m for m in self.inbox if m["text"] == text)

    def drain(self, seconds=1.0):
        deadline = time.monotonic() + seconds
        while (left := deadline - time.monotonic()) > 0:
            msg = self.conn.read(left)
            if msg is None:
                return
            self._handle(msg)


def unique(prefix):
    return f"{prefix}{os.urandom(3).hex()}"
