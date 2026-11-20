// The line above a message: display name (opens a private conversation),
// account handle when it differs, bot badge, time, and E2EE badge.
import { ircFold } from "../../common/ircv3.ts";
import { ensureBuf } from "../buffers.ts";
import { switchBuf } from "../sidebar.ts";
import { S } from "../state.ts";
import type { ChatLine } from "../types.ts";
import { botLabel, displayNameOf, peekUser, userTooltip } from "../users.ts";
import { nickClass } from "../util.ts";

export function createTime(entry: ChatLine, compact = false): HTMLElement {
  const time = document.createElement("span");
  time.className = compact ? "msg-time compact-time" : "msg-time";
  time.textContent = entry.time;
  return time;
}

export function createMeta(entry: ChatLine): HTMLElement {
  const meta = document.createElement("div");
  meta.className = "msg-meta";
  const name = displayNameOf(entry.nick);

  const nick = document.createElement("span");
  nick.className = `msg-nick ${nickClass(entry.nick, "nc")}`;
  nick.dir = "auto";
  nick.textContent = name;
  nick.title = userTooltip(entry.nick);
  nick.onclick = () => {
    if (ircFold(entry.nick) !== ircFold(S.myNick)) {
      ensureBuf(entry.nick);
      switchBuf(ircFold(entry.nick));
    }
  };
  meta.appendChild(nick);

  if (name !== entry.nick) {
    const handle = document.createElement("span");
    handle.className = "msg-handle";
    handle.dir = "ltr";
    handle.textContent = entry.nick;
    meta.appendChild(handle);
  }
  if (entry.bot || peekUser(entry.nick)?.bot) {
    const bot = document.createElement("span");
    bot.className = "msg-bot";
    bot.textContent = botLabel();
    meta.appendChild(bot);
  }
  meta.appendChild(createTime(entry));
  if (entry.encrypted) {
    const badge = document.createElement("span");
    badge.className = "msg-e2ee";
    badge.textContent = "E2EE";
    badge.title = "End-to-end encrypted";
    meta.appendChild(badge);
  }
  return meta;
}
