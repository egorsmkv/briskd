// Stats: the server over the last 15 minutes or hour, from GET /api/stats
// (briskd_stats samples every 5 s and keeps one hour in memory). Fetched only
// while this tab is shown; a refetch keeps the previous charts until the new
// data arrives.
import { useEffect, useState } from "preact/hooks";
import { fetchStats } from "./api.ts";
import { autoRefresh, overview } from "./store.ts";
import { LineChart, type Series } from "./LineChart.tsx";
import {
  fmtBytesShort,
  fmtCount,
  latest,
  type StatsPayload,
  windowStart,
} from "./stats_format.ts";

const RANGES = [
  { minutes: 15, label: "15 min" },
  { minutes: 60, label: "1 hour" },
] as const;
const RANGE_KEY = "briskd-admin-stats-range";
const REFRESH_MS = 5000;

function savedRange(): number {
  try {
    return Number(localStorage.getItem(RANGE_KEY)) === 60 ? 60 : 15;
  } catch {
    return 15;
  }
}

const perSec = (f: (v: number) => string) => (v: number) => `${f(v)}/s`;
const pct = (v: number) => `${Math.round(v)}%`;

export function StatsTab({ active }: { active: boolean }) {
  const [data, setData] = useState<StatsPayload | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [minutes, setMinutes] = useState(savedRange);

  useEffect(() => {
    if (!active) return;
    let stopped = false;
    const load = async () => {
      if (document.hidden) return;
      setLoading(true);
      try {
        const next = await fetchStats();
        if (!stopped) {
          setData(next);
          setError(null);
        }
      } catch (e) {
        if (!stopped) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!stopped) setLoading(false);
      }
    };
    void load();
    const id = setInterval(() => {
      if (autoRefresh.value) void load();
    }, REFRESH_MS);
    return () => {
      stopped = true;
      clearInterval(id);
    };
  }, [active]);

  const pick = (m: number) => {
    setMinutes(m);
    try {
      localStorage.setItem(RANGE_KEY, String(m));
    } catch {
      // Storage unavailable: the choice lasts for this page only.
    }
  };

  const m = data?.metrics ?? {};
  const allTimes = (m.t ?? []) as number[];
  const from = allTimes.length
    ? allTimes[allTimes.length - 1] - minutes * 60_000
    : 0;
  const start = windowStart(allTimes, from);
  const times = allTimes.slice(start);
  const col = (k: string) => (m[k] ?? []).slice(start);
  const s = (label: string, k: string): Series => ({ label, values: col(k) });
  const maxGap = (data?.interval_ms ?? REFRESH_MS) * 2.5;
  const now = (k: string) => latest(m[k] ?? []);
  const maxClients = overview.value?.status?.max_clients;

  const tiles: Array<[string, string, string]> = [
    [
      "Sessions",
      now("sessions") === null ? "–" : fmtCount(now("sessions") as number),
      maxClients ? `of ${fmtCount(maxClients)} allowed` : "local connections",
    ],
    [
      "Messages sent",
      now("lines_out") === null
        ? "–"
        : `${fmtCount(now("lines_out") as number)}/s`,
      "lines written to clients and peers",
    ],
    [
      "State queue",
      now("state_queue") === null
        ? "–"
        : fmtCount(now("state_queue") as number),
      "messages waiting for briskd_state",
    ],
    [
      "Schedulers",
      now("scheduler_util") === null
        ? "–"
        : pct(now("scheduler_util") as number),
      "busy, all normal schedulers",
    ],
    [
      "Memory",
      now("memory_total") === null
        ? "–"
        : fmtBytesShort(now("memory_total") as number),
      "Erlang VM total",
    ],
  ];

  return (
    <div class={loading && data ? "stats refreshing" : "stats"}>
      <div class="page-head">
        <h2>Server Stats</h2>
        <div class="stats-range" role="group" aria-label="Time range">
          {RANGES.map((r) => (
            <button
              key={r.minutes}
              type="button"
              class={minutes === r.minutes ? "seg active" : "seg"}
              aria-pressed={minutes === r.minutes ? "true" : "false"}
              onClick={() => pick(r.minutes)}
            >
              {r.label}
            </button>
          ))}
        </div>
      </div>
      <p class="stats-note">
        Sampled every {Math.round((data?.interval_ms ?? REFRESH_MS) / 1000)}
        {" "}
        s. The last hour is kept in memory and starts empty when the server
        restarts.
      </p>
      {error && (
        <div class="stats-notice err" role="status">
          Stats unavailable: {error}
        </div>
      )}
      {data && allTimes.length === 0 && (
        <div class="stats-notice" role="status">
          Collecting the first samples…
        </div>
      )}
      <div class="grid stats-tiles">
        {tiles.map(([label, value, sub]) => (
          <div class="card" key={label}>
            <div class="label">{label}</div>
            <div class="value">{value}</div>
            <div class="sub">{sub}</div>
          </div>
        ))}
      </div>
      <div class="chart-grid">
        <LineChart
          id="chart-clients"
          title="Clients"
          sub="Local connections, users past registration, and users on linked servers"
          times={times}
          series={[
            s("Sessions", "sessions"),
            s("Registered", "registered"),
            s("Remote users", "remote_users"),
          ]}
          fmt={fmtCount}
          maxGap={maxGap}
        />
        <LineChart
          id="chart-lines"
          title="Messages per second"
          sub="IRC lines received from and written to clients and server links"
          times={times}
          series={[s("Received", "lines_in"), s("Sent", "lines_out")]}
          fmt={perSec(fmtCount)}
          maxGap={maxGap}
        />
        <LineChart
          id="chart-bytes"
          title="Bandwidth"
          sub="Bytes of those lines per second"
          times={times}
          series={[s("Received", "bytes_in"), s("Sent", "bytes_out")]}
          fmt={perSec(fmtBytesShort)}
          bytes
          maxGap={maxGap}
        />
        <LineChart
          id="chart-queue"
          title="State process queue"
          sub="Messages waiting for briskd_state, the single writer of protocol state. Sustained growth means it is saturated."
          times={times}
          series={[s("Queued messages", "state_queue")]}
          fmt={fmtCount}
          maxGap={maxGap}
        />
        <LineChart
          id="chart-sched"
          title="Scheduler utilization"
          sub="Busy share of the normal schedulers between samples"
          times={times}
          series={[s("Busy", "scheduler_util")]}
          fmt={pct}
          yMax={100}
          maxGap={maxGap}
        />
        <LineChart
          id="chart-memory"
          title="Memory"
          sub="Erlang VM total and its largest parts"
          times={times}
          series={[
            s("Total", "memory_total"),
            s("Processes", "memory_processes"),
            s("Binaries", "memory_binary"),
            s("ETS", "memory_ets"),
          ]}
          fmt={fmtBytesShort}
          bytes
          maxGap={maxGap}
        />
        <LineChart
          id="chart-conns"
          title="Connections per second"
          sub="Accepted, and refused because max_clients was reached"
          times={times}
          series={[s("Accepted", "connections"), s("Refused", "rejected")]}
          fmt={perSec(fmtCount)}
          maxGap={maxGap}
        />
        <LineChart
          id="chart-runq"
          title="Run queue"
          sub="Erlang processes ready to run and waiting for a scheduler"
          times={times}
          series={[s("Waiting processes", "run_queue")]}
          fmt={fmtCount}
          maxGap={maxGap}
        />
      </div>
    </div>
  );
}
