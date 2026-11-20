// Channels: create a channel; per channel, edit its modes, key, limit, and
// mask lists (ChannelEditor), set its topic, send a notice, or delete it.
import { useRef, useState } from "preact/hooks";
import type { ChannelEntry } from "./api.ts";
import { ChannelEditor } from "./ChannelEditor.tsx";
import { matchesFilter } from "./format.ts";
import { formKey, submitForm } from "./forms.ts";
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

function deleteChannel(ch: ChannelEntry, onDeleted: () => void): void {
  const members = ch.local_members ?? 0;
  openModal({
    title: `Delete ${ch.name}?`,
    message: `${
      members
        ? `${members} member${
          members === 1 ? " is" : "s are"
        } removed from the channel. `
        : ""
    }Its topic, modes, lists, and history are deleted. This cannot be undone.`,
    label: "Reason shown to members",
    value: "Channel closed by administrator",
    allowEmpty: true,
    requireText: ch.name,
    confirmLabel: "Delete Channel",
    danger: true,
    onConfirm: async (reason) => {
      if (await runAction("delete-channel", [ch.name, reason])) onDeleted();
    },
  });
}

/** A channel name the server accepts here: #, &, or + and no separators. */
function validName(name: string): boolean {
  // The server also refuses a BEL (^G); it reports that itself.
  return /^[#&+][^\s,:]{1,49}$/.test(name);
}

export function ChannelsTab() {
  const [name, setName] = useState("");
  const [topic, setTopicDraft] = useState("");
  const [editing, setEditing] = useState<string | null>(null);
  const nameRef = useRef<HTMLInputElement>(null);

  const all = overview.value?.channels?.channels ?? [];
  const q = filterOf("channels");
  const channels = all.filter((ch) =>
    matchesFilter(q, ch.name, ch.topic, ch.modes)
  );
  const selected = editing
    ? all.find((ch) => ch.name.toLowerCase() === editing.toLowerCase())
    : undefined;

  const typed = name.trim();
  const fullName = typed && !/^[#&+]/.test(typed) ? `#${typed}` : typed;
  const nameOk = validName(fullName);

  const onSubmit = (ev: Event) => {
    ev.preventDefault();
    const t = topic.trim();
    void submitForm(
      "create-channel",
      nameOk ? (t ? [fullName, t] : [fullName]) : null,
      () => {
        setName("");
        setTopicDraft("");
        nameRef.current?.focus();
      },
    );
  };

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
        <button
          type="button"
          class={editing === ch.name ? "small primary" : "small"}
          aria-expanded={editing === ch.name ? "true" : "false"}
          aria-controls="channel-editor"
          onClick={() => setEditing(editing === ch.name ? null : ch.name)}
        >
          Settings
        </button>
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
        <ActionButton
          class="danger small"
          busyKey={busyKey("delete-channel", ch.name)}
          disabled={ch.predefined}
          title={ch.predefined
            ? "Listed in the configuration file's channels; remove it there"
            : undefined}
          onClick={() =>
            deleteChannel(ch, () => {
              if (editing === ch.name) setEditing(null);
            })}
        >
          Delete
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
      <form class="inline-form" id="form-channel" onSubmit={onSubmit}>
        <input
          ref={nameRef}
          type="text"
          id="inp-chan-name"
          placeholder="#channel"
          aria-label="Channel name"
          aria-invalid={typed && !nameOk ? "true" : undefined}
          required
          spellcheck={false}
          autocomplete="off"
          value={name}
          onInput={(ev) => setName(ev.currentTarget.value)}
        />
        <input
          type="text"
          id="inp-chan-topic"
          placeholder="Topic (optional)"
          aria-label="Topic"
          maxLength={390}
          value={topic}
          onInput={(ev) => setTopicDraft(ev.currentTarget.value)}
        />
        <ActionButton
          type="submit"
          class="primary"
          busyKey={formKey("create-channel")}
          disabled={!nameOk}
        >
          Create Channel
        </ActionButton>
      </form>
      {selected && (
        <ChannelEditor
          key={selected.name}
          ch={selected}
          onClose={() => setEditing(null)}
        />
      )}
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
