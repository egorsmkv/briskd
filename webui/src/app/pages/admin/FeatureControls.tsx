// Server feature controls: what this server offers, changed live and kept
// across REHASH and restarts (ircd_overrides on the server). Each control
// shows its value, marks a change made here (differing from the
// configuration file), and resets to the file's value.
import { useState } from "preact/hooks";
import type { Control } from "./api.ts";
import { busyKey, controls, features, isBusy, runAction } from "./store.ts";
import { ActionButton } from "./Table.tsx";

interface Meta {
  title: string;
  desc: string;
  /** Unit after a number, e.g. "s". */
  unit?: string;
}

const META: Record<string, Meta> = {
  "features.reactions": {
    title: "Emoji reactions",
    desc: "React to messages with emoji (+draft/react).",
  },
  "features.replies": {
    title: "Replies",
    desc: "Quote and answer a message (+draft/reply).",
  },
  "features.typing": {
    title: "Typing indicators",
    desc: "Show who is typing (+typing).",
  },
  "features.editing": {
    title: "Message editing",
    desc: "Edit sent messages in place.",
  },
  "features.redaction": {
    title: "Message deletion",
    desc: "Delete sent messages (draft/message-redaction).",
  },
  "features.link_previews": {
    title: "Link previews",
    desc: "OpenGraph cards for links, fetched with SSRF protection.",
  },
  chathistory: {
    title: "Message history",
    desc:
      "Record channel and account conversations and offer draft/chathistory. Off: nothing is recorded and the capability is withdrawn.",
  },
  history_limit: {
    title: "History length",
    desc: "Messages kept per channel or conversation.",
  },
  account_registration: {
    title: "Account registration",
    desc: "Let users create accounts (REGISTER and the sign-up page).",
  },
  account_registration_before_connect: {
    title: "Register before connecting",
    desc: "Allow REGISTER before the IRC session is registered.",
  },
  account_registration_email_required: {
    title: "Require an email address",
    desc: "New accounts must give an email address.",
  },
  multiclient: {
    title: "Several connections per account",
    desc: "A second login to the same account shares its nickname.",
  },
  account_rejoin: {
    title: "Rejoin channels on login",
    desc: "Logging in rejoins the channels the account was in.",
  },
  max_accounts: {
    title: "Maximum accounts",
    desc: "Registration stops at this many accounts.",
  },
  e2ee: {
    title: "End-to-end encryption",
    desc: "The E2EE key broker (egorsmkv.github.io/e2ee).",
  },
  calls: {
    title: "Voice calls",
    desc: "One-to-one calls through rtpengine.",
  },
  voice: {
    title: "Voice messages",
    desc: "Record and send OPUS clips (S3 storage).",
  },
  files: {
    title: "File sharing",
    desc: "Upload images and files (S3 storage).",
  },
  search: {
    title: "Message search",
    desc: "SEARCH and WebIRC search through ircd-search.",
  },
  dronebl: {
    title: "DroneBL checks",
    desc: "Look up connecting addresses in the DroneBL blocklist.",
  },
  utf8_only: {
    title: "UTF-8 only",
    desc: "Refuse messages that are not valid UTF-8 (UTF8ONLY).",
  },
  monitor_limit: {
    title: "MONITOR list size",
    desc: "Nicknames one client may watch.",
  },
  resource_delay: {
    title: "Nickname hold",
    desc: "Seconds a released nickname stays reserved (437).",
    unit: "s",
  },
};

const GROUPS: Array<[string, string]> = [
  ["chat", "Chat"],
  ["history", "History"],
  ["accounts", "Accounts"],
  ["services", "Services"],
  ["security", "Security"],
  ["limits", "Limits"],
];

function shown(c: Control): string {
  if (c.type === "boolean") return c.value ? "on" : "off";
  return `${c.value}${META[c.key]?.unit ?? ""}`;
}

function setControl(key: string, value: string): void {
  void runAction("set-control", [key, value], {
    after: (data) => {
      const next = (data as { controls?: Control[] }).controls;
      if (Array.isArray(next)) controls.value = next;
      // The chat switches also drive the older features summary.
      const f = features.value;
      if (f && key.startsWith("features.")) {
        features.value = {
          ...f,
          [key.slice("features.".length)]: value === "true",
        };
      }
      return Promise.resolve();
    },
  });
}

function resetControl(key: string): void {
  void runAction("reset-control", [key], {
    key: busyKey("reset-control", key),
    after: (data) => {
      const next = (data as { controls?: Control[] }).controls;
      if (Array.isArray(next)) controls.value = next;
      return Promise.resolve();
    },
  });
}

function NumberField({ c }: { c: Control }) {
  const [draft, setDraft] = useState<string | null>(null);
  const value = draft ?? String(c.value);
  const n = Number(value);
  const valid = /^\d+$/.test(value) && n >= (c.min ?? 0) &&
    n <= (c.max ?? Number.MAX_SAFE_INTEGER);
  const changed = draft !== null && value !== String(c.value);
  const save = () => {
    if (!valid || !changed) return;
    setControl(c.key, value);
    setDraft(null);
  };
  return (
    <div class="control-number">
      <input
        type="number"
        inputMode="numeric"
        min={c.min}
        max={c.max}
        value={value}
        aria-label={META[c.key]?.title ?? c.key}
        aria-invalid={valid ? undefined : "true"}
        onInput={(e) => setDraft((e.target as HTMLInputElement).value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") save();
          if (e.key === "Escape") setDraft(null);
        }}
      />
      {changed && (
        <ActionButton
          class="small primary"
          busyKey={busyKey("set-control", c.key)}
          disabled={!valid}
          onClick={save}
        >
          Save
        </ActionButton>
      )}
      {!valid && (
        <span class="control-hint err">
          {c.min}–{c.max}
        </span>
      )}
    </div>
  );
}

function Switch({ c }: { c: Control }) {
  const on = c.value === true;
  const title = META[c.key]?.title ?? c.key;
  return (
    <button
      type="button"
      role="switch"
      class={on ? "switch on" : "switch"}
      aria-checked={on ? "true" : "false"}
      aria-label={title}
      disabled={!c.available || isBusy(busyKey("set-control", c.key))}
      onClick={() => setControl(c.key, on ? "false" : "true")}
    >
      <span class="switch-knob" />
    </button>
  );
}

function ControlRow({ c }: { c: Control }) {
  const meta = META[c.key] ?? { title: c.key, desc: "" };
  return (
    <div
      class={`control-row${c.available ? "" : " unavailable"}`}
      data-key={c.key}
    >
      <div class="control-text">
        <div class="control-title">
          <strong>{meta.title}</strong>
          {c.overridden && (
            <span
              class="badge changed"
              title={`Changed here. The configuration file says ${
                c.type === "boolean"
                  ? (c.default ? "on" : "off")
                  : String(c.default)
              }.`}
            >
              changed
            </span>
          )}
        </div>
        <div class="muted control-desc">
          {c.available
            ? meta.desc
            : "Not configured in the configuration file; set it up there to enable."}
        </div>
        {c.overridden && (
          <button
            type="button"
            class="link-button"
            disabled={isBusy(busyKey("reset-control", c.key))}
            onClick={() => resetControl(c.key)}
          >
            Use the configuration file's value (
            {shown({ ...c, value: c.default })})
          </button>
        )}
      </div>
      <div class="control-input">
        {c.type === "boolean" ? <Switch c={c} /> : <NumberField c={c} />}
      </div>
    </div>
  );
}

/** All controls, grouped. */
export function FeatureControls() {
  const list = controls.value;
  if (!list) return <p class="muted">Loading features…</p>;
  const changed = list.filter((c) => c.overridden).length;
  return (
    <div class="feature-controls" id="feature-controls">
      <p class="muted">
        What this server offers. Changes apply at once, connected clients are
        told of capabilities added or withdrawn, and they are kept across REHASH
        and restarts. {changed > 0 &&
          `${changed} setting${
            changed === 1 ? " differs" : "s differ"
          } from the configuration file.`}
      </p>
      <div class="control-groups">
        {GROUPS.map(([group, title]) => {
          const rows = list.filter((c) => c.group === group);
          if (rows.length === 0) return null;
          return (
            <section class="panel control-group" key={group}>
              <h3>{title}</h3>
              {rows.map((c) => <ControlRow key={c.key} c={c} />)}
            </section>
          );
        })}
      </div>
    </div>
  );
}
