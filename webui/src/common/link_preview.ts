/**
 * Zero-dependency OpenGraph Link Preview card for WebIRC.
 *
 * Fetches sanitized metadata from the server's SSRF-protected
 * `GET /api/link-preview?url=...` endpoint (never fetches external URLs or
 * third-party images directly from the browser, preserving user privacy and
 * strict CSP).
 */

export interface LinkPreviewData {
  url: string;
  domain: string;
  site_name?: string;
  title: string;
  description?: string;
}

const previewCache = new Map<string, LinkPreviewData | null>();
const HTTP_URL_RE = /https?:\/\/[^\s<>"'`)\]]{4,1000}/i;

/** Extract the first public http(s) URL from a chat message, if any. */
export function extractFirstHttpUrl(text: string): string | null {
  const m = HTTP_URL_RE.exec(text || "");
  if (!m) return null;
  const cleaned = m[0].replace(/[.,!?;:]+$/, "");
  try {
    const u = new URL(cleaned);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    if (u.hostname === "localhost" || u.hostname === "127.0.0.1") return null;
    return u.href;
  } catch {
    return null;
  }
}

function buildCardDom(data: LinkPreviewData): HTMLElement {
  const a = document.createElement("a");
  a.className = "og-card";
  a.href = data.url;
  a.target = "_blank";
  a.rel = "noopener noreferrer";

  const site = document.createElement("div");
  site.className = "og-site";
  site.textContent = data.site_name && data.site_name !== data.domain
    ? `${data.site_name} · ${data.domain}`
    : data.domain;

  const title = document.createElement("div");
  title.className = "og-title";
  title.dir = "auto";
  title.textContent = data.title;

  a.appendChild(site);
  a.appendChild(title);

  if (data.description) {
    const desc = document.createElement("div");
    desc.className = "og-desc";
    desc.dir = "auto";
    desc.textContent = data.description;
    a.appendChild(desc);
  }
  return a;
}

export function createLinkPreviewSlot(url: string): HTMLElement {
  const slot = document.createElement("div");
  slot.className = "og-slot";

  const cached = previewCache.get(url);
  if (cached !== undefined) {
    if (cached) slot.appendChild(buildCardDom(cached));
    return slot;
  }

  void fetch(`/api/link-preview?url=${encodeURIComponent(url)}`, {
    headers: { "X-Requested-With": "ircd-webui" },
  }).then(async (resp) => {
    if (!resp.ok) {
      previewCache.set(url, null);
      return;
    }
    const data = (await resp.json()) as Partial<LinkPreviewData>;
    if (!data.title || !data.domain) {
      previewCache.set(url, null);
      return;
    }
    const clean: LinkPreviewData = {
      url,
      domain: data.domain,
      site_name: data.site_name,
      title: data.title,
      description: data.description,
    };
    if (previewCache.size > 120) {
      const first = previewCache.keys().next().value;
      if (first) previewCache.delete(first);
    }
    previewCache.set(url, clean);
    slot.appendChild(buildCardDom(clean));
  }).catch(() => {
    previewCache.set(url, null);
  });

  return slot;
}
