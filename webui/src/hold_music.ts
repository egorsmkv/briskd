// Hold audio for voice calls: a gentle, generated loop (no audio files and
// no existing tune) rendered with Web Audio into a MediaStreamTrack, which
// replaces the microphone track on the call's RTP sender while on hold.

/** A track to send while on hold, and how to release it. */
export interface HoldSource {
  track: MediaStreamTrack;
  stop(): void;
}

// A slow four-chord loop (Cmaj7, Am7, Fmaj7, G6), MIDI note numbers.
const CHORDS: number[][] = [
  [60, 64, 67, 71],
  [57, 60, 64, 67],
  [53, 57, 60, 64],
  [55, 59, 62, 64],
];
const STEP_S = 0.3; // one arpeggio note
const STEPS_PER_CHORD = 8;
const PATTERN = [0, 1, 2, 3, 2, 1, 2, 1];
const LOOKAHEAD_S = 0.4;
const TICK_MS = 100;

/** Pure: the notes to play at `step` of the loop, for tests and scheduling. */
export function holdNotes(step: number): { melody: number; bass?: number } {
  const chordIndex = Math.floor(step / STEPS_PER_CHORD) % CHORDS.length;
  const chord = CHORDS[chordIndex];
  const pos = step % STEPS_PER_CHORD;
  const melody = chord[PATTERN[pos]] + 12;
  return pos === 0 ? { melody, bass: chord[0] - 12 } : { melody };
}

export function midiToHz(note: number): number {
  return 440 * 2 ** ((note - 69) / 12);
}

/**
 * Start the hold loop. Returns null when Web Audio or MediaStream output is
 * unavailable; the caller then sends silence instead.
 */
export function createHoldMusic(): HoldSource | null {
  let ctx: AudioContext;
  try {
    ctx = new AudioContext();
  } catch {
    return null;
  }
  if (typeof ctx.createMediaStreamDestination !== "function") {
    void ctx.close().catch(() => {});
    return null;
  }
  const out = ctx.createMediaStreamDestination();
  const master = ctx.createGain();
  master.gain.value = 0.22;
  // Soften the tone and add a short echo for some space.
  const lowpass = ctx.createBiquadFilter();
  lowpass.type = "lowpass";
  lowpass.frequency.value = 2400;
  const delay = ctx.createDelay(1);
  delay.delayTime.value = STEP_S * 1.5;
  const feedback = ctx.createGain();
  feedback.gain.value = 0.25;
  master.connect(lowpass).connect(out);
  lowpass.connect(delay);
  delay.connect(feedback).connect(delay);
  delay.connect(out);

  const note = (midi: number, at: number, len: number, level: number) => {
    const osc = ctx.createOscillator();
    const env = ctx.createGain();
    osc.type = "triangle";
    osc.frequency.value = midiToHz(midi);
    env.gain.setValueAtTime(0, at);
    env.gain.linearRampToValueAtTime(level, at + 0.02);
    env.gain.exponentialRampToValueAtTime(0.001, at + len);
    osc.connect(env).connect(master);
    osc.start(at);
    osc.stop(at + len + 0.05);
  };

  let step = 0;
  let next = ctx.currentTime + 0.05;
  const schedule = () => {
    while (next < ctx.currentTime + LOOKAHEAD_S) {
      const n = holdNotes(step);
      note(n.melody, next, STEP_S * 1.6, 0.5);
      if (n.bass !== undefined) note(n.bass, next, STEP_S * 7, 0.6);
      step++;
      next += STEP_S;
    }
  };
  schedule();
  const timer = setInterval(schedule, TICK_MS);
  // Some browsers start an AudioContext suspended until a user gesture; the
  // hold button is one, so resuming here succeeds.
  void ctx.resume().catch(() => {});

  const track = out.stream.getAudioTracks()[0];
  let stopped = false;
  return {
    track,
    stop() {
      if (stopped) return;
      stopped = true;
      clearInterval(timer);
      track.stop();
      void ctx.close().catch(() => {});
    },
  };
}
