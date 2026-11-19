/// <reference lib="deno.ns" />
import { tokenizeCodeLine } from "./code_card.ts";
import { extractFirstHttpUrl } from "./link_preview.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("tokenizeCodeLine highlights keywords, strings, numbers, and comments", () => {
  const ts = tokenizeCodeLine('const x = 42; // hello "world"', "typescript");
  assert(ts[0].kind === "kw" && ts[0].text === "const", "keyword const");
  assert(
    ts.some((t) => t.kind === "num" && t.text === "42"),
    "number 42",
  );
  assert(
    ts.some((t) => t.kind === "cmt" && t.text.startsWith("// hello")),
    "comment",
  );

  const erl = tokenizeCodeLine('case X of 1 -> "ok" end. % note', "erlang");
  assert(erl[0].kind === "kw" && erl[0].text === "case", "erlang keyword");
  assert(erl.some((t) => t.kind === "str" && t.text === '"ok"'), "string");
  assert(erl.some((t) => t.kind === "cmt" && t.text === "% note"), "erl cmt");
});

Deno.test("extractFirstHttpUrl extracts public URLs and skips localhost", () => {
  assert(
    extractFirstHttpUrl("check https://erlang.org/doc/ right now!") ===
      "https://erlang.org/doc/",
    "extracts https url",
  );
  assert(
    extractFirstHttpUrl("see http://localhost:8081/admin") === null,
    "skips localhost",
  );
  assert(extractFirstHttpUrl("no links here") === null, "no url");
});
