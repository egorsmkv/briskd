/// <reference lib="deno.ns" />
import {
  applyCommand,
  COMMAND_LIMIT,
  COMMANDS,
  findCommand,
  rankCommands,
  slashState,
  usage,
} from "./slash.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

const names = (q: string, avail?: Parameters<typeof rankCommands>[1]) =>
  rankCommands(q, avail).map((c) => c.name).join(",");

Deno.test("slashState: name, arguments, or not a command", () => {
  assert(slashState("/", 1)?.kind === "name", "a lone slash lists commands");
  const s = slashState("/jo", 3);
  assert(s?.kind === "name" && s.query === "jo", "query is the typed name");
  const caretInside = slashState("/join #a", 2);
  assert(
    caretInside?.kind === "name" && caretInside.query === "j",
    "caret inside the first word: completing the name",
  );
  const args = slashState("/kick bob", 9);
  assert(args?.kind === "args" && args.spec.name === "kick", "args of /kick");
  const alias = slashState("/j #x", 5);
  assert(alias?.kind === "args" && alias.spec.name === "join", "alias /j");
  assert(slashState("/nosuch x", 9) === null, "unknown command: no hint");
  assert(slashState("hello /join", 11) === null, "not at the start");
  assert(slashState("//not a command", 5) === null, "// sends a slash");
  assert(slashState("/join\n#x", 3) === null, "multi-line is not a command");
  assert(slashState("/jo-in", 6) === null, "names are letters and digits");
});

Deno.test("rankCommands: prefix, then alias, then substring", () => {
  assert(names("jo").startsWith("join"), "join first for jo");
  assert(names("q").split(",")[0] === "quit", `quit before msg: ${names("q")}`);
  assert(names("q").includes("msg"), "the alias /query finds msg");
  assert(names("raw") === "raw", "exact");
  assert(names("zzz") === "", "no match");
  assert(names("").split(",").length === COMMAND_LIMIT, "an empty query lists");
  const notOper = names("k", (c) => c.needs !== "oper");
  assert(!notOper.includes("kill"), "operator commands hidden");
  assert(notOper.includes("kick"), "kick stays");
});

Deno.test("applyCommand inserts the name and keeps arguments", () => {
  const kick = findCommand("kick")!;
  let r = applyCommand("/ki", kick);
  assert(r.text === "/kick " && r.caret === 6, JSON.stringify(r));
  r = applyCommand("/ki bob", kick);
  assert(r.text === "/kick bob" && r.caret === 6, JSON.stringify(r));
  r = applyCommand("/cl", findCommand("clear")!);
  assert(r.text === "/clear" && r.caret === 6, "no space without arguments");
});

Deno.test("the table: unique names and aliases, usage strings", () => {
  const all = COMMANDS.flatMap((c) => [c.name, ...(c.aliases ?? [])]);
  assert(new Set(all).size === all.length, "no duplicate names");
  assert(usage(findCommand("query")!) === "/msg <nick> <text>", "usage");
  assert(findCommand("JOIN")?.name === "join", "case-insensitive");
});
