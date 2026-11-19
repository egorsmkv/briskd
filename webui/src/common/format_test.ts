/// <reference lib="deno.ns" />
import { parseIrcFormatting } from "./format.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("parseIrcFormatting handles bold, italic, underline, strike, mono, and reset", () => {
  const segs = parseIrcFormatting(
    "plain \x02bold \x1Ditalic\x0F normal \x11mono\x11 \x1Estrike\x1E \x1Funder\x1F",
  );
  assert(segs[0].text === "plain " && !segs[0].bold, "plain segment");
  assert(segs[1].text === "bold " && segs[1].bold === true, "bold segment");
  assert(
    segs[2].text === "italic" && segs[2].bold === true &&
      segs[2].italic === true,
    "bold+italic segment",
  );
  assert(
    segs[3].text === " normal " && !segs[3].bold && !segs[3].italic,
    "reset segment",
  );
  assert(segs[4].text === "mono" && segs[4].mono === true, "mono segment");
  assert(segs[6].text === "strike" && segs[6].strike === true, "strike");
  assert(segs[8].text === "under" && segs[8].underline === true, "underline");
});

Deno.test("parseIrcFormatting handles mIRC colors and hex colors", () => {
  const segs = parseIrcFormatting("\x034,1alert\x03 plain \x0400e64dneon\x04");
  assert(
    segs[0].text === "alert" && segs[0].fg === "#ef4444" &&
      segs[0].bg === "#111827",
    "mIRC fg+bg",
  );
  assert(segs[1].text === " plain " && !segs[1].fg && !segs[1].bg, "clear");
  assert(segs[2].text === "neon" && segs[2].fg === "#00e64d", "hex color");
});

Deno.test("parseIrcFormatting strips Unicode bidi override spoofing characters", () => {
  const segs = parseIrcFormatting("check \u202Efdp.exe\u202C and שלום");
  assert(segs.length === 1, "single segment");
  assert(!segs[0].text.includes("\u202E"), "RLO must be stripped");
  assert(!segs[0].text.includes("\u202C"), "PDF must be stripped");
  assert(segs[0].text.includes("שלום"), "Hebrew text must be preserved");
});
