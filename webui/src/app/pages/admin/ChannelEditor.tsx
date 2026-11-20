// The settings of one channel, edited as the server (ircdctl
// set-channel-modes): mode switches, key, user limit, and the ban,
// exception, and invite-exception lists. Every change is one MODE from the
// server, seen by members and sent to peers (not for local & channels).
import { useState } from "preact/hooks";
import type { ChannelEntry } from "./api.ts";
import { busyKey, isBusy, runAction } from "./store.ts";
import { ActionButton } from "./Table.tsx";

/** Channel mode switches, in the order shown (RFC 2811 4.2). */
const FLAGS: Array<[string, string, string]> = [
  ["n", "No outside messages", "Only members can send to the channel."],
  ["t", "Topic lock", "Only channel operators can change the topic."],
  ["m", "Moderated", "Only operators and voiced members can speak."],
  ["i", "Invite only", "Joining needs an invitation or an invite exception."],
  ["s", "Secret", "Hidden from LIST, WHOIS, and NAMES for non-members."],
  ["p", "Private", "Listed without its topic or members."],
  ["q", "Quiet", "Joins, parts, and nick changes are not shown (server only)."],
];

/** Mask lists: mode letter, title, field of ChannelEntry. */
const LISTS: Array<
  ["b" | "e" | "I", string, "bans" | "exceptions" | "invites"]
> = [
  ["b", "Bans", "bans"],
  ["e", "Ban exceptions", "exceptions"],
  ["I", "Invite exceptions", "invites"],
];

/** Entries per list (ISUPPORT MAXLIST=beI:100). */
const MAX_LIST = 100;

function setModes(channel: string, modes: string, args: string[] = []) {
  return runAction("set-channel-modes", [channel, modes, ...args]);
}

/** A mask is one IRC parameter: no spaces, not starting with ":". */
function validMask(mask: string): boolean {
  return mask !== "" && !/\s/.test(mask) && !mask.startsWith(":") &&
    mask.length <= 200;
}

function MaskList(
  { ch, mode, title, items }: {
    ch: ChannelEntry;
    mode: "b" | "e" | "I";
    title: string;
    items: string[];
  },
) {
  const [draft, setDraft] = useState("");
  const mask = draft.trim();
  const full = items.length >= MAX_LIST;
  const add = async (ev: Event) => {
    ev.preventDefault();
    if (!validMask(mask) || full) return;
    if (await setModes(ch.name, `+${mode}`, [mask])) setDraft("");
  };
  return (
    <section class="chan-list" data-mode={mode}>
      <h4>
        {title} <span class="muted">{items.length}/{MAX_LIST}</span>
      </h4>
      {items.length === 0
        ? <p class="muted chan-empty">None.</p>
        : (
          <ul class="mask-chips">
            {items.map((m) => (
              <li key={m} class="mask-chip">
                <code>{m}</code>
                <button
                  type="button"
                  class="chip-remove"
                  aria-label={`Remove ${m}`}
                  title="Remove"
                  disabled={isBusy(busyKey("set-channel-modes", ch.name))}
                  onClick={() => void setModes(ch.name, `-${mode}`, [m])}
                >
                  ×
                </button>
              </li>
            ))}
          </ul>
        )}
      <form class="inline-form compact" onSubmit={add}>
        <input
          type="text"
          placeholder="nick!user@host, e.g. *!*@203.0.113.*"
          aria-label={`Add to ${title}`}
          value={draft}
          spellcheck={false}
          autocomplete="off"
          onInput={(ev) => setDraft(ev.currentTarget.value)}
        />
        <ActionButton
          type="submit"
          class="small"
          busyKey={busyKey("set-channel-modes", ch.name)}
          disabled={!validMask(mask) || full}
        >
          Add
        </ActionButton>
      </form>
    </section>
  );
}

function KeyAndLimit({ ch }: { ch: ChannelEntry }) {
  const [key, setKey] = useState("");
  const [limit, setLimit] = useState("");
  const busy = busyKey("set-channel-modes", ch.name);
  const keyOk = key !== "" && key.length <= 64 && !/[\s,:]/.test(key);
  const n = Number(limit);
  const limitOk = /^\d+$/.test(limit) && n > 0 && n <= 2147483647;
  return (
    <div class="chan-params">
      <div class="chan-param">
        <div class="control-text">
          <strong>Key</strong>
          <span class="muted control-desc">
            {ch.has_key ? "A key is set; joining needs it." : "No key."}
          </span>
        </div>
        <form
          class="inline-form compact"
          onSubmit={async (ev) => {
            ev.preventDefault();
            if (keyOk && await setModes(ch.name, "+k", [key])) setKey("");
          }}
        >
          <input
            type="password"
            autocomplete="new-password"
            placeholder={ch.has_key ? "New key" : "Key"}
            aria-label="Channel key"
            value={key}
            onInput={(ev) => setKey(ev.currentTarget.value)}
          />
          <ActionButton
            type="submit"
            class="small"
            busyKey={busy}
            disabled={!keyOk}
          >
            Set
          </ActionButton>
          {ch.has_key && (
            <ActionButton
              class="small"
              busyKey={busy}
              onClick={() => void setModes(ch.name, "-k", ["*"])}
            >
              Remove
            </ActionButton>
          )}
        </form>
      </div>
      <div class="chan-param">
        <div class="control-text">
          <strong>User limit</strong>
          <span class="muted control-desc">
            {ch.limit ? `At most ${ch.limit} members.` : "No limit."}
          </span>
        </div>
        <form
          class="inline-form compact"
          onSubmit={async (ev) => {
            ev.preventDefault();
            if (limitOk && await setModes(ch.name, "+l", [String(n)])) {
              setLimit("");
            }
          }}
        >
          <input
            type="number"
            inputMode="numeric"
            min={1}
            placeholder={ch.limit ? String(ch.limit) : "Limit"}
            aria-label="User limit"
            value={limit}
            onInput={(ev) => setLimit(ev.currentTarget.value)}
          />
          <ActionButton
            type="submit"
            class="small"
            busyKey={busy}
            disabled={!limitOk}
          >
            Set
          </ActionButton>
          {ch.limit
            ? (
              <ActionButton
                class="small"
                busyKey={busy}
                onClick={() => void setModes(ch.name, "-l")}
              >
                Remove
              </ActionButton>
            )
            : null}
        </form>
      </div>
    </div>
  );
}

/** The editor for `ch`, closed with `onClose`. */
export function ChannelEditor(
  { ch, onClose }: { ch: ChannelEntry; onClose: () => void },
) {
  const set = new Set((ch.modes ?? "").replace(/^\+/, "").split(""));
  const busy = busyKey("set-channel-modes", ch.name);
  const local = ch.name.startsWith("&");
  return (
    <section
      class="panel chan-editor"
      id="channel-editor"
      aria-labelledby="channel-editor-title"
    >
      <div class="chan-editor-head">
        <div>
          <h3 id="channel-editor-title">
            <code>{ch.name}</code>
          </h3>
          <p class="muted control-desc">
            {ch.local_members ?? 0} local, {ch.remote_members ?? 0}{" "}
            remote members. Changes are made by the server and shown to members
            {local ? "" : " and other servers"}.
          </p>
        </div>
        <button
          type="button"
          class="small"
          aria-label="Close channel settings"
          onClick={onClose}
        >
          Close
        </button>
      </div>
      <div class="chan-editor-grid">
        <div class="control-group chan-modes">
          <h4>Modes</h4>
          {FLAGS.map(([m, title, desc]) => {
            const on = set.has(m);
            return (
              <div class="control-row" key={m} data-mode={m}>
                <div class="control-text">
                  <div class="control-title">
                    <strong>{title}</strong>
                    <code class="muted">+{m}</code>
                  </div>
                  <div class="muted control-desc">{desc}</div>
                </div>
                <button
                  type="button"
                  role="switch"
                  class={on ? "switch on" : "switch"}
                  aria-checked={on ? "true" : "false"}
                  aria-label={title}
                  disabled={isBusy(busy)}
                  onClick={() =>
                    void setModes(ch.name, `${on ? "-" : "+"}${m}`)}
                >
                  <span class="switch-knob" />
                </button>
              </div>
            );
          })}
        </div>
        <div class="chan-side">
          <KeyAndLimit ch={ch} />
          {LISTS.map(([mode, title, field]) => (
            <MaskList
              key={mode}
              ch={ch}
              mode={mode}
              title={title}
              items={ch[field] ?? []}
            />
          ))}
        </div>
      </div>
    </section>
  );
}
