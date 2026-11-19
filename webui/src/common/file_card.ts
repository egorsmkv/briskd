/**
 * Custom zero-dependency file attachment card for WebIRC.
 *
 * Renders inline image previews for safe raster formats (PNG, JPEG, GIF, WebP)
 * and color-coded, theme-aware file cards with size badges and one-click
 * download links for documents, archives, text, media, and general files.
 */

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
  downloadLabel?: string;
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
  const url = `/api/files/${opts.fileId}`;
  const displayName = opts.fileName || opts.fileId;
  const { kind, ext } = classifyFile(opts.fileId);
  const sizeText = formatBytes(opts.fileSize);
  const preview = isPreviewImageId(opts.fileId);

  const card = document.createElement("div");
  card.className = preview ? "file-card file-card-image" : "file-card";

  if (preview) {
    const link = document.createElement("a");
    link.className = "file-preview-link";
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    const img = document.createElement("img");
    img.className = "file-preview-img";
    img.src = url;
    img.alt = displayName;
    img.loading = "lazy";
    link.appendChild(img);
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
  extPill.textContent = ext.toUpperCase();
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
