// Pure rules of @-mention completion: find the "@query" being typed, rank
// matching nicknames, and insert the chosen one.

/** Candidates shown at most. */
export const MENTION_LIMIT = 8;

export interface MentionQuery {
  /** Index of the "@" in the text. */
  start: number;
  /** Text typed after "@" up to the caret. */
  query: string;
}

/**
 * The "@query" ending at `caret`, or null. The "@" must start the text or
 * follow whitespace or an opening bracket (so "user@host" does not trigger),
 * and the query has no whitespace, "@", ",", or ":".
 */
export function mentionQuery(text: string, caret: number): MentionQuery | null {
  const m = /(^|[\s([{])@([^\s@,:]{0,32})$/.exec(text.slice(0, caret));
  if (!m) return null;
  return { start: caret - m[2].length - 1, query: m[2] };
}

/**
 * Nicknames matching `query`, best first:
 *   1. the nickname starts with the query,
 *   2. a word of the display name starts with it,
 *   3. the nickname contains it;
 * within a tier, people who spoke recently come first (`recent` is newest
 * first), then by name. Comparison uses `fold` (the server's case mapping).
 */
export function rankMentions(
  query: string,
  nicks: Iterable<string>,
  opts: {
    fold: (s: string) => string;
    display?: (nick: string) => string;
    recent?: string[];
    exclude?: string;
    limit?: number;
  },
): string[] {
  const { fold } = opts;
  const q = fold(query);
  const recentRank = new Map<string, number>();
  (opts.recent ?? []).forEach((n, i) => {
    const k = fold(n);
    if (!recentRank.has(k)) recentRank.set(k, i);
  });
  const excluded = opts.exclude ? fold(opts.exclude) : null;
  const scored: Array<{ nick: string; tier: number; recent: number }> = [];
  const seen = new Set<string>();
  for (const nick of nicks) {
    const key = fold(nick);
    if (!nick || key === excluded || seen.has(key)) continue;
    seen.add(key);
    const display = opts.display ? fold(opts.display(nick)) : "";
    let tier: number;
    if (key.startsWith(q)) tier = 0;
    else if (display.split(/\s+/).some((w) => w.startsWith(q))) tier = 1;
    else if (key.includes(q)) tier = 2;
    else continue;
    scored.push({ nick, tier, recent: recentRank.get(key) ?? Infinity });
  }
  scored.sort((a, b) =>
    a.tier - b.tier || a.recent - b.recent ||
    fold(a.nick).localeCompare(fold(b.nick))
  );
  return scored.slice(0, opts.limit ?? MENTION_LIMIT).map((s) => s.nick);
}

/**
 * Replace the "@query" from `start` to `caret` with "@nick " and return the
 * new text and caret. No second space is added before an existing one.
 */
export function applyMention(
  text: string,
  start: number,
  caret: number,
  nick: string,
): { text: string; caret: number } {
  const after = text.slice(caret);
  const insert = after.startsWith(" ") ? `@${nick}` : `@${nick} `;
  return {
    text: text.slice(0, start) + insert + after,
    caret: start + insert.length + (after.startsWith(" ") ? 1 : 0),
  };
}
