// Pure helpers of the admin panel: number formatting, filters, paging, and
// the tab named by a URL (unit-tested in format_test.ts).

/** The admin tabs in display order. */
export const TABS = [
  "overview",
  "stats",
  "clients",
  "channels",
  "links",
  "accounts",
  "dronebl",
  "media",
  "operations",
] as const;

export type Tab = typeof TABS[number];

const VALID_TABS = new Set<string>(TABS);

/** Whether `name` is an admin tab. */
export function isTab(name: string): name is Tab {
  return VALID_TABS.has(name);
}

/** The tab for `/admin/<tab>`, else a `#<tab>` hash, else "overview". */
export function tabFromLocation(pathname: string, hash: string): Tab {
  const m = pathname.match(/^\/admin\/([a-z]+)\/?$/i);
  if (m) {
    const t = m[1].toLowerCase();
    if (isTab(t)) return t;
  }
  const h = hash.replace(/^#/, "").toLowerCase();
  return isTab(h) ? h : "overview";
}

/** The URL path of a tab. */
export function tabPath(tab: Tab): string {
  return tab === "overview" ? "/admin" : `/admin/${tab}`;
}

/** "1d 2h 3m 4s" (days only when non-zero). */
export function fmtUptime(s: number): string {
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return (d ? `${d}d ` : "") + `${h}h ${m}m ${sec}s`;
}

/** Binary-prefixed size: "512 B", "1.5 KiB", "2.0 MiB", "1.00 GiB". */
export function fmtBytes(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GiB`;
  }
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${bytes} B`;
}

/** Whether a client host is a literal IPv4 or IPv6 address. */
export function isIpAddress(host?: string): boolean {
  if (!host) return false;
  return /^(\d{1,3}\.){3}\d{1,3}$/.test(host) ||
    /^[0-9a-fA-F:]+$/.test(host) && host.includes(":");
}

/** Case-insensitive substring match of `query` in any field; "" matches. */
export function matchesFilter(
  query: string,
  ...fields: Array<string | undefined | null>
): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return fields.some((f) => (f || "").toLowerCase().includes(q));
}

export interface PageWindow {
  /** The current page, clamped to 1..totalPages. */
  page: number;
  totalPages: number;
  /** Slice bounds: rows[start, end). */
  start: number;
  end: number;
}

/** The rows of page `page` (clamped) of `total` rows, `size` per page. */
export function pageWindow(
  total: number,
  size: number,
  page: number,
): PageWindow {
  const totalPages = Math.max(1, Math.ceil(total / size));
  const p = Math.min(Math.max(page, 1), totalPages);
  const start = (p - 1) * size;
  return { page: p, totalPages, start, end: Math.min(start + size, total) };
}
