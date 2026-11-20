// User-to-user voice calls over the `egorsmkv.github.io/calls` capability.
//
// Signalling travels as IRC `CALL` lines; the server relays each session
// description through rtpengine, so media goes browser → rtpengine → browser.
// Descriptions are complete (ICE gathering finishes before sending) and travel
// base64-encoded in numbered chunks:
//   CALL OFFER|ANSWER <nick> <token> <part> <total> :<chunk>
//   CALL RINGING|REJECT|HANGUP <nick> <token> [:<reason>]

import {
  audioConstraints,
  type CallAudioSettings,
  DEFAULT_CALL_SETTINGS,
  needsNewTrack,
} from "./call_settings.ts";

export const CALLS_CAP = "egorsmkv.github.io/calls";

const CHUNK = 400;
const MAX_PARTS = 40;
const GATHER_TIMEOUT_MS = 3000;
const TOKEN_RE = /^[A-Za-z0-9]{8,32}$/;

export type CallPhase =
  | "idle"
  | "calling" // offer sent, waiting for the callee's client
  | "ringing" // callee's client is ringing
  | "incoming" // we are being called
  | "connecting" // descriptions exchanged, ICE/DTLS in progress
  | "active";

export interface CallView {
  phase: CallPhase;
  peer: string;
  token: string;
  outgoing: boolean;
  muted: boolean;
  /** `performance.now()` when media connected; 0 before. */
  connectedAt: number;
}

export interface CallHooks {
  send(line: string): void;
  /** Called on every state change; `view.phase === "idle"` means no call. */
  onChange(view: CallView): void;
  /** A finished or failed call, for a line in the peer's conversation. */
  onEnded(peer: string, summary: string): void;
  remoteAudio(): HTMLAudioElement;
  /** Current audio preferences (devices, processing, bitrate, ring sound). */
  audio?(): CallAudioSettings;
}

interface Assembly {
  kind: string;
  total: number;
  parts: string[];
}

/** The call ended while the microphone prompt or ICE gathering was pending. */
class Cancelled extends Error {}

function randomToken(): string {
  const alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
}

function fmtDuration(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const m = Math.floor(s / 60);
  const h = Math.floor(m / 60);
  const mm = String(m % 60).padStart(h ? 2 : 1, "0");
  const ss = String(s % 60).padStart(2, "0");
  return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

export function callDuration(view: CallView): string {
  return view.connectedAt
    ? fmtDuration(performance.now() - view.connectedAt)
    : "";
}

const REASON_TEXT: Record<string, string> = {
  "normal": "Call ended",
  "declined": "Call declined",
  "busy": "Line busy",
  "no-answer": "No answer",
  "disconnected": "The other side disconnected",
  "max-duration": "Call time limit reached",
  "media-error": "Call failed (media error)",
  "failed": "Call failed (connection lost)",
  "cancelled": "Call cancelled",
};

function reasonText(reason: string): string {
  return REASON_TEXT[reason] || "Call ended";
}

/** Wait until ICE gathering completes (or a timeout), so the SDP is complete. */
function gathered(pc: RTCPeerConnection): Promise<void> {
  if (pc.iceGatheringState === "complete") return Promise.resolve();
  return new Promise((resolve) => {
    const done = () => {
      pc.removeEventListener("icegatheringstatechange", check);
      clearTimeout(timer);
      resolve();
    };
    const check = () => {
      if (pc.iceGatheringState === "complete") done();
    };
    const timer = setTimeout(done, GATHER_TIMEOUT_MS);
    pc.addEventListener("icegatheringstatechange", check);
  });
}

export class CallManager {
  private hooks: CallHooks;
  private view: CallView = {
    phase: "idle",
    peer: "",
    token: "",
    outgoing: false,
    muted: false,
    connectedAt: 0,
  };
  private pc: RTCPeerConnection | null = null;
  private stream: MediaStream | null = null;
  private remoteOffer = "";
  private assemblies = new Map<string, Assembly>();
  private tone: Tone | null = null;
  /** Bumped per microphone switch, so only the newest switch takes effect. */
  private trackGen = 0;
  enabled = false;

  constructor(hooks: CallHooks) {
    this.hooks = hooks;
  }

  get state(): CallView {
    return { ...this.view };
  }

  get busy(): boolean {
    return this.view.phase !== "idle";
  }

  /** Start a call to `nick`. Throws when the microphone is unavailable. */
  async call(nick: string): Promise<void> {
    if (!this.enabled || this.busy || !nick) return;
    const token = randomToken();
    this.set({ phase: "calling", peer: nick, token, outgoing: true });
    try {
      const pc = await this.preparePeer(token);
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await this.applyBitrate(pc);
      await gathered(pc);
      if (this.view.token !== token) return; // cancelled meanwhile
      this.sendSdp("OFFER", nick, token, pc.localDescription?.sdp || "");
    } catch (err) {
      if (err instanceof Cancelled || this.view.token !== token) return;
      this.finish(nick, `Call failed: ${errorText(err)}`);
      throw err;
    }
  }

  /** Accept the ringing incoming call. */
  async accept(): Promise<void> {
    if (this.view.phase !== "incoming") return;
    const { peer, token } = this.view;
    this.stopTone();
    this.set({ phase: "connecting" });
    try {
      const pc = await this.preparePeer(token);
      await pc.setRemoteDescription({ type: "offer", sdp: this.remoteOffer });
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await this.applyBitrate(pc);
      await gathered(pc);
      if (this.view.token !== token) return;
      this.sendSdp("ANSWER", peer, token, pc.localDescription?.sdp || "");
    } catch (err) {
      if (err instanceof Cancelled || this.view.token !== token) return;
      this.hooks.send(`CALL HANGUP ${peer} ${token} :failed`);
      this.finish(peer, `Call failed: ${errorText(err)}`);
    }
  }

  decline(): void {
    if (this.view.phase !== "incoming") return;
    const { peer, token } = this.view;
    this.hooks.send(`CALL REJECT ${peer} ${token} :declined`);
    this.finish(peer, `Declined a call from ${peer}`);
  }

  /** Hang up (or cancel an outgoing call). */
  hangup(): void {
    if (!this.busy) return;
    if (this.view.phase === "incoming") return this.decline();
    const { peer, token, phase } = this.view;
    const cancelled = phase === "calling" || phase === "ringing";
    this.hooks.send(
      `CALL HANGUP ${peer} ${token} :${cancelled ? "cancelled" : "normal"}`,
    );
    this.finish(
      peer,
      cancelled ? "Call cancelled" : this.endedText("Call ended"),
    );
  }

  toggleMute(): void {
    if (!this.stream) return;
    const muted = !this.view.muted;
    for (const track of this.stream.getAudioTracks()) track.enabled = !muted;
    this.set({ muted });
  }

  /**
   * Apply changed audio preferences to a call in progress: a new microphone
   * track (device or processing changed) replaces the sent one without
   * renegotiation, and the bitrate is updated. `previous` is what the call
   * was using. Playback device and volume belong to the audio element.
   */
  async applyAudioSettings(previous: CallAudioSettings): Promise<void> {
    const pc = this.pc;
    const token = this.view.token;
    if (!pc || !this.stream) return;
    const next = this.settings();
    if (needsNewTrack(previous, next)) {
      const sender = pc.getSenders().find((x) => x.track?.kind === "audio");
      if (!sender) return;
      const gen = ++this.trackGen;
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: audioConstraints(next),
        video: false,
      });
      // The call ended or a newer change started while the device opened.
      if (
        this.pc !== pc || this.view.token !== token || gen !== this.trackGen
      ) {
        for (const t of stream.getTracks()) t.stop();
        return;
      }
      const track = stream.getAudioTracks()[0];
      if (!track) {
        for (const t of stream.getTracks()) t.stop();
        return;
      }
      track.enabled = !this.view.muted;
      try {
        await sender.replaceTrack(track);
      } catch (err) {
        for (const t of stream.getTracks()) t.stop();
        throw err;
      }
      // finish() may have run during replaceTrack and released this.stream;
      // the new stream must not outlive the call.
      if (this.pc !== pc || gen !== this.trackGen) {
        for (const t of stream.getTracks()) t.stop();
        return;
      }
      const old = this.stream;
      this.stream = stream;
      for (const t of old?.getTracks() ?? []) t.stop();
    }
    if (previous.bitrate !== next.bitrate) await this.applyBitrate(pc);
  }

  /** The IRC connection went away: drop any call without signalling. */
  reset(): void {
    if (this.busy) this.finish(this.view.peer, "Call ended (disconnected)");
    this.assemblies.clear();
  }

  /**
   * Handle a `CALL` line. `from` is the sender's nick (empty for the
   * server). Returns true when the line was a call message.
   */
  handle(from: string, params: string[]): boolean {
    const sub = (params[0] || "").toUpperCase();
    const token = params[2] || "";
    if (!TOKEN_RE.test(token)) return true;
    switch (sub) {
      case "OFFER":
      case "ANSWER": {
        const sdp = this.collect(sub, token, params[3], params[4], params[5]);
        if (sdp === null) return true;
        if (sub === "OFFER") this.onOffer(from, token, sdp);
        else void this.onAnswer(token, sdp);
        return true;
      }
      case "RINGING":
        if (this.view.token === token && this.view.phase === "calling") {
          this.set({ phase: "ringing" });
          this.startTone("ringback");
        }
        return true;
      case "REJECT":
        if (this.view.token === token) {
          const reason = params[3] || "declined";
          this.finish(this.view.peer, reasonText(reason));
        }
        return true;
      case "HANGUP":
        if (this.view.token === token) {
          const reason = params[3] || "normal";
          const missed = this.view.phase === "incoming";
          const text = missed
            ? `Missed call from ${this.view.peer}`
            : this.endedText(reasonText(reason));
          this.finish(this.view.peer, text);
        }
        return true;
      default:
        return true;
    }
  }

  /** A `FAIL CALL <code> <token> :text` reply. */
  handleFail(code: string, token: string, text: string): void {
    if (token && token !== this.view.token) return;
    if (!this.busy) return;
    const friendly: Record<string, string> = {
      TARGET_BUSY: "is busy or unavailable",
      TARGET_UNSUPPORTED: "uses a client without voice calls",
      TARGET_REMOTE: "is on another server; calls work only on this server",
      NO_SUCH_NICK: "is not online",
      MEDIA_ERROR: "could not be reached: the media relay is unavailable",
      RATE_LIMITED: "could not be called: too many calls, try later",
      LIMIT_REACHED: "could not be called: the server is at its call limit",
      ACCOUNT_REQUIRED: "could not be called: log in to make calls",
    };
    const peer = this.view.peer;
    const reason = friendly[code]
      ? `${peer} ${friendly[code]}`
      : `Call failed: ${text || code}`;
    this.finish(peer, reason);
  }

  // --- internals -----------------------------------------------------------

  private onOffer(from: string, token: string, sdp: string): void {
    if (!from) return;
    if (this.busy) {
      this.hooks.send(`CALL REJECT ${from} ${token} :busy`);
      this.hooks.onEnded(from, `Missed call from ${from} (you were busy)`);
      return;
    }
    this.remoteOffer = sdp;
    this.set({ phase: "incoming", peer: from, token, outgoing: false });
    this.hooks.send(`CALL RINGING ${from} ${token}`);
    this.startTone("ring");
  }

  private async onAnswer(token: string, sdp: string): Promise<void> {
    if (!this.pc || this.view.token !== token) return;
    if (this.view.phase !== "calling" && this.view.phase !== "ringing") return;
    this.stopTone();
    this.set({ phase: "connecting" });
    try {
      await this.pc.setRemoteDescription({ type: "answer", sdp });
    } catch (err) {
      // Hung up meanwhile: closing the connection rejected the call; the
      // call is already finished and must not be signalled again.
      if (this.view.token !== token) return;
      const { peer } = this.view;
      this.hooks.send(`CALL HANGUP ${peer} ${token} :failed`);
      this.finish(peer, `Call failed: ${errorText(err)}`);
    }
  }

  private collect(
    kind: string,
    token: string,
    partStr: string | undefined,
    totalStr: string | undefined,
    chunk: string | undefined,
  ): string | null {
    const part = Number(partStr);
    const total = Number(totalStr);
    if (
      !Number.isInteger(part) || !Number.isInteger(total) || total < 1 ||
      total > MAX_PARTS || part < 1 || part > total || !chunk ||
      chunk.length > CHUNK
    ) {
      return null;
    }
    const key = `${kind}:${token}`;
    let asm = this.assemblies.get(key);
    if (part === 1) {
      asm = { kind, total, parts: [] };
      this.assemblies.set(key, asm);
      // Keep at most a handful of partial descriptions.
      while (this.assemblies.size > 4) {
        const first = this.assemblies.keys().next().value;
        if (first === undefined || first === key) break;
        this.assemblies.delete(first);
      }
    }
    if (!asm || asm.total !== total || asm.parts.length !== part - 1) {
      this.assemblies.delete(key);
      return null;
    }
    asm.parts.push(chunk);
    if (asm.parts.length < total) return null;
    this.assemblies.delete(key);
    try {
      return atob(asm.parts.join(""));
    } catch {
      return null;
    }
  }

  private sendSdp(
    kind: string,
    nick: string,
    token: string,
    sdp: string,
  ): void {
    const b64 = btoa(sdp);
    const chunks: string[] = [];
    for (let i = 0; i < b64.length; i += CHUNK) {
      chunks.push(b64.slice(i, i + CHUNK));
    }
    if (chunks.length === 0 || chunks.length > MAX_PARTS) {
      throw new Error("session description too large");
    }
    chunks.forEach((c, i) =>
      this.hooks.send(
        `CALL ${kind} ${nick} ${token} ${i + 1} ${chunks.length} :${c}`,
      )
    );
  }

  /**
   * Open the microphone and a peer connection for the call `token`. If the
   * call ends while the permission prompt is open, the new stream is stopped
   * at once (so the microphone is not left on) and `Cancelled` is thrown.
   */
  private async preparePeer(token: string): Promise<RTCPeerConnection> {
    if (!navigator.mediaDevices?.getUserMedia) {
      throw new Error("this browser cannot record audio (HTTPS is required)");
    }
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: audioConstraints(this.settings()),
      video: false,
    });
    if (this.view.token !== token) {
      for (const t of stream.getTracks()) t.stop();
      throw new Cancelled("call ended");
    }
    this.stream = stream;
    // rtpengine terminates ICE and DTLS on each leg; no STUN/TURN is needed.
    // The bundle policy stays at the default ("balanced"): rtpengine 12 drops
    // the `a=group:BUNDLE` line when it rewrites a description, and browsers
    // refuse a remote offer without one under "max-bundle". With a single
    // audio m-line, bundling changes nothing on the wire.
    const pc = new RTCPeerConnection({
      iceServers: [],
      rtcpMuxPolicy: "require",
    });
    for (const track of this.stream.getTracks()) {
      pc.addTrack(track, this.stream);
    }
    pc.ontrack = (ev) => {
      const audio = this.hooks.remoteAudio();
      audio.srcObject = ev.streams[0] || new MediaStream([ev.track]);
      void audio.play().catch(() => {});
    };
    pc.onconnectionstatechange = () => {
      if (pc !== this.pc) return;
      if (pc.connectionState === "connected" && this.view.phase !== "active") {
        this.set({ phase: "active", connectedAt: performance.now() });
      } else if (pc.connectionState === "failed") {
        const { peer, token } = this.view;
        this.hooks.send(`CALL HANGUP ${peer} ${token} :failed`);
        this.finish(peer, this.endedText(reasonText("failed")));
      }
    };
    this.pc = pc;
    return pc;
  }

  private settings(): CallAudioSettings {
    return this.hooks.audio?.() ?? DEFAULT_CALL_SETTINGS;
  }

  /**
   * Cap the Opus send bitrate (RTCRtpSender parameters, no renegotiation).
   * 0 removes the cap. Unsupported browsers keep their default.
   */
  private async applyBitrate(pc: RTCPeerConnection): Promise<void> {
    const kbps = this.settings().bitrate;
    for (const sender of pc.getSenders()) {
      if (sender.track?.kind !== "audio") continue;
      try {
        const params = sender.getParameters();
        if (!params.encodings || params.encodings.length === 0) {
          if (!kbps) continue;
          params.encodings = [{}];
        }
        for (const enc of params.encodings) {
          if (kbps) enc.maxBitrate = kbps * 1000;
          else delete enc.maxBitrate;
        }
        await sender.setParameters(params);
      } catch {
        // Not supported here or the connection closed: keep the default.
      }
    }
  }

  private endedText(base: string): string {
    const d = callDuration(this.view);
    return d ? `${base} (${d})` : base;
  }

  private finish(peer: string, summary: string): void {
    this.stopTone();
    if (this.pc) {
      this.pc.onconnectionstatechange = null;
      this.pc.ontrack = null;
      this.pc.close();
      this.pc = null;
    }
    if (this.stream) {
      for (const t of this.stream.getTracks()) t.stop();
      this.stream = null;
    }
    const audio = this.hooks.remoteAudio();
    audio.srcObject = null;
    this.remoteOffer = "";
    this.view = {
      phase: "idle",
      peer: "",
      token: "",
      outgoing: false,
      muted: false,
      connectedAt: 0,
    };
    this.hooks.onChange(this.state);
    if (peer) this.hooks.onEnded(peer, summary);
  }

  private set(patch: Partial<CallView>): void {
    this.view = { ...this.view, ...patch };
    this.hooks.onChange(this.state);
  }

  private startTone(kind: "ring" | "ringback"): void {
    this.stopTone();
    const s = this.settings();
    if (kind === "ring" && !s.ringtone) return;
    this.tone = new Tone(kind, s.outputId);
  }

  private stopTone(): void {
    this.tone?.stop();
    this.tone = null;
  }
}

function errorText(err: unknown): string {
  if (err instanceof DOMException && err.name === "NotAllowedError") {
    return "microphone permission denied";
  }
  if (err instanceof DOMException && err.name === "NotFoundError") {
    return "no microphone found";
  }
  return err instanceof Error ? err.message : String(err);
}

/** Generated ring (incoming) and ringback (outgoing) tones; no audio files. */
class Tone {
  private ctx: AudioContext | null = null;
  private timer: number | null = null;

  constructor(kind: "ring" | "ringback", outputId = "") {
    try {
      this.ctx = new AudioContext();
    } catch {
      return;
    }
    // Ring on the chosen speakers where AudioContext.setSinkId exists.
    const sink = this.ctx as AudioContext & {
      setSinkId?: (id: string) => Promise<void>;
    };
    if (outputId && sink.setSinkId) {
      void sink.setSinkId(outputId).catch(() => {});
    }
    const play = () => {
      const ctx = this.ctx;
      if (!ctx) return;
      const now = ctx.currentTime;
      const beeps = kind === "ring"
        ? [[0, 0.4, 880], [0.5, 0.4, 660]]
        : [[0, 1.0, 425]];
      for (const [start, len, freq] of beeps) {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.frequency.value = freq;
        gain.gain.setValueAtTime(0, now + start);
        gain.gain.linearRampToValueAtTime(0.12, now + start + 0.02);
        gain.gain.setValueAtTime(0.12, now + start + len - 0.05);
        gain.gain.linearRampToValueAtTime(0, now + start + len);
        osc.connect(gain).connect(ctx.destination);
        osc.start(now + start);
        osc.stop(now + start + len);
      }
    };
    play();
    this.timer = setInterval(play, kind === "ring" ? 2500 : 4000);
  }

  stop(): void {
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
    void this.ctx?.close().catch(() => {});
    this.ctx = null;
  }
}
