/// <reference lib="deno.ns" />
import {
  computePeaks,
  fallbackPeaks,
  formatVoiceTime,
} from "./voice_player.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("formatVoiceTime formats seconds as M:SS", () => {
  assert(formatVoiceTime(0) === "0:00", "0s");
  assert(formatVoiceTime(7) === "0:07", "7s");
  assert(formatVoiceTime(65) === "1:05", "65s");
  assert(formatVoiceTime(125.9) === "2:05", "125.9s");
  assert(formatVoiceTime(-3) === "0:00", "negative");
  assert(formatVoiceTime(Number.NaN) === "0:00", "NaN");
});

Deno.test("fallbackPeaks is deterministic and bounded in [0.16, 1.0]", () => {
  const a = fallbackPeaks("0123456789abcdef0123456789abcdef.ogg", 36);
  const b = fallbackPeaks("0123456789abcdef0123456789abcdef.ogg", 36);
  const c = fallbackPeaks("fedcba9876543210fedcba9876543210.ogg", 36);
  assert(a.length === 36, "length 36");
  assert(a.every((v, idx) => v === b[idx]), "deterministic");
  assert(a.some((v, idx) => v !== c[idx]), "varies by seed");
  for (const v of a) {
    assert(v >= 0.16 && v <= 1.0, `bounded ${v}`);
  }
});

Deno.test("computePeaks normalizes PCM audio into bounded bars", () => {
  const pcm = new Float32Array(360);
  for (let i = 0; i < pcm.length; i++) {
    pcm[i] = i < 180 ? 0.1 : 0.8 * Math.sin(i * 0.3);
  }
  const peaks = computePeaks(pcm, 18);
  assert(peaks.length === 18, "length 18");
  assert(Math.max(...peaks) === 1, "max normalized to 1");
  assert(peaks[0] < peaks[15], "louder section taller");
  for (const v of peaks) {
    assert(v >= 0.14 && v <= 1.0, `bounded ${v}`);
  }
});
