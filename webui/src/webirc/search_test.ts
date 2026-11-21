/// <reference lib="deno.ns" />
import { ircFold } from "../common/ircv3.ts";
import { parseIrc } from "./parse.ts";
import {
  cleanQuery,
  highlight,
  queryTerms,
  SearchCollector,
  searchCommand,
} from "./search.ts";
import type { IrcMessage } from "./types.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  const [a, e] = [JSON.stringify(actual), JSON.stringify(expected)];
  if (a !== e) throw new Error(`expected ${e}, got ${a}`);
}

function msg(raw: string): IrcMessage {
  return parseIrc(raw) as IrcMessage;
}

Deno.test("searchCommand builds the command, with paging", () => {
  assertEquals(
    searchCommand("#dev", 20, "deploy  failed"),
    "SEARCH #dev 20 :deploy  failed",
  );
  assertEquals(
    searchCommand("*", 5, "x", Date.UTC(2026, 10, 21, 12, 0, 0)),
    "SEARCH * 5 timestamp=2026-11-21T12:00:00.000Z :x",
  );
});

Deno.test("cleanQuery keeps one line within 300 bytes", () => {
  assertEquals(cleanQuery("  a\r\nb  "), "a b");
  const long = "я".repeat(200); // 400 bytes
  assertEquals(new TextEncoder().encode(cleanQuery(long)).length, 300);
});

Deno.test("the collector gathers a batch and leaves other lines alone", () => {
  const c = new SearchCollector(() => "me", ircFold);
  assertEquals(c.feed(msg(":irc.dev PRIVMSG #dev :live")).kind, "pass");
  assertEquals(
    c.feed(msg(":irc.dev BATCH +7 egorsmkv.github.io/search * 3")).kind,
    "consumed",
  );
  c.feed(msg(
    "@batch=7;time=2026-11-21T10:00:00.000Z;msgid=a1 :bob!b@h PRIVMSG #dev :deploy done",
  ));
  // A direct message is filed under the other person, whoever sent it.
  c.feed(
    msg(
      "@batch=7;time=2026-11-21T09:00:00.000Z :Me!m@h PRIVMSG carol :ping deploy",
    ),
  );
  c.feed(
    msg(
      "@batch=7;time=2026-11-21T08:00:00.000Z :carol!c@h PRIVMSG me :\x01ACTION deploys\x01",
    ),
  );
  // Other batches still pass.
  assertEquals(c.feed(msg(":irc.dev BATCH +8 chathistory #dev")).kind, "pass");
  const done = c.feed(msg(":irc.dev BATCH -7"));
  assertEquals(done.kind, "done");
  if (done.kind !== "done") return;
  assertEquals(done.result.total, 3);
  assertEquals(done.result.target, "*");
  assertEquals(
    done.result.hits.map((
      h,
    ) => [h.conversation, h.nick, h.text, h.msgid ?? null]),
    [
      ["#dev", "bob", "deploy done", "a1"],
      ["carol", "Me", "ping deploy", null],
      ["carol", "carol", "deploys", null],
    ],
  );
  assertEquals(done.result.hits[0].time, Date.UTC(2026, 10, 21, 10));
  assertEquals(c.feed(msg(":irc.dev BATCH -7")).kind, "pass");
});

Deno.test("FAIL SEARCH is reported", () => {
  const c = new SearchCollector(() => "me", ircFold);
  assertEquals(
    c.feed(
      msg(
        ":irc.dev FAIL SEARCH INVALID_TARGET #x :Messages could not be searched",
      ),
    ),
    {
      kind: "fail",
      code: "INVALID_TARGET",
      target: "#x",
      text: "Messages could not be searched",
    },
  );
  assertEquals(c.feed(msg(":irc.dev FAIL CHATHISTORY X :y")).kind, "pass");
});

Deno.test("queryTerms and highlight mark the searched words", () => {
  assertEquals(queryTerms('deploy* "rolling out" -staging OR Fix'), [
    "deploy",
    "rolling out",
    "fix",
  ]);
  assertEquals(highlight("Deploy is rolling out", ["deploy", "rolling out"]), [
    { text: "Deploy", match: true },
    { text: " is ", match: false },
    { text: "rolling out", match: true },
  ]);
  assertEquals(highlight("Привіт СВІТ", ["світ"]), [
    { text: "Привіт ", match: false },
    { text: "СВІТ", match: true },
  ]);
  assertEquals(highlight("abc", []), [{ text: "abc", match: false }]);
});
