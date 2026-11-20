/// <reference lib="deno.ns" />
import {
  DOM_HARD_MAX,
  GROUP_GAP_MS,
  isAtBottom,
  isGrouped,
  windowToInclude,
} from "./policy.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

const at = (h: number, m = 0) => new Date(2026, 0, 15, h, m).getTime();
const line = (nick: string, epochMs: number, kind = "") => ({
  nick,
  kind,
  epochMs,
});

Deno.test("lines of one author within the gap are grouped", () => {
  assert(isGrouped(line("ann", at(10, 1)), line("ann", at(10, 0))), "run");
  assert(!isGrouped(line("ann", at(10, 0))), "first line");
  assert(!isGrouped(line("bob", at(10, 1)), line("ann", at(10, 0))), "author");
  assert(
    !isGrouped(
      line("ann", at(10, 0) + GROUP_GAP_MS),
      line("ann", at(10, 0)),
    ),
    "gap reached",
  );
  assert(
    !isGrouped(line("ann", at(10, 1), "sys"), line("ann", at(10, 0))),
    "system line",
  );
  assert(
    !isGrouped(line("ann", at(10, 1)), line("ann", at(10, 0), "sys")),
    "after a system line",
  );
  const lateNight = new Date(2026, 0, 15, 23, 59).getTime();
  const nextDay = new Date(2026, 0, 16, 0, 0).getTime();
  assert(
    !isGrouped(line("ann", nextDay), line("ann", lateNight)),
    "new day starts a new run",
  );
});

Deno.test("bottom detection allows a small slack", () => {
  assert(isAtBottom(1000, 600, 400), "exactly at the end");
  assert(isAtBottom(1000, 550, 400), "50px above");
  assert(!isAtBottom(1000, 500, 400), "100px above");
  assert(isAtBottom(300, 0, 400), "content shorter than the view");
});

Deno.test("window grows to include a line, within the hard cap", () => {
  assert(windowToInclude(550, 600, 200) === 200, "already inside");
  assert(windowToInclude(300, 600, 200) === 320, "with 20 lines of context");
  assert(windowToInclude(0, 600, 200) === DOM_HARD_MAX, "capped");
  assert(windowToInclude(0, 600, 450, 0) === 600, "whole conversation");
});
