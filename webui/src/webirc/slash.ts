// The slash commands WebIRC understands (commands.ts runs them), and the
// pure rules of the command list in the message box: whether a "/command"
// is being typed, which commands match, and what choosing one inserts.
// /help prints this same table, so the list and the help never disagree.

/** When a command applies; the picker hides those that do not. */
export type CommandNeed = "channel" | "calls" | "e2ee" | "oper" | "search";

export interface CommandSpec {
  name: string;
  aliases?: string[];
  /** Argument syntax, e.g. "<nick> [reason]". */
  args?: string;
  /** i18n key of the one-line description. */
  desc: string;
  needs?: CommandNeed;
}

export const COMMANDS: CommandSpec[] = [
  { name: "join", aliases: ["j"], args: "#channel [key]", desc: "cmd.join" },
  {
    name: "part",
    aliases: ["leave"],
    args: "[#channel] [reason]",
    desc: "cmd.part",
  },
  {
    name: "msg",
    aliases: ["query", "pm"],
    args: "<nick> <text>",
    desc: "cmd.msg",
  },
  { name: "notice", args: "<target> <text>", desc: "cmd.notice" },
  { name: "me", args: "<action>", desc: "cmd.me" },
  { name: "nick", args: "<new nick>", desc: "cmd.nick" },
  { name: "topic", args: "[new topic]", desc: "cmd.topic", needs: "channel" },
  { name: "mode", args: "<target> [modes]", desc: "cmd.mode" },
  {
    name: "kick",
    args: "<nick> [reason]",
    desc: "cmd.kick",
    needs: "channel",
  },
  { name: "invite", args: "<nick> [#channel]", desc: "cmd.invite" },
  { name: "whois", args: "<nick>", desc: "cmd.whois" },
  { name: "whowas", args: "<nick>", desc: "cmd.whowas" },
  { name: "who", args: "[mask]", desc: "cmd.who" },
  { name: "names", args: "[#channel]", desc: "cmd.names" },
  { name: "list", args: "[filter]", desc: "cmd.list" },
  { name: "away", args: "[message]", desc: "cmd.away" },
  { name: "back", desc: "cmd.back" },
  { name: "setname", args: "<real name>", desc: "cmd.setname" },
  { name: "monitor", args: "+|- <nick>", desc: "cmd.monitor" },
  { name: "history", args: "[limit]", desc: "cmd.history" },
  { name: "search", args: "[words]", desc: "cmd.search", needs: "search" },
  { name: "meta", args: "set|clear|list …", desc: "cmd.meta" },
  { name: "call", args: "[nick]", desc: "cmd.call", needs: "calls" },
  { name: "hangup", desc: "cmd.hangup", needs: "calls" },
  {
    name: "e2ee",
    args: "on|off|status|rotate|verify|reset",
    desc: "cmd.e2ee",
    needs: "e2ee",
  },
  { name: "oper", args: "<name> <password>", desc: "cmd.oper" },
  { name: "kill", args: "<nick> <reason>", desc: "cmd.kill", needs: "oper" },
  { name: "rehash", desc: "cmd.rehash", needs: "oper" },
  { name: "clear", desc: "cmd.clear" },
  { name: "raw", aliases: ["quote"], args: "<line>", desc: "cmd.raw" },
  { name: "quit", args: "[reason]", desc: "cmd.quit" },
  { name: "help", desc: "cmd.help" },
];

/** Commands shown at most. */
export const COMMAND_LIMIT = 8;

/** "/name args", for the list and /help. */
export function usage(spec: CommandSpec): string {
  return spec.args ? `/${spec.name} ${spec.args}` : `/${spec.name}`;
}

export type SlashState =
  /** Typing the command name: `query` is what follows "/". */
  | { kind: "name"; query: string }
  /** Typing the arguments of a known command. */
  | { kind: "args"; spec: CommandSpec };

/**
 * What is being typed, for a message box holding `text` with the caret at
 * `caret`: a command name (the text starts with "/" and the caret is still
 * in the first word), the arguments of a known command, or nothing. "//"
 * (a message that starts with a slash) and multi-line text are not
 * commands.
 */
export function slashState(text: string, caret: number): SlashState | null {
  if (!text.startsWith("/") || text.startsWith("//") || text.includes("\n")) {
    return null;
  }
  const space = text.search(/\s/);
  if (space === -1 || caret <= space) {
    const query = text.slice(1, caret);
    return /^[a-z0-9]*$/i.test(query) ? { kind: "name", query } : null;
  }
  const spec = findCommand(text.slice(1, space));
  return spec ? { kind: "args", spec } : null;
}

/** The command `name` or one of its aliases names, ignoring case. */
export function findCommand(
  name: string,
  commands: CommandSpec[] = COMMANDS,
): CommandSpec | undefined {
  const n = name.toLowerCase();
  return commands.find((c) => c.name === n || c.aliases?.includes(n));
}

/**
 * Commands matching `query`, best first: the name starts with it, then an
 * alias does, then the name contains it; ties keep the table's order, which
 * lists everyday commands first. `available` drops commands that do not
 * apply here (not an operator, no calls on this server, ...).
 */
export function rankCommands(
  query: string,
  available: (spec: CommandSpec) => boolean = () => true,
  commands: CommandSpec[] = COMMANDS,
  limit = COMMAND_LIMIT,
): CommandSpec[] {
  const q = query.toLowerCase();
  const tier = (c: CommandSpec): number =>
    c.name.startsWith(q)
      ? 0
      : c.aliases?.some((a) => a.startsWith(q))
      ? 1
      : c.name.includes(q)
      ? 2
      : -1;
  return commands
    .map((c, i) => ({ c, i, t: tier(c) }))
    .filter(({ c, t }) => t >= 0 && available(c))
    .sort((a, b) => a.t - b.t || a.i - b.i)
    .slice(0, limit)
    .map(({ c }) => c);
}

/**
 * The message box after choosing `spec` while typing its name: "/name "
 * (with a space when it takes arguments) replaces the first word, and the
 * caret goes after it.
 */
export function applyCommand(
  text: string,
  spec: CommandSpec,
): { text: string; caret: number } {
  const space = text.search(/\s/);
  const rest = space === -1 ? "" : text.slice(space).replace(/^\s+/, "");
  const head = spec.args ? `/${spec.name} ` : `/${spec.name}`;
  return { text: head + rest, caret: head.length };
}
