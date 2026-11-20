/// <reference lib="deno.ns" />
import { loadLinkPreview } from "./link_preview.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

function fakeFetch(respond: () => Response) {
  let calls = 0;
  const fn = ((_input: unknown, _init?: unknown) => {
    calls++;
    return new Promise<Response>((r) => setTimeout(() => r(respond()), 5));
  }) as unknown as typeof fetch;
  return { fn, calls: () => calls };
}

Deno.test("concurrent requests for one URL share a single fetch", async () => {
  const f = fakeFetch(() =>
    Response.json({ domain: "example.com", title: "Example" })
  );
  const url = "https://example.com/shared";
  const results = await Promise.all([
    loadLinkPreview(url, f.fn),
    loadLinkPreview(url, f.fn),
    loadLinkPreview(url, f.fn),
  ]);
  assert(f.calls() === 1, `one request, got ${f.calls()}`);
  assert(results.every((r) => r?.title === "Example"), "all get the preview");
  await loadLinkPreview(url, f.fn);
  assert(f.calls() === 1, "cached afterwards");
});

Deno.test("204 means no preview and is remembered", async () => {
  const f = fakeFetch(() => new Response(null, { status: 204 }));
  const url = "https://example.com/none";
  assert((await loadLinkPreview(url, f.fn)) === null, "no preview");
  assert((await loadLinkPreview(url, f.fn)) === null, "still none");
  assert(f.calls() === 1, "not requested again");
});

Deno.test("errors and incomplete data give no preview", async () => {
  const failing =
    (() => Promise.reject(new Error("offline"))) as unknown as typeof fetch;
  assert(
    (await loadLinkPreview("https://example.com/err", failing)) === null,
    "network error",
  );
  const f = fakeFetch(() => Response.json({ domain: "example.com" }));
  assert(
    (await loadLinkPreview("https://example.com/untitled", f.fn)) === null,
    "no title",
  );
});
