// IRCv3 draft/multiline (https://ircv3.net/specs/extensions/multiline):
// assembling received batches into one message, and splitting composed text
// into the lines of an outgoing batch.
//
//   BATCH +ref draft/multiline <target>     (carries the message tags)
//   @batch=ref PRIVMSG <target> :line one
//   @batch=ref;draft/multiline-concat PRIVMSG <target> :…continued
//   BATCH -ref

export const MULTILINE_CAP = "draft/multiline";
export const CONCAT_TAG = "draft/multiline-concat";

/** The subset of a parsed IRC line this module needs. */
export interface BatchLine {
  tags: Record<string, string>;
  prefix: string;
  nick: string;
  command: string;
  params: string[];
}

export interface MultilineLimits {
  maxBytes: number;
  maxLines: number;
}

/** Parse `max-bytes=4096,max-lines=100`; absent or bad values are null. */
export function parseMultilineCap(value: string): MultilineLimits | null {
  const bytes = /(?:^|,)max-bytes=(\d+)/.exec(value);
  const lines = /(?:^|,)max-lines=(\d+)/.exec(value);
  const maxBytes = bytes ? parseInt(bytes[1], 10) : NaN;
  // max-bytes is required by the spec; max-lines is optional.
  if (!Number.isFinite(maxBytes) || maxBytes <= 0) return null;
  const maxLines = lines ? parseInt(lines[1], 10) : Infinity;
  return {
    maxBytes,
    maxLines: Number.isFinite(maxLines) && maxLines > 0 ? maxLines : Infinity,
  };
}

interface OpenBatch {
  prefix: string;
  nick: string;
  tags: Record<string, string>;
  target: string;
  command: string;
  text: string;
  lines: number;
}

export type FeedResult =
  | { kind: "pass" }
  | { kind: "consumed" }
  | { kind: "complete"; message: BatchLine };

// Bounds for untrusted input: open batches, lines and characters per batch.
const MAX_OPEN = 16;
const MAX_BATCH_LINES = 500;
const MAX_BATCH_CHARS = 64 * 1024;

/**
 * Collects the lines of `draft/multiline` batches. Feed every parsed line:
 * lines of an open multiline batch are consumed, and its end returns one
 * PRIVMSG or NOTICE whose text joins the lines with `\n` (or nothing, for
 * `draft/multiline-concat` lines), with the opening line's tags (msgid, time,
 * replies) and prefix. Other lines, including other batch types, pass.
 */
export class MultilineAssembler {
  private open = new Map<string, OpenBatch>();

  feed(msg: BatchLine): FeedResult {
    if (msg.command === "BATCH") return this.batch(msg);
    const ref = msg.tags.batch;
    const open = ref !== undefined ? this.open.get(ref) : undefined;
    if (!open) return { kind: "pass" };
    if (msg.command !== "PRIVMSG" && msg.command !== "NOTICE") {
      return { kind: "consumed" };
    }
    const line = msg.params[1] ?? "";
    if (open.lines === 0) {
      open.command = msg.command;
      open.text = line;
    } else {
      open.text += (CONCAT_TAG in msg.tags ? "" : "\n") + line;
    }
    open.lines++;
    if (open.lines > MAX_BATCH_LINES || open.text.length > MAX_BATCH_CHARS) {
      // Over the bound: drop the batch rather than grow without limit.
      this.open.delete(ref!);
    }
    return { kind: "consumed" };
  }

  /** Forget every open batch (the connection was reset). */
  clear(): void {
    this.open.clear();
  }

  private batch(msg: BatchLine): FeedResult {
    const first = msg.params[0] ?? "";
    const ref = first.slice(1);
    if (!ref) return { kind: "pass" };
    if (first[0] === "+") {
      if (msg.params[1]?.toLowerCase() !== MULTILINE_CAP) {
        return { kind: "pass" };
      }
      if (this.open.size >= MAX_OPEN) {
        const oldest = this.open.keys().next().value;
        if (oldest !== undefined) this.open.delete(oldest);
      }
      const tags = { ...msg.tags };
      this.open.set(ref, {
        prefix: msg.prefix,
        nick: msg.nick,
        tags,
        target: msg.params[2] ?? "",
        command: "PRIVMSG",
        text: "",
        lines: 0,
      });
      return { kind: "consumed" };
    }
    if (first[0] === "-") {
      const open = this.open.get(ref);
      if (!open) return { kind: "pass" };
      this.open.delete(ref);
      if (open.lines === 0) return { kind: "consumed" };
      return {
        kind: "complete",
        message: {
          tags: open.tags,
          prefix: open.prefix,
          nick: open.nick,
          command: open.command,
          params: [open.target, open.text],
        },
      };
    }
    return { kind: "pass" };
  }
}

export interface OutLine {
  text: string;
  /** Joined to the previous line without a line break. */
  concat: boolean;
}

/** UTF-8 byte length. */
export function utf8Bytes(s: string): number {
  return new TextEncoder().encode(s).length;
}

/**
 * Split composed text into batch lines: one per line break, and lines over
 * `maxLineBytes` (UTF-8) cut into `concat` continuations, at a space when
 * there is one, never inside a character. Trailing blank lines are dropped.
 */
export function splitMultiline(text: string, maxLineBytes: number): OutLine[] {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  while (lines.length > 0 && lines[lines.length - 1].trim() === "") {
    lines.pop();
  }
  const out: OutLine[] = [];
  for (const line of lines) {
    let rest = line;
    let concat = false;
    do {
      const piece = takeBytes(rest, maxLineBytes);
      out.push({ text: piece, concat });
      rest = rest.slice(piece.length);
      concat = true;
    } while (rest.length > 0);
  }
  return out;
}

/** The longest prefix of `s` within `max` UTF-8 bytes, ending at a space if possible. */
function takeBytes(s: string, max: number): string {
  if (utf8Bytes(s) <= max) return s;
  let bytes = 0;
  let end = 0;
  for (const ch of s) {
    const n = utf8Bytes(ch);
    if (bytes + n > max) break;
    bytes += n;
    end += ch.length;
  }
  if (end === 0) end = [...s][0].length; // a single character over the limit
  // Prefer to break after a space, unless that leaves a tiny piece.
  const space = s.lastIndexOf(" ", end - 1);
  return space > end / 2 ? s.slice(0, space + 1) : s.slice(0, end);
}

/**
 * Body size as the server counts it for `max-bytes`: the line texts plus a
 * line break between lines that are not concatenated.
 */
export function multilineBytes(lines: OutLine[]): number {
  let total = 0;
  lines.forEach((l, i) => {
    total += utf8Bytes(l.text) + (i > 0 && !l.concat ? 1 : 0);
  });
  return total;
}
