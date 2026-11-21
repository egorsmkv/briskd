// Page header: server name and status, uptime and listeners, the "updated"
// stamp, auto-refresh, theme toggle, and manual refresh.
import { useEffect, useRef, useState } from "preact/hooks";
import { formatAgo } from "../../../common/admin_text.ts";
import { initTheme } from "../../../common/theme.ts";
import { signOut } from "./api.ts";
import { fmtUptime } from "./format.ts";
import {
  autoRefresh,
  lastUpdated,
  overview,
  refresh,
  setAutoRefresh,
  setBusy,
  unreachable,
} from "./store.ts";
import { ActionButton } from "./Table.tsx";

const REFRESH_KEY = "ui:refresh";
/** How often the "Updated … ago" stamp is redrawn, in milliseconds. */
const STAMP_TICK_MS = 1000;

function ThemeButton() {
  const ref = useRef<HTMLButtonElement>(null);
  // The theme module labels the button and toggles light/dark on click.
  useEffect(() => {
    initTheme([ref.current]);
  }, []);
  return (
    <button
      type="button"
      id="btn-theme"
      ref={ref}
      aria-label="Toggle dark mode"
    >
      Dark
    </button>
  );
}

function Stamp() {
  const [, tick] = useState(0);
  useEffect(() => {
    const id = setInterval(() => tick((n) => n + 1), STAMP_TICK_MS);
    return () => clearInterval(id);
  }, []);
  const at = lastUpdated.value;
  return (
    <span class="muted last-updated" id="last-updated" aria-live="off">
      {at ? `Updated ${formatAgo(Date.now() - at)}` : ""}
    </span>
  );
}

export function Header() {
  const data = overview.value;
  const st = data?.status;
  let badgeText = "loading";
  let badgeClass = "badge";
  if (unreachable.value) {
    badgeText = "unreachable";
    badgeClass = "badge off";
  } else if (data) {
    badgeText = st?.status || "unknown";
    badgeClass = st?.status === "running" ? "badge" : "badge off";
  }
  const meta = data
    ? `network ${st?.network || "-"} | up ${
      fmtUptime(st?.uptime_seconds || 0)
    } | listeners: ` +
      (st?.listeners || []).map((l) => `${l.transport}:${l.port}`).join(", ")
    : "";

  const manualRefresh = async () => {
    setBusy(REFRESH_KEY, true);
    try {
      await refresh(true);
    } finally {
      setBusy(REFRESH_KEY, false);
    }
  };

  return (
    <header>
      <div class="brand">
        <h1 id="srv-name">{data ? st?.name || "briskd" : "briskd"}</h1>
        <span id="srv-status" class={badgeClass}>{badgeText}</span>
        <span id="srv-meta" class="muted">{meta}</span>
      </div>
      <div class="header-controls">
        <Stamp />
        <label class="muted">
          <input
            type="checkbox"
            id="auto-refresh"
            checked={autoRefresh.value}
            onChange={(ev) => setAutoRefresh(ev.currentTarget.checked)}
          />{" "}
          Auto-refresh (5s)
        </label>
        <ThemeButton />
        <ActionButton
          busyKey={REFRESH_KEY}
          id="btn-refresh"
          onClick={() => void manualRefresh()}
        >
          Refresh
        </ActionButton>
        <button
          type="button"
          id="btn-sign-out"
          onClick={() => void signOut()}
        >
          Sign out
        </button>
      </div>
    </header>
  );
}
