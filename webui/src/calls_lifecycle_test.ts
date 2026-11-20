/// <reference lib="deno.ns" />
// Resource cleanup across the call lifecycle, with a fake microphone and a
// fake RTCPeerConnection: every way a call ends must stop the microphone
// tracks, close the peer connection, and detach the remote audio.
import { CallManager } from "./calls.ts";
import {
  type CallAudioSettings,
  DEFAULT_CALL_SETTINGS,
} from "./call_settings.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

class FakeTrack {
  kind = "audio";
  enabled = true;
  stopped = false;
  stop() {
    this.stopped = true;
  }
}

class FakeStream {
  constructor(public tracks: FakeTrack[]) {}
  getTracks() {
    return this.tracks;
  }
  getAudioTracks() {
    return this.tracks;
  }
}

class FakeSender {
  constructor(public track: FakeTrack | null) {}
  params: { encodings: Array<{ maxBitrate?: number }> } = { encodings: [{}] };
  getParameters() {
    return { encodings: this.params.encodings.map((e) => ({ ...e })) };
  }
  setParameters(p: { encodings: Array<{ maxBitrate?: number }> }) {
    this.params = p;
    return Promise.resolve();
  }
  replaceTrack(t: FakeTrack) {
    this.track = t;
    return Promise.resolve();
  }
}

class Deferred<T> {
  resolve!: (v: T) => void;
  reject!: (e: unknown) => void;
  promise = new Promise<T>((res, rej) => {
    this.resolve = res;
    this.reject = rej;
  });
}

class FakePC {
  static all: FakePC[] = [];
  /** When set, the next setRemoteDescription waits on this. */
  static remoteGate: Deferred<void> | null = null;
  closed = false;
  connectionState = "new";
  iceGatheringState = "complete";
  localDescription: { type: string; sdp: string } | null = null;
  senders: FakeSender[] = [];
  ontrack: ((ev: unknown) => void) | null = null;
  onconnectionstatechange: (() => void) | null = null;
  constructor() {
    FakePC.all.push(this);
  }
  addTrack(t: FakeTrack) {
    const s = new FakeSender(t);
    this.senders.push(s);
    return s;
  }
  getSenders() {
    return this.senders;
  }
  createOffer() {
    return Promise.resolve({ type: "offer", sdp: SDP });
  }
  createAnswer() {
    return Promise.resolve({ type: "answer", sdp: SDP });
  }
  setLocalDescription(d: { type: string; sdp: string }) {
    this.localDescription = d;
    return Promise.resolve();
  }
  setRemoteDescription() {
    const gate = FakePC.remoteGate;
    FakePC.remoteGate = null;
    if (gate) return gate.promise;
    return this.closed
      ? Promise.reject(new Error("closed"))
      : Promise.resolve();
  }
  addEventListener() {}
  removeEventListener() {}
  close() {
    this.closed = true;
    this.connectionState = "closed";
  }
  connect() {
    this.connectionState = "connected";
    this.onconnectionstatechange?.();
  }
}

const SDP = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=x\r\n";
const tracks: FakeTrack[] = [];
let micGate: Deferred<void> | null = null;

async function getUserMedia() {
  const gate = micGate;
  micGate = null;
  if (gate) await gate.promise;
  const t = new FakeTrack();
  tracks.push(t);
  return new FakeStream([t]);
}

/** Install the fakes for one test and restore the globals afterwards. */
async function withFakes(fn: () => Promise<void>): Promise<void> {
  const g = globalThis as unknown as Record<string, unknown>;
  const nav = navigator as unknown as Record<string, unknown>;
  const hadPc = g.RTCPeerConnection;
  const hadMd = Object.getOwnPropertyDescriptor(nav, "mediaDevices");
  g.RTCPeerConnection = FakePC;
  Object.defineProperty(nav, "mediaDevices", {
    configurable: true,
    value: { getUserMedia },
  });
  FakePC.all = [];
  FakePC.remoteGate = null;
  tracks.length = 0;
  micGate = null;
  try {
    await fn();
  } finally {
    g.RTCPeerConnection = hadPc;
    if (hadMd) Object.defineProperty(nav, "mediaDevices", hadMd);
    else delete nav.mediaDevices;
  }
}

function setup(settings: Partial<CallAudioSettings> = {}) {
  const sent: string[] = [];
  const audio = {
    srcObject: null as unknown,
    play: () => Promise.resolve(),
  } as unknown as HTMLAudioElement;
  let current: CallAudioSettings = { ...DEFAULT_CALL_SETTINGS, ...settings };
  const music: Array<{ track: FakeTrack; stopped: boolean }> = [];
  const calls = new CallManager({
    send: (l) => sent.push(l),
    onChange: () => {},
    onEnded: () => {},
    remoteAudio: () => audio,
    audio: () => current,
    holdSource: () => {
      const m = { track: new FakeTrack(), stopped: false };
      music.push(m);
      return {
        track: m.track as unknown as MediaStreamTrack,
        stop: () => {
          m.stopped = true;
          m.track.stop();
        },
      };
    },
  });
  calls.enabled = true;
  calls.holdSupported = true;
  const change = (patch: Partial<CallAudioSettings>) => {
    const previous = current;
    current = { ...current, ...patch };
    return calls.applyAudioSettings(previous);
  };
  return { calls, sent, audio, change, music };
}

function chunks(kind: string, token: string): string[][] {
  return [[kind, "me", token, "1", "1", btoa(SDP)]];
}

const flush = () => new Promise((r) => setTimeout(r, 0));

/** Start an outgoing call to bob and bring it to `active`. */
async function activeCall(calls: CallManager): Promise<string> {
  await calls.call("bob");
  const token = calls.state.token;
  for (const p of chunks("ANSWER", token)) calls.handle("bob", p);
  await flush();
  FakePC.all[0].connect();
  assert(calls.state.phase === "active", "call is active");
  return token;
}

function assertReleased(audio: HTMLAudioElement, calls: CallManager): void {
  assert(calls.state.phase === "idle", "idle");
  assert(tracks.length > 0, "a microphone track was opened");
  assert(tracks.every((t) => t.stopped), "every microphone track stopped");
  assert(FakePC.all.every((pc) => pc.closed), "peer connection closed");
  assert(audio.srcObject === null, "remote audio detached");
}

Deno.test("local hangup releases microphone, connection, and audio", async () => {
  await withFakes(async () => {
    const { calls, sent, audio } = setup({ bitrate: 32 });
    const token = await activeCall(calls);
    const enc = FakePC.all[0].senders[0].params.encodings[0];
    assert(enc.maxBitrate === 32000, "bitrate cap applied");
    calls.hangup();
    assert(sent.includes(`CALL HANGUP bob ${token} :normal`), "hangup sent");
    assertReleased(audio, calls);
  });
});

Deno.test("hangup from the other side releases everything", async () => {
  await withFakes(async () => {
    const { calls, audio } = setup();
    const token = await activeCall(calls);
    calls.handle("bob", ["HANGUP", "me", token, "normal"]);
    assertReleased(audio, calls);
  });
});

Deno.test("disconnect while connected releases everything", async () => {
  await withFakes(async () => {
    const { calls, audio } = setup();
    await activeCall(calls);
    calls.reset();
    assertReleased(audio, calls);
  });
});

Deno.test("accepted incoming call is released on hangup", async () => {
  await withFakes(async () => {
    const { calls, sent, audio } = setup();
    for (const p of chunks("OFFER", "incoming1")) calls.handle("alice", p);
    await calls.accept();
    assert(sent.some((l) => l.startsWith("CALL ANSWER alice")), "answered");
    FakePC.all[0].connect();
    calls.handle("alice", ["HANGUP", "me", "incoming1", "normal"]);
    assertReleased(audio, calls);
  });
});

Deno.test("hanging up while the answer is applied sends one hangup", async () => {
  await withFakes(async () => {
    const { calls, sent, audio } = setup();
    await calls.call("bob");
    const token = calls.state.token;
    const gate = new Deferred<void>();
    FakePC.remoteGate = gate;
    for (const p of chunks("ANSWER", token)) calls.handle("bob", p);
    calls.hangup();
    gate.reject(new Error("closed"));
    await flush();
    const hangups = sent.filter((l) => l.startsWith("CALL HANGUP"));
    assert(hangups.length === 1, `one hangup, got ${JSON.stringify(hangups)}`);
    assert(!sent.some((l) => l.startsWith("CALL HANGUP  ")), "no empty nick");
    assertReleased(audio, calls);
  });
});

Deno.test("switching microphone mid-call replaces and stops the old track", async () => {
  await withFakes(async () => {
    const { calls, change, audio } = setup();
    await activeCall(calls);
    calls.toggleMute();
    await change({ inputId: "usb-mic" });
    const sender = FakePC.all[0].senders[0];
    assert(tracks.length === 2, "second track opened");
    assert(tracks[0].stopped, "old track stopped");
    assert(sender.track === tracks[1], "sender uses the new track");
    assert(!tracks[1].enabled, "mute carried over");
    await change({ bitrate: 64 });
    assert(sender.params.encodings[0].maxBitrate === 64000, "bitrate updated");
    calls.hangup();
    assertReleased(audio, calls);
  });
});

Deno.test("a microphone switch that finishes after hangup is released", async () => {
  await withFakes(async () => {
    const { calls, change, audio } = setup();
    await activeCall(calls);
    const gate = new Deferred<void>();
    micGate = gate;
    const switching = change({ inputId: "usb-mic" });
    calls.hangup();
    gate.resolve();
    await switching;
    assert(tracks.length === 2, "late track was opened");
    assertReleased(audio, calls);
  });
});

Deno.test("only the newest of two quick switches is kept", async () => {
  await withFakes(async () => {
    const { calls, change } = setup();
    await activeCall(calls);
    const slow = new Deferred<void>();
    micGate = slow;
    const first = change({ inputId: "mic-a" });
    const second = change({ inputId: "mic-b" });
    await second;
    slow.resolve();
    await first;
    const sender = FakePC.all[0].senders[0];
    // tracks[1] is the second switch (it resolved first); tracks[2] is the
    // first switch, which resolved late and must be discarded.
    assert(tracks.length === 3, "three tracks opened");
    assert(sender.track === tracks[1], "newest switch wins");
    assert(tracks[2].stopped, "superseded track stopped");
    calls.hangup();
  });
});

Deno.test("hold sends music instead of the microphone; resume restores it", async () => {
  await withFakes(async () => {
    const { calls, sent, audio, music } = setup();
    const token = await activeCall(calls);
    const sender = FakePC.all[0].senders[0];
    const mic = tracks[0];
    calls.toggleMute(); // mute survives hold and resume
    await calls.toggleHold();
    assert(calls.state.held, "held");
    assert(sent.includes(`CALL HOLD bob ${token}`), "HOLD sent");
    assert(sender.track === (music[0].track as unknown), "music on sender");
    assert(audio.muted === true, "other side muted while held");
    assert(!mic.stopped, "microphone kept for resume");
    await calls.toggleHold();
    assert(!calls.state.held, "resumed");
    assert(sent.includes(`CALL RESUME bob ${token}`), "RESUME sent");
    assert(sender.track === mic, "microphone back on sender");
    assert(!mic.enabled, "still muted");
    assert(music[0].stopped, "music released on resume");
    assert(audio.muted === false, "other side audible again");
    calls.hangup();
    assertReleased(audio, calls);
  });
});

Deno.test("hanging up while on hold releases the hold music", async () => {
  await withFakes(async () => {
    const { calls, audio, music } = setup();
    const token = await activeCall(calls);
    await calls.toggleHold();
    calls.handle("bob", ["HANGUP", "me", token, "normal"]);
    assert(music[0].stopped, "music stopped");
    assert(audio.muted === false, "audio element unmuted for the next call");
    assertReleased(audio, calls);
  });
});

Deno.test("switching microphone on hold keeps the music until resume", async () => {
  await withFakes(async () => {
    const { calls, change, music } = setup();
    await activeCall(calls);
    await calls.toggleHold();
    await change({ inputId: "usb-mic" });
    const sender = FakePC.all[0].senders[0];
    assert(sender.track === (music[0].track as unknown), "music still sent");
    assert(tracks[0].stopped, "old microphone released");
    await calls.toggleHold();
    assert(sender.track === tracks[1], "new microphone sent after resume");
    calls.hangup();
  });
});

Deno.test("hold from the other side is shown, and only while active", async () => {
  await withFakes(async () => {
    const { calls } = setup();
    for (const p of chunks("OFFER", "incoming3")) calls.handle("alice", p);
    calls.handle("alice", ["HOLD", "me", "incoming3"]);
    assert(!calls.state.remoteHeld, "ignored before the call is active");
    calls.decline();
    const token = await activeCall(calls);
    calls.handle("bob", ["HOLD", "me", "othertoken1"]);
    assert(!calls.state.remoteHeld, "other token ignored");
    calls.handle("bob", ["HOLD", "me", token]);
    assert(calls.state.remoteHeld, "remote hold shown");
    calls.handle("bob", ["RESUME", "me", token]);
    assert(!calls.state.remoteHeld, "remote resume shown");
    calls.hangup();
  });
});

Deno.test("hold works locally when the server cannot relay it", async () => {
  await withFakes(async () => {
    const { calls, sent, music } = setup();
    calls.holdSupported = false;
    await activeCall(calls);
    await calls.toggleHold();
    assert(calls.state.held, "held");
    assert(!sent.some((l) => l.startsWith("CALL HOLD")), "no HOLD line");
    assert(music.length === 1, "music still sent");
    calls.hangup();
  });
});
