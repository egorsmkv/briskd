// Operations: rehash, config check, TLS reload, log level, broadcast notice,
// message search (status, index size, rebuild), Mnesia backup, drain, and stop.
import { useState } from "preact/hooks";
import {
  busyKey,
  currentLogLevel,
  isBusy,
  LOG_LEVEL_SELECT_ID,
  logLevelChoice,
  openModal,
  overview,
  refresh,
  runAction,
  serverName,
  toast,
} from "./store.ts";
import { ActionButton } from "./Table.tsx";
import { fmtBytes } from "./format.ts";

const LOG_LEVELS = [
  "trace",
  "debug",
  "info",
  "notice",
  "warning",
  "error",
  "critical",
  "alert",
  "emergency",
];

/** An action with no arguments other than `args`, keyed by the action. */
function op(action: string, args: string[] = []): void {
  void runAction(action, args, { key: busyKey(action) });
}

function broadcast(): void {
  openModal({
    title: "Broadcast Server Notice",
    message: "Every connected user receives this NOTICE.",
    label: "Message to all connected users",
    placeholder: "Maintenance announcement...",
    confirmLabel: "Broadcast",
    onConfirm: (msg) => op("notice-all", [msg]),
  });
}

function drain(): void {
  openModal({
    title: "Drain Listeners",
    message:
      "Listeners stop accepting connections and every connected client is disconnected.",
    label: "Drain reason",
    value: "Server maintenance",
    confirmLabel: "Drain Now",
    danger: true,
    allowEmpty: true,
    requireText: serverName(),
    onConfirm: (reason) => op("drain", [reason]),
  });
}

function stop(): void {
  openModal({
    title: "Stop IRC Server",
    message:
      "The daemon shuts down. This panel stops working until it is started again.",
    label: "Shutdown reason",
    value: "Server shutting down",
    confirmLabel: "Stop Server",
    danger: true,
    allowEmpty: true,
    requireText: serverName(),
    onConfirm: (reason) => op("stop", [reason]),
  });
}

function rebuildSearch(): void {
  openModal({
    title: "Rebuild Search Index",
    message:
      "The index is cleared and rebuilt from stored history. Searches return partial results until it finishes, usually within seconds.",
    confirmLabel: "Rebuild Index",
    onConfirm: () =>
      void runAction("search-rebuild", [], {
        key: busyKey("search-rebuild"),
        // The rebuild runs in the background: show its progress shortly.
        after: () =>
          new Promise((r) => setTimeout(() => r(refresh(true)), 1500)),
      }),
  });
}

function when(ms: number | null | undefined): string {
  return ms ? new Date(ms).toLocaleString() : "never";
}

function SearchCard() {
  const info = overview.value?.search;
  const configured = !!info && info.status !== "not_configured";
  const svc = info?.service ?? {};
  const rows: Array<[string, string]> = !configured ? [] : [
    [
      "Indexer",
      info?.enabled
        ? `${info?.status ?? "unknown"}, ${info?.queued ?? 0} changes queued`
        : "switched off (Features & Media)",
    ],
    [
      "Service",
      svc.reachable
        ? "reachable"
        : `unreachable${svc.error ? ` (${svc.error})` : ""}`,
    ],
    [
      "Indexed messages",
      svc.reachable ? (svc.docs ?? 0).toLocaleString("en-US") : "-",
    ],
    [
      "Index size",
      svc.reachable
        ? `${fmtBytes(svc.bytes ?? 0)} in ${svc.segments ?? 0} segments`
        : "-",
    ],
    [
      "Last rebuild",
      info?.last_rebuild_at
        ? `${when(info.last_rebuild_at)}: ${
          (info.last_rebuild_docs ?? 0).toLocaleString("en-US")
        } messages in ${((info.last_rebuild_ms ?? 0) / 1000).toFixed(1)} s`
        : "never",
    ],
    ["Rebuilds since start", String(info?.rebuilds ?? 0)],
  ];
  if (configured && info?.last_error) {
    rows.push(["Last error", info.last_error]);
  }
  return (
    <div class="ops-card">
      <h3>Message Search</h3>
      <p class="muted">
        The Tantivy index behind SEARCH and WebIRC search. It mirrors stored
        history and is rebuilt from it at startup and after an outage.
      </p>
      {configured
        ? (
          <dl class="kv-list" id="search-info">
            {rows.map(([k, v]) => (
              <div key={k}>
                <dt>{k}</dt>
                <dd>{v}</dd>
              </div>
            ))}
          </dl>
        )
        : (
          <p class="muted" id="search-info">
            Not configured: add a <code>search</code>{" "}
            section to the configuration and restart.
          </p>
        )}
      <div class="ops-row">
        <ActionButton
          busyKey={busyKey("search-rebuild")}
          id="btn-search-rebuild"
          disabled={!configured || !info?.enabled}
          onClick={rebuildSearch}
        >
          Rebuild Index
        </ActionButton>
        <ActionButton
          busyKey="ui:refresh-search"
          id="btn-search-refresh"
          onClick={() => void refresh(true)}
        >
          Refresh
        </ActionButton>
      </div>
    </div>
  );
}

function BackupCard() {
  const [path, setPath] = useState("");
  const [invalid, setInvalid] = useState(false);
  const backup = (input: HTMLInputElement | null) => {
    if (isBusy(busyKey("backup"))) return;
    const p = path.trim();
    if (!p) {
      input?.focus();
      setInvalid(true);
      toast("err", "Enter a backup file path.");
      return;
    }
    op("backup", [p]);
  };
  return (
    <div class="ops-card">
      <h3>Mnesia Backup</h3>
      <p class="muted">Write a consistent Mnesia database snapshot to disk.</p>
      <div class="ops-row">
        <input
          type="text"
          id="inp-backup"
          class={invalid ? "invalid" : undefined}
          placeholder="/tmp/mnesia.bak"
          size={22}
          value={path}
          onInput={(ev) => {
            setPath(ev.currentTarget.value);
            setInvalid(false);
          }}
          onKeyDown={(ev) => {
            if (ev.key === "Enter") {
              ev.preventDefault();
              backup(ev.currentTarget);
            }
          }}
        />
        <ActionButton
          busyKey={busyKey("backup")}
          id="btn-backup"
          onClick={() =>
            backup(document.getElementById("inp-backup") as HTMLInputElement)}
        >
          Backup Mnesia
        </ActionButton>
      </div>
    </div>
  );
}

export function OperationsTab() {
  // Before the first overview the select shows its first option.
  const choice = logLevelChoice.value || LOG_LEVELS[0];
  return (
    <div class="ops-grid">
      <div class="ops-card">
        <h3>Configuration &amp; TLS</h3>
        <p class="muted">
          Reload configuration or TLS certificates without disconnecting
          clients.
        </p>
        <div class="ops-row">
          <ActionButton
            class="primary"
            busyKey={busyKey("rehash")}
            id="btn-rehash"
            onClick={() => op("rehash")}
          >
            Rehash Config
          </ActionButton>
          <ActionButton
            busyKey={busyKey("check-config")}
            id="btn-check-config"
            onClick={() => op("check-config")}
          >
            Check Config
          </ActionButton>
          <ActionButton
            busyKey={busyKey("reload-certs")}
            id="btn-reload-certs"
            onClick={() => op("reload-certs")}
          >
            Reload TLS Certs
          </ActionButton>
        </div>
      </div>

      <div class="ops-card">
        <h3>Logging &amp; Broadcast</h3>
        <p class="muted">
          Adjust runtime logger verbosity or send a server-wide NOTICE.
        </p>
        <div class="ops-row">
          <select
            id={LOG_LEVEL_SELECT_ID}
            aria-label="Log level"
            value={choice}
            onChange={(ev) => {
              logLevelChoice.value = ev.currentTarget.value;
            }}
          >
            {LOG_LEVELS.map((l) => <option key={l} value={l}>{l}</option>)}
          </select>
          <ActionButton
            busyKey={busyKey("log-level")}
            id="btn-log-level"
            disabled={!choice || choice === currentLogLevel.value}
            onClick={() => op("log-level", [choice])}
          >
            Set Log Level
          </ActionButton>
          <ActionButton
            busyKey={busyKey("notice-all")}
            id="btn-notice-all"
            onClick={broadcast}
          >
            Broadcast Notice
          </ActionButton>
        </div>
      </div>

      <SearchCard />

      <BackupCard />

      <div class="ops-card danger-zone">
        <h3>Server Lifecycle</h3>
        <p class="muted">
          Gracefully drain connections or shut down the IRC daemon.
        </p>
        <div class="ops-row">
          <ActionButton
            class="danger"
            busyKey={busyKey("drain")}
            id="btn-drain"
            onClick={drain}
          >
            Drain Listeners
          </ActionButton>
          <ActionButton
            class="danger"
            busyKey={busyKey("stop")}
            id="btn-stop"
            onClick={stop}
          >
            Stop Server
          </ActionButton>
        </div>
      </div>
    </div>
  );
}
