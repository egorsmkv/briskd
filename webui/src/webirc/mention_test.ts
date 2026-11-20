/// <reference lib="deno.ns" />
import { ircFold } from "../common/ircv3.ts";
import { applyMention, mentionQuery, rankMentions } from "./mention.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}
const eq = (a: unknown, b: unknown, msg: string) =>
  assert(
    JSON.stringify(a) === JSON.stringify(b),
    `${msg}: ${JSON.stringify(a)}`,
  );

Deno.test("an @ at a word start opens a query up to the caret", () => {
  eq(mentionQuery("@", 1), { start: 0, query: "" }, "bare @");
  eq(mentionQuery("hi @al", 6), { start: 3, query: "al" }, "after a space");
  eq(mentionQuery("hi @al there", 6), { start: 3, query: "al" }, "caret mid");
  eq(mentionQuery("(@bo", 4), { start: 1, query: "bo" }, "after bracket");
  eq(mentionQuery("a\n@x", 4), { start: 2, query: "x" }, "new line");
  eq(mentionQuery("user@host", 9), null, "inside a word");
  eq(mentionQuery("@al ", 4), null, "finished by a space");
  eq(mentionQuery("@al, hi", 7), null, "after punctuation");
  eq(mentionQuery("no at", 5), null, "no @");
});

Deno.test("ranking: nick prefix, display name, substring; recent first", () => {
  const nicks = ["alice", "Albert", "bob", "malia", "[al]", "carol"];
  const display = (n: string) => n === "carol" ? "Alfie Carol" : n;
  const out = rankMentions("al", nicks, {
    fold: ircFold,
    display,
    recent: ["albert"],
  });
  eq(out, ["Albert", "alice", "carol", "[al]", "malia"], "tiers and recency");
  eq(
    rankMentions("", ["b", "a", "c"], { fold: ircFold, recent: ["c"] }),
    ["c", "a", "b"],
    "empty query: recent, then by name",
  );
  eq(
    rankMentions("a", ["me", "Ann", "ann"], { fold: ircFold, exclude: "ME" }),
    ["Ann"],
    "excludes self and folded duplicates",
  );
  eq(
    rankMentions("{a", ["[al]"], { fold: ircFold }),
    ["[al]"],
    "RFC 1459 folding",
  );
  eq(
    rankMentions("", Array.from({ length: 20 }, (_, i) => `n${i}`), {
      fold: ircFold,
      limit: 3,
    }).length,
    3,
    "limit",
  );
});

Deno.test("applying a mention replaces the query and adds a space", () => {
  eq(applyMention("hi @al", 3, 6, "alice"), {
    text: "hi @alice ",
    caret: 10,
  }, "at the end");
  eq(applyMention("@al there", 0, 3, "alice"), {
    text: "@alice there",
    caret: 7,
  }, "before a space: no second space");
});
