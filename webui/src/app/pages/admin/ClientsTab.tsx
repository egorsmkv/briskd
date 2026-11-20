// Clients: connected sessions with Kick and (for IP hosts) Ban IP.
import { isIpAddress, matchesFilter } from "./format.ts";
import { busyKey, filterOf, openModal, overview, runAction } from "./store.ts";
import { ActionButton, FilterInput, mono, type Row, Table } from "./Table.tsx";

function kick(nick: string): void {
  openModal({
    title: `Kick ${nick}`,
    message: "The client is disconnected immediately and may reconnect.",
    label: "Kick reason",
    value: "Disconnected by administrator",
    confirmLabel: "Kick Client",
    danger: true,
    allowEmpty: true,
    onConfirm: (reason) => void runAction("kick-client", [nick, reason]),
  });
}

function banIp(host: string): void {
  openModal({
    title: `Ban IP ${host}`,
    message: "New connections from this address are refused.",
    label: "Ban reason",
    value: "Manual administrator ban",
    confirmLabel: "Ban IP",
    danger: true,
    allowEmpty: true,
    onConfirm: (reason) =>
      void runAction("dronebl-ban", reason ? [host, reason] : [host]),
  });
}

export function ClientsTab() {
  const q = filterOf("clients");
  const clients = (overview.value?.clients?.clients ?? []).filter((c) =>
    matchesFilter(q, c.nick, c.user, c.host, c.account)
  );
  const rows: Row[] = clients.map((c, i) => {
    const nick = c.nick;
    const host = c.host;
    const canBan = Boolean(host && isIpAddress(host));
    const actions = nick || canBan
      ? (
        <span class="action-row">
          {nick && (
            <ActionButton
              class="danger small"
              busyKey={busyKey("kick-client", nick)}
              onClick={() => kick(nick)}
            >
              Kick
            </ActionButton>
          )}
          {canBan && host && (
            <ActionButton
              class="small"
              busyKey={busyKey("dronebl-ban", host)}
              onClick={() => banIp(host)}
            >
              Ban IP
            </ActionButton>
          )}
        </span>
      )
      : "";
    return {
      key: nick ? `n:${nick}` : `i:${i}`,
      cells: [
        mono(c.nick || "*"),
        mono(`${c.user || "-"}@${c.host || "-"}`),
        c.account || "-",
        c.operator ? "yes" : "no",
        c.secure ? "yes" : "no",
        Array.isArray(c.channels)
          ? c.channels.join(", ")
          : String(c.channels ?? 0),
        `${c.idle_seconds ?? 0}s`,
        actions,
      ],
    };
  });
  return (
    <>
      <div class="page-head">
        <h2>Connected Clients</h2>
        <FilterInput
          tableKey="clients"
          placeholder="Filter by nick, host, account..."
        />
      </div>
      <div id="clients-wrap">
        <Table
          tableKey="clients"
          headers={[
            "Nick",
            "User@Host",
            "Account",
            "Oper",
            "TLS",
            "Channels",
            "Idle",
            "Action",
          ]}
          rows={rows}
          emptyText="No clients connected."
        />
      </div>
    </>
  );
}
