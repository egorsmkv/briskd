"""Signal-style end-to-end encryption for the ircd E2EE test clients.

Everything here runs in the client; the server only stores public keys and
routes ciphertext. The constructions follow the Signal specifications:

- X3DH key agreement (https://signal.org/docs/specifications/x3dh/). The
  identity key is an Ed25519 signing key plus an X25519 key, published as the
  64 bytes ed25519_pub || x25519_pub (instead of XEdDSA).
- The Double Ratchet (https://signal.org/docs/specifications/doubleratchet/)
  with HKDF-SHA256, HMAC-SHA256 chains, AES-256-GCM, and skipped message keys.
- Sender Keys for channels: a symmetric hash ratchet per sender and channel,
  messages signed with an Ed25519 key, distributed over the pairwise sessions.

Wire formats (base64 in the IRC message, see docs/e2ee.md):

    prekey envelope: 0x01 0x01 | ik(64) | ek(32) | spk_id(4) | opk_id(4) | ratchet
    message envelope: 0x01 0x02 | ratchet
    ratchet message:  dh(32) | pn(4) | n(4) | AES-GCM ciphertext
    channel message:  0x01 0x03 | key_id(4) | iteration(4) | ciphertext | sig(64)
"""

import copy
import hashlib
import hmac
import os
import struct

from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

VERSION = 1
PREKEY, MESSAGE, CHANNEL = 1, 2, 3
NO_OPK = 0xFFFFFFFF
MAX_SKIP = 1000


class CryptoError(Exception):
    """A message failed authentication or could not be decrypted."""


def raw(public_key):
    return public_key.public_bytes(Encoding.Raw, PublicFormat.Raw)


def hkdf(ikm, salt, info, length):
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def aead_encrypt(message_key, plaintext, ad):
    material = hkdf(message_key, b"\0" * 32, b"ircd-e2ee message keys", 44)
    return AESGCM(material[:32]).encrypt(material[32:], plaintext, ad)


def aead_decrypt(message_key, ciphertext, ad):
    material = hkdf(message_key, b"\0" * 32, b"ircd-e2ee message keys", 44)
    try:
        return AESGCM(material[:32]).decrypt(material[32:], ciphertext, ad)
    except InvalidTag as exc:
        raise CryptoError("authentication failed") from exc


def kdf_chain(chain_key):
    """Symmetric ratchet step: (next chain key, message key)."""
    return (
        hmac.new(chain_key, b"\x02", hashlib.sha256).digest(),
        hmac.new(chain_key, b"\x01", hashlib.sha256).digest(),
    )


class Identity:
    """Long-term identity: Ed25519 for signatures, X25519 for X3DH."""

    def __init__(self):
        self.signing = Ed25519PrivateKey.generate()
        self.dh = X25519PrivateKey.generate()

    @property
    def public(self):
        return raw(self.signing.public_key()) + raw(self.dh.public_key())

    def sign(self, data):
        return self.signing.sign(data)

    @staticmethod
    def verify(public, data, signature):
        try:
            Ed25519PublicKey.from_public_bytes(public[:32]).verify(signature, data)
        except InvalidSignature as exc:
            raise CryptoError("bad signature") from exc

    @staticmethod
    def dh_public(public):
        return X25519PublicKey.from_public_bytes(public[32:64])


class PreKeys:
    """A device's signed prekey and one-time prekeys (private halves)."""

    def __init__(self, identity, count, spk_id=1):
        self.spk_id = spk_id
        self.spk = X25519PrivateKey.generate()
        self.signature = identity.sign(raw(self.spk.public_key()))
        self.one_time = {}
        self.next_id = 1
        self.add(count)

    def add(self, count):
        new = {}
        for _ in range(count):
            new[self.next_id] = X25519PrivateKey.generate()
            self.next_id += 1
        self.one_time.update(new)
        return {key_id: raw(key.public_key()) for key_id, key in new.items()}


def x3dh_initiate(identity, bundle):
    """Sender side. `bundle` is a dict with identity, spk_id, spk, signature,
    and optional opk_id/opk. Returns (shared key, associated data, header)."""
    Identity.verify(bundle["identity"], bundle["spk"], bundle["signature"])
    ephemeral = X25519PrivateKey.generate()
    spk = X25519PublicKey.from_public_bytes(bundle["spk"])
    parts = [
        identity.dh.exchange(spk),
        ephemeral.exchange(Identity.dh_public(bundle["identity"])),
        ephemeral.exchange(spk),
    ]
    opk_id = NO_OPK
    if bundle.get("opk") is not None:
        parts.append(ephemeral.exchange(X25519PublicKey.from_public_bytes(bundle["opk"])))
        opk_id = bundle["opk_id"]
    shared = hkdf(b"\xff" * 32 + b"".join(parts), b"\0" * 32, b"ircd-e2ee X3DH", 32)
    associated = identity.public + bundle["identity"]
    header = identity.public + raw(ephemeral.public_key()) + struct.pack(">II", bundle["spk_id"], opk_id)
    return shared, associated, header


def x3dh_respond(identity, prekeys, header):
    """Receiver side: the shared key and associated data from a prekey header.
    `consume_opk(opk_id)` removes the one-time prekey after the first message
    decrypts, so an invalid message does not burn the prekey."""
    if len(header) != 104:
        raise CryptoError("invalid prekey header")
    their_identity, ephemeral = header[:64], header[64:96]
    spk_id, opk_id = struct.unpack(">II", header[96:104])
    if spk_id != prekeys.spk_id:
        raise CryptoError("unknown signed prekey")
    ephemeral = X25519PublicKey.from_public_bytes(ephemeral)
    parts = [
        prekeys.spk.exchange(Identity.dh_public(their_identity)),
        identity.dh.exchange(ephemeral),
        prekeys.spk.exchange(ephemeral),
    ]
    if opk_id != NO_OPK:
        opk = prekeys.one_time.get(opk_id)
        if opk is None:
            raise CryptoError("one-time prekey already used")
        parts.append(opk.exchange(ephemeral))
    shared = hkdf(b"\xff" * 32 + b"".join(parts), b"\0" * 32, b"ircd-e2ee X3DH", 32)
    return shared, their_identity + identity.public, their_identity, opk_id


class DoubleRatchet:
    """One pairwise session. Decryption leaves the state unchanged on failure."""

    def __init__(self, shared, associated):
        self.ad = associated
        self.root = shared
        self.dh_self = None
        self.dh_remote = None
        self.send_chain = None
        self.recv_chain = None
        self.ns = self.nr = self.pn = 0
        self.skipped = {}

    @classmethod
    def initiator(cls, shared, associated, remote_spk):
        state = cls(shared, associated)
        state.dh_self = X25519PrivateKey.generate()
        state.dh_remote = X25519PublicKey.from_public_bytes(remote_spk)
        state.root, state.send_chain = state._kdf_root(state.dh_self.exchange(state.dh_remote))
        return state

    @classmethod
    def responder(cls, shared, associated, spk_private):
        state = cls(shared, associated)
        state.dh_self = spk_private
        return state

    def _kdf_root(self, dh_out):
        out = hkdf(dh_out, self.root, b"ircd-e2ee ratchet", 64)
        return out[:32], out[32:]

    def encrypt(self, plaintext):
        self.send_chain, key = kdf_chain(self.send_chain)
        header = raw(self.dh_self.public_key()) + struct.pack(">II", self.pn, self.ns)
        self.ns += 1
        return header + aead_encrypt(key, plaintext, self.ad + header)

    def decrypt(self, message):
        saved = copy.copy(self.__dict__)
        saved["skipped"] = dict(self.skipped)
        try:
            return self._decrypt(message)
        except Exception:
            self.__dict__.update(saved)
            raise

    def _decrypt(self, message):
        if len(message) < 40 + 16:
            raise CryptoError("short message")
        header, ciphertext = message[:40], message[40:]
        dh, (pn, n) = header[:32], struct.unpack(">II", header[32:40])
        key = self.skipped.pop((dh, n), None)
        if key is not None:
            return aead_decrypt(key, ciphertext, self.ad + header)
        if self.dh_remote is None or dh != raw(self.dh_remote):
            self._skip(pn)
            self._dh_step(dh)
        self._skip(n)
        self.recv_chain, key = kdf_chain(self.recv_chain)
        self.nr += 1
        return aead_decrypt(key, ciphertext, self.ad + header)

    def _skip(self, until):
        if self.recv_chain is None:
            if until != 0:
                raise CryptoError("cannot skip before first DH step")
            return
        if until < self.nr or len(self.skipped) + (until - self.nr) > MAX_SKIP:
            raise CryptoError("too many skipped messages")
        while self.nr < until:
            self.recv_chain, key = kdf_chain(self.recv_chain)
            self.skipped[(raw(self.dh_remote), self.nr)] = key
            self.nr += 1

    def _dh_step(self, dh):
        self.pn, self.ns, self.nr = self.ns, 0, 0
        self.dh_remote = X25519PublicKey.from_public_bytes(dh)
        self.root, self.recv_chain = self._kdf_root(self.dh_self.exchange(self.dh_remote))
        self.dh_self = X25519PrivateKey.generate()
        self.root, self.send_chain = self._kdf_root(self.dh_self.exchange(self.dh_remote))


def prekey_envelope(header, ratchet_message):
    return bytes([VERSION, PREKEY]) + header + ratchet_message


def message_envelope(ratchet_message):
    return bytes([VERSION, MESSAGE]) + ratchet_message


def parse_envelope(data):
    """('prekey', header, ratchet) or ('msg', None, ratchet)."""
    if len(data) < 2 or data[0] != VERSION:
        raise CryptoError("unknown envelope version")
    if data[1] == PREKEY:
        if len(data) < 2 + 104 + 56:
            raise CryptoError("short prekey envelope")
        return "prekey", data[2:106], data[106:]
    if data[1] == MESSAGE:
        if len(data) < 2 + 56:
            raise CryptoError("short message envelope")
        return "msg", None, data[2:]
    raise CryptoError("unknown envelope type")


class SenderKey:
    """A channel sender key: a hash ratchet and an Ed25519 signing key. The
    owner holds the private key; members hold the public key."""

    def __init__(self, key_id, chain, iteration, signing_public, signing_private=None):
        self.key_id = key_id
        self.chain = chain
        self.iteration = iteration
        self.signing_public = signing_public
        self.signing_private = signing_private
        self.skipped = {}

    @classmethod
    def create(cls):
        signing = Ed25519PrivateKey.generate()
        key_id = int.from_bytes(os.urandom(4), "big") & 0x7FFFFFFF
        return cls(key_id, os.urandom(32), 0, raw(signing.public_key()), signing)

    def distribution(self):
        """What members need: id, current chain and iteration, verification key."""
        return {
            "key_id": self.key_id,
            "chain": self.chain.hex(),
            "iteration": self.iteration,
            "signing": self.signing_public.hex(),
        }

    @classmethod
    def from_distribution(cls, data):
        return cls(
            data["key_id"], bytes.fromhex(data["chain"]), data["iteration"], bytes.fromhex(data["signing"])
        )

    def encrypt(self, plaintext, channel):
        self.chain, key = kdf_chain(self.chain)
        header = bytes([VERSION, CHANNEL]) + struct.pack(">II", self.key_id, self.iteration)
        self.iteration += 1
        body = header + aead_encrypt(key, plaintext, channel.encode() + header)
        return body + self.signing_private.sign(body)

    def decrypt(self, data, channel):
        if len(data) < 10 + 16 + 64:
            raise CryptoError("short channel message")
        body, signature = data[:-64], data[-64:]
        try:
            Ed25519PublicKey.from_public_bytes(self.signing_public).verify(signature, body)
        except InvalidSignature as exc:
            raise CryptoError("bad channel signature") from exc
        header = body[:10]
        if header[0] != VERSION or header[1] != CHANNEL:
            raise CryptoError("unknown channel envelope")
        key_id, iteration = struct.unpack(">II", header[2:10])
        if key_id != self.key_id:
            raise CryptoError("unknown sender key")
        saved_chain, saved_iter, saved_skipped = self.chain, self.iteration, dict(self.skipped)
        try:
            key = self.skipped.pop(iteration, None)
            if key is None:
                if (
                    iteration < self.iteration
                    or len(self.skipped) + (iteration - self.iteration) > MAX_SKIP
                ):
                    raise CryptoError("old or too distant channel message")
                while self.iteration < iteration:
                    self.chain, skipped = kdf_chain(self.chain)
                    self.skipped[self.iteration] = skipped
                    self.iteration += 1
                self.chain, key = kdf_chain(self.chain)
                self.iteration += 1
            return aead_decrypt(key, body[10:], channel.encode() + header)
        except Exception:
            self.chain, self.iteration, self.skipped = saved_chain, saved_iter, saved_skipped
            raise


def channel_key_id(data):
    if len(data) < 10 or data[0] != VERSION or data[1] != CHANNEL:
        raise CryptoError("not a channel message")
    return struct.unpack(">I", data[2:6])[0]
