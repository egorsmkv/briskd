/**
 * Custom zero-dependency voice message player with real Web Audio API waveform
 * extraction (with deterministic fallback), interactive scrubbing, playback speed
 * toggle (1x / 1.5x / 2x), and single-active-player coordination.
 *
 * Uses only DOM APIs (no innerHTML) and CSS theme variables so it adapts to all
 * WebIRC themes and strict CSP policies.
 */

const BAR_COUNT = 36;
const SPEEDS = [1, 1.5, 2] as const;

let activeAudio: HTMLAudioElement | null = null;
const peakCache = new Map<string, number[]>();

export interface VoicePlayerOptions {
  voiceId: string;
  durationSec?: number;
  label: string;
  playAriaLabel?: string;
  pauseAriaLabel?: string;
}

/** Format seconds as M:SS (e.g. 0:07, 1:42). */
export function formatVoiceTime(sec: number): string {
  const s = Math.max(0, Math.floor(Number.isFinite(sec) ? sec : 0));
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${r < 10 ? "0" : ""}${r}`;
}

/**
 * Deterministic, speech-like placeholder waveform seeded from the voice ID so
 * the player renders cleanly before decoding the OPUS audio buffer.
 */
export function fallbackPeaks(seed: string, count = BAR_COUNT): number[] {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) {
    h ^= seed.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  const peaks: number[] = [];
  for (let i = 0; i < count; i++) {
    h = (Math.imul(h, 1664525) + 1013904223) >>> 0;
    const rand = (h >>> 16) / 65535;
    // Slight speech envelope (softer at edges, varied in middle)
    const pos = i / Math.max(1, count - 1);
    const env = 0.55 + 0.45 * Math.sin(pos * Math.PI);
    const val = Math.min(1, Math.max(0.16, (0.22 + rand * 0.78) * env));
    peaks.push(val);
  }
  return peaks;
}

/**
 * Downsample a mono/multi-channel AudioBuffer PCM array into `count` normalized
 * bar heights in [0.14, 1.0].
 */
export function computePeaks(
  samples: Float32Array,
  count = BAR_COUNT,
): number[] {
  if (samples.length === 0 || count <= 0) return [];
  const step = Math.max(1, Math.floor(samples.length / count));
  const raw: number[] = [];
  let maxPeak = 0.001;

  for (let i = 0; i < count; i++) {
    const start = i * step;
    const end = Math.min(samples.length, start + step);
    let sumSq = 0;
    let peak = 0;
    const len = Math.max(1, end - start);
    for (let j = start; j < end; j++) {
      const v = Math.abs(samples[j]);
      if (v > peak) peak = v;
      sumSq += v * v;
    }
    const rms = Math.sqrt(sumSq / len);
    const combined = peak * 0.55 + rms * 0.45;
    if (combined > maxPeak) maxPeak = combined;
    raw.push(combined);
  }

  return raw.map((v) => Math.min(1, Math.max(0.14, v / maxPeak)));
}

async function decodePeaksFromUrl(url: string): Promise<number[] | null> {
  const cached = peakCache.get(url);
  if (cached) return cached;

  const AudioCtx = globalThis.AudioContext ||
    (globalThis as unknown as { webkitAudioContext?: typeof AudioContext })
      .webkitAudioContext;
  if (!AudioCtx) return null;

  try {
    const resp = await fetch(url);
    if (!resp.ok) return null;
    const buf = await resp.arrayBuffer();
    const ctx = new AudioCtx();
    try {
      const decoded = await ctx.decodeAudioData(buf);
      const data = decoded.getChannelData(0);
      const peaks = computePeaks(data, BAR_COUNT);
      if (peaks.length === BAR_COUNT) {
        if (peakCache.size > 120) {
          const first = peakCache.keys().next().value;
          if (first) peakCache.delete(first);
        }
        peakCache.set(url, peaks);
        return peaks;
      }
      return null;
    } finally {
      void ctx.close().catch(() => {});
    }
  } catch {
    return null;
  }
}

function makeSvgIcon(kind: "play" | "pause"): SVGSVGElement {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", "16");
  svg.setAttribute("height", "16");
  svg.setAttribute("fill", "currentColor");
  svg.setAttribute("aria-hidden", "true");
  if (kind === "play") {
    const poly = document.createElementNS(ns, "polygon");
    poly.setAttribute("points", "7,4 20,12 7,20");
    svg.appendChild(poly);
  } else {
    const r1 = document.createElementNS(ns, "rect");
    r1.setAttribute("x", "6");
    r1.setAttribute("y", "4");
    r1.setAttribute("width", "4");
    r1.setAttribute("height", "16");
    r1.setAttribute("rx", "1");
    const r2 = document.createElementNS(ns, "rect");
    r2.setAttribute("x", "14");
    r2.setAttribute("y", "4");
    r2.setAttribute("width", "4");
    r2.setAttribute("height", "16");
    r2.setAttribute("rx", "1");
    svg.appendChild(r1);
    svg.appendChild(r2);
  }
  return svg;
}

export function createVoicePlayer(opts: VoicePlayerOptions): HTMLElement {
  const url = `/api/voice/${opts.voiceId}`;
  let totalDur = opts.durationSec && opts.durationSec > 0
    ? opts.durationSec
    : 0;
  let speedIdx = 0;
  let waveformLoaded = false;

  const root = document.createElement("div");
  root.className = "voice-card";
  root.setAttribute("role", "group");
  root.setAttribute("aria-label", opts.label);

  const audio = document.createElement("audio");
  audio.preload = "metadata";
  audio.src = url;
  audio.className = "hidden";
  root.appendChild(audio);

  // Circular Play / Pause button
  const playBtn = document.createElement("button");
  playBtn.type = "button";
  playBtn.className = "voice-play-btn";
  playBtn.setAttribute(
    "aria-label",
    opts.playAriaLabel || "Play voice message",
  );
  playBtn.appendChild(makeSvgIcon("play"));

  // Center column: waveform + meta footer
  const main = document.createElement("div");
  main.className = "voice-main";

  const wave = document.createElement("div");
  wave.className = "voice-wave";
  wave.dir = "ltr";
  wave.setAttribute("role", "slider");
  wave.setAttribute("tabindex", "0");
  wave.setAttribute("aria-label", opts.label);
  wave.setAttribute("aria-valuemin", "0");
  wave.setAttribute("aria-valuemax", "100");
  wave.setAttribute("aria-valuenow", "0");

  const bars: HTMLSpanElement[] = [];
  const initialPeaks = peakCache.get(url) ||
    fallbackPeaks(opts.voiceId, BAR_COUNT);
  if (peakCache.has(url)) waveformLoaded = true;

  for (let i = 0; i < initialPeaks.length; i++) {
    const bar = document.createElement("span");
    bar.className = "voice-bar";
    bar.style.height = `${Math.round(initialPeaks[i] * 100)}%`;
    wave.appendChild(bar);
    bars.push(bar);
  }

  const meta = document.createElement("div");
  meta.className = "voice-meta";

  const timeEl = document.createElement("span");
  timeEl.className = "voice-time";
  timeEl.textContent = totalDur > 0 ? formatVoiceTime(totalDur) : "0:00";

  const rightMeta = document.createElement("div");
  rightMeta.className = "voice-meta-right";

  const codecBadge = document.createElement("span");
  codecBadge.className = "voice-codec";
  codecBadge.textContent = "OPUS";

  const speedBtn = document.createElement("button");
  speedBtn.type = "button";
  speedBtn.className = "voice-speed";
  speedBtn.textContent = "1x";
  speedBtn.title = "Playback speed";

  rightMeta.appendChild(codecBadge);
  rightMeta.appendChild(speedBtn);
  meta.appendChild(timeEl);
  meta.appendChild(rightMeta);

  main.appendChild(wave);
  main.appendChild(meta);
  root.appendChild(playBtn);
  root.appendChild(main);

  function applyPeaks(peaks: number[]): void {
    for (let i = 0; i < Math.min(bars.length, peaks.length); i++) {
      bars[i].style.height = `${Math.round(peaks[i] * 100)}%`;
    }
  }

  function effectiveDuration(): number {
    if (Number.isFinite(audio.duration) && audio.duration > 0) {
      return audio.duration;
    }
    return totalDur;
  }

  function updateProgress(): void {
    const dur = effectiveDuration();
    const cur = audio.currentTime || 0;
    const ratio = dur > 0 ? Math.min(1, Math.max(0, cur / dur)) : 0;
    const activeCount = Math.round(ratio * bars.length);
    for (let i = 0; i < bars.length; i++) {
      bars[i].classList.toggle("played", i < activeCount);
    }
    wave.setAttribute("aria-valuenow", String(Math.round(ratio * 100)));
    if (!audio.paused || cur > 0) {
      timeEl.textContent = dur > 0
        ? `${formatVoiceTime(cur)} / ${formatVoiceTime(dur)}`
        : formatVoiceTime(cur);
    } else {
      timeEl.textContent = formatVoiceTime(dur);
    }
  }

  function setPlayingUi(playing: boolean): void {
    root.classList.toggle("playing", playing);
    playBtn.textContent = "";
    playBtn.appendChild(makeSvgIcon(playing ? "pause" : "play"));
    playBtn.setAttribute(
      "aria-label",
      playing
        ? opts.pauseAriaLabel || "Pause voice message"
        : opts.playAriaLabel || "Play voice message",
    );
  }

  function ensureRealWaveform(): void {
    if (waveformLoaded) return;
    waveformLoaded = true;
    void decodePeaksFromUrl(url).then((peaks) => {
      if (peaks) applyPeaks(peaks);
    });
  }

  // Decode real waveform lazily in the background so visible voice notes show
  // true amplitude bars right away.
  ensureRealWaveform();

  function seekToRatio(ratio: number): void {
    const clamped = Math.min(1, Math.max(0, ratio));
    const dur = effectiveDuration();
    if (dur > 0) {
      audio.currentTime = clamped * dur;
      updateProgress();
    }
  }

  playBtn.addEventListener("click", () => {
    if (audio.paused) {
      if (activeAudio && activeAudio !== audio) {
        activeAudio.pause();
      }
      activeAudio = audio;
      audio.playbackRate = SPEEDS[speedIdx];
      void audio.play().catch(() => {
        setPlayingUi(false);
      });
    } else {
      audio.pause();
    }
  });

  speedBtn.addEventListener("click", () => {
    speedIdx = (speedIdx + 1) % SPEEDS.length;
    const rate = SPEEDS[speedIdx];
    audio.playbackRate = rate;
    speedBtn.textContent = `${rate}x`;
  });

  let dragging = false;
  function pointerRatio(ev: PointerEvent | MouseEvent): number {
    const rect = wave.getBoundingClientRect();
    if (rect.width <= 0) return 0;
    return (ev.clientX - rect.left) / rect.width;
  }

  wave.addEventListener("pointerdown", (ev) => {
    dragging = true;
    wave.setPointerCapture?.(ev.pointerId);
    seekToRatio(pointerRatio(ev));
  });
  wave.addEventListener("pointermove", (ev) => {
    if (dragging) seekToRatio(pointerRatio(ev));
  });
  wave.addEventListener("pointerup", () => {
    dragging = false;
  });
  wave.addEventListener("pointercancel", () => {
    dragging = false;
  });

  wave.addEventListener("keydown", (ev) => {
    const dur = effectiveDuration();
    if (dur <= 0) return;
    if (ev.key === "ArrowRight") {
      ev.preventDefault();
      audio.currentTime = Math.min(dur, (audio.currentTime || 0) + 5);
      updateProgress();
    } else if (ev.key === "ArrowLeft") {
      ev.preventDefault();
      audio.currentTime = Math.max(0, (audio.currentTime || 0) - 5);
      updateProgress();
    } else if (ev.key === " " || ev.key === "Enter") {
      ev.preventDefault();
      playBtn.click();
    }
  });

  audio.addEventListener("loadedmetadata", () => {
    if (Number.isFinite(audio.duration) && audio.duration > 0) {
      totalDur = audio.duration;
      updateProgress();
    }
  });
  audio.addEventListener("play", () => setPlayingUi(true));
  audio.addEventListener("pause", () => {
    setPlayingUi(false);
    if (activeAudio === audio) activeAudio = null;
  });
  audio.addEventListener("timeupdate", updateProgress);
  audio.addEventListener("ended", () => {
    setPlayingUi(false);
    audio.currentTime = 0;
    updateProgress();
    if (activeAudio === audio) activeAudio = null;
  });

  return root;
}
