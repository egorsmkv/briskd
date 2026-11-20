// Media & Features: live feature toggles, voice messages, and shared files
// (from GET /api/media), with upload limit reset.
import { fmtBytes, matchesFilter } from "./format.ts";
import {
  busyKey,
  confirmDelete,
  features,
  filterOf,
  media,
  MEDIA_REFRESH_KEY,
  refreshAll,
  refreshMedia,
  runAction,
} from "./store.ts";
import { ActionButton, FilterInput, mono, type Row, Table } from "./Table.tsx";

const FEATURE_META: Array<{ key: string; title: string; desc: string }> = [
  {
    key: "reactions",
    title: "Emoji Reactions",
    desc: "+draft/react TAGMSG emoji pills",
  },
  {
    key: "replies",
    title: "Message Replies",
    desc: "+draft/reply quoted message threads",
  },
  {
    key: "typing",
    title: "Typing Indicators",
    desc: "+typing live typing notifications",
  },
  {
    key: "editing",
    title: "Message Editing",
    desc: "+egorsmkv.github.io/edit in-place edits",
  },
  {
    key: "redaction",
    title: "Message Redaction",
    desc: "draft/message-redaction REDACT deletions",
  },
  {
    key: "link_previews",
    title: "Link Previews",
    desc: "SSRF-protected OpenGraph cards for URLs",
  },
];

function toggleFeature(key: string, enable: boolean): void {
  void runAction("toggle-feature", [key, enable ? "true" : "false"], {
    after: async (data) => {
      const next = data.features;
      if (next && typeof next === "object") {
        features.value = next as Record<string, boolean>;
      }
      await refreshAll();
    },
  });
}

function FeatureGrid() {
  const feats = features.value;
  return (
    <div class="feature-grid" id="features-grid">
      {feats && FEATURE_META.map((item) => {
        const enabled = feats[item.key] !== false;
        const verb = enabled ? "Disable" : "Enable";
        return (
          <div
            key={item.key}
            class={enabled ? "feature-card on" : "feature-card"}
          >
            <div class="feature-top">
              <strong>{item.title}</strong>
              <span class={`badge ${enabled ? "ok" : "off"}`}>
                {enabled ? "enabled" : "disabled"}
              </span>
            </div>
            <div class="muted feature-desc">{item.desc}</div>
            <ActionButton
              class={enabled ? "small" : "small primary"}
              busyKey={busyKey("toggle-feature", item.key)}
              aria-pressed={enabled ? "true" : "false"}
              aria-label={`${verb} ${item.title}`}
              onClick={() => toggleFeature(item.key, !enabled)}
            >
              {verb}
            </ActionButton>
          </div>
        );
      })}
    </div>
  );
}

function deleteVoice(id: string): void {
  confirmDelete(
    "Delete voice message?",
    `Object ${id} is removed from storage. Clients showing it will no longer be able to play it.`,
    "Delete",
    () => void runAction("delete-voice", [id], { after: refreshAll }),
  );
}

function deleteFile(id: string): void {
  confirmDelete(
    "Delete shared file?",
    `Object ${id} is removed from storage. Links to it stop working.`,
    "Delete",
    () => void runAction("delete-file", [id], { after: refreshAll }),
  );
}

function totalSize(objs: Array<{ size: number }>): number {
  return objs.reduce((s, o) => s + (o.size || 0), 0);
}

function VoiceSection() {
  const voice = media.value?.voice;
  const objs = voice?.objects ?? [];
  const heading = voice?.enabled
    ? `Voice Messages — ${
      voice.bucket || "ircd-voice"
    } (${objs.length} objects, ${fmtBytes(totalSize(objs))}, max ${
      fmtBytes(voice.max_bytes ?? 0)
    } / ${voice.max_duration ?? 120}s)`
    : media.value
    ? "Voice Messages (disabled)"
    : "Voice Messages (OPUS)";
  const q = filterOf("voice");
  const rows: Row[] = objs.filter((o) =>
    matchesFilter(q, o.id, o.last_modified)
  )
    .map((o) => ({
      key: o.id,
      cells: [
        mono(o.id),
        fmtBytes(o.size),
        mono(o.last_modified || "-"),
        <audio
          key="cell"
          controls
          preload="none"
          src={`/api/voice/${o.id}`}
          class="admin-audio"
        />,
        <ActionButton
          key="cell"
          class="small danger"
          busyKey={busyKey("delete-voice", o.id)}
          onClick={() => deleteVoice(o.id)}
        >
          Delete
        </ActionButton>,
      ],
    }));
  return (
    <div class="media-section">
      <div class="page-head">
        <h3 id="voice-heading">{heading}</h3>
        <FilterInput tableKey="voice" placeholder="Filter voice IDs..." />
      </div>
      <div id="voice-wrap">
        {media.value && (
          <Table
            tableKey="voice"
            headers={["Object ID", "Size", "Uploaded", "Preview", "Action"]}
            rows={rows}
            emptyText={voice?.error
              ? `Storage error: ${voice.error}`
              : "No voice messages."}
          />
        )}
      </div>
    </div>
  );
}

function FilesSection() {
  const files = media.value?.files;
  const objs = files?.objects ?? [];
  const heading = files?.enabled
    ? `Shared Files — ${
      files.bucket || "ircd-files"
    } (${objs.length} objects, ${fmtBytes(totalSize(objs))}, max ${
      fmtBytes(files.max_bytes ?? 0)
    })`
    : media.value
    ? "Shared Files (disabled)"
    : "Shared Files";
  const q = filterOf("files");
  const rows: Row[] = objs.filter((o) =>
    matchesFilter(q, o.id, o.last_modified)
  )
    .map((o) => ({
      key: o.id,
      cells: [
        mono(o.id),
        o.preview ? "image" : "file",
        fmtBytes(o.size),
        mono(o.last_modified || "-"),
        <div key="cell" class="action-row">
          <a
            class="btn-link"
            href={`/api/files/${o.id}`}
            target="_blank"
            rel="noopener noreferrer"
          >
            Open ↗
          </a>
          <ActionButton
            class="small danger"
            busyKey={busyKey("delete-file", o.id)}
            onClick={() => deleteFile(o.id)}
          >
            Delete
          </ActionButton>
        </div>,
      ],
    }));
  return (
    <div class="media-section">
      <div class="page-head">
        <h3 id="files-heading">{heading}</h3>
        <FilterInput tableKey="files" placeholder="Filter file IDs..." />
      </div>
      <div id="files-wrap">
        {media.value && (
          <Table
            tableKey="files"
            headers={["Object ID", "Type", "Size", "Uploaded", "Actions"]}
            rows={rows}
            emptyText={files?.error
              ? `Storage error: ${files.error}`
              : "No shared files."}
          />
        )}
      </div>
    </div>
  );
}

export function MediaTab() {
  const resetKey = busyKey("clear-upload-limits");
  return (
    <>
      <div class="page-head">
        <h2>Chat Features (Live Toggles)</h2>
        <div class="ops-row">
          <ActionButton
            busyKey={MEDIA_REFRESH_KEY}
            id="btn-refresh-media"
            onClick={() => void refreshMedia()}
          >
            Refresh Storage
          </ActionButton>
          <ActionButton
            busyKey={resetKey}
            id="btn-clear-upload-limits"
            onClick={() =>
              void runAction("clear-upload-limits", [], { key: resetKey })}
          >
            Reset Upload Limits
          </ActionButton>
        </div>
      </div>
      <p class="muted">
        Enable or disable messenger features server-wide without restarting.
        Changes take effect immediately for new connections and redaction
        checks.
      </p>
      <FeatureGrid />
      <VoiceSection />
      <FilesSection />
    </>
  );
}
