/// <reference lib="deno.ns" />
import {
  audioConstraints,
  DEFAULT_CALL_SETTINGS,
  meterLevel,
  needsNewTrack,
  normalizeCallSettings,
  toneWav,
} from "./call_settings.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("missing or malformed settings fall back to defaults", () => {
  for (const raw of [null, undefined, "x", 3, []]) {
    const s = normalizeCallSettings(raw);
    assert(
      JSON.stringify(s) === JSON.stringify(DEFAULT_CALL_SETTINGS),
      `defaults for ${String(raw)}`,
    );
  }
  const s = normalizeCallSettings({
    inputId: 5,
    outputId: "x".repeat(300),
    echoCancellation: "no",
    bitrate: 48,
    volume: 7,
    ringtone: false,
  });
  assert(s.inputId === "" && s.outputId === "", "bad ids dropped");
  assert(s.echoCancellation === true, "non-boolean flag keeps default");
  assert(s.bitrate === 0, "unknown bitrate becomes auto");
  assert(s.volume === 1, "volume clamped to 1");
  assert(s.ringtone === false, "valid flag kept");
  assert(normalizeCallSettings({ volume: -2 }).volume === 0, "clamped to 0");
  assert(normalizeCallSettings({ volume: NaN }).volume === 1, "NaN volume");
  assert(normalizeCallSettings({ bitrate: 64 }).bitrate === 64, "64 kept");
});

Deno.test("constraints prefer the chosen microphone without requiring it", () => {
  const c = audioConstraints({ ...DEFAULT_CALL_SETTINGS, inputId: "mic-2" });
  assert(
    JSON.stringify(c.deviceId) === JSON.stringify({ ideal: "mic-2" }),
    "ideal device",
  );
  assert(
    !("deviceId" in audioConstraints(DEFAULT_CALL_SETTINGS)),
    "no device for default",
  );
  const off = audioConstraints({
    ...DEFAULT_CALL_SETTINGS,
    echoCancellation: false,
  });
  assert(off.echoCancellation === false, "processing flag passed through");
});

Deno.test("only device and processing changes need a new track", () => {
  const d = DEFAULT_CALL_SETTINGS;
  assert(!needsNewTrack(d, { ...d, volume: 0.5 }), "volume");
  assert(!needsNewTrack(d, { ...d, bitrate: 32 }), "bitrate");
  assert(!needsNewTrack(d, { ...d, outputId: "spk" }), "output");
  assert(needsNewTrack(d, { ...d, inputId: "mic" }), "input");
  assert(needsNewTrack(d, { ...d, noiseSuppression: false }), "processing");
});

Deno.test("test tone is a valid PCM WAV", () => {
  const wav = toneWav(440, 0.5, 8000);
  const text = (a: number, b: number) =>
    String.fromCharCode(...wav.subarray(a, b));
  const v = new DataView(wav.buffer);
  assert(text(0, 4) === "RIFF" && text(8, 12) === "WAVE", "RIFF/WAVE");
  assert(text(36, 40) === "data", "data chunk");
  assert(v.getUint32(24, true) === 8000, "sample rate");
  assert(v.getUint32(40, true) === 8000, "4000 samples of 2 bytes");
  assert(wav.length === 44 + 8000, "total size");
  assert(v.getInt16(44, true) === 0, "fades in from silence");
});

Deno.test("meter maps RMS to 0..100 on a 60 dB scale", () => {
  assert(meterLevel(0) === 0, "silence");
  assert(meterLevel(NaN) === 0, "NaN");
  assert(meterLevel(0.001) === 0, "-60 dB");
  assert(meterLevel(1) === 100, "0 dB");
  assert(meterLevel(2) === 100, "clamped");
  assert(meterLevel(0.0316) === 50, "-30 dB is half");
});

Deno.test("hold music loops over four chords with a bass note per chord", async () => {
  const { holdNotes, midiToHz } = await import("./hold_music.ts");
  assert(Math.abs(midiToHz(69) - 440) < 1e-9, "A4");
  assert(holdNotes(0).bass !== undefined, "bass on the first step");
  assert(holdNotes(1).bass === undefined, "no bass mid-chord");
  assert(
    JSON.stringify(holdNotes(0)) === JSON.stringify(holdNotes(32)),
    "loops after 4 chords of 8 steps",
  );
  assert(holdNotes(8).melody !== holdNotes(0).melody, "chord changes");
});
