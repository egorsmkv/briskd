// Links: connected peers (SQUIT) and configured peers that are down
// (Connect), plus a form to connect a configured peer by name.
import { useState } from "preact/hooks";
import { matchesFilter } from "./format.ts";
import { formKey, submitForm } from "./forms.ts";
import { busyKey, filterOf, openModal, overview, runAction } from "./store.ts";
import {
  ActionButton,
  FilterInput,
  mono,
  type Row,
  styled,
  Table,
} from "./Table.tsx";

function squit(name: string): void {
  openModal({
    title: `Disconnect Peer ${name}`,
    message: "Users and channels reachable only through this peer are removed.",
    label: "SQUIT reason",
    value: "Operator disconnect",
    confirmLabel: "SQUIT",
    danger: true,
    allowEmpty: true,
    onConfirm: (reason) => void runAction("squit", [name, reason]),
  });
}

export function LinksTab() {
  const [peer, setPeer] = useState("");
  const q = filterOf("links");
  const connected = overview.value?.links?.connected ?? [];
  const configured = overview.value?.links?.configured ?? [];
  const rows: Row[] = [];
  for (const l of connected) {
    const name = l.name || l.server || "";
    if (!matchesFilter(q, name, l.info, "connected")) continue;
    rows.push({
      key: `up:${name}`,
      cells: [
        mono(name),
        styled(`connected (hop ${l.hop ?? 1})`, "state-ok"),
        l.info || "",
        <ActionButton
          key="cell"
          class="danger small"
          busyKey={busyKey("squit", name)}
          onClick={() => squit(name)}
        >
          SQUIT
        </ActionButton>,
      ],
    });
  }
  for (const cfg of configured) {
    if (connected.some((l) => (l.name || l.server) === cfg.name)) continue;
    if (!matchesFilter(q, cfg.name, cfg.host, "configured")) continue;
    rows.push({
      key: `cfg:${cfg.name}`,
      cells: [
        mono(cfg.name),
        `configured (${cfg.host}:${cfg.port})`,
        cfg.tls ? "TLS" : "TCP",
        <ActionButton
          key="cell"
          class="primary small"
          busyKey={busyKey("connect", cfg.name)}
          onClick={() => void runAction("connect", [cfg.name])}
        >
          Connect
        </ActionButton>,
      ],
    });
  }

  const onSubmit = (ev: Event) => {
    ev.preventDefault();
    const name = peer.trim();
    void submitForm("connect", name ? [name] : null, () => setPeer(""));
  };

  return (
    <>
      <div class="page-head">
        <h2>Server Links</h2>
        <FilterInput tableKey="links" placeholder="Filter peers..." />
      </div>
      <form class="inline-form" id="form-connect" onSubmit={onSubmit}>
        <input
          type="text"
          id="inp-peer"
          placeholder="Configured peer name"
          required
          value={peer}
          onInput={(ev) => setPeer(ev.currentTarget.value)}
        />
        <ActionButton
          type="submit"
          class="primary"
          busyKey={formKey("connect")}
        >
          Connect Peer
        </ActionButton>
      </form>
      <div id="links-wrap">
        <Table
          tableKey="links"
          headers={["Server", "State", "Info", "Action"]}
          rows={rows}
          emptyText="No peers configured or connected."
        />
      </div>
    </>
  );
}
