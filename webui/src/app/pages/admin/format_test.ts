/// <reference lib="deno.ns" />
import {
  fmtBytes,
  fmtUptime,
  isIpAddress,
  matchesFilter,
  pageWindow,
  tabFromLocation,
  tabPath,
} from "./format.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`Expected ${e}, got ${a}`);
}

Deno.test("tabFromLocation reads the path, then the hash", () => {
  assertEquals(tabFromLocation("/admin", ""), "overview");
  assertEquals(tabFromLocation("/admin/", ""), "overview");
  assertEquals(tabFromLocation("/admin/clients", ""), "clients");
  assertEquals(tabFromLocation("/admin/stats", ""), "stats");
  assertEquals(tabFromLocation("/admin/Media/", ""), "media");
  assertEquals(tabFromLocation("/admin/nope", ""), "overview");
  assertEquals(tabFromLocation("/admin", "#dronebl"), "dronebl");
  assertEquals(tabFromLocation("/admin/links", "#dronebl"), "links");
  assertEquals(tabFromLocation("/admin/x/y", ""), "overview");
});

Deno.test("tabPath", () => {
  assertEquals(tabPath("overview"), "/admin");
  assertEquals(tabPath("operations"), "/admin/operations");
});

Deno.test("fmtUptime", () => {
  assertEquals(fmtUptime(0), "0h 0m 0s");
  assertEquals(fmtUptime(3661), "1h 1m 1s");
  assertEquals(fmtUptime(90061), "1d 1h 1m 1s");
});

Deno.test("fmtBytes", () => {
  assertEquals(fmtBytes(512), "512 B");
  assertEquals(fmtBytes(1536), "1.5 KiB");
  assertEquals(fmtBytes(2 * 1024 * 1024), "2.0 MiB");
  assertEquals(fmtBytes(1024 * 1024 * 1024), "1.00 GiB");
});

Deno.test("isIpAddress", () => {
  assertEquals(isIpAddress("192.0.2.1"), true);
  assertEquals(isIpAddress("2001:db8::1"), true);
  assertEquals(isIpAddress("example.org"), false);
  assertEquals(isIpAddress("deadbeef"), false);
  assertEquals(isIpAddress(undefined), false);
});

Deno.test("matchesFilter", () => {
  assertEquals(matchesFilter("", "a"), true);
  assertEquals(matchesFilter("  ", undefined), true);
  assertEquals(matchesFilter("BoB", "alice", "bobby"), true);
  assertEquals(matchesFilter("carol", "alice", null, undefined), false);
});

Deno.test("pageWindow clamps the page", () => {
  assertEquals(pageWindow(0, 25, 1), {
    page: 1,
    totalPages: 1,
    start: 0,
    end: 0,
  });
  assertEquals(pageWindow(30, 25, 2), {
    page: 2,
    totalPages: 2,
    start: 25,
    end: 30,
  });
  assertEquals(pageWindow(30, 25, 9).page, 2);
  assertEquals(pageWindow(30, 25, 0).page, 1);
});
