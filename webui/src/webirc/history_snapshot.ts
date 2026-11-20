// Which conversations (channels and private ones) history_cache.ts keeps
// across a page reload, and how much of each (pure, unit-tested).
import type { ChatLine } from "./types.ts";

/** Newest lines kept per conversation. */
export const MAX_LINES = 150;
/** Most conversations kept, the most recently active first. */
export const MAX_CONVERSATIONS = 30;

export type StoredLine = Omit<ChatLine, "reactions">;
export type Stored = Record<string, { name: string; lines: StoredLine[] }>;

/** The conversations to keep, newest activity first, trimmed. */
export function snapshot(
  bufs: Iterable<[string, { name: string; lines: ChatLine[] }]>,
): Stored {
  const dms = [...bufs]
    .filter(([, b]) => b.name !== "*status" && b.lines.length > 0)
    .sort((a, b) =>
      (b[1].lines.at(-1)?.epochMs ?? 0) - (a[1].lines.at(-1)?.epochMs ?? 0)
    )
    .slice(0, MAX_CONVERSATIONS);
  const out: Stored = {};
  for (const [key, b] of dms) {
    out[key] = {
      name: b.name,
      // Reactions are a Map and change often; they come back with history.
      lines: b.lines.slice(-MAX_LINES).map(({ reactions: _r, ...l }) => l),
    };
  }
  return out;
}
