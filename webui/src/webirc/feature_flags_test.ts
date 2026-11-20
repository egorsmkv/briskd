/// <reference lib="deno.ns" />
import { changedFeatures, parseFeatures } from "./feature_flags.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("parseFeatures reads the capability value", () => {
  const f = parseFeatures("reactions,typing");
  assert(f.reactions && f.typing, "listed are on");
  assert(
    !f.replies && !f.editing && !f.redaction && !f.link_previews,
    "rest off",
  );
  const none = parseFeatures("none");
  assert(Object.values(none).every((v) => !v), "none turns everything off");
  assert(parseFeatures("reactions,unknown").reactions, "unknown names ignored");
});

Deno.test("changedFeatures lists only keys whose value differs", () => {
  const before = parseFeatures("reactions,replies,typing");
  const after = parseFeatures("reactions,typing,editing");
  assert(
    changedFeatures(before, after).join() === "replies,editing",
    changedFeatures(before, after).join(),
  );
  assert(changedFeatures(before, { redaction: false }).length === 0, "same");
  assert(
    changedFeatures(before, { redaction: true }).join() === "redaction",
    "partial",
  );
});
