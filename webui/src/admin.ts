import {
  byId as $,
  errorMessage,
  postJson,
  showNotice as showNoticeById,
} from "./common/dom.ts";
import { initTheme } from "./common/theme.ts";
import {
  actionTitle,
  formatAgo,
  humanizeError,
  successMessage,
} from "./common/admin_text.ts";

interface ListenerInfo {
  transport: string;
  port: number;
}

interface StatusData {
  status?: string;
  name?: string;
  network?: string;
  uptime_seconds?: number;
  listeners?: ListenerInfo[];
  sessions?: number;
  max_clients?: number;
  registered_users?: number;
  operators_online?: number;
  channels?: number;
  remote_channels?: number;
  known_servers?: number;
  remote_users?: number;
  services?: number;
  accounts?: number;
  retention?: string;
  db_disk_bytes?: number;
  db_memory_bytes?: number;
  db_tables?: number;
  memory_bytes?: number;
  erlang_processes?: number;
  log_level?: string;
}

interface ClientEntry {
  nick?: string;
  user?: string;
  host?: string;
  account?: string | null;
  operator?: boolean;
  secure?: boolean;
  channels?: number | string[];
  idle_seconds?: number;
}

interface ChannelEntry {
  name: string;
  local_members?: number;
  remote_members?: number;
  modes?: string;
  predefined?: boolean;
  topic?: string;
}

interface ConnectedLink {
  name?: string;
  server?: string;
  hop?: number;
  info?: string;
}

interface ConfiguredLink {
  name: string;
  host: string;
  port: number;
  tls?: boolean;
}

interface AccountEntry {
  name: string;
  verified?: boolean;
  email?: string | null;
  certfps?: number;
}

interface DroneblBan {
  ip: string;
  code: number;
  expires_in?: number;
  reason?: string;
}

interface MediaObject {
  id: string;
  size: number;
  last_modified?: string;
  preview?: boolean;
}

interface MediaPayload {
  features?: Record<string, boolean>;
  voice?: {
    enabled: boolean;
    bucket?: string;
    max_bytes?: number;
    max_duration?: number;
    objects?: MediaObject[];
    error?: string;
  };
  files?: {
    enabled: boolean;
    bucket?: string;
    max_bytes?: number;
    objects?: MediaObject[];
    error?: string;
  };
}

interface OverviewPayload {
  status?: StatusData;
  clients?: { clients?: ClientEntry[] };
  channels?: { channels?: ChannelEntry[] };
  links?: { connected?: ConnectedLink[]; configured?: ConfiguredLink[] };
  accounts?: { accounts?: AccountEntry[] };
  dronebl?: {
    stats?: {
      enabled?: boolean;
      bans?: number;
      cached_clean?: number;
      in_flight?: number;
    };
    bans?: DroneblBan[];
  };
  features?: Record<string, boolean>;
  media_summary?: {
    voice_enabled?: boolean;
    voice_max_bytes?: number;
    voice_max_duration?: number;
    files_enabled?: boolean;
    files_max_bytes?: number;
  };
}

type CellValue =
  | Node
  | { text: string; cls?: string }
  | string
  | number
  | null
  | undefined;

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  text?: string | number | null,
  cls?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (text !== undefined && text !== null) node.textContent = String(text);
  if (cls) node.className = cls;
  return node;
}

function fmtUptime(s: number): string {
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return (d ? `${d}d ` : "") + `${h}h ${m}m ${sec}s`;
}

function fmtBytes(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GiB`;
  }
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${bytes} B`;
}

// ---------------------------------------------------------------------------
// Toasts: action results appear near the pointer's reach regardless of how far
// the page is scrolled. Successes fade out; errors stay until dismissed.

type ToastKind = "ok" | "err";
const MAX_TOASTS = 4;
const TOAST_MS = 4000;

function toast(kind: ToastKind, text: string): void {
  const box = $("toasts");
  while (box.childElementCount >= MAX_TOASTS) box.firstElementChild?.remove();
  const item = el("div", undefined, `toast ${kind}`);
  item.setAttribute("role", kind === "err" ? "alert" : "status");
  const icon = el("span", kind === "ok" ? "✓" : "!", "toast-icon");
  icon.setAttribute("aria-hidden", "true");
  const close = el("button", "×", "toast-close");
  close.type = "button";
  close.setAttribute("aria-label", "Dismiss");
  let timer: number | undefined;
  const dismiss = () => {
    clearTimeout(timer);
    item.classList.add("leaving");
    setTimeout(() => item.remove(), 180);
  };
  close.onclick = dismiss;
  item.append(icon, el("span", text, "toast-text"), close);
  box.appendChild(item);
  if (kind === "ok") {
    timer = setTimeout(dismiss, TOAST_MS);
    item.onmouseenter = () => clearTimeout(timer);
    item.onmouseleave = () => {
      timer = setTimeout(dismiss, TOAST_MS / 2);
    };
  }
}

/** Persistent banner for connectivity problems; null hides it. */
function setConnectionProblem(text: string | null): void {
  if (text) showNoticeById("notice", false, text);
  else {
    const node = $("notice");
    node.className = "";
    node.textContent = "";
  }
}

// ---------------------------------------------------------------------------
// Actions. A busy key is the action plus its target, so a button re-created by
// a table re-render still shows its pending request, and repeated clicks on
// the same action for the same target are ignored until the first finishes.

const inFlight = new Set<string>();

function busyKey(action: string, target = ""): string {
  return `${action}:${target}`;
}

function setBusy(btn: HTMLButtonElement, busy: boolean): void {
  btn.disabled = busy;
  btn.classList.toggle("busy", busy);
  if (busy) btn.setAttribute("aria-busy", "true");
  else btn.removeAttribute("aria-busy");
}

function syncBusy(key: string): void {
  document.querySelectorAll<HTMLButtonElement>("button[data-busy-key]")
    .forEach((b) => {
      if (b.dataset.busyKey === key) setBusy(b, inFlight.has(key));
    });
}

interface RunOptions {
  /** Busy key; defaults to the action and its first argument. */
  key?: string;
  /** Called after success, before the button stops spinning. */
  after?: (data: Record<string, unknown>) => Promise<void> | void;
}

async function runAction(
  action: string,
  args: string[] = [],
  opts: RunOptions = {},
): Promise<Record<string, unknown> | null> {
  const key = opts.key ?? busyKey(action, args[0]);
  if (inFlight.has(key)) return null;
  inFlight.add(key);
  syncBusy(key);
  try {
    const { ok, status, data } = await postJson<Record<string, unknown>>(
      "/api/action",
      { action, args },
    );
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
    inFlight.delete(key);
    syncBusy(key);
    updateLogLevelButton();
  }
}

/** A button bound to a busy key; `fk` keeps keyboard focus across re-renders. */
function actionButton(
  label: string,
  cls: string,
  key: string,
  onClick: () => void,
): HTMLButtonElement {
  const btn = el("button", label, cls);
  btn.type = "button";
  btn.dataset.busyKey = key;
  btn.dataset.fk = `btn:${key}`;
  if (inFlight.has(key)) setBusy(btn, true);
  btn.onclick = onClick;
  return btn;
}

// ---------------------------------------------------------------------------
// Modal: prompt, confirmation, or typed confirmation for destructive actions.

interface AdminModalOptions {
  title: string;
  message?: string;
  /** Label of the text field; omit for a plain confirmation. */
  label?: string;
  value?: string;
  placeholder?: string;
  inputType?: "text" | "password";
  confirmLabel?: string;
  danger?: boolean;
  allowEmpty?: boolean;
  /** When set, the user must type this text before confirming. */
  requireText?: string;
  onConfirm: (value: string) => void;
}

let modalConfirm: ((value: string) => void) | null = null;
let modalAllowEmpty = false;
let modalHasInput = false;
let modalRequireText = "";
let modalOpener: HTMLElement | null = null;

function isModalOpen(): boolean {
  return $("admin-modal").classList.contains("open");
}

function modalValid(): boolean {
  if (modalRequireText) {
    const typed = $<HTMLInputElement>("admin-modal-confirm-input").value.trim();
    if (typed !== modalRequireText) return false;
  }
  if (modalHasInput && !modalAllowEmpty) {
    const inp = $<HTMLInputElement>("admin-modal-input");
    const val = inp.type === "password" ? inp.value : inp.value.trim();
    if (!val) return false;
  }
  return true;
}

function updateModalSubmit(): void {
  $<HTMLButtonElement>("admin-modal-submit").disabled = !modalValid();
}

function openAdminModal(opts: AdminModalOptions): void {
  modalOpener = document.activeElement instanceof HTMLElement
    ? document.activeElement
    : null;
  $("admin-modal-title").textContent = opts.title;
  const msg = $("admin-modal-message");
  msg.textContent = opts.message ?? "";
  msg.hidden = !opts.message;

  modalHasInput = opts.label !== undefined;
  $("admin-modal-field").hidden = !modalHasInput;
  $("admin-modal-label").textContent = opts.label ?? "";
  const inp = $<HTMLInputElement>("admin-modal-input");
  inp.type = opts.inputType || "text";
  inp.value = opts.value ?? "";
  inp.placeholder = opts.placeholder ?? "";
  inp.autocomplete = opts.inputType === "password" ? "new-password" : "off";

  modalRequireText = opts.requireText ?? "";
  $("admin-modal-confirm-field").hidden = !modalRequireText;
  $("admin-modal-confirm-label").textContent = modalRequireText
    ? `Type ${modalRequireText} to confirm`
    : "";
  const confirmInp = $<HTMLInputElement>("admin-modal-confirm-input");
  confirmInp.value = "";
  confirmInp.placeholder = modalRequireText;

  const sub = $<HTMLButtonElement>("admin-modal-submit");
  sub.textContent = opts.confirmLabel || "Confirm";
  sub.className = opts.danger ? "danger" : "primary";
  modalConfirm = opts.onConfirm;
  modalAllowEmpty = opts.allowEmpty === true;
  updateModalSubmit();
  $("admin-modal").classList.add("open");
  document.body.classList.add("modal-open");

  const first = modalHasInput
    ? inp
    : modalRequireText
    ? confirmInp
    : $<HTMLButtonElement>("btn-cancel-modal");
  first.focus();
  if (first === inp && inp.value) inp.select();
}

function closeAdminModal(): void {
  if (!isModalOpen()) return;
  $("admin-modal").classList.remove("open");
  document.body.classList.remove("modal-open");
  modalConfirm = null;
  $<HTMLInputElement>("admin-modal-input").value = "";
  $<HTMLInputElement>("admin-modal-confirm-input").value = "";
  if (modalOpener && modalOpener.isConnected) modalOpener.focus();
  modalOpener = null;
}

function confirmDelete(
  title: string,
  message: string,
  confirmLabel: string,
  onConfirm: () => void,
): void {
  openAdminModal({
    title,
    message,
    confirmLabel,
    danger: true,
    onConfirm: () => onConfirm(),
  });
}

$("btn-close-modal").onclick = closeAdminModal;
$("btn-cancel-modal").onclick = closeAdminModal;
// Close on a backdrop click only when the press also started on the backdrop,
// so selecting text in the input and releasing outside does not dismiss it.
let backdropPress = false;
$("admin-modal").addEventListener("mousedown", (ev) => {
  backdropPress = ev.target === $("admin-modal");
});
$("admin-modal").addEventListener("click", (ev) => {
  if (backdropPress && ev.target === $("admin-modal")) closeAdminModal();
  backdropPress = false;
});
$("admin-modal").addEventListener("keydown", (ev) => {
  if (ev.key !== "Tab") return;
  const focusables = Array.from(
    $("admin-modal").querySelectorAll<HTMLElement>(
      "button:not(:disabled), input:not([hidden])",
    ),
  ).filter((n) => n.offsetParent !== null);
  if (focusables.length === 0) return;
  const first = focusables[0];
  const last = focusables[focusables.length - 1];
  if (ev.shiftKey && document.activeElement === first) {
    ev.preventDefault();
    last.focus();
  } else if (!ev.shiftKey && document.activeElement === last) {
    ev.preventDefault();
    first.focus();
  }
});
document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape" && isModalOpen()) {
    ev.preventDefault();
    closeAdminModal();
  }
});
$("admin-modal-input").addEventListener("input", updateModalSubmit);
$("admin-modal-confirm-input").addEventListener("input", updateModalSubmit);
$<HTMLFormElement>("admin-modal-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  if (!modalConfirm || !modalValid()) return;
  const inp = $<HTMLInputElement>("admin-modal-input");
  const val = inp.type === "password" ? inp.value : inp.value.trim();
  const fn = modalConfirm;
  closeAdminModal();
  fn(val);
});

// ---------------------------------------------------------------------------
// Tables

const PAGE_SIZE_KEY = "ircd-admin-page-size";
const PAGE_SIZES = [10, 25, 50, 100];
const MEDIA_TABLES = new Set(["voice", "files"]);
const tablePages: Record<string, number> = {};
const tableFilters: Record<string, string> = {};
let lastOverview: OverviewPayload | null = null;
let lastMedia: MediaPayload | null = null;

function rerenderTable(key: string): void {
  if (MEDIA_TABLES.has(key)) {
    if (lastMedia) renderMedia(lastMedia);
  } else if (lastOverview) {
    render(lastOverview);
  }
}

function clearFilter(key: string): void {
  const inp = $<HTMLInputElement>(`filter-${key}`);
  inp.value = "";
  tableFilters[key] = "";
  tablePages[key] = 1;
  rerenderTable(key);
  inp.focus();
}

function matchesFilter(
  key: string,
  ...fields: Array<string | undefined | null>
): boolean {
  const q = (tableFilters[key] || "").toLowerCase();
  if (!q) return true;
  return fields.some((f) => (f || "").toLowerCase().includes(q));
}

function isIpAddress(host?: string): boolean {
  if (!host) return false;
  return /^(\d{1,3}\.){3}\d{1,3}$/.test(host) ||
    /^[0-9a-fA-F:]+$/.test(host) && host.includes(":");
}
let pageSize = (() => {
  try {
    const saved = parseInt(localStorage.getItem(PAGE_SIZE_KEY) || "", 10);
    if (PAGE_SIZES.includes(saved)) return saved;
  } catch {
    // ignore
  }
  return 25;
})();

function emptyState(key: string, emptyText: string): HTMLElement {
  const q = tableFilters[key];
  const box = el("div", undefined, "empty");
  if (!q) {
    box.textContent = emptyText;
    return box;
  }
  box.appendChild(el("span", `No matches for “${q}”.`));
  const clear = el("button", "Clear filter", "small");
  clear.type = "button";
  clear.dataset.fk = `clear:${key}`;
  clear.onclick = () => clearFilter(key);
  box.appendChild(clear);
  return box;
}

function makeTable(
  key: string,
  headers: string[],
  rows: CellValue[][],
  emptyText = "Nothing here yet.",
): HTMLElement {
  if (!rows.length) return emptyState(key, emptyText);

  const total = rows.length;
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const page = Math.min(Math.max(tablePages[key] ?? 1, 1), totalPages);
  tablePages[key] = page;
  const start = (page - 1) * pageSize;
  const end = Math.min(start + pageSize, total);
  const slice = rows.slice(start, end);

  const container = el("div", undefined, "table-wrap");
  const table = document.createElement("table");
  const thead = document.createElement("thead");
  const tr = document.createElement("tr");
  for (const h of headers) {
    const th = el("th", h);
    th.scope = "col";
    tr.appendChild(th);
  }
  thead.appendChild(tr);
  table.appendChild(thead);

  const tbody = document.createElement("tbody");
  for (const cells of slice) {
    const r = document.createElement("tr");
    for (const cell of cells) {
      const td = document.createElement("td");
      if (cell instanceof Node) {
        td.appendChild(cell);
      } else if (cell && typeof cell === "object" && "text" in cell) {
        td.textContent = String(cell.text);
        if (cell.cls) td.className = cell.cls;
      } else {
        td.textContent = cell === undefined || cell === null
          ? ""
          : String(cell);
      }
      r.appendChild(td);
    }
    tbody.appendChild(r);
  }
  table.appendChild(tbody);
  container.appendChild(table);

  const pager = el("div", undefined, "pager");
  pager.appendChild(
    el("span", `Showing ${start + 1}–${end} of ${total}`, "muted"),
  );

  const controls = el("div", undefined, "pager-controls");
  const sizeLabel = el("label", "Rows:", "muted pager-size");
  const sizeSel = document.createElement("select");
  sizeSel.setAttribute("aria-label", "Rows per page");
  sizeSel.dataset.fk = `pager:${key}:size`;
  for (const sz of PAGE_SIZES) {
    const opt = document.createElement("option");
    opt.value = String(sz);
    opt.textContent = String(sz);
    if (sz === pageSize) opt.selected = true;
    sizeSel.appendChild(opt);
  }
  sizeSel.onchange = () => {
    pageSize = parseInt(sizeSel.value, 10) || 25;
    try {
      localStorage.setItem(PAGE_SIZE_KEY, String(pageSize));
    } catch {
      // ignore
    }
    tablePages[key] = 1;
    rerenderTable(key);
  };
  sizeLabel.appendChild(sizeSel);
  controls.appendChild(sizeLabel);

  const prevBtn = el("button", "‹ Prev", "small");
  prevBtn.type = "button";
  prevBtn.disabled = page <= 1;
  prevBtn.dataset.fk = `pager:${key}:prev`;
  prevBtn.setAttribute("aria-label", "Previous page");
  prevBtn.onclick = () => {
    tablePages[key] = page - 1;
    rerenderTable(key);
  };
  controls.appendChild(prevBtn);

  controls.appendChild(
    el("span", `Page ${page} / ${totalPages}`, "pager-info"),
  );

  const nextBtn = el("button", "Next ›", "small");
  nextBtn.type = "button";
  nextBtn.disabled = page >= totalPages;
  nextBtn.dataset.fk = `pager:${key}:next`;
  nextBtn.setAttribute("aria-label", "Next page");
  nextBtn.onclick = () => {
    tablePages[key] = page + 1;
    rerenderTable(key);
  };
  controls.appendChild(nextBtn);

  pager.appendChild(controls);
  container.appendChild(pager);
  return container;
}

/**
 * Swap a section's content, then give keyboard focus back to the control that
 * had it (matched by `data-fk`), so a refresh does not throw the user out.
 */
function replace(id: string, ...nodes: Node[]): void {
  const wrap = $(id);
  const active = document.activeElement;
  const fk = active instanceof HTMLElement && wrap.contains(active)
    ? active.dataset.fk
    : undefined;
  wrap.replaceChildren(...nodes);
  if (!fk) return;
  const next = Array.from(wrap.querySelectorAll<HTMLElement>("[data-fk]"))
    .find((n) => n.dataset.fk === fk);
  if (next && !(next instanceof HTMLButtonElement && next.disabled)) {
    next.focus();
  }
}

// ---------------------------------------------------------------------------
// Rendering

let currentLogLevel = "";

function updateLogLevelButton(): void {
  const sel = $<HTMLSelectElement>("sel-log-level");
  const btn = $<HTMLButtonElement>("btn-log-level");
  if (!btn.classList.contains("busy")) {
    btn.disabled = !sel.value || sel.value === currentLogLevel;
  }
}

function serverName(): string {
  return lastOverview?.status?.name || "ircd";
}

function render(data: OverviewPayload): void {
  lastOverview = data;
  const st = data.status ?? {};
  $("srv-name").textContent = st.name || "ircd";
  const badge = $("srv-status");
  badge.textContent = st.status || "unknown";
  badge.className = st.status === "running" ? "badge" : "badge off";
  $("srv-meta").textContent =
    `network ${st.network || "-"} | up ${
      fmtUptime(st.uptime_seconds || 0)
    } | listeners: ` +
    (st.listeners || []).map((l) => `${l.transport}:${l.port}`).join(", ");

  $("st-sessions").textContent = `${st.sessions ?? 0} / ${st.max_clients ?? 0}`;
  $("st-sessions-sub").textContent = `registered: ${
    st.registered_users ?? 0
  }, operators: ${st.operators_online ?? 0}`;
  $("st-channels").textContent = String(st.channels ?? 0);
  $("st-channels-sub").textContent = `remote: ${st.remote_channels ?? 0}`;
  $("st-network").textContent = `${st.known_servers ?? 0} peers`;
  $("st-network-sub").textContent = `remote users: ${
    st.remote_users ?? 0
  }, services: ${st.services ?? 0}`;
  $("st-accounts").textContent = String(st.accounts ?? 0);
  $("st-retention").textContent = `retention: ${st.retention || "-"}`;

  const dbl = data.dronebl ?? {};
  const dblStats = dbl.stats ?? {};
  $("st-dronebl").textContent = dblStats.enabled
    ? `${dblStats.bans ?? 0} bans`
    : "disabled";
  $("st-dronebl-sub").textContent = dblStats.enabled
    ? `clean cache: ${dblStats.cached_clean ?? 0}, in-flight: ${
      dblStats.in_flight ?? 0
    }`
    : "enable in config";

  $("st-db").textContent = fmtBytes(st.db_disk_bytes || 0);
  $("st-db-sub").textContent = `RAM: ${fmtBytes(st.db_memory_bytes || 0)} | ${
    st.db_tables ?? 0
  } tables`;

  $("st-memory").textContent = fmtBytes(st.memory_bytes || 0);
  $("st-procs").textContent = `${st.erlang_processes ?? 0} processes`;

  const selLvl = $<HTMLSelectElement>("sel-log-level");
  if (st.log_level) {
    const changed = currentLogLevel !== st.log_level;
    currentLogLevel = st.log_level;
    // Follow the server unless the operator is choosing a new level.
    if (changed && document.activeElement !== selLvl) {
      selLvl.value = st.log_level;
    }
  }
  updateLogLevelButton();

  const clients = data.clients?.clients ?? [];
  $("cnt-clients").textContent = String(clients.length);
  const filteredClients = clients.filter((c) =>
    matchesFilter("clients", c.nick, c.user, c.host, c.account)
  );
  replace(
    "clients-wrap",
    makeTable(
      "clients",
      [
        "Nick",
        "User@Host",
        "Account",
        "Oper",
        "TLS",
        "Channels",
        "Idle",
        "Action",
      ],
      filteredClients.map((c) => {
        const actions = el("span", undefined, "action-row");
        const nick = c.nick;
        if (nick) {
          actions.appendChild(
            actionButton(
              "Kick",
              "danger small",
              busyKey("kick-client", nick),
              () =>
                openAdminModal({
                  title: `Kick ${nick}`,
                  message:
                    "The client is disconnected immediately and may reconnect.",
                  label: "Kick reason",
                  value: "Disconnected by administrator",
                  confirmLabel: "Kick Client",
                  danger: true,
                  allowEmpty: true,
                  onConfirm: (reason) =>
                    void runAction("kick-client", [nick, reason]),
                }),
            ),
          );
        }
        const host = c.host;
        if (host && isIpAddress(host)) {
          actions.appendChild(
            actionButton(
              "Ban IP",
              "small",
              busyKey("dronebl-ban", host),
              () =>
                openAdminModal({
                  title: `Ban IP ${host}`,
                  message: "New connections from this address are refused.",
                  label: "Ban reason",
                  value: "Manual administrator ban",
                  confirmLabel: "Ban IP",
                  danger: true,
                  allowEmpty: true,
                  onConfirm: (reason) =>
                    void runAction(
                      "dronebl-ban",
                      reason ? [host, reason] : [host],
                    ),
                }),
            ),
          );
        }
        const chDisplay = Array.isArray(c.channels)
          ? c.channels.join(", ")
          : String(c.channels ?? 0);
        return [
          { text: c.nick || "*", cls: "mono" },
          { text: `${c.user || "-"}@${c.host || "-"}`, cls: "mono" },
          c.account || "-",
          c.operator ? "yes" : "no",
          c.secure ? "yes" : "no",
          chDisplay,
          `${c.idle_seconds ?? 0}s`,
          actions.childNodes.length ? actions : "",
        ];
      }),
      "No clients connected.",
    ),
  );

  const channels = data.channels?.channels ?? [];
  $("cnt-channels").textContent = String(channels.length);
  const filteredChannels = channels.filter((ch) =>
    matchesFilter("channels", ch.name, ch.topic, ch.modes)
  );
  replace(
    "channels-wrap",
    makeTable(
      "channels",
      ["Channel", "Local", "Remote", "Modes", "Predefined", "Topic", "Action"],
      filteredChannels.map((ch) => {
        const actions = el("span", undefined, "action-row");
        actions.appendChild(
          actionButton(
            "Set Topic",
            "small",
            busyKey("set-topic", ch.name),
            () =>
              openAdminModal({
                title: `Set Topic for ${ch.name}`,
                label: "Channel topic (leave blank to clear)",
                value: ch.topic || "",
                confirmLabel: "Save Topic",
                allowEmpty: true,
                onConfirm: (next) =>
                  void runAction("set-topic", [ch.name, next]),
              }),
          ),
        );
        actions.appendChild(
          actionButton(
            "Notice",
            "small",
            busyKey("notice-channel", ch.name),
            () =>
              openAdminModal({
                title: `Send Notice to ${ch.name}`,
                label: "Server NOTICE message",
                placeholder: "Message to all members in channel...",
                confirmLabel: "Send Notice",
                onConfirm: (msg) =>
                  void runAction("notice-channel", [ch.name, msg]),
              }),
          ),
        );
        return [
          { text: ch.name, cls: "mono" },
          ch.local_members ?? 0,
          ch.remote_members ?? 0,
          { text: ch.modes || "+", cls: "mono" },
          ch.predefined ? "yes" : "no",
          ch.topic || "",
          actions,
        ];
      }),
      "No active channels.",
    ),
  );

  const connected = data.links?.connected ?? [];
  const configured = data.links?.configured ?? [];
  $("cnt-links").textContent = String(connected.length);
  const linkRows: CellValue[][] = [];
  for (const l of connected) {
    const srvName = l.name || l.server || "";
    if (!matchesFilter("links", srvName, l.info, "connected")) continue;
    const btn = actionButton(
      "SQUIT",
      "danger small",
      busyKey("squit", srvName),
      () =>
        openAdminModal({
          title: `Disconnect Peer ${srvName}`,
          message:
            "Users and channels reachable only through this peer are removed.",
          label: "SQUIT reason",
          value: "Operator disconnect",
          confirmLabel: "SQUIT",
          danger: true,
          allowEmpty: true,
          onConfirm: (reason) => void runAction("squit", [srvName, reason]),
        }),
    );
    linkRows.push([
      { text: srvName, cls: "mono" },
      { text: `connected (hop ${l.hop ?? 1})`, cls: "state-ok" },
      l.info || "",
      btn,
    ]);
  }
  for (const cfg of configured) {
    const isUp = connected.some((l) => (l.name || l.server) === cfg.name);
    if (!isUp) {
      if (!matchesFilter("links", cfg.name, cfg.host, "configured")) continue;
      const btn = actionButton(
        "Connect",
        "primary small",
        busyKey("connect", cfg.name),
        () => void runAction("connect", [cfg.name]),
      );
      linkRows.push([
        { text: cfg.name, cls: "mono" },
        `configured (${cfg.host}:${cfg.port})`,
        cfg.tls ? "TLS" : "TCP",
        btn,
      ]);
    }
  }
  replace(
    "links-wrap",
    makeTable(
      "links",
      ["Server", "State", "Info", "Action"],
      linkRows,
      "No peers configured or connected.",
    ),
  );

  const accounts = data.accounts?.accounts ?? [];
  $("cnt-accounts").textContent = String(accounts.length);
  const filteredAccounts = accounts.filter((a) =>
    matchesFilter(
      "accounts",
      a.name,
      a.email,
      a.verified === false ? "pending" : "verified",
    )
  );
  replace(
    "accounts-wrap",
    makeTable(
      "accounts",
      ["Account", "Status", "Email", "CertFPs", "Action"],
      filteredAccounts.map((a) => {
        const wrap = el("span", undefined, "action-row");
        if (a.verified === false) {
          wrap.appendChild(
            actionButton(
              "Verify",
              "primary small",
              busyKey("verify-account", a.name),
              () => void runAction("verify-account", [a.name]),
            ),
          );
        } else {
          wrap.appendChild(
            actionButton(
              "Reset Pass",
              "small",
              busyKey("reset-password", a.name),
              () =>
                openAdminModal({
                  title: `Reset Password for ${a.name}`,
                  label: "New SASL password",
                  inputType: "password",
                  placeholder: "Enter new password...",
                  confirmLabel: "Update Password",
                  onConfirm: (pass) =>
                    void runAction("reset-password", [a.name, pass]),
                }),
            ),
          );
        }
        wrap.appendChild(
          actionButton(
            "Delete",
            "danger small",
            busyKey("delete-account", a.name),
            () =>
              confirmDelete(
                `Delete account ${a.name}?`,
                "The account, its credentials, and its certificate fingerprints are removed. This cannot be undone.",
                "Delete Account",
                () => void runAction("delete-account", [a.name]),
              ),
          ),
        );
        return [
          { text: a.name, cls: "mono" },
          a.verified === false
            ? { text: "pending", cls: "state-warn" }
            : { text: "verified", cls: "state-ok" },
          a.email || "-",
          a.certfps ?? 0,
          wrap,
        ];
      }),
      "No accounts yet.",
    ),
  );

  const bans = dbl.bans ?? [];
  $("cnt-dronebl").textContent = String(bans.length);
  const filteredBans = bans.filter((b) =>
    matchesFilter("dronebl", b.ip, b.reason, String(b.code))
  );
  replace(
    "dronebl-wrap",
    makeTable(
      "dronebl",
      ["IP", "Code", "Expires In", "Reason", "Action"],
      filteredBans.map((b) => [
        { text: b.ip, cls: "mono" },
        b.code,
        `${b.expires_in ?? 0}s`,
        b.reason || "",
        actionButton(
          "Unban",
          "small",
          busyKey("dronebl-unban", b.ip),
          () => void runAction("dronebl-unban", [b.ip]),
        ),
      ]),
      "No active bans.",
    ),
  );

  const feats = data.features ?? {};
  const totalFeats = Object.keys(feats).length || 6;
  const enabledCount = Object.values(feats).filter(Boolean).length;
  const ms = data.media_summary ?? {};
  $("st-media").textContent = `${enabledCount}/${totalFeats} features`;
  const parts: string[] = [];
  parts.push(
    ms.voice_enabled
      ? `voice ${fmtBytes(ms.voice_max_bytes ?? 0)}`
      : "voice off",
  );
  parts.push(
    ms.files_enabled
      ? `files ${fmtBytes(ms.files_max_bytes ?? 0)}`
      : "files off",
  );
  $("st-media-sub").textContent = parts.join(" / ");
  if (data.features) renderFeatures(data.features);
}

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

function renderFeatures(features: Record<string, boolean>): void {
  const cards: HTMLElement[] = [];
  for (const item of FEATURE_META) {
    const enabled = features[item.key] !== false;
    const card = el("div", null, `feature-card${enabled ? " on" : ""}`);
    const top = el("div", null, "feature-top");
    top.appendChild(el("strong", item.title));
    top.appendChild(
      el(
        "span",
        enabled ? "enabled" : "disabled",
        `badge ${enabled ? "ok" : "off"}`,
      ),
    );
    card.appendChild(top);
    card.appendChild(el("div", item.desc, "muted feature-desc"));
    const btn = actionButton(
      enabled ? "Disable" : "Enable",
      enabled ? "small" : "small primary",
      busyKey("toggle-feature", item.key),
      () =>
        void runAction(
          "toggle-feature",
          [item.key, enabled ? "false" : "true"],
          {
            after: async (data) => {
              const next = data.features;
              if (next && typeof next === "object") {
                renderFeatures(next as Record<string, boolean>);
              }
              await Promise.all([refresh(true), refreshMedia()]);
            },
          },
        ),
    );
    btn.setAttribute("aria-pressed", String(enabled));
    btn.setAttribute(
      "aria-label",
      `${enabled ? "Disable" : "Enable"} ${item.title}`,
    );
    card.appendChild(btn);
    cards.push(card);
  }
  replace("features-grid", ...cards);
}

function renderMedia(data: MediaPayload): void {
  lastMedia = data;
  if (data.features) renderFeatures(data.features);

  const voice = data.voice;
  const voiceObjs = voice?.objects ?? [];
  const voiceTotal = voiceObjs.reduce((s, o) => s + (o.size || 0), 0);
  $("voice-heading").textContent = voice?.enabled
    ? `Voice Messages — ${
      voice.bucket || "ircd-voice"
    } (${voiceObjs.length} objects, ${fmtBytes(voiceTotal)}, max ${
      fmtBytes(voice.max_bytes ?? 0)
    } / ${voice.max_duration ?? 120}s)`
    : "Voice Messages (disabled)";

  const afterMedia = async () => {
    await Promise.all([refresh(true), refreshMedia()]);
  };

  const filteredVoice = voiceObjs.filter((o) =>
    matchesFilter("voice", o.id, o.last_modified)
  );
  replace(
    "voice-wrap",
    makeTable(
      "voice",
      ["Object ID", "Size", "Uploaded", "Preview", "Action"],
      filteredVoice.map((o) => {
        const audio = document.createElement("audio");
        audio.controls = true;
        audio.preload = "none";
        audio.src = `/api/voice/${o.id}`;
        audio.className = "admin-audio";
        const delBtn = actionButton(
          "Delete",
          "small danger",
          busyKey("delete-voice", o.id),
          () =>
            confirmDelete(
              "Delete voice message?",
              `Object ${o.id} is removed from storage. Clients showing it will no longer be able to play it.`,
              "Delete",
              () =>
                void runAction("delete-voice", [o.id], { after: afterMedia }),
            ),
        );
        return [
          { text: o.id, cls: "mono" },
          fmtBytes(o.size),
          { text: o.last_modified || "-", cls: "mono" },
          audio,
          delBtn,
        ];
      }),
      voice?.error ? `Storage error: ${voice.error}` : "No voice messages.",
    ),
  );

  const files = data.files;
  const fileObjs = files?.objects ?? [];
  const filesTotal = fileObjs.reduce((s, o) => s + (o.size || 0), 0);
  $("files-heading").textContent = files?.enabled
    ? `Shared Files — ${
      files.bucket || "ircd-files"
    } (${fileObjs.length} objects, ${fmtBytes(filesTotal)}, max ${
      fmtBytes(files.max_bytes ?? 0)
    })`
    : "Shared Files (disabled)";

  const filteredFiles = fileObjs.filter((o) =>
    matchesFilter("files", o.id, o.last_modified)
  );
  replace(
    "files-wrap",
    makeTable(
      "files",
      ["Object ID", "Type", "Size", "Uploaded", "Actions"],
      filteredFiles.map((o) => {
        const wrap = el("div", null, "action-row");
        const openLink = el("a", "Open ↗", "btn-link");
        openLink.href = `/api/files/${o.id}`;
        openLink.target = "_blank";
        openLink.rel = "noopener noreferrer";
        const delBtn = actionButton(
          "Delete",
          "small danger",
          busyKey("delete-file", o.id),
          () =>
            confirmDelete(
              "Delete shared file?",
              `Object ${o.id} is removed from storage. Links to it stop working.`,
              "Delete",
              () =>
                void runAction("delete-file", [o.id], { after: afterMedia }),
            ),
        );
        wrap.appendChild(openLink);
        wrap.appendChild(delBtn);
        return [
          { text: o.id, cls: "mono" },
          o.preview ? "image" : "file",
          fmtBytes(o.size),
          { text: o.last_modified || "-", cls: "mono" },
          wrap,
        ];
      }),
      files?.error ? `Storage error: ${files.error}` : "No shared files.",
    ),
  );
}

// ---------------------------------------------------------------------------
// Loading. Unchanged payloads are not re-rendered, so hover, focus, open
// selects, and playing audio survive the periodic refresh.

let lastOverviewText = "";
let lastMediaText = "";
let lastUpdated = 0;
let refreshing: Promise<void> | null = null;

function updateStamp(): void {
  const stamp = $("last-updated");
  stamp.textContent = lastUpdated
    ? `Updated ${formatAgo(Date.now() - lastUpdated)}`
    : "";
}

async function refreshMedia(): Promise<void> {
  const btn = $<HTMLButtonElement>("btn-refresh-media");
  setBusy(btn, true);
  try {
    const res = await fetch("/api/media", { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const text = await res.text();
    if (text !== lastMediaText || !lastMedia) {
      lastMediaText = text;
      renderMedia(JSON.parse(text) as MediaPayload);
    }
  } catch (e) {
    toast("err", `Failed to load media storage: ${errorMessage(e)}`);
  } finally {
    setBusy(btn, false);
  }
}

/**
 * Fetch the overview. `force` re-renders even when unchanged (after an
 * action). Concurrent calls share one request.
 */
function refresh(force = false): Promise<void> {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    try {
      const res = await fetch("/api/overview", { cache: "no-store" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const text = await res.text();
      lastUpdated = Date.now();
      setConnectionProblem(null);
      if (force || text !== lastOverviewText || !lastOverview) {
        lastOverviewText = text;
        render(JSON.parse(text) as OverviewPayload);
      }
    } catch (e) {
      $("srv-status").textContent = "unreachable";
      $("srv-status").className = "badge off";
      setConnectionProblem(
        `Cannot reach the server (${errorMessage(e)}). Retrying…`,
      );
    } finally {
      refreshing = null;
      updateStamp();
    }
  })();
  return refreshing;
}

initTheme([$("btn-theme")]);

// ---------------------------------------------------------------------------
// Tabs: click, arrow keys, Home/End, and history navigation.

const VALID_TABS = new Set([
  "overview",
  "clients",
  "channels",
  "links",
  "accounts",
  "dronebl",
  "media",
  "operations",
]);

function tabFromUrl(): string {
  const m = location.pathname.match(/^\/admin\/([a-z]+)\/?$/i);
  if (m && VALID_TABS.has(m[1].toLowerCase())) return m[1].toLowerCase();
  const h = location.hash.replace(/^#/, "").toLowerCase();
  if (VALID_TABS.has(h)) return h;
  return "overview";
}

function tabButtons(): HTMLButtonElement[] {
  return Array.from(document.querySelectorAll<HTMLButtonElement>(".tab"));
}

function activateTab(tab: string, updateUrl = true): void {
  const next = VALID_TABS.has(tab) ? tab : "overview";
  tabButtons().forEach((t) => {
    const active = t.dataset.tab === next;
    t.classList.toggle("active", active);
    t.setAttribute("aria-selected", String(active));
    t.setAttribute("aria-controls", `panel-${t.dataset.tab}`);
    t.tabIndex = active ? 0 : -1;
    if (active) t.scrollIntoView({ block: "nearest", inline: "nearest" });
  });
  document.querySelectorAll<HTMLElement>(".page").forEach((p) => {
    p.classList.toggle("active", p.id === `panel-${next}`);
  });
  if (updateUrl) {
    const targetPath = next === "overview" ? "/admin" : `/admin/${next}`;
    if (location.pathname !== targetPath || location.hash) {
      history.pushState({ tab: next }, "", targetPath);
    }
  }
  if (next === "media") void refreshMedia();
}

$("tabs").addEventListener("click", (ev) => {
  const target = ev.target as HTMLElement | null;
  const btn = target?.closest<HTMLButtonElement>(".tab");
  if (!btn || !btn.dataset.tab) return;
  activateTab(btn.dataset.tab);
});

$("tabs").addEventListener("keydown", (ev) => {
  const tabs = tabButtons();
  const i = tabs.indexOf(document.activeElement as HTMLButtonElement);
  if (i < 0) return;
  let j: number;
  if (ev.key === "ArrowRight") j = (i + 1) % tabs.length;
  else if (ev.key === "ArrowLeft") j = (i - 1 + tabs.length) % tabs.length;
  else if (ev.key === "Home") j = 0;
  else if (ev.key === "End") j = tabs.length - 1;
  else return;
  ev.preventDefault();
  tabs[j].focus();
  if (tabs[j].dataset.tab) activateTab(tabs[j].dataset.tab!);
});

globalThis.addEventListener("popstate", () => {
  activateTab(tabFromUrl(), false);
});

activateTab(tabFromUrl(), false);

// Overview cards act as links to their tab (mouse and keyboard).
function gotoFromCard(ev: Event): void {
  const card = (ev.target as HTMLElement | null)?.closest<HTMLElement>(
    "[data-goto]",
  );
  if (card?.dataset.goto) activateTab(card.dataset.goto);
}
$("stats-grid").addEventListener("click", gotoFromCard);
$("stats-grid").addEventListener("keydown", (ev) => {
  if (ev.key === "Enter" || ev.key === " ") {
    ev.preventDefault();
    gotoFromCard(ev);
  }
});

// ---------------------------------------------------------------------------
// Header and operations

const AUTO_REFRESH_KEY = "ircd-admin-auto-refresh";
const autoRefresh = $<HTMLInputElement>("auto-refresh");
try {
  autoRefresh.checked = localStorage.getItem(AUTO_REFRESH_KEY) !== "off";
} catch {
  // ignore
}
autoRefresh.onchange = () => {
  try {
    localStorage.setItem(AUTO_REFRESH_KEY, autoRefresh.checked ? "on" : "off");
  } catch {
    // ignore
  }
  if (autoRefresh.checked) void refresh();
};

$("btn-refresh").onclick = async () => {
  const btn = $<HTMLButtonElement>("btn-refresh");
  setBusy(btn, true);
  try {
    await refresh(true);
  } finally {
    setBusy(btn, false);
  }
};

function bindOp(id: string, action: string, args: () => string[]): void {
  const btn = $<HTMLButtonElement>(id);
  btn.dataset.busyKey = busyKey(action);
  btn.onclick = () => void runAction(action, args(), { key: busyKey(action) });
}

bindOp("btn-rehash", "rehash", () => []);
bindOp("btn-check-config", "check-config", () => []);
bindOp("btn-reload-certs", "reload-certs", () => []);
bindOp(
  "btn-log-level",
  "log-level",
  () => [$<HTMLSelectElement>("sel-log-level").value],
);
$("sel-log-level").addEventListener("change", updateLogLevelButton);
$("btn-clear-upload-limits").dataset.busyKey = busyKey("clear-upload-limits");
$("btn-clear-upload-limits").onclick = () =>
  void runAction("clear-upload-limits", [], {
    key: busyKey("clear-upload-limits"),
  });

$("btn-notice-all").dataset.busyKey = busyKey("notice-all");
$("btn-notice-all").onclick = () => {
  openAdminModal({
    title: "Broadcast Server Notice",
    message: "Every connected user receives this NOTICE.",
    label: "Message to all connected users",
    placeholder: "Maintenance announcement...",
    confirmLabel: "Broadcast",
    onConfirm: (msg) =>
      void runAction("notice-all", [msg], { key: busyKey("notice-all") }),
  });
};

$("btn-backup").dataset.busyKey = busyKey("backup");
$("btn-backup").onclick = () => {
  const inp = $<HTMLInputElement>("inp-backup");
  const p = inp.value.trim();
  if (!p) {
    inp.focus();
    inp.classList.add("invalid");
    toast("err", "Enter a backup file path.");
    return;
  }
  void runAction("backup", [p], { key: busyKey("backup") });
};
$("inp-backup").addEventListener(
  "input",
  () => $("inp-backup").classList.remove("invalid"),
);
$("inp-backup").addEventListener("keydown", (ev) => {
  if (ev.key === "Enter") {
    ev.preventDefault();
    $("btn-backup").click();
  }
});

$("btn-drain").dataset.busyKey = busyKey("drain");
$("btn-drain").onclick = () => {
  openAdminModal({
    title: "Drain Listeners",
    message:
      "Listeners stop accepting connections and every connected client is disconnected.",
    label: "Drain reason",
    value: "Server maintenance",
    confirmLabel: "Drain Now",
    danger: true,
    allowEmpty: true,
    requireText: serverName(),
    onConfirm: (reason) =>
      void runAction("drain", [reason], { key: busyKey("drain") }),
  });
};
$("btn-stop").dataset.busyKey = busyKey("stop");
$("btn-stop").onclick = () => {
  openAdminModal({
    title: "Stop IRC Server",
    message:
      "The daemon shuts down. This panel stops working until it is started again.",
    label: "Shutdown reason",
    value: "Server shutting down",
    confirmLabel: "Stop Server",
    danger: true,
    allowEmpty: true,
    requireText: serverName(),
    onConfirm: (reason) =>
      void runAction("stop", [reason], { key: busyKey("stop") }),
  });
};

// Filters: typing filters live; Escape clears.
for (
  const key of [
    "clients",
    "channels",
    "links",
    "accounts",
    "dronebl",
    "voice",
    "files",
  ]
) {
  const inp = $<HTMLInputElement>(`filter-${key}`);
  inp.addEventListener("input", () => {
    tableFilters[key] = inp.value.trim();
    tablePages[key] = 1;
    rerenderTable(key);
  });
  inp.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && inp.value) {
      ev.preventDefault();
      clearFilter(key);
    }
  });
}

$("btn-refresh-media").onclick = () => void refreshMedia();

/**
 * Submit a form through an action: the submit button spins while the request
 * runs, and the fields are cleared only when it succeeds.
 */
function bindForm(
  id: string,
  action: string,
  collect: () => string[] | null,
  clear: () => void,
): void {
  const form = $<HTMLFormElement>(id);
  const submit = form.querySelector<HTMLButtonElement>("button[type=submit]");
  const key = busyKey(`form:${action}`);
  if (submit) submit.dataset.busyKey = key;
  form.onsubmit = async (ev) => {
    ev.preventDefault();
    const args = collect();
    if (!args) return;
    if (await runAction(action, args, { key })) clear();
  };
}

bindForm(
  "form-connect",
  "connect",
  () => {
    const peer = $<HTMLInputElement>("inp-peer").value.trim();
    return peer ? [peer] : null;
  },
  () => {
    $<HTMLInputElement>("inp-peer").value = "";
  },
);
bindForm(
  "form-account",
  "create-account",
  () => {
    const name = $<HTMLInputElement>("inp-acct-name").value.trim();
    const pass = $<HTMLInputElement>("inp-acct-pass").value;
    const email = $<HTMLInputElement>("inp-acct-email").value.trim();
    if (!name || !pass) return null;
    return email ? [name, pass, email] : [name, pass];
  },
  () => {
    $<HTMLInputElement>("inp-acct-name").value = "";
    $<HTMLInputElement>("inp-acct-pass").value = "";
    $<HTMLInputElement>("inp-acct-email").value = "";
    $<HTMLInputElement>("inp-acct-name").focus();
  },
);
bindForm(
  "form-ban-ip",
  "dronebl-ban",
  () => {
    const ip = $<HTMLInputElement>("inp-ban-ip").value.trim();
    const reason = $<HTMLInputElement>("inp-ban-reason").value.trim();
    if (!ip) return null;
    return reason ? [ip, reason] : [ip];
  },
  () => {
    $<HTMLInputElement>("inp-ban-ip").value = "";
    $<HTMLInputElement>("inp-ban-reason").value = "";
  },
);

void refresh(true);
// Skip the periodic refresh while a dialog is open or the tab is hidden, so a
// re-render never moves the row the operator is acting on.
setInterval(() => {
  if (autoRefresh.checked && !isModalOpen() && !document.hidden) {
    void refresh();
  }
}, 5000);
setInterval(updateStamp, 1000);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && autoRefresh.checked) void refresh();
});
