// A time-series line chart for the Stats tab: SVG sized to its container,
// series colors from CSS classes (chart-s1..chart-s4; the pages' CSP forbids
// inline style attributes), a crosshair that snaps to the nearest sample with
// one tooltip for every series (pointer and arrow keys), a legend with the
// newest values when there are two or more series, and a table view.
import { useEffect, useRef, useState } from "preact/hooks";
import {
  fmtClock,
  latest,
  maxOf,
  nearestIndex,
  niceTicks,
  niceTicksBytes,
  segments,
} from "./stats_format.ts";

export interface Series {
  label: string;
  values: Array<number | null>;
}

const HEIGHT = 200;
const M = { top: 10, right: 12, bottom: 24, left: 60 };
const MINUTE = 60_000;
/** Spacing between x-axis time labels, minutes. */
const X_STEPS = [1, 2, 5, 10, 15, 30, 60];

/** Width of the element, following resizes. */
function useWidth(): [preact.RefObject<HTMLDivElement>, number] {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(600);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const update = () => setWidth(Math.max(240, Math.floor(el.clientWidth)));
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, width];
}

function xTicks(t0: number, t1: number): number[] {
  const span = Math.max(t1 - t0, MINUTE);
  const step = (X_STEPS.find((m) => span / (m * MINUTE) <= 5) ?? 60) * MINUTE;
  const out: number[] = [];
  for (let t = Math.ceil(t0 / step) * step; t <= t1; t += step) out.push(t);
  return out;
}

export function LineChart(
  { id, title, sub, times, series, fmt, yMax, bytes, maxGap }: {
    id: string;
    title: string;
    sub: string;
    times: number[];
    series: Series[];
    fmt: (v: number) => string;
    /** A fixed top of the y-axis (percentages), else from the data. */
    yMax?: number;
    /** Byte values: ticks step in binary units. */
    bytes?: boolean;
    /** Longest step, ms, a line may bridge. */
    maxGap: number;
  },
) {
  const [ref, width] = useWidth();
  const [hover, setHover] = useState<number | null>(null);
  const [table, setTable] = useState(false);
  const n = times.length;
  const idx = hover !== null && hover < n ? hover : null;

  const plotW = width - M.left - M.right;
  const plotH = HEIGHT - M.top - M.bottom;
  const t0 = n ? times[0] : 0;
  const t1 = n ? times[n - 1] : 1;
  const peak = yMax ?? maxOf(...series.map((s) => s.values));
  const ticks = bytes ? niceTicksBytes(peak) : niceTicks(peak);
  const top = ticks[ticks.length - 1] || 1;
  const x = (t: number) =>
    M.left + (t1 > t0 ? ((t - t0) / (t1 - t0)) * plotW : plotW);
  const y = (v: number) => M.top + plotH - (Math.min(v, top) / top) * plotH;

  const paths = series.map((s) =>
    segments(times, s.values, maxGap).map(([a, b]) => {
      let d = "";
      for (let i = a; i <= b; i++) {
        d += `${i === a ? "M" : "L"}${x(times[i]).toFixed(1)},${
          y(s.values[i] as number).toFixed(1)
        }`;
      }
      // A lone point would draw nothing as a path: give it a dot.
      return { d, single: a === b ? a : -1 };
    })
  );

  const onMove = (ev: PointerEvent) => {
    if (!n) return;
    const rect = (ev.currentTarget as SVGElement).getBoundingClientRect();
    const px = ev.clientX - rect.left;
    const t = t0 + ((px - M.left) / Math.max(plotW, 1)) * (t1 - t0);
    setHover(nearestIndex(times, t));
  };
  const onKey = (ev: KeyboardEvent) => {
    if (!n) return;
    const cur = idx ?? n - 1;
    let next: number | null = cur;
    if (ev.key === "ArrowLeft") next = Math.max(0, cur - 1);
    else if (ev.key === "ArrowRight") next = Math.min(n - 1, cur + 1);
    else if (ev.key === "Home") next = 0;
    else if (ev.key === "End") next = n - 1;
    else if (ev.key === "Escape") next = null;
    else return;
    ev.preventDefault();
    setHover(next);
  };

  const now = series.map((s) => latest(s.values));
  const summary = series.map((s, i) =>
    `${s.label} ${now[i] === null ? "no data" : fmt(now[i] as number)}`
  ).join(", ");
  const tipLeft = idx !== null && x(times[idx]) > width / 2;

  return (
    <figure class="chart-card" aria-labelledby={`${id}-title`}>
      <figcaption class="chart-head">
        <div>
          <h3 id={`${id}-title`}>{title}</h3>
          <p class="chart-sub">{sub}</p>
        </div>
        {series.length === 1 && now[0] !== null && (
          <div class="chart-now">{fmt(now[0] as number)}</div>
        )}
      </figcaption>
      {series.length > 1 && (
        <ul class="chart-legend">
          {series.map((s, i) => (
            <li key={s.label}>
              <span class={`chart-key chart-s${i + 1}`} aria-hidden="true" />
              <span class="chart-legend-label">{s.label}</span>
              <strong>{now[i] === null ? "–" : fmt(now[i] as number)}</strong>
            </li>
          ))}
        </ul>
      )}
      <div
        class="chart-plot"
        ref={ref}
        tabIndex={0}
        role="img"
        aria-label={`${title}. Latest: ${summary}. Arrow keys read earlier samples.`}
        onKeyDown={onKey}
        onBlur={() => setHover(null)}
      >
        <svg
          width={width}
          height={HEIGHT}
          viewBox={`0 0 ${width} ${HEIGHT}`}
          onPointerMove={onMove}
          onPointerLeave={() => setHover(null)}
          aria-hidden="true"
        >
          {ticks.map((v) => (
            <g key={v}>
              <line
                class={v === 0 ? "chart-axis" : "chart-gridline"}
                x1={M.left}
                x2={width - M.right}
                y1={y(v)}
                y2={y(v)}
              />
              <text
                class="chart-tick"
                x={M.left - 8}
                y={y(v)}
                dy="0.32em"
                text-anchor="end"
              >
                {fmt(v)}
              </text>
            </g>
          ))}
          {n > 1 && xTicks(t0, t1).map((t) => (
            <text
              key={t}
              class="chart-tick"
              x={x(t)}
              y={HEIGHT - 6}
              text-anchor="middle"
            >
              {fmtClock(t)}
            </text>
          ))}
          {paths.map((segs, i) =>
            segs.map((p, j) =>
              p.single >= 0
                ? (
                  <circle
                    key={`${i}-${j}`}
                    class={`chart-dot chart-s${i + 1}`}
                    cx={x(times[p.single])}
                    cy={y(series[i].values[p.single] as number)}
                    r={3}
                  />
                )
                : (
                  <path
                    key={`${i}-${j}`}
                    class={`chart-line chart-s${i + 1}`}
                    d={p.d}
                  />
                )
            )
          )}
          {idx !== null && (
            <g>
              <line
                class="chart-cross"
                x1={x(times[idx])}
                x2={x(times[idx])}
                y1={M.top}
                y2={M.top + plotH}
              />
              {series.map((s, i) => {
                const v = s.values[idx];
                return typeof v === "number"
                  ? (
                    <circle
                      key={s.label}
                      class={`chart-dot chart-ring chart-s${i + 1}`}
                      cx={x(times[idx])}
                      cy={y(v)}
                      r={4}
                    />
                  )
                  : null;
              })}
            </g>
          )}
          <rect
            class="chart-hit"
            x={M.left}
            y={M.top}
            width={Math.max(plotW, 0)}
            height={plotH}
          />
        </svg>
        {idx !== null && (
          <div
            class={tipLeft ? "chart-tip flip" : "chart-tip"}
            style={{
              left: `${tipLeft ? x(times[idx]) - 12 : x(times[idx]) + 12}px`,
            }}
          >
            <div class="chart-tip-time">{fmtClock(times[idx], true)}</div>
            {series.map((s, i) => {
              const v = s.values[idx];
              return (
                <div class="chart-tip-row" key={s.label}>
                  <span
                    class={`chart-key chart-s${i + 1}`}
                    aria-hidden="true"
                  />
                  <strong>{typeof v === "number" ? fmt(v) : "–"}</strong>
                  <span>{s.label}</span>
                </div>
              );
            })}
          </div>
        )}
        {n === 0 && (
          <div class="chart-empty">
            No samples in this range yet.
          </div>
        )}
      </div>
      <details
        class="chart-table"
        onToggle={(ev) =>
          setTable((ev.currentTarget as HTMLDetailsElement).open)}
      >
        <summary>Table</summary>
        {table && (
          <div class="chart-table-wrap">
            <table>
              <thead>
                <tr>
                  <th scope="col">Time</th>
                  {series.map((s) => (
                    <th scope="col" key={s.label}>{s.label}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {times.map((_, k) => {
                  const i = n - 1 - k;
                  return (
                    <tr key={times[i]}>
                      <td>{fmtClock(times[i], true)}</td>
                      {series.map((s) => {
                        const v = s.values[i];
                        return (
                          <td key={s.label} class="num">
                            {typeof v === "number" ? fmt(v) : "–"}
                          </td>
                        );
                      })}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </details>
    </figure>
  );
}
