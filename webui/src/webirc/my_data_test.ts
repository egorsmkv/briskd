/// <reference lib="deno.ns" />
import { appKeys, canDeleteAccount } from "./my_data.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("appKeys keeps only this app's storage keys", () => {
  const keys = appKeys([
    "briskd-webirc-settings",
    "ircd-e2ee-v1:alice",
    "briskd-webirc-dms",
    "other-site-key",
    "xbriskd-webirc",
  ]);
  assert(
    keys.join() ===
      "briskd-webirc-settings,ircd-e2ee-v1:alice,briskd-webirc-dms",
    keys.join(),
  );
});

Deno.test("canDeleteAccount needs account, password, and consent", () => {
  assert(canDeleteAccount("alice", "pw", true), "all present");
  assert(!canDeleteAccount(" ", "pw", true), "no account");
  assert(!canDeleteAccount("alice", "", true), "no password");
  assert(!canDeleteAccount("alice", "pw", false), "not confirmed");
  assert(!canDeleteAccount("a".repeat(65), "pw", true), "too long");
});
