// Small pure helpers: nick colors, channel names, timestamps.
/** Nickname colors: the `--nick-N` (text) and `--avatar-N` tokens. */
export const NICK_COLORS = 8;

/** A stable color index for `nick`, 0 to NICK_COLORS - 1. */
export function nickHue(nick: string): number {
  let h = 0;
  for (let i = 0; i < nick.length; i++) {
    h = (h * 31 + nick.charCodeAt(i)) >>> 0;
  }
  return h % NICK_COLORS;
}

/**
 * The class that colors `nick`: `nc-N` for its name as text, `av-N` for its
 * avatar background. Each theme sets the colors, so a nickname stays
 * readable in light and dark themes alike.
 */
export function nickClass(nick: string, kind: "nc" | "av"): string {
  return `${kind}-${nickHue(nick)}`;
}

export function isChan(name: string): boolean {
  return /^[#&+!]/.test(name || "");
}

export function fmtTime(iso?: string): { text: string; ms: number } {
  const d = iso ? new Date(iso) : new Date();
  if (Number.isNaN(d.getTime())) return { text: "", ms: Date.now() };
  return { text: d.toTimeString().slice(0, 5), ms: d.getTime() };
}
