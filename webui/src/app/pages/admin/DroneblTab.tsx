// DroneBL: active IP bans (Unban) and a form to ban an IP.
import { useState } from "preact/hooks";
import { matchesFilter } from "./format.ts";
import { formKey, submitForm } from "./forms.ts";
import { busyKey, filterOf, overview, runAction } from "./store.ts";
import { ActionButton, FilterInput, mono, type Row, Table } from "./Table.tsx";

export function DroneblTab() {
  const [ip, setIp] = useState("");
  const [reason, setReason] = useState("");
  const q = filterOf("dronebl");
  const bans = (overview.value?.dronebl?.bans ?? []).filter((b) =>
    matchesFilter(q, b.ip, b.reason, String(b.code))
  );
  const rows: Row[] = bans.map((b) => ({
    key: b.ip,
    cells: [
      mono(b.ip),
      b.code,
      `${b.expires_in ?? 0}s`,
      b.reason || "",
      <ActionButton
        key="cell"
        class="small"
        busyKey={busyKey("dronebl-unban", b.ip)}
        onClick={() => void runAction("dronebl-unban", [b.ip])}
      >
        Unban
      </ActionButton>,
    ],
  }));

  const onSubmit = (ev: Event) => {
    ev.preventDefault();
    const addr = ip.trim();
    const why = reason.trim();
    const args = !addr ? null : why ? [addr, why] : [addr];
    void submitForm("dronebl-ban", args, () => {
      setIp("");
      setReason("");
    });
  };

  return (
    <>
      <div class="page-head">
        <h2>DroneBL Bans</h2>
        <FilterInput
          tableKey="dronebl"
          placeholder="Filter by IP or reason..."
        />
      </div>
      <form class="inline-form" id="form-ban-ip" onSubmit={onSubmit}>
        <input
          type="text"
          id="inp-ban-ip"
          placeholder="IP address to ban"
          required
          value={ip}
          onInput={(ev) => setIp(ev.currentTarget.value)}
        />
        <input
          type="text"
          id="inp-ban-reason"
          placeholder="Reason (optional)"
          value={reason}
          onInput={(ev) => setReason(ev.currentTarget.value)}
        />
        <ActionButton
          type="submit"
          class="danger"
          busyKey={formKey("dronebl-ban")}
        >
          Ban IP
        </ActionButton>
      </form>
      <div id="dronebl-wrap">
        <Table
          tableKey="dronebl"
          headers={["IP", "Code", "Expires In", "Reason", "Action"]}
          rows={rows}
          emptyText="No active bans."
        />
      </div>
    </>
  );
}
