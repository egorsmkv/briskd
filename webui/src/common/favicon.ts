export interface FaviconState {
  connected: boolean;
  unread: number;
  mentions: number;
}

let lastKey = "";

function roundedRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
): void {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function setIconHref(href: string, type: string): void {
  const head = document.head;
  if (!head) return;
  const existing = head.querySelectorAll(
    'link[rel="icon"], link[rel="shortcut icon"]',
  );
  existing.forEach((el) => el.remove());
  const link = document.createElement("link");
  link.rel = "icon";
  link.type = type;
  link.href = href;
  head.appendChild(link);
}

export function restoreDefaultFavicon(): void {
  if (lastKey === "default") return;
  lastKey = "default";
  const head = document.head;
  if (!head) return;
  head.querySelectorAll('link[rel="icon"], link[rel="shortcut icon"]').forEach((
    el,
  ) => el.remove());
  const ico = document.createElement("link");
  ico.rel = "icon";
  ico.href = "/favicon.ico";
  ico.setAttribute("sizes", "32x32");
  const svg = document.createElement("link");
  svg.rel = "icon";
  svg.type = "image/svg+xml";
  svg.href = "/favicon.svg";
  head.appendChild(ico);
  head.appendChild(svg);
}

export function updateDynamicFavicon(state: FaviconState): void {
  if (!state.connected) {
    restoreDefaultFavicon();
    return;
  }

  const badgeCount = state.mentions > 0 ? state.mentions : state.unread;
  const badgeLabel = badgeCount > 9
    ? "9+"
    : badgeCount > 0
    ? String(badgeCount)
    : "";
  const mode = state.mentions > 0
    ? "mention"
    : state.unread > 0
    ? "unread"
    : "online";
  const key = `${mode}:${badgeLabel}`;
  if (key === lastKey) return;
  lastKey = key;

  const canvas = document.createElement("canvas");
  canvas.width = 64;
  canvas.height = 64;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;

  // Base rounded square (#2563eb)
  roundedRect(ctx, 2, 2, 60, 60, 14);
  ctx.fillStyle = "#2563eb";
  ctx.fill();

  // White '#' IRC glyph
  ctx.strokeStyle = "#ffffff";
  ctx.lineWidth = 5.6;
  ctx.lineCap = "round";
  ctx.beginPath();
  ctx.moveTo(24.4, 15);
  ctx.lineTo(20.6, 49);
  ctx.moveTo(43.4, 15);
  ctx.lineTo(39.6, 49);
  ctx.moveTo(15, 25.2);
  ctx.lineTo(49, 25.2);
  ctx.moveTo(13.6, 38.8);
  ctx.lineTo(47.6, 38.8);
  ctx.stroke();

  if (mode === "online") {
    // Subtle green connected indicator in bottom-right
    ctx.beginPath();
    ctx.arc(51, 51, 11, 0, Math.PI * 2);
    ctx.fillStyle = "#ffffff";
    ctx.fill();
    ctx.beginPath();
    ctx.arc(51, 51, 8, 0, Math.PI * 2);
    ctx.fillStyle = "#16a34a";
    ctx.fill();
  } else {
    // Notification count badge in top-right (red for mentions/DMs, amber for unread)
    const cx = 46;
    const cy = 18;
    const r = 17;
    ctx.beginPath();
    ctx.arc(cx, cy, r + 2.5, 0, Math.PI * 2);
    ctx.fillStyle = "#ffffff";
    ctx.fill();
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.fillStyle = mode === "mention" ? "#dc2626" : "#f59e0b";
    ctx.fill();

    ctx.fillStyle = "#ffffff";
    ctx.font = badgeLabel.length > 1
      ? "700 18px sans-serif"
      : "700 22px sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(badgeLabel, cx, cy + 1);
  }

  setIconHref(canvas.toDataURL("image/png"), "image/png");
}
