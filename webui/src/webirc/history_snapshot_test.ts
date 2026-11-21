/// <reference lib="deno.ns" />
import {
  MAX_CONVERSATIONS,
  MAX_LINES,
  restoredConversations,
  restoredLine,
  snapshot,
} from "./history_snapshot.ts";
import type { ChatLine } from "./types.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

function line(epochMs: number, text = "hi"): ChatLine {
  return { time: "12:00", epochMs, nick: "bot", text, kind: "" };
}

Deno.test("snapshot keeps channels and private conversations, trimmed", () => {
  const many = Array.from(
    { length: MAX_LINES + 20 },
    (_, i) => line(i, `m${i}`),
  );
  many[many.length - 1].reactions = new Map([["+1", new Set(["a"])]]);
  const out = snapshot([
    ["*status", { name: "*status", lines: [line(1)] }],
    ["#lobby", { name: "#lobby", lines: [line(2)] }],
    ["helper", { name: "helper", lines: many }],
    ["empty", { name: "empty", lines: [] }],
  ]);
  assert(
    Object.keys(out).sort().join() === "#lobby,helper",
    Object.keys(out).join(),
  );
  const kept = out.helper.lines;
  assert(kept.length === MAX_LINES, `kept ${kept.length}`);
  assert(kept[0].text === "m20", "oldest lines dropped first");
  assert(!("reactions" in kept[kept.length - 1]), "reactions are not stored");
  assert(JSON.parse(JSON.stringify(out)).helper.name === "helper", "JSON-safe");
});

Deno.test("snapshot keeps the most recently active conversations", () => {
  const bufs: Array<[string, { name: string; lines: ChatLine[] }]> = [];
  for (let i = 0; i < MAX_CONVERSATIONS + 5; i++) {
    bufs.push([`u${i}`, { name: `u${i}`, lines: [line(i * 1000)] }]);
  }
  const keys = Object.keys(snapshot(bufs));
  assert(keys.length === MAX_CONVERSATIONS, `kept ${keys.length}`);
  assert(keys[0] === `u${MAX_CONVERSATIONS + 4}`, "newest first");
  assert(!keys.includes("u0"), "the least recent are dropped");
});

Deno.test("restoredLine keeps only well-typed fields", () => {
  const ok = restoredLine({
    time: "12:00",
    epochMs: 5,
    nick: "bob",
    text: "hi",
    kind: "",
    msgid: "m1",
    fileSize: "big",
    albumIds: ["a", 2],
    evil: "x",
  });
  assert(ok !== null && ok.msgid === "m1", "valid line kept");
  assert(ok !== null && !("fileSize" in ok), "bad number dropped");
  assert(ok !== null && !("albumIds" in ok), "bad array dropped");
  assert(ok !== null && !("evil" in ok), "unknown field dropped");
  assert(restoredLine({ ...ok, epochMs: 1e20 }) === null, "time out of range");
  assert(restoredLine({ ...ok, nick: 7 }) === null, "nick must be a string");
  assert(restoredLine({ ...ok, kind: "boom" }) === null, "unknown kind");
  assert(restoredLine(null) === null, "null");
});

Deno.test("restoredConversations survives corrupt storage", () => {
  assert(restoredConversations("null").length === 0, "null");
  assert(restoredConversations("[1,2]").length === 0, "array");
  assert(restoredConversations("{bad").length === 0, "bad JSON");
  const good = { time: "1", epochMs: 1, nick: "a", text: "t", kind: "" };
  const out = restoredConversations(JSON.stringify({
    a: null,
    b: { name: 5, lines: [] },
    c: { name: "#x", lines: "no" },
    d: { name: "#lobby", lines: [good, { text: 1 }, null] },
    e: { name: "*status", lines: [good] },
  }));
  assert(out.length === 1 && out[0].name === "#lobby", JSON.stringify(out));
  assert(out[0].lines.length === 1, "invalid lines dropped");
});
