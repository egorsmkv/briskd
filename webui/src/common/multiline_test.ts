/// <reference lib="deno.ns" />
import {
  type BatchLine,
  MultilineAssembler,
  multilineBytes,
  parseMultilineCap,
  splitMultiline,
  utf8Bytes,
} from "./multiline.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

function line(
  command: string,
  params: string[],
  tags: Record<string, string> = {},
): BatchLine {
  return { tags, prefix: "alice!a@h", nick: "alice", command, params };
}

Deno.test("cap value parsing", () => {
  const l = parseMultilineCap("max-bytes=4096,max-lines=100");
  assert(l?.maxBytes === 4096 && l.maxLines === 100, "both limits");
  const only = parseMultilineCap("max-bytes=2048");
  assert(only?.maxLines === Infinity, "max-lines optional");
  assert(parseMultilineCap("max-lines=5") === null, "max-bytes required");
  assert(parseMultilineCap("") === null, "empty");
});

Deno.test("a multiline batch becomes one message with the opening tags", () => {
  const a = new MultilineAssembler();
  const open = line("BATCH", ["+r1", "draft/multiline", "#chan"], {
    msgid: "m1",
    time: "2026-01-01T00:00:00Z",
  });
  assert(a.feed(open).kind === "consumed", "open consumed");
  const b = { batch: "r1" };
  assert(
    a.feed(line("PRIVMSG", ["#chan", "hello"], b)).kind === "consumed",
    "1",
  );
  a.feed(line("PRIVMSG", ["#chan", ""], b));
  a.feed(line("PRIVMSG", ["#chan", "wor"], b));
  a.feed(
    line("PRIVMSG", ["#chan", "ld"], {
      batch: "r1",
      "draft/multiline-concat": "",
    }),
  );
  const end = a.feed(line("BATCH", ["-r1"]));
  assert(end.kind === "complete", "complete");
  if (end.kind !== "complete") return;
  assert(end.message.params[1] === "hello\n\nworld", "joined text");
  assert(end.message.params[0] === "#chan", "target");
  assert(end.message.command === "PRIVMSG", "command");
  assert(end.message.tags.msgid === "m1", "opening msgid kept");
  assert(end.message.nick === "alice", "sender kept");
});

Deno.test("NOTICE batches and other batch types", () => {
  const a = new MultilineAssembler();
  a.feed(line("BATCH", ["+n", "draft/multiline", "bob"]));
  a.feed(line("NOTICE", ["bob", "a"], { batch: "n" }));
  a.feed(line("NOTICE", ["bob", "b"], { batch: "n" }));
  const end = a.feed(line("BATCH", ["-n"]));
  assert(end.kind === "complete" && end.message.command === "NOTICE", "notice");
  // A chathistory batch is left to the caller, and so are its lines.
  assert(
    a.feed(line("BATCH", ["+h", "chathistory", "#c"])).kind === "pass",
    "+h",
  );
  assert(
    a.feed(line("PRIVMSG", ["#c", "x"], { batch: "h" })).kind === "pass",
    "history line",
  );
  assert(a.feed(line("BATCH", ["-h"])).kind === "pass", "-h");
  // Unbatched lines pass.
  assert(a.feed(line("PRIVMSG", ["#c", "x"])).kind === "pass", "plain");
});

Deno.test("empty batch and unknown end produce nothing", () => {
  const a = new MultilineAssembler();
  a.feed(line("BATCH", ["+e", "draft/multiline", "#c"]));
  assert(a.feed(line("BATCH", ["-e"])).kind === "consumed", "empty batch");
  assert(a.feed(line("BATCH", ["-zz"])).kind === "pass", "unknown end");
});

Deno.test("open batches are bounded", () => {
  const a = new MultilineAssembler();
  for (let i = 0; i < 40; i++) {
    a.feed(line("BATCH", [`+b${i}`, "draft/multiline", "#c"]));
  }
  // The oldest were evicted: their lines now pass through.
  assert(
    a.feed(line("PRIVMSG", ["#c", "x"], { batch: "b0" })).kind === "pass",
    "evicted",
  );
  assert(
    a.feed(line("PRIVMSG", ["#c", "x"], { batch: "b39" })).kind === "consumed",
    "newest kept",
  );
  // An oversized batch is dropped.
  a.feed(line("BATCH", ["+big", "draft/multiline", "#c"]));
  for (let i = 0; i < 600; i++) {
    a.feed(line("PRIVMSG", ["#c", "x"], { batch: "big" }));
  }
  assert(a.feed(line("BATCH", ["-big"])).kind === "pass", "dropped batch");
});

Deno.test("splitting keeps line breaks and cuts long lines", () => {
  const out = splitMultiline("one\r\ntwo\n\nthree\n\n", 400);
  assert(
    JSON.stringify(out.map((l) => l.text)) ===
      JSON.stringify(["one", "two", "", "three"]),
    "lines, trailing blanks dropped",
  );
  assert(out.every((l) => !l.concat), "no continuations");

  const long = "word ".repeat(50).trim(); // 249 bytes
  const pieces = splitMultiline(long, 60);
  assert(pieces.length > 1, "cut");
  assert(!pieces[0].concat && pieces.slice(1).every((l) => l.concat), "concat");
  assert(pieces.every((l) => utf8Bytes(l.text) <= 60), "within limit");
  assert(pieces.map((l) => l.text).join("") === long, "lossless");
  assert(pieces.every((l) => l.text.length > 0), "no blank continuation");

  const emoji = "😀".repeat(30); // 4 bytes each
  const e = splitMultiline(emoji, 10);
  assert(e.every((l) => utf8Bytes(l.text) <= 10), "emoji within limit");
  assert(e.map((l) => l.text).join("") === emoji, "no split characters");
});

Deno.test("byte count matches the server's max-bytes rule", () => {
  const lines = splitMultiline("ab\ncd", 400);
  assert(multilineBytes(lines) === 5, "a line break counts one byte");
  const cut = splitMultiline("abcdef", 3);
  assert(multilineBytes(cut) === 6, "continuations add no break");
});
