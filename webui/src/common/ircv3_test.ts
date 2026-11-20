/// <reference lib="deno.ns" />
import {
  cleanMetaText,
  formatStandardReply,
  markerToMs,
  msToMarker,
  parseMonitorTargets,
  parseNamesEntry,
  parseWhoxReply,
  prefixCharsFromIsupport,
  safeAvatarUrl,
  safeHomepageUrl,
} from "./ircv3.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("parseNamesEntry handles multi-prefix and userhost-in-names", () => {
  const plain = parseNamesEntry("alice");
  assert(plain?.nick === "alice" && plain.prefix === "", "plain nick");
  const multi = parseNamesEntry("@+bob");
  assert(multi?.nick === "bob" && multi.prefix === "@+", "multi-prefix");
  const full = parseNamesEntry("@carol!c@example.org");
  assert(
    full?.nick === "carol" && full.prefix === "@" &&
      full.userhost === "c@example.org",
    "userhost-in-names",
  );
  assert(parseNamesEntry("@") === null, "prefix without nick");
  assert(parseNamesEntry("!u@h") === null, "userhost without nick");
});

Deno.test("prefixCharsFromIsupport reads the PREFIX token", () => {
  assert(prefixCharsFromIsupport("(ov)@+") === "@+", "ov");
  assert(prefixCharsFromIsupport(undefined) === "~&@%+", "default");
  assert(prefixCharsFromIsupport("garbage") === "~&@%+", "malformed");
});

Deno.test("parseWhoxReply reads flags and account for our token", () => {
  const e = parseWhoxReply(["me", "152", "#c", "bot1", "G*B@", "acct"]);
  assert(
    e !== null && e.nick === "bot1" && e.away && e.bot && e.oper &&
      e.account === "acct",
    "flags",
  );
  const here = parseWhoxReply(["me", "152", "#c", "u", "H", "0"]);
  assert(here !== null && !here.away && !here.bot && !here.account, "here");
  assert(
    parseWhoxReply(["me", "999", "#c", "u", "H", "0"]) === null,
    "other token",
  );
  assert(parseWhoxReply(["me", "152"]) === null, "short");
});

Deno.test("parseMonitorTargets splits nick and userhost", () => {
  const t = parseMonitorTargets("a!u@h,b,,!x@y");
  assert(t.length === 2, "skips empty and nickless");
  assert(t[0].nick === "a" && t[0].userhost === "u@h", "with userhost");
  assert(t[1].nick === "b" && t[1].userhost === undefined, "bare nick");
});

Deno.test("safeAvatarUrl allows only https and same-origin files", () => {
  assert(
    safeAvatarUrl("https://example.org/a.png") === "https://example.org/a.png",
    "https",
  );
  assert(
    safeAvatarUrl(`/api/files/${"a".repeat(32)}.png`) !== null,
    "files path",
  );
  assert(safeAvatarUrl("http://example.org/a.png") === null, "http");
  assert(safeAvatarUrl("javascript:alert(1)") === null, "javascript");
  assert(safeAvatarUrl("data:image/png;base64,AA") === null, "data");
  assert(safeAvatarUrl("/api/files/../x") === null, "path traversal");
  assert(safeHomepageUrl("http://example.org") !== null, "homepage http");
  assert(safeHomepageUrl("javascript:x") === null, "homepage js");
});

Deno.test("cleanMetaText strips controls and bounds length", () => {
  assert(cleanMetaText(" a\x02b‮c ") === "abc", "controls");
  assert(cleanMetaText("x".repeat(100), 10).length === 10, "bounded");
});

Deno.test("read marker values round-trip", () => {
  const ms = Date.UTC(2026, 10, 20, 1, 2, 3, 456);
  assert(msToMarker(ms) === "timestamp=2026-11-20T01:02:03.456Z", "format");
  assert(markerToMs(msToMarker(ms)) === ms, "round trip");
  assert(markerToMs("*") === null, "unset");
  assert(markerToMs("timestamp=nope") === null, "malformed");
});

Deno.test("formatStandardReply names command, code, and description", () => {
  assert(
    formatStandardReply("FAIL", ["METADATA", "KEY_INVALID", "x", "bad key"]) ===
      "FAIL METADATA: bad key (KEY_INVALID)",
    "fail",
  );
  assert(
    formatStandardReply("NOTE", ["*", "OPER_MESSAGE", "hello"]) ===
      "NOTE: hello (OPER_MESSAGE)",
    "note without command",
  );
});
