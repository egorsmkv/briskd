import { byId as $, errorMessage, postJson } from "./common/dom.ts";
import { initAltcha } from "./common/altcha.ts";
import { dayKey, formatDayLabel, renderIrcMessage } from "./common/format.ts";
import { currentLang, initLang, setLang, t } from "./common/i18n.ts";
import { currentTheme, initTheme, setTheme, THEMES } from "./common/theme.ts";
import { updateDynamicFavicon } from "./common/favicon.ts";
import { createRemoteCodeCard } from "./common/code_card.ts";
import {
  createAlbumGrid,
  createEncryptedAttachmentView,
  createFileCard,
  E2EE_ATT_PREFIX,
  type E2eeAttachmentItem,
  formatBytes,
  isPreviewImageId,
  parseE2eeAttachment,
} from "./common/file_card.ts";
import {
  createLinkPreviewSlot,
  extractFirstHttpUrl,
} from "./common/link_preview.ts";
import { createVoicePlayer } from "./common/voice_player.ts";
import { encryptAttachment } from "./e2ee/crypto.ts";
import { E2EE_CAP, E2eeManager } from "./e2ee/manager.ts";

interface WebircSettings {
  layout: "auto" | "mobile" | "desktop";
  density: "comfortable" | "compact";
  fontSize: "small" | "normal" | "large";
  timestamps: boolean;
  joinPart: boolean;
  notifyMentions: boolean;
  reactions: boolean;
  replies: boolean;
  typing: boolean;
  editing: boolean;
  redaction: boolean;
  linkPreviews: boolean;
}

type FeatureKey =
  | "reactions"
  | "replies"
  | "typing"
  | "editing"
  | "redaction"
  | "link_previews";

const SETTINGS_KEY = "ircd-webirc-settings";

function loadSettings(): WebircSettings {
  const defaults: WebircSettings = {
    layout: "auto",
    density: "comfortable",
    fontSize: "normal",
    timestamps: true,
    joinPart: true,
    notifyMentions: false,
    reactions: true,
    replies: true,
    typing: true,
    editing: true,
    redaction: true,
    linkPreviews: true,
  };
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    if (!raw) return defaults;
    const parsed = JSON.parse(raw) as Partial<WebircSettings>;
    return {
      layout: parsed.layout === "mobile" || parsed.layout === "desktop"
        ? parsed.layout
        : "auto",
      density: parsed.density === "compact" ? "compact" : "comfortable",
      fontSize: parsed.fontSize === "small" || parsed.fontSize === "large"
        ? parsed.fontSize
        : "normal",
      timestamps: parsed.timestamps !== false,
      joinPart: parsed.joinPart !== false,
      notifyMentions: parsed.notifyMentions === true,
      reactions: parsed.reactions !== false,
      replies: parsed.replies !== false,
      typing: parsed.typing !== false,
      editing: parsed.editing !== false,
      redaction: parsed.redaction !== false,
      linkPreviews: parsed.linkPreviews !== false,
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
  msgid?: string;
  account?: string;
  replyTo?: string;
  edited?: boolean;
  redacted?: boolean;
  reactions?: Map<string, Set<string>>;
  voiceId?: string;
  voiceDur?: number;
  fileId?: string;
  fileName?: string;
  fileSize?: number;
  albumIds?: string[];
  pasteId?: string;
  pasteLang?: string;
  pasteTitle?: string;
}

const FEATURES_CAP = "egorsmkv.github.io/features";
const REDACT_CAP = "draft/message-redaction";
const REACT_TAG = "+draft/react";
const REPLY_TAG = "+draft/reply";
const TYPING_TAG = "+typing";
const EDIT_TAG = "+egorsmkv.github.io/edit";
const SAFE_MSGID_RE = /^[A-Za-z0-9._-]{1,128}$/;
const MAX_REACTIONS_PER_MSG = 20;
const MAX_TYPERS_PER_BUF = 20;
const QUICK_EMOJIS = ["👍", "❤️", "😂", "🔥"] as const;

const serverFeatures: Record<FeatureKey, boolean> = {
  reactions: true,
  replies: true,
  typing: true,
  editing: true,
  redaction: true,
  link_previews: true,
};

function featureOn(key: FeatureKey): boolean {
  if (key === "link_previews") {
    return serverFeatures.link_previews && settings.linkPreviews;
  }
  return serverFeatures[key] && settings[key];
}

const PASTE_TAG = "+egorsmkv.github.io/paste";
const PASTE_LANG_TAG = "+egorsmkv.github.io/paste-lang";
const PASTE_TITLE_TAG = "+egorsmkv.github.io/paste-title";

const VOICE_CAP = "egorsmkv.github.io/voice";
const VOICE_TAG = "+egorsmkv.github.io/voice";
const VOICE_DUR_TAG = "+egorsmkv.github.io/voice-dur";
const VOICE_ID_RE = /^[0-9a-f]{32}\.(ogg|webm)$/;

const FILES_CAP = "egorsmkv.github.io/files";
const FILE_TAG = "+egorsmkv.github.io/file";
const FILE_NAME_TAG = "+egorsmkv.github.io/file-name";
const FILE_SIZE_TAG = "+egorsmkv.github.io/file-size";
const ALBUM_TAG = "+egorsmkv.github.io/album";
const FILE_ID_RE = /^[0-9a-f]{32}\.[a-z0-9]{1,8}$/;

function fmtDuration(sec?: number): string {
  const s = Math.max(0, Math.floor(sec || 0));
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${r < 10 ? "0" : ""}${r}`;
}

interface BufferState {
  name: string;
  topic: string;
  lines: ChatLine[];
  unread: number;
  mentions: number;
  members: Map<string, string>;
  modes: Set<string>;
  bans: string[];
}

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
  const nick = prefix.includes("!")
    ? prefix.slice(0, prefix.indexOf("!"))
    : prefix;
  return { tags, prefix, nick, command, params };
}

initTheme([], {
  defaultTheme: "hacker",
  storageKey: "ircd-webirc-theme",
});
initLang();

const settings: WebircSettings = loadSettings();

function applySettings(): void {
  document.body.classList.toggle("layout-mobile", settings.layout === "mobile");
  document.body.classList.toggle(
    "layout-desktop",
    settings.layout === "desktop",
  );
  document.body.classList.toggle(
    "density-compact",
    settings.density === "compact",
  );
  document.body.classList.toggle("hide-timestamps", !settings.timestamps);
  document.body.classList.toggle("font-small", settings.fontSize === "small");
  document.body.classList.toggle("font-large", settings.fontSize === "large");
  $<HTMLSelectElement>("opt-lang").value = currentLang();
  $<HTMLSelectElement>("opt-layout").value = settings.layout;
  $<HTMLSelectElement>("opt-density").value = settings.density;
  $<HTMLSelectElement>("opt-fontsize").value = settings.fontSize;
  $<HTMLInputElement>("opt-timestamps").checked = settings.timestamps;
  $<HTMLInputElement>("opt-joinpart").checked = settings.joinPart;
  $<HTMLInputElement>("opt-notify").checked = settings.notifyMentions;
  $<HTMLInputElement>("opt-reactions").checked = settings.reactions;
  $<HTMLInputElement>("opt-replies").checked = settings.replies;
  $<HTMLInputElement>("opt-typing").checked = settings.typing;
  $<HTMLInputElement>("opt-editing").checked = settings.editing;
  $<HTMLInputElement>("opt-redaction").checked = settings.redaction;
  $<HTMLInputElement>("opt-link-previews").checked = settings.linkPreviews;
  $<HTMLInputElement>("opt-link-previews").disabled = !serverFeatures
    .link_previews;
  for (
    const key of [
      "reactions",
      "replies",
      "typing",
      "editing",
      "redaction",
    ] as const
  ) {
    const el = $<HTMLInputElement>(`opt-${key}`);
    el.disabled = !serverFeatures[key];
  }
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
      setTheme(t.id);
      renderThemeSwatches();
    };
    grid.appendChild(btn);
  }
}

function switchSettingsTab(tab: "general" | "e2ee"): void {
  const isE2ee = tab === "e2ee";
  $("tab-settings-general").classList.toggle("active", !isE2ee);
  $("tab-settings-general").setAttribute("aria-selected", String(!isE2ee));
  $("tab-settings-e2ee").classList.toggle("active", isE2ee);
  $("tab-settings-e2ee").setAttribute("aria-selected", String(isE2ee));
  $("pane-settings-general").classList.toggle("active", !isE2ee);
  $("pane-settings-e2ee").classList.toggle("active", isE2ee);
  if (isE2ee) renderE2eeModal();
}

function openSettings(tab: "general" | "e2ee" = "general"): void {
  renderThemeSwatches();
  applySettings();
  switchSettingsTab(tab);
  $("settings-modal").classList.add("open");
}

function closeSettings(): void {
  $("settings-modal").classList.remove("open");
}

applySettings();
$("btn-settings-1").onclick = () => openSettings("general");
$("btn-settings-2").onclick = () => openSettings("general");
$("btn-close-settings").onclick = closeSettings;
$("tab-settings-general").onclick = () => switchSettingsTab("general");
$("tab-settings-e2ee").onclick = () => switchSettingsTab("e2ee");
$("settings-modal").addEventListener("click", (ev) => {
  if (ev.target === $("settings-modal")) closeSettings();
});
document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape") {
    closeSettings();
    closeTopicModal();
    closeCodeModal();
    closeModModal();
    closeAttachMenu();
    closeDiscoverModal();
    clearComposeMode();
  }
});

$<HTMLSelectElement>("opt-lang").onchange = (ev) => {
  const v = (ev.target as HTMLSelectElement).value;
  setLang(v === "he" ? "he" : "en");
  updateE2eeUi();
  renderBuffers();
  renderMembers();
  if ($("settings-modal").classList.contains("open")) renderE2eeModal();
  const buf = buffers.get(activeBuf);
  if (buf) {
    $("active-title").textContent = buf.name === "*status"
      ? t("status.title")
      : buf.name;
    $("active-topic").textContent = buf.topic ||
      (isChan(buf.name) ? t("topic.none") : "");
  }
};
$<HTMLSelectElement>("opt-layout").onchange = (ev) => {
  const v = (ev.target as HTMLSelectElement).value;
  settings.layout = v === "mobile" || v === "desktop" ? v : "auto";
  saveSettings(settings);
  applySettings();
  closeDrawers();
};

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
  if (
    checked && typeof Notification !== "undefined" &&
    Notification.permission === "default"
  ) {
    try {
      await Notification.requestPermission();
    } catch {
      // ignore
    }
  }
  settings.notifyMentions = checked;
  saveSettings(settings);
};

for (
  const key of [
    "reactions",
    "replies",
    "typing",
    "editing",
    "redaction",
  ] as const
) {
  $<HTMLInputElement>(`opt-${key}`).onchange = (ev) => {
    settings[key] = (ev.target as HTMLInputElement).checked;
    saveSettings(settings);
    if (!featureOn("typing")) renderTypingBar();
    if (!featureOn("replies") && composeMode?.kind === "reply") {
      clearComposeMode();
    }
    if (!featureOn("editing") && composeMode?.kind === "edit") {
      clearComposeMode();
    }
    renderActiveMessages();
  };
}
$<HTMLInputElement>("opt-link-previews").onchange = (ev) => {
  settings.linkPreviews = (ev.target as HTMLInputElement).checked;
  saveSettings(settings);
  renderActiveMessages();
};

const bodyData = document.body.dataset;
const WS_PORT = bodyData.wsPort || "";
const WSS_PORT = bodyData.wssPort || "";
const BASE_TITLE = document.title;

interface SavedSession {
  nick: string;
  acct: string;
  pass: string;
  channels: string[];
  wsUrl: string;
  activeBuf: string;
}

const SESSION_KEY = "ircd-webirc-session";

function bufferToPath(name: string): string {
  if (name === "*status") return "/status";
  if (isChan(name)) {
    const clean = name.startsWith("#") ? name.slice(1) : name;
    return `/channel/${encodeURIComponent(clean)}`;
  }
  return `/dm/${encodeURIComponent(name)}`;
}

const MAX_BUFFERS = 100;

function isSafeIrcTarget(s: string): boolean {
  if (s.length < 1 || s.length > 50) return false;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c <= 0x20 || c === 0x2c || c === 0x7f) return false;
  }
  return true;
}

function pathToBuffer(pathname: string): string | null {
  if (pathname === "/status") return "*status";
  const cm = pathname.match(/^\/channel\/([^/]+)\/?$/);
  if (cm) {
    try {
      const dec = decodeURIComponent(cm[1]).trim();
      if (dec && isSafeIrcTarget(dec)) {
        return isChan(dec) ? dec : `#${dec}`;
      }
    } catch {
      return null;
    }
  }
  const dm = pathname.match(/^\/dm\/([^/]+)\/?$/);
  if (dm) {
    try {
      const dec = decodeURIComponent(dm[1]).trim();
      if (dec && !isChan(dec) && isSafeIrcTarget(dec)) return dec;
    } catch {
      return null;
    }
  }
  return null;
}

function saveSession(): void {
  if (!myNick || !lastWsUrl) return;
  const chans: string[] = [];
  buffers.forEach((b) => {
    if (isChan(b.name)) chans.push(b.name);
  });
  const payload: SavedSession = {
    nick: myNick,
    acct: saslUser,
    pass: saslPass,
    channels: chans.length > 0 ? chans : autoChannels,
    wsUrl: lastWsUrl,
    activeBuf,
  };
  try {
    sessionStorage.setItem(SESSION_KEY, JSON.stringify(payload));
  } catch {
    // ignore storage errors
  }
}

function loadSession(): SavedSession | null {
  try {
    const raw = sessionStorage.getItem(SESSION_KEY);
    if (!raw) return null;
    const p = JSON.parse(raw) as Partial<SavedSession>;
    if (!p.nick || !p.wsUrl) return null;
    return {
      nick: p.nick,
      acct: p.acct || "",
      pass: p.pass || "",
      channels: Array.isArray(p.channels) ? p.channels.filter(Boolean) : [],
      wsUrl: p.wsUrl,
      activeBuf: p.activeBuf || "*status",
    };
  } catch {
    return null;
  }
}

function clearSession(): void {
  try {
    sessionStorage.removeItem(SESSION_KEY);
  } catch {
    // ignore
  }
}

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
  const pathBuf = pathToBuffer(location.pathname);
  const qChan = new URLSearchParams(location.search).get("channel")?.trim();
  if (pathBuf && isChan(pathBuf)) {
    $<HTMLInputElement>("inp-channels").value = pathBuf;
  } else if (qChan && /^[#&+!]/.test(qChan)) {
    $<HTMLInputElement>("inp-channels").value = qChan;
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
let isIrcOp = false;
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
    if ($("settings-modal").classList.contains("open")) renderE2eeModal();
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
    inp.placeholder = t("ph.msg");
    return;
  }
  btn.style.display = "inline-flex";
  const on = e2ee.isBufferEncrypted(buf.name);
  const ready = e2ee.isReady();
  btn.classList.toggle("on", on);
  btn.textContent = on ? t("e2ee.on") : t("e2ee.off");
  if (!ready) {
    btn.title = e2ee.isServerSupported()
      ? t("e2ee.banner.noacct")
      : t("e2ee.banner.unsupported");
  } else {
    btn.title = on ? t("e2ee.on") : t("e2ee.off");
  }
  form.classList.toggle("e2ee-active", on);
  inp.placeholder = on ? t("ph.msg.e2ee", { target: buf.name }) : t("ph.msg");
}

function renderE2eeModal(): void {
  const st = e2ee.getStatus();
  const banner = $("e2ee-status-banner");
  banner.className = "e2ee-status-banner";
  if (!st.serverSupported) {
    banner.classList.add("warn");
    banner.textContent = t("e2ee.banner.unsupported");
  } else if (!st.account) {
    banner.classList.add("warn");
    banner.textContent = t("e2ee.banner.noacct");
  } else if (!st.bound) {
    banner.textContent = t("e2ee.banner.binding");
  } else {
    banner.classList.add("ok");
    banner.textContent = t("e2ee.banner.active");
  }

  $("e2ee-account").textContent = st.account || "-";
  $("e2ee-device").textContent = st.deviceId ? String(st.deviceId) : "-";
  $("e2ee-prekeys").textContent = st.bound ? String(st.prekeyCount) : "-";
  $("e2ee-sessions").textContent = String(st.sessionCount);
  $("e2ee-fingerprint").textContent = st.fingerprint || "-";

  const buf = buffers.get(activeBuf);
  const canRotate = st.bound && !!buf && isChan(buf.name);
  $<HTMLButtonElement>("btn-e2ee-export").disabled = !st.account;
  $<HTMLButtonElement>("btn-e2ee-import").disabled = !st.account;
  $<HTMLButtonElement>("btn-e2ee-rotate").disabled = !canRotate;
  $<HTMLButtonElement>("btn-e2ee-replenish").disabled = !st.bound;
  $<HTMLButtonElement>("btn-e2ee-reset").disabled = !st.account;

  const peersEl = $("e2ee-peers");
  peersEl.textContent = "";
  if (st.trustedPeers.length === 0) {
    const empty = document.createElement("div");
    empty.className = "e2ee-empty";
    empty.textContent = t("e2ee.peers.empty");
    peersEl.appendChild(empty);
  } else {
    for (const p of st.trustedPeers) {
      const row = document.createElement("div");
      row.className = "e2ee-peer-row";
      const info = document.createElement("div");
      info.className = "e2ee-peer-info";
      const title = document.createElement("div");
      title.className = "peer-id";
      title.textContent = `${p.account} (${p.device})`;
      const sn = document.createElement("div");
      sn.className = "peer-sn";
      sn.dir = "ltr";
      sn.textContent = p.safetyNumber;
      info.appendChild(title);
      info.appendChild(sn);

      const forget = document.createElement("button");
      forget.type = "button";
      forget.className = "small";
      forget.textContent = t("e2ee.forget");
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
$("btn-e2ee-export").onclick = () => {
  const pass = prompt(
    "Enter a passphrase (min 6 characters) to encrypt your E2EE key backup:",
  );
  if (pass === null) return;
  try {
    const { filename, content } = e2ee.exportBackup(pass);
    const blob = new Blob([content], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    addLine("*status", {
      text: `Downloaded encrypted E2EE key backup (${filename}).`,
      kind: "sys",
    });
  } catch (err) {
    alert(errorMessage(err));
  }
};
$("btn-e2ee-import").onclick = () => {
  const fileInp = $<HTMLInputElement>("inp-e2ee-file");
  fileInp.value = "";
  fileInp.click();
};
$<HTMLInputElement>("inp-e2ee-file").onchange = async (ev) => {
  const input = ev.target as HTMLInputElement;
  const file = input.files && input.files[0];
  if (!file) return;
  const pass = prompt("Enter the passphrase for this E2EE key backup:");
  if (pass === null) return;
  try {
    const text = await file.text();
    const res = e2ee.importBackup(text, pass);
    renderE2eeModal();
    addLine("*status", {
      text:
        `Imported E2EE keys for ${res.account} (device ${res.deviceId}) and re-binding...`,
      kind: "sys",
    });
  } catch (err) {
    alert(errorMessage(err));
  }
};
$("btn-e2ee-replenish").onclick = () => {
  e2ee.replenishPrekeys(20);
  addLine("*status", {
    text: "Uploaded 20 fresh E2EE one-time prekeys.",
    kind: "sys",
  });
};
$("btn-e2ee-rotate").onclick = () => {
  const buf = buffers.get(activeBuf);
  if (buf && isChan(buf.name)) void e2ee.rotateChannelKey(buf.name);
};
$("btn-e2ee-reset").onclick = () => {
  if (
    confirm(
      "Reset your E2EE device keys and sessions? Peers will see a new identity key.",
    )
  ) {
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
globalThis.addEventListener("focus", clearHiddenCounters);

function ensureBuf(name: string): BufferState {
  const key = name.toLowerCase();
  let buf = buffers.get(key);
  if (!buf) {
    if (buffers.size >= MAX_BUFFERS) {
      // Evict oldest inactive non-channel DM buffer to prevent DM flood memory exhaustion
      for (const [k, existing] of buffers.entries()) {
        if (k !== "*status" && k !== activeBuf && !isChan(existing.name)) {
          buffers.delete(k);
          break;
        }
      }
    }
    buf = {
      name,
      topic: "",
      lines: [],
      unread: 0,
      mentions: 0,
      members: new Map(),
      modes: new Set(),
      bans: [],
    };
    buffers.set(key, buf);
    renderBuffers();
  }
  return buf;
}

function isMention(text: string, sender: string): boolean {
  if (!myNick || !sender || sender.toLowerCase() === myNick.toLowerCase()) {
    return false;
  }
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
    msgid?: string;
    account?: string;
    replyTo?: string;
    voiceId?: string;
    voiceDur?: number;
    fileId?: string;
    fileName?: string;
    fileSize?: number;
    albumIds?: string[];
    pasteId?: string;
    pasteLang?: string;
    pasteTitle?: string;
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
    msgid: opts.msgid && SAFE_MSGID_RE.test(opts.msgid)
      ? opts.msgid
      : undefined,
    account: opts.account,
    replyTo: opts.replyTo && SAFE_MSGID_RE.test(opts.replyTo)
      ? opts.replyTo
      : undefined,
    voiceId: opts.voiceId,
    voiceDur: opts.voiceDur,
    fileId: opts.fileId,
    fileName: opts.fileName,
    fileSize: opts.fileSize,
    albumIds: opts.albumIds,
    pasteId: opts.pasteId,
    pasteLang: opts.pasteLang,
    pasteTitle: opts.pasteTitle,
  };
  const prev = buf.lines[buf.lines.length - 1];
  buf.lines.push(entry);
  if (buf.lines.length > 600) buf.lines.shift();

  const isFromOther = !!entry.nick &&
    entry.nick.toLowerCase() !== myNick.toLowerCase();
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

  // Halloy-style day divider when date changes
  if (!prev || dayKey(entry.epochMs) !== dayKey(prev.epochMs)) {
    const sep = document.createElement("div");
    sep.className = "day-divider";
    const span = document.createElement("span");
    span.textContent = formatDayLabel(entry.epochMs);
    sep.appendChild(span);
    wrap.appendChild(sep);
  }

  const sameDay = !!prev && dayKey(entry.epochMs) === dayKey(prev.epochMs);
  const grouped = sameDay &&
    !entry.kind &&
    !!entry.nick &&
    !!prev &&
    !prev.kind &&
    prev.nick === entry.nick &&
    entry.epochMs - prev.epochMs < 180000;

  const fmtOpts = {
    myNick: entry.kind ? undefined : myNick,
    onChannelClick: (chan: string) => {
      const k = chan.toLowerCase();
      if (buffers.has(k)) switchBuf(k);
      else sendRaw(`JOIN ${chan}`);
    },
  };

  const row = document.createElement("div");
  row.className = "msg" +
    (entry.kind ? ` ${entry.kind}` : "") +
    (grouped ? " grouped" : "") +
    (entry.mention ? " mention" : "") +
    (entry.redacted ? " redacted" : "");
  if (entry.msgid) row.dataset.msgid = entry.msgid;

  const renderBodyContent = (): Node => {
    if (entry.redacted) {
      const span = document.createElement("span");
      span.className = "msg-redacted-text";
      span.textContent = t("msg.deleted");
      return span;
    }
    if (entry.encrypted) {
      const att = parseE2eeAttachment(entry.text);
      if (att) {
        return createEncryptedAttachmentView(att, {
          voiceLabel: t("voice.label"),
          downloadLabel: t("file.download"),
        });
      }
    }
    if (entry.pasteId && FILE_ID_RE.test(entry.pasteId)) {
      return createRemoteCodeCard({
        fileId: entry.pasteId,
        lang: entry.pasteLang,
        title: entry.pasteTitle,
      });
    }
    if (entry.albumIds && entry.albumIds.length > 0) {
      return createAlbumGrid(
        entry.albumIds.map((id) => ({
          url: `/api/files/${id}`,
          name: id,
        })),
      );
    }
    if (entry.voiceId && VOICE_ID_RE.test(entry.voiceId)) {
      return createVoicePlayer({
        voiceId: entry.voiceId,
        durationSec: entry.voiceDur,
        label: t("voice.label"),
      });
    }
    if (entry.fileId && FILE_ID_RE.test(entry.fileId)) {
      return createFileCard({
        fileId: entry.fileId,
        fileName: entry.fileName || entry.fileId,
        fileSize: entry.fileSize,
        downloadLabel: t("file.download"),
      });
    }
    const frag = document.createDocumentFragment();
    frag.appendChild(renderIrcMessage(entry.text, fmtOpts));
    if (entry.edited) {
      const ed = document.createElement("span");
      ed.className = "msg-edited";
      ed.textContent = ` ${t("msg.edited")}`;
      frag.appendChild(ed);
    }
    if (!entry.encrypted && !entry.kind && featureOn("link_previews")) {
      const url = extractFirstHttpUrl(entry.text);
      if (url) frag.appendChild(createLinkPreviewSlot(url));
    }
    return frag;
  };

  const renderReplyRef = (): HTMLElement | null => {
    if (!entry.replyTo || entry.redacted || !featureOn("replies")) return null;
    const orig = findMessageInActive(entry.replyTo);
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "msg-reply-ref";
    const who = document.createElement("span");
    who.className = "reply-nick";
    who.textContent = orig ? `↩ ${orig.nick}` : "↩";
    const snip = document.createElement("span");
    snip.className = "reply-snip";
    snip.dir = "auto";
    snip.textContent = orig
      ? (orig.redacted ? t("msg.deleted") : orig.text.slice(0, 80))
      : entry.replyTo.slice(0, 12);
    btn.appendChild(who);
    btn.appendChild(snip);
    btn.onclick = () => jumpToMessage(entry.replyTo!);
    return btn;
  };

  const renderReactionsEl = (): HTMLElement | null => {
    if (
      !entry.reactions || entry.reactions.size === 0 || entry.redacted ||
      !featureOn("reactions")
    ) {
      return null;
    }
    const bar = document.createElement("div");
    bar.className = "msg-reactions";
    entry.reactions.forEach((nicks, emoji) => {
      if (nicks.size === 0) return;
      const pill = document.createElement("button");
      pill.type = "button";
      const mine = Array.from(nicks).some((n) =>
        n.toLowerCase() === myNick.toLowerCase()
      );
      pill.className = "react-pill" + (mine ? " mine" : "");
      pill.title = Array.from(nicks).join(", ");
      const em = document.createElement("span");
      em.textContent = emoji;
      const cnt = document.createElement("span");
      cnt.className = "react-count";
      cnt.textContent = String(nicks.size);
      pill.appendChild(em);
      pill.appendChild(cnt);
      pill.onclick = () => {
        if (entry.msgid) sendReaction(entry.msgid, emoji);
      };
      bar.appendChild(pill);
    });
    return bar.childElementCount > 0 ? bar : null;
  };

  const renderActionsEl = (): HTMLElement | null => {
    if (!entry.msgid || entry.redacted || entry.kind) return null;
    const isMine = entry.nick.toLowerCase() === myNick.toLowerCase();
    const canReact = featureOn("reactions");
    const canReply = featureOn("replies");
    const canEdit = featureOn("editing") && isMine && !entry.voiceId &&
      !entry.fileId && !entry.encrypted;
    const canDelete = featureOn("redaction") &&
      (isMine || isOperatorInBuffer(buffers.get(activeBuf)));
    if (!canReact && !canReply && !canEdit && !canDelete) return null;

    const actions = document.createElement("div");
    actions.className = "msg-actions";
    if (canReact) {
      for (const emoji of QUICK_EMOJIS) {
        const b = document.createElement("button");
        b.type = "button";
        b.className = "msg-act-btn";
        b.textContent = emoji;
        b.title = emoji;
        b.onclick = () => sendReaction(entry.msgid!, emoji);
        actions.appendChild(b);
      }
    }
    if (canReply) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "msg-act-btn";
      b.textContent = "↩";
      b.title = t("msg.reply");
      b.setAttribute("aria-label", t("msg.reply"));
      b.onclick = () => startReply(entry);
      actions.appendChild(b);
    }
    if (canEdit) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "msg-act-btn";
      b.textContent = "✎";
      b.title = t("msg.edit");
      b.setAttribute("aria-label", t("msg.edit"));
      b.onclick = () => startEdit(entry);
      actions.appendChild(b);
    }
    if (canDelete) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "msg-act-btn danger";
      b.textContent = "🗑";
      b.title = t("msg.delete");
      b.setAttribute("aria-label", t("msg.delete"));
      b.onclick = () => sendRedaction(entry.msgid!);
      actions.appendChild(b);
    }
    return actions;
  };

  if (entry.kind || !entry.nick) {
    const t = document.createElement("span");
    t.className = "msg-time";
    t.textContent = entry.time;
    row.appendChild(t);
    const body = document.createElement("span");
    body.className = "msg-text";
    body.dir = "auto";
    body.appendChild(renderBodyContent());
    row.appendChild(body);
  } else if (grouped) {
    const t = document.createElement("span");
    t.className = "msg-time compact-time";
    t.textContent = entry.time;
    row.appendChild(t);
    const col = document.createElement("div");
    col.className = "msg-col";
    const ref = renderReplyRef();
    if (ref) col.appendChild(ref);
    const body = document.createElement("div");
    body.className = "msg-text";
    body.dir = "auto";
    body.appendChild(renderBodyContent());
    col.appendChild(body);
    const reacts = renderReactionsEl();
    if (reacts) col.appendChild(reacts);
    row.appendChild(col);
  } else {
    const av = document.createElement("div");
    av.className = "avatar";
    av.style.backgroundColor = nickColor(entry.nick);
    av.textContent = entry.nick.slice(0, 2).toUpperCase();
    row.appendChild(av);

    const col = document.createElement("div");
    col.className = "msg-col";

    const ref = renderReplyRef();
    if (ref) col.appendChild(ref);

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
    body.dir = "auto";
    body.appendChild(renderBodyContent());

    col.appendChild(meta);
    col.appendChild(body);
    const reacts = renderReactionsEl();
    if (reacts) col.appendChild(reacts);
    row.appendChild(col);
  }

  const actions = renderActionsEl();
  if (actions) {
    row.appendChild(actions);
    row.addEventListener("click", (ev) => {
      const target = ev.target as HTMLElement | null;
      if (target?.closest("button, a, audio, .voice-wave")) return;
      const wasOpen = row.classList.contains("actions-open");
      document.querySelectorAll(".msg.actions-open").forEach((el) =>
        el.classList.remove("actions-open")
      );
      if (!wasOpen) row.classList.add("actions-open");
    });
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
$("btn-members").onclick = () => {
  const useDesktopGrid = settings.layout === "desktop" ||
    (settings.layout === "auto" && globalThis.innerWidth > 960);
  if (useDesktopGrid) {
    $("chat-view").classList.toggle("members-open");
  } else {
    toggleDrawer("right");
  }
};
$("btn-close-left").onclick = closeDrawers;
$("btn-close-right").onclick = () => {
  $("chat-view").classList.remove("members-open");
  closeDrawers();
};
$("drawer-backdrop").onclick = closeDrawers;

function renderActiveMessages(): void {
  const buf = buffers.get(activeBuf);
  const wrap = $("messages");
  const prevTop = wrap.scrollTop;
  const atBottom = wrap.scrollHeight - wrap.scrollTop - wrap.clientHeight < 60;
  wrap.textContent = "";
  if (!buf) return;
  let prev: ChatLine | undefined;
  for (const line of buf.lines) {
    appendLineDom(line, prev);
    prev = line;
  }
  wrap.scrollTop = atBottom ? wrap.scrollHeight : prevTop;
}

function isOperatorInBuffer(buf: BufferState | undefined): boolean {
  if (!buf || !isChan(buf.name)) return false;
  if (isIrcOp) return true;
  const me = myNick.toLowerCase();
  for (const [memberNick, prefix] of buf.members.entries()) {
    if (memberNick.toLowerCase() === me) {
      return /[@&~]/.test(prefix || "");
    }
  }
  return false;
}

function updateTopicButton(): void {
  const buf = buffers.get(activeBuf);
  const isOp = isOperatorInBuffer(buf);
  $("btn-topic").style.display = isOp ? "inline-flex" : "none";
  $("btn-mod").style.display = isOp ? "inline-flex" : "none";
}

function switchBuf(key: string, updateUrl = true): void {
  const buf = buffers.get(key);
  if (!buf) return;
  closeDrawers();
  clearComposeMode();
  activeBuf = key;
  buf.unread = 0;
  buf.mentions = 0;
  const titleEl = $("active-title");
  titleEl.dir = buf.name === "*status" ? "auto" : "ltr";
  titleEl.textContent = buf.name === "*status" ? t("status.title") : buf.name;
  const topicEl = $("active-topic");
  topicEl.dir = "auto";
  topicEl.textContent = buf.topic || (isChan(buf.name) ? t("topic.none") : "");
  updateTopicButton();

  const wrap = $("messages");
  wrap.textContent = "";
  let prev: ChatLine | undefined;
  for (const line of buf.lines) {
    appendLineDom(line, prev);
    prev = line;
  }
  wrap.scrollTop = wrap.scrollHeight;
  updateScrollFab();
  renderTypingBar();
  updateE2eeUi();
  renderBuffers();
  renderMembers();
  updateTitle();
  if (updateUrl && $("chat-view").classList.contains("active")) {
    const nextPath = bufferToPath(buf.name);
    if (location.pathname !== nextPath) {
      history.replaceState({ buf: key }, "", nextPath);
    }
    saveSession();
  }
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
  const nameSpan = document.createElement("span");
  nameSpan.dir = buf.name === "*status" ? "auto" : "ltr";
  nameSpan.textContent = buf.name === "*status" ? t("status.short") : buf.name;
  label.appendChild(nameSpan);
  item.appendChild(label);

  const right = document.createElement("span");
  right.className = "buf-right";
  if (buf.unread > 0) {
    const b = document.createElement("span");
    b.className = "buf-badge" + (buf.mentions > 0 ? " mention" : "");
    b.textContent = buf.unread > 99 ? "99+" : String(buf.unread);
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
  } else {
    const spacer = document.createElement("span");
    spacer.className = "buf-close-spacer";
    spacer.setAttribute("aria-hidden", "true");
    right.appendChild(spacer);
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
    $("members-title").textContent = t("members.title");
    return;
  }
  const q = memberFilter.toLowerCase();
  const sorted = Array.from(buf.members.entries())
    .filter(([nick]) => !q || nick.toLowerCase().includes(q))
    .sort((a, b) => {
      const r = roleRank(a[1]) - roleRank(b[1]);
      return r !== 0 ? r : a[0].localeCompare(b[0]);
    });
  $("members-title").textContent = t("members.count", {
    count: buf.members.size,
  });
  const amOp = isOperatorInBuffer(buf);
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

    const isSelf = nick.toLowerCase() === myNick.toLowerCase();
    if (amOp && !isSelf) {
      const acts = document.createElement("div");
      acts.className = "member-mod-actions";
      const hasOp = /[@&~]/.test(prefix || "");
      const hasVoice = /\+/.test(prefix || "");
      const mkBtn = (
        label: string,
        title: string,
        cls: string,
        fn: () => void,
      ): HTMLButtonElement => {
        const b = document.createElement("button");
        b.type = "button";
        b.className = `member-mod-btn ${cls}`;
        b.textContent = label;
        b.title = title;
        b.onclick = (ev) => {
          ev.stopPropagation();
          fn();
        };
        return b;
      };
      acts.appendChild(
        mkBtn(
          "@",
          hasOp ? `Deop ${nick}` : `Op ${nick}`,
          hasOp ? "active" : "",
          () => sendRaw(`MODE ${buf.name} ${hasOp ? "-o" : "+o"} ${nick}`),
        ),
      );
      acts.appendChild(
        mkBtn(
          "+",
          hasVoice ? `Devoice ${nick}` : `Voice ${nick}`,
          hasVoice ? "active" : "",
          () => sendRaw(`MODE ${buf.name} ${hasVoice ? "-v" : "+v"} ${nick}`),
        ),
      );
      acts.appendChild(
        mkBtn(
          "✕",
          `Kick ${nick}`,
          "danger",
          () => sendRaw(`KICK ${buf.name} ${nick} :Removed by moderator`),
        ),
      );
      acts.appendChild(
        mkBtn("⊘", `Kick & Ban ${nick}`, "danger", () => {
          sendRaw(`MODE ${buf.name} +b ${nick}!*@*`);
          sendRaw(`KICK ${buf.name} ${nick} :Banned by moderator`);
        }),
      );
      row.appendChild(acts);
    }

    row.onclick = () => {
      if (!isSelf) {
        ensureBuf(nick);
        switchBuf(nick.toLowerCase());
      }
    };
    list.appendChild(row);
  }
}

function sendRaw(line: string): void {
  if (ws && ws.readyState === WebSocket.OPEN) {
    const clean = line.replace(/[\r\n\0]/g, "");
    if (clean) ws.send(clean);
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
        const capName = eq === -1 ? tok : tok.slice(0, eq);
        advertisedCaps.push(capName);
        if (capName === FILES_CAP && eq !== -1) {
          const m = /max-bytes=(\d+)/.exec(tok.slice(eq + 1));
          if (m) {
            const parsed = parseInt(m[1], 10);
            if (Number.isFinite(parsed) && parsed > 0) filesMaxBytes = parsed;
          }
        }
        if (capName === FEATURES_CAP && eq !== -1) {
          const val = tok.slice(eq + 1);
          const enabledSet = new Set(
            val === "none" ? [] : val.split(",").filter(Boolean),
          );
          for (
            const k of [
              "reactions",
              "replies",
              "typing",
              "editing",
              "redaction",
              "link_previews",
            ] as const
          ) {
            serverFeatures[k] = enabledSet.has(k);
          }
          applySettings();
        }
      }
      if (more) return;
      if (!advertisedCaps.includes(REDACT_CAP)) {
        serverFeatures.redaction = false;
        applySettings();
      }
      const wanted = [
        "message-tags",
        "server-time",
        "echo-message",
        "batch",
        "draft/chathistory",
        "draft/multiline",
        REDACT_CAP,
        "away-notify",
        "account-notify",
        "account-tag",
        "extended-join",
        E2EE_CAP,
        FEATURES_CAP,
        FILES_CAP,
        VOICE_CAP,
      ];
      if (saslPass) wanted.push("sasl");
      const toReq = wanted.filter((c) => advertisedCaps.includes(c));
      if (toReq.length > 0) sendRaw(`CAP REQ :${toReq.join(" ")}`);
      else sendRaw("CAP END");
    } else if (sub === "ACK") {
      const acked = (params[2] || "").split(" ").filter(Boolean);
      if (acked.includes(E2EE_CAP)) e2ee.setServerSupported(true);
      if (acked.includes(FILES_CAP)) {
        filesSupported = true;
        updateFileButton();
      }
      if (acked.includes(VOICE_CAP)) {
        voiceSupported = true;
        updateVoiceButton();
      }
      if (acked.includes("account-tag")) e2ee.setAccountTagEnabled(true);
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
    addLine("*status", {
      time,
      text: params[1] || "SASL authentication successful",
      kind: "sys",
    });
    sendRaw("CAP END");
    return;
  }
  if (command === "904" || command === "905") {
    addLine("*status", {
      time,
      text: `SASL failed: ${params[1] || ""}`,
      kind: "err",
    });
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
      if (!desiredBuf || desiredBuf === chan.toLowerCase()) {
        switchBuf(chan.toLowerCase());
        desiredBuf = "";
      } else {
        renderBuffers();
      }
      saveSession();
      sendRaw(`CHATHISTORY LATEST ${chan} * 50`);
    }
    if (settings.joinPart) {
      addLine(chan, { time, text: `${nick} joined ${chan}`, kind: "sys" });
    }
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
          addLine(chan, {
            time,
            text: `${nick} left (${params[1] || ""})`,
            kind: "sys",
          });
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
          addLine(buf.name, {
            time,
            text: `${nick} quit (${params[0] || ""})`,
            kind: "sys",
          });
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
        addLine(buf.name, {
          time,
          text: `${nick} is now known as ${next}`,
          kind: "sys",
        });
      }
    });
    renderMembers();
    return;
  }
  if (command === "332") {
    const chan = params[1];
    const buf = ensureBuf(chan);
    buf.topic = params[2] || "";
    if (activeBuf === chan.toLowerCase()) {
      $("active-topic").textContent = buf.topic;
    }
    addLine(chan, { time, text: `Topic: ${buf.topic}`, kind: "sys" });
    return;
  }
  if (command === "TOPIC") {
    const chan = params[0];
    const buf = ensureBuf(chan);
    buf.topic = params[1] || "";
    if (activeBuf === chan.toLowerCase()) {
      $("active-topic").textContent = buf.topic;
    }
    addLine(chan, {
      time,
      text: `${nick} set topic: ${buf.topic}`,
      kind: "sys",
    });
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
    updateTopicButton();
    return;
  }
  if (command === "381") {
    isIrcOp = true;
    updateTopicButton();
    addLine("*status", {
      time,
      text: params[1] || "You are now an IRC operator",
      kind: "sys",
    });
    return;
  }
  if (command === "324") {
    const chan = params[1];
    const modeStr = params[2] || "";
    const buf = ensureBuf(chan);
    buf.modes.clear();
    for (const ch of modeStr) {
      if (/[a-zA-Z]/.test(ch)) buf.modes.add(ch);
    }
    if (
      activeBuf === chan.toLowerCase() &&
      $("mod-modal").classList.contains("open")
    ) {
      renderModModal();
    }
    return;
  }
  if (command === "367") {
    const chan = params[1];
    const mask = params[2];
    if (chan && mask) {
      const buf = ensureBuf(chan);
      if (!buf.bans.includes(mask)) buf.bans.push(mask);
      if (
        activeBuf === chan.toLowerCase() &&
        $("mod-modal").classList.contains("open")
      ) {
        renderModModal();
      }
    }
    return;
  }
  if (command === "368") {
    if ($("mod-modal").classList.contains("open")) renderModModal();
    return;
  }
  if (command === "MODE") {
    const target = params[0];
    if (isChan(target)) {
      const buf = ensureBuf(target);
      const modeStr = params[1] || "";
      let sign = "+";
      for (const ch of modeStr) {
        if (ch === "+" || ch === "-") sign = ch;
        else if (/[mitns]/.test(ch)) {
          if (sign === "+") buf.modes.add(ch);
          else buf.modes.delete(ch);
        }
      }
      addLine(target, {
        time,
        text: `${nick || msg.prefix} set mode ${params.slice(1).join(" ")}`,
        kind: "sys",
      });
      sendRaw(`NAMES ${target}`);
      if (
        activeBuf === target.toLowerCase() &&
        $("mod-modal").classList.contains("open")
      ) {
        renderModModal();
      }
    } else {
      const modes = params[1] || "";
      if (target.toLowerCase() === myNick.toLowerCase()) {
        if (modes.includes("+") && modes.includes("o")) isIrcOp = true;
        if (modes.includes("-") && modes.includes("o")) isIrcOp = false;
        updateTopicButton();
      }
      addLine("*status", {
        time,
        text: `Mode ${target} ${params.slice(1).join(" ")}`,
        kind: "sys",
      });
    }
    return;
  }
  if (command === "INVITE") {
    addLine("*status", {
      time,
      text: `${nick} invited you to ${params[1]}`,
      kind: "sys",
    });
    return;
  }
  if (command === "TAGMSG") {
    const target = params[0] || "";
    const dest = isChan(target)
      ? target
      : nick.toLowerCase() === myNick.toLowerCase()
      ? target
      : nick;
    if (!dest) return;
    const reactEmoji = msg.tags[REACT_TAG];
    const replyTarget = msg.tags[REPLY_TAG];
    if (reactEmoji && replyTarget && featureOn("reactions")) {
      applyReaction(dest, replyTarget, reactEmoji, nick || msg.prefix);
      return;
    }
    const typingState = msg.tags[TYPING_TAG];
    if (
      typingState && featureOn("typing") &&
      nick.toLowerCase() !== myNick.toLowerCase()
    ) {
      updateRemoteTyping(dest, nick, typingState);
    }
    return;
  }
  if (command === "REDACT") {
    const target = params[0] || "";
    const targetMsgId = params[1] || "";
    const dest = isChan(target)
      ? target
      : nick.toLowerCase() === myNick.toLowerCase()
      ? target
      : nick;
    if (dest && targetMsgId) {
      applyRedaction(dest, targetMsgId);
    }
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
    if (nick && nick.toLowerCase() !== myNick.toLowerCase()) {
      updateRemoteTyping(dest, nick, "done");
    }
    const editTargetId = msg.tags[EDIT_TAG];
    if (
      command === "PRIVMSG" && editTargetId &&
      SAFE_MSGID_RE.test(editTargetId) &&
      featureOn("editing") &&
      applyEdit(
        dest,
        editTargetId,
        nick || msg.prefix,
        msg.tags.account,
        text,
      )
    ) {
      return;
    }
    if (text.startsWith("\x01ACTION ") && text.endsWith("\x01")) {
      addLine(dest, {
        time,
        text: `* ${nick} ${text.slice(8, -1)}`,
        kind: "action",
        msgid: msg.tags.msgid,
      });
    } else {
      const rawVoiceId = msg.tags[VOICE_TAG] || "";
      const voiceId = VOICE_ID_RE.test(rawVoiceId) ? rawVoiceId : undefined;
      const rawDur = parseInt(msg.tags[VOICE_DUR_TAG] || "", 10);
      const voiceDur = Number.isFinite(rawDur) && rawDur > 0 && rawDur <= 600
        ? rawDur
        : undefined;
      const rawFileId = msg.tags[FILE_TAG] || "";
      const fileId = FILE_ID_RE.test(rawFileId) ? rawFileId : undefined;
      let fileName: string | undefined;
      if (fileId && msg.tags[FILE_NAME_TAG]) {
        try {
          fileName = decodeURIComponent(msg.tags[FILE_NAME_TAG]);
        } catch {
          fileName = msg.tags[FILE_NAME_TAG];
        }
      }
      const rawFileSize = parseInt(msg.tags[FILE_SIZE_TAG] || "", 10);
      const fileSize = Number.isFinite(rawFileSize) && rawFileSize > 0
        ? rawFileSize
        : undefined;
      const rawAlbum = msg.tags[ALBUM_TAG] || "";
      const albumIds = rawAlbum
        ? rawAlbum.split(",").filter((id) =>
          FILE_ID_RE.test(id) && isPreviewImageId(id)
        ).slice(0, 10)
        : undefined;
      const rawPasteId = msg.tags[PASTE_TAG] || "";
      const pasteId = FILE_ID_RE.test(rawPasteId) ? rawPasteId : undefined;
      const pasteLang = pasteId
        ? (msg.tags[PASTE_LANG_TAG] || "text")
        : undefined;
      let pasteTitle: string | undefined;
      if (pasteId && msg.tags[PASTE_TITLE_TAG]) {
        try {
          pasteTitle = decodeURIComponent(msg.tags[PASTE_TITLE_TAG]);
        } catch {
          pasteTitle = msg.tags[PASTE_TITLE_TAG];
        }
      }
      const replyTo = msg.tags[REPLY_TAG] || undefined;
      addLine(dest, {
        time,
        nick: nick || msg.prefix,
        text,
        kind: command === "NOTICE" ? "notice" : "",
        msgid: msg.tags.msgid,
        account: msg.tags.account,
        replyTo,
        voiceId,
        voiceDur,
        fileId,
        fileName,
        fileSize,
        albumIds: albumIds && albumIds.length > 0 ? albumIds : undefined,
        pasteId,
        pasteLang,
        pasteTitle,
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
    addLine("*status", {
      time,
      text: `${command}: ${params.join(" ")}`,
      kind: "err",
    });
    return;
  }
  if (command === "322") {
    const chan = params[1] || "";
    const users = parseInt(params[2] || "0", 10) || 0;
    const topic = params[3] || "";
    if (discoverLoading || $("discover-modal").classList.contains("open")) {
      if (chan) {
        discoverChannels.push({ name: chan, users, topic });
        renderDiscoverList();
      }
      return;
    }
    addLine("*status", {
      time,
      text: `${chan} (${users} users) ${topic}`,
      kind: "sys",
    });
    return;
  }
  if (command === "323") {
    if (discoverLoading || $("discover-modal").classList.contains("open")) {
      discoverLoading = false;
      renderDiscoverList();
      return;
    }
    return;
  }
  if (/^\d{3}$/.test(command)) {
    if (["366", "002", "003", "004", "005", "375", "376"].includes(command)) {
      return;
    }
    addLine("*status", {
      time,
      text: `[${command}] ${params.slice(1).join(" ")}`,
      kind: "sys",
    });
  }
}

let connOffline = false;

function setConnButtonState(offline: boolean): void {
  connOffline = offline;
  const btn = $("btn-conn");
  const label = $("btn-conn-label");
  btn.classList.toggle("primary", offline);
  btn.classList.toggle("danger", !offline);
  $("icon-disconnect").classList.toggle("hidden", offline);
  $("icon-reconnect").classList.toggle("hidden", !offline);
  const text = offline ? t("btn.reconnect") : t("btn.disconnect");
  label.textContent = text;
  btn.title = text;
  btn.setAttribute("aria-label", text);
}

function connectSocket(url: string): void {
  const parsed = new URL(url);
  if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
    throw new Error("WebSocket URL must start with ws:// or wss://");
  }
  lastWsUrl = parsed.href;
  if (ws) {
    try {
      ws.close();
    } catch {
      // ignore
    }
  }
  ws = new WebSocket(parsed.href, ["text.ircv3.net"]);
  $("status-dot").classList.remove("off");
  setConnButtonState(false);
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
    setConnButtonState(true);
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
        else {sendRaw(
            `KICK ${buf.name} ${rest.slice(0, s2)} :${rest.slice(s2 + 1)}`,
          );}
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
      sendRaw(
        rest
          ? `WHO ${rest}`
          : buf && isChan(buf.name)
          ? `WHO ${buf.name}`
          : "WHO",
      );
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
        sendRaw(
          `CHATHISTORY LATEST ${buf.name} * ${
            Math.min(Math.max(limit, 1), 200)
          }`,
        );
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
        if (
          buf && buf.name !== "*status" &&
          e2ee.setBufferEncrypted(buf.name, true)
        ) {
          addLine(buf.name, {
            text: "End-to-end encryption enabled.",
            kind: "sys",
          });
        }
      } else if (sub === "off") {
        if (buf && buf.name !== "*status") {
          e2ee.setBufferEncrypted(buf.name, false);
          addLine(buf.name, {
            text: "End-to-end encryption disabled.",
            kind: "sys",
          });
        }
      } else if (sub === "rotate") {
        if (buf && isChan(buf.name)) void e2ee.rotateChannelKey(buf.name);
        else {addLine(target, {
            text: "Switch to a channel to rotate its Sender Key.",
            kind: "err",
          });}
      } else if (sub === "verify") {
        const who =
          (parts[1] || (!isChan(target) && target !== "*status" ? target : ""))
            .toLowerCase();
        const st = e2ee.getStatus();
        const matches = who
          ? st.trustedPeers.filter((p) => p.account === who)
          : st.trustedPeers;
        if (matches.length === 0) {
          addLine(target, {
            text: "No pinned E2EE peer devices found.",
            kind: "sys",
          });
        } else {
          for (const p of matches) {
            addLine(target, {
              text:
                `Safety # for ${p.account} (device ${p.device}): ${p.safetyNumber}`,
              kind: "sys",
            });
          }
        }
      } else if (sub === "reset") {
        e2ee.resetDevice();
        addLine(target, { text: "E2EE device keys reset.", kind: "sys" });
      } else {
        openSettings("e2ee");
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
      clearSession();
      sendRaw(`QUIT :${rest || "Leaving WebIRC"}`);
      return;
    default:
      addLine(target, {
        text: `Unknown command: /${cmd} (try /help)`,
        kind: "err",
      });
  }
}

let desiredBuf = "";

function startSession(opts: {
  nick: string;
  acct: string;
  pass: string;
  channels: string[];
  wsUrl: string;
  targetBuf?: string;
}): void {
  const err = $("connect-err");
  err.style.display = "none";
  myNick = opts.nick;
  isIrcOp = false;
  saslUser = opts.acct;
  saslPass = opts.pass;
  autoChannels = opts.channels;
  desiredBuf = (opts.targetBuf || "").toLowerCase();

  if (desiredBuf && desiredBuf !== "*status" && isChan(desiredBuf)) {
    if (!autoChannels.some((c) => c.toLowerCase() === desiredBuf)) {
      autoChannels = [...autoChannels, desiredBuf];
    }
  }
  try {
    buffers.clear();
    ensureBuf("*status");
    if (desiredBuf && desiredBuf !== "*status" && !isChan(desiredBuf)) {
      ensureBuf(opts.targetBuf || desiredBuf);
    }
    $("connect-view").style.display = "none";
    $("chat-view").classList.add("active");
    $("my-nick").textContent = myNick;
    if (desiredBuf && buffers.has(desiredBuf)) {
      switchBuf(desiredBuf);
      desiredBuf = "";
    } else {
      switchBuf("*status", false);
    }
    connectSocket(opts.wsUrl);
    saveSession();
  } catch (e) {
    err.textContent = `Invalid WebSocket URL: ${errorMessage(e)}`;
    err.style.display = "block";
    $("chat-view").classList.remove("active");
    $("connect-view").style.display = "flex";
  }
}

const connectErr = $("connect-err");
const loginAltcha = initAltcha(
  $<HTMLInputElement>("altcha-check"),
  $("altcha-label"),
  (msg) => {
    connectErr.textContent = msg;
    connectErr.style.display = "block";
  },
);

$<HTMLFormElement>("connect-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  connectErr.style.display = "none";
  const altchaPayload = loginAltcha.getPayload();
  if (!altchaPayload) {
    connectErr.textContent = "Please complete the ALTCHA verification.";
    connectErr.style.display = "block";
    return;
  }
  const btn = $<HTMLButtonElement>("btn-connect");
  btn.disabled = true;
  try {
    const res = await postJson<{ error?: string; message?: string }>(
      "/api/webirc/verify",
      { altcha: altchaPayload },
    );
    if (!res.ok) {
      connectErr.textContent = res.data.message ||
        "ALTCHA verification failed. Please try again.";
      connectErr.style.display = "block";
      loginAltcha.reset();
      return;
    }
    loginAltcha.reset();
    const pathBuf = pathToBuffer(location.pathname);
    startSession({
      nick: $<HTMLInputElement>("inp-nick").value.trim(),
      acct: $<HTMLInputElement>("inp-acct").value.trim(),
      pass: $<HTMLInputElement>("inp-pass").value,
      channels: $<HTMLInputElement>("inp-channels").value
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean),
      wsUrl: $<HTMLInputElement>("inp-ws").value.trim(),
      targetBuf: pathBuf || undefined,
    });
  } catch (e) {
    connectErr.textContent = `Verification failed: ${errorMessage(e)}`;
    connectErr.style.display = "block";
    loginAltcha.reset();
  } finally {
    btn.disabled = false;
  }
});

globalThis.addEventListener("popstate", () => {
  const target = pathToBuffer(location.pathname);
  if (target && buffers.has(target.toLowerCase())) {
    switchBuf(target.toLowerCase(), false);
  }
});

let topicTarget = "";

function openTopicModal(): void {
  const buf = buffers.get(activeBuf);
  if (!buf || !isChan(buf.name)) return;
  topicTarget = buf.name;
  $("topic-modal-chan").textContent = buf.name;
  const inp = $<HTMLInputElement>("inp-topic");
  inp.value = buf.topic || "";
  $("topic-modal").classList.add("open");
  inp.focus();
  inp.select();
}

function closeTopicModal(): void {
  $("topic-modal").classList.remove("open");
  topicTarget = "";
}

$("btn-topic").onclick = openTopicModal;
$("btn-close-topic").onclick = closeTopicModal;
$("btn-cancel-topic").onclick = closeTopicModal;
$("topic-modal").addEventListener("click", (ev) => {
  if (ev.target === $("topic-modal")) closeTopicModal();
});
$<HTMLFormElement>("topic-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  if (!topicTarget) return;
  const next = $<HTMLInputElement>("inp-topic").value.trim();
  sendRaw(`TOPIC ${topicTarget} :${next}`);
  closeTopicModal();
});

$("btn-conn").onclick = () => {
  if (connOffline) {
    if (lastWsUrl) connectSocket(lastWsUrl);
    return;
  }
  clearSession();
  isRegistered = false;
  hiddenUnread = 0;
  hiddenMentions = 0;
  if (ws && ws.readyState === WebSocket.OPEN) {
    sendRaw("QUIT :Leaving WebIRC");
    ws.close();
  }
  ws = null;
  updateTitle();
  if (location.pathname !== "/") {
    history.replaceState(null, "", "/");
  }
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
      n.toLowerCase().startsWith(prefix.toLowerCase())
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
    addLine("*status", {
      text: "Join a channel first (e.g. /join #lobby) or type /help.",
      kind: "err",
    });
    return;
  }
  if (e2ee.isBufferEncrypted(buf.name)) {
    const dest = buf.name;
    clearComposeMode();
    sendTypingState(dest, "done");
    void e2ee.sendEncrypted(dest, raw).then((ok) => {
      if (ok) addLine(dest, { nick: myNick, text: raw, encrypted: true });
    });
    return;
  }
  sendTypingState(buf.name, "done");
  if (composeMode?.kind === "edit" && featureOn("editing")) {
    const targetId = composeMode.msgid;
    clearComposeMode();
    sendRaw(`@${EDIT_TAG}=${targetId} PRIVMSG ${buf.name} :${raw}`);
    return;
  }
  if (composeMode?.kind === "reply" && featureOn("replies")) {
    const targetId = composeMode.msgid;
    clearComposeMode();
    sendRaw(`@${REPLY_TAG}=${targetId} PRIVMSG ${buf.name} :${raw}`);
    return;
  }
  clearComposeMode();
  sendRaw(`PRIVMSG ${buf.name} :${raw}`);
});

type ComposeMode =
  | { kind: "reply"; msgid: string; nick: string; snippet: string }
  | { kind: "edit"; msgid: string; origText: string }
  | null;

let composeMode: ComposeMode = null;

function clearComposeMode(): void {
  composeMode = null;
  $("compose-banner").classList.add("hidden");
  $("compose-banner-label").textContent = "";
  $("compose-banner-snippet").textContent = "";
}

function startReply(entry: ChatLine): void {
  if (!entry.msgid || !featureOn("replies")) return;
  composeMode = {
    kind: "reply",
    msgid: entry.msgid,
    nick: entry.nick,
    snippet: entry.text.slice(0, 100),
  };
  $("compose-banner-label").textContent = t("msg.replyingTo", {
    nick: entry.nick,
  });
  $("compose-banner-snippet").textContent = composeMode.snippet;
  $("compose-banner").classList.remove("hidden");
  msgInp.focus();
}

function startEdit(entry: ChatLine): void {
  if (!entry.msgid || !featureOn("editing")) return;
  composeMode = {
    kind: "edit",
    msgid: entry.msgid,
    origText: entry.text,
  };
  $("compose-banner-label").textContent = t("msg.editing");
  $("compose-banner-snippet").textContent = entry.text.slice(0, 100);
  $("compose-banner").classList.remove("hidden");
  msgInp.value = entry.text;
  msgInp.focus();
}

$("btn-compose-cancel").onclick = () => {
  if (composeMode?.kind === "edit") msgInp.value = "";
  clearComposeMode();
};

function findMessageInActive(msgid: string): ChatLine | undefined {
  const buf = buffers.get(activeBuf);
  if (!buf) return undefined;
  return buf.lines.find((l) => l.msgid === msgid);
}

function jumpToMessage(msgid: string): void {
  const wrap = $("messages");
  const rows = wrap.querySelectorAll<HTMLElement>("[data-msgid]");
  for (const el of rows) {
    if (el.dataset.msgid === msgid) {
      el.scrollIntoView({ behavior: "smooth", block: "center" });
      el.classList.remove("flash-highlight");
      void el.offsetWidth;
      el.classList.add("flash-highlight");
      break;
    }
  }
}

function sendReaction(msgid: string, emoji: string): void {
  if (!featureOn("reactions") || !SAFE_MSGID_RE.test(msgid)) return;
  const clean = emoji.trim().slice(0, 8);
  if (!clean || /[\s;\r\n\0]/.test(clean)) return;
  const buf = buffers.get(activeBuf);
  if (!buf || buf.name === "*status") return;
  sendRaw(`@${REPLY_TAG}=${msgid};${REACT_TAG}=${clean} TAGMSG ${buf.name}`);
}

function sendRedaction(msgid: string): void {
  if (!featureOn("redaction") || !SAFE_MSGID_RE.test(msgid)) return;
  const buf = buffers.get(activeBuf);
  if (!buf || buf.name === "*status") return;
  sendRaw(`REDACT ${buf.name} ${msgid}`);
}

function applyReaction(
  bufName: string,
  msgid: string,
  emoji: string,
  sender: string,
): void {
  if (!SAFE_MSGID_RE.test(msgid) || !sender) return;
  let cleanEmoji = "";
  for (const ch of emoji.trim()) {
    const code = ch.codePointAt(0) || 0;
    if (
      code < 0x20 || code === 0x7f ||
      (code >= 0x202a && code <= 0x202e) ||
      (code >= 0x2066 && code <= 0x2069)
    ) {
      continue;
    }
    cleanEmoji += ch;
    if (cleanEmoji.length >= 8) break;
  }
  if (!cleanEmoji) return;
  const key = bufName.toLowerCase();
  const buf = buffers.get(key);
  if (!buf) return;
  const line = buf.lines.find((l) => l.msgid === msgid);
  if (!line || line.redacted) return;
  if (!line.reactions) line.reactions = new Map();
  let set = line.reactions.get(cleanEmoji);
  if (!set) {
    if (line.reactions.size >= MAX_REACTIONS_PER_MSG) return;
    set = new Set();
    line.reactions.set(cleanEmoji, set);
  }
  const existing = Array.from(set).find((n) =>
    n.toLowerCase() === sender.toLowerCase()
  );
  if (existing) {
    set.delete(existing);
    if (set.size === 0) line.reactions.delete(cleanEmoji);
  } else {
    set.add(sender);
  }
  if (activeBuf === key) renderActiveMessages();
}

function applyEdit(
  bufName: string,
  msgid: string,
  sender: string,
  senderAccount: string | undefined,
  newText: string,
): boolean {
  const key = bufName.toLowerCase();
  const buf = buffers.get(key);
  if (!buf) return false;
  const line = buf.lines.find((l) => l.msgid === msgid);
  if (
    !line || line.redacted || line.encrypted || line.voiceId || line.fileId ||
    line.albumIds
  ) {
    return false;
  }
  // Prevent spoofing: require matching nick, and matching SASL account if known
  if (line.nick.toLowerCase() !== sender.toLowerCase()) return false;
  if (
    line.account && line.account !== "*" &&
    (!senderAccount ||
      senderAccount.toLowerCase() !== line.account.toLowerCase())
  ) {
    return false;
  }
  line.text = newText;
  line.edited = true;
  if (activeBuf === key) renderActiveMessages();
  return true;
}

function applyRedaction(bufName: string, msgid: string): void {
  const key = bufName.toLowerCase();
  const buf = buffers.get(key);
  if (!buf) return;
  const line = buf.lines.find((l) => l.msgid === msgid);
  if (!line) return;
  line.redacted = true;
  line.text = "";
  line.voiceId = undefined;
  line.fileId = undefined;
  line.reactions?.clear();
  if (activeBuf === key) renderActiveMessages();
}

// Typing indicators (per-buffer remote typers with 6s expiry + throttled local send)
const typingTimers = new Map<string, Map<string, number>>();
let lastTypingSentAt = 0;
let lastTypingTarget = "";
let localTypingStopTimer: number | null = null;

function renderTypingBar(): void {
  const bar = $("typing-bar");
  if (!featureOn("typing")) {
    bar.classList.add("hidden");
    return;
  }
  const map = typingTimers.get(activeBuf);
  const nicks = map ? Array.from(map.keys()) : [];
  if (nicks.length === 0) {
    bar.classList.add("hidden");
    return;
  }
  let text = "";
  if (nicks.length === 1) text = t("typing.one", { nick: nicks[0] });
  else if (nicks.length === 2) {
    text = t("typing.two", { a: nicks[0], b: nicks[1] });
  } else text = t("typing.many", { count: nicks.length });
  $("typing-text").textContent = text;
  bar.classList.remove("hidden");
}

function updateRemoteTyping(
  bufName: string,
  sender: string,
  state: string,
): void {
  const key = bufName.toLowerCase();
  let map = typingTimers.get(key);
  if (!map) {
    map = new Map();
    typingTimers.set(key, map);
  }
  const prev = map.get(sender);
  if (prev !== undefined) globalThis.clearTimeout(prev);
  if (state === "active") {
    if (!map.has(sender) && map.size >= MAX_TYPERS_PER_BUF) return;
    const tid = globalThis.setTimeout(() => {
      map?.delete(sender);
      if (activeBuf === key) renderTypingBar();
    }, 6000);
    map.set(sender, tid);
  } else {
    map.delete(sender);
  }
  if (activeBuf === key) renderTypingBar();
}

function sendTypingState(target: string, state: "active" | "done"): void {
  if (
    !featureOn("typing") || !isRegistered || !target || target === "*status"
  ) {
    return;
  }
  if (state === "active") {
    const now = Date.now();
    if (lastTypingTarget === target && now - lastTypingSentAt < 3000) return;
    lastTypingSentAt = now;
    lastTypingTarget = target;
    sendRaw(`@${TYPING_TAG}=active TAGMSG ${target}`);
    if (localTypingStopTimer !== null) {
      globalThis.clearTimeout(localTypingStopTimer);
    }
    localTypingStopTimer = globalThis.setTimeout(() => {
      sendTypingState(target, "done");
    }, 5000);
  } else {
    if (localTypingStopTimer !== null) {
      globalThis.clearTimeout(localTypingStopTimer);
      localTypingStopTimer = null;
    }
    if (lastTypingTarget === target) {
      lastTypingTarget = "";
      lastTypingSentAt = 0;
      sendRaw(`@${TYPING_TAG}=done TAGMSG ${target}`);
    }
  }
}

msgInp.addEventListener("input", () => {
  if (!featureOn("typing")) return;
  const buf = buffers.get(activeBuf);
  if (!buf || buf.name === "*status") return;
  const v = msgInp.value;
  if (v.trim() && !v.startsWith("/")) {
    sendTypingState(buf.name, "active");
  } else {
    sendTypingState(buf.name, "done");
  }
});

let voiceSupported = false;
let voiceRecorder: MediaRecorder | null = null;
let voiceStream: MediaStream | null = null;
let voiceChunks: Blob[] = [];
let voiceStartMs = 0;
let voiceTimerId: number | null = null;
let voiceCancelled = false;
let voiceTarget = "";
const VOICE_MAX_SEC = 120;

function pickOpusMime(): string {
  if (typeof MediaRecorder === "undefined") return "";
  const candidates = [
    "audio/ogg;codecs=opus",
    "audio/webm;codecs=opus",
    "audio/webm",
  ];
  for (const mime of candidates) {
    if (MediaRecorder.isTypeSupported(mime)) return mime;
  }
  return "";
}

function canRecordVoice(): boolean {
  return voiceSupported &&
    typeof MediaRecorder !== "undefined" &&
    Boolean(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
}

function updateVoiceButton(): void {
  updateAttachControls();
}

function resetVoiceUi(): void {
  if (voiceTimerId !== null) {
    globalThis.clearInterval(voiceTimerId);
    voiceTimerId = null;
  }
  if (voiceStream) {
    for (const track of voiceStream.getTracks()) track.stop();
    voiceStream = null;
  }
  voiceRecorder = null;
  voiceChunks = [];
  const btn = $("btn-voice");
  btn.classList.remove("recording");
  btn.classList.add("hidden");
  btn.title = t("voice.record");
  $("send-form").classList.remove("recording-active");
  $("voice-timer").textContent = "";
  $("btn-voice-cancel").classList.add("hidden");
}

async function uploadAndSendVoice(
  blob: Blob,
  durSec: number,
  target: string,
): Promise<void> {
  const btn = $<HTMLButtonElement>("btn-voice");
  btn.disabled = true;
  try {
    if (e2ee.isBufferEncrypted(target) && filesSupported) {
      const raw = new Uint8Array(await blob.arrayBuffer());
      const enc = encryptAttachment(raw);
      const uploaded = await uploadBinaryFile(enc.ciphertext, "encrypted.bin");
      if (!uploaded) return;
      const payload = E2EE_ATT_PREFIX + JSON.stringify({
        v: 1,
        kind: "voice",
        id: uploaded.id,
        mime: blob.type || "audio/ogg",
        dur: durSec,
        bytes: raw.byteLength,
        key: enc.key,
        iv: enc.iv,
        sha256: enc.sha256,
      });
      const ok = await e2ee.sendEncrypted(target, payload);
      if (ok) addLine(target, { nick: myNick, text: payload, encrypted: true });
      return;
    }
    const resp = await fetch("/api/voice", {
      method: "POST",
      headers: {
        "X-Requested-With": "ircd-webui",
        "Content-Type": blob.type || "audio/ogg",
        "X-Voice-Duration": String(durSec),
      },
      body: blob,
    });
    const data = await resp.json().catch(() => ({})) as {
      id?: string;
      duration?: number;
      error?: string;
      message?: string;
    };
    if (!resp.ok || !data.id || !VOICE_ID_RE.test(data.id)) {
      const reason = data.message || data.error || `HTTP ${resp.status}`;
      addLine(target, {
        text: t("voice.err.upload", { reason }),
        kind: "err",
      });
      return;
    }
    const finalDur = typeof data.duration === "number" && data.duration > 0
      ? data.duration
      : durSec;
    sendRaw(
      `@${VOICE_TAG}=${data.id};${VOICE_DUR_TAG}=${finalDur} PRIVMSG ${target} :[Voice message ${
        fmtDuration(finalDur)
      }] /api/voice/${data.id}`,
    );
  } catch (e) {
    addLine(target, {
      text: t("voice.err.upload", { reason: errorMessage(e) }),
      kind: "err",
    });
  } finally {
    btn.disabled = false;
  }
}

$("btn-voice").addEventListener("click", () => {
  if (voiceRecorder && voiceRecorder.state === "recording") {
    voiceCancelled = false;
    voiceRecorder.stop();
    return;
  }
  const buf = buffers.get(activeBuf);
  if (!buf || buf.name === "*status") {
    addLine("*status", { text: t("voice.err.target"), kind: "err" });
    return;
  }
  voiceTarget = buf.name;
  voiceCancelled = false;
  void navigator.mediaDevices.getUserMedia({ audio: true }).then((stream) => {
    voiceStream = stream;
    voiceChunks = [];
    const mime = pickOpusMime();
    const opts: MediaRecorderOptions = mime
      ? { mimeType: mime, audioBitsPerSecond: 32000 }
      : { audioBitsPerSecond: 32000 };
    const rec = new MediaRecorder(stream, opts);
    voiceRecorder = rec;
    voiceStartMs = Date.now();
    rec.ondataavailable = (ev) => {
      if (ev.data && ev.data.size > 0) voiceChunks.push(ev.data);
    };
    rec.onstop = () => {
      const chunks = voiceChunks.slice();
      const cancelled = voiceCancelled;
      const target = voiceTarget;
      const durSec = Math.max(
        1,
        Math.min(VOICE_MAX_SEC, Math.round((Date.now() - voiceStartMs) / 1000)),
      );
      const outMime = rec.mimeType || mime || "audio/ogg";
      resetVoiceUi();
      if (!cancelled && chunks.length > 0) {
        const blob = new Blob(chunks, { type: outMime });
        void uploadAndSendVoice(blob, durSec, target);
      }
    };
    rec.start(250);
    const btn = $("btn-voice");
    btn.classList.remove("hidden");
    btn.classList.add("recording");
    btn.title = t("voice.stop");
    $("send-form").classList.add("recording-active");
    closeAttachMenu();
    $("btn-voice-cancel").classList.remove("hidden");
    $("voice-timer").textContent = "0:00";
    voiceTimerId = globalThis.setInterval(() => {
      const elapsed = Math.floor((Date.now() - voiceStartMs) / 1000);
      $("voice-timer").textContent = fmtDuration(elapsed);
      if (elapsed >= VOICE_MAX_SEC && voiceRecorder) {
        voiceCancelled = false;
        voiceRecorder.stop();
      }
    }, 250);
  }).catch(() => {
    resetVoiceUi();
    addLine(voiceTarget || "*status", {
      text: t("voice.err.mic"),
      kind: "err",
    });
  });
});

$("btn-voice-cancel").addEventListener("click", () => {
  voiceCancelled = true;
  if (voiceRecorder && voiceRecorder.state === "recording") {
    voiceRecorder.stop();
  } else {
    resetVoiceUi();
  }
});

let filesSupported = false;
let filesMaxBytes = 10485760;

function updateAttachControls(): void {
  const voiceOk = canRecordVoice();
  const anyAttach = filesSupported || voiceOk;
  $("btn-attach-menu").classList.toggle("hidden", !anyAttach);
  $("btn-attach-file-menu").classList.toggle("hidden", !filesSupported);
  $("btn-attach-code-menu").classList.toggle("hidden", !filesSupported);
  $("btn-attach-voice-menu").classList.toggle("hidden", !voiceOk);
  if (filesSupported) {
    $("attach-file-desc").textContent = `${t("attach.file.desc")} (max ${
      formatBytes(filesMaxBytes)
    })`;
  }
}

function updateFileButton(): void {
  updateAttachControls();
}

function openAttachModal(): void {
  const buf = buffers.get(activeBuf);
  if (!buf || buf.name === "*status") {
    addLine("*status", { text: t("file.err.target"), kind: "err" });
    return;
  }
  updateAttachControls();
  $("attach-modal").classList.add("open");
}

function closeAttachMenu(): void {
  $("attach-modal").classList.remove("open");
}

$("btn-attach-menu").addEventListener("click", openAttachModal);
$("btn-close-attach").addEventListener("click", closeAttachMenu);
$("attach-modal").addEventListener("click", (ev) => {
  if (ev.target === $("attach-modal")) closeAttachMenu();
});

$("btn-attach-file-menu").addEventListener("click", () => {
  closeAttachMenu();
  fileInp.value = "";
  fileInp.click();
});

$("btn-attach-code-menu").addEventListener("click", () => {
  closeAttachMenu();
  openCodeModal();
});

$("btn-attach-voice-menu").addEventListener("click", () => {
  closeAttachMenu();
  $("btn-voice").click();
});

document.addEventListener("click", (ev) => {
  const target = ev.target as HTMLElement | null;
  if (!target?.closest(".msg")) {
    document.querySelectorAll(".msg.actions-open").forEach((el) =>
      el.classList.remove("actions-open")
    );
  }
});

async function uploadBinaryFile(
  body: Blob | Uint8Array,
  filename: string,
): Promise<{ id: string; name: string; bytes: number } | null> {
  const resp = await fetch("/api/files", {
    method: "POST",
    headers: {
      "X-Requested-With": "ircd-webui",
      "Content-Type": "application/octet-stream",
      "X-File-Name": encodeURIComponent(filename || "file.bin"),
    },
    body: body instanceof Uint8Array ? (body as BodyInit) : body,
  });
  const data = await resp.json().catch(() => ({})) as {
    id?: string;
    name?: string;
    bytes?: number;
    error?: string;
    message?: string;
  };
  if (!resp.ok || !data.id || !FILE_ID_RE.test(data.id)) {
    throw new Error(data.message || data.error || `HTTP ${resp.status}`);
  }
  return {
    id: data.id,
    name: data.name || filename || data.id,
    bytes: typeof data.bytes === "number" && data.bytes > 0 ? data.bytes : 0,
  };
}

function isRasterImageFile(file: File): boolean {
  return [
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
  ].includes(file.type) ||
    isPreviewImageId(
      `00000000000000000000000000000000.${
        (file.name.split(".").pop() || "").toLowerCase()
      }`,
    );
}

async function uploadAndSendFiles(
  files: File[],
  target: string,
): Promise<void> {
  if (!filesSupported || files.length === 0) return;
  const batch = files.slice(0, 10);
  for (const f of batch) {
    if (f.size > filesMaxBytes) {
      addLine(target, {
        text: t("file.err.tooLarge", { max: formatBytes(filesMaxBytes) }),
        kind: "err",
      });
      return;
    }
  }
  const btn = $<HTMLButtonElement>("btn-attach-menu");
  btn.disabled = true;
  btn.classList.add("uploading");
  try {
    const encrypted = e2ee.isBufferEncrypted(target);
    const allImages = batch.length >= 2 && batch.every(isRasterImageFile);

    if (encrypted) {
      if (allImages) {
        const items: E2eeAttachmentItem[] = [];
        for (const f of batch) {
          const raw = new Uint8Array(await f.arrayBuffer());
          const enc = encryptAttachment(raw);
          const up = await uploadBinaryFile(enc.ciphertext, "encrypted.bin");
          if (up) {
            items.push({
              id: up.id,
              name: f.name || "image.png",
              mime: f.type || "image/png",
              bytes: raw.byteLength,
              key: enc.key,
              iv: enc.iv,
              sha256: enc.sha256,
            });
          }
        }
        if (items.length > 0) {
          const payload = E2EE_ATT_PREFIX + JSON.stringify({
            v: 1,
            kind: "album",
            items,
          });
          const ok = await e2ee.sendEncrypted(target, payload);
          if (ok) {
            addLine(target, { nick: myNick, text: payload, encrypted: true });
          }
        }
      } else {
        for (const f of batch) {
          if (f.size <= 0) continue;
          const raw = new Uint8Array(await f.arrayBuffer());
          const enc = encryptAttachment(raw);
          const up = await uploadBinaryFile(enc.ciphertext, "encrypted.bin");
          if (!up) continue;
          const payload = E2EE_ATT_PREFIX + JSON.stringify({
            v: 1,
            kind: "file",
            id: up.id,
            name: f.name || "file.bin",
            mime: f.type || "application/octet-stream",
            bytes: raw.byteLength,
            key: enc.key,
            iv: enc.iv,
            sha256: enc.sha256,
          });
          const ok = await e2ee.sendEncrypted(target, payload);
          if (ok) {
            addLine(target, { nick: myNick, text: payload, encrypted: true });
          }
        }
      }
      return;
    }

    if (allImages) {
      const ids: string[] = [];
      for (const f of batch) {
        if (f.size <= 0) continue;
        const up = await uploadBinaryFile(f, f.name || "image.png");
        if (up && isPreviewImageId(up.id)) ids.push(up.id);
      }
      if (ids.length >= 2) {
        sendRaw(
          `@${ALBUM_TAG}=${
            ids.join(",")
          } PRIVMSG ${target} :[Album: ${ids.length} images]`,
        );
      } else if (ids.length === 1) {
        const id = ids[0];
        sendRaw(
          `@${FILE_TAG}=${id};${FILE_NAME_TAG}=${
            encodeURIComponent(batch[0].name || id)
          };${FILE_SIZE_TAG}=${batch[0].size} PRIVMSG ${target} :[File: ${
            batch[0].name || id
          }] /api/files/${id}`,
        );
      }
      return;
    }

    for (const f of batch) {
      if (f.size <= 0) continue;
      const up = await uploadBinaryFile(f, f.name || "file.bin");
      if (!up) continue;
      const size = up.bytes || f.size;
      const encodedName = encodeURIComponent(up.name);
      sendRaw(
        `@${FILE_TAG}=${up.id};${FILE_NAME_TAG}=${encodedName};${FILE_SIZE_TAG}=${size} PRIVMSG ${target} :[File: ${up.name} (${
          formatBytes(size)
        })] /api/files/${up.id}`,
      );
    }
  } catch (e) {
    addLine(target, {
      text: t("file.err.upload", { reason: errorMessage(e) }),
      kind: "err",
    });
  } finally {
    btn.disabled = false;
    btn.classList.remove("uploading");
  }
}

function shareFilesInActiveBuffer(files: File[]): void {
  const buf = buffers.get(activeBuf);
  if (!buf || buf.name === "*status") {
    addLine("*status", { text: t("file.err.target"), kind: "err" });
    return;
  }
  void uploadAndSendFiles(files, buf.name);
}

const fileInp = $<HTMLInputElement>("inp-file");
fileInp.addEventListener("change", () => {
  const files = fileInp.files ? Array.from(fileInp.files) : [];
  if (files.length > 0) shareFilesInActiveBuffer(files);
});

const messagesDropZone = $("messages");
messagesDropZone.addEventListener("dragover", (ev) => {
  if (!filesSupported) return;
  if (ev.dataTransfer?.types.includes("Files")) {
    ev.preventDefault();
    messagesDropZone.classList.add("drag-over");
  }
});
messagesDropZone.addEventListener("dragleave", () => {
  messagesDropZone.classList.remove("drag-over");
});
messagesDropZone.addEventListener("drop", (ev) => {
  messagesDropZone.classList.remove("drag-over");
  if (!filesSupported) return;
  const files = ev.dataTransfer?.files ? Array.from(ev.dataTransfer.files) : [];
  if (files.length > 0) {
    ev.preventDefault();
    shareFilesInActiveBuffer(files);
  }
});

msgInp.addEventListener("paste", (ev) => {
  if (!filesSupported) return;
  const files = ev.clipboardData?.files
    ? Array.from(ev.clipboardData.files)
    : [];
  if (files.length > 0) {
    ev.preventDefault();
    shareFilesInActiveBuffer(files);
  }
});

// Code Snippet / Paste modal
function openCodeModal(): void {
  const buf = buffers.get(activeBuf);
  if (!buf || buf.name === "*status") {
    addLine("*status", { text: t("file.err.target"), kind: "err" });
    return;
  }
  $("code-modal").classList.add("open");
  $<HTMLTextAreaElement>("inp-code-body").focus();
}

function closeCodeModal(): void {
  $("code-modal").classList.remove("open");
}

$("btn-close-code").onclick = closeCodeModal;
$("btn-cancel-code").onclick = closeCodeModal;
$("code-modal").addEventListener("click", (ev) => {
  if (ev.target === $("code-modal")) closeCodeModal();
});

const codeBodyInp = $<HTMLTextAreaElement>("inp-code-body");
codeBodyInp.addEventListener("keydown", (ev) => {
  if (ev.key === "Tab") {
    ev.preventDefault();
    const s = codeBodyInp.selectionStart;
    const e = codeBodyInp.selectionEnd;
    codeBodyInp.value = codeBodyInp.value.slice(0, s) + "  " +
      codeBodyInp.value.slice(e);
    codeBodyInp.selectionStart = codeBodyInp.selectionEnd = s + 2;
  } else if (ev.key === "Enter" && (ev.ctrlKey || ev.metaKey)) {
    ev.preventDefault();
    $<HTMLFormElement>("code-form").requestSubmit();
  }
});

$<HTMLFormElement>("code-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const buf = buffers.get(activeBuf);
  if (!buf || buf.name === "*status") return;
  const code = codeBodyInp.value;
  if (!code.trim()) return;
  const lang = $<HTMLSelectElement>("sel-code-lang").value || "text";
  const title = $<HTMLInputElement>("inp-code-title").value.trim();
  const target = buf.name;
  closeCodeModal();
  codeBodyInp.value = "";
  $<HTMLInputElement>("inp-code-title").value = "";

  try {
    const raw = new TextEncoder().encode(code);
    if (e2ee.isBufferEncrypted(target)) {
      const enc = encryptAttachment(raw);
      const up = await uploadBinaryFile(enc.ciphertext, "encrypted.bin");
      if (!up) return;
      const payload = E2EE_ATT_PREFIX + JSON.stringify({
        v: 1,
        kind: "paste",
        id: up.id,
        lang,
        title,
        key: enc.key,
        iv: enc.iv,
        sha256: enc.sha256,
      });
      const ok = await e2ee.sendEncrypted(target, payload);
      if (ok) addLine(target, { nick: myNick, text: payload, encrypted: true });
      return;
    }
    const up = await uploadBinaryFile(raw, (title || "snippet") + ".txt");
    if (!up) return;
    const titleTag = title
      ? `;${PASTE_TITLE_TAG}=${encodeURIComponent(title)}`
      : "";
    const label = title ? `${title} (${lang})` : lang;
    sendRaw(
      `@${PASTE_TAG}=${up.id};${PASTE_LANG_TAG}=${lang}${titleTag} PRIVMSG ${target} :[Code: ${label}] /api/files/${up.id}`,
    );
  } catch (e) {
    addLine(target, {
      text: t("file.err.upload", { reason: errorMessage(e) }),
      kind: "err",
    });
  }
});

// Channel Moderation Modal (operators only)
const MOD_MODES: Array<{ flag: string; label: string }> = [
  { flag: "m", label: "+m Moderated" },
  { flag: "i", label: "+i Invite-only" },
  { flag: "t", label: "+t Op Topic" },
  { flag: "n", label: "+n No External" },
  { flag: "s", label: "+s Secret" },
];

function renderModModal(): void {
  const buf = buffers.get(activeBuf);
  if (!buf || !isChan(buf.name)) return;
  $("mod-modal-title").textContent = `${t("mod.title")} — ${buf.name}`;

  const grid = $("mod-mode-grid");
  grid.textContent = "";
  for (const m of MOD_MODES) {
    const active = buf.modes.has(m.flag);
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "small mod-mode-btn" + (active ? " active" : "");
    btn.textContent = m.label;
    btn.onclick = () => {
      sendRaw(`MODE ${buf.name} ${active ? "-" : "+"}${m.flag}`);
    };
    grid.appendChild(btn);
  }

  const banWrap = $("mod-ban-list");
  banWrap.textContent = "";
  if (buf.bans.length === 0) {
    const empty = document.createElement("div");
    empty.className = "muted";
    empty.textContent = t("mod.bans.empty");
    banWrap.appendChild(empty);
  } else {
    for (const mask of buf.bans) {
      const row = document.createElement("div");
      row.className = "mod-ban-row";
      const code = document.createElement("span");
      code.className = "mono";
      code.textContent = mask;
      const unban = document.createElement("button");
      unban.type = "button";
      unban.className = "small";
      unban.textContent = t("mod.unban");
      unban.onclick = () => {
        sendRaw(`MODE ${buf.name} -b ${mask}`);
        buf.bans = buf.bans.filter((b) => b !== mask);
        renderModModal();
      };
      row.appendChild(code);
      row.appendChild(unban);
      banWrap.appendChild(row);
    }
  }
}

function openModModal(): void {
  const buf = buffers.get(activeBuf);
  if (!buf || !isOperatorInBuffer(buf)) return;
  buf.bans = [];
  sendRaw(`MODE ${buf.name}`);
  sendRaw(`MODE ${buf.name} +b`);
  renderModModal();
  $("mod-modal").classList.add("open");
}

function closeModModal(): void {
  $("mod-modal").classList.remove("open");
}

$("btn-mod").onclick = openModModal;
$("btn-close-mod").onclick = closeModModal;
$("mod-modal").addEventListener("click", (ev) => {
  if (ev.target === $("mod-modal")) closeModModal();
});

$<HTMLFormElement>("mod-invite-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  const buf = buffers.get(activeBuf);
  const inp = $<HTMLInputElement>("inp-mod-invite");
  const targetNick = inp.value.trim();
  if (buf && isChan(buf.name) && targetNick) {
    sendRaw(`INVITE ${targetNick} ${buf.name}`);
    inp.value = "";
  }
});

$<HTMLFormElement>("mod-notice-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  const buf = buffers.get(activeBuf);
  const inp = $<HTMLInputElement>("inp-mod-notice");
  const msg = inp.value.trim();
  if (buf && isChan(buf.name) && msg) {
    sendRaw(`NOTICE ${buf.name} :${msg}`);
    inp.value = "";
  }
});

$<HTMLFormElement>("mod-ban-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  const buf = buffers.get(activeBuf);
  const inp = $<HTMLInputElement>("inp-mod-ban");
  const mask = inp.value.trim();
  if (buf && isChan(buf.name) && mask) {
    sendRaw(`MODE ${buf.name} +b ${mask}`);
    if (!buf.bans.includes(mask)) buf.bans.push(mask);
    inp.value = "";
    renderModModal();
  }
});

// Channel Discovery Modal (LIST / 322 / 323)
interface DiscoveredChannel {
  name: string;
  users: number;
  topic: string;
}
let discoverChannels: DiscoveredChannel[] = [];
let discoverLoading = false;

function renderDiscoverList(): void {
  const wrap = $("discover-list");
  wrap.textContent = "";
  if (discoverLoading && discoverChannels.length === 0) {
    const msg = document.createElement("div");
    msg.className = "muted discover-empty";
    msg.textContent = t("discover.loading");
    wrap.appendChild(msg);
    return;
  }
  const q = $<HTMLInputElement>("inp-discover-filter").value.trim()
    .toLowerCase();
  const filtered = discoverChannels
    .filter((c) =>
      !q || c.name.toLowerCase().includes(q) ||
      c.topic.toLowerCase().includes(q)
    )
    .sort((a, b) => b.users - a.users || a.name.localeCompare(b.name));

  if (filtered.length === 0) {
    const msg = document.createElement("div");
    msg.className = "muted discover-empty";
    msg.textContent = t("discover.empty");
    wrap.appendChild(msg);
    return;
  }

  for (const ch of filtered) {
    const row = document.createElement("div");
    row.className = "discover-row";

    const info = document.createElement("div");
    info.className = "discover-info";

    const top = document.createElement("div");
    top.className = "discover-top";
    const nameEl = document.createElement("strong");
    nameEl.dir = "ltr";
    nameEl.textContent = ch.name;
    const countEl = document.createElement("span");
    countEl.className = "discover-count";
    countEl.textContent = t("discover.users", { count: ch.users });
    top.appendChild(nameEl);
    top.appendChild(countEl);

    info.appendChild(top);
    if (ch.topic) {
      const topicEl = document.createElement("div");
      topicEl.className = "discover-topic muted";
      topicEl.dir = "auto";
      topicEl.textContent = ch.topic;
      info.appendChild(topicEl);
    }

    const joined = buffers.has(ch.name.toLowerCase());
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = joined ? "small" : "small primary";
    btn.textContent = joined ? t("discover.open") : t("btn.join");
    btn.onclick = () => {
      closeDiscoverModal();
      if (joined) {
        switchBuf(ch.name.toLowerCase());
      } else {
        sendRaw(`JOIN ${ch.name}`);
      }
    };

    row.appendChild(info);
    row.appendChild(btn);
    wrap.appendChild(row);
  }
}

function requestDiscoverList(): void {
  discoverChannels = [];
  discoverLoading = true;
  renderDiscoverList();
  sendRaw("LIST");
}

function openDiscoverModal(): void {
  closeDrawers();
  $("discover-modal").classList.add("open");
  requestDiscoverList();
  $<HTMLInputElement>("inp-discover-filter").focus();
}

function closeDiscoverModal(): void {
  $("discover-modal").classList.remove("open");
  discoverLoading = false;
}

$("btn-discover").onclick = openDiscoverModal;
$("btn-close-discover").onclick = closeDiscoverModal;
$("btn-discover-refresh").onclick = requestDiscoverList;
$("inp-discover-filter").addEventListener("input", renderDiscoverList);
$("discover-modal").addEventListener("click", (ev) => {
  if (ev.target === $("discover-modal")) closeDiscoverModal();
});

// Keep chat workspace pinned cleanly above the iOS software keyboard
if (globalThis.visualViewport) {
  const syncViewport = (): void => {
    const vv = globalThis.visualViewport;
    if (!vv) return;
    const chat = $("chat-view");
    if (!chat.classList.contains("active")) return;
    const msgs = $("messages");
    const wasAtBottom = msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight <
      80;
    chat.style.height = `${Math.round(vv.height)}px`;
    globalThis.scrollTo(0, 0);
    if (wasAtBottom) msgs.scrollTop = msgs.scrollHeight;
  };
  globalThis.visualViewport.addEventListener("resize", syncViewport);
  globalThis.visualViewport.addEventListener("scroll", syncViewport);
}

// Scroll-to-bottom floating button
const scrollFab = $("btn-scroll-bottom");
const msgsEl = $("messages");
function updateScrollFab(): void {
  const dist = msgsEl.scrollHeight - msgsEl.scrollTop - msgsEl.clientHeight;
  scrollFab.classList.toggle("hidden", dist < 180);
}
msgsEl.addEventListener("scroll", updateScrollFab, { passive: true });
scrollFab.addEventListener("click", () => {
  msgsEl.scrollTo({ top: msgsEl.scrollHeight, behavior: "smooth" });
});

// Edge swipe gesture to open/close Channels drawer on touch devices
let edgeStartX = 0;
let edgeStartY = 0;
let edgeActive = false;
document.addEventListener("touchstart", (ev) => {
  if (ev.touches.length !== 1) return;
  const x = ev.touches[0].clientX;
  const y = ev.touches[0].clientY;
  const isRtl = document.documentElement.dir === "rtl";
  const drawerOpen = $("sidebar-left").classList.contains("open");
  const nearEdge = isRtl ? x > globalThis.innerWidth - 28 : x < 28;
  if (nearEdge || drawerOpen) {
    edgeStartX = x;
    edgeStartY = y;
    edgeActive = true;
  } else {
    edgeActive = false;
  }
}, { passive: true });

document.addEventListener("touchend", (ev) => {
  if (!edgeActive || ev.changedTouches.length !== 1) return;
  edgeActive = false;
  const dx = ev.changedTouches[0].clientX - edgeStartX;
  const dy = ev.changedTouches[0].clientY - edgeStartY;
  if (Math.abs(dx) < 56 || Math.abs(dx) < Math.abs(dy) * 1.5) return;
  const isRtl = document.documentElement.dir === "rtl";
  const openSwipe = isRtl ? dx < 0 : dx > 0;
  const drawerOpen = $("sidebar-left").classList.contains("open");
  if (openSwipe && !drawerOpen) {
    toggleDrawer("left");
  } else if (!openSwipe && drawerOpen) {
    closeDrawers();
  }
}, { passive: true });

// Auto-restore saved WebIRC session across page refreshes
(function restoreSavedSession() {
  const saved = loadSession();
  if (!saved) return;
  $<HTMLInputElement>("inp-nick").value = saved.nick;
  $<HTMLInputElement>("inp-acct").value = saved.acct;
  $<HTMLInputElement>("inp-pass").value = saved.pass;
  $<HTMLInputElement>("inp-channels").value = saved.channels.join(",");
  $<HTMLInputElement>("inp-ws").value = saved.wsUrl;
  const pathBuf = pathToBuffer(location.pathname);
  startSession({
    nick: saved.nick,
    acct: saved.acct,
    pass: saved.pass,
    channels: saved.channels,
    wsUrl: saved.wsUrl,
    targetBuf: pathBuf || saved.activeBuf,
  });
})();
