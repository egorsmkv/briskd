import {
  byId as $,
  errorMessage,
  postJson,
  showNotice as showNoticeById,
} from "./common/dom.ts";
import { initTheme } from "./common/theme.ts";

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

const showNotice = (ok: boolean, text: string) =>
  showNoticeById("notice", ok, text);

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

async function postAction(action: string, args: string[] = []): Promise<void> {
  try {
    const { ok, data } = await postJson<Record<string, unknown>>(
      "/api/action",
      {
        action,
        args,
      },
    );
    if (ok) {
      showNotice(true, `${action}: ${JSON.stringify(data)}`);
      await refresh();
    } else {
      showNotice(false, `${action} failed: ${JSON.stringify(data)}`);
    }
  } catch (err) {
    showNotice(false, `${action} error: ${errorMessage(err)}`);
  }
}

const PAGE_SIZE_KEY = "ircd-admin-page-size";
const PAGE_SIZES = [10, 25, 50, 100];
const tablePages: Record<string, number> = {};
const tableFilters: Record<string, string> = {};
let lastOverview: OverviewPayload | null = null;

interface AdminModalOptions {
  title: string;
  label: string;
  value?: string;
  placeholder?: string;
  inputType?: "text" | "password";
  confirmLabel?: string;
  danger?: boolean;
  allowEmpty?: boolean;
  onConfirm: (value: string) => void;
}

let modalConfirm: ((value: string) => void) | null = null;
let modalAllowEmpty = false;

function openAdminModal(opts: AdminModalOptions): void {
  $("admin-modal-title").textContent = opts.title;
  $("admin-modal-label").textContent = opts.label;
  const inp = $<HTMLInputElement>("admin-modal-input");
  inp.type = opts.inputType || "text";
  inp.value = opts.value ?? "";
  inp.placeholder = opts.placeholder ?? "";
  const sub = $<HTMLButtonElement>("admin-modal-submit");
  sub.textContent = opts.confirmLabel || "Confirm";
  sub.className = opts.danger ? "danger" : "primary";
  modalConfirm = opts.onConfirm;
  modalAllowEmpty = opts.allowEmpty === true;
  $("admin-modal").classList.add("open");
  inp.focus();
  if (inp.value) inp.select();
}

function closeAdminModal(): void {
  $("admin-modal").classList.remove("open");
  modalConfirm = null;
  $<HTMLInputElement>("admin-modal-input").value = "";
}

$("btn-close-modal").onclick = closeAdminModal;
$("btn-cancel-modal").onclick = closeAdminModal;
$("admin-modal").addEventListener("click", (ev) => {
  if (ev.target === $("admin-modal")) closeAdminModal();
});
document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape") closeAdminModal();
});
$<HTMLFormElement>("admin-modal-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  if (!modalConfirm) return;
  const inp = $<HTMLInputElement>("admin-modal-input");
  const val = inp.type === "password" ? inp.value : inp.value.trim();
  if (!modalAllowEmpty && !val) return;
  const fn = modalConfirm;
  closeAdminModal();
  fn(val);
});

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

function makeTable(
  key: string,
  headers: string[],
  rows: CellValue[][],
): HTMLElement {
  if (!rows.length) return el("div", "None.", "empty");

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
  for (const h of headers) tr.appendChild(el("th", h));
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
    if (lastOverview) render(lastOverview);
  };
  sizeLabel.appendChild(sizeSel);
  controls.appendChild(sizeLabel);

  const prevBtn = el("button", "Prev", "small");
  prevBtn.type = "button";
  prevBtn.disabled = page <= 1;
  prevBtn.onclick = () => {
    tablePages[key] = page - 1;
    if (lastOverview) render(lastOverview);
  };
  controls.appendChild(prevBtn);

  controls.appendChild(
    el("span", `Page ${page} / ${totalPages}`, "pager-info"),
  );

  const nextBtn = el("button", "Next", "small");
  nextBtn.type = "button";
  nextBtn.disabled = page >= totalPages;
  nextBtn.onclick = () => {
    tablePages[key] = page + 1;
    if (lastOverview) render(lastOverview);
  };
  controls.appendChild(nextBtn);

  pager.appendChild(controls);
  container.appendChild(pager);
  return container;
}

function replace(id: string, node: Node): void {
  const wrap = $(id);
  wrap.textContent = "";
  wrap.appendChild(node);
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
  if (st.log_level && document.activeElement !== selLvl) {
    selLvl.value = st.log_level;
  }

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
        if (c.nick) {
          const kickBtn = el("button", "Kick", "danger small");
          kickBtn.type = "button";
          kickBtn.onclick = () => {
            openAdminModal({
              title: `Kick ${c.nick}`,
              label: "Kick reason",
              value: "Disconnected by administrator",
              confirmLabel: "Kick Client",
              danger: true,
              allowEmpty: true,
              onConfirm: (reason) => {
                if (c.nick) void postAction("kick-client", [c.nick, reason]);
              },
            });
          };
          actions.appendChild(kickBtn);
        }
        if (isIpAddress(c.host)) {
          const banBtn = el("button", "Ban IP", "small");
          banBtn.type = "button";
          banBtn.onclick = () => {
            openAdminModal({
              title: `Ban IP ${c.host}`,
              label: "Ban reason",
              value: "Manual administrator ban",
              confirmLabel: "Ban IP",
              danger: true,
              allowEmpty: true,
              onConfirm: (reason) => {
                if (c.host) {
                  void postAction(
                    "dronebl-ban",
                    reason ? [c.host, reason] : [c.host],
                  );
                }
              },
            });
          };
          actions.appendChild(banBtn);
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
        const tbtn = el("button", "Set Topic", "small");
        tbtn.type = "button";
        tbtn.onclick = () => {
          openAdminModal({
            title: `Set Topic for ${ch.name}`,
            label: "Channel topic (leave blank to clear)",
            value: ch.topic || "",
            confirmLabel: "Save Topic",
            allowEmpty: true,
            onConfirm: (next) => void postAction("set-topic", [ch.name, next]),
          });
        };
        const nbtn = el("button", "Notice", "small");
        nbtn.type = "button";
        nbtn.onclick = () => {
          openAdminModal({
            title: `Send Notice to ${ch.name}`,
            label: "Server NOTICE message",
            placeholder: "Message to all members in channel...",
            confirmLabel: "Send Notice",
            onConfirm: (msg) =>
              void postAction("notice-channel", [ch.name, msg]),
          });
        };
        actions.appendChild(tbtn);
        actions.appendChild(nbtn);
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
    ),
  );

  const connected = data.links?.connected ?? [];
  const configured = data.links?.configured ?? [];
  $("cnt-links").textContent = String(connected.length);
  const linkRows: CellValue[][] = [];
  for (const l of connected) {
    const srvName = l.name || l.server || "";
    if (!matchesFilter("links", srvName, l.info, "connected")) continue;
    const btn = el("button", "SQUIT", "danger small");
    btn.type = "button";
    btn.onclick = () => {
      openAdminModal({
        title: `Disconnect Peer ${srvName}`,
        label: "SQUIT reason",
        value: "Operator disconnect",
        confirmLabel: "SQUIT",
        danger: true,
        allowEmpty: true,
        onConfirm: (reason) => void postAction("squit", [srvName, reason]),
      });
    };
    linkRows.push([
      { text: srvName, cls: "mono" },
      `connected (hop ${l.hop ?? 1})`,
      l.info || "",
      btn,
    ]);
  }
  for (const cfg of configured) {
    const isUp = connected.some((l) => (l.name || l.server) === cfg.name);
    if (!isUp) {
      if (!matchesFilter("links", cfg.name, cfg.host, "configured")) continue;
      const btn = el("button", "Connect", "primary small");
      btn.type = "button";
      btn.onclick = () => void postAction("connect", [cfg.name]);
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
    makeTable("links", ["Server", "State", "Info", "Action"], linkRows),
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
          const vbtn = el("button", "Verify", "primary small");
          vbtn.type = "button";
          vbtn.onclick = () => void postAction("verify-account", [a.name]);
          wrap.appendChild(vbtn);
        } else {
          const pbtn = el("button", "Reset Pass", "small");
          pbtn.type = "button";
          pbtn.onclick = () => {
            openAdminModal({
              title: `Reset Password for ${a.name}`,
              label: "New SASL password",
              inputType: "password",
              placeholder: "Enter new password...",
              confirmLabel: "Update Password",
              onConfirm: (pass) =>
                void postAction("reset-password", [a.name, pass]),
            });
          };
          wrap.appendChild(pbtn);
        }
        const btn = el("button", "Delete", "danger small");
        btn.type = "button";
        btn.onclick = () => {
          if (confirm(`Delete account ${a.name}?`)) {
            void postAction("delete-account", [a.name]);
          }
        };
        wrap.appendChild(btn);
        return [
          { text: a.name, cls: "mono" },
          a.verified === false ? "pending" : "verified",
          a.email || "-",
          a.certfps ?? 0,
          wrap,
        ];
      }),
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
      filteredBans.map((b) => {
        const btn = el("button", "Unban", "small");
        btn.type = "button";
        btn.onclick = () => void postAction("dronebl-unban", [b.ip]);
        return [
          { text: b.ip, cls: "mono" },
          b.code,
          `${b.expires_in ?? 0}s`,
          b.reason || "",
          btn,
        ];
      }),
    ),
  );
}

async function refresh(): Promise<void> {
  try {
    const res = await fetch("/api/overview", { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    render((await res.json()) as OverviewPayload);
  } catch (e) {
    $("srv-status").textContent = "unreachable";
    $("srv-status").className = "badge off";
    showNotice(
      false,
      `Failed to load server stats: ${
        e instanceof Error ? e.message : String(e)
      }`,
    );
  }
}

initTheme([$("btn-theme")]);

const VALID_TABS = new Set([
  "overview",
  "clients",
  "channels",
  "links",
  "accounts",
  "dronebl",
  "operations",
]);

function activateTab(tab: string, updateHash = true): void {
  const next = VALID_TABS.has(tab) ? tab : "overview";
  document.querySelectorAll<HTMLButtonElement>(".tab").forEach((t) => {
    const active = t.dataset.tab === next;
    t.classList.toggle("active", active);
    t.setAttribute("aria-selected", String(active));
  });
  document.querySelectorAll<HTMLElement>(".page").forEach((p) => {
    p.classList.toggle("active", p.id === `panel-${next}`);
  });
  if (updateHash && location.hash !== `#${next}`) {
    history.replaceState(null, "", `#${next}`);
  }
}

$("tabs").addEventListener("click", (ev) => {
  const target = ev.target as HTMLElement | null;
  const btn = target?.closest<HTMLButtonElement>(".tab");
  if (!btn || !btn.dataset.tab) return;
  activateTab(btn.dataset.tab);
});

globalThis.addEventListener("hashchange", () => {
  activateTab(location.hash.replace(/^#/, ""), false);
});

activateTab(location.hash.replace(/^#/, ""), false);

$("btn-refresh").onclick = () => void refresh();
$("btn-rehash").onclick = () => void postAction("rehash", []);
$("btn-check-config").onclick = () => void postAction("check-config", []);
$("btn-reload-certs").onclick = () => void postAction("reload-certs", []);
$("btn-log-level").onclick = () =>
  void postAction("log-level", [$<HTMLSelectElement>("sel-log-level").value]);
$("btn-notice-all").onclick = () => {
  openAdminModal({
    title: "Broadcast Server Notice",
    label: "Message to all connected users",
    placeholder: "Maintenance announcement...",
    confirmLabel: "Broadcast",
    onConfirm: (msg) => void postAction("notice-all", [msg]),
  });
};
$("btn-backup").onclick = () => {
  const p = $<HTMLInputElement>("inp-backup").value.trim();
  if (!p) {
    showNotice(false, "Enter a backup file path.");
    return;
  }
  void postAction("backup", [p]);
};
$("btn-drain").onclick = () => {
  openAdminModal({
    title: "Drain Listeners",
    label: "Drain reason (disconnects all clients)",
    value: "Server maintenance",
    confirmLabel: "Drain Now",
    danger: true,
    allowEmpty: true,
    onConfirm: (reason) => void postAction("drain", [reason]),
  });
};
$("btn-stop").onclick = () => {
  openAdminModal({
    title: "Stop IRC Server",
    label: "Shutdown reason",
    value: "Server shutting down",
    confirmLabel: "Stop Server",
    danger: true,
    allowEmpty: true,
    onConfirm: (reason) => void postAction("stop", [reason]),
  });
};

for (const key of ["clients", "channels", "links", "accounts", "dronebl"]) {
  $<HTMLInputElement>(`filter-${key}`).addEventListener("input", (ev) => {
    tableFilters[key] = (ev.target as HTMLInputElement).value.trim();
    tablePages[key] = 1;
    if (lastOverview) render(lastOverview);
  });
}

$("stats-grid").addEventListener("click", (ev) => {
  const card = (ev.target as HTMLElement | null)?.closest<HTMLElement>(
    "[data-goto]",
  );
  if (card?.dataset.goto) activateTab(card.dataset.goto);
});
$<HTMLFormElement>("form-connect").onsubmit = (ev) => {
  ev.preventDefault();
  const inp = $<HTMLInputElement>("inp-peer");
  const peer = inp.value.trim();
  if (peer) {
    void postAction("connect", [peer]);
    inp.value = "";
  }
};
$<HTMLFormElement>("form-account").onsubmit = (ev) => {
  ev.preventDefault();
  const nameInp = $<HTMLInputElement>("inp-acct-name");
  const passInp = $<HTMLInputElement>("inp-acct-pass");
  const emailInp = $<HTMLInputElement>("inp-acct-email");
  const name = nameInp.value.trim();
  const pass = passInp.value;
  const email = emailInp.value.trim();
  if (name && pass) {
    const args = email ? [name, pass, email] : [name, pass];
    void postAction("create-account", args);
    nameInp.value = "";
    passInp.value = "";
    emailInp.value = "";
  }
};
$<HTMLFormElement>("form-ban-ip").onsubmit = (ev) => {
  ev.preventDefault();
  const ipInp = $<HTMLInputElement>("inp-ban-ip");
  const reasonInp = $<HTMLInputElement>("inp-ban-reason");
  const ip = ipInp.value.trim();
  const reason = reasonInp.value.trim();
  if (ip) {
    void postAction("dronebl-ban", reason ? [ip, reason] : [ip]);
    ipInp.value = "";
    reasonInp.value = "";
  }
};

void refresh();
setInterval(() => {
  if ($<HTMLInputElement>("auto-refresh").checked) void refresh();
}, 5000);
