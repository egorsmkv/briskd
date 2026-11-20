/// <reference lib="deno.ns" />
import { MAX_CONVERSATIONS, MAX_LINES, snapshot } from "./dm_snapshot.ts";
import type { ChatLine } from "./types.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

function line(epochMs: number, text = "hi"): ChatLine {
  return { time: "12:00", epochMs, nick: "bot", text, kind: "" };
}

Deno.test("snapshot keeps private conversations only, trimmed", () => {
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
  assert(Object.keys(out).join() === "helper", Object.keys(out).join());
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
