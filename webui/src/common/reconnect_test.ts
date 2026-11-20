/// <reference lib="deno.ns" />
import {
  altNick,
  backoffDelay,
  DEFAULT_BACKOFF,
  RECLAIM_SECRET,
  reclaimSecret,
  rejoinList,
} from "./reconnect.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("backoff doubles from 1s and caps at 60s", () => {
  const top = () => 0; // no jitter taken off
  const delays = [0, 1, 2, 3, 4, 5, 6, 7].map((n) =>
    backoffDelay(n, DEFAULT_BACKOFF, top)
  );
  assert(
    JSON.stringify(delays) ===
      JSON.stringify([1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000]),
    `schedule ${delays}`,
  );
  assert(backoffDelay(10_000, DEFAULT_BACKOFF, top) === 60000, "huge attempt");
  assert(backoffDelay(-3, DEFAULT_BACKOFF, top) === 1000, "negative attempt");
});

Deno.test("jitter only shortens the delay, by at most 30%", () => {
  for (let i = 0; i < 1000; i++) {
    const d = backoffDelay(3);
    assert(d >= 8000 * 0.7 && d <= 8000, `in range: ${d}`);
  }
  assert(backoffDelay(3, DEFAULT_BACKOFF, () => 1) === 5600, "full jitter");
});

Deno.test("rejoin keeps open channels first and folds duplicates", () => {
  const fold = (s: string) => s.toLowerCase().replace("[", "{");
  const out = rejoinList(["#Dev", "#a[b]"], ["#dev", "#lobby", "#A{b]"], fold);
  assert(
    JSON.stringify(out) === JSON.stringify(["#Dev", "#a[b]", "#lobby"]),
    `rejoin ${out}`,
  );
  assert(rejoinList([], [], fold).length === 0, "empty");
});

Deno.test("alternative nicknames stay within the length limit", () => {
  assert(altNick("alice", 9, 0) === "alice_", "append");
  assert(altNick("alice_", 9, 1) === "alice__", "append again");
  assert(altNick("abcdefghi", 9, 2) === "abcdefgh2", "replace last at limit");
  assert(altNick("abcdefgh2", 9, 3) === "abcdefgh3", "rotate digit");
  for (let i = 0; i < 20; i++) {
    assert(altNick("abcdefghi", 9, i).length <= 9, "never longer");
  }
});

Deno.test("reclaimSecret: base64url the server accepts", () => {
  const all = new Uint8Array(24).map((_, i) => (i * 37 + 251) & 0xff);
  const secret = reclaimSecret(all);
  assert(secret.length === 32, `length ${secret.length}`);
  assert(RECLAIM_SECRET.test(secret), `accepted: ${secret}`);
  assert(!/[+/=]/.test(secret), "no +, /, or padding");
  assert(
    reclaimSecret(new Uint8Array(24).fill(0xff)) === "_".repeat(32),
    "0xff bytes map to _",
  );
  assert(!RECLAIM_SECRET.test("short"), "too short is refused");
  assert(!RECLAIM_SECRET.test("has space in it 123"), "spaces refused");
});
