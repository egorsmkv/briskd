// Channels: active channels with Set Topic and channel Notice.
import type { ChannelEntry } from "./api.ts";
import { matchesFilter } from "./format.ts";
import { busyKey, filterOf, openModal, overview, runAction } from "./store.ts";
import { ActionButton, FilterInput, mono, type Row, Table } from "./Table.tsx";

function setTopic(ch: ChannelEntry): void {
  openModal({
    title: `Set Topic for ${ch.name}`,
    label: "Channel topic (leave blank to clear)",
    value: ch.topic || "",
    confirmLabel: "Save Topic",
    allowEmpty: true,
    onConfirm: (next) => void runAction("set-topic", [ch.name, next]),
  });
}

function notice(name: string): void {
  openModal({
    title: `Send Notice to ${name}`,
    label: "Server NOTICE message",
    placeholder: "Message to all members in channel...",
    confirmLabel: "Send Notice",
    onConfirm: (msg) => void runAction("notice-channel", [name, msg]),
  });
}

export function ChannelsTab() {
  const q = filterOf("channels");
  const channels = (overview.value?.channels?.channels ?? []).filter((ch) =>
    matchesFilter(q, ch.name, ch.topic, ch.modes)
  );
  const rows: Row[] = channels.map((ch) => ({
    key: ch.name,
    cells: [
      mono(ch.name),
      ch.local_members ?? 0,
      ch.remote_members ?? 0,
      mono(ch.modes || "+"),
      ch.predefined ? "yes" : "no",
      ch.topic || "",
      <span key="cell" class="action-row">
        <ActionButton
          class="small"
          busyKey={busyKey("set-topic", ch.name)}
          onClick={() => setTopic(ch)}
        >
          Set Topic
        </ActionButton>
        <ActionButton
          class="small"
          busyKey={busyKey("notice-channel", ch.name)}
          onClick={() => notice(ch.name)}
        >
          Notice
        </ActionButton>
      </span>,
    ],
  }));
  return (
    <>
      <div class="page-head">
        <h2>Active Channels</h2>
        <FilterInput
          tableKey="channels"
          placeholder="Filter by channel, topic, modes..."
        />
      </div>
      <div id="channels-wrap">
        <Table
          tableKey="channels"
          headers={[
            "Channel",
            "Local",
            "Remote",
            "Modes",
            "Predefined",
            "Topic",
            "Action",
          ]}
          rows={rows}
          emptyText="No active channels."
        />
      </div>
    </>
  );
}
