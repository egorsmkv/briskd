// IRC line parsing (message tags, prefix, parameters).
import { type IrcMessage } from "./types.ts";

export function parseIrc(raw: string): IrcMessage | null {
  let idx = 0;
  const tags: Record<string, string> = {};
  if (raw[0] === "@") {
    const sp = raw.indexOf(" ");
    if (sp === -1) return null;
    for (const pair of raw.slice(1, sp).split(";")) {
      const eq = pair.indexOf("=");
      if (eq === -1) tags[pair] = "";
      else tags[pair.slice(0, eq)] = pair.slice(eq + 1);
    }
    idx = sp + 1;
    while (raw[idx] === " ") idx++;
  }
  let prefix = "";
  if (raw[idx] === ":") {
    const sp = raw.indexOf(" ", idx);
    if (sp === -1) return null;
    prefix = raw.slice(idx + 1, sp);
    idx = sp + 1;
    while (raw[idx] === " ") idx++;
  }
  const params: string[] = [];
  let command = "";
  while (idx < raw.length) {
    if (raw[idx] === ":" && command) {
      params.push(raw.slice(idx + 1));
      break;
    }
    let sp = raw.indexOf(" ", idx);
    if (sp === -1) sp = raw.length;
    const tok = raw.slice(idx, sp);
    if (!command) command = tok.toUpperCase();
    else params.push(tok);
    idx = sp + 1;
    while (raw[idx] === " ") idx++;
  }
  const nick = prefix.includes("!")
    ? prefix.slice(0, prefix.indexOf("!"))
    : prefix;
  return { tags, prefix, nick, command, params };
}
