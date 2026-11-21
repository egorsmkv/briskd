// Settings → Calls: devices, microphone test, speaker test, audio preferences.
import {
  audioConstraints,
  type CallAudioSettings,
  canSelectOutput,
  meterLevel,
  needsNewTrack,
  normalizeCallSettings,
  saveCallSettings,
  setOutput,
  toneWav,
} from "../call_settings.ts";
import { byId as $, errorMessage } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { calls } from "./calls_ui.ts";
import { S } from "./state.ts";

// --- Settings → Calls ------------------------------------------------------
//
// Device lists, a live microphone level meter, a speaker test, and the
// preferences in call_settings.ts. The meter and the test sound hold a
// microphone stream, an AudioContext, and an object URL; all of them are
// released by stopCallSettingsMedia() when the test is stopped, the tab or
// the dialog is left, or the page is hidden.

// Incremented on every start and stop: a getUserMedia() that resolves after
// a newer start or a stop sees a different value and releases its stream.

/** Play the other side at the chosen volume on the chosen speakers. */
export function applyCallPlayback(): void {
  const audio = $<HTMLAudioElement>("call-audio");
  audio.volume = S.callSettings.volume;
  void setOutput(audio, S.callSettings.outputId);
}

export function callSettingsError(err: unknown | null): void {
  const box = $("call-settings-error");
  if (err === null) {
    box.classList.add("hidden");
    box.textContent = "";
    return;
  }
  const name = err instanceof DOMException ? err.name : "";
  box.textContent = name === "NotAllowedError" || name === "SecurityError"
    ? t("callset.denied")
    : name === "NotFoundError" || name === "OverconstrainedError"
    ? t("callset.nomic")
    : !navigator.mediaDevices?.getUserMedia
    ? t("callset.unavailable")
    : errorMessage(err);
  box.classList.remove("hidden");
}

export function fillDeviceSelect(
  select: HTMLSelectElement,
  devices: MediaDeviceInfo[],
  chosen: string,
): void {
  select.textContent = "";
  const def = document.createElement("option");
  def.value = "";
  def.textContent = t("callset.default");
  select.appendChild(def);
  let n = 0;
  for (const d of devices) {
    // Chrome lists the default device twice: as "default" and by its id.
    if (d.deviceId === "default" || !d.deviceId) continue;
    n++;
    const opt = document.createElement("option");
    opt.value = d.deviceId;
    opt.textContent = d.label || t("callset.device", { n });
    select.appendChild(opt);
  }
  // A saved device that is unplugged shows as the default; the preference is
  // kept, so it is used again when the device comes back.
  select.value = devices.some((d) => d.deviceId === chosen) ? chosen : "";
}

export async function refreshCallDevices(): Promise<void> {
  const md = navigator.mediaDevices;
  if (!md?.enumerateDevices) {
    callSettingsError(new Error(t("callset.unavailable")));
    return;
  }
  let devices: MediaDeviceInfo[] = [];
  try {
    devices = await md.enumerateDevices();
  } catch (err) {
    callSettingsError(err);
    return;
  }
  const inputs = devices.filter((d) => d.kind === "audioinput");
  const outputs = devices.filter((d) => d.kind === "audiooutput");
  const cameras = devices.filter((d) => d.kind === "videoinput");
  fillDeviceSelect(
    $<HTMLSelectElement>("opt-call-input"),
    inputs,
    S.callSettings.inputId,
  );
  fillDeviceSelect(
    $<HTMLSelectElement>("opt-call-output"),
    outputs,
    S.callSettings.outputId,
  );
  fillDeviceSelect(
    $<HTMLSelectElement>("opt-call-camera"),
    cameras,
    S.callSettings.cameraId,
  );
  // Only when the server offers video calls and this browser has a camera.
  $("row-call-camera").classList.toggle(
    "hidden",
    !calls.videoSupported || cameras.length === 0,
  );
  // Labels are empty until the page has been granted microphone access.
  const unlabelled = devices.length > 0 &&
    !devices.some((d) => d.label);
  $("call-settings-permission").classList.toggle("hidden", !unlabelled);
}

export function renderCallSettings(): void {
  const s = S.callSettings;
  $<HTMLInputElement>("opt-call-echo").checked = s.echoCancellation;
  $<HTMLInputElement>("opt-call-noise").checked = s.noiseSuppression;
  $<HTMLInputElement>("opt-call-agc").checked = s.autoGainControl;
  $<HTMLInputElement>("opt-call-ringtone").checked = s.ringtone;
  $<HTMLSelectElement>("opt-call-bitrate").value = String(s.bitrate);
  const volume = Math.round(s.volume * 100);
  $<HTMLInputElement>("opt-call-volume").value = String(volume);
  $("call-volume-value").textContent = `${volume}%`;
  const outputs = canSelectOutput();
  $("row-call-output").classList.toggle("hidden", !outputs);
  $("call-output-unsupported").classList.toggle("hidden", outputs);
  callSettingsError(null);
  void refreshCallDevices();
}

/** Save a change, apply it to playback, and to a call in progress. */
export function updateCallSettings(patch: Partial<CallAudioSettings>): void {
  const previous = S.callSettings;
  S.callSettings = normalizeCallSettings({ ...S.callSettings, ...patch });
  saveCallSettings(S.callSettings);
  applyCallPlayback();
  calls.applyAudioSettings(previous).catch((err) => callSettingsError(err));
  if (S.micTest && needsNewTrack(previous, S.callSettings)) {
    stopMicTest();
    void startMicTest();
  }
}

export function setMicMeter(level: number): void {
  $("call-mic-meter-fill").style.width = `${level}%`;
  $("call-mic-meter").setAttribute("aria-valuenow", String(level));
}

export function stopMicTest(): void {
  S.micTestGen++;
  S.micTestStarting = false;
  if (S.micTest) {
    cancelAnimationFrame(S.micTest.frame);
    for (const track of S.micTest.stream.getTracks()) track.stop();
    void S.micTest.ctx.close().catch(() => {});
    S.micTest = null;
  }
  setMicMeter(0);
  const btn = $<HTMLButtonElement>("btn-callset-mictest");
  btn.textContent = t("callset.mictest");
  btn.setAttribute("aria-pressed", "false");
}

export async function startMicTest(): Promise<void> {
  if (S.micTest || S.micTestStarting) return;
  if (!navigator.mediaDevices?.getUserMedia) {
    callSettingsError(new Error(t("callset.unavailable")));
    return;
  }
  const gen = ++S.micTestGen;
  S.micTestStarting = true;
  const btn = $<HTMLButtonElement>("btn-callset-mictest");
  btn.textContent = t("callset.mictest_stop");
  btn.setAttribute("aria-pressed", "true");
  let stream: MediaStream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: audioConstraints(S.callSettings),
      video: false,
    });
  } catch (err) {
    if (gen !== S.micTestGen) return;
    stopMicTest();
    callSettingsError(err);
    return;
  }
  // Stopped (tab or dialog closed) or restarted while the prompt was open.
  if (gen !== S.micTestGen) {
    for (const track of stream.getTracks()) track.stop();
    return;
  }
  S.micTestStarting = false;
  callSettingsError(null);
  const ctx = new AudioContext();
  const analyser = ctx.createAnalyser();
  analyser.fftSize = 1024;
  ctx.createMediaStreamSource(stream).connect(analyser);
  const samples = new Float32Array(analyser.fftSize);
  const test = { stream, ctx, frame: 0 };
  const tick = () => {
    if (S.micTest !== test) return;
    analyser.getFloatTimeDomainData(samples);
    let sum = 0;
    for (const x of samples) sum += x * x;
    setMicMeter(meterLevel(Math.sqrt(sum / samples.length)));
    test.frame = requestAnimationFrame(tick);
  };
  S.micTest = test;
  tick();
  // Labels become available once access is granted.
  void refreshCallDevices();
}

export function stopSpeakerTest(): void {
  if (!S.speakerTest) return;
  S.speakerTest.audio.pause();
  S.speakerTest.audio.removeAttribute("src");
  URL.revokeObjectURL(S.speakerTest.url);
  S.speakerTest = null;
}

export async function playSpeakerTest(): Promise<void> {
  stopSpeakerTest();
  const url = URL.createObjectURL(
    new Blob([toneWav() as BlobPart], { type: "audio/wav" }),
  );
  const audio = new Audio();
  const test = { audio, url };
  S.speakerTest = test;
  audio.volume = S.callSettings.volume;
  audio.onended = () => {
    if (S.speakerTest === test) stopSpeakerTest();
  };
  await setOutput(audio, S.callSettings.outputId);
  if (S.speakerTest !== test) return;
  audio.src = url;
  try {
    await audio.play();
  } catch (err) {
    if (S.speakerTest === test) stopSpeakerTest();
    callSettingsError(err);
  }
}

export function stopCallSettingsMedia(): void {
  stopMicTest();
  stopSpeakerTest();
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  applyCallPlayback();

  $("btn-callset-mictest").onclick = () => {
    if (S.micTest || S.micTestStarting) stopMicTest();
    else void startMicTest();
  };

  $("btn-callset-speakertest").onclick = () => void playSpeakerTest();

  $("btn-callset-allow").onclick = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: true,
        video: false,
      });
      for (const track of stream.getTracks()) track.stop();
      callSettingsError(null);
    } catch (err) {
      callSettingsError(err);
    }
    await refreshCallDevices();
  };

  $<HTMLSelectElement>("opt-call-input").onchange = (ev) =>
    updateCallSettings({ inputId: (ev.target as HTMLSelectElement).value });

  $<HTMLSelectElement>("opt-call-output").onchange = (ev) =>
    updateCallSettings({ outputId: (ev.target as HTMLSelectElement).value });

  $<HTMLSelectElement>("opt-call-camera").onchange = (ev) =>
    updateCallSettings({ cameraId: (ev.target as HTMLSelectElement).value });

  $<HTMLInputElement>("opt-call-volume").oninput = (ev) => {
    const volume = Number((ev.target as HTMLInputElement).value) / 100;
    $("call-volume-value").textContent = `${Math.round(volume * 100)}%`;
    updateCallSettings({ volume });
  };

  $<HTMLInputElement>("opt-call-echo").onchange = (ev) =>
    updateCallSettings({
      echoCancellation: (ev.target as HTMLInputElement).checked,
    });

  $<HTMLInputElement>("opt-call-noise").onchange = (ev) =>
    updateCallSettings({
      noiseSuppression: (ev.target as HTMLInputElement).checked,
    });

  $<HTMLInputElement>("opt-call-agc").onchange = (ev) =>
    updateCallSettings({
      autoGainControl: (ev.target as HTMLInputElement).checked,
    });

  $<HTMLInputElement>("opt-call-ringtone").onchange = (ev) =>
    updateCallSettings({ ringtone: (ev.target as HTMLInputElement).checked });

  $<HTMLSelectElement>("opt-call-bitrate").onchange = (ev) =>
    updateCallSettings({
      bitrate: Number((ev.target as HTMLSelectElement).value),
    });

  navigator.mediaDevices?.addEventListener?.("devicechange", () => {
    if ($("pane-settings-calls").classList.contains("active")) {
      void refreshCallDevices();
    }
  });
}
