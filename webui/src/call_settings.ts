// Call preferences: devices (microphone, speakers, camera), browser audio
// processing, the Opus send bitrate, playback volume, and the ring sound. Stored per browser in
// localStorage; nothing here is sent to the server.

export interface CallAudioSettings {
  /** `MediaDeviceInfo.deviceId` of the microphone; "" is the system default. */
  inputId: string;
  /** `deviceId` of the speakers (needs `setSinkId`); "" is the default. */
  outputId: string;
  echoCancellation: boolean;
  noiseSuppression: boolean;
  autoGainControl: boolean;
  /** Opus send bitrate in kbit/s; 0 lets the browser decide. */
  bitrate: number;
  /** Playback volume of the other side, 0..1. */
  volume: number;
  /** Play the ring tone for incoming calls. */
  ringtone: boolean;
  /** `deviceId` of the camera for video calls; "" is the default. */
  cameraId: string;
}

export const CALL_SETTINGS_KEY = "briskd-webirc-call-settings";

/** Offered send bitrates (kbit/s); 0 means the browser's default (auto). */
export const BITRATES = [0, 16, 32, 64, 128] as const;

export const DEFAULT_CALL_SETTINGS: CallAudioSettings = {
  inputId: "",
  outputId: "",
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
  bitrate: 0,
  volume: 1,
  ringtone: true,
  cameraId: "",
};

/** Validate stored or user-supplied values; anything invalid gets the default. */
export function normalizeCallSettings(raw: unknown): CallAudioSettings {
  const d = DEFAULT_CALL_SETTINGS;
  if (!raw || typeof raw !== "object") return { ...d };
  const r = raw as Record<string, unknown>;
  const id = (v: unknown) => typeof v === "string" && v.length <= 256 ? v : "";
  const flag = (v: unknown, def: boolean) => typeof v === "boolean" ? v : def;
  const bitrate = (BITRATES as readonly number[]).includes(r.bitrate as number)
    ? r.bitrate as number
    : d.bitrate;
  const volume = typeof r.volume === "number" && Number.isFinite(r.volume)
    ? Math.min(1, Math.max(0, r.volume))
    : d.volume;
  return {
    inputId: id(r.inputId),
    outputId: id(r.outputId),
    echoCancellation: flag(r.echoCancellation, d.echoCancellation),
    noiseSuppression: flag(r.noiseSuppression, d.noiseSuppression),
    autoGainControl: flag(r.autoGainControl, d.autoGainControl),
    bitrate,
    volume,
    ringtone: flag(r.ringtone, d.ringtone),
    cameraId: id(r.cameraId),
  };
}

export function loadCallSettings(): CallAudioSettings {
  try {
    const raw = localStorage.getItem(CALL_SETTINGS_KEY);
    return normalizeCallSettings(raw ? JSON.parse(raw) : null);
  } catch {
    return { ...DEFAULT_CALL_SETTINGS };
  }
}

export function saveCallSettings(s: CallAudioSettings): void {
  try {
    localStorage.setItem(CALL_SETTINGS_KEY, JSON.stringify(s));
  } catch {
    // Private mode or storage disabled: the settings last for this page.
  }
}

/**
 * getUserMedia audio constraints for `s`. The device is `ideal`, not
 * `exact`, so an unplugged microphone falls back to the default one instead
 * of failing the call.
 */
export function audioConstraints(s: CallAudioSettings): MediaTrackConstraints {
  const c: MediaTrackConstraints = {
    echoCancellation: s.echoCancellation,
    noiseSuppression: s.noiseSuppression,
    autoGainControl: s.autoGainControl,
  };
  if (s.inputId) c.deviceId = { ideal: s.inputId };
  return c;
}

/**
 * getUserMedia video constraints for `s`: the chosen camera (`ideal`, so an
 * unplugged one falls back to the default), aiming at 720p and 30 frames per
 * second without requiring them, so any camera works.
 */
export function videoConstraints(s: CallAudioSettings): MediaTrackConstraints {
  const c: MediaTrackConstraints = {
    width: { ideal: 1280 },
    height: { ideal: 720 },
    frameRate: { ideal: 30, max: 30 },
  };
  if (s.cameraId) c.deviceId = { ideal: s.cameraId };
  return c;
}

/** Whether changing from `a` to `b` needs a new camera track. */
export function needsNewCamera(
  a: CallAudioSettings,
  b: CallAudioSettings,
): boolean {
  return a.cameraId !== b.cameraId;
}

/** Whether changing from `a` to `b` needs a new microphone track. */
export function needsNewTrack(
  a: CallAudioSettings,
  b: CallAudioSettings,
): boolean {
  return a.inputId !== b.inputId ||
    a.echoCancellation !== b.echoCancellation ||
    a.noiseSuppression !== b.noiseSuppression ||
    a.autoGainControl !== b.autoGainControl;
}

/** Whether this browser can choose the audio output device. */
export function canSelectOutput(): boolean {
  return typeof HTMLMediaElement !== "undefined" &&
    "setSinkId" in HTMLMediaElement.prototype;
}

/** Route `el` to the output `deviceId` ("" = default); ignored if unsupported. */
export async function setOutput(
  el: HTMLMediaElement,
  deviceId: string,
): Promise<void> {
  const sink = el as HTMLMediaElement & {
    setSinkId?: (id: string) => Promise<void>;
  };
  if (!sink.setSinkId) return;
  try {
    await sink.setSinkId(deviceId);
  } catch {
    // The device went away or permission is missing: keep the current one.
  }
}

/**
 * A short 16-bit mono PCM WAV of a sine tone with soft edges, for the speaker
 * test. Played through an `<audio>` element so it can use `setSinkId`.
 */
export function toneWav(
  freq = 440,
  seconds = 0.8,
  rate = 24000,
): Uint8Array {
  const samples = Math.round(seconds * rate);
  const buf = new ArrayBuffer(44 + samples * 2);
  const v = new DataView(buf);
  const ascii = (off: number, s: string) => {
    for (let i = 0; i < s.length; i++) v.setUint8(off + i, s.charCodeAt(i));
  };
  ascii(0, "RIFF");
  v.setUint32(4, 36 + samples * 2, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  v.setUint32(16, 16, true); // fmt chunk size
  v.setUint16(20, 1, true); // PCM
  v.setUint16(22, 1, true); // mono
  v.setUint32(24, rate, true);
  v.setUint32(28, rate * 2, true); // byte rate
  v.setUint16(32, 2, true); // block align
  v.setUint16(34, 16, true); // bits per sample
  ascii(36, "data");
  v.setUint32(40, samples * 2, true);
  const fade = Math.round(rate * 0.03);
  for (let i = 0; i < samples; i++) {
    const edge = Math.min(1, i / fade, (samples - 1 - i) / fade);
    const x = Math.sin(2 * Math.PI * freq * i / rate) * 0.3 * edge;
    v.setInt16(44 + i * 2, Math.round(x * 32767), true);
  }
  return new Uint8Array(buf);
}

/** Map an RMS sample level (0..1) to a 0..100 meter value on a 60 dB scale. */
export function meterLevel(rms: number): number {
  if (!(rms > 0)) return 0;
  const db = 20 * Math.log10(rms);
  return Math.round(Math.min(100, Math.max(0, (db + 60) / 60 * 100)));
}
