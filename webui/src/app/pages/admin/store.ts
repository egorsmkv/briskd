// Admin panel state: the last overview and media payloads, in-flight action
// keys, toasts, the open dialog, and table filters and pages. Module-level
// signals, so the state survives leaving and re-entering the admin page.
import { batch, signal } from "@preact/signals";
import { errorMessage } from "../../../common/dom.ts";
import {
  actionTitle,
  humanizeError,
  successMessage,
} from "../../../common/admin_text.ts";
import {
  type ActionReply,
  type Control,
  type Features,
  fetchMediaText,
  fetchOverviewText,
  type MediaPayload,
  type OverviewPayload,
  postAction,
} from "./api.ts";

// ---------------------------------------------------------------------------
// Payloads

export const overview = signal<OverviewPayload | null>(null);
export const media = signal<MediaPayload | null>(null);
/** Feature toggles: the newest of the overview, media, or toggle replies. */
export const features = signal<Features | null>(null);
/** Server feature controls: the newest of the overview, media, or a change. */
export const controls = signal<Control[] | null>(null);
/** The last overview request failed. */
export const unreachable = signal(false);
/** Persistent banner text for connectivity problems; null hides it. */
export const connectionProblem = signal<string | null>(null);
/** Date.now() of the last successful overview load (0: never). */
export const lastUpdated = signal(0);
/** The server's log level, and the one selected in Operations. */
export const currentLogLevel = signal("");
export const logLevelChoice = signal("");

/** Id of the log level <select>, which keeps its choice while focused. */
export const LOG_LEVEL_SELECT_ID = "sel-log-level";

export function serverName(): string {
  return overview.value?.status?.name || "briskd";
}

// ---------------------------------------------------------------------------
// Toasts: successes fade out; errors stay until dismissed.

export type ToastKind = "ok" | "err";

export interface ToastItem {
  id: number;
  kind: ToastKind;
  text: string;
  leaving: boolean;
}

const MAX_TOASTS = 4;
/** How long a success toast stays, in milliseconds. */
export const TOAST_MS = 4000;
/** Length of the leaving transition, in milliseconds. */
const TOAST_LEAVE_MS = 180;
let toastSeq = 0;

export const toasts = signal<ToastItem[]>([]);

export function toast(kind: ToastKind, text: string): void {
  const kept = toasts.value.slice(-(MAX_TOASTS - 1));
  toasts.value = [...kept, { id: ++toastSeq, kind, text, leaving: false }];
}

export function dismissToast(id: number): void {
  toasts.value = toasts.value.map((t) =>
    t.id === id ? { ...t, leaving: true } : t
  );
  setTimeout(() => {
    toasts.value = toasts.value.filter((t) => t.id !== id);
  }, TOAST_LEAVE_MS);
}

// ---------------------------------------------------------------------------
// Busy keys. A key is the action plus its target, so a button re-rendered by
// a table refresh still shows its pending request, and repeated clicks on the
// same action for the same target are ignored until the first finishes.

export const busy = signal<ReadonlySet<string>>(new Set());

export function busyKey(action: string, target = ""): string {
  return `${action}:${target}`;
}

export function isBusy(key: string): boolean {
  return busy.value.has(key);
}

export function setBusy(key: string, on: boolean): void {
  const next = new Set(busy.value);
  if (on) next.add(key);
  else next.delete(key);
  busy.value = next;
}

// ---------------------------------------------------------------------------
// Dialog: prompt, confirmation, or typed confirmation for destructive actions.

export interface ModalOptions {
  title: string;
  message?: string;
  /** Label of the text field; omit for a plain confirmation. */
  label?: string;
  value?: string;
  placeholder?: string;
  inputType?: "text" | "password" | "email";
  confirmLabel?: string;
  danger?: boolean;
  allowEmpty?: boolean;
  /** When set, the user must type this text before confirming. */
  requireText?: string;
  onConfirm: (value: string) => void;
}

export interface ModalState extends ModalOptions {
  id: number;
  /** The element focused when the dialog opened; refocused on close. */
  opener: HTMLElement | null;
}

let modalSeq = 0;
export const modal = signal<ModalState | null>(null);

export function openModal(opts: ModalOptions): void {
  const active = document.activeElement;
  modal.value = {
    ...opts,
    id: ++modalSeq,
    opener: active instanceof HTMLElement ? active : null,
  };
}

export function closeModal(): void {
  const cur = modal.value;
  if (!cur) return;
  modal.value = null;
  if (cur.opener && cur.opener.isConnected) cur.opener.focus();
}

export function confirmDelete(
  title: string,
  message: string,
  confirmLabel: string,
  onConfirm: () => void,
): void {
  openModal({
    title,
    message,
    confirmLabel,
    danger: true,
    onConfirm: () => onConfirm(),
  });
}

// ---------------------------------------------------------------------------
// Tables: per-table filter text and page, shared rows-per-page.

const PAGE_SIZE_KEY = "briskd-admin-page-size";
export const PAGE_SIZES = [10, 25, 50, 100];

function savedPageSize(): number {
  try {
    const saved = parseInt(localStorage.getItem(PAGE_SIZE_KEY) || "", 10);
    if (PAGE_SIZES.includes(saved)) return saved;
  } catch {
    // Storage may be unavailable; use the default.
  }
  return 25;
}

/** Filter input text by table key, as typed. */
export const filters = signal<Record<string, string>>({});
export const pages = signal<Record<string, number>>({});
export const pageSize = signal(savedPageSize());

export function filterOf(key: string): string {
  return (filters.value[key] ?? "").trim();
}

export function setFilter(key: string, text: string): void {
  batch(() => {
    filters.value = { ...filters.value, [key]: text };
    pages.value = { ...pages.value, [key]: 1 };
  });
}

export function setPage(key: string, page: number): void {
  pages.value = { ...pages.value, [key]: page };
}

export function setPageSize(key: string, size: number): void {
  batch(() => {
    pageSize.value = size;
    pages.value = { ...pages.value, [key]: 1 };
  });
  try {
    localStorage.setItem(PAGE_SIZE_KEY, String(size));
  } catch {
    // Storage may be unavailable; the size applies to this visit.
  }
}

/** Clear a table's filter and focus its input (#filter-<key>). */
export function clearFilter(key: string): void {
  setFilter(key, "");
  document.getElementById(`filter-${key}`)?.focus();
}

// ---------------------------------------------------------------------------
// Auto-refresh preference.

const AUTO_REFRESH_KEY = "briskd-admin-auto-refresh";

function savedAutoRefresh(): boolean {
  try {
    return localStorage.getItem(AUTO_REFRESH_KEY) !== "off";
  } catch {
    return true;
  }
}

export const autoRefresh = signal(savedAutoRefresh());

export function setAutoRefresh(on: boolean): void {
  autoRefresh.value = on;
  try {
    localStorage.setItem(AUTO_REFRESH_KEY, on ? "on" : "off");
  } catch {
    // Storage may be unavailable; the choice applies to this visit.
  }
  if (on) void refresh();
}

// ---------------------------------------------------------------------------
// Loading. Unchanged payloads are not re-rendered, so hover, focus, open
// selects, and playing audio survive the periodic refresh.

let lastOverviewText = "";
let lastMediaText = "";
let refreshing: Promise<void> | null = null;

function applyOverview(data: OverviewPayload): void {
  batch(() => {
    overview.value = data;
    const level = data.status?.log_level;
    if (level) {
      const changed = currentLogLevel.value !== level;
      currentLogLevel.value = level;
      // Follow the server unless the operator is choosing a new level.
      const sel = document.getElementById(LOG_LEVEL_SELECT_ID);
      if (changed && document.activeElement !== sel) {
        logLevelChoice.value = level;
      }
    }
    if (data.features) features.value = data.features;
    if (data.controls) controls.value = data.controls;
  });
}

/**
 * Fetch the overview. `force` re-renders even when unchanged (after an
 * action). Concurrent calls share one request.
 */
export function refresh(force = false): Promise<void> {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    try {
      const text = await fetchOverviewText();
      batch(() => {
        lastUpdated.value = Date.now();
        connectionProblem.value = null;
        unreachable.value = false;
      });
      if (force || text !== lastOverviewText || !overview.value) {
        lastOverviewText = text;
        applyOverview(JSON.parse(text) as OverviewPayload);
      }
    } catch (e) {
      batch(() => {
        unreachable.value = true;
        connectionProblem.value = `Cannot reach the server (${
          errorMessage(e)
        }). Retrying…`;
      });
    } finally {
      refreshing = null;
    }
  })();
  return refreshing;
}

/** Busy key of the "Refresh Storage" button. */
export const MEDIA_REFRESH_KEY = "ui:refresh-media";

/** Fetch the media listing (re-rendered only when changed). */
export async function refreshMedia(): Promise<void> {
  setBusy(MEDIA_REFRESH_KEY, true);
  try {
    const text = await fetchMediaText();
    if (text !== lastMediaText || !media.value) {
      lastMediaText = text;
      const data = JSON.parse(text) as MediaPayload;
      batch(() => {
        media.value = data;
        if (data.features) features.value = data.features;
        if (data.controls) controls.value = data.controls;
      });
    }
  } catch (e) {
    toast("err", `Failed to load media storage: ${errorMessage(e)}`);
  } finally {
    setBusy(MEDIA_REFRESH_KEY, false);
  }
}

/** Reload both the overview and the media listing. */
export async function refreshAll(): Promise<void> {
  await Promise.all([refresh(true), refreshMedia()]);
}

// ---------------------------------------------------------------------------
// Actions

export interface RunOptions {
  /** Busy key; defaults to the action and its first argument. */
  key?: string;
  /** Called after success, before the button stops spinning. */
  after?: (data: ActionReply) => Promise<void> | void;
}

/**
 * POST an action, toast its outcome, and refresh (or run `after`). Returns
 * the reply on success, null on failure or when the same key is in flight.
 */
export async function runAction(
  action: string,
  args: string[] = [],
  opts: RunOptions = {},
): Promise<ActionReply | null> {
  const key = opts.key ?? busyKey(action, args[0]);
  if (isBusy(key)) return null;
  setBusy(key, true);
  try {
    const { ok, status, data } = await postAction(action, args);
    if (!ok) {
      toast(
        "err",
        `${actionTitle(action)} failed: ${humanizeError(data, status)}`,
      );
      return null;
    }
    toast("ok", successMessage(action, args, data));
    // Keep the spinner until the tables reflect the change.
    await (opts.after ? opts.after(data) : refresh(true));
    return data;
  } catch (err) {
    toast("err", `${actionTitle(action)} failed: ${errorMessage(err)}`);
    return null;
  } finally {
    setBusy(key, false);
  }
}
