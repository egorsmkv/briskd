// Overview: summary cards; most link to their tab (mouse and keyboard).
import type { ComponentChildren } from "preact";
import { fmtBytes, type Tab } from "./format.ts";
import { overview } from "./store.ts";

function Card(
  { label, value, sub, goto, onGoto }: {
    label: ComponentChildren;
    value: string;
    sub: string;
    goto?: Tab;
    onGoto: (tab: Tab) => void;
  },
) {
  if (!goto) {
    return (
      <div class="card">
        <div class="label">{label}</div>
        <div class="value">{value}</div>
        <div class="sub">{sub}</div>
      </div>
    );
  }
  return (
    <div
      class="card clickable"
      data-goto={goto}
      role="link"
      tabIndex={0}
      onClick={() => onGoto(goto)}
      onKeyDown={(ev) => {
        if (ev.key === "Enter" || ev.key === " ") {
          ev.preventDefault();
          onGoto(goto);
        }
      }}
    >
      <div class="label">{label}</div>
      <div class="value">{value}</div>
      <div class="sub">{sub}</div>
    </div>
  );
}

export function OverviewTab({ onGoto }: { onGoto: (tab: Tab) => void }) {
  const data = overview.value;
  if (!data) {
    const labels: Array<[string, Tab | undefined]> = [
      ["Sessions", "clients"],
      ["Channels", "channels"],
      ["Network", "links"],
      ["Accounts", "accounts"],
      ["DroneBL", "dronebl"],
      ["Features & Media", "media"],
      ["Database", undefined],
      ["Erlang VM", undefined],
    ];
    return (
      <div class="grid" id="stats-grid">
        {labels.map(([label, goto]) => (
          <Card
            key={label}
            label={label}
            value="-"
            sub=""
            goto={goto}
            onGoto={onGoto}
          />
        ))}
      </div>
    );
  }

  const st = data.status ?? {};
  const dbl = data.dronebl?.stats ?? {};
  const feats = data.features ?? {};
  const totalFeats = Object.keys(feats).length || 6;
  const enabledCount = Object.values(feats).filter(Boolean).length;
  const ms = data.media_summary ?? {};
  const mediaSub = [
    ms.voice_enabled
      ? `voice ${fmtBytes(ms.voice_max_bytes ?? 0)}`
      : "voice off",
    ms.files_enabled
      ? `files ${fmtBytes(ms.files_max_bytes ?? 0)}`
      : "files off",
  ].join(" / ");

  return (
    <div class="grid" id="stats-grid">
      <Card
        label="Sessions"
        value={`${st.sessions ?? 0} / ${st.max_clients ?? 0}`}
        sub={`registered: ${st.registered_users ?? 0}, operators: ${
          st.operators_online ?? 0
        }`}
        goto="clients"
        onGoto={onGoto}
      />
      <Card
        label="Channels"
        value={String(st.channels ?? 0)}
        sub={`remote: ${st.remote_channels ?? 0}`}
        goto="channels"
        onGoto={onGoto}
      />
      <Card
        label="Network"
        value={`${st.known_servers ?? 0} peers`}
        sub={`remote users: ${st.remote_users ?? 0}, services: ${
          st.services ?? 0
        }`}
        goto="links"
        onGoto={onGoto}
      />
      <Card
        label="Accounts"
        value={String(st.accounts ?? 0)}
        sub={`retention: ${st.retention || "-"}`}
        goto="accounts"
        onGoto={onGoto}
      />
      <Card
        label="DroneBL"
        value={dbl.enabled ? `${dbl.bans ?? 0} bans` : "disabled"}
        sub={dbl.enabled
          ? `clean cache: ${dbl.cached_clean ?? 0}, in-flight: ${
            dbl.in_flight ?? 0
          }`
          : "enable in config"}
        goto="dronebl"
        onGoto={onGoto}
      />
      <Card
        label="Features & Media"
        value={`${enabledCount}/${totalFeats} features`}
        sub={mediaSub}
        goto="media"
        onGoto={onGoto}
      />
      <Card
        label="Database"
        value={fmtBytes(st.db_disk_bytes || 0)}
        sub={`RAM: ${fmtBytes(st.db_memory_bytes || 0)} | ${
          st.db_tables ?? 0
        } tables`}
        onGoto={onGoto}
      />
      <Card
        label="Erlang VM"
        value={fmtBytes(st.memory_bytes || 0)}
        sub={`${st.erlang_processes ?? 0} processes`}
        onGoto={onGoto}
      />
    </div>
  );
}
