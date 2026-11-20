// Small pure helpers: nick colors, channel names, timestamps.
export const AVATAR_COLORS = [
  "#2563eb",
  "#0891b2",
  "#059669",
  "#7c3aed",
  "#db2777",
  "#d97706",
  "#dc2626",
  "#4f46e5",
];

export function nickColor(nick: string): string {
  let h = 0;
  for (let i = 0; i < nick.length; i++) {
    h = (h * 31 + nick.charCodeAt(i)) >>> 0;
  }
  return AVATAR_COLORS[h % AVATAR_COLORS.length];
}

export function isChan(name: string): boolean {
  return /^[#&+!]/.test(name || "");
}

export function fmtTime(iso?: string): { text: string; ms: number } {
  const d = iso ? new Date(iso) : new Date();
  if (Number.isNaN(d.getTime())) return { text: "", ms: Date.now() };
  return { text: d.toTimeString().slice(0, 5), ms: d.getTime() };
}
