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
import { isChan, nickColor } from "./util.ts";

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

export function buildBufRow(buf: BufferState, key: string): HTMLElement {
  const item = document.createElement("div");
  item.className = "buf-item" + (key === S.activeBuf ? " active" : "");

  const label = document.createElement("span");
  label.className = "buf-name";
  if (key !== "*status" && e2ee.isBufferEncrypted(buf.name)) {
    const lock = document.createElement("span");
    lock.className = "buf-lock";
    lock.textContent = "🔒";
    label.appendChild(lock);
  }
  const presence = key !== "*status" && !isChan(buf.name)
    ? presenceClass(buf.name)
    : "";
  if (presence) {
    const dot = document.createElement("span");
    dot.className = `buf-presence ${presence}`;
    dot.title = presenceText(buf.name);
    label.appendChild(dot);
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
        monitorRemove(buf.name);
        if (S.activeBuf === key) switchBuf("*status");
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
  const amOp = isOperatorInBuffer(buf);
  for (const [nick, prefix] of sorted) {
    const info = peekUser(nick);
    const row = document.createElement("div");
    row.className = "member-item" + (info?.away !== undefined ? " away" : "");
    row.title = userTooltip(nick);
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
    name.dir = "auto";
    name.textContent = displayNameOf(nick);
    row.appendChild(name);
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
        switchBuf(ircFold(nick));
      }
    };
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
