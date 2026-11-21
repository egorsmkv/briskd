// Message search (egorsmkv.github.io/search): building the SEARCH command,
// collecting a reply batch into results, and splitting a result's text into
// highlighted parts. Pure, so it is unit-tested in search_test.ts; the dialog
// is search_ui.ts.
import type { IrcMessage } from "./types.ts";

export const SEARCH_CAP = "egorsmkv.github.io/search";
export const SEARCH_BATCH = "egorsmkv.github.io/search";
/** Longest query the server accepts, UTF-8 bytes. */
export const MAX_QUERY_BYTES = 300;

export interface SearchHit {
  /** Where the message is: a channel, or the other side of a direct message. */
  conversation: string;
  nick: string;
  text: string;
  /** Milliseconds since the epoch. */
  time: number;
  msgid?: string;
}

export interface SearchResult {
  target: string;
  total: number;
  hits: SearchHit[];
}

export type SearchFeed =
  | { kind: "pass" }
  | { kind: "consumed" }
  | { kind: "done"; result: SearchResult }
  | { kind: "fail"; code: string; target: string; text: string };

/** The query as sent: one line, within the server's byte limit. */
export function cleanQuery(query: string): string {
  let q = query.replace(/[\r\n\0]+/g, " ").trim();
  const enc = new TextEncoder();
  while (enc.encode(q).length > MAX_QUERY_BYTES) {
    q = [...q].slice(0, -1).join("");
  }
  return q;
}

/**
 * `SEARCH <target> <limit> [timestamp=<before>] :<query>`. `target` is a
 * channel, a nickname, or `*` (every conversation); `before` (ms) pages back.
 */
export function searchCommand(
  target: string,
  limit: number,
  query: string,
  before?: number,
): string {
  const page = before === undefined
    ? ""
    : ` timestamp=${new Date(before).toISOString()}`;
  return `SEARCH ${target} ${limit}${page} :${cleanQuery(query)}`;
}

/** The conversation a result belongs to, as WebIRC names buffers. */
function conversationOf(
  msg: IrcMessage,
  myNick: string,
  fold: (s: string) => string,
): string {
  const target = msg.params[0] || "";
  if (/^[#&+!]/.test(target)) return target;
  // A direct message: the other person, whichever side sent it.
  return fold(msg.nick) === fold(myNick) ? target : msg.nick;
}

/** `\x01ACTION text\x01` shows as its text. */
function plainText(text: string): string {
  const start = "\u0001ACTION ";
  if (!text.startsWith(start)) return text;
  const body = text.slice(start.length);
  return body.endsWith("\u0001") ? body.slice(0, -1) : body;
}

/**
 * Collects SEARCH replies: the batch of type `egorsmkv.github.io/search`
 * (parameters: target and total matches) and the messages tagged with it,
 * and `FAIL SEARCH`. Feed every incoming message, after draft/multiline
 * batches are assembled; lines that are not search replies pass.
 */
export class SearchCollector {
  private open = new Map<string, SearchResult>();

  constructor(
    private myNick: () => string,
    private fold: (s: string) => string,
  ) {}

  feed(msg: IrcMessage): SearchFeed {
    const { command, params } = msg;
    if (command === "BATCH") {
      const ref = params[0] || "";
      if (ref.startsWith("+") && params[1] === SEARCH_BATCH) {
        this.open.set(ref.slice(1), {
          target: params[2] || "*",
          total: Number(params[3]) || 0,
          hits: [],
        });
        return { kind: "consumed" };
      }
      if (ref.startsWith("-") && this.open.has(ref.slice(1))) {
        const result = this.open.get(ref.slice(1)) as SearchResult;
        this.open.delete(ref.slice(1));
        return { kind: "done", result };
      }
      return { kind: "pass" };
    }
    const batch = msg.tags.batch;
    if (batch !== undefined && this.open.has(batch)) {
      if (command === "PRIVMSG" || command === "NOTICE") {
        const time = Date.parse(msg.tags.time || "");
        (this.open.get(batch) as SearchResult).hits.push({
          conversation: conversationOf(msg, this.myNick(), this.fold),
          nick: msg.nick,
          text: plainText(params[1] || ""),
          time: Number.isNaN(time) ? 0 : time,
          msgid: msg.tags.msgid || undefined,
        });
      }
      return { kind: "consumed" };
    }
    if (command === "FAIL" && params[0] === "SEARCH") {
      return {
        kind: "fail",
        code: params[1] || "",
        target: params.length > 3 ? params[2] : "",
        text: params[params.length - 1] || "",
      };
    }
    return { kind: "pass" };
  }

  /** Forget unfinished batches (the connection was lost). */
  clear(): void {
    this.open.clear();
  }
}

/**
 * Words of a query worth highlighting: not `-excluded`, not the `AND`/`OR`/
 * `NOT` operators, without quotes and a trailing `*`.
 */
export function queryTerms(query: string): string[] {
  const terms: string[] = [];
  for (const raw of query.match(/"[^"]*"|\S+/g) ?? []) {
    if (raw.startsWith("-") || /^(AND|OR|NOT)$/.test(raw)) continue;
    const term = raw.replace(/^\+/, "").replace(/^"|"$/g, "").replace(/\*$/, "")
      .trim();
    if (term) terms.push(term.toLocaleLowerCase());
  }
  return terms;
}

/** `text` split into parts, `match` where a query term occurs (any case). */
export function highlight(
  text: string,
  terms: string[],
): Array<{ text: string; match: boolean }> {
  const lower = text.toLocaleLowerCase();
  // Only case mappings that keep the length keep the offsets aligned.
  if (lower.length !== text.length || terms.length === 0) {
    return [{ text, match: false }];
  }
  const marks = new Array<boolean>(text.length).fill(false);
  for (const term of terms) {
    let from = 0;
    for (
      let at = lower.indexOf(term, from);
      at !== -1;
      at = lower.indexOf(term, from)
    ) {
      marks.fill(true, at, at + term.length);
      from = at + term.length;
    }
  }
  const parts: Array<{ text: string; match: boolean }> = [];
  let start = 0;
  for (let i = 1; i <= text.length; i++) {
    if (i === text.length || marks[i] !== marks[start]) {
      parts.push({ text: text.slice(start, i), match: marks[start] });
      start = i;
    }
  }
  return parts;
}
