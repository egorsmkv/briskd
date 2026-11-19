import { initTheme } from "./common/theme.ts";

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

initTheme([$("btn-theme-1"), $("btn-theme-2")]);

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
const buffers = new Map<string, BufferState>();
const sentHistory: string[] = [];
let histPos = -1;

function updateTitle(): void {
  let totalUnread = 0;
  let totalMentions = 0;
  buffers.forEach((b) => {
    totalUnread += b.unread;
    totalMentions += b.mentions;
  });
  if (totalMentions > 0) document.title = `(@${totalMentions}) ${BASE_TITLE}`;
  else if (totalUnread > 0) document.title = `(${totalUnread}) ${BASE_TITLE}`;
  else document.title = BASE_TITLE;
}

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
  };
  const prev = buf.lines[buf.lines.length - 1];
  buf.lines.push(entry);
  if (buf.lines.length > 600) buf.lines.shift();

  if (bufName.toLowerCase() === activeBuf) {
    appendLineDom(entry, prev);
  } else {
    buf.unread += 1;
    if (mention) buf.mentions += 1;
    renderBuffers();
    updateTitle();
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
  label.textContent = buf.name === "*status" ? "Server" : buf.name;
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
  if (command === "CAP") {
    const sub = (params[1] || "").toUpperCase();
    if (sub === "LS") {
      const caps = [
        "message-tags",
        "server-time",
        "echo-message",
        "batch",
        "draft/chathistory",
        "away-notify",
        "account-notify",
        "extended-join",
      ];
      if (saslPass) caps.push("sasl");
      sendRaw(`CAP REQ :${caps.join(" ")}`);
    } else if (sub === "ACK") {
      if (saslPass && (params[2] || "").includes("sasl")) {
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
  if (command === "903") {
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
    $("my-nick").textContent = myNick;
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
    addLine(chan, { time, text: `${nick} joined ${chan}`, kind: "sys" });
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
        addLine(chan, { time, text: `${nick} left (${params[1] || ""})`, kind: "sys" });
        renderMembers();
      }
    }
    return;
  }
  if (command === "QUIT") {
    buffers.forEach((buf) => {
      if (buf.members.has(nick)) {
        buf.members.delete(nick);
        addLine(buf.name, { time, text: `${nick} quit (${params[0] || ""})`, kind: "sys" });
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
  if (ws && ws.readyState === WebSocket.OPEN) {
    sendRaw("QUIT :Leaving WebIRC");
    ws.close();
  }
  ws = null;
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
  sendRaw(`PRIVMSG ${buf.name} :${raw}`);
});
