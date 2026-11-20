// Pure helpers for the IRCv3 extensions the WebIRC client consumes:
// multi-prefix / userhost-in-names (353), WHOX (354), MONITOR (730/731),
// draft/metadata-2 values, draft/read-marker timestamps, and standard replies.

/** User metadata keys the client subscribes to (draft/metadata-2). */
export const METADATA_KEYS = [
  "avatar",
  "display-name",
  "pronouns",
  "status",
  "homepage",
] as const;

export type MetadataKey = typeof METADATA_KEYS[number];

/** Longest metadata value kept client-side, in UTF-16 code units. */
export const MAX_META_VALUE = 300;

/** Token used to recognise our own WHOX replies. */
export const WHOX_TOKEN = "152";

/** WHOX field selection: token, channel, nick, flags, account. */
export const WHOX_FIELDS = `%tcnfa,${WHOX_TOKEN}`;

export interface NamesEntry {
  nick: string;
  prefix: string;
  userhost?: string;
}

/**
 * Parse one RPL_NAMREPLY (353) entry. With multi-prefix the entry may carry
 * several prefix characters (`@+nick`); with userhost-in-names it carries
 * `nick!user@host`.
 */
export function parseNamesEntry(
  entry: string,
  prefixChars = "~&@%+",
): NamesEntry | null {
  let i = 0;
  while (i < entry.length && prefixChars.includes(entry[i])) i++;
  const prefix = entry.slice(0, i);
  const rest = entry.slice(i);
  if (!rest) return null;
  const bang = rest.indexOf("!");
  if (bang === -1) return { nick: rest, prefix };
  const nick = rest.slice(0, bang);
  if (!nick) return null;
  return { nick, prefix, userhost: rest.slice(bang + 1) };
}

/** Prefix characters from an RPL_ISUPPORT `PREFIX=(ov)@+` value. */
export function prefixCharsFromIsupport(value: string | undefined): string {
  const m = /^\(([^)]*)\)(.*)$/.exec(value || "");
  return m && m[2] ? m[2] : "~&@%+";
}

export interface WhoxEntry {
  channel: string;
  nick: string;
  away: boolean;
  bot: boolean;
  oper: boolean;
  /** Raw WHO flags, including channel prefixes under multi-prefix. */
  flags: string;
  account?: string;
}

/**
 * Parse an RPL_WHOSPCRPL (354) reply to `WHO <mask> %tcnfa,<token>`.
 * `params` are the message parameters including the leading client nick.
 * Returns null for a reply carrying another token.
 */
export function parseWhoxReply(
  params: string[],
  token = WHOX_TOKEN,
): WhoxEntry | null {
  if (params.length < 6 || params[1] !== token) return null;
  const [, , channel, nick, flags, account] = params;
  if (!nick) return null;
  return {
    channel,
    nick,
    away: flags.startsWith("G"),
    bot: flags.includes("B"),
    oper: flags.includes("*"),
    flags,
    account: account && account !== "0" ? account : undefined,
  };
}

/** Targets in a MONITOR 730/731 trailing list (`nick[!user@host],...`). */
export function parseMonitorTargets(
  list: string,
): Array<{ nick: string; userhost?: string }> {
  const out: Array<{ nick: string; userhost?: string }> = [];
  for (const item of list.split(",")) {
    const target = item.trim();
    if (!target) continue;
    const bang = target.indexOf("!");
    if (bang === -1) out.push({ nick: target });
    else if (bang > 0) {
      out.push({
        nick: target.slice(0, bang),
        userhost: target.slice(bang + 1),
      });
    }
  }
  return out;
}

/**
 * Accept an `avatar` metadata value only when it is an absolute https URL or
 * a same-origin `/api/files/<id>` path; anything else is dropped so a peer
 * cannot point the page at `javascript:`, `data:`, or plain-http content.
 */
export function safeAvatarUrl(value: string | undefined): string | null {
  if (!value || value.length > MAX_META_VALUE) return null;
  if (/^\/api\/files\/[0-9a-f]{32}\.[a-z0-9]{1,8}$/.test(value)) return value;
  try {
    const u = new URL(value);
    return u.protocol === "https:" ? u.href : null;
  } catch {
    return null;
  }
}

/** Same as `safeAvatarUrl` for `homepage`, also allowing plain http. */
export function safeHomepageUrl(value: string | undefined): string | null {
  if (!value || value.length > MAX_META_VALUE) return null;
  try {
    const u = new URL(value);
    return u.protocol === "https:" || u.protocol === "http:" ? u.href : null;
  } catch {
    return null;
  }
}

/** Strip control characters and bound a display-oriented metadata value. */
export function cleanMetaText(value: string, max = 64): string {
  // deno-lint-ignore no-control-regex
  const clean = value.replace(/[\x00-\x1f\x7f‪-‮⁦-⁩]/g, "")
    .trim();
  return clean.length > max ? clean.slice(0, max) : clean;
}

/**
 * Milliseconds from a `MARKREAD` value (`timestamp=...` or `*`), or null when
 * no marker is set or the value is malformed.
 */
export function markerToMs(value: string | undefined): number | null {
  if (!value || !value.startsWith("timestamp=")) return null;
  const ms = Date.parse(value.slice("timestamp=".length));
  return Number.isNaN(ms) ? null : ms;
}

/** `timestamp=YYYY-MM-DDThh:mm:ss.sssZ` for a `MARKREAD` request. */
export function msToMarker(ms: number): string {
  return `timestamp=${new Date(ms).toISOString()}`;
}

/**
 * Human text for an IRCv3 standard reply: `FAIL|WARN|NOTE <command> <code>
 * [context...] :<description>`.
 */
export function formatStandardReply(kind: string, params: string[]): string {
  const command = params[0] || "*";
  const code = params[1] || "";
  const description = params.length > 2 ? params[params.length - 1] : "";
  const label = command === "*" ? kind : `${kind} ${command}`;
  return description
    ? `${label}: ${description}${code ? ` (${code})` : ""}`
    : `${label} ${code}`.trim();
}
