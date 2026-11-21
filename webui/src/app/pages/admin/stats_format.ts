// Pure helpers of the Stats tab: axis ticks, value formatting, the plotted
// window, line segments, and the sample nearest the pointer (unit-tested in
// stats_format_test.ts).

/** GET /api/stats: one array per metric, oldest sample first. */
export interface StatsPayload {
  interval_ms: number;
  metrics: Record<string, Array<number | null>>;
}

/** Clean y-axis ticks from 0 up to at least `max` (about `count` steps). */
export function niceTicks(max: number, count = 4): number[] {
  if (!(max > 0) || !Number.isFinite(max)) return [0, 1];
  const raw = max / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) ??
    10 * mag;
  const ticks: number[] = [];
  for (let v = 0; v < max + step * 1e-9; v += step) ticks.push(round(v));
  if (ticks[ticks.length - 1] < max) ticks.push(round(ticks.length * step));
  return ticks;
}

/**
 * Ticks for a byte axis: clean steps in the binary unit the maximum falls in
 * (0, 256 MiB, 512 MiB, ... rather than 95.4 MiB, 191 MiB, ...).
 */
export function niceTicksBytes(max: number, count = 4): number[] {
  if (!(max > 0) || !Number.isFinite(max)) return [0, 1];
  let unit = 1;
  while (max / unit >= 1024) unit *= 1024;
  return niceTicks(max / unit, count).map((v) => v * unit);
}

function round(v: number): number {
  return Math.round(v * 1e9) / 1e9;
}

/** 950, 1,200, 12.5K, 3.4M: in full under 10,000, compact above. */
export function fmtCount(v: number): string {
  const a = Math.abs(v);
  if (a >= 1e9) return `${trim(v / 1e9)}B`;
  if (a >= 1e6) return `${trim(v / 1e6)}M`;
  if (a >= 1e4) return `${trim(v / 1e3)}K`;
  if (Number.isInteger(v)) return v.toLocaleString("en-US");
  return a >= 100 ? Math.round(v).toLocaleString("en-US") : trim(v);
}

function trim(v: number): string {
  return (Math.abs(v) >= 100 ? v.toFixed(0) : v.toFixed(1)).replace(/\.0$/, "");
}

/** Bytes with a binary prefix, compact for axes: 0 B, 512 B, 1.5 KiB, 12 MiB. */
export function fmtBytesShort(v: number): string {
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let i = 0;
  let x = Math.abs(v);
  while (x >= 1024 && i < units.length - 1) {
    x /= 1024;
    i++;
  }
  const s = i === 0 ? Math.round(x).toString() : trim(x);
  return `${v < 0 ? "-" : ""}${s} ${units[i]}`;
}

/** "14:05" or "14:05:30" in local time. */
export function fmtClock(ms: number, seconds = false): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  const hm = `${p(d.getHours())}:${p(d.getMinutes())}`;
  return seconds ? `${hm}:${p(d.getSeconds())}` : hm;
}

/** Index of the first sample at or after `from` (times ascending). */
export function windowStart(times: number[], from: number): number {
  let lo = 0;
  let hi = times.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (times[mid] < from) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/** Index of the sample closest in time to `t` (times ascending, non-empty). */
export function nearestIndex(times: number[], t: number): number {
  const i = windowStart(times, t);
  if (i <= 0) return 0;
  if (i >= times.length) return times.length - 1;
  return t - times[i - 1] <= times[i] - t ? i - 1 : i;
}

/**
 * Runs of consecutive plottable points as [start, end] index pairs
 * (inclusive). A run breaks at a missing value and where the time step
 * exceeds `maxGap` ms (the server was down or restarted), so a line never
 * bridges data that does not exist.
 */
export function segments(
  times: number[],
  values: Array<number | null>,
  maxGap: number,
): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  let start = -1;
  for (let i = 0; i < values.length; i++) {
    const ok = typeof values[i] === "number" && Number.isFinite(values[i]);
    const gap = i > 0 && times[i] - times[i - 1] > maxGap;
    if (start >= 0 && (!ok || gap)) {
      out.push([start, i - 1]);
      start = -1;
    }
    if (ok && start < 0) start = i;
  }
  if (start >= 0) out.push([start, values.length - 1]);
  return out;
}

/** The largest finite value, or 0. */
export function maxOf(...lists: Array<Array<number | null>>): number {
  let m = 0;
  for (const list of lists) {
    for (const v of list) if (typeof v === "number" && v > m) m = v;
  }
  return m;
}

/** The newest finite value of a series, or null. */
export function latest(values: Array<number | null>): number | null {
  for (let i = values.length - 1; i >= 0; i--) {
    const v = values[i];
    if (typeof v === "number" && Number.isFinite(v)) return v;
  }
  return null;
}
