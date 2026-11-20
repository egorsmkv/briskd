/// <reference lib="deno.ns" />
import { afterLogin, pageFor } from "./routes.ts";

function eq(actual: unknown, expected: unknown): void {
  if (actual !== expected) {
    throw new Error(`expected ${String(expected)}, got ${String(actual)}`);
  }
}

Deno.test("the sign-in page has its own route", () => {
  eq(pageFor("/admin/login"), "login");
  eq(pageFor("/admin"), "admin");
  eq(pageFor("/admin/channels"), "admin");
});

Deno.test("afterLogin returns only to admin pages", () => {
  eq(afterLogin("/admin/channels"), "/admin/channels");
  eq(afterLogin("/admin"), "/admin");
  eq(afterLogin(null), "/admin");
  eq(afterLogin(""), "/admin");
  eq(afterLogin("/admin/login"), "/admin");
  eq(afterLogin("https://evil.example/admin"), "/admin");
  eq(afterLogin("//evil.example/admin"), "/admin");
  eq(afterLogin("/admin/../webirc"), "/admin");
  eq(afterLogin("/signup"), "/admin");
});
