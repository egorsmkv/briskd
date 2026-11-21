"""End-to-end tests for the briskd E2EE broker with real Signal-style clients.

Two linked servers (`hub` and `leaf`, see docker-compose.yml) and Python
devices that do X3DH, the Double Ratchet, and Sender Keys. The servers only
ever see public keys and ciphertext.

Run: test/e2ee/run   (or set E2EE_HUB / E2EE_LEAF to host:port and run pytest)
"""

import base64
import os
import time

import pytest

from device import CAP, Device, IdentityChanged, ServerError, unique
from e2ee_crypto import (
    CryptoError,
    DoubleRatchet,
    Identity,
    PreKeys,
    SenderKey,
    raw,
    x3dh_initiate,
    x3dh_respond,
)
from irc import Connection


def endpoint(name, default):
    host, port = os.environ.get(name, default).rsplit(":", 1)
    return host, int(port)


HUB = endpoint("E2EE_HUB", "127.0.0.1:6667")
LEAF = endpoint("E2EE_LEAF", "127.0.0.1:6668")
PASSWORD = "correct-horse-battery"


# --- Crypto, no server ---------------------------------------------------


def session_pair():
    alice, bob = Identity(), Identity()
    prekeys = PreKeys(bob, 2)
    bundle = {
        "identity": bob.public,
        "spk_id": prekeys.spk_id,
        "spk": raw(prekeys.spk.public_key()),
        "signature": prekeys.signature,
        "opk_id": 1,
        "opk": raw(prekeys.one_time[1].public_key()),
    }
    shared, ad, header = x3dh_initiate(alice, bundle)
    sender = DoubleRatchet.initiator(shared, ad, bundle["spk"])
    shared2, ad2, their, opk_id = x3dh_respond(bob, prekeys, header)
    prekeys.one_time.pop(opk_id, None)
    assert (shared2, ad2, their, opk_id) == (shared, ad, alice.public, 1)
    return sender, DoubleRatchet.responder(shared2, ad2, prekeys.spk)


def test_ratchet_round_trip_and_out_of_order():
    a, b = session_pair()
    first = [a.encrypt(f"m{i}".encode()) for i in range(3)]
    assert b.decrypt(first[2]) == b"m2"  # skipped keys for m0, m1
    assert b.decrypt(first[0]) == b"m0"
    reply = b.encrypt(b"pong")  # DH ratchet step
    assert a.decrypt(reply) == b"pong"
    assert b.decrypt(first[1]) == b"m1"
    late = a.encrypt(b"after")
    assert b.decrypt(late) == b"after"


def test_ratchet_rejects_tampering_and_replay():
    a, b = session_pair()
    msg = a.encrypt(b"secret")
    tampered = msg[:-1] + bytes([msg[-1] ^ 1])
    with pytest.raises(CryptoError):
        b.decrypt(tampered)
    assert b.decrypt(msg) == b"secret"  # the failed attempt left the state intact
    with pytest.raises(CryptoError):
        b.decrypt(msg)  # message keys are used once


def test_x3dh_rejects_forged_signed_prekey():
    bob, mallory = Identity(), Identity()
    prekeys = PreKeys(bob, 1)
    bundle = {
        "identity": bob.public,
        "spk_id": 1,
        "spk": raw(prekeys.spk.public_key()),
        "signature": mallory.sign(raw(prekeys.spk.public_key())),
    }
    with pytest.raises(CryptoError):
        x3dh_initiate(Identity(), bundle)


def test_sender_key_order_and_forward_secrecy():
    own = SenderKey.create()
    member = SenderKey.from_distribution(own.distribution())
    messages = [own.encrypt(f"c{i}".encode(), "#x") for i in range(3)]
    assert member.decrypt(messages[1], "#x") == b"c1"
    assert member.decrypt(messages[0], "#x") == b"c0"
    with pytest.raises(CryptoError):
        member.decrypt(messages[0], "#x")  # used once
    # A member who joins later cannot read what was sent before.
    late = SenderKey.from_distribution(own.distribution())
    with pytest.raises(CryptoError):
        late.decrypt(messages[2], "#x")
    with pytest.raises(CryptoError):
        member.decrypt(messages[2], "#other")  # bound to the channel


# --- Live servers ----------------------------------------------------------


@pytest.fixture(scope="session", autouse=True)
def linked():
    """Wait until hub and leaf are linked."""
    conn = Connection(*HUB)
    conn.send("NICK probe" + os.urandom(2).hex())
    conn.send("USER p 0 * :probe")
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        conn.send("LINKS")
        msg = conn.read(2)
        seen = ""
        while msg is not None and msg.command != "365":
            seen += msg.raw + "\n"
            msg = conn.read(2)
        if "leaf.test" in seen:
            conn.close()
            return
        time.sleep(1)
    pytest.fail("hub and leaf never linked")


def device(where, name, dev, nick=None, register=False, prekeys=20):
    d = Device(*where, nick or name, name, PASSWORD, dev, register=register, prekeys=prekeys)
    return d


def new_account(where, role, dev):
    name = unique(role)
    d = device(where, name, dev, register=True)
    d.publish()
    return name, d


def test_capability_advertised_with_limits():
    for where in (HUB, LEAF):
        conn = Connection(*where)
        conn.send("CAP LS 302")
        caps = ""
        while (msg := conn.read(3)) is not None:
            caps += msg.raw
            if msg.command == "CAP" and msg.params[2:3] != ["*"]:
                break
        assert f"{CAP}=v=1,max-devices=" in caps
        conn.close()


def test_direct_messages_on_one_server():
    alice_name, alice = new_account(HUB, "alice", 101)
    bob_name, bob = new_account(HUB, "bob", 201)
    alice.bind()
    bob.bind()
    bob.send_text(alice_name, alice_name, "hello alice")
    assert alice.wait_text("hello alice")["from"] == bob_name
    alice.send_text(bob_name, bob_name, "hi bob")
    bob.wait_text("hi bob")
    for i in range(5):  # several ratchet steps both ways
        bob.send_text(alice_name, alice_name, f"b{i}")
        alice.wait_text(f"b{i}")
        alice.send_text(bob_name, bob_name, f"a{i}")
        bob.wait_text(f"a{i}")
    # The ciphertext on the wire never contains the plaintext.
    wire = [m.raw for m in alice.conn.log if m.command == "PRIVMSG"]
    assert wire and not any("hello alice" in line for line in wire)
    assert alice.errors == [] and bob.errors == []
    alice.close()
    bob.close()


def test_offline_queue_and_ack():
    alice_name, alice = new_account(HUB, "alice", 102)
    alice.close()
    bob_name, bob = new_account(HUB, "bob", 202)
    bob.send_text(alice_name, alice_name, "while you were out 1")
    bob.send_text(alice_name, alice_name, "while you were out 2")
    bob.sync()
    queued = [m for m in bob.conn.log if m.command == "E2EE" and m.params[0] == "QUEUED"]
    assert len(queued) == 2
    # Alice comes back with the same device keys.
    back = device(HUB, alice_name, 102)
    back.identity, back.prekeys = alice.identity, alice.prekeys
    assert back.bind() == 2
    assert [m["text"] for m in back.inbox] == ["while you were out 1", "while you were out 2"]
    assert all(m["queued"] for m in back.inbox)
    # Acknowledged: nothing is replayed again.
    assert back.bind() == 0
    back.close()
    bob.close()


def test_long_message_as_multiline_while_offline():
    alice_name, alice = new_account(HUB, "alice", 103)
    alice.close()
    bob_name, bob = new_account(HUB, "bob", 203)
    long_text = "x" * 2000 + " end"
    bob.send_text(alice_name, alice_name, long_text)
    bob.sync()
    assert not bob.fails, bob.fails
    back = device(HUB, alice_name, 103)
    back.identity, back.prekeys = alice.identity, alice.prekeys
    assert back.bind() == 1
    assert back.inbox[0]["text"] == long_text
    back.close()
    bob.close()


def test_two_devices_of_one_account():
    alice_name, phone = new_account(HUB, "alice", 104)
    laptop = device(HUB, alice_name, 105, nick=alice_name + "_2")
    laptop.publish()
    phone.bind()
    laptop.bind()
    bob_name, bob = new_account(HUB, "bob", 204)
    bob.send_text(alice_name, alice_name, "to both")
    phone.wait_text("to both")
    laptop.wait_text("to both")  # delivered to the second nickname too
    # The laptop goes offline: its copy is queued, the phone still reads live.
    laptop.close()
    time.sleep(0.5)
    bob.send_text(alice_name, alice_name, "laptop is away")
    phone.wait_text("laptop is away")
    again = device(HUB, alice_name, 105, nick=alice_name + "_2")
    again.identity, again.prekeys = laptop.identity, laptop.prekeys
    again.sessions, again.trusted = laptop.sessions, laptop.trusted
    assert again.bind() == 1
    assert again.inbox[0]["text"] == "laptop is away"
    for d in (phone, again, bob):
        d.close()


def retry(action, attempts=40, delay=0.25):
    for _ in range(attempts - 1):
        try:
            return action()
        except ServerError:
            time.sleep(delay)
    return action()


def test_bundles_and_queue_replicated_across_the_link():
    alice_name, alice = new_account(HUB, "alice", 106)
    alice.close()
    carol_name, carol = new_account(LEAF, "carol", 306)
    # Carol, on the leaf, fetches Alice's bundle published on the hub.
    retry(lambda: carol.fetch(alice_name))
    carol.sessions.clear()
    carol.awaiting_reply.clear()
    carol.trusted.clear()
    carol.send_text(alice_name, alice_name, "across the link")
    carol.sync()
    assert any(m.command == "E2EE" and m.params[0] == "QUEUED" for m in carol.conn.log)
    # Alice binds on the leaf: the queue was replicated there too.
    time.sleep(0.5)
    on_leaf = device(LEAF, alice_name, 106)
    on_leaf.identity, on_leaf.prekeys = alice.identity, alice.prekeys
    assert on_leaf.bind() == 1
    assert on_leaf.inbox[0]["text"] == "across the link"
    on_leaf.close()
    # The ACK reached the hub: nothing left to replay there.
    time.sleep(0.5)
    on_hub = device(HUB, alice_name, 106)
    on_hub.identity, on_hub.prekeys = alice.identity, alice.prekeys
    assert on_hub.bind() == 0
    # Live delivery across the link once both are bound.
    on_hub.send_text(carol_name, carol_name, "hello from the hub")
    carol.bind()
    carol.wait_text("hello from the hub")
    on_hub.close()
    carol.close()


def test_channel_sender_keys_and_rotation():
    channel = "#" + unique("secret")
    alice_name, alice = new_account(HUB, "alice", 107)
    bob_name, bob = new_account(HUB, "bob", 207)
    carol_name, carol = new_account(LEAF, "carol", 307)
    for d in (alice, bob, carol):
        d.bind()
        d.join(channel)
    time.sleep(0.5)
    for d in (alice, bob, carol):
        d.share_sender_key(channel)
    alice.send_channel(channel, "hello channel")
    bob.wait_text("hello channel")
    carol.wait_text("hello channel")
    carol.send_channel(channel, "from the leaf")
    alice.wait_text("from the leaf")
    bob.wait_text("from the leaf")
    # Carol leaves: Alice rotates and hands the new key only to Bob.
    carol.conn.send(f"PART {channel}")
    carol.sync()
    time.sleep(0.5)
    old_state = carol.received_keys[(channel, alice_name, 107)]
    alice.share_sender_key(channel, rotate=True)
    alice.send_channel(channel, "after rotation")
    bob.wait_text("after rotation")
    rotated = [
        base64.b64decode(m.params[-1])
        for m in bob.conn.log
        if m.command == "PRIVMSG" and m.params[0] == channel and m.nick == alice_name
    ][-1]
    with pytest.raises(CryptoError):
        old_state.decrypt(rotated, channel)
    for d in (alice, bob, carol):
        d.close()


def test_tofu_detects_a_changed_identity_key():
    alice_name, alice = new_account(HUB, "alice", 108)
    bob_name, bob = new_account(HUB, "bob", 208)
    bob.fetch(alice_name)
    # Someone republishes device 108 with other keys (for example after
    # taking over the account): Bob's pinned identity no longer matches.
    alice.identity = Identity()
    alice.prekeys = PreKeys(alice.identity, 5)
    alice.publish()
    with pytest.raises(IdentityChanged):
        bob.fetch(alice_name)
    alice.close()
    bob.close()


def test_server_refuses_keys_without_an_account():
    conn = Connection(*HUB)
    conn.send(f"CAP REQ :message-tags {CAP}")
    conn.send("CAP END")
    nick = unique("anon")
    conn.send(f"NICK {nick}")
    conn.send("USER a 0 * :a")
    conn.send("E2EE PUBLISH 1 AAAA 1:AAAA AAAA")
    seen = ""
    while (msg := conn.read(3)) is not None:
        seen += msg.raw + "\n"
        if msg.command == "FAIL":
            break
    assert "FAIL E2EE ACCOUNT_REQUIRED" in seen
    conn.close()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
