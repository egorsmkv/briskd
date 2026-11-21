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

const KINDS = new Set(["", "sys", "err", "action", "notice"]);
/** Largest time a Date can hold (ms since the epoch). */
const MAX_TIME_MS = 8.64e15;

/**
 * A line read back from storage, rebuilt from fields of the right type, or
 * null. Storage can be edited, truncated, or written by another release, and
 * a bad field would otherwise break rendering or history requests (an
 * out-of-range time makes toISOString() throw).
 */
export function restoredLine(x: unknown): StoredLine | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  if (
    typeof o.text !== "string" || typeof o.time !== "string" ||
    typeof o.nick !== "string" || typeof o.epochMs !== "number" ||
    !Number.isFinite(o.epochMs) || o.epochMs < 0 || o.epochMs > MAX_TIME_MS ||
    typeof o.kind !== "string" || !KINDS.has(o.kind)
  ) {
    return null;
  }
  const line: StoredLine = {
    time: o.time,
    epochMs: o.epochMs,
    nick: o.nick,
    text: o.text,
    kind: o.kind as StoredLine["kind"],
  };
  for (
    const k of [
      "msgid",
      "account",
      "replyTo",
      "voiceId",
      "fileId",
      "fileName",
      "pasteId",
      "pasteLang",
      "pasteTitle",
    ] as const
  ) {
    if (typeof o[k] === "string") line[k] = o[k] as string;
  }
  for (
    const k of ["mention", "encrypted", "edited", "redacted", "bot"] as const
  ) {
    if (typeof o[k] === "boolean") line[k] = o[k] as boolean;
  }
  for (const k of ["voiceDur", "fileSize"] as const) {
    const v = o[k];
    if (typeof v === "number" && Number.isFinite(v) && v >= 0) line[k] = v;
  }
  if (
    Array.isArray(o.albumIds) && o.albumIds.every((a) => typeof a === "string")
  ) {
    line.albumIds = o.albumIds as string[];
  }
  return line;
}

/** The conversations in a stored snapshot, each with its valid lines. */
export function restoredConversations(
  raw: string,
): Array<{ name: string; lines: StoredLine[] }> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return [];
  const out: Array<{ name: string; lines: StoredLine[] }> = [];
  for (const entry of Object.values(parsed as Record<string, unknown>)) {
    if (!entry || typeof entry !== "object") continue;
    const { name, lines } = entry as { name?: unknown; lines?: unknown };
    if (typeof name !== "string" || name === "" || name === "*status") continue;
    if (!Array.isArray(lines)) continue;
    const valid = lines.map(restoredLine).filter((l): l is StoredLine =>
      l !== null
    );
    out.push({ name, lines: valid.slice(-MAX_LINES) });
    if (out.length >= MAX_CONVERSATIONS) break;
  }
  return out;
}
