import nacl from "tweetnacl";
import { sha256 } from "@noble/hashes/sha256";
import { hmac } from "@noble/hashes/hmac";
import { hkdf } from "@noble/hashes/hkdf";
import { pbkdf2 } from "@noble/hashes/pbkdf2";
import { gcm } from "@noble/ciphers/aes";

export const VERSION = 1;
export const PREKEY = 1;
export const MESSAGE = 2;
export const CHANNEL = 3;
export const NO_OPK = 0xffffffff;
export const MAX_SKIP = 1000;

const enc = new TextEncoder();
const ZEROS_32 = new Uint8Array(32);
const FF_32 = new Uint8Array(32).fill(0xff);
const INFO_MSG = enc.encode("ircd-e2ee message keys");
const INFO_X3DH = enc.encode("ircd-e2ee X3DH");
const INFO_RATCHET = enc.encode("ircd-e2ee ratchet");
const BYTE_01 = new Uint8Array([0x01]);
const BYTE_02 = new Uint8Array([0x02]);

export class CryptoError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CryptoError";
  }
}

export interface KeyPair {
  publicKey: Uint8Array;
  secretKey: Uint8Array;
}

export interface PreKeyBundle {
  account: string;
  device: number;
  identity: Uint8Array;
  spkId: number;
  spk: Uint8Array;
  signature: Uint8Array;
  opkId: number | null;
  opk: Uint8Array | null;
}

export interface SenderKeyDistribution {
  key_id: number;
  chain: string;
  iteration: number;
  signing: string;
  channel?: string;
}

export function concatBytes(...parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export function toB64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

export function fromB64(text: string): Uint8Array {
  const bin = atob(text.trim());
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function toHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}

export function fromHex(hex: string): Uint8Array {
  if (
    typeof hex !== "string" || hex.length % 2 !== 0 ||
    !/^[0-9a-fA-F]*$/.test(hex)
  ) {
    throw new CryptoError("invalid hex");
  }
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function dhExchange(secretKey: Uint8Array, publicKey: Uint8Array): Uint8Array {
  if (secretKey.length !== 32 || publicKey.length !== 32) {
    throw new CryptoError("invalid X25519 key length");
  }
  const shared = nacl.scalarMult(secretKey, publicKey);
  let acc = 0;
  for (let i = 0; i < shared.length; i++) acc |= shared[i];
  if (acc === 0) throw new CryptoError("low-order X25519 public key");
  return shared;
}

function compareBytes(a: Uint8Array, b: Uint8Array): number {
  const len = Math.min(a.length, b.length);
  for (let i = 0; i < len; i++) {
    if (a[i] !== b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

function u32be(n: number): Uint8Array {
  const b = new Uint8Array(4);
  const v = new DataView(b.buffer);
  v.setUint32(0, n >>> 0, false);
  return b;
}

function readU32be(bytes: Uint8Array, offset: number): number {
  const v = new DataView(bytes.buffer, bytes.byteOffset + offset, 4);
  return v.getUint32(0, false);
}

export function randomBytes(len: number): Uint8Array {
  return nacl.randomBytes(len);
}

export function randomDeviceId(): number {
  const b = randomBytes(4);
  const n = (readU32be(b, 0) & 0x7fffffff) || 1;
  return n;
}

function deriveHkdf(
  ikm: Uint8Array,
  salt: Uint8Array,
  info: Uint8Array,
  length: number,
): Uint8Array {
  return hkdf(sha256, ikm, salt, info, length);
}

export function aeadEncrypt(
  messageKey: Uint8Array,
  plaintext: Uint8Array,
  ad: Uint8Array,
): Uint8Array {
  const material = deriveHkdf(messageKey, ZEROS_32, INFO_MSG, 44);
  const key = material.subarray(0, 32);
  const iv = material.subarray(32, 44);
  return gcm(key, iv, ad).encrypt(plaintext);
}

export function aeadDecrypt(
  messageKey: Uint8Array,
  ciphertext: Uint8Array,
  ad: Uint8Array,
): Uint8Array {
  const material = deriveHkdf(messageKey, ZEROS_32, INFO_MSG, 44);
  const key = material.subarray(0, 32);
  const iv = material.subarray(32, 44);
  try {
    return gcm(key, iv, ad).decrypt(ciphertext);
  } catch {
    throw new CryptoError("authentication failed");
  }
}

export function kdfChain(chainKey: Uint8Array): [Uint8Array, Uint8Array] {
  return [hmac(sha256, chainKey, BYTE_02), hmac(sha256, chainKey, BYTE_01)];
}

export interface SerializedIdentity {
  signingPub: string;
  signingSec: string;
  dhPub: string;
  dhSec: string;
}

export class Identity {
  readonly signing: KeyPair;
  readonly dh: KeyPair;

  constructor(signing?: KeyPair, dh?: KeyPair) {
    this.signing = signing ?? nacl.sign.keyPair();
    this.dh = dh ?? nacl.box.keyPair();
  }

  get publicKey(): Uint8Array {
    return concatBytes(this.signing.publicKey, this.dh.publicKey);
  }

  sign(data: Uint8Array): Uint8Array {
    return nacl.sign.detached(data, this.signing.secretKey);
  }

  static verify(
    pub64: Uint8Array,
    data: Uint8Array,
    signature: Uint8Array,
  ): void {
    if (pub64.length !== 64 || signature.length !== 64) {
      throw new CryptoError("invalid key or signature length");
    }
    const ok = nacl.sign.detached.verify(
      data,
      signature,
      pub64.subarray(0, 32),
    );
    if (!ok) throw new CryptoError("bad signature");
  }

  static dhPublic(pub64: Uint8Array): Uint8Array {
    if (pub64.length !== 64) {
      throw new CryptoError("invalid identity key length");
    }
    return pub64.subarray(32, 64);
  }

  toJSON(): SerializedIdentity {
    return {
      signingPub: toB64(this.signing.publicKey),
      signingSec: toB64(this.signing.secretKey),
      dhPub: toB64(this.dh.publicKey),
      dhSec: toB64(this.dh.secretKey),
    };
  }

  static fromJSON(d: SerializedIdentity): Identity {
    return new Identity(
      { publicKey: fromB64(d.signingPub), secretKey: fromB64(d.signingSec) },
      { publicKey: fromB64(d.dhPub), secretKey: fromB64(d.dhSec) },
    );
  }
}

export interface SerializedPreKeys {
  spkId: number;
  spkPub: string;
  spkSec: string;
  signature: string;
  nextId: number;
  oneTime: Array<[number, string, string]>;
}

export class PreKeys {
  spkId: number;
  spk: KeyPair;
  signature: Uint8Array;
  oneTime: Map<number, KeyPair>;
  nextId: number;

  constructor(identity: Identity, count: number, spkId = 1) {
    this.spkId = spkId;
    this.spk = nacl.box.keyPair();
    this.signature = identity.sign(this.spk.publicKey);
    this.oneTime = new Map();
    this.nextId = 1;
    if (count > 0) this.add(count);
  }

  add(count: number): Map<number, Uint8Array> {
    const added = new Map<number, Uint8Array>();
    for (let i = 0; i < count; i++) {
      const kp = nacl.box.keyPair();
      const id = this.nextId++;
      this.oneTime.set(id, kp);
      added.set(id, kp.publicKey);
    }
    return added;
  }

  toJSON(): SerializedPreKeys {
    const ot: Array<[number, string, string]> = [];
    this.oneTime.forEach((kp, id) => {
      ot.push([id, toB64(kp.publicKey), toB64(kp.secretKey)]);
    });
    return {
      spkId: this.spkId,
      spkPub: toB64(this.spk.publicKey),
      spkSec: toB64(this.spk.secretKey),
      signature: toB64(this.signature),
      nextId: this.nextId,
      oneTime: ot,
    };
  }

  static fromJSON(d: SerializedPreKeys): PreKeys {
    const pk = Object.create(PreKeys.prototype) as PreKeys;
    pk.spkId = d.spkId;
    pk.spk = { publicKey: fromB64(d.spkPub), secretKey: fromB64(d.spkSec) };
    pk.signature = fromB64(d.signature);
    pk.nextId = d.nextId;
    pk.oneTime = new Map();
    for (const [id, pub, sec] of d.oneTime) {
      pk.oneTime.set(id, { publicKey: fromB64(pub), secretKey: fromB64(sec) });
    }
    return pk;
  }
}

export function x3dhInitiate(
  identity: Identity,
  bundle: PreKeyBundle,
): { shared: Uint8Array; ad: Uint8Array; header: Uint8Array } {
  if (
    bundle.identity.length !== 64 || bundle.spk.length !== 32 ||
    bundle.signature.length !== 64
  ) {
    throw new CryptoError("invalid prekey bundle key length");
  }
  if (bundle.opk !== null && bundle.opk.length !== 32) {
    throw new CryptoError("invalid one-time prekey length");
  }
  Identity.verify(bundle.identity, bundle.spk, bundle.signature);
  const ephemeral = nacl.box.keyPair();
  const parts: Uint8Array[] = [
    dhExchange(identity.dh.secretKey, bundle.spk),
    dhExchange(ephemeral.secretKey, Identity.dhPublic(bundle.identity)),
    dhExchange(ephemeral.secretKey, bundle.spk),
  ];
  let opkId = NO_OPK;
  if (bundle.opk !== null && bundle.opkId !== null) {
    parts.push(dhExchange(ephemeral.secretKey, bundle.opk));
    opkId = bundle.opkId;
  }
  const shared = deriveHkdf(
    concatBytes(FF_32, ...parts),
    ZEROS_32,
    INFO_X3DH,
    32,
  );
  const ad = concatBytes(identity.publicKey, bundle.identity);
  const header = concatBytes(
    identity.publicKey,
    ephemeral.publicKey,
    u32be(bundle.spkId),
    u32be(opkId),
  );
  return { shared, ad, header };
}

export function x3dhRespond(
  identity: Identity,
  prekeys: PreKeys,
  header: Uint8Array,
): {
  shared: Uint8Array;
  ad: Uint8Array;
  theirIdentity: Uint8Array;
  opkId: number;
} {
  if (header.length !== 104) throw new CryptoError("invalid prekey header");
  const theirIdentity = header.subarray(0, 64);
  const ephemeral = header.subarray(64, 96);
  const spkId = readU32be(header, 96);
  const opkId = readU32be(header, 100);
  if (spkId !== prekeys.spkId) throw new CryptoError("unknown signed prekey");
  const parts: Uint8Array[] = [
    dhExchange(prekeys.spk.secretKey, Identity.dhPublic(theirIdentity)),
    dhExchange(identity.dh.secretKey, ephemeral),
    dhExchange(prekeys.spk.secretKey, ephemeral),
  ];
  if (opkId !== NO_OPK) {
    const opk = prekeys.oneTime.get(opkId);
    if (!opk) throw new CryptoError("one-time prekey already used");
    parts.push(dhExchange(opk.secretKey, ephemeral));
  }
  const shared = deriveHkdf(
    concatBytes(FF_32, ...parts),
    ZEROS_32,
    INFO_X3DH,
    32,
  );
  const ad = concatBytes(theirIdentity, identity.publicKey);
  return { shared, ad, theirIdentity: new Uint8Array(theirIdentity), opkId };
}

export interface SerializedRatchet {
  ad: string;
  root: string;
  dhSelfPub: string;
  dhSelfSec: string;
  dhRemote: string | null;
  sendChain: string | null;
  recvChain: string | null;
  ns: number;
  nr: number;
  pn: number;
  skipped: Array<[string, string]>;
}

export class DoubleRatchet {
  ad: Uint8Array;
  root: Uint8Array;
  dhSelf!: KeyPair;
  dhRemote: Uint8Array | null = null;
  sendChain: Uint8Array | null = null;
  recvChain: Uint8Array | null = null;
  ns = 0;
  nr = 0;
  pn = 0;
  skipped: Map<string, Uint8Array> = new Map();

  constructor(shared: Uint8Array, ad: Uint8Array) {
    this.ad = new Uint8Array(ad);
    this.root = new Uint8Array(shared);
  }

  static initiator(
    shared: Uint8Array,
    ad: Uint8Array,
    remoteSpk: Uint8Array,
  ): DoubleRatchet {
    const state = new DoubleRatchet(shared, ad);
    state.dhSelf = nacl.box.keyPair();
    state.dhRemote = new Uint8Array(remoteSpk);
    const [root, sendChain] = state.kdfRoot(
      dhExchange(state.dhSelf.secretKey, state.dhRemote),
    );
    state.root = root;
    state.sendChain = sendChain;
    return state;
  }

  static responder(
    shared: Uint8Array,
    ad: Uint8Array,
    spkPrivate: KeyPair,
  ): DoubleRatchet {
    const state = new DoubleRatchet(shared, ad);
    state.dhSelf = spkPrivate;
    return state;
  }

  private kdfRoot(dhOut: Uint8Array): [Uint8Array, Uint8Array] {
    const out = deriveHkdf(dhOut, this.root, INFO_RATCHET, 64);
    return [out.slice(0, 32), out.slice(32, 64)];
  }

  encrypt(plaintext: Uint8Array): Uint8Array {
    if (!this.sendChain) throw new CryptoError("send chain not initialized");
    const [nextChain, key] = kdfChain(this.sendChain);
    this.sendChain = nextChain;
    const header = concatBytes(
      this.dhSelf.publicKey,
      u32be(this.pn),
      u32be(this.ns),
    );
    this.ns += 1;
    const ct = aeadEncrypt(key, plaintext, concatBytes(this.ad, header));
    return concatBytes(header, ct);
  }

  decrypt(message: Uint8Array): Uint8Array {
    const snap = {
      root: this.root,
      dhSelf: this.dhSelf,
      dhRemote: this.dhRemote,
      sendChain: this.sendChain,
      recvChain: this.recvChain,
      ns: this.ns,
      nr: this.nr,
      pn: this.pn,
      skipped: new Map(this.skipped),
    };
    try {
      return this.decryptInner(message);
    } catch (err) {
      this.root = snap.root;
      this.dhSelf = snap.dhSelf;
      this.dhRemote = snap.dhRemote;
      this.sendChain = snap.sendChain;
      this.recvChain = snap.recvChain;
      this.ns = snap.ns;
      this.nr = snap.nr;
      this.pn = snap.pn;
      this.skipped = snap.skipped;
      throw err;
    }
  }

  private decryptInner(message: Uint8Array): Uint8Array {
    if (message.length < 40 + 16) throw new CryptoError("short message");
    const header = message.subarray(0, 40);
    const ciphertext = message.subarray(40);
    const dh = header.subarray(0, 32);
    const pn = readU32be(header, 32);
    const n = readU32be(header, 36);
    const skipKey = `${toHex(dh)}:${n}`;
    const skipped = this.skipped.get(skipKey);
    if (skipped) {
      this.skipped.delete(skipKey);
      return aeadDecrypt(skipped, ciphertext, concatBytes(this.ad, header));
    }
    if (!this.dhRemote || !bytesEqual(dh, this.dhRemote)) {
      this.skip(pn);
      this.dhStep(dh);
    }
    this.skip(n);
    if (!this.recvChain) throw new CryptoError("recv chain not initialized");
    const [nextRecv, key] = kdfChain(this.recvChain);
    this.recvChain = nextRecv;
    this.nr += 1;
    return aeadDecrypt(key, ciphertext, concatBytes(this.ad, header));
  }

  private skip(until: number): void {
    if (!this.recvChain) {
      if (until !== 0) {
        throw new CryptoError("cannot skip before first DH step");
      }
      return;
    }
    if (until < this.nr || this.skipped.size + (until - this.nr) > MAX_SKIP) {
      throw new CryptoError("too many skipped messages");
    }
    while (this.nr < until) {
      const [nextRecv, key] = kdfChain(this.recvChain);
      this.recvChain = nextRecv;
      this.skipped.set(`${toHex(this.dhRemote!)}:${this.nr}`, key);
      this.nr += 1;
    }
  }

  private dhStep(dh: Uint8Array): void {
    this.pn = this.ns;
    this.ns = 0;
    this.nr = 0;
    this.dhRemote = new Uint8Array(dh);
    const [r1, recvChain] = this.kdfRoot(
      dhExchange(this.dhSelf.secretKey, this.dhRemote),
    );
    this.root = r1;
    this.recvChain = recvChain;
    this.dhSelf = nacl.box.keyPair();
    const [r2, sendChain] = this.kdfRoot(
      dhExchange(this.dhSelf.secretKey, this.dhRemote),
    );
    this.root = r2;
    this.sendChain = sendChain;
  }

  toJSON(): SerializedRatchet {
    const skipped: Array<[string, string]> = [];
    this.skipped.forEach((v, k) => skipped.push([k, toB64(v)]));
    return {
      ad: toB64(this.ad),
      root: toB64(this.root),
      dhSelfPub: toB64(this.dhSelf.publicKey),
      dhSelfSec: toB64(this.dhSelf.secretKey),
      dhRemote: this.dhRemote ? toB64(this.dhRemote) : null,
      sendChain: this.sendChain ? toB64(this.sendChain) : null,
      recvChain: this.recvChain ? toB64(this.recvChain) : null,
      ns: this.ns,
      nr: this.nr,
      pn: this.pn,
      skipped,
    };
  }

  static fromJSON(d: SerializedRatchet): DoubleRatchet {
    const r = new DoubleRatchet(fromB64(d.root), fromB64(d.ad));
    r.dhSelf = {
      publicKey: fromB64(d.dhSelfPub),
      secretKey: fromB64(d.dhSelfSec),
    };
    r.dhRemote = d.dhRemote ? fromB64(d.dhRemote) : null;
    r.sendChain = d.sendChain ? fromB64(d.sendChain) : null;
    r.recvChain = d.recvChain ? fromB64(d.recvChain) : null;
    r.ns = d.ns;
    r.nr = d.nr;
    r.pn = d.pn;
    for (const [k, v] of d.skipped) r.skipped.set(k, fromB64(v));
    return r;
  }
}

export function prekeyEnvelope(
  header: Uint8Array,
  ratchetMessage: Uint8Array,
): Uint8Array {
  return concatBytes(new Uint8Array([VERSION, PREKEY]), header, ratchetMessage);
}

export function messageEnvelope(ratchetMessage: Uint8Array): Uint8Array {
  return concatBytes(new Uint8Array([VERSION, MESSAGE]), ratchetMessage);
}

export function parseEnvelope(
  data: Uint8Array,
): { kind: "prekey"; header: Uint8Array; ratchet: Uint8Array } | {
  kind: "msg";
  header: null;
  ratchet: Uint8Array;
} {
  if (data.length < 2 || data[0] !== VERSION) {
    throw new CryptoError("unknown envelope version");
  }
  if (data[1] === PREKEY) {
    if (data.length < 2 + 104 + 56) {
      throw new CryptoError("short prekey envelope");
    }
    return {
      kind: "prekey",
      header: data.subarray(2, 106),
      ratchet: data.subarray(106),
    };
  }
  if (data[1] === MESSAGE) {
    if (data.length < 2 + 56) throw new CryptoError("short message envelope");
    return { kind: "msg", header: null, ratchet: data.subarray(2) };
  }
  throw new CryptoError("unknown envelope type");
}

export interface SerializedSenderKey {
  keyId: number;
  chain: string;
  iteration: number;
  signingPub: string;
  signingSec: string | null;
  skipped: Array<[number, string]>;
}

export class SenderKey {
  keyId: number;
  chain: Uint8Array;
  iteration: number;
  signingPublic: Uint8Array;
  signingPrivate: Uint8Array | null;
  skipped: Map<number, Uint8Array> = new Map();

  constructor(
    keyId: number,
    chain: Uint8Array,
    iteration: number,
    signingPublic: Uint8Array,
    signingPrivate: Uint8Array | null = null,
  ) {
    this.keyId = keyId;
    this.chain = new Uint8Array(chain);
    this.iteration = iteration;
    this.signingPublic = new Uint8Array(signingPublic);
    this.signingPrivate = signingPrivate
      ? new Uint8Array(signingPrivate)
      : null;
  }

  static create(): SenderKey {
    const signing = nacl.sign.keyPair();
    const keyId = readU32be(randomBytes(4), 0) & 0x7fffffff;
    return new SenderKey(
      keyId,
      randomBytes(32),
      0,
      signing.publicKey,
      signing.secretKey,
    );
  }

  distribution(channel?: string): SenderKeyDistribution {
    const dist: SenderKeyDistribution = {
      key_id: this.keyId,
      chain: toHex(this.chain),
      iteration: this.iteration,
      signing: toHex(this.signingPublic),
    };
    if (channel) dist.channel = channel;
    return dist;
  }

  static fromDistribution(d: SenderKeyDistribution): SenderKey {
    if (
      typeof d.key_id !== "number" ||
      !Number.isInteger(d.key_id) ||
      d.key_id < 0 ||
      d.key_id > 0xffffffff
    ) {
      throw new CryptoError("invalid sender key id");
    }
    if (
      typeof d.iteration !== "number" || !Number.isInteger(d.iteration) ||
      d.iteration < 0
    ) {
      throw new CryptoError("invalid sender key iteration");
    }
    const chain = fromHex(d.chain);
    const signing = fromHex(d.signing);
    if (chain.length !== 32 || signing.length !== 32) {
      throw new CryptoError("invalid sender key material length");
    }
    return new SenderKey(d.key_id, chain, d.iteration, signing, null);
  }

  encrypt(plaintext: Uint8Array, channel: string): Uint8Array {
    if (!this.signingPrivate) {
      throw new CryptoError("sender key has no private signing key");
    }
    const [nextChain, key] = kdfChain(this.chain);
    this.chain = nextChain;
    const header = concatBytes(
      new Uint8Array([VERSION, CHANNEL]),
      u32be(this.keyId),
      u32be(this.iteration),
    );
    this.iteration += 1;
    const ct = aeadEncrypt(
      key,
      plaintext,
      concatBytes(enc.encode(channel), header),
    );
    const body = concatBytes(header, ct);
    const sig = nacl.sign.detached(body, this.signingPrivate);
    return concatBytes(body, sig);
  }

  decrypt(data: Uint8Array, channel: string): Uint8Array {
    if (data.length < 10 + 16 + 64) {
      throw new CryptoError("short channel message");
    }
    const body = data.subarray(0, data.length - 64);
    const sig = data.subarray(data.length - 64);
    if (!nacl.sign.detached.verify(body, sig, this.signingPublic)) {
      throw new CryptoError("bad channel signature");
    }
    const header = body.subarray(0, 10);
    if (header[0] !== VERSION || header[1] !== CHANNEL) {
      throw new CryptoError("unknown channel envelope");
    }
    const keyId = readU32be(header, 2);
    const iteration = readU32be(header, 6);
    if (keyId !== this.keyId) throw new CryptoError("unknown sender key");

    const savedChain = this.chain;
    const savedIter = this.iteration;
    const savedSkipped = new Map(this.skipped);
    try {
      let key = this.skipped.get(iteration);
      if (key) {
        this.skipped.delete(iteration);
      } else {
        if (
          iteration < this.iteration ||
          this.skipped.size + (iteration - this.iteration) > MAX_SKIP
        ) {
          throw new CryptoError("old or too distant channel message");
        }
        while (this.iteration < iteration) {
          const [nc, sk] = kdfChain(this.chain);
          this.chain = nc;
          this.skipped.set(this.iteration, sk);
          this.iteration += 1;
        }
        const [nc, k] = kdfChain(this.chain);
        this.chain = nc;
        key = k;
        this.iteration += 1;
      }
      return aeadDecrypt(
        key,
        body.subarray(10),
        concatBytes(enc.encode(channel), header),
      );
    } catch (err) {
      this.chain = savedChain;
      this.iteration = savedIter;
      this.skipped = savedSkipped;
      throw err;
    }
  }

  toJSON(): SerializedSenderKey {
    const skipped: Array<[number, string]> = [];
    this.skipped.forEach((v, k) => skipped.push([k, toB64(v)]));
    return {
      keyId: this.keyId,
      chain: toB64(this.chain),
      iteration: this.iteration,
      signingPub: toB64(this.signingPublic),
      signingSec: this.signingPrivate ? toB64(this.signingPrivate) : null,
      skipped,
    };
  }

  static fromJSON(d: SerializedSenderKey): SenderKey {
    const sk = new SenderKey(
      d.keyId,
      fromB64(d.chain),
      d.iteration,
      fromB64(d.signingPub),
      d.signingSec ? fromB64(d.signingSec) : null,
    );
    for (const [k, v] of d.skipped) sk.skipped.set(k, fromB64(v));
    return sk;
  }
}

export function identityFingerprint(pub64: Uint8Array): string {
  const hash = sha256(pub64);
  const hex = toHex(hash.subarray(0, 12)).toUpperCase();
  return hex.match(/.{1,4}/g)?.join(" ") ?? hex;
}

export function safetyNumber(idA: Uint8Array, idB: Uint8Array): string {
  const [first, second] = compareBytes(idA, idB) <= 0 ? [idA, idB] : [idB, idA];
  const h1 = sha256(concatBytes(BYTE_01, first, second));
  const h2 = sha256(concatBytes(BYTE_02, first, second));
  const digest = concatBytes(h1, h2);
  const groups: string[] = [];
  for (let i = 0; i < 60; i += 5) {
    const val = digest[i] * 4294967296 +
      digest[i + 1] * 16777216 +
      digest[i + 2] * 65536 +
      digest[i + 3] * 256 +
      digest[i + 4];
    groups.push(String(val % 100000).padStart(5, "0"));
  }
  return groups.join(" ");
}

const BACKUP_FORMAT = "ircd-e2ee-backup";
const BACKUP_VERSION = 1;
const BACKUP_ITERATIONS = 100000;
const BACKUP_AD = enc.encode("ircd-e2ee-backup-v1");
const dec = new TextDecoder();

interface EncryptedBackupEnvelope {
  format: string;
  version: number;
  kdf: string;
  iterations: number;
  salt: string;
  iv: string;
  ciphertext: string;
}

export function encryptKeyBackup(
  plaintextJson: string,
  passphrase: string,
): string {
  if (!passphrase || passphrase.length < 6) {
    throw new CryptoError("Backup passphrase must be at least 6 characters");
  }
  const salt = randomBytes(16);
  const iv = randomBytes(12);
  const key = pbkdf2(sha256, enc.encode(passphrase), salt, {
    c: BACKUP_ITERATIONS,
    dkLen: 32,
  });
  const ciphertext = gcm(key, iv, BACKUP_AD).encrypt(enc.encode(plaintextJson));
  const envelope: EncryptedBackupEnvelope = {
    format: BACKUP_FORMAT,
    version: BACKUP_VERSION,
    kdf: "pbkdf2-sha256",
    iterations: BACKUP_ITERATIONS,
    salt: toB64(salt),
    iv: toB64(iv),
    ciphertext: toB64(ciphertext),
  };
  return JSON.stringify(envelope, null, 2);
}

export function decryptKeyBackup(
  backupJson: string,
  passphrase: string,
): string {
  if (!passphrase) throw new CryptoError("Passphrase is required");
  let env: Partial<EncryptedBackupEnvelope>;
  try {
    env = JSON.parse(backupJson) as Partial<EncryptedBackupEnvelope>;
  } catch {
    throw new CryptoError("Invalid backup file (not JSON)");
  }
  if (
    env.format !== BACKUP_FORMAT ||
    env.version !== BACKUP_VERSION ||
    env.kdf !== "pbkdf2-sha256" ||
    typeof env.iterations !== "number" ||
    !Number.isInteger(env.iterations) ||
    env.iterations < 10000 ||
    env.iterations > 1000000 ||
    typeof env.salt !== "string" ||
    typeof env.iv !== "string" ||
    typeof env.ciphertext !== "string"
  ) {
    throw new CryptoError("Unsupported or malformed E2EE backup file");
  }
  const salt = fromB64(env.salt);
  const iv = fromB64(env.iv);
  const ciphertext = fromB64(env.ciphertext);
  if (salt.length !== 16 || iv.length !== 12 || ciphertext.length < 16) {
    throw new CryptoError("Corrupted backup parameters");
  }
  const key = pbkdf2(sha256, enc.encode(passphrase), salt, {
    c: env.iterations,
    dkLen: 32,
  });
  try {
    const pt = gcm(key, iv, BACKUP_AD).decrypt(ciphertext);
    return dec.decode(pt);
  } catch {
    throw new CryptoError("Wrong passphrase or corrupted backup");
  }
}

const ATTACHMENT_AD = enc.encode("ircd-e2ee-attachment-v1");

export interface EncryptedAttachmentResult {
  ciphertext: Uint8Array;
  key: string;
  iv: string;
  sha256: string;
}

/**
 * Encrypt arbitrary attachment bytes (voice note or file) with a fresh random
 * AES-256-GCM key and 12-byte IV, plus a SHA-256 digest of the ciphertext so
 * the object store cannot silently swap or tamper with the stored blob.
 */
export function encryptAttachment(
  plaintext: Uint8Array,
): EncryptedAttachmentResult {
  const key = randomBytes(32);
  const iv = randomBytes(12);
  const ciphertext = gcm(key, iv, ATTACHMENT_AD).encrypt(plaintext);
  const digest = sha256(ciphertext);
  return {
    ciphertext,
    key: toB64(key),
    iv: toB64(iv),
    sha256: toB64(digest),
  };
}

/**
 * Verify the SHA-256 digest of an encrypted attachment blob and decrypt it
 * with AES-256-GCM.
 */
export function decryptAttachment(
  ciphertext: Uint8Array,
  keyB64: string,
  ivB64: string,
  sha256B64: string,
): Uint8Array {
  const key = fromB64(keyB64);
  const iv = fromB64(ivB64);
  const expectedHash = fromB64(sha256B64);
  if (key.length !== 32 || iv.length !== 12 || expectedHash.length !== 32) {
    throw new CryptoError("Invalid encrypted attachment parameters");
  }
  const actualHash = sha256(ciphertext);
  let diff = 0;
  for (let i = 0; i < 32; i++) diff |= actualHash[i] ^ expectedHash[i];
  if (diff !== 0) {
    throw new CryptoError("Encrypted attachment integrity check failed");
  }
  try {
    return gcm(key, iv, ATTACHMENT_AD).decrypt(ciphertext);
  } catch {
    throw new CryptoError("Encrypted attachment decryption failed");
  }
}
