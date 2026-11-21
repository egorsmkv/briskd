import { errorMessage } from "../common/dom.ts";
import { ircFold } from "../common/ircv3.ts";
import {
  bytesEqual,
  CryptoError,
  decryptKeyBackup,
  DoubleRatchet,
  encryptKeyBackup,
  fromB64,
  Identity,
  identityFingerprint,
  messageEnvelope,
  NO_OPK,
  parseEnvelope,
  PreKeyBundle,
  prekeyEnvelope,
  PreKeys,
  randomDeviceId,
  safetyNumber,
  SenderKey,
  SenderKeyDistribution,
  SerializedIdentity,
  SerializedPreKeys,
  SerializedRatchet,
  SerializedSenderKey,
  toB64,
  x3dhInitiate,
  x3dhRespond,
} from "./crypto.ts";

export const E2EE_VENDOR = "egorsmkv.github.io";
export const E2EE_CAP = `${E2EE_VENDOR}/e2ee`;
export const TAG_SRC = `+${E2EE_VENDOR}/e2ee-src`;
export const TAG_DST = `+${E2EE_VENDOR}/e2ee-dst`;
export const TAG_TYPE = `+${E2EE_VENDOR}/e2ee-type`;
export const TAG_QID = `${E2EE_VENDOR}/e2ee-qid`;

const CHUNK = 400;
const INITIAL_PREKEYS = 20;
const STORAGE_PREFIX = "ircd-e2ee-v1:";

// localStorage key for an account's state. Keys (account, channel, and
// buffer names) are folded with ircFold (RFC 1459, as the server does).
function storageKey(account: string): string {
  return STORAGE_PREFIX + ircFold(account);
}

// Older builds keyed state with String.prototype.toLowerCase. Account names
// are nickname-charset ASCII, so ircFold(legacy) equals ircFold(original);
// this key is read as a fallback and removed once the folded key is written.
function legacyStorageKey(account: string): string {
  return STORAGE_PREFIX + account.toLowerCase();
}

// Re-key persisted map entries with ircFold. Entries written by older builds
// carry toLowerCase keys; folding them again maps ASCII names to the same key
// the current code uses. The first entry wins if two keys collide.
function refold<V>(
  entries: Array<[string, V]> | undefined,
): Array<[string, V]> {
  const seen = new Set<string>();
  const out: Array<[string, V]> = [];
  for (const [k, v] of entries || []) {
    const fk = ircFold(k);
    if (seen.has(fk)) continue;
    seen.add(fk);
    out.push([fk, v]);
  }
  return out;
}

const enc = new TextEncoder();
const dec = new TextDecoder();

export interface IrcMsgLike {
  tags: Record<string, string>;
  prefix: string;
  nick: string;
  command: string;
  params: string[];
}

export interface DecryptedEvent {
  target: string;
  nick: string;
  account: string;
  device: number;
  text: string;
  time?: string;
  queued: boolean;
  isChannel: boolean;
}

export interface E2eeCallbacks {
  sendRaw: (line: string) => void;
  onDecrypted: (ev: DecryptedEvent) => void;
  onNotice: (target: string, text: string, kind: "sys" | "err") => void;
  onStateChange: () => void;
}

export interface TrustedPeerInfo {
  key: string;
  account: string;
  device: number;
  fingerprint: string;
  safetyNumber: string;
}

export interface E2eeStatus {
  serverSupported: boolean;
  account: string;
  deviceId: number;
  bound: boolean;
  prekeyCount: number;
  fingerprint: string;
  sessionCount: number;
  trustedPeers: TrustedPeerInfo[];
}

/** Nicks whose account is remembered (as the users table, webirc/users.ts). */
const MAX_NICK_ACCOUNTS = 5000;

/** Limits on encrypted multiline batches, as in common/multiline.ts. */
const MAX_OPEN_BATCHES = 16;
const MAX_BATCH_LINES = 500;
const MAX_BATCH_CHARS = 64 * 1024;

/** Channel sender keys kept per peer device (one per channel shared). */
const MAX_KEYS_PER_PEER = 64;
/** Channel sender keys kept in total. */
const MAX_RECEIVED_KEYS = 2000;

interface PersistedState {
  deviceId: number;
  identity: SerializedIdentity;
  prekeys: SerializedPreKeys;
  prekeysUploaded: boolean;
  sessions: Array<[string, SerializedRatchet]>;
  awaitingReply: Array<[string, string]>;
  trusted: Array<[string, string]>;
  senderKeys: Array<[string, SerializedSenderKey]>;
  receivedKeys: Array<[string, SerializedSenderKey]>;
  sharedWith: Array<[string, string[]]>;
  enabledBuffers: string[];
}

interface FetchRequest {
  target: string;
  bundles: PreKeyBundle[];
  resolve: (bundles: PreKeyBundle[]) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface WhoRequest {
  channel: string;
  token: string;
  found: Array<{ nick: string; account: string }>;
  resolve: (members: Array<{ nick: string; account: string }>) => void;
  timer: ReturnType<typeof setTimeout>;
}

function isChan(name: string): boolean {
  return /^[#&+!]/.test(name || "");
}

function formatTags(tags: Record<string, string | null>): string {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(tags)) {
    if (v === null) parts.push(k);
    else parts.push(`${k}=${v}`);
  }
  return parts.length ? `@${parts.join(";")} ` : "";
}

export class E2eeManager {
  private cb: E2eeCallbacks;
  private serverSupported = false;
  private accountTagEnabled = false;
  private account = "";
  private myNick = "";
  private deviceId = 0;
  private identity: Identity | null = null;
  private prekeys: PreKeys | null = null;
  private prekeysUploaded = false;
  private bound = false;
  private serverPrekeyCount = 0;
  private replenishing = false;

  private sessions = new Map<string, DoubleRatchet>();
  private awaitingReply = new Map<string, Uint8Array>();
  private trusted = new Map<string, Uint8Array>();
  private senderKeys = new Map<string, SenderKey>();
  private receivedKeys = new Map<string, SenderKey>();
  private sharedWith = new Map<string, Set<string>>();
  private needsRotation = new Set<string>();
  private enabledBuffers = new Set<string>();
  /** Folded nick → folded account, most recently learned last; capped. */
  private nickToAccount = new Map<string, string>();

  private rememberAccount(nick: string, account: string): void {
    this.nickToAccount.delete(nick);
    this.nickToAccount.set(nick, account);
    if (this.nickToAccount.size > MAX_NICK_ACCOUNTS) {
      const oldest = this.nickToAccount.keys().next().value;
      if (oldest !== undefined) this.nickToAccount.delete(oldest);
    }
  }

  /** Open encrypted multiline batches (bounded like common/multiline.ts). */
  private batches = new Map<
    string,
    { start: IrcMsgLike; lines: string[]; chars: number }
  >();
  private fetchQueue: Array<{
    target: string;
    resolve: (b: PreKeyBundle[]) => void;
    reject: (e: Error) => void;
  }> = [];
  private activeFetch: FetchRequest | null = null;
  private activeWho = new Map<string, WhoRequest>();
  private batchSeq = 1;
  private whoSeq = 42;

  constructor(cb: E2eeCallbacks) {
    this.cb = cb;
  }

  resetConnection(): void {
    this.serverSupported = false;
    this.accountTagEnabled = false;
    this.bound = false;
    this.replenishing = false;
    this.batches.clear();
    if (this.activeFetch) {
      clearTimeout(this.activeFetch.timer);
      this.activeFetch.reject(new Error("Disconnected"));
      this.activeFetch = null;
    }
    while (this.fetchQueue.length) {
      this.fetchQueue.shift()!.reject(new Error("Disconnected"));
    }
    this.activeWho.forEach((w) => {
      clearTimeout(w.timer);
      w.resolve([]);
    });
    this.activeWho.clear();
    this.cb.onStateChange();
  }

  setServerSupported(supported: boolean): void {
    this.serverSupported = supported;
    this.cb.onStateChange();
  }

  setAccountTagEnabled(enabled: boolean): void {
    this.accountTagEnabled = enabled;
  }

  setMyNick(nick: string): void {
    this.myNick = nick;
  }

  setAccount(account: string): void {
    const clean = account.trim();
    if (!clean || clean === "*") return;
    if (ircFold(this.account) !== ircFold(clean)) {
      this.account = clean;
      this.loadOrCreateState(clean);
    }
    this.cb.onStateChange();
  }

  onRegistered(): void {
    if (
      !this.serverSupported || !this.account || !this.identity || !this.prekeys
    ) {
      this.cb.onStateChange();
      return;
    }
    this.publishAndBind();
  }

  isServerSupported(): boolean {
    return this.serverSupported;
  }

  isReady(): boolean {
    return this.serverSupported && !!this.account && this.bound &&
      !!this.identity;
  }

  isBufferEncrypted(bufKey: string): boolean {
    return this.enabledBuffers.has(ircFold(bufKey));
  }

  setBufferEncrypted(bufKey: string, enabled: boolean): boolean {
    const k = ircFold(bufKey);
    if (k === "*status") return false;
    if (enabled) {
      if (!this.serverSupported) {
        this.cb.onNotice(
          bufKey,
          "Server does not advertise E2EE capability (egorsmkv.github.io/e2ee).",
          "err",
        );
        return false;
      }
      if (!this.account) {
        this.cb.onNotice(
          bufKey,
          "E2EE requires logging in with a SASL account first.",
          "err",
        );
        return false;
      }
      if (!this.bound) {
        this.cb.onNotice(
          bufKey,
          "E2EE device is still initializing; please wait a moment.",
          "err",
        );
        return false;
      }
      this.enabledBuffers.add(k);
    } else {
      this.enabledBuffers.delete(k);
    }
    this.saveState();
    this.cb.onStateChange();
    return this.enabledBuffers.has(k);
  }

  toggleBuffer(bufKey: string): boolean {
    return this.setBufferEncrypted(bufKey, !this.isBufferEncrypted(bufKey));
  }

  onMemberLeft(channel: string): void {
    const k = ircFold(channel);
    if (this.senderKeys.has(k)) {
      this.needsRotation.add(k);
    }
  }

  getStatus(): E2eeStatus {
    const trustedPeers: TrustedPeerInfo[] = [];
    if (this.identity) {
      const myPub = this.identity.publicKey;
      this.trusted.forEach((pub, key) => {
        const idx = key.lastIndexOf(":");
        const account = idx >= 0 ? key.slice(0, idx) : key;
        const device = idx >= 0 ? parseInt(key.slice(idx + 1), 10) || 0 : 0;
        trustedPeers.push({
          key,
          account,
          device,
          fingerprint: identityFingerprint(pub),
          safetyNumber: safetyNumber(myPub, pub),
        });
      });
    }
    trustedPeers.sort((a, b) => a.key.localeCompare(b.key));
    return {
      serverSupported: this.serverSupported,
      account: this.account,
      deviceId: this.deviceId,
      bound: this.bound,
      prekeyCount: this.serverPrekeyCount,
      fingerprint: this.identity
        ? identityFingerprint(this.identity.publicKey)
        : "",
      sessionCount: this.sessions.size,
      trustedPeers,
    };
  }

  forgetPeer(peerKey: string): void {
    this.trusted.delete(peerKey);
    this.sessions.delete(peerKey);
    this.awaitingReply.delete(peerKey);
    this.saveState();
    this.cb.onStateChange();
  }

  replenishPrekeys(count = INITIAL_PREKEYS): void {
    if (!this.isReady() || !this.prekeys) return;
    const added = this.prekeys.add(count);
    this.uploadPrekeysMap(added);
    this.saveState();
  }

  async rotateChannelKey(channel: string): Promise<void> {
    if (!this.isReady() || !isChan(channel)) return;
    const k = ircFold(channel);
    this.senderKeys.set(k, SenderKey.create());
    this.sharedWith.set(k, new Set());
    this.needsRotation.delete(k);
    this.saveState();
    await this.distributeSenderKey(channel);
    this.cb.onNotice(
      channel,
      "Rotated E2EE channel Sender Key and distributed to members.",
      "sys",
    );
  }

  resetDevice(): void {
    if (this.serverSupported && this.account && this.deviceId) {
      this.cb.sendRaw(`E2EE REMOVE ${this.deviceId}`);
    }
    if (this.account) {
      try {
        localStorage.removeItem(storageKey(this.account));
        localStorage.removeItem(legacyStorageKey(this.account));
      } catch {
        // ignore
      }
    }
    this.sessions.clear();
    this.awaitingReply.clear();
    this.trusted.clear();
    this.senderKeys.clear();
    this.receivedKeys.clear();
    this.sharedWith.clear();
    this.needsRotation.clear();
    this.bound = false;
    if (this.account) {
      this.createFreshState();
      if (this.serverSupported) this.publishAndBind();
    }
    this.cb.onStateChange();
  }

  // ---- Storage ----

  private createFreshState(): void {
    this.deviceId = randomDeviceId();
    this.identity = new Identity();
    this.prekeys = new PreKeys(this.identity, INITIAL_PREKEYS);
    this.prekeysUploaded = false;
    this.saveState();
  }

  private loadOrCreateState(account: string): void {
    this.sessions.clear();
    this.awaitingReply.clear();
    this.trusted.clear();
    this.senderKeys.clear();
    this.receivedKeys.clear();
    this.sharedWith.clear();
    this.needsRotation.clear();
    this.enabledBuffers.clear();

    let raw: string | null = null;
    try {
      raw = localStorage.getItem(storageKey(account)) ??
        localStorage.getItem(legacyStorageKey(account));
    } catch {
      raw = null;
    }
    if (raw && this.loadState(raw)) return;
    if (raw) {
      // The identity could not be read. New keys are made (peers will see
      // a changed identity), but the old text is kept aside first instead
      // of being overwritten, so it can still be recovered.
      try {
        localStorage.setItem(`${storageKey(account)}:unreadable`, raw);
      } catch {
        // storage full: nothing more can be done
      }
      this.cb.onNotice(
        "*status",
        "E2EE: the saved keys for this account could not be read; new keys were created. " +
          "The old data was kept in this browser's storage.",
        "err",
      );
    }
    this.createFreshState();
  }

  /**
   * Keep a peer's sender key for a channel. A peer chooses the channel
   * name, and every key is saved on every message, so the keys are capped:
   * per peer device and in total, the oldest stored first going.
   */
  private storeReceivedKey(id: string, peer: string, sk: SenderKey): void {
    this.receivedKeys.delete(id);
    this.receivedKeys.set(id, sk);
    const suffix = `|${peer}`;
    const mine = [...this.receivedKeys.keys()].filter((k) =>
      k.endsWith(suffix)
    );
    for (
      const k of mine.slice(0, Math.max(0, mine.length - MAX_KEYS_PER_PEER))
    ) {
      this.receivedKeys.delete(k);
    }
    while (this.receivedKeys.size > MAX_RECEIVED_KEYS) {
      const oldest = this.receivedKeys.keys().next().value;
      if (oldest === undefined) break;
      this.receivedKeys.delete(oldest);
    }
  }

  /**
   * Load saved state. The identity and prekeys are required: false (state
   * left empty) when they cannot be read. A session, key, or list entry that
   * cannot be read is skipped, so one bad entry does not cost the identity.
   */
  private loadState(raw: string): boolean {
    let d: Partial<PersistedState>;
    try {
      const parsed: unknown = JSON.parse(raw);
      if (!parsed || typeof parsed !== "object") return false;
      d = parsed as Partial<PersistedState>;
      if (typeof d.deviceId !== "number" || !Number.isInteger(d.deviceId)) {
        return false;
      }
      this.identity = Identity.fromJSON(
        d.identity as PersistedState["identity"],
      );
      this.prekeys = PreKeys.fromJSON(d.prekeys as PersistedState["prekeys"]);
      this.deviceId = d.deviceId;
    } catch {
      this.identity = null;
      this.prekeys = null;
      return false;
    }
    this.prekeysUploaded = !!d.prekeysUploaded;
    const each = <T>(
      entries: Array<[string, T]> | undefined,
      apply: (key: string, value: T) => void,
    ) => {
      if (!Array.isArray(entries)) return;
      const pairs = entries.filter((e): e is [string, T] =>
        Array.isArray(e) && typeof e[0] === "string"
      );
      for (const [k, v] of refold(pairs)) {
        try {
          apply(k, v);
        } catch {
          // one unreadable entry: skip it
        }
      }
    };
    each(d.sessions, (k, v) => this.sessions.set(k, DoubleRatchet.fromJSON(v)));
    each(d.awaitingReply, (k, v) => this.awaitingReply.set(k, fromB64(v)));
    each(d.trusted, (k, v) => this.trusted.set(k, fromB64(v)));
    each(d.senderKeys, (k, v) => this.senderKeys.set(k, SenderKey.fromJSON(v)));
    each(
      d.receivedKeys,
      (k, v) => this.receivedKeys.set(k, SenderKey.fromJSON(v)),
    );
    each(d.sharedWith, (k, list) => {
      if (!Array.isArray(list)) return;
      this.sharedWith.set(
        k,
        new Set(list.filter((n) => typeof n === "string").map(ircFold)),
      );
    });
    if (Array.isArray(d.enabledBuffers)) {
      for (const b of d.enabledBuffers) {
        if (typeof b === "string") this.enabledBuffers.add(ircFold(b));
      }
    }
    return true;
  }

  exportBackup(passphrase: string): { filename: string; content: string } {
    if (!this.account || !this.identity || !this.prekeys) {
      throw new CryptoError("No E2EE keys initialized for this account");
    }
    const payload = JSON.stringify({
      account: this.account,
      state: this.serializeState(),
    });
    const content = encryptKeyBackup(payload, passphrase);
    const safeAcct = this.account.replace(/[^a-zA-Z0-9._-]/g, "_");
    return {
      filename: `ircd-e2ee-${safeAcct}-${this.deviceId}.json`,
      content,
    };
  }

  importBackup(
    backupText: string,
    passphrase: string,
  ): { account: string; deviceId: number } {
    const plain = decryptKeyBackup(backupText, passphrase);
    let parsed: { account?: string; state?: PersistedState };
    try {
      parsed = JSON.parse(plain) as {
        account?: string;
        state?: PersistedState;
      };
    } catch {
      throw new CryptoError("Corrupted backup payload");
    }
    if (
      !parsed.account || !parsed.state || !parsed.state.identity ||
      !parsed.state.prekeys
    ) {
      throw new CryptoError("Incomplete E2EE backup payload");
    }
    if (
      this.account &&
      ircFold(parsed.account) !== ircFold(this.account)
    ) {
      throw new CryptoError(
        `Backup belongs to account "${parsed.account}", but you are logged in as "${this.account}"`,
      );
    }

    const d = parsed.state;
    if (
      typeof d.deviceId !== "number" ||
      !Number.isInteger(d.deviceId) ||
      d.deviceId < 1 ||
      d.deviceId > 0x7fffffff
    ) {
      throw new CryptoError("Invalid device ID in backup");
    }

    // Validate & deserialize all cryptographic objects before mutating live state
    const identity = Identity.fromJSON(d.identity);
    const prekeys = PreKeys.fromJSON(d.prekeys);
    const sessions = new Map<string, DoubleRatchet>();
    for (const [k, v] of refold(d.sessions)) {
      sessions.set(k, DoubleRatchet.fromJSON(v));
    }
    const awaitingReply = new Map<string, Uint8Array>();
    for (const [k, v] of refold(d.awaitingReply)) {
      awaitingReply.set(k, fromB64(v));
    }
    const trusted = new Map<string, Uint8Array>();
    for (const [k, v] of refold(d.trusted)) trusted.set(k, fromB64(v));
    const senderKeys = new Map<string, SenderKey>();
    for (const [k, v] of refold(d.senderKeys)) {
      senderKeys.set(k, SenderKey.fromJSON(v));
    }
    const receivedKeys = new Map<string, SenderKey>();
    for (const [k, v] of refold(d.receivedKeys)) {
      receivedKeys.set(k, SenderKey.fromJSON(v));
    }
    const sharedWith = new Map<string, Set<string>>();
    for (const [k, list] of refold(d.sharedWith)) {
      sharedWith.set(k, new Set(list.map(ircFold)));
    }
    const enabledBuffers = new Set<string>(
      (d.enabledBuffers || []).map(ircFold),
    );

    if (!this.account) this.account = parsed.account;
    this.deviceId = d.deviceId;
    this.identity = identity;
    this.prekeys = prekeys;
    this.prekeysUploaded = false;
    this.sessions = sessions;
    this.awaitingReply = awaitingReply;
    this.trusted = trusted;
    this.senderKeys = senderKeys;
    this.receivedKeys = receivedKeys;
    this.sharedWith = sharedWith;
    this.needsRotation.clear();
    this.enabledBuffers = enabledBuffers;
    this.bound = false;
    this.saveState();
    if (this.serverSupported && this.account) {
      this.publishAndBind();
    }
    this.cb.onStateChange();
    return { account: this.account, deviceId: this.deviceId };
  }

  private serializeState(): PersistedState {
    return {
      deviceId: this.deviceId,
      identity: this.identity!.toJSON(),
      prekeys: this.prekeys!.toJSON(),
      prekeysUploaded: this.prekeysUploaded,
      sessions: Array.from(this.sessions.entries()).map((
        [k, v],
      ) => [k, v.toJSON()]),
      awaitingReply: Array.from(this.awaitingReply.entries()).map((
        [k, v],
      ) => [k, toB64(v)]),
      trusted: Array.from(this.trusted.entries()).map((
        [k, v],
      ) => [k, toB64(v)]),
      senderKeys: Array.from(this.senderKeys.entries()).map((
        [k, v],
      ) => [k, v.toJSON()]),
      receivedKeys: Array.from(this.receivedKeys.entries()).map((
        [k, v],
      ) => [k, v.toJSON()]),
      sharedWith: Array.from(this.sharedWith.entries()).map((
        [k, s],
      ) => [k, Array.from(s)]),
      enabledBuffers: Array.from(this.enabledBuffers),
    };
  }

  private saveState(): void {
    if (!this.account || !this.identity || !this.prekeys) return;
    const data = this.serializeState();
    try {
      localStorage.setItem(storageKey(this.account), JSON.stringify(data));
      const legacy = legacyStorageKey(this.account);
      if (legacy !== storageKey(this.account)) localStorage.removeItem(legacy);
    } catch {
      // ignore quota errors
    }
  }

  // ---- Publish / Prekeys / Bind ----

  private publishAndBind(): void {
    if (!this.identity || !this.prekeys) return;
    const ik = toB64(this.identity.publicKey);
    const spk = toB64(this.prekeys.spk.publicKey);
    const sig = toB64(this.prekeys.signature);
    this.cb.sendRaw(
      `E2EE PUBLISH ${this.deviceId} ${ik} ${this.prekeys.spkId}:${spk} ${sig}`,
    );
  }

  private uploadPrekeysMap(keys: Map<number, Uint8Array>): void {
    const items = Array.from(keys.entries()).sort((a, b) => a[0] - b[0]);
    for (let i = 0; i < items.length; i += 8) {
      const chunk = items
        .slice(i, i + 8)
        .map(([id, pub]) => `${id}:${toB64(pub)}`)
        .join(" ");
      this.cb.sendRaw(`E2EE PREKEYS ${this.deviceId} ${chunk}`);
    }
  }

  // ---- Inbound IRC handling ----

  handleIrc(msg: IrcMsgLike): boolean {
    const { command, params, tags } = msg;

    if (command === "E2EE") {
      this.handleE2eeReply(params);
      return true;
    }
    if (command === "FAIL" && params[0] === "E2EE") {
      const code = params[1] || "ERROR";
      const detail = params.slice(2).join(" ");
      if (this.activeFetch) {
        const req = this.activeFetch;
        clearTimeout(req.timer);
        this.activeFetch = null;
        req.reject(new Error(`E2EE ${code}: ${detail}`));
        this.pumpFetchQueue();
      } else {
        this.cb.onNotice("*status", `E2EE error (${code}): ${detail}`, "err");
      }
      return true;
    }
    if (command === "354" && params.length >= 4) {
      const req = this.activeWho.get(params[1]);
      if (req) {
        const nick = params[2];
        const acct = params[3];
        if (acct && acct !== "0") {
          this.rememberAccount(ircFold(nick), ircFold(acct));
          req.found.push({ nick, account: ircFold(acct) });
        }
        return true;
      }
    }
    if (command === "315" && params.length >= 2) {
      const ch = ircFold(params[1]);
      for (const [tok, req] of this.activeWho.entries()) {
        if (req.channel === ch) {
          clearTimeout(req.timer);
          this.activeWho.delete(tok);
          req.resolve(req.found);
          return true;
        }
      }
    }
    if (command === "BATCH" && params[0]) {
      const ref = params[0].slice(1);
      if (
        params[0].startsWith("+") && params[1] === "draft/multiline" &&
        tags[TAG_TYPE]
      ) {
        if (this.batches.size >= MAX_OPEN_BATCHES) {
          const oldest = this.batches.keys().next().value;
          if (oldest !== undefined) this.batches.delete(oldest);
        }
        this.batches.set(ref, { start: msg, lines: [], chars: 0 });
        return true;
      }
      if (params[0].startsWith("-") && this.batches.has(ref)) {
        const opened = this.batches.get(ref)!;
        this.batches.delete(ref);
        const fullText = opened.lines.join("");
        const target = opened.start.params[2] || "*status";
        this.receiveEnvelope(
          opened.start.tags,
          opened.start.nick,
          target,
          fullText,
        );
        return true;
      }
    }
    if (
      (command === "PRIVMSG" || command === "NOTICE") && tags.batch &&
      this.batches.has(tags.batch)
    ) {
      const open = this.batches.get(tags.batch)!;
      const line = params[params.length - 1] || "";
      open.lines.push(line);
      open.chars += line.length;
      // Too large for an envelope: drop the batch (its end is then ignored).
      if (open.lines.length > MAX_BATCH_LINES || open.chars > MAX_BATCH_CHARS) {
        this.batches.delete(tags.batch);
      }
      return true;
    }
    if (command === "PRIVMSG" && tags[TAG_TYPE]) {
      this.receiveEnvelope(
        tags,
        msg.nick,
        params[0] || "*status",
        params[1] || "",
      );
      return true;
    }
    return false;
  }

  private handleE2eeReply(params: string[]): void {
    const sub = (params[0] || "").toUpperCase();
    if (sub === "PUBLISHED") {
      if (this.prekeys && !this.prekeysUploaded) {
        const pubs = new Map<number, Uint8Array>();
        this.prekeys.oneTime.forEach((kp, id) => pubs.set(id, kp.publicKey));
        this.uploadPrekeysMap(pubs);
        this.prekeysUploaded = true;
        this.saveState();
      } else {
        this.cb.sendRaw(`E2EE PREKEYS ${this.deviceId}`);
      }
      this.cb.sendRaw(`E2EE BIND ${this.deviceId}`);
      return;
    }
    if (sub === "PREKEYS" && params.length >= 3) {
      const count = parseInt(params[2], 10);
      if (!Number.isNaN(count)) {
        this.serverPrekeyCount = count;
        this.cb.onStateChange();
        if (count < 10 && this.bound && !this.replenishing && this.prekeys) {
          this.replenishing = true;
          const added = this.prekeys.add(INITIAL_PREKEYS);
          this.uploadPrekeysMap(added);
          this.saveState();
          setTimeout(() => {
            this.replenishing = false;
          }, 2000);
        }
      }
      return;
    }
    if (sub === "BOUND") {
      this.bound = true;
      const queued = parseInt(params[2] || "0", 10) || 0;
      this.cb.onNotice(
        "*status",
        `E2EE active (device ${this.deviceId}${
          queued > 0 ? `, replaying ${queued} queued` : ""
        }).`,
        "sys",
      );
      this.cb.onStateChange();
      return;
    }
    if (sub === "BUNDLE" && this.activeFetch && params.length >= 6) {
      const [, account, devStr, ikStr, spkStr, sigStr, opkStr] = params;
      const spkColon = spkStr.indexOf(":");
      if (spkColon === -1) return;
      const bundle: PreKeyBundle = {
        account: ircFold(account),
        device: parseInt(devStr, 10),
        identity: fromB64(ikStr),
        spkId: parseInt(spkStr.slice(0, spkColon), 10),
        spk: fromB64(spkStr.slice(spkColon + 1)),
        signature: fromB64(sigStr),
        opkId: null,
        opk: null,
      };
      if (opkStr) {
        const opkColon = opkStr.indexOf(":");
        if (opkColon !== -1) {
          bundle.opkId = parseInt(opkStr.slice(0, opkColon), 10);
          bundle.opk = fromB64(opkStr.slice(opkColon + 1));
        }
      }
      this.activeFetch.bundles.push(bundle);
      return;
    }
    if (sub === "FETCHED" && this.activeFetch) {
      const req = this.activeFetch;
      clearTimeout(req.timer);
      this.activeFetch = null;
      req.resolve(req.bundles);
      this.pumpFetchQueue();
      return;
    }
    if (sub === "REMOVED") {
      this.cb.onNotice(
        "*status",
        `Removed E2EE device ${params[1] || ""}.`,
        "sys",
      );
    }
  }

  // ---- Receiving & Decrypting ----

  private receiveEnvelope(
    tags: Record<string, string>,
    senderNick: string,
    target: string,
    text: string,
  ): void {
    const qid = tags[TAG_QID];
    const src = tags[TAG_SRC] || "";
    const dst = tags[TAG_DST] || "";
    const kind = tags[TAG_TYPE] || "";
    const colon = src.lastIndexOf(":");
    if (colon <= 0) return;

    const srcAccount = ircFold(src.slice(0, colon));
    const srcDevice = parseInt(src.slice(colon + 1), 10);
    if (Number.isNaN(srcDevice) || srcDevice < 1) return;

    // Verify client-only e2ee-src account against the server-authenticated account tag
    // to prevent TOFU poisoning / sender spoofing.
    const serverAcct = ircFold(tags.account || "");
    if (serverAcct) {
      if (serverAcct !== srcAccount) {
        const dest = isChan(target) ? target : senderNick || serverAcct;
        this.cb.onNotice(
          dest,
          `[E2EE] Rejected spoofed sender tag: claimed ${srcAccount}, authenticated as ${serverAcct}.`,
          "err",
        );
        return;
      }
    } else if (this.accountTagEnabled && !qid) {
      const dest = isChan(target) ? target : senderNick || "*status";
      this.cb.onNotice(
        dest,
        `[E2EE] Rejected unauthenticated E2EE envelope claiming ${srcAccount}.`,
        "err",
      );
      return;
    }

    // Suppress echo-message of our own outbound encrypted envelopes
    if (
      srcAccount === ircFold(this.account) && srcDevice === this.deviceId
    ) {
      return;
    }
    if (senderNick) {
      this.rememberAccount(ircFold(senderNick), srcAccount);
    }

    try {
      if (kind === "sk" && isChan(target)) {
        this.receiveChannel(
          target,
          senderNick,
          srcAccount,
          srcDevice,
          text,
          tags.time,
          !!qid,
        );
      } else if (dst === String(this.deviceId)) {
        this.receivePairwise(
          senderNick,
          srcAccount,
          srcDevice,
          text,
          tags.time,
          !!qid,
        );
      } else {
        return; // envelope intended for another device of our account
      }
      if (qid) {
        this.cb.sendRaw(`E2EE ACK ${qid}`);
      }
    } catch (err) {
      const dest = isChan(target) ? target : senderNick || srcAccount;
      this.cb.onNotice(
        dest,
        `[E2EE] Could not decrypt message from ${senderNick || srcAccount}: ${
          errorMessage(err)
        }`,
        "err",
      );
    }
  }

  private pinIdentity(
    account: string,
    device: number,
    idKey: Uint8Array,
  ): void {
    const key = `${account}:${device}`;
    const existing = this.trusted.get(key);
    if (existing) {
      if (!bytesEqual(existing, idKey)) {
        throw new CryptoError(
          `Identity key CHANGED for ${account} (device ${device})! Verify safety number or reset in E2EE Keys.`,
        );
      }
    } else {
      this.trusted.set(key, new Uint8Array(idKey));
    }
  }

  private receivePairwise(
    senderNick: string,
    account: string,
    device: number,
    b64Text: string,
    time: string | undefined,
    queued: boolean,
  ): void {
    if (!this.identity || !this.prekeys) {
      throw new CryptoError("device not initialized");
    }
    const env = parseEnvelope(fromB64(b64Text));
    const key = `${account}:${device}`;
    let plaintext: Uint8Array | null = null;

    const existing = this.sessions.get(key);
    if (existing) {
      try {
        plaintext = existing.decrypt(env.ratchet);
      } catch (err) {
        if (env.kind !== "prekey") throw err;
      }
    }
    if (plaintext === null) {
      if (env.kind !== "prekey") {
        throw new CryptoError("no session for message envelope");
      }
      const resp = x3dhRespond(this.identity, this.prekeys, env.header);
      this.pinIdentity(account, device, resp.theirIdentity);
      const session = DoubleRatchet.responder(
        resp.shared,
        resp.ad,
        this.prekeys.spk,
      );
      plaintext = session.decrypt(env.ratchet);
      if (resp.opkId !== NO_OPK) {
        this.prekeys.oneTime.delete(resp.opkId);
      }
      this.sessions.set(key, session);
    }
    this.awaitingReply.delete(key);

    const payload = JSON.parse(dec.decode(plaintext)) as {
      t?: string;
      skd?: SenderKeyDistribution;
    };
    if (
      payload.skd && typeof payload.skd.channel === "string" &&
      isChan(payload.skd.channel)
    ) {
      const chanKey = ircFold(payload.skd.channel);
      this.storeReceivedKey(
        `${chanKey}|${key}`,
        key,
        SenderKey.fromDistribution(payload.skd),
      );
      this.saveState();
      this.cb.onStateChange();
      return;
    }
    this.saveState();
    this.cb.onStateChange();
    if (typeof payload.t === "string") {
      const dmTarget = senderNick || account;
      this.cb.onDecrypted({
        target: dmTarget,
        nick: dmTarget,
        account,
        device,
        text: payload.t,
        time,
        queued,
        isChannel: false,
      });
    }
  }

  private receiveChannel(
    channel: string,
    senderNick: string,
    account: string,
    device: number,
    b64Text: string,
    time: string | undefined,
    queued: boolean,
  ): void {
    const key = `${ircFold(channel)}|${account}:${device}`;
    const sk = this.receivedKeys.get(key);
    if (!sk) throw new CryptoError("missing sender key");
    const pt = sk.decrypt(fromB64(b64Text), channel);
    this.saveState();
    const payload = JSON.parse(dec.decode(pt)) as { t?: string };
    if (typeof payload.t === "string") {
      this.cb.onDecrypted({
        target: channel,
        nick: senderNick || account,
        account,
        device,
        text: payload.t,
        time,
        queued,
        isChannel: true,
      });
    }
  }

  // ---- Sending & Encrypting ----

  async sendEncrypted(target: string, text: string): Promise<boolean> {
    if (!this.isReady() || !this.identity) {
      this.cb.onNotice(
        target,
        "E2EE is not ready (requires SASL login and server E2EE support).",
        "err",
      );
      return false;
    }
    try {
      if (isChan(target)) {
        await this.sendChannel(target, text);
      } else {
        await this.sendPayload(target, { t: text });
      }
      return true;
    } catch (err) {
      this.cb.onNotice(
        target,
        `[E2EE] Send failed: ${errorMessage(err)}`,
        "err",
      );
      return false;
    }
  }

  private async sendChannel(channel: string, text: string): Promise<void> {
    const chanKey = ircFold(channel);
    if (!this.senderKeys.has(chanKey) || this.needsRotation.has(chanKey)) {
      this.senderKeys.set(chanKey, SenderKey.create());
      this.sharedWith.set(chanKey, new Set());
      this.needsRotation.delete(chanKey);
    }
    await this.distributeSenderKey(channel);
    // The keys may have been replaced while waiting (account switch, backup
    // import): then this send is abandoned rather than using a stale key.
    const sk = this.senderKeys.get(chanKey);
    if (!sk) {
      throw new CryptoError(
        "The channel key changed while sending; send again",
      );
    }
    const ct = sk.encrypt(enc.encode(JSON.stringify({ t: text })), channel);
    this.saveState();
    this.sendEnvelope(channel, null, ct, "sk");
  }

  private async distributeSenderKey(channel: string): Promise<void> {
    const chanKey = ircFold(channel);
    const sk = this.senderKeys.get(chanKey);
    if (!sk) return;
    let shared = this.sharedWith.get(chanKey);
    if (!shared) {
      shared = new Set();
      this.sharedWith.set(chanKey, shared);
    }
    const members = await this.queryChannelMembers(channel);
    const handover = { skd: sk.distribution(channel) };
    const seenAccounts = new Set<string>();
    for (const m of members) {
      if (ircFold(m.nick) === ircFold(this.myNick)) continue;
      if (m.account === ircFold(this.account)) continue;
      if (seenAccounts.has(m.account)) continue;
      seenAccounts.add(m.account);
      if (shared.has(m.account)) continue;
      try {
        await this.sendPayload(m.nick, handover, m.account);
        shared.add(m.account);
      } catch {
        // Member may not have E2EE devices published; continue for other members
      }
    }
    this.saveState();
  }

  private async sendPayload(
    targetNick: string,
    payload: Record<string, unknown>,
    knownAccount?: string,
  ): Promise<void> {
    if (!this.identity) throw new CryptoError("device not initialized");
    let account = (knownAccount && ircFold(knownAccount)) ||
      this.nickToAccount.get(ircFold(targetNick));
    let devices = account ? this.sessionDevicesFor(account) : [];

    if (!account || devices.length === 0) {
      const bundles = await this.fetchBundles(account || targetNick);
      if (bundles.length === 0) {
        throw new Error(`No E2EE devices published for ${targetNick}`);
      }
      account = bundles[0].account;
      this.rememberAccount(ircFold(targetNick), account);
      for (const b of bundles) {
        this.pinIdentity(b.account, b.device, b.identity);
        const key = `${b.account}:${b.device}`;
        if (!this.sessions.has(key)) {
          const { shared, ad, header } = x3dhInitiate(this.identity, b);
          this.sessions.set(key, DoubleRatchet.initiator(shared, ad, b.spk));
          this.awaitingReply.set(key, header);
        }
      }
      devices = this.sessionDevicesFor(account);
    }

    const ptBytes = enc.encode(JSON.stringify(payload));
    for (const dev of devices) {
      const key = `${account}:${dev}`;
      const ratchet = this.sessions.get(key);
      // Sessions replaced while waiting for bundles: skip this device.
      if (!ratchet) continue;
      const msg = ratchet.encrypt(ptBytes);
      const preHeader = this.awaitingReply.get(key);
      if (preHeader) {
        this.sendEnvelope(
          targetNick,
          dev,
          prekeyEnvelope(preHeader, msg),
          "prekey",
        );
      } else {
        this.sendEnvelope(targetNick, dev, messageEnvelope(msg), "msg");
      }
    }
    this.saveState();
    this.cb.onStateChange();
  }

  private sessionDevicesFor(account: string): number[] {
    const prefix = `${ircFold(account)}:`;
    const devs: number[] = [];
    this.sessions.forEach((_, key) => {
      if (key.startsWith(prefix)) {
        const d = parseInt(key.slice(prefix.length), 10);
        if (!Number.isNaN(d)) devs.push(d);
      }
    });
    devs.sort((a, b) => a - b);
    return devs;
  }

  private sendEnvelope(
    target: string,
    dstDevice: number | null,
    envelope: Uint8Array,
    kind: "prekey" | "msg" | "sk",
  ): void {
    const text = toB64(envelope);
    const tags: Record<string, string | null> = {
      [TAG_SRC]: `${this.account}:${this.deviceId}`,
      [TAG_TYPE]: kind,
    };
    if (dstDevice !== null) tags[TAG_DST] = String(dstDevice);

    if (text.length <= CHUNK) {
      this.cb.sendRaw(`${formatTags(tags)}PRIVMSG ${target} :${text}`);
      return;
    }
    const ref = `e2ee${this.batchSeq++}`;
    this.cb.sendRaw(
      `${formatTags(tags)}BATCH +${ref} draft/multiline ${target}`,
    );
    for (let i = 0; i < text.length; i += CHUNK) {
      const lineTags: Record<string, string | null> = { batch: ref };
      if (i > 0) lineTags["draft/multiline-concat"] = null;
      this.cb.sendRaw(
        `${formatTags(lineTags)}PRIVMSG ${target} :${text.slice(i, i + CHUNK)}`,
      );
    }
    this.cb.sendRaw(`BATCH -${ref}`);
  }

  // ---- Async IRC queries (FETCH & WHOX) ----

  private fetchBundles(target: string): Promise<PreKeyBundle[]> {
    return new Promise((resolve, reject) => {
      this.fetchQueue.push({ target, resolve, reject });
      this.pumpFetchQueue();
    });
  }

  private pumpFetchQueue(): void {
    if (this.activeFetch || this.fetchQueue.length === 0) return;
    const next = this.fetchQueue.shift()!;
    const timer = setTimeout(() => {
      if (this.activeFetch && this.activeFetch.resolve === next.resolve) {
        this.activeFetch = null;
        next.reject(
          new Error(`Timed out fetching E2EE keys for ${next.target}`),
        );
        this.pumpFetchQueue();
      }
    }, 10000);

    this.activeFetch = {
      target: next.target,
      bundles: [],
      resolve: next.resolve,
      reject: next.reject,
      timer,
    };
    this.cb.sendRaw(`E2EE FETCH ${next.target}`);
  }

  private queryChannelMembers(
    channel: string,
  ): Promise<Array<{ nick: string; account: string }>> {
    return new Promise((resolve) => {
      const token = String(this.whoSeq);
      this.whoSeq = this.whoSeq >= 99 ? 42 : this.whoSeq + 1;
      const timer = setTimeout(() => {
        const req = this.activeWho.get(token);
        if (req) {
          this.activeWho.delete(token);
          req.resolve(req.found);
        }
      }, 6000);

      this.activeWho.set(token, {
        channel: ircFold(channel),
        token,
        found: [],
        resolve,
        timer,
      });
      this.cb.sendRaw(`WHO ${channel} %tna,${token}`);
    });
  }
}
