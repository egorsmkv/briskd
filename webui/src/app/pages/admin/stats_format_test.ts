/// <reference lib="deno.ns" />
import {
  fmtBytesShort,
  fmtCount,
  latest,
  maxOf,
  nearestIndex,
  niceTicks,
  niceTicksBytes,
  segments,
  windowStart,
} from "./stats_format.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  const [a, e] = [JSON.stringify(actual), JSON.stringify(expected)];
  if (a !== e) throw new Error(`expected ${e}, got ${a}`);
}

Deno.test("niceTicks starts at 0 and covers the maximum in clean steps", () => {
  assertEquals(niceTicks(0), [0, 1]);
  assertEquals(niceTicks(100), [0, 25, 50, 75, 100]);
  assertEquals(niceTicks(93510), [0, 25000, 50000, 75000, 100000]);
  assertEquals(niceTicks(7), [0, 2, 4, 6, 8]);
  assertEquals(niceTicks(0.3), [0, 0.1, 0.2, 0.3]);
});

Deno.test("niceTicksBytes steps in the binary unit of the maximum", () => {
  const MiB = 1024 * 1024;
  assertEquals(
    niceTicksBytes(381 * MiB),
    [0, 100, 200, 300, 400].map((v) => v * MiB),
  );
  assertEquals(niceTicksBytes(3.8 * MiB), [0, 1, 2, 3, 4].map((v) => v * MiB));
  assertEquals(niceTicksBytes(900), [0, 250, 500, 750, 1000]);
});

Deno.test("fmtCount is full under 10,000 and compact above", () => {
  assertEquals(fmtCount(950), "950");
  assertEquals(fmtCount(1200), "1,200");
  assertEquals(fmtCount(12500), "12.5K");
  assertEquals(fmtCount(93510), "93.5K");
  assertEquals(fmtCount(3_400_000), "3.4M");
  assertEquals(fmtCount(2.5), "2.5");
  assertEquals(fmtCount(0), "0");
});

Deno.test("fmtBytesShort uses binary prefixes", () => {
  assertEquals(fmtBytesShort(512), "512 B");
  assertEquals(fmtBytesShort(1536), "1.5 KiB");
  assertEquals(fmtBytesShort(1024 * 1024 * 300), "300 MiB");
});

Deno.test("windowStart and nearestIndex search sorted times", () => {
  const t = [0, 5000, 10000, 15000];
  assertEquals(windowStart(t, -1), 0);
  assertEquals(windowStart(t, 5000), 1);
  assertEquals(windowStart(t, 5001), 2);
  assertEquals(windowStart(t, 99999), 4);
  assertEquals(nearestIndex(t, 2400), 0);
  assertEquals(nearestIndex(t, 2600), 1);
  assertEquals(nearestIndex(t, 99999), 3);
  assertEquals(nearestIndex(t, -5), 0);
});

Deno.test("segments break at missing values and time gaps", () => {
  const t = [0, 5, 10, 15, 100, 105];
  assertEquals(segments(t, [1, 2, null, 4, 5, 6], 12), [[0, 1], [3, 3], [
    4,
    5,
  ]]);
  assertEquals(segments(t, [null, null, null, null, null, null], 12), []);
  assertEquals(segments([0, 5], [1, 2], 12), [[0, 1]]);
});

Deno.test("maxOf and latest skip missing values", () => {
  assertEquals(maxOf([1, null, 3], [2]), 3);
  assertEquals(maxOf([null]), 0);
  assertEquals(latest([1, 2, null]), 2);
  assertEquals(latest([null]), null);
});
