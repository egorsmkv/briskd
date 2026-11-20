// Features & Media: server feature controls, voice messages, and shared files
// (from GET /api/media), with upload limit reset.
import { fmtBytes, matchesFilter } from "./format.ts";
import {
  busyKey,
  confirmDelete,
  filterOf,
  media,
  MEDIA_REFRESH_KEY,
  refreshAll,
  refreshMedia,
  runAction,
} from "./store.ts";
import { FeatureControls } from "./FeatureControls.tsx";
import { ActionButton, FilterInput, mono, type Row, Table } from "./Table.tsx";

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
        <h2>Server Features</h2>
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
      <FeatureControls />
      <VoiceSection />
      <FilesSection />
    </>
  );
}
