/// <reference lib="deno.ns" />
import {
  actionTitle,
  formatAgo,
  humanizeError,
  successMessage,
} from "./admin_text.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("humanizeError reads message, atoms, and Erlang terms", () => {
  assert(
    humanizeError({ error: "x", message: "Try again" }) === "Try again",
    "message wins",
  );
  assert(
    humanizeError({ error: "no_such_account" }) === "No such account",
    "atom",
  );
  assert(
    humanizeError({ error: '{no_such_nick,<<"bob">>}' }) ===
      "No such nick: bob",
    "binary term",
  );
  assert(
    humanizeError({ error: "{timeout,5000}" }) === "Timeout: 5000",
    "plain term",
  );
  assert(humanizeError({}, 502) === "HTTP 502", "status fallback");
  assert(humanizeError(null) === "Unknown error", "no data");
});

Deno.test("successMessage names the action target", () => {
  assert(
    successMessage("kick-client", ["bob", "bye"], {}) === "Kicked bob",
    "kick",
  );
  assert(
    successMessage("check-config", [], { status: "valid", path: "/c.json" }) ===
      "Configuration is valid (/c.json)",
    "check-config",
  );
  assert(
    successMessage("set-topic", ["#a", ""], {}) === "Topic cleared for #a",
    "topic clear",
  );
  assert(
    successMessage("toggle-feature", ["link_previews", "false"], {}) ===
      "Link previews disabled",
    "feature",
  );
  assert(
    successMessage("log-level", ["info"], { log_level: "info" }) ===
      "Log level set to info",
    "log level",
  );
  assert(
    successMessage("mystery", [], {}) === "mystery: done",
    "unknown action",
  );
  assert(actionTitle("squit") === "SQUIT", "title");
});

Deno.test("formatAgo buckets elapsed time", () => {
  assert(formatAgo(500) === "just now", "now");
  assert(formatAgo(12_000) === "12s ago", "seconds");
  assert(formatAgo(180_000) === "3m ago", "minutes");
  assert(formatAgo(7_200_000) === "2h ago", "hours");
});
