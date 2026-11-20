// User state: away, account, host, realname, read markers, metadata, MONITOR, WHOX.
import {
  ircFold,
  markerToMs,
  parseMonitorTargets,
  parseWhoxReply,
  prefixCharsFromIsupport,
} from "../../common/ircv3.ts";
import { addLine } from "../buffers.ts";
import { isupport } from "../caps.ts";
import { buffers, S } from "../state.ts";
import type { IrcMessage } from "../types.ts";
import {
  applyMarker,
  applyMetadata,
  monitored,
  pendingWho,
  scheduleUserRender,
  userInfo,
} from "../users.ts";

/**
 * User state: away, account, host, realname, read markers, metadata, MONITOR, WHOX.
 * Returns true when the line was handled.
 */
export function handlePresence(
  msg: IrcMessage,
  time: string | undefined,
): boolean {
  const { command, params, nick } = msg;

  if (command === "AWAY") {
    // away-notify (and extended-monitor for monitored nicks).
    if (nick) {
      userInfo(nick).away = params.length > 0 ? params[0] : undefined;
      scheduleUserRender();
    }
    return true;
  }

  if (command === "ACCOUNT") {
    if (nick) {
      userInfo(nick).account = params[0] && params[0] !== "*"
        ? params[0]
        : undefined;
      scheduleUserRender();
    }
    return true;
  }

  if (command === "CHGHOST") {
    if (nick && params[0] && params[1]) {
      userInfo(nick).userhost = `${params[0]}@${params[1]}`;
    }
    return true;
  }

  if (command === "SETNAME") {
    if (nick) {
      userInfo(nick).realname = params[0] || "";
      if (ircFold(nick) === ircFold(S.myNick)) {
        addLine("*status", {
          time,
          text: `Real name set to: ${params[0] || ""}`,
          kind: "sys",
        });
      }
      scheduleUserRender();
    }
    return true;
  }

  if (command === "MARKREAD") {
    if (params[0]) applyMarker(params[0], markerToMs(params[1]));
    return true;
  }

  if (command === "METADATA") {
    // METADATA <target> <key> <visibility> [:<value>]; no value = cleared.
    applyMetadata(params[0], params[1], params[3]);
    return true;
  }

  if (command === "761" || command === "766") {
    // 761 <me> <target> <key> <visibility> :<value>; 766 = key not set.
    const value = command === "761" ? params[4] : undefined;
    applyMetadata(params[1], params[2], value);
    if (Date.now() < S.metaEchoUntil) {
      addLine("*status", {
        time,
        text: `${params[1]} ${params[2]}: ${value ?? "(not set)"}`,
        kind: "sys",
      });
    }
    return true;
  }

  if (["760", "762", "770", "771", "772"].includes(command)) return true;

  if (command === "730" || command === "731") {
    const online = command === "730";
    for (const target of parseMonitorTargets(params[1] || "")) {
      const u = userInfo(target.nick);
      u.online = online;
      if (!online) u.away = undefined;
      if (target.userhost) u.userhost = target.userhost;
      if (!monitored.has(ircFold(target.nick))) {
        addLine("*status", {
          time,
          text: `${target.nick} is ${online ? "online" : "offline"}`,
          kind: "sys",
        });
      }
    }
    scheduleUserRender();
    return true;
  }

  if (command === "354") {
    const entry = parseWhoxReply(params);
    if (entry) {
      const u = userInfo(entry.nick);
      u.away = entry.away ? (u.away ?? "") : undefined;
      u.bot = entry.bot;
      if (entry.account) u.account = entry.account;
      const chanKey = ircFold(entry.channel);
      const buf = buffers.get(chanKey);
      if (buf && pendingWho.has(chanKey)) {
        const prefixChars = prefixCharsFromIsupport(isupport.get("PREFIX"));
        const prefix = Array.from(entry.flags).filter((c) =>
          prefixChars.includes(c)
        ).join("");
        buf.members.set(entry.nick, prefix);
      }
      if (pendingWho.has(chanKey)) return true;
      scheduleUserRender();
    }
  }

  if (command === "315" && pendingWho.delete(ircFold(params[1] || ""))) {
    scheduleUserRender();
    return true;
  }
  return false;
}
