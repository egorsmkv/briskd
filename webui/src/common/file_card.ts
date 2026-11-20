/**
 * Custom zero-dependency file attachment card, multi-image album grid, and
 * E2EE encrypted attachment loader for WebIRC.
 *
 * Renders inline image previews (opening the full-screen Lightbox on click)
 * for safe raster formats (PNG, JPEG, GIF, WebP), multi-image albums, and
 * color-coded file cards with size badges and one-click download links.
 */

import { type LightboxItem, openLightbox } from "./lightbox.ts";
import { createCodeCard } from "./code_card.ts";
import { createVoicePlayer } from "./voice_player.ts";
import { decryptAttachment } from "../e2ee/crypto.ts";

export type FileCategory =
  | "image"
  | "pdf"
  | "archive"
  | "text"
  | "media"
  | "file";

export interface FileCardOptions {
  fileId: string;
  fileName: string;
  fileSize?: number;
  srcUrl?: string;
  previewImage?: boolean;
  encrypted?: boolean;
  downloadLabel?: string;
}

export const E2EE_ATT_PREFIX = "__ircd_e2ee_att__:";

export interface E2eeAttachmentItem {
  id: string;
  name: string;
  mime: string;
  bytes: number;
  key: string;
  iv: string;
  sha256: string;
}

export type E2eeAttachmentPayload =
  | {
    v: 1;
    kind: "voice";
    id: string;
    mime: string;
    dur: number;
    bytes: number;
    key: string;
    iv: string;
    sha256: string;
  }
  | {
    v: 1;
    kind: "file";
    id: string;
    name: string;
    mime: string;
    bytes: number;
    key: string;
    iv: string;
    sha256: string;
  }
  | {
    v: 1;
    kind: "album";
    items: E2eeAttachmentItem[];
  }
  | {
    v: 1;
    kind: "paste";
    id: string;
    lang: string;
    title: string;
    key: string;
    iv: string;
    sha256: string;
  };

const decryptedBlobCache = new Map<string, string>();
const SAFE_E2EE_ID_RE = /^[0-9a-f]{32}\.[a-z0-9]{1,8}$/;
const SAFE_IMAGE_MIMES = new Set([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
]);
const SAFE_AUDIO_MIMES = new Set([
  "audio/ogg",
  "audio/webm",
  "audio/mpeg",
  "audio/wav",
]);

/**
 * Strip path separators, control chars, and Unicode bidi spoofing overrides
 * (e.g. RLO U+202E) from untrusted filenames before displaying or downloading.
 */
export function sanitizeDisplayName(raw: string): string {
  const base = (raw || "").split(/[/\\]/).pop() || "";
  const out = base.replace(
    // deno-lint-ignore no-control-regex
    /[\x00-\x1f\x7f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g,
    "",
  );
  const trimmed = out.trim().slice(0, 120);
  return trimmed || "file.bin";
}

export function parseE2eeAttachment(
  text: string,
): E2eeAttachmentPayload | null {
  if (!text.startsWith(E2EE_ATT_PREFIX)) return null;
  try {
    const parsed = JSON.parse(text.slice(E2EE_ATT_PREFIX.length)) as Partial<
      E2eeAttachmentPayload
    >;
    if (parsed.v !== 1) return null;
    if (
      parsed.kind === "voice" && typeof parsed.id === "string" &&
      SAFE_E2EE_ID_RE.test(parsed.id) && typeof parsed.key === "string" &&
      typeof parsed.iv === "string" && typeof parsed.sha256 === "string"
    ) {
      return parsed as E2eeAttachmentPayload;
    }
    if (
      parsed.kind === "file" && typeof parsed.id === "string" &&
      SAFE_E2EE_ID_RE.test(parsed.id) && typeof parsed.key === "string" &&
      typeof parsed.iv === "string" && typeof parsed.sha256 === "string"
    ) {
      return parsed as E2eeAttachmentPayload;
    }
    if (
      parsed.kind === "album" && Array.isArray(parsed.items) &&
      parsed.items.length > 0 && parsed.items.length <= 10 &&
      parsed.items.every((it) =>
        it && typeof it.id === "string" && SAFE_E2EE_ID_RE.test(it.id) &&
        typeof it.key === "string" && typeof it.iv === "string" &&
        typeof it.sha256 === "string"
      )
    ) {
      return parsed as E2eeAttachmentPayload;
    }
    if (
      parsed.kind === "paste" && typeof parsed.id === "string" &&
      SAFE_E2EE_ID_RE.test(parsed.id) && typeof parsed.key === "string" &&
      typeof parsed.iv === "string" && typeof parsed.sha256 === "string"
    ) {
      return parsed as E2eeAttachmentPayload;
    }
    return null;
  } catch {
    return null;
  }
}

const IMAGE_EXTS = new Set(["png", "jpg", "jpeg", "gif", "webp"]);
const ARCHIVE_EXTS = new Set(["zip", "tar", "gz"]);
const TEXT_EXTS = new Set(["txt", "md", "csv", "json"]);
const MEDIA_EXTS = new Set(["mp4", "webm", "mp3", "ogg", "wav"]);

/** Format a byte count into a concise human-readable string (B, KB, MB, GB). */
export function formatBytes(bytes?: number): string {
  if (!bytes || !Number.isFinite(bytes) || bytes <= 0) return "";
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

/** Extract lowercase extension from a file ID or filename. */
export function extractExt(name: string): string {
  const dot = name.lastIndexOf(".");
  if (dot <= 0 || dot === name.length - 1) return "bin";
  const ext = name.slice(dot + 1).toLowerCase();
  return /^[a-z0-9]{1,8}$/.test(ext) ? ext : "bin";
}

/** Classify a file ID or filename into a visual badge category. */
export function classifyFile(nameOrId: string): {
  kind: FileCategory;
  ext: string;
} {
  const ext = extractExt(nameOrId);
  if (IMAGE_EXTS.has(ext)) return { kind: "image", ext };
  if (ext === "pdf") return { kind: "pdf", ext };
  if (ARCHIVE_EXTS.has(ext)) return { kind: "archive", ext };
  if (TEXT_EXTS.has(ext)) return { kind: "text", ext };
  if (MEDIA_EXTS.has(ext)) return { kind: "media", ext };
  return { kind: "file", ext };
}

/** Whether a validated file ID is a safe raster image suitable for inline preview. */
export function isPreviewImageId(fileId: string): boolean {
  return IMAGE_EXTS.has(extractExt(fileId));
}

function makeFileSvg(kind: FileCategory | "download"): SVGSVGElement {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", kind === "download" ? "16" : "20");
  svg.setAttribute("height", kind === "download" ? "16" : "20");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "2");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  svg.setAttribute("aria-hidden", "true");

  const add = (tag: string, attrs: Record<string, string>): void => {
    const el = document.createElementNS(ns, tag);
    for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
    svg.appendChild(el);
  };

  if (kind === "download") {
    add("path", { d: "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" });
    add("polyline", { points: "7 10 12 15 17 10" });
    add("line", { x1: "12", y1: "15", x2: "12", y2: "3" });
  } else if (kind === "image") {
    add("rect", { x: "3", y: "3", width: "18", height: "18", rx: "2" });
    add("circle", { cx: "8.5", cy: "8.5", r: "1.5" });
    add("polyline", { points: "21 15 16 10 5 21" });
  } else if (kind === "archive") {
    add("path", {
      d: "M21 8v13H3V8",
    });
    add("path", { d: "M1 3h22v5H1z" });
    add("line", { x1: "10", y1: "12", x2: "14", y2: "12" });
  } else if (kind === "media") {
    add("polygon", { points: "5 3 19 12 5 21 5 3" });
  } else {
    add("path", {
      d: "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z",
    });
    add("polyline", { points: "14 2 14 8 20 8" });
    if (kind === "text" || kind === "pdf") {
      add("line", { x1: "8", y1: "13", x2: "16", y2: "13" });
      add("line", { x1: "8", y1: "17", x2: "13", y2: "17" });
    }
  }
  return svg;
}

export function createFileCard(opts: FileCardOptions): HTMLElement {
  const url = opts.srcUrl || `/api/files/${opts.fileId}`;
  const displayName = sanitizeDisplayName(opts.fileName || opts.fileId);
  const { kind, ext } = classifyFile(displayName);
  const sizeText = formatBytes(opts.fileSize);
  const preview = opts.previewImage ?? isPreviewImageId(opts.fileId);

  const card = document.createElement("div");
  card.className = preview ? "file-card file-card-image" : "file-card";

  if (preview) {
    const link = document.createElement("button");
    link.type = "button";
    link.className = "file-preview-link";
    link.title = displayName;
    link.setAttribute("aria-label", displayName);
    const img = document.createElement("img");
    img.className = "file-preview-img";
    img.src = url;
    img.alt = displayName;
    img.loading = "lazy";
    link.appendChild(img);
    link.onclick = () => {
      openLightbox([
        { url, name: displayName, sizeText, encrypted: opts.encrypted },
      ], 0);
    };
    card.appendChild(link);
  }

  const row = document.createElement("div");
  row.className = "file-card-row";

  if (!preview) {
    const icon = document.createElement("div");
    icon.className = `file-icon file-icon-${kind}`;
    icon.appendChild(makeFileSvg(kind));
    row.appendChild(icon);
  }

  const info = document.createElement("div");
  info.className = "file-info";

  const nameEl = document.createElement("div");
  nameEl.className = "file-name";
  nameEl.dir = "auto";
  nameEl.textContent = displayName;
  nameEl.title = displayName;

  const meta = document.createElement("div");
  meta.className = "file-meta";
  const extPill = document.createElement("span");
  extPill.className = `file-ext file-ext-${kind}`;
  extPill.textContent = opts.encrypted
    ? `🔒 ${ext.toUpperCase()}`
    : ext.toUpperCase();
  meta.appendChild(extPill);
  if (sizeText) {
    const sizeEl = document.createElement("span");
    sizeEl.className = "file-size";
    sizeEl.textContent = sizeText;
    meta.appendChild(sizeEl);
  }

  info.appendChild(nameEl);
  info.appendChild(meta);
  row.appendChild(info);

  const dl = document.createElement("a");
  dl.className = "file-dl-btn";
  dl.href = url;
  dl.download = displayName;
  dl.rel = "noopener noreferrer";
  dl.title = opts.downloadLabel || "Download file";
  dl.setAttribute(
    "aria-label",
    `${opts.downloadLabel || "Download"} ${displayName}`,
  );
  dl.appendChild(makeFileSvg("download"));
  row.appendChild(dl);

  card.appendChild(row);
  return card;
}

export function createAlbumGrid(
  items: LightboxItem[],
  encrypted = false,
): HTMLElement {
  const grid = document.createElement("div");
  const cols = items.length >= 5 ? "cols-3" : "cols-2";
  grid.className = `album-grid ${cols}`;
  items.forEach((item, idx) => {
    const tile = document.createElement("button");
    tile.type = "button";
    tile.className = "album-tile";
    tile.title = item.name;
    tile.setAttribute("aria-label", item.name);
    const img = document.createElement("img");
    img.src = item.url;
    img.alt = item.name;
    img.loading = "lazy";
    tile.appendChild(img);
    if (encrypted && idx === 0) {
      const badge = document.createElement("span");
      badge.className = "album-e2ee-badge";
      badge.textContent = "🔒 E2EE";
      tile.appendChild(badge);
    }
    tile.onclick = () => openLightbox(items, idx);
    grid.appendChild(tile);
  });
  return grid;
}

async function fetchAndDecryptBlobUrl(
  id: string,
  mime: string,
  key: string,
  iv: string,
  sha256: string,
): Promise<string> {
  const cached = decryptedBlobCache.get(id);
  if (cached) return cached;
  const resp = await fetch(`/api/files/${id}`);
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
  const ct = new Uint8Array(await resp.arrayBuffer());
  const pt = decryptAttachment(ct, key, iv, sha256);
  const baseMime = (mime || "").split(";")[0].trim().toLowerCase();
  const safeMime =
    SAFE_IMAGE_MIMES.has(baseMime) || SAFE_AUDIO_MIMES.has(baseMime)
      ? baseMime
      : "application/octet-stream";
  const blob = new Blob([pt as BlobPart], { type: safeMime });
  const url = URL.createObjectURL(blob);
  if (decryptedBlobCache.size > 80) {
    const first = decryptedBlobCache.entries().next().value;
    if (first) {
      URL.revokeObjectURL(first[1]);
      decryptedBlobCache.delete(first[0]);
    }
  }
  decryptedBlobCache.set(id, url);
  return url;
}

export function createEncryptedAttachmentView(
  payload: E2eeAttachmentPayload,
  opts: { voiceLabel: string; downloadLabel: string },
): HTMLElement {
  const host = document.createElement("div");
  host.className = "e2ee-att-host";
  const loading = document.createElement("span");
  loading.className = "e2ee-att-status";
  loading.textContent = "🔒 Decrypting attachment...";
  host.appendChild(loading);

  if (payload.kind === "voice") {
    void fetchAndDecryptBlobUrl(
      payload.id,
      payload.mime || "audio/ogg",
      payload.key,
      payload.iv,
      payload.sha256,
    ).then((blobUrl) => {
      host.textContent = "";
      host.appendChild(
        createVoicePlayer({
          voiceId: payload.id,
          srcUrl: blobUrl,
          durationSec: payload.dur,
          label: opts.voiceLabel,
          encrypted: true,
        }),
      );
    }).catch(() => {
      loading.textContent = "🔒 Failed to decrypt voice message";
    });
  } else if (payload.kind === "file") {
    void fetchAndDecryptBlobUrl(
      payload.id,
      payload.mime || "application/octet-stream",
      payload.key,
      payload.iv,
      payload.sha256,
    ).then((blobUrl) => {
      host.textContent = "";
      host.appendChild(
        createFileCard({
          fileId: payload.id,
          fileName: payload.name || payload.id,
          fileSize: payload.bytes,
          srcUrl: blobUrl,
          previewImage: SAFE_IMAGE_MIMES.has(payload.mime),
          encrypted: true,
          downloadLabel: opts.downloadLabel,
        }),
      );
    }).catch(() => {
      loading.textContent = "🔒 Failed to decrypt file";
    });
  } else if (payload.kind === "album") {
    void Promise.all(
      payload.items.map(async (it) => {
        const url = await fetchAndDecryptBlobUrl(
          it.id,
          it.mime || "image/png",
          it.key,
          it.iv,
          it.sha256,
        );
        return {
          url,
          name: it.name || it.id,
          sizeText: formatBytes(it.bytes),
          encrypted: true,
        } satisfies LightboxItem;
      }),
    ).then((items) => {
      host.textContent = "";
      host.appendChild(createAlbumGrid(items, true));
    }).catch(() => {
      loading.textContent = "🔒 Failed to decrypt image album";
    });
  } else if (payload.kind === "paste") {
    void fetch(`/api/files/${payload.id}`).then(async (resp) => {
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const ct = new Uint8Array(await resp.arrayBuffer());
      const pt = decryptAttachment(ct, payload.key, payload.iv, payload.sha256);
      const code = new TextDecoder().decode(pt).slice(0, 65536);
      host.textContent = "";
      host.appendChild(
        createCodeCard({
          code,
          lang: payload.lang,
          title: payload.title,
          encrypted: true,
        }),
      );
    }).catch(() => {
      loading.textContent = "🔒 Failed to decrypt code snippet";
    });
  }

  return host;
}
