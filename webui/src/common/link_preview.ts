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
const PREVIEW_CACHE_MAX = 200;

function cachePreview(url: string, data: LinkPreviewData | null): void {
  previewCache.delete(url);
  previewCache.set(url, data);
  if (previewCache.size > PREVIEW_CACHE_MAX) {
    const oldest = previewCache.keys().next().value;
    if (oldest !== undefined) previewCache.delete(oldest);
  }
}
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

/** Requests in flight, by URL: every slot for one URL shares a request. */
const inFlight = new Map<string, Promise<LinkPreviewData | null>>();

/**
 * The preview for `url`, fetched once: cached results (including "no
 * preview") are reused, and concurrent callers share the request. The list
 * re-renders many times while a conversation fills (history, member lists),
 * which used to send the same request each time.
 */
export function loadLinkPreview(
  url: string,
  fetchFn: typeof fetch = fetch,
): Promise<LinkPreviewData | null> {
  const cached = previewCache.get(url);
  if (cached !== undefined) return Promise.resolve(cached);
  const pending = inFlight.get(url);
  if (pending) return pending;
  const request = fetchFn(`/api/link-preview?url=${encodeURIComponent(url)}`, {
    headers: { "X-Requested-With": "ircd-webui" },
  }).then(async (resp): Promise<LinkPreviewData | null> => {
    // 204: the page has no usable preview.
    if (resp.status === 204 || !resp.ok) return null;
    const data = (await resp.json()) as Partial<LinkPreviewData>;
    if (!data.title || !data.domain) return null;
    return {
      url,
      domain: data.domain,
      site_name: data.site_name,
      title: data.title,
      description: data.description,
    };
  }).catch(() => null).then((result) => {
    cachePreview(url, result);
    inFlight.delete(url);
    return result;
  });
  inFlight.set(url, request);
  return request;
}

export function createLinkPreviewSlot(url: string): HTMLElement {
  const slot = document.createElement("div");
  slot.className = "og-slot";
  const cached = previewCache.get(url);
  if (cached !== undefined) {
    if (cached) slot.appendChild(buildCardDom(cached));
    return slot;
  }
  void loadLinkPreview(url).then((data) => {
    if (data) slot.appendChild(buildCardDom(data));
  });
  return slot;
}
