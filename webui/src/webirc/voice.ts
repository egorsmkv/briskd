// Recording and sending voice messages.
import { byId as $, errorMessage } from "../common/dom.ts";
import { E2EE_ATT_PREFIX } from "../common/file_card.ts";
import { t } from "../common/i18n.ts";
import { formatVoiceTime } from "../common/voice_player.ts";
import { encryptAttachment } from "../e2ee/crypto.ts";
import { addLine } from "./buffers.ts";
import { sendRaw } from "./connection.ts";
import { VOICE_DUR_TAG, VOICE_ID_RE, VOICE_TAG } from "./constants.ts";
import { e2ee } from "./e2ee_ui.ts";
import {
  closeAttachMenu,
  updateAttachControls,
  uploadBinaryFile,
} from "./files.ts";
import { buffers, S } from "./state.ts";

export const VOICE_MAX_SEC = 120;

export function pickOpusMime(): string {
  if (typeof MediaRecorder === "undefined") return "";
  const candidates = [
    "audio/ogg;codecs=opus",
    "audio/webm;codecs=opus",
    "audio/webm",
  ];
  for (const mime of candidates) {
    if (MediaRecorder.isTypeSupported(mime)) return mime;
  }
  return "";
}

export function canRecordVoice(): boolean {
  return S.voiceSupported &&
    typeof MediaRecorder !== "undefined" &&
    Boolean(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
}

export function updateVoiceButton(): void {
  updateAttachControls();
}

export function resetVoiceUi(): void {
  if (S.voiceTimerId !== null) {
    globalThis.clearInterval(S.voiceTimerId);
    S.voiceTimerId = null;
  }
  if (S.voiceStream) {
    for (const track of S.voiceStream.getTracks()) track.stop();
    S.voiceStream = null;
  }
  S.voiceRecorder = null;
  S.voiceChunks = [];
  const btn = $("btn-voice");
  btn.classList.remove("recording");
  btn.classList.add("hidden");
  btn.title = t("voice.record");
  $("send-form").classList.remove("recording-active");
  $("voice-timer").textContent = "";
  $("btn-voice-cancel").classList.add("hidden");
}

export async function uploadAndSendVoice(
  blob: Blob,
  durSec: number,
  target: string,
): Promise<void> {
  const btn = $<HTMLButtonElement>("btn-voice");
  btn.disabled = true;
  try {
    if (e2ee.isBufferEncrypted(target) && S.filesSupported) {
      const raw = new Uint8Array(await blob.arrayBuffer());
      const enc = encryptAttachment(raw);
      const uploaded = await uploadBinaryFile(enc.ciphertext, "encrypted.bin");
      if (!uploaded) return;
      const payload = E2EE_ATT_PREFIX + JSON.stringify({
        v: 1,
        kind: "voice",
        id: uploaded.id,
        mime: blob.type || "audio/ogg",
        dur: durSec,
        bytes: raw.byteLength,
        key: enc.key,
        iv: enc.iv,
        sha256: enc.sha256,
      });
      const ok = await e2ee.sendEncrypted(target, payload);
      if (ok) {
        addLine(target, { nick: S.myNick, text: payload, encrypted: true });
      }
      return;
    }
    const resp = await fetch("/api/voice", {
      method: "POST",
      headers: {
        "X-Requested-With": "ircd-webui",
        "Content-Type": blob.type || "audio/ogg",
        "X-Voice-Duration": String(durSec),
      },
      body: blob,
    });
    const data = await resp.json().catch(() => ({})) as {
      id?: string;
      duration?: number;
      error?: string;
      message?: string;
    };
    if (!resp.ok || !data.id || !VOICE_ID_RE.test(data.id)) {
      const reason = data.message || data.error || `HTTP ${resp.status}`;
      addLine(target, {
        text: t("voice.err.upload", { reason }),
        kind: "err",
      });
      return;
    }
    const finalDur = typeof data.duration === "number" && data.duration > 0
      ? data.duration
      : durSec;
    sendRaw(
      `@${VOICE_TAG}=${data.id};${VOICE_DUR_TAG}=${finalDur} PRIVMSG ${target} :[Voice message ${
        formatVoiceTime(finalDur)
      }] /api/voice/${data.id}`,
    );
  } catch (e) {
    addLine(target, {
      text: t("voice.err.upload", { reason: errorMessage(e) }),
      kind: "err",
    });
  } finally {
    btn.disabled = false;
  }
}

/**
 * True while the microphone is being opened (the permission prompt may be
 * showing): a second click then would start a second recording and leave
 * the first stream and its timer running.
 */
let starting = false;

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  $("btn-voice").addEventListener("click", () => {
    if (S.voiceRecorder && S.voiceRecorder.state === "recording") {
      S.voiceCancelled = false;
      S.voiceRecorder.stop();
      return;
    }
    if (starting) return;
    const buf = buffers.get(S.activeBuf);
    if (!buf || buf.name === "*status") {
      addLine("*status", { text: t("voice.err.target"), kind: "err" });
      return;
    }
    S.voiceTarget = buf.name;
    S.voiceCancelled = false;
    starting = true;
    void navigator.mediaDevices.getUserMedia({ audio: true }).then((stream) => {
      starting = false;
      S.voiceStream = stream;
      S.voiceChunks = [];
      const mime = pickOpusMime();
      const opts: MediaRecorderOptions = mime
        ? { mimeType: mime, audioBitsPerSecond: 32000 }
        : { audioBitsPerSecond: 32000 };
      const rec = new MediaRecorder(stream, opts);
      S.voiceRecorder = rec;
      S.voiceStartMs = Date.now();
      rec.ondataavailable = (ev) => {
        if (ev.data && ev.data.size > 0) S.voiceChunks.push(ev.data);
      };
      rec.onstop = () => {
        const chunks = S.voiceChunks.slice();
        const cancelled = S.voiceCancelled;
        const target = S.voiceTarget;
        const durSec = Math.max(
          1,
          Math.min(
            VOICE_MAX_SEC,
            Math.round((Date.now() - S.voiceStartMs) / 1000),
          ),
        );
        const outMime = rec.mimeType || mime || "audio/ogg";
        resetVoiceUi();
        if (!cancelled && chunks.length > 0) {
          const blob = new Blob(chunks, { type: outMime });
          void uploadAndSendVoice(blob, durSec, target);
        }
      };
      rec.start(250);
      const btn = $("btn-voice");
      btn.classList.remove("hidden");
      btn.classList.add("recording");
      btn.title = t("voice.stop");
      $("send-form").classList.add("recording-active");
      closeAttachMenu();
      $("btn-voice-cancel").classList.remove("hidden");
      $("voice-timer").textContent = "0:00";
      S.voiceTimerId = globalThis.setInterval(() => {
        const elapsed = Math.floor((Date.now() - S.voiceStartMs) / 1000);
        $("voice-timer").textContent = formatVoiceTime(elapsed);
        if (elapsed >= VOICE_MAX_SEC && S.voiceRecorder) {
          S.voiceCancelled = false;
          S.voiceRecorder.stop();
        }
      }, 250);
    }).catch(() => {
      starting = false;
      resetVoiceUi();
      addLine(S.voiceTarget || "*status", {
        text: t("voice.err.mic"),
        kind: "err",
      });
    });
  });

  $("btn-voice-cancel").addEventListener("click", () => {
    S.voiceCancelled = true;
    if (S.voiceRecorder && S.voiceRecorder.state === "recording") {
      S.voiceRecorder.stop();
    } else {
      resetVoiceUi();
    }
  });
}
