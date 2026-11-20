// Switching conversations, the conversation list, members list, and drawers.
import { byId as $ } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { ircFold } from "../common/ircv3.ts";
import { ensureBuf, updateTitle } from "./buffers.ts";
import { updateCallButton } from "./calls_ui.ts";
import { sendRaw } from "./connection.ts";
import { e2ee, updateE2eeUi } from "./e2ee_ui.ts";
import { clearComposeMode } from "./message_actions.ts";
import { renderMessages } from "./chat/list.ts";
import { restorePosition, savedWindow, savePosition } from "./chat/scroll.ts";
import { bufferToPath, saveSession } from "./session.ts";
import { settings } from "./settings.ts";
import { buffers, S } from "./state.ts";
import { type BufferState } from "./types.ts";
import { renderTypingBar } from "./typing.ts";
import {
  bufSubtitle,
  displayNameOf,
  markActiveRead,
  monitorRemove,
  peekUser,
  presenceClass,
  presenceText,
  userTooltip,
} from "./users.ts";
import { isChan } from "./util.ts";
import { iconEl } from "../common/icons.ts";
import { createAvatar } from "./chat/avatar.ts";
import { scheduleHistorySave } from "./history_cache.ts";

export function closeDrawers(): void {
  $("sidebar-left").classList.remove("open");
  $("sidebar-right").classList.remove("open");
  $("drawer-backdrop").classList.remove("open");
}

export function toggleDrawer(side: "left" | "right"): void {
  const el = $(side === "left" ? "sidebar-left" : "sidebar-right");
  const other = $(side === "left" ? "sidebar-right" : "sidebar-left");
  other.classList.remove("open");
  const next = !el.classList.contains("open");
  el.classList.toggle("open", next);
  $("drawer-backdrop").classList.toggle("open", next);
}

export function isOperatorInBuffer(buf: BufferState | undefined): boolean {
  if (!buf || !isChan(buf.name)) return false;
  if (S.isIrcOp) return true;
  const me = ircFold(S.myNick);
  for (const [memberNick, prefix] of buf.members.entries()) {
    if (ircFold(memberNick) === me) {
      return /[@&~]/.test(prefix || "");
    }
  }
  return false;
}

export function updateTopicButton(): void {
  const buf = buffers.get(S.activeBuf);
  const isOp = isOperatorInBuffer(buf);
  $("btn-topic").style.display = isOp ? "inline-flex" : "none";
  $("btn-mod").style.display = isOp ? "inline-flex" : "none";
}

export function switchBuf(key: string, updateUrl = true): void {
  const buf = buffers.get(key);
  if (!buf) return;
  closeDrawers();
  clearComposeMode();
  // The reader's place in the conversation being left is kept for later.
  if (S.activeBuf !== key) savePosition(S.activeBuf);
  S.activeBuf = key;
  buf.unread = 0;
  buf.mentions = 0;
  $("chat-head").dataset.kind = buf.name === "*status"
    ? "status"
    : isChan(buf.name)
    ? "channel"
    : "dm";
  const titleEl = $("active-title");
  titleEl.dir = buf.name === "*status" ? "auto" : "ltr";
  titleEl.textContent = buf.name === "*status" ? t("status.title") : buf.name;
  const topicEl = $("active-topic");
  topicEl.dir = "auto";
  topicEl.textContent = bufSubtitle(buf);
  updateTopicButton();

  S.renderWindow = savedWindow(key);
  renderMessages(buf, "bottom");
  restorePosition(key);
  renderTypingBar();
  updateE2eeUi();
  updateCallButton();
  renderBuffers();
  renderMembers();
  updateTitle();
  markActiveRead();
  if (updateUrl && $("chat-view").classList.contains("active")) {
    const nextPath = bufferToPath(buf.name);
    if (location.pathname !== nextPath) {
      history.replaceState({ buf: key }, "", nextPath);
    }
    saveSession();
  }
  $<HTMLTextAreaElement>("inp-msg").focus();
}

/** Show our nickname in the header and on the sidebar's user card. */
export function showMyNick(): void {
  $("my-nick").textContent = S.myNick;
  $("me-nick").textContent = S.myNick;
  $("me-avatar").replaceChildren(createAvatar(S.myNick));
}

/** Make a row act as a button for the keyboard (Enter or Space). */
function keyActivate(el: HTMLElement, fn: () => void): void {
  el.tabIndex = 0;
  el.onclick = fn;
  el.onkeydown = (ev) => {
    if (ev.target !== el) return;
    if (ev.key === "Enter" || ev.key === " ") {
      ev.preventDefault();
      fn();
    }
  };
}

/** The glyph before a conversation: server, channel (or lock), or avatar. */
function bufLead(buf: BufferState, key: string): HTMLElement {
  const lead = document.createElement("span");
  lead.className = "buf-lead";
  if (key === "*status") {
    lead.appendChild(iconEl("server", 15));
  } else if (isChan(buf.name)) {
    const locked = e2ee.isBufferEncrypted(buf.name);
    lead.appendChild(iconEl(locked ? "lock" : "hash", 15));
    if (locked) lead.classList.add("locked");
  } else {
    lead.classList.add("buf-lead-avatar");
    lead.appendChild(createAvatar(buf.name));
    const presence = presenceClass(buf.name);
    if (presence) {
      const dot = document.createElement("span");
      dot.className = `buf-presence ${presence}`;
      dot.title = presenceText(buf.name);
      lead.appendChild(dot);
    }
  }
  return lead;
}

export function buildBufRow(buf: BufferState, key: string): HTMLElement {
  const item = document.createElement("div");
  const active = key === S.activeBuf;
  item.className = "buf-item" + (active ? " active" : "") +
    (buf.unread > 0 && !active ? " unread" : "");
  item.setAttribute("role", "listitem");
  if (active) item.setAttribute("aria-current", "page");
  item.appendChild(bufLead(buf, key));

  const label = document.createElement("span");
  label.className = "buf-name";
  const nameSpan = document.createElement("span");
  nameSpan.dir = buf.name === "*status" ? "auto" : "ltr";
  nameSpan.textContent = buf.name === "*status"
    ? t("status.short")
    : isChan(buf.name)
    ? buf.name.replace(/^#/, "")
    : displayNameOf(buf.name);
  label.appendChild(nameSpan);
  item.appendChild(label);
  item.title = buf.name === "*status" ? t("status.title") : buf.name;

  const right = document.createElement("span");
  right.className = "buf-right";
  if (buf.unread > 0) {
    const b = document.createElement("span");
    b.className = "buf-badge" + (buf.mentions > 0 ? " mention" : "");
    b.textContent = buf.unread > 99 ? "99+" : String(buf.unread);
    b.setAttribute(
      "aria-label",
      buf.mentions > 0
        ? t("badge.mentions", { count: buf.unread })
        : t("badge.unread", { count: buf.unread }),
    );
    right.appendChild(b);
  }
  if (key !== "*status") {
    const close = document.createElement("button");
    close.type = "button";
    close.className = "buf-close";
    close.title = isChan(buf.name) ? "Leave channel" : "Close conversation";
    close.setAttribute("aria-label", close.title);
    close.appendChild(iconEl("x", 14));
    close.onclick = (ev) => {
      ev.stopPropagation();
      if (isChan(buf.name)) {
        sendRaw(`PART ${buf.name}`);
      } else {
        buffers.delete(key);
        scheduleHistorySave();
        monitorRemove(buf.name);
        if (S.activeBuf === key) switchBuf("*status");
        else renderBuffers();
      }
    };
    right.appendChild(close);
  }
  item.appendChild(right);
  keyActivate(item, () => switchBuf(key));
  return item;
}

export function renderBuffers(): void {
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

export function roleRank(prefix: string): number {
  if (prefix.includes("@")) return 0;
  if (prefix.includes("+")) return 1;
  return 2;
}

/** Member list group of a channel prefix: operators, voiced, everyone else. */
function roleGroup(prefix: string): "ops" | "voiced" | "members" {
  const rank = roleRank(prefix);
  return rank === 0 ? "ops" : rank === 1 ? "voiced" : "members";
}

export function renderMembers(): void {
  const buf = buffers.get(S.activeBuf);
  const list = $("members-list");
  list.textContent = "";
  if (!buf || !isChan(buf.name)) {
    $("members-title").textContent = t("members.title");
    return;
  }
  const q = S.memberFilter.toLowerCase();
  const sorted = Array.from(buf.members.entries())
    .filter(([nick]) => !q || nick.toLowerCase().includes(q))
    .sort((a, b) => {
      const r = roleRank(a[1]) - roleRank(b[1]);
      return r !== 0 ? r : a[0].localeCompare(b[0]);
    });
  $("members-title").textContent = t("members.count", {
    count: buf.members.size,
  });
  if (sorted.length === 0) {
    const empty = document.createElement("div");
    empty.className = "members-empty";
    empty.textContent = t("members.none");
    list.appendChild(empty);
    return;
  }
  const amOp = isOperatorInBuffer(buf);
  let group = "";
  for (const [nick, prefix] of sorted) {
    const g = roleGroup(prefix);
    if (g !== group) {
      group = g;
      const head = document.createElement("div");
      head.className = "members-group";
      const count = sorted.filter(([, p]) => roleGroup(p) === g).length;
      head.textContent = `${t(`members.group.${g}`)} — ${count}`;
      list.appendChild(head);
    }
    const info = peekUser(nick);
    const row = document.createElement("div");
    row.className = "member-item" + (info?.away !== undefined ? " away" : "");
    row.title = userTooltip(nick);
    const lead = document.createElement("span");
    lead.className = "member-lead";
    lead.appendChild(createAvatar(nick));
    if (info?.away !== undefined) {
      const dot = document.createElement("span");
      dot.className = "buf-presence away";
      lead.appendChild(dot);
    }
    row.appendChild(lead);

    const name = document.createElement("span");
    name.className = "member-name";
    name.dir = "auto";
    name.textContent = displayNameOf(nick);
    row.appendChild(name);
    if (prefix) {
      const role = document.createElement("span");
      role.className = "member-role";
      role.textContent = prefix;
      role.title = /[@&~]/.test(prefix)
        ? t("members.role.op")
        : t("members.role.voice");
      row.appendChild(role);
    }
    if (info?.bot) {
      const bot = document.createElement("span");
      bot.className = "msg-bot";
      bot.textContent = t("badge.bot");
      row.appendChild(bot);
    }
    const isSelf = ircFold(nick) === ircFold(S.myNick);
    if (amOp && !isSelf) {
      const acts = document.createElement("div");
      acts.className = "member-mod-actions";
      const hasOp = /[@&~]/.test(prefix || "");
      const hasVoice = /\+/.test(prefix || "");
      const mkBtn = (
        label: string | SVGSVGElement,
        title: string,
        cls: string,
        fn: () => void,
      ): HTMLButtonElement => {
        const b = document.createElement("button");
        b.type = "button";
        b.className = `member-mod-btn ${cls}`;
        if (typeof label === "string") b.textContent = label;
        else b.appendChild(label);
        b.setAttribute("aria-label", title);
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
          iconEl("x", 13),
          `Kick ${nick}`,
          "danger",
          () => sendRaw(`KICK ${buf.name} ${nick} :Removed by moderator`),
        ),
      );
      acts.appendChild(
        mkBtn(iconEl("ban", 13), `Kick & Ban ${nick}`, "danger", () => {
          sendRaw(`MODE ${buf.name} +b ${nick}!*@*`);
          sendRaw(`KICK ${buf.name} ${nick} :Banned by moderator`);
        }),
      );
      row.appendChild(acts);
    }

    keyActivate(row, () => {
      if (!isSelf) {
        ensureBuf(nick);
        switchBuf(ircFold(nick));
      }
    });
    list.appendChild(row);
  }
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
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
}
