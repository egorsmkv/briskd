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
    stats?: { enabled?: boolean; bans?: number; cached_clean?: number; in_flight?: number };
    bans?: DroneblBan[];
  };
}

type CellValue = Node | { text: string; cls?: string } | string | number | null | undefined;

const $ = <T extends HTMLElement = HTMLElement>(id: string): T =>
  document.getElementById(id) as T;

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

function showNotice(ok: boolean, text: string): void {
  const n = $("notice");
  n.className = ok ? "ok" : "err";
  n.textContent = text;
}

function fmtUptime(s: number): string {
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return (d ? `${d}d ` : "") + `${h}h ${m}m ${sec}s`;
}

function fmtMem(bytes: number): string {
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}

async function postAction(action: string, args: string[] = []): Promise<void> {
  try {
    const res = await fetch("/api/action", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Requested-With": "ircd-webui",
      },
      body: JSON.stringify({ action, args }),
    });
    const data = await res.json();
    if (res.ok) {
      showNotice(true, `${action}: ${JSON.stringify(data)}`);
      await refresh();
    } else {
      showNotice(false, `${action} failed: ${JSON.stringify(data)}`);
    }
  } catch (e) {
    showNotice(false, `${action} error: ${e instanceof Error ? e.message : String(e)}`);
  }
}

function makeTable(headers: string[], rows: CellValue[][]): HTMLElement {
  if (!rows.length) return el("div", "None.", "empty");
  const table = document.createElement("table");
  const thead = document.createElement("thead");
  const tr = document.createElement("tr");
  for (const h of headers) tr.appendChild(el("th", h));
  thead.appendChild(tr);
  table.appendChild(thead);

  const tbody = document.createElement("tbody");
  for (const cells of rows) {
    const r = document.createElement("tr");
    for (const cell of cells) {
      const td = document.createElement("td");
      if (cell instanceof Node) {
        td.appendChild(cell);
      } else if (cell && typeof cell === "object" && "text" in cell) {
        td.textContent = String(cell.text);
        if (cell.cls) td.className = cell.cls;
      } else {
        td.textContent = cell === undefined || cell === null ? "" : String(cell);
      }
      r.appendChild(td);
    }
    tbody.appendChild(r);
  }
  table.appendChild(tbody);
  return table;
}

function replace(id: string, node: Node): void {
  const wrap = $(id);
  wrap.textContent = "";
  wrap.appendChild(node);
}

function render(data: OverviewPayload): void {
  const st = data.status ?? {};
  $("srv-name").textContent = st.name || "ircd";
  const badge = $("srv-status");
  badge.textContent = st.status || "unknown";
  badge.className = st.status === "running" ? "badge" : "badge off";
  $("srv-meta").textContent =
    `network ${st.network || "-"} | up ${fmtUptime(st.uptime_seconds || 0)} | listeners: ` +
    (st.listeners || []).map((l) => `${l.transport}:${l.port}`).join(", ");

  $("st-sessions").textContent = `${st.sessions ?? 0} / ${st.max_clients ?? 0}`;
  $("st-sessions-sub").textContent =
    `registered: ${st.registered_users ?? 0}, operators: ${st.operators_online ?? 0}`;
  $("st-channels").textContent = String(st.channels ?? 0);
  $("st-channels-sub").textContent = `remote: ${st.remote_channels ?? 0}`;
  $("st-network").textContent = `${st.known_servers ?? 0} peers`;
  $("st-network-sub").textContent =
    `remote users: ${st.remote_users ?? 0}, services: ${st.services ?? 0}`;
  $("st-accounts").textContent = String(st.accounts ?? 0);
  $("st-retention").textContent = `retention: ${st.retention || "-"}`;

  const dbl = data.dronebl ?? {};
  const dblStats = dbl.stats ?? {};
  $("st-dronebl").textContent = dblStats.enabled ? `${dblStats.bans ?? 0} bans` : "disabled";
  $("st-dronebl-sub").textContent = dblStats.enabled
    ? `clean cache: ${dblStats.cached_clean ?? 0}, in-flight: ${dblStats.in_flight ?? 0}`
    : "enable in config";

  $("st-memory").textContent = fmtMem(st.memory_bytes || 0);
  $("st-procs").textContent = `${st.erlang_processes ?? 0} processes`;

  const selLvl = $<HTMLSelectElement>("sel-log-level");
  if (st.log_level && document.activeElement !== selLvl) {
    selLvl.value = st.log_level;
  }

  const clients = data.clients?.clients ?? [];
  $("cnt-clients").textContent = String(clients.length);
  replace(
    "clients-wrap",
    makeTable(
      ["Nick", "User@Host", "Account", "Oper", "TLS", "Channels", "Idle", "Action"],
      clients.map((c) => {
        const btn = el("button", "Kick", "danger small");
        btn.type = "button";
        btn.onclick = () => {
          const reason = prompt(`Kick reason for ${c.nick}:`, "Disconnected by administrator");
          if (reason !== null && c.nick) void postAction("kick-client", [c.nick, reason]);
        };
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
          c.nick ? btn : "",
        ];
      }),
    ),
  );

  const channels = data.channels?.channels ?? [];
  $("cnt-channels").textContent = String(channels.length);
  replace(
    "channels-wrap",
    makeTable(
      ["Channel", "Local", "Remote", "Modes", "Predefined", "Topic", "Action"],
      channels.map((ch) => {
        const tbtn = el("button", "Set Topic", "small");
        tbtn.type = "button";
        tbtn.onclick = () => {
          const next = prompt(`New topic for ${ch.name}:`, ch.topic || "");
          if (next !== null) void postAction("set-topic", [ch.name, next]);
        };
        return [
          { text: ch.name, cls: "mono" },
          ch.local_members ?? 0,
          ch.remote_members ?? 0,
          { text: ch.modes || "+", cls: "mono" },
          ch.predefined ? "yes" : "no",
          ch.topic || "",
          tbtn,
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
    const btn = el("button", "SQUIT", "danger small");
    btn.type = "button";
    btn.onclick = () => {
      const reason = prompt(`SQUIT reason for ${srvName}:`, "Operator disconnect");
      if (reason !== null) void postAction("squit", [srvName, reason]);
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
  replace("links-wrap", makeTable(["Server", "State", "Info", "Action"], linkRows));

  const accounts = data.accounts?.accounts ?? [];
  $("cnt-accounts").textContent = String(accounts.length);
  replace(
    "accounts-wrap",
    makeTable(
      ["Account", "Status", "Email", "CertFPs", "Action"],
      accounts.map((a) => {
        const wrap = el("span", undefined, "action-row");
        if (a.verified === false) {
          const vbtn = el("button", "Verify", "primary small");
          vbtn.type = "button";
          vbtn.onclick = () => void postAction("verify-account", [a.name]);
          wrap.appendChild(vbtn);
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
  replace(
    "dronebl-wrap",
    makeTable(
      ["IP", "Code", "Expires In", "Reason", "Action"],
      bans.map((b) => {
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
    showNotice(false, `Failed to load server stats: ${e instanceof Error ? e.message : String(e)}`);
  }
}

initTheme([$("btn-theme")]);

$("tabs").addEventListener("click", (ev) => {
  const target = ev.target as HTMLElement | null;
  const btn = target?.closest<HTMLButtonElement>(".tab");
  if (!btn || !btn.dataset.tab) return;
  document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
  document.querySelectorAll(".panel").forEach((p) => p.classList.remove("active"));
  btn.classList.add("active");
  $(`panel-${btn.dataset.tab}`).classList.add("active");
});

$("btn-refresh").onclick = () => void refresh();
$("btn-rehash").onclick = () => void postAction("rehash", []);
$("btn-check-config").onclick = () => void postAction("check-config", []);
$("btn-reload-certs").onclick = () => void postAction("reload-certs", []);
$("btn-log-level").onclick = () =>
  void postAction("log-level", [$<HTMLSelectElement>("sel-log-level").value]);
$("btn-notice-all").onclick = () => {
  const msg = prompt("Broadcast server NOTICE to all connected users:");
  if (msg && msg.trim()) void postAction("notice-all", [msg.trim()]);
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
  const reason = prompt("Drain reason:", "Server maintenance");
  if (reason !== null && confirm("Drain all listeners and disconnect clients?")) {
    void postAction("drain", [reason]);
  }
};
$("btn-stop").onclick = () => {
  const reason = prompt("Stop reason:", "Server shutting down");
  if (reason !== null && confirm("Stop the IRC server?")) {
    void postAction("stop", [reason]);
  }
};
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
