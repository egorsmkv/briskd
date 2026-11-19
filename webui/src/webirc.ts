import { currentTheme, initTheme, setTheme, THEMES } from "./common/theme.ts";
import { updateDynamicFavicon } from "./common/favicon.ts";
import { E2EE_CAP, E2eeManager } from "./e2ee/manager.ts";

interface WebircSettings {
  density: "comfortable" | "compact";
  fontSize: "small" | "normal" | "large";
  timestamps: boolean;
  joinPart: boolean;
  notifyMentions: boolean;
}

const SETTINGS_KEY = "ircd-webirc-settings";

function loadSettings(): WebircSettings {
  const defaults: WebircSettings = {
    density: "comfortable",
    fontSize: "normal",
    timestamps: true,
    joinPart: true,
    notifyMentions: false,
  };
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    if (!raw) return defaults;
    const parsed = JSON.parse(raw) as Partial<WebircSettings>;
    return {
      density: parsed.density === "compact" ? "compact" : "comfortable",
      fontSize:
        parsed.fontSize === "small" || parsed.fontSize === "large" ? parsed.fontSize : "normal",
      timestamps: parsed.timestamps !== false,
      joinPart: parsed.joinPart !== false,
      notifyMentions: parsed.notifyMentions === true,
    };
  } catch {
    return defaults;
  }
}

function saveSettings(s: WebircSettings): void {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(s));
  } catch {
    // ignore
  }
}

interface IrcMessage {
  tags: Record<string, string>;
  prefix: string;
  nick: string;
  command: string;
  params: string[];
}

interface ChatLine {
  time: string;
  epochMs: number;
  nick: string;
  text: string;
  kind: "" | "sys" | "err" | "action" | "notice";
  mention?: boolean;
  encrypted?: boolean;
}

interface BufferState {
  name: string;
  topic: string;
  lines: ChatLine[];
  unread: number;
  mentions: number;
  members: Map<string, string>;
}

const $ = <T extends HTMLElement = HTMLElement>(id: string): T =>
  document.getElementById(id) as T;

const AVATAR_COLORS = [
  "#2563eb",
  "#0891b2",
  "#059669",
  "#7c3aed",
  "#db2777",
  "#d97706",
  "#dc2626",
  "#4f46e5",
];

function nickColor(nick: string): string {
  let h = 0;
  for (let i = 0; i < nick.length; i++) {
    h = (h * 31 + nick.charCodeAt(i)) >>> 0;
  }
  return AVATAR_COLORS[h % AVATAR_COLORS.length];
}

function isChan(name: string): boolean {
  return /^[#&+!]/.test(name || "");
}

function fmtTime(iso?: string): { text: string; ms: number } {
  const d = iso ? new Date(iso) : new Date();
  if (Number.isNaN(d.getTime())) return { text: "", ms: Date.now() };
  return { text: d.toTimeString().slice(0, 5), ms: d.getTime() };
}

function parseIrc(raw: string): IrcMessage | null {
  let idx = 0;
  const tags: Record<string, string> = {};
  if (raw[0] === "@") {
    const sp = raw.indexOf(" ");
    if (sp === -1) return null;
    for (const pair of raw.slice(1, sp).split(";")) {
      const eq = pair.indexOf("=");
      if (eq === -1) tags[pair] = "";
      else tags[pair.slice(0, eq)] = pair.slice(eq + 1);
    }
    idx = sp + 1;
    while (raw[idx] === " ") idx++;
  }
  let prefix = "";
  if (raw[idx] === ":") {
    const sp = raw.indexOf(" ", idx);
    if (sp === -1) return null;
    prefix = raw.slice(idx + 1, sp);
    idx = sp + 1;
    while (raw[idx] === " ") idx++;
  }
  const params: string[] = [];
  let command = "";
  while (idx < raw.length) {
    if (raw[idx] === ":" && command) {
      params.push(raw.slice(idx + 1));
      break;
    }
    let sp = raw.indexOf(" ", idx);
    if (sp === -1) sp = raw.length;
    const tok = raw.slice(idx, sp);
    if (!command) command = tok.toUpperCase();
    else params.push(tok);
    idx = sp + 1;
    while (raw[idx] === " ") idx++;
  }
  const nick = prefix.includes("!") ? prefix.slice(0, prefix.indexOf("!")) : prefix;
  return { tags, prefix, nick, command, params };
}

const themeButtons = [$("btn-theme-1"), $("btn-theme-2")];
initTheme(themeButtons);

const settings: WebircSettings = loadSettings();

function applySettings(): void {
  document.body.classList.toggle("density-compact", settings.density === "compact");
  document.body.classList.toggle("hide-timestamps", !settings.timestamps);
  document.body.classList.toggle("font-small", settings.fontSize === "small");
  document.body.classList.toggle("font-large", settings.fontSize === "large");
  $<HTMLSelectElement>("opt-density").value = settings.density;
  $<HTMLSelectElement>("opt-fontsize").value = settings.fontSize;
  $<HTMLInputElement>("opt-timestamps").checked = settings.timestamps;
  $<HTMLInputElement>("opt-joinpart").checked = settings.joinPart;
  $<HTMLInputElement>("opt-notify").checked = settings.notifyMentions;
}

function renderThemeSwatches(): void {
  const grid = $("theme-grid");
  grid.textContent = "";
  const active = currentTheme();
  for (const t of THEMES) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "theme-swatch" + (t.id === active ? " active" : "");
    const chip = document.createElement("span");
    chip.className = "swatch-chip";
    chip.style.backgroundColor = t.swatchBg;
    chip.style.borderColor = t.swatchAccent;
    const label = document.createElement("span");
    label.textContent = t.name;
    btn.appendChild(chip);
    btn.appendChild(label);
    btn.onclick = () => {
      setTheme(t.id, themeButtons);
      renderThemeSwatches();
    };
    grid.appendChild(btn);
  }
}

function openSettings(): void {
  renderThemeSwatches();
  applySettings();
  $("settings-modal").classList.add("open");
}

function closeSettings(): void {
  $("settings-modal").classList.remove("open");
}

applySettings();
$("btn-settings-1").onclick = openSettings;
$("btn-settings-2").onclick = openSettings;
$("btn-close-settings").onclick = closeSettings;
$("settings-modal").addEventListener("click", (ev) => {
  if (ev.target === $("settings-modal")) closeSettings();
});
document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape") {
    closeSettings();
    closeE2eeModal();
  }
});

$<HTMLSelectElement>("opt-density").onchange = (ev) => {
  const v = (ev.target as HTMLSelectElement).value;
  settings.density = v === "compact" ? "compact" : "comfortable";
  saveSettings(settings);
  applySettings();
};
$<HTMLSelectElement>("opt-fontsize").onchange = (ev) => {
  const v = (ev.target as HTMLSelectElement).value;
  settings.fontSize = v === "small" || v === "large" ? v : "normal";
  saveSettings(settings);
  applySettings();
};
$<HTMLInputElement>("opt-timestamps").onchange = (ev) => {
  settings.timestamps = (ev.target as HTMLInputElement).checked;
  saveSettings(settings);
  applySettings();
};
$<HTMLInputElement>("opt-joinpart").onchange = (ev) => {
  settings.joinPart = (ev.target as HTMLInputElement).checked;
  saveSettings(settings);
  applySettings();
};
$<HTMLInputElement>("opt-notify").onchange = async (ev) => {
  const checked = (ev.target as HTMLInputElement).checked;
  if (checked && typeof Notification !== "undefined" && Notification.permission === "default") {
    try {
      await Notification.requestPermission();
    } catch {
      // ignore
    }
  }
  settings.notifyMentions = checked;
  saveSettings(settings);
};

const bodyData = document.body.dataset;
const WS_PORT = bodyData.wsPort || "";
const WSS_PORT = bodyData.wssPort || "";
const BASE_TITLE = document.title;

(function initWsUrl() {
  const isHttps = location.protocol === "https:";
  const host = location.hostname || "127.0.0.1";
  const inp = $<HTMLInputElement>("inp-ws");
  if (isHttps && WSS_PORT) {
    inp.value = `wss://${host}:${WSS_PORT}/`;
  } else if (WS_PORT) {
    inp.value = `ws://${host}:${WS_PORT}/`;
  } else if (WSS_PORT) {
    inp.value = `wss://${host}:${WSS_PORT}/`;
  } else {
    inp.value = `${isHttps ? "wss" : "ws"}://${location.host}/`;
  }
})();

let ws: WebSocket | null = null;
let lastWsUrl = "";
let myNick = "";
let saslUser = "";
let saslPass = "";
let autoChannels: string[] = [];
let activeBuf = "*status";
let memberFilter = "";
let advertisedCaps: string[] = [];
let isRegistered = false;
let hiddenUnread = 0;
let hiddenMentions = 0;
const buffers = new Map<string, BufferState>();
const sentHistory: string[] = [];
let histPos = -1;

const e2ee = new E2eeManager({
  sendRaw: (line) => sendRaw(line),
  onDecrypted: (ev) => {
    addLine(ev.target, {
      time: ev.time,
      nick: ev.nick,
      text: ev.text,
      encrypted: true,
    });
  },
  onNotice: (target, text, kind) => {
    addLine(target, { text, kind });
  },
  onStateChange: () => {
    updateE2eeUi();
    renderBuffers();
    if ($("e2ee-modal").classList.contains("open")) renderE2eeModal();
  },
});

function updateE2eeUi(): void {
  const buf = buffers.get(activeBuf);
  const btn = $("btn-e2ee");
  const form = $("send-form");
  const inp = $<HTMLInputElement>("inp-msg");
  if (!buf || buf.name === "*status") {
    btn.style.display = "none";
    form.classList.remove("e2ee-active");
    inp.placeholder = "Message or /help (Tab to complete nicks, Alt+Up/Down to switch)";
    return;
  }
  btn.style.display = "inline-flex";
  const on = e2ee.isBufferEncrypted(buf.name);
  const ready = e2ee.isReady();
  btn.classList.toggle("on", on);
  btn.textContent = on ? "🔒 E2EE On" : "🔓 E2EE Off";
  if (!ready) {
    btn.title = e2ee.isServerSupported()
      ? "Log in with a SASL account to enable E2EE"
      : "Server does not have E2EE enabled";
  } else {
    btn.title = on
      ? "End-to-end encryption is active for this conversation (click to disable)"
      : "Click to enable end-to-end encryption for this conversation";
  }
  form.classList.toggle("e2ee-active", on);
  inp.placeholder = on
    ? `Encrypted message to ${buf.name} (E2EE) or /help...`
    : "Message or /help (Tab to complete nicks, Alt+Up/Down to switch)";
}

function renderE2eeModal(): void {
  const st = e2ee.getStatus();
  const banner = $("e2ee-status-banner");
  banner.className = "e2ee-status-banner";
  if (!st.serverSupported) {
    banner.classList.add("warn");
    banner.textContent = "Server does not advertise egorsmkv.github.io/e2ee.";
  } else if (!st.account) {
    banner.classList.add("warn");
    banner.textContent = "Connect with a SASL account to publish device keys and use E2EE.";
  } else if (!st.bound) {
    banner.textContent = "Publishing and binding E2EE device keys...";
  } else {
    banner.classList.add("ok");
    banner.textContent = "E2EE active (X3DH + Double Ratchet for DMs, Sender Keys for channels).";
  }

  $("e2ee-account").textContent = st.account || "-";
  $("e2ee-device").textContent = st.deviceId ? String(st.deviceId) : "-";
  $("e2ee-prekeys").textContent = st.bound ? String(st.prekeyCount) : "-";
  $("e2ee-sessions").textContent = String(st.sessionCount);
  $("e2ee-fingerprint").textContent = st.fingerprint || "-";

  const buf = buffers.get(activeBuf);
  const canRotate = st.bound && !!buf && isChan(buf.name);
  $<HTMLButtonElement>("btn-e2ee-rotate").disabled = !canRotate;
  $<HTMLButtonElement>("btn-e2ee-replenish").disabled = !st.bound;
  $<HTMLButtonElement>("btn-e2ee-reset").disabled = !st.account;

  const peersEl = $("e2ee-peers");
  peersEl.textContent = "";
  if (st.trustedPeers.length === 0) {
    const empty = document.createElement("div");
    empty.className = "e2ee-empty";
    empty.textContent = "No peer devices pinned yet. Send or receive an encrypted message to establish sessions.";
    peersEl.appendChild(empty);
  } else {
    for (const p of st.trustedPeers) {
      const row = document.createElement("div");
      row.className = "e2ee-peer-row";
      const info = document.createElement("div");
      info.className = "e2ee-peer-info";
      const title = document.createElement("div");
      title.className = "peer-id";
      title.textContent = `${p.account} (device ${p.device})`;
      const sn = document.createElement("div");
      sn.className = "peer-sn";
      sn.textContent = `Safety #: ${p.safetyNumber}`;
      info.appendChild(title);
      info.appendChild(sn);

      const forget = document.createElement("button");
      forget.type = "button";
      forget.className = "small";
      forget.textContent = "Forget";
      forget.title = "Forget pinned identity key and session for this device";
      forget.onclick = () => {
        e2ee.forgetPeer(p.key);
        renderE2eeModal();
      };
      row.appendChild(info);
      row.appendChild(forget);
      peersEl.appendChild(row);
    }
  }
}

function openE2eeModal(): void {
  renderE2eeModal();
  $("e2ee-modal").classList.add("open");
}

function closeE2eeModal(): void {
  $("e2ee-modal").classList.remove("open");
}

$("btn-e2ee").onclick = () => {
  const buf = buffers.get(activeBuf);
  if (!buf || buf.name === "*status") return;
  const on = e2ee.toggleBuffer(buf.name);
  if (e2ee.isReady()) {
    addLine(buf.name, {
      text: on
        ? "End-to-end encryption enabled for this conversation."
        : "End-to-end encryption disabled for this conversation.",
      kind: "sys",
    });
  }
};
$("btn-e2ee-keys").onclick = openE2eeModal;
$("btn-close-e2ee").onclick = closeE2eeModal;
$("e2ee-modal").addEventListener("click", (ev) => {
  if (ev.target === $("e2ee-modal")) closeE2eeModal();
});
$("btn-e2ee-replenish").onclick = () => {
  e2ee.replenishPrekeys(20);
  addLine("*status", { text: "Uploaded 20 fresh E2EE one-time prekeys.", kind: "sys" });
};
$("btn-e2ee-rotate").onclick = () => {
  const buf = buffers.get(activeBuf);
  if (buf && isChan(buf.name)) void e2ee.rotateChannelKey(buf.name);
};
$("btn-e2ee-reset").onclick = () => {
  if (confirm("Reset your E2EE device keys and sessions? Peers will see a new identity key.")) {
    e2ee.resetDevice();
    renderE2eeModal();
  }
};

function updateTitle(): void {
  let totalUnread = hiddenUnread;
  let totalMentions = hiddenMentions;
  buffers.forEach((b) => {
    totalUnread += b.unread;
    totalMentions += b.mentions;
  });
  if (totalMentions > 0) document.title = `(@${totalMentions}) ${BASE_TITLE}`;
  else if (totalUnread > 0) document.title = `(${totalUnread}) ${BASE_TITLE}`;
  else document.title = BASE_TITLE;
  updateDynamicFavicon({
    connected: isRegistered,
    unread: totalUnread,
    mentions: totalMentions,
  });
}

function clearHiddenCounters(): void {
  if (hiddenUnread > 0 || hiddenMentions > 0) {
    hiddenUnread = 0;
    hiddenMentions = 0;
    updateTitle();
  }
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden) clearHiddenCounters();
});
window.addEventListener("focus", clearHiddenCounters);

function ensureBuf(name: string): BufferState {
  const key = name.toLowerCase();
  let buf = buffers.get(key);
  if (!buf) {
    buf = { name, topic: "", lines: [], unread: 0, mentions: 0, members: new Map() };
    buffers.set(key, buf);
    renderBuffers();
  }
  return buf;
}

function isMention(text: string, sender: string): boolean {
  if (!myNick || !sender || sender.toLowerCase() === myNick.toLowerCase()) return false;
  const escaped = myNick.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|\\W)${escaped}(\\W|$)`, "i").test(text);
}

function addLine(
  bufName: string,
  opts: {
    time?: string;
    nick?: string;
    text: string;
    kind?: ChatLine["kind"];
    encrypted?: boolean;
  },
): void {
  const buf = ensureBuf(bufName);
  const t = fmtTime(opts.time);
  const mention = opts.kind ? false : isMention(opts.text, opts.nick || "");
  const entry: ChatLine = {
    time: t.text,
    epochMs: t.ms,
    nick: opts.nick || "",
    text: opts.text,
    kind: opts.kind || "",
    mention,
    encrypted: opts.encrypted,
  };
  const prev = buf.lines[buf.lines.length - 1];
  buf.lines.push(entry);
  if (buf.lines.length > 600) buf.lines.shift();

  const isFromOther = !!entry.nick && entry.nick.toLowerCase() !== myNick.toLowerCase();
  const isDm = !isChan(bufName) && bufName !== "*status";
  const isAlert = mention || (isDm && isFromOther && !opts.kind);

  if (bufName.toLowerCase() === activeBuf) {
    appendLineDom(entry, prev);
    if (document.hidden && isFromOther && !opts.kind) {
      hiddenUnread += 1;
      if (isAlert) hiddenMentions += 1;
      updateTitle();
    }
  } else {
    buf.unread += 1;
    if (isAlert) buf.mentions += 1;
    renderBuffers();
    updateTitle();
  }
  if (
    mention &&
    settings.notifyMentions &&
    typeof Notification !== "undefined" &&
    Notification.permission === "granted" &&
    document.hidden
  ) {
    new Notification(`${entry.nick} in ${bufName}`, { body: entry.text });
  }
}

function appendLineDom(entry: ChatLine, prev?: ChatLine): void {
  const wrap = $("messages");
  const atBottom = wrap.scrollHeight - wrap.scrollTop - wrap.clientHeight < 60;
  const grouped =
    !entry.kind &&
    !!entry.nick &&
    !!prev &&
    !prev.kind &&
    prev.nick === entry.nick &&
    entry.epochMs - prev.epochMs < 180000;

  const row = document.createElement("div");
  row.className =
    "msg" +
    (entry.kind ? ` ${entry.kind}` : "") +
    (grouped ? " grouped" : "") +
    (entry.mention ? " mention" : "");

  if (entry.kind || !entry.nick) {
    const t = document.createElement("span");
    t.className = "msg-time";
    t.textContent = entry.time;
    row.appendChild(t);
    const body = document.createElement("span");
    body.className = "msg-text";
    body.textContent = entry.text;
    row.appendChild(body);
  } else if (grouped) {
    const t = document.createElement("span");
    t.className = "msg-time compact-time";
    t.textContent = entry.time;
    row.appendChild(t);
    const body = document.createElement("span");
    body.className = "msg-text";
    body.textContent = entry.text;
    row.appendChild(body);
  } else {
    const av = document.createElement("div");
    av.className = "avatar";
    av.style.backgroundColor = nickColor(entry.nick);
    av.textContent = entry.nick.slice(0, 2).toUpperCase();
    row.appendChild(av);

    const col = document.createElement("div");
    col.className = "msg-col";

    const meta = document.createElement("div");
    meta.className = "msg-meta";
    const n = document.createElement("span");
    n.className = "msg-nick";
    n.textContent = entry.nick;
    n.style.color = nickColor(entry.nick);
    n.title = "Click to message";
    n.onclick = () => {
      if (entry.nick.toLowerCase() !== myNick.toLowerCase()) {
        ensureBuf(entry.nick);
        switchBuf(entry.nick.toLowerCase());
      }
    };
    const t = document.createElement("span");
    t.className = "msg-time";
    t.textContent = entry.time;
    meta.appendChild(n);
    meta.appendChild(t);
    if (entry.encrypted) {
      const badge = document.createElement("span");
      badge.className = "msg-e2ee";
      badge.textContent = "E2EE";
      badge.title = "End-to-end encrypted";
      meta.appendChild(badge);
    }

    const body = document.createElement("div");
    body.className = "msg-text";
    body.textContent = entry.text;

    col.appendChild(meta);
    col.appendChild(body);
    row.appendChild(col);
  }

  wrap.appendChild(row);
  if (atBottom) wrap.scrollTop = wrap.scrollHeight;
}

function closeDrawers(): void {
  $("sidebar-left").classList.remove("open");
  $("sidebar-right").classList.remove("open");
  $("drawer-backdrop").classList.remove("open");
}

function toggleDrawer(side: "left" | "right"): void {
  const el = $(side === "left" ? "sidebar-left" : "sidebar-right");
  const other = $(side === "left" ? "sidebar-right" : "sidebar-left");
  other.classList.remove("open");
  const next = !el.classList.contains("open");
  el.classList.toggle("open", next);
  $("drawer-backdrop").classList.toggle("open", next);
}

$("btn-menu").onclick = () => toggleDrawer("left");
$("btn-members").onclick = () => toggleDrawer("right");
$("btn-close-left").onclick = closeDrawers;
$("btn-close-right").onclick = closeDrawers;
$("drawer-backdrop").onclick = closeDrawers;

function switchBuf(key: string): void {
  const buf = buffers.get(key);
  if (!buf) return;
  closeDrawers();
  activeBuf = key;
  buf.unread = 0;
  buf.mentions = 0;
  $("active-title").textContent = buf.name === "*status" ? "Server Status" : buf.name;
  $("active-topic").textContent = buf.topic || (isChan(buf.name) ? "No topic set" : "");
  $("btn-topic").style.display = isChan(buf.name) ? "inline-flex" : "none";

  const wrap = $("messages");
  wrap.textContent = "";
  let prev: ChatLine | undefined;
  for (const line of buf.lines) {
    appendLineDom(line, prev);
    prev = line;
  }
  wrap.scrollTop = wrap.scrollHeight;
  updateE2eeUi();
  renderBuffers();
  renderMembers();
  updateTitle();
  $<HTMLInputElement>("inp-msg").focus();
}

function buildBufRow(buf: BufferState, key: string): HTMLElement {
  const item = document.createElement("div");
  item.className = "buf-item" + (key === activeBuf ? " active" : "");

  const label = document.createElement("span");
  label.className = "buf-name";
  if (key !== "*status" && e2ee.isBufferEncrypted(buf.name)) {
    const lock = document.createElement("span");
    lock.className = "buf-lock";
    lock.textContent = "🔒";
    label.appendChild(lock);
  }
  label.appendChild(document.createTextNode(buf.name === "*status" ? "Server" : buf.name));
  item.appendChild(label);

  const right = document.createElement("span");
  right.className = "buf-right";
  if (buf.unread > 0) {
    const b = document.createElement("span");
    b.className = "buf-badge" + (buf.mentions > 0 ? " mention" : "");
    b.textContent = String(buf.unread);
    right.appendChild(b);
  }
  if (key !== "*status") {
    const close = document.createElement("button");
    close.type = "button";
    close.className = "buf-close";
    close.title = isChan(buf.name) ? "Leave channel" : "Close conversation";
    close.textContent = "×";
    close.onclick = (ev) => {
      ev.stopPropagation();
      if (isChan(buf.name)) {
        sendRaw(`PART ${buf.name}`);
      } else {
        buffers.delete(key);
        if (activeBuf === key) switchBuf("*status");
        else renderBuffers();
      }
    };
    right.appendChild(close);
  }
  item.appendChild(right);
  item.onclick = () => switchBuf(key);
  return item;
}

function renderBuffers(): void {
  const chansWrap = $("channel-list");
  const dmsWrap = $("dm-list");
  chansWrap.textContent = "";
  dmsWrap.textContent = "";

  const statusBuf = buffers.get("*status");
  if (statusBuf) chansWrap.appendChild(buildBufRow(statusBuf, "*status"));

  const chans: Array<[string, BufferState]> = [];
  const dms: Array<[string, BufferState]> = [];
  buffers.forEach((buf, key) => {
    if (key === "*status") return;
    if (isChan(buf.name)) chans.push([key, buf]);
    else dms.push([key, buf]);
  });
  chans.sort((a, b) => a[0].localeCompare(b[0]));
  dms.sort((a, b) => a[0].localeCompare(b[0]));

  for (const [k, b] of chans) chansWrap.appendChild(buildBufRow(b, k));
  for (const [k, b] of dms) dmsWrap.appendChild(buildBufRow(b, k));
}

function roleRank(prefix: string): number {
  if (prefix.includes("@")) return 0;
  if (prefix.includes("+")) return 1;
  return 2;
}

function renderMembers(): void {
  const buf = buffers.get(activeBuf);
  const list = $("members-list");
  list.textContent = "";
  if (!buf || !isChan(buf.name)) {
    $("members-title").textContent = "Members";
    return;
  }
  const q = memberFilter.toLowerCase();
  const sorted = Array.from(buf.members.entries())
    .filter(([nick]) => !q || nick.toLowerCase().includes(q))
    .sort((a, b) => {
      const r = roleRank(a[1]) - roleRank(b[1]);
      return r !== 0 ? r : a[0].localeCompare(b[0]);
    });
  $("members-title").textContent = `Members (${buf.members.size})`;
  for (const [nick, prefix] of sorted) {
    const row = document.createElement("div");
    row.className = "member-item";
    const dot = document.createElement("span");
    dot.className = "member-dot";
    dot.style.backgroundColor = nickColor(nick);
    row.appendChild(dot);

    if (prefix) {
      const role = document.createElement("span");
      role.className = "member-role";
      role.textContent = prefix;
      row.appendChild(role);
    }
    const name = document.createElement("span");
    name.className = "member-name";
    name.textContent = nick;
    row.appendChild(name);

    row.onclick = () => {
      if (nick.toLowerCase() !== myNick.toLowerCase()) {
        ensureBuf(nick);
        switchBuf(nick.toLowerCase());
      }
    };
    list.appendChild(row);
  }
}

function sendRaw(line: string): void {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(line);
  }
}

function handleMessage(raw: string): void {
  const msg = parseIrc(raw);
  if (!msg) return;
  const time = msg.tags.time;
  const { command, params, nick } = msg;

  if (command === "PING") {
    sendRaw(`PONG :${params[0] || ""}`);
    return;
  }
  if (e2ee.handleIrc(msg)) {
    return;
  }
  if (command === "CAP") {
    const sub = (params[1] || "").toUpperCase();
    if (sub === "LS") {
      const more = params[2] === "*";
      const listStr = more ? params[3] || "" : params[2] || "";
      for (const tok of listStr.split(" ").filter(Boolean)) {
        const eq = tok.indexOf("=");
        advertisedCaps.push(eq === -1 ? tok : tok.slice(0, eq));
      }
      if (more) return;
      const wanted = [
        "message-tags",
        "server-time",
        "echo-message",
        "batch",
        "draft/chathistory",
        "draft/multiline",
        "away-notify",
        "account-notify",
        "extended-join",
        E2EE_CAP,
      ];
      if (saslPass) wanted.push("sasl");
      const toReq = wanted.filter((c) => advertisedCaps.includes(c));
      if (toReq.length > 0) sendRaw(`CAP REQ :${toReq.join(" ")}`);
      else sendRaw("CAP END");
    } else if (sub === "ACK") {
      const acked = (params[2] || "").split(" ").filter(Boolean);
      if (acked.includes(E2EE_CAP)) e2ee.setServerSupported(true);
      if (saslPass && acked.includes("sasl")) {
        sendRaw("AUTHENTICATE PLAIN");
      } else {
        sendRaw("CAP END");
      }
    } else if (sub === "NAK") {
      sendRaw("CAP END");
    }
    return;
  }
  if (command === "AUTHENTICATE" && params[0] === "+") {
    const auth = btoa(`\0${saslUser || myNick}\0${saslPass}`);
    sendRaw(`AUTHENTICATE ${auth}`);
    return;
  }
  if (command === "900") {
    if (params[2]) e2ee.setAccount(params[2]);
    return;
  }
  if (command === "903") {
    if (saslUser || myNick) e2ee.setAccount(saslUser || myNick);
    addLine("*status", { time, text: params[1] || "SASL authentication successful", kind: "sys" });
    sendRaw("CAP END");
    return;
  }
  if (command === "904" || command === "905") {
    addLine("*status", { time, text: `SASL failed: ${params[1] || ""}`, kind: "err" });
    sendRaw("CAP END");
    return;
  }
  if (command === "001") {
    myNick = params[0] || myNick;
    isRegistered = true;
    $("my-nick").textContent = myNick;
    e2ee.setMyNick(myNick);
    e2ee.onRegistered();
    updateTitle();
    addLine("*status", { time, text: params[1] || "Connected", kind: "sys" });
    for (const ch of autoChannels) sendRaw(`JOIN ${ch}`);
    return;
  }
  if (command === "JOIN") {
    const chan = params[0];
    const buf = ensureBuf(chan);
    buf.members.set(nick, "");
    if (nick.toLowerCase() === myNick.toLowerCase()) {
      switchBuf(chan.toLowerCase());
      sendRaw(`CHATHISTORY LATEST ${chan} * 50`);
    }
    if (settings.joinPart) addLine(chan, { time, text: `${nick} joined ${chan}`, kind: "sys" });
    renderMembers();
    return;
  }
  if (command === "PART") {
    const chan = params[0];
    const buf = buffers.get(chan.toLowerCase());
    if (buf) {
      buf.members.delete(nick);
      if (nick.toLowerCase() === myNick.toLowerCase()) {
        buffers.delete(chan.toLowerCase());
        if (activeBuf === chan.toLowerCase()) switchBuf("*status");
        else renderBuffers();
      } else {
        e2ee.onMemberLeft(chan);
        if (settings.joinPart) {
          addLine(chan, { time, text: `${nick} left (${params[1] || ""})`, kind: "sys" });
        }
        renderMembers();
      }
    }
    return;
  }
  if (command === "QUIT") {
    buffers.forEach((buf) => {
      if (buf.members.has(nick)) {
        buf.members.delete(nick);
        if (isChan(buf.name)) e2ee.onMemberLeft(buf.name);
        if (settings.joinPart) {
          addLine(buf.name, { time, text: `${nick} quit (${params[0] || ""})`, kind: "sys" });
        }
      }
    });
    renderMembers();
    return;
  }
  if (command === "NICK") {
    const next = params[0];
    if (nick.toLowerCase() === myNick.toLowerCase()) {
      myNick = next;
      $("my-nick").textContent = myNick;
      e2ee.setMyNick(myNick);
    }
    buffers.forEach((buf) => {
      if (buf.members.has(nick)) {
        const pfx = buf.members.get(nick) || "";
        buf.members.delete(nick);
        buf.members.set(next, pfx);
        addLine(buf.name, { time, text: `${nick} is now known as ${next}`, kind: "sys" });
      }
    });
    renderMembers();
    return;
  }
  if (command === "332") {
    const chan = params[1];
    const buf = ensureBuf(chan);
    buf.topic = params[2] || "";
    if (activeBuf === chan.toLowerCase()) $("active-topic").textContent = buf.topic;
    addLine(chan, { time, text: `Topic: ${buf.topic}`, kind: "sys" });
    return;
  }
  if (command === "TOPIC") {
    const chan = params[0];
    const buf = ensureBuf(chan);
    buf.topic = params[1] || "";
    if (activeBuf === chan.toLowerCase()) $("active-topic").textContent = buf.topic;
    addLine(chan, { time, text: `${nick} set topic: ${buf.topic}`, kind: "sys" });
    return;
  }
  if (command === "353") {
    const chan = params[2];
    const buf = ensureBuf(chan);
    for (const entry of (params[3] || "").split(" ").filter(Boolean)) {
      const m = entry.match(/^([@+%~&]*)(.+)$/);
      if (m) buf.members.set(m[2], m[1]);
    }
    renderMembers();
    return;
  }
  if (command === "MODE") {
    const target = params[0];
    if (isChan(target)) {
      addLine(target, {
        time,
        text: `${nick || msg.prefix} set mode ${params.slice(1).join(" ")}`,
        kind: "sys",
      });
      sendRaw(`NAMES ${target}`);
    } else {
      addLine("*status", { time, text: `Mode ${target} ${params.slice(1).join(" ")}`, kind: "sys" });
    }
    return;
  }
  if (command === "INVITE") {
    addLine("*status", { time, text: `${nick} invited you to ${params[1]}`, kind: "sys" });
    return;
  }
  if (command === "PRIVMSG" || command === "NOTICE") {
    const target = params[0] || "*status";
    const text = params[1] || "";
    const dest = isChan(target)
      ? target
      : nick.toLowerCase() === myNick.toLowerCase()
        ? target
        : nick || "*status";
    if (text.startsWith("\x01ACTION ") && text.endsWith("\x01")) {
      addLine(dest, { time, text: `* ${nick} ${text.slice(8, -1)}`, kind: "action" });
    } else {
      addLine(dest, {
        time,
        nick: nick || msg.prefix,
        text,
        kind: command === "NOTICE" ? "notice" : "",
      });
    }
    return;
  }
  if (command === "KICK") {
    const chan = params[0];
    const victim = params[1];
    const buf = buffers.get(chan.toLowerCase());
    if (buf) buf.members.delete(victim);
    if (victim.toLowerCase() !== myNick.toLowerCase()) e2ee.onMemberLeft(chan);
    addLine(chan, {
      time,
      text: `${victim} was kicked by ${nick} (${params[2] || ""})`,
      kind: "err",
    });
    renderMembers();
    return;
  }
  if (command === "ERROR" || command === "FAIL") {
    addLine("*status", { time, text: `${command}: ${params.join(" ")}`, kind: "err" });
    return;
  }
  if (command === "322") {
    addLine("*status", {
      time,
      text: `${params[1]} (${params[2]} users) ${params[3] || ""}`,
      kind: "sys",
    });
    return;
  }
  if (/^\d{3}$/.test(command)) {
    if (["366", "002", "003", "004", "005", "375", "376"].includes(command)) return;
    addLine("*status", { time, text: `[${command}] ${params.slice(1).join(" ")}`, kind: "sys" });
  }
}

function connectSocket(url: string): void {
  lastWsUrl = url;
  if (ws) {
    try {
      ws.close();
    } catch {
      // ignore
    }
  }
  ws = new WebSocket(url, ["text.ircv3.net"]);
  $("status-dot").classList.remove("off");
  $("btn-reconnect").style.display = "none";
  addLine("*status", { text: `Connecting to ${url}...`, kind: "sys" });

  ws.onopen = () => {
    advertisedCaps = [];
    e2ee.resetConnection();
    sendRaw("CAP LS 302");
    sendRaw(`NICK ${myNick}`);
    sendRaw(`USER ${myNick} 0 * :${myNick}`);
  };
  ws.onmessage = (e) => {
    if (typeof e.data === "string") handleMessage(e.data);
  };
  ws.onerror = () => {
    addLine("*status", { text: "WebSocket connection error.", kind: "err" });
  };
  ws.onclose = () => {
    isRegistered = false;
    hiddenUnread = 0;
    hiddenMentions = 0;
    e2ee.resetConnection();
    updateTitle();
    $("status-dot").classList.add("off");
    $("btn-reconnect").style.display = "inline-flex";
    addLine("*status", { text: "Disconnected from server.", kind: "err" });
  };
}

function showHelp(target: string): void {
  const cmds = [
    "/join #chan [key]  (/j)",
    "/part [#chan] [reason]  (/leave)",
    "/msg <target> <text>  (/query, /pm)",
    "/notice <target> <text>",
    "/me <action>",
    "/nick <newnick>",
    "/topic [new topic]",
    "/mode <target> [modes...]",
    "/kick <nick> [reason]",
    "/invite <nick> [#chan]",
    "/whois <nick> | /whowas <nick> | /who [mask]",
    "/names [#chan] | /list [filter]",
    "/away [message] | /back | /setname <realname>",
    "/monitor +|- <nick> | /history [limit]",
    "/e2ee [on|off|status|rotate|verify|reset]",
    "/oper <name> <pass> | /kill <nick> <reason> | /rehash",
    "/clear | /raw <line> | /quit [reason]",
  ];
  addLine(target, { text: `Commands:\n${cmds.join("\n")}`, kind: "sys" });
}

function runSlashCommand(raw: string, buf: BufferState | undefined): void {
  const target = buf ? buf.name : "*status";
  const sp = raw.indexOf(" ");
  const cmd = (sp === -1 ? raw.slice(1) : raw.slice(1, sp)).toLowerCase();
  const rest = sp === -1 ? "" : raw.slice(sp + 1).trim();

  switch (cmd) {
    case "help":
      showHelp(target);
      return;
    case "j":
    case "join":
      if (rest) sendRaw(`JOIN ${isChan(rest) ? rest : `#${rest}`}`);
      return;
    case "leave":
    case "part": {
      if (rest && isChan(rest)) {
        const s2 = rest.indexOf(" ");
        if (s2 === -1) sendRaw(`PART ${rest}`);
        else sendRaw(`PART ${rest.slice(0, s2)} :${rest.slice(s2 + 1)}`);
      } else if (buf && isChan(buf.name)) {
        sendRaw(`PART ${buf.name}${rest ? ` :${rest}` : ""}`);
      }
      return;
    }
    case "msg":
    case "pm":
    case "query": {
      const s2 = rest.indexOf(" ");
      if (s2 > 0) {
        const dest = rest.slice(0, s2);
        const text = rest.slice(s2 + 1);
        ensureBuf(dest);
        switchBuf(dest.toLowerCase());
        sendRaw(`PRIVMSG ${dest} :${text}`);
      } else if (rest) {
        ensureBuf(rest);
        switchBuf(rest.toLowerCase());
      }
      return;
    }
    case "notice": {
      const s2 = rest.indexOf(" ");
      if (s2 > 0) sendRaw(`NOTICE ${rest.slice(0, s2)} :${rest.slice(s2 + 1)}`);
      return;
    }
    case "me":
      if (rest && buf && buf.name !== "*status") {
        sendRaw(`PRIVMSG ${buf.name} :\x01ACTION ${rest}\x01`);
      }
      return;
    case "nick":
      if (rest) sendRaw(`NICK ${rest}`);
      return;
    case "topic":
      if (buf && isChan(buf.name)) {
        sendRaw(rest ? `TOPIC ${buf.name} :${rest}` : `TOPIC ${buf.name}`);
      }
      return;
    case "mode":
      if (rest) sendRaw(`MODE ${rest}`);
      else if (buf && isChan(buf.name)) sendRaw(`MODE ${buf.name}`);
      return;
    case "kick":
      if (buf && isChan(buf.name) && rest) {
        const s2 = rest.indexOf(" ");
        if (s2 === -1) sendRaw(`KICK ${buf.name} ${rest}`);
        else sendRaw(`KICK ${buf.name} ${rest.slice(0, s2)} :${rest.slice(s2 + 1)}`);
      }
      return;
    case "invite": {
      const parts = rest.split(/\s+/).filter(Boolean);
      if (parts.length >= 2) sendRaw(`INVITE ${parts[0]} ${parts[1]}`);
      else if (parts.length === 1 && buf && isChan(buf.name)) {
        sendRaw(`INVITE ${parts[0]} ${buf.name}`);
      }
      return;
    }
    case "whois":
      if (rest) sendRaw(`WHOIS ${rest}`);
      return;
    case "whowas":
      if (rest) sendRaw(`WHOWAS ${rest}`);
      return;
    case "who":
      sendRaw(rest ? `WHO ${rest}` : buf && isChan(buf.name) ? `WHO ${buf.name}` : "WHO");
      return;
    case "names":
      if (rest) sendRaw(`NAMES ${rest}`);
      else if (buf && isChan(buf.name)) sendRaw(`NAMES ${buf.name}`);
      return;
    case "list":
      sendRaw(rest ? `LIST ${rest}` : "LIST");
      return;
    case "away":
      sendRaw(rest ? `AWAY :${rest}` : "AWAY");
      return;
    case "back":
      sendRaw("AWAY");
      return;
    case "setname":
      if (rest) sendRaw(`SETNAME :${rest}`);
      return;
    case "monitor":
      if (rest) sendRaw(`MONITOR ${rest}`);
      return;
    case "history": {
      const limit = parseInt(rest, 10) || 50;
      if (buf && buf.name !== "*status") {
        sendRaw(`CHATHISTORY LATEST ${buf.name} * ${Math.min(Math.max(limit, 1), 200)}`);
      }
      return;
    }
    case "clear":
      if (buf) {
        buf.lines = [];
        $("messages").textContent = "";
      }
      return;
    case "e2ee": {
      const parts = rest.split(/\s+/).filter(Boolean);
      const sub = (parts[0] || "status").toLowerCase();
      if (sub === "on") {
        if (buf && buf.name !== "*status" && e2ee.setBufferEncrypted(buf.name, true)) {
          addLine(buf.name, { text: "End-to-end encryption enabled.", kind: "sys" });
        }
      } else if (sub === "off") {
        if (buf && buf.name !== "*status") {
          e2ee.setBufferEncrypted(buf.name, false);
          addLine(buf.name, { text: "End-to-end encryption disabled.", kind: "sys" });
        }
      } else if (sub === "rotate") {
        if (buf && isChan(buf.name)) void e2ee.rotateChannelKey(buf.name);
        else addLine(target, { text: "Switch to a channel to rotate its Sender Key.", kind: "err" });
      } else if (sub === "verify") {
        const who = (parts[1] || (!isChan(target) && target !== "*status" ? target : "")).toLowerCase();
        const st = e2ee.getStatus();
        const matches = who
          ? st.trustedPeers.filter((p) => p.account === who)
          : st.trustedPeers;
        if (matches.length === 0) {
          addLine(target, { text: "No pinned E2EE peer devices found.", kind: "sys" });
        } else {
          for (const p of matches) {
            addLine(target, {
              text: `Safety # for ${p.account} (device ${p.device}): ${p.safetyNumber}`,
              kind: "sys",
            });
          }
        }
      } else if (sub === "reset") {
        e2ee.resetDevice();
        addLine(target, { text: "E2EE device keys reset.", kind: "sys" });
      } else {
        openE2eeModal();
      }
      return;
    }
    case "oper": {
      const parts = rest.split(/\s+/).filter(Boolean);
      if (parts.length >= 2) sendRaw(`OPER ${parts[0]} ${parts[1]}`);
      return;
    }
    case "kill": {
      const s2 = rest.indexOf(" ");
      if (s2 > 0) sendRaw(`KILL ${rest.slice(0, s2)} :${rest.slice(s2 + 1)}`);
      return;
    }
    case "rehash":
      sendRaw("REHASH");
      return;
    case "raw":
    case "quote":
      if (rest) sendRaw(rest);
      return;
    case "quit":
      sendRaw(`QUIT :${rest || "Leaving WebIRC"}`);
      return;
    default:
      addLine(target, { text: `Unknown command: /${cmd} (try /help)`, kind: "err" });
  }
}

$<HTMLFormElement>("connect-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  const err = $("connect-err");
  err.style.display = "none";
  myNick = $<HTMLInputElement>("inp-nick").value.trim();
  saslUser = $<HTMLInputElement>("inp-acct").value.trim();
  saslPass = $<HTMLInputElement>("inp-pass").value;
  autoChannels = $<HTMLInputElement>("inp-channels").value
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const url = $<HTMLInputElement>("inp-ws").value.trim();
  try {
    buffers.clear();
    ensureBuf("*status");
    $("connect-view").style.display = "none";
    $("chat-view").classList.add("active");
    $("my-nick").textContent = myNick;
    switchBuf("*status");
    connectSocket(url);
  } catch (e) {
    err.textContent = `Invalid WebSocket URL: ${e instanceof Error ? e.message : String(e)}`;
    err.style.display = "block";
    $("chat-view").classList.remove("active");
    $("connect-view").style.display = "flex";
  }
});

$("btn-reconnect").onclick = () => {
  if (lastWsUrl) connectSocket(lastWsUrl);
};

$("btn-topic").onclick = () => {
  const buf = buffers.get(activeBuf);
  if (!buf || !isChan(buf.name)) return;
  const next = prompt(`Topic for ${buf.name}:`, buf.topic || "");
  if (next !== null) sendRaw(`TOPIC ${buf.name} :${next}`);
};

$("btn-disconnect").onclick = () => {
  isRegistered = false;
  hiddenUnread = 0;
  hiddenMentions = 0;
  if (ws && ws.readyState === WebSocket.OPEN) {
    sendRaw("QUIT :Leaving WebIRC");
    ws.close();
  }
  ws = null;
  updateTitle();
  $("chat-view").classList.remove("active");
  $("connect-view").style.display = "flex";
};

$<HTMLFormElement>("join-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  const inp = $<HTMLInputElement>("inp-join");
  const ch = inp.value.trim();
  if (!ch) return;
  sendRaw(`JOIN ${isChan(ch) ? ch : `#${ch}`}`);
  inp.value = "";
});

$<HTMLInputElement>("inp-member-filter").addEventListener("input", (ev) => {
  memberFilter = (ev.target as HTMLInputElement).value.trim();
  renderMembers();
});

const msgInp = $<HTMLInputElement>("inp-msg");

msgInp.addEventListener("keydown", (ev) => {
  if (ev.key === "Tab") {
    const buf = buffers.get(activeBuf);
    if (!buf || !isChan(buf.name)) return;
    const val = msgInp.value;
    const lastSpace = val.lastIndexOf(" ");
    const prefix = val.slice(lastSpace + 1);
    if (!prefix) return;
    const match = Array.from(buf.members.keys()).find((n) =>
      n.toLowerCase().startsWith(prefix.toLowerCase()),
    );
    if (match) {
      ev.preventDefault();
      const suffix = lastSpace === -1 ? ": " : " ";
      msgInp.value = val.slice(0, lastSpace + 1) + match + suffix;
    }
  } else if (ev.key === "ArrowUp" && !ev.altKey) {
    if (sentHistory.length > 0) {
      ev.preventDefault();
      histPos = Math.min(histPos + 1, sentHistory.length - 1);
      msgInp.value = sentHistory[sentHistory.length - 1 - histPos];
    }
  } else if (ev.key === "ArrowDown" && !ev.altKey) {
    if (histPos > 0) {
      ev.preventDefault();
      histPos -= 1;
      msgInp.value = sentHistory[sentHistory.length - 1 - histPos];
    } else if (histPos === 0) {
      ev.preventDefault();
      histPos = -1;
      msgInp.value = "";
    }
  }
});

document.addEventListener("keydown", (ev) => {
  if (!ev.altKey || (ev.key !== "ArrowUp" && ev.key !== "ArrowDown")) return;
  const keys = Array.from(buffers.keys());
  if (keys.length < 2) return;
  ev.preventDefault();
  const idx = keys.indexOf(activeBuf);
  const delta = ev.key === "ArrowDown" ? 1 : -1;
  switchBuf(keys[(idx + delta + keys.length) % keys.length]);
});

$<HTMLFormElement>("send-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  const raw = msgInp.value;
  if (!raw.trim()) return;
  msgInp.value = "";
  sentHistory.push(raw);
  if (sentHistory.length > 100) sentHistory.shift();
  histPos = -1;

  const buf = buffers.get(activeBuf);
  if (raw.startsWith("/")) {
    runSlashCommand(raw, buf);
    return;
  }
  if (!buf || buf.name === "*status") {
    addLine("*status", { text: "Join a channel first (e.g. /join #lobby) or type /help.", kind: "err" });
    return;
  }
  if (e2ee.isBufferEncrypted(buf.name)) {
    const dest = buf.name;
    void e2ee.sendEncrypted(dest, raw).then((ok) => {
      if (ok) addLine(dest, { nick: myNick, text: raw, encrypted: true });
    });
    return;
  }
  sendRaw(`PRIVMSG ${buf.name} :${raw}`);
});
