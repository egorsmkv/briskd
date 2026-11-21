// File uploads, attachments menu, drag-and-drop, paste, and code snippets.
import { byId as $, errorMessage } from "../common/dom.ts";
import {
  E2EE_ATT_PREFIX,
  type E2eeAttachmentItem,
  formatBytes,
  isPreviewImageId,
} from "../common/file_card.ts";
import { t } from "../common/i18n.ts";
import { encryptAttachment } from "../e2ee/crypto.ts";
import { addLine } from "./buffers.ts";
import { msgInp } from "./composer.ts";
import { sendRaw } from "./connection.ts";
import {
  ALBUM_TAG,
  FILE_ID_RE,
  FILE_NAME_TAG,
  FILE_SIZE_TAG,
  FILE_TAG,
  PASTE_LANG_TAG,
  PASTE_TAG,
  PASTE_TITLE_TAG,
} from "./constants.ts";
import { e2ee } from "./e2ee_ui.ts";
import { buffers, S } from "./state.ts";
import { canRecordVoice } from "./voice.ts";

export function updateAttachControls(): void {
  const voiceOk = canRecordVoice();
  const anyAttach = S.filesSupported || voiceOk;
  $("btn-attach-menu").classList.toggle("hidden", !anyAttach);
  $("btn-attach-file-menu").classList.toggle("hidden", !S.filesSupported);
  $("btn-attach-code-menu").classList.toggle("hidden", !S.filesSupported);
  $("btn-attach-voice-menu").classList.toggle("hidden", !voiceOk);
  if (S.filesSupported) {
    $("attach-file-desc").textContent = `${t("attach.file.desc")} (max ${
      formatBytes(S.filesMaxBytes)
    })`;
  }
}

export function updateFileButton(): void {
  updateAttachControls();
}

export function openAttachModal(): void {
  const buf = buffers.get(S.activeBuf);
  if (!buf || buf.name === "*status") {
    addLine("*status", { text: t("file.err.target"), kind: "err" });
    return;
  }
  updateAttachControls();
  $("attach-modal").classList.add("open");
}

export function closeAttachMenu(): void {
  $("attach-modal").classList.remove("open");
}

export async function uploadBinaryFile(
  body: Blob | Uint8Array,
  filename: string,
): Promise<{ id: string; name: string; bytes: number } | null> {
  const resp = await fetch("/api/files", {
    method: "POST",
    headers: {
      "X-Requested-With": "briskd-webui",
      "Content-Type": "application/octet-stream",
      "X-File-Name": encodeURIComponent(filename || "file.bin"),
    },
    body: body instanceof Uint8Array ? (body as BodyInit) : body,
  });
  const data = await resp.json().catch(() => ({})) as {
    id?: string;
    name?: string;
    bytes?: number;
    error?: string;
    message?: string;
  };
  if (!resp.ok || !data.id || !FILE_ID_RE.test(data.id)) {
    throw new Error(data.message || data.error || `HTTP ${resp.status}`);
  }
  return {
    id: data.id,
    name: data.name || filename || data.id,
    bytes: typeof data.bytes === "number" && data.bytes > 0 ? data.bytes : 0,
  };
}

export function isRasterImageFile(file: File): boolean {
  return [
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
  ].includes(file.type) ||
    isPreviewImageId(
      `00000000000000000000000000000000.${
        (file.name.split(".").pop() || "").toLowerCase()
      }`,
    );
}

export async function uploadAndSendFiles(
  files: File[],
  target: string,
): Promise<void> {
  if (!S.filesSupported || files.length === 0) return;
  const batch = files.slice(0, 10);
  for (const f of batch) {
    if (f.size > S.filesMaxBytes) {
      addLine(target, {
        text: t("file.err.tooLarge", { max: formatBytes(S.filesMaxBytes) }),
        kind: "err",
      });
      return;
    }
  }
  const btn = $<HTMLButtonElement>("btn-attach-menu");
  btn.disabled = true;
  btn.classList.add("uploading");
  try {
    const encrypted = e2ee.isBufferEncrypted(target);
    const allImages = batch.length >= 2 && batch.every(isRasterImageFile);

    if (encrypted) {
      if (allImages) {
        const items: E2eeAttachmentItem[] = [];
        for (const f of batch) {
          const raw = new Uint8Array(await f.arrayBuffer());
          const enc = encryptAttachment(raw);
          const up = await uploadBinaryFile(enc.ciphertext, "encrypted.bin");
          if (up) {
            items.push({
              id: up.id,
              name: f.name || "image.png",
              mime: f.type || "image/png",
              bytes: raw.byteLength,
              key: enc.key,
              iv: enc.iv,
              sha256: enc.sha256,
            });
          }
        }
        if (items.length > 0) {
          const payload = E2EE_ATT_PREFIX + JSON.stringify({
            v: 1,
            kind: "album",
            items,
          });
          const ok = await e2ee.sendEncrypted(target, payload);
          if (ok) {
            addLine(target, { nick: S.myNick, text: payload, encrypted: true });
          }
        }
      } else {
        for (const f of batch) {
          if (f.size <= 0) continue;
          const raw = new Uint8Array(await f.arrayBuffer());
          const enc = encryptAttachment(raw);
          const up = await uploadBinaryFile(enc.ciphertext, "encrypted.bin");
          if (!up) continue;
          const payload = E2EE_ATT_PREFIX + JSON.stringify({
            v: 1,
            kind: "file",
            id: up.id,
            name: f.name || "file.bin",
            mime: f.type || "application/octet-stream",
            bytes: raw.byteLength,
            key: enc.key,
            iv: enc.iv,
            sha256: enc.sha256,
          });
          const ok = await e2ee.sendEncrypted(target, payload);
          if (ok) {
            addLine(target, { nick: S.myNick, text: payload, encrypted: true });
          }
        }
      }
      return;
    }

    if (allImages) {
      const ids: string[] = [];
      for (const f of batch) {
        if (f.size <= 0) continue;
        const up = await uploadBinaryFile(f, f.name || "image.png");
        if (up && isPreviewImageId(up.id)) ids.push(up.id);
      }
      if (ids.length >= 2) {
        sendRaw(
          `@${ALBUM_TAG}=${
            ids.join(",")
          } PRIVMSG ${target} :[Album: ${ids.length} images]`,
        );
      } else if (ids.length === 1) {
        const id = ids[0];
        sendRaw(
          `@${FILE_TAG}=${id};${FILE_NAME_TAG}=${
            encodeURIComponent(batch[0].name || id)
          };${FILE_SIZE_TAG}=${batch[0].size} PRIVMSG ${target} :[File: ${
            batch[0].name || id
          }] /api/files/${id}`,
        );
      }
      return;
    }

    for (const f of batch) {
      if (f.size <= 0) continue;
      const up = await uploadBinaryFile(f, f.name || "file.bin");
      if (!up) continue;
      const size = up.bytes || f.size;
      const encodedName = encodeURIComponent(up.name);
      sendRaw(
        `@${FILE_TAG}=${up.id};${FILE_NAME_TAG}=${encodedName};${FILE_SIZE_TAG}=${size} PRIVMSG ${target} :[File: ${up.name} (${
          formatBytes(size)
        })] /api/files/${up.id}`,
      );
    }
  } catch (e) {
    addLine(target, {
      text: t("file.err.upload", { reason: errorMessage(e) }),
      kind: "err",
    });
  } finally {
    btn.disabled = false;
    btn.classList.remove("uploading");
  }
}

export function shareFilesInActiveBuffer(files: File[]): void {
  const buf = buffers.get(S.activeBuf);
  if (!buf || buf.name === "*status") {
    addLine("*status", { text: t("file.err.target"), kind: "err" });
    return;
  }
  void uploadAndSendFiles(files, buf.name);
}

export const fileInp = $<HTMLInputElement>("inp-file");

export const messagesDropZone = $("messages");

// Code Snippet / Paste modal
export function openCodeModal(): void {
  const buf = buffers.get(S.activeBuf);
  if (!buf || buf.name === "*status") {
    addLine("*status", { text: t("file.err.target"), kind: "err" });
    return;
  }
  $("code-modal").classList.add("open");
  $<HTMLTextAreaElement>("inp-code-body").focus();
}

export function closeCodeModal(): void {
  $("code-modal").classList.remove("open");
}

export const codeBodyInp = $<HTMLTextAreaElement>("inp-code-body");

// Channel Moderation Modal (operators only)
export const MOD_MODES: Array<{ flag: string; label: string }> = [
  { flag: "m", label: "+m Moderated" },
  { flag: "i", label: "+i Invite-only" },
  { flag: "t", label: "+t Op Topic" },
  { flag: "n", label: "+n No External" },
  { flag: "s", label: "+s Secret" },
];

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  $("btn-attach-menu").addEventListener("click", openAttachModal);

  $("btn-close-attach").addEventListener("click", closeAttachMenu);

  $("attach-modal").addEventListener("click", (ev) => {
    if (ev.target === $("attach-modal")) closeAttachMenu();
  });

  $("btn-attach-file-menu").addEventListener("click", () => {
    closeAttachMenu();
    fileInp.value = "";
    fileInp.click();
  });

  $("btn-attach-code-menu").addEventListener("click", () => {
    closeAttachMenu();
    openCodeModal();
  });

  $("btn-attach-voice-menu").addEventListener("click", () => {
    closeAttachMenu();
    $("btn-voice").click();
  });

  document.addEventListener("click", (ev) => {
    const target = ev.target as HTMLElement | null;
    if (!target?.closest(".msg")) {
      document.querySelectorAll(".msg.actions-open").forEach((el) =>
        el.classList.remove("actions-open")
      );
    }
  });

  fileInp.addEventListener("change", () => {
    const files = fileInp.files ? Array.from(fileInp.files) : [];
    if (files.length > 0) shareFilesInActiveBuffer(files);
  });

  messagesDropZone.addEventListener("dragover", (ev) => {
    if (!S.filesSupported) return;
    if (ev.dataTransfer?.types.includes("Files")) {
      ev.preventDefault();
      messagesDropZone.classList.add("drag-over");
    }
  });

  messagesDropZone.addEventListener("dragleave", () => {
    messagesDropZone.classList.remove("drag-over");
  });

  messagesDropZone.addEventListener("drop", (ev) => {
    messagesDropZone.classList.remove("drag-over");
    if (!S.filesSupported) return;
    const files = ev.dataTransfer?.files
      ? Array.from(ev.dataTransfer.files)
      : [];
    if (files.length > 0) {
      ev.preventDefault();
      shareFilesInActiveBuffer(files);
    }
  });

  msgInp.addEventListener("paste", (ev) => {
    if (!S.filesSupported) return;
    const files = ev.clipboardData?.files
      ? Array.from(ev.clipboardData.files)
      : [];
    if (files.length > 0) {
      ev.preventDefault();
      shareFilesInActiveBuffer(files);
    }
  });

  $("btn-close-code").onclick = closeCodeModal;

  $("btn-cancel-code").onclick = closeCodeModal;

  $("code-modal").addEventListener("click", (ev) => {
    if (ev.target === $("code-modal")) closeCodeModal();
  });

  codeBodyInp.addEventListener("keydown", (ev) => {
    if (ev.key === "Tab") {
      ev.preventDefault();
      const s = codeBodyInp.selectionStart;
      const e = codeBodyInp.selectionEnd;
      codeBodyInp.value = codeBodyInp.value.slice(0, s) + "  " +
        codeBodyInp.value.slice(e);
      codeBodyInp.selectionStart = codeBodyInp.selectionEnd = s + 2;
    } else if (ev.key === "Enter" && (ev.ctrlKey || ev.metaKey)) {
      ev.preventDefault();
      $<HTMLFormElement>("code-form").requestSubmit();
    }
  });

  $<HTMLFormElement>("code-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const buf = buffers.get(S.activeBuf);
    if (!buf || buf.name === "*status") return;
    const code = codeBodyInp.value;
    if (!code.trim()) return;
    const lang = $<HTMLSelectElement>("sel-code-lang").value || "text";
    const title = $<HTMLInputElement>("inp-code-title").value.trim();
    const target = buf.name;
    closeCodeModal();
    codeBodyInp.value = "";
    $<HTMLInputElement>("inp-code-title").value = "";

    try {
      const raw = new TextEncoder().encode(code);
      if (e2ee.isBufferEncrypted(target)) {
        const enc = encryptAttachment(raw);
        const up = await uploadBinaryFile(enc.ciphertext, "encrypted.bin");
        if (!up) return;
        const payload = E2EE_ATT_PREFIX + JSON.stringify({
          v: 1,
          kind: "paste",
          id: up.id,
          lang,
          title,
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
      const up = await uploadBinaryFile(raw, (title || "snippet") + ".txt");
      if (!up) return;
      const titleTag = title
        ? `;${PASTE_TITLE_TAG}=${encodeURIComponent(title)}`
        : "";
      const label = title ? `${title} (${lang})` : lang;
      sendRaw(
        `@${PASTE_TAG}=${up.id};${PASTE_LANG_TAG}=${lang}${titleTag} PRIVMSG ${target} :[Code: ${label}] /api/files/${up.id}`,
      );
    } catch (e) {
      addLine(target, {
        text: t("file.err.upload", { reason: errorMessage(e) }),
        kind: "err",
      });
    }
  });
}
