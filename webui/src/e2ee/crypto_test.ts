/// <reference lib="deno.ns" />
import {
  CryptoError,
  DoubleRatchet,
  Identity,
  messageEnvelope,
  NO_OPK,
  parseEnvelope,
  PreKeys,
  prekeyEnvelope,
  safetyNumber,
  SenderKey,
  x3dhInitiate,
  x3dhRespond,
} from "./crypto.ts";

const enc = new TextEncoder();
const dec = new TextDecoder();

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("X3DH + Double Ratchet roundtrip with OPK, out-of-order, and serialization", () => {
  const aliceId = new Identity();
  const bobId = new Identity();
  const bobPre = new PreKeys(bobId, 5);
  const firstOpkEntry = Array.from(bobPre.oneTime.entries())[0];

  const bundle = {
    account: "bob",
    device: 2,
    identity: bobId.publicKey,
    spkId: bobPre.spkId,
    spk: bobPre.spk.publicKey,
    signature: bobPre.signature,
    opkId: firstOpkEntry[0],
    opk: firstOpkEntry[1].publicKey,
  };

  const init = x3dhInitiate(aliceId, bundle);
  const aliceRatchet = DoubleRatchet.initiator(init.shared, init.ad, bundle.spk);

  // Alice sends 2 messages before Bob replies (test out-of-order delivery)
  const env1 = prekeyEnvelope(init.header, aliceRatchet.encrypt(enc.encode("hello bob 1")));
  const env2 = prekeyEnvelope(init.header, aliceRatchet.encrypt(enc.encode("hello bob 2")));

  // Bob receives message 2 first!
  const parsed2 = parseEnvelope(env2);
  assert(parsed2.kind === "prekey", "expected prekey envelope");
  const resp = x3dhRespond(bobId, bobPre, parsed2.header!);
  assert(resp.opkId === firstOpkEntry[0], "opkId should match");
  const bobRatchet = DoubleRatchet.responder(resp.shared, resp.ad, bobPre.spk);
  const pt2 = dec.decode(bobRatchet.decrypt(parsed2.ratchet));
  assert(pt2 === "hello bob 2", `unexpected pt2: ${pt2}`);

  // Now Bob receives message 1 (skipped key)
  const parsed1 = parseEnvelope(env1);
  const pt1 = dec.decode(bobRatchet.decrypt(parsed1.ratchet));
  assert(pt1 === "hello bob 1", `unexpected pt1: ${pt1}`);

  // Bob replies to Alice (triggers DH ratchet step)
  const env3 = messageEnvelope(bobRatchet.encrypt(enc.encode("hi alice!")));
  const parsed3 = parseEnvelope(env3);
  assert(parsed3.kind === "msg", "expected msg envelope");
  const pt3 = dec.decode(aliceRatchet.decrypt(parsed3.ratchet));
  assert(pt3 === "hi alice!", `unexpected pt3: ${pt3}`);

  // Corrupt ciphertext must fail and NOT corrupt ratchet state
  const bad = new Uint8Array(parsed3.ratchet);
  bad[bad.length - 1] ^= 0xff;
  let failed = false;
  try {
    aliceRatchet.decrypt(bad);
  } catch (e) {
    failed = e instanceof CryptoError;
  }
  assert(failed, "expected CryptoError on tampered message");

  // Serialize & deserialize ratchet, then continue conversing
  const aliceRestored = DoubleRatchet.fromJSON(aliceRatchet.toJSON());
  const bobRestored = DoubleRatchet.fromJSON(bobRatchet.toJSON());
  const env4 = messageEnvelope(aliceRestored.encrypt(enc.encode("after reload")));
  const parsed4 = parseEnvelope(env4);
  assert(dec.decode(bobRestored.decrypt(parsed4.ratchet)) === "after reload", "reload failed");
});

Deno.test("X3DH without OPK", () => {
  const aliceId = new Identity();
  const bobId = new Identity();
  const bobPre = new PreKeys(bobId, 0);
  const bundle = {
    account: "bob",
    device: 2,
    identity: bobId.publicKey,
    spkId: bobPre.spkId,
    spk: bobPre.spk.publicKey,
    signature: bobPre.signature,
    opkId: null,
    opk: null,
  };
  const init = x3dhInitiate(aliceId, bundle);
  const resp = x3dhRespond(bobId, bobPre, init.header);
  assert(resp.opkId === NO_OPK, "expected NO_OPK");
  const a = DoubleRatchet.initiator(init.shared, init.ad, bundle.spk);
  const b = DoubleRatchet.responder(resp.shared, resp.ad, bobPre.spk);
  const ct = a.encrypt(enc.encode("no-opk"));
  assert(dec.decode(b.decrypt(ct)) === "no-opk", "no-opk roundtrip failed");
});

Deno.test("SenderKey channel encryption, out-of-order, and serialization", () => {
  const sender = SenderKey.create();
  const receiver = SenderKey.fromDistribution(sender.distribution("#secret"));

  const c1 = sender.encrypt(enc.encode("msg 1"), "#secret");
  const c2 = sender.encrypt(enc.encode("msg 2"), "#secret");

  // Receive out of order
  assert(dec.decode(receiver.decrypt(c2, "#secret")) === "msg 2", "channel msg 2 failed");
  assert(dec.decode(receiver.decrypt(c1, "#secret")) === "msg 1", "channel msg 1 failed");

  // Wrong channel AD must fail
  let failed = false;
  try {
    const c3 = sender.encrypt(enc.encode("msg 3"), "#secret");
    receiver.decrypt(c3, "#other");
  } catch (e) {
    failed = e instanceof CryptoError;
  }
  assert(failed, "wrong channel should fail");

  // Serialization
  const sender2 = SenderKey.fromJSON(sender.toJSON());
  const receiver2 = SenderKey.fromJSON(receiver.toJSON());
  const c4 = sender2.encrypt(enc.encode("after reload"), "#secret");
  assert(dec.decode(receiver2.decrypt(c4, "#secret")) === "after reload", "sk reload failed");
});

Deno.test("Safety number is symmetric", () => {
  const a = new Identity();
  const b = new Identity();
  assert(
    safetyNumber(a.publicKey, b.publicKey) === safetyNumber(b.publicKey, a.publicKey),
    "safety number must be symmetric",
  );
});
