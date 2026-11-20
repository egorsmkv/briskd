// Channel membership, nick changes, topics, modes, invites, and LIST.
import { byId as $ } from "../../common/dom.ts";
import { showMyNick } from "../sidebar.ts";
import {
  ircFold,
  parseNamesEntry,
  prefixCharsFromIsupport,
  WHOX_FIELDS,
} from "../../common/ircv3.ts";
import { addLine, ensureBuf } from "../buffers.ts";
import { refreshIntro } from "../chat/list.ts";
import { capOn, isupport } from "../caps.ts";
import { catchUp, historyAfter, sendRaw } from "../connection.ts";
import { e2ee } from "../e2ee_ui.ts";
import { renderDiscoverList, renderModModal } from "../modals.ts";
import { saveSession } from "../session.ts";
import { settings } from "../settings.ts";
import {
  renderBuffers,
  renderMembers,
  switchBuf,
  updateTopicButton,
} from "../sidebar.ts";
import { buffers, S } from "../state.ts";
import type { IrcMessage } from "../types.ts";
import {
  monitored,
  pendingWho,
  userhostOf,
  userInfo,
  users,
} from "../users.ts";
import { isChan } from "../util.ts";

/**
 * Channel membership, nick changes, topics, modes, invites, and LIST.
 * Returns true when the line was handled.
 */
export function handleChannels(
  msg: IrcMessage,
  time: string | undefined,
): boolean {
  const { command, params, nick } = msg;

  if (command === "JOIN") {
    const chan = params[0];
    const buf = ensureBuf(chan);
    buf.members.set(nick, "");
    const joiner = userInfo(nick);
    const joinHost = userhostOf(msg.prefix);
    if (joinHost) joiner.userhost = joinHost;
    if (params.length >= 3) {
      // extended-join: JOIN <channel> <account|*> :<realname>
      joiner.account = params[1] !== "*" ? params[1] : undefined;
      joiner.realname = params[2];
    }
    if (ircFold(nick) === ircFold(S.myNick)) {
      const rejoin = catchUp.delete(ircFold(chan));
      if (rejoin) {
        renderBuffers();
      } else if (!S.desiredBuf || S.desiredBuf === ircFold(chan)) {
        switchBuf(ircFold(chan));
        S.desiredBuf = "";
      } else {
        renderBuffers();
      }
      saveSession();
      const after = rejoin ? historyAfter(buf) : null;
      sendRaw(
        after
          ? `CHATHISTORY AFTER ${chan} ${after} 100`
          : `CHATHISTORY LATEST ${chan} * 50`,
      );
      if (isupport.has("WHOX")) {
        // One WHOX reply gives prefixes, away, bot, and account per member.
        pendingWho.add(ircFold(chan));
        sendRaw(`WHO ${chan} ${WHOX_FIELDS}`);
      } else if (capOn("no-implicit-names")) {
        sendRaw(`NAMES ${chan}`);
      }
    }
    if (settings.joinPart) {
      addLine(chan, { time, text: `${nick} joined ${chan}`, kind: "sys" });
    }
    renderMembers();
    return true;
  }

  if (command === "PART") {
    const chan = params[0];
    const buf = buffers.get(ircFold(chan));
    if (buf) {
      buf.members.delete(nick);
      if (ircFold(nick) === ircFold(S.myNick)) {
        buffers.delete(ircFold(chan));
        if (S.activeBuf === ircFold(chan)) switchBuf("*status");
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
    return true;
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
    if (nick && !monitored.has(ircFold(nick))) {
      users.delete(ircFold(nick));
    }
    renderMembers();
    return true;
  }

  if (command === "NICK") {
    const next = params[0];
    const moved = users.get(ircFold(nick));
    if (moved && next && !monitored.has(ircFold(nick))) {
      users.delete(ircFold(nick));
      users.set(ircFold(next), moved);
    }
    if (ircFold(nick) === ircFold(S.myNick)) {
      S.myNick = next;
      // A nick change of ours (from /nick, or retaking the preferred nick)
      // is what a reconnect registers with next time.
      S.preferredNick = next;
      S.regainPending = false;
      showMyNick();
      e2ee.setMyNick(S.myNick);
      saveSession();
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
    return true;
  }

  if (command === "332") {
    const chan = params[1];
    const buf = ensureBuf(chan);
    buf.topic = params[2] || "";
    if (S.activeBuf === ircFold(chan)) {
      $("active-topic").textContent = buf.topic;
      refreshIntro(buf);
    }
    addLine(chan, { time, text: `Topic: ${buf.topic}`, kind: "sys" });
    return true;
  }

  if (command === "TOPIC") {
    const chan = params[0];
    const buf = ensureBuf(chan);
    buf.topic = params[1] || "";
    if (S.activeBuf === ircFold(chan)) {
      $("active-topic").textContent = buf.topic;
      refreshIntro(buf);
    }
    addLine(chan, {
      time,
      text: `${nick} set topic: ${buf.topic}`,
      kind: "sys",
    });
    return true;
  }

  if (command === "353") {
    const chan = params[2];
    const buf = ensureBuf(chan);
    const prefixChars = prefixCharsFromIsupport(isupport.get("PREFIX"));
    for (const raw of (params[3] || "").split(" ").filter(Boolean)) {
      const entry = parseNamesEntry(raw, prefixChars);
      if (!entry) continue;
      buf.members.set(entry.nick, entry.prefix);
      if (entry.userhost) userInfo(entry.nick).userhost = entry.userhost;
    }
    renderMembers();
    updateTopicButton();
    return true;
  }

  if (command === "381") {
    S.isIrcOp = true;
    updateTopicButton();
    addLine("*status", {
      time,
      text: params[1] || "You are now an IRC operator",
      kind: "sys",
    });
    return true;
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
      S.activeBuf === ircFold(chan) &&
      $("mod-modal").classList.contains("open")
    ) {
      renderModModal();
    }
    return true;
  }

  if (command === "367") {
    const chan = params[1];
    const mask = params[2];
    if (chan && mask) {
      const buf = ensureBuf(chan);
      if (!buf.bans.includes(mask)) buf.bans.push(mask);
      if (
        S.activeBuf === ircFold(chan) &&
        $("mod-modal").classList.contains("open")
      ) {
        renderModModal();
      }
    }
    return true;
  }

  if (command === "368") {
    if ($("mod-modal").classList.contains("open")) renderModModal();
    return true;
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
        S.activeBuf === ircFold(target) &&
        $("mod-modal").classList.contains("open")
      ) {
        renderModModal();
      }
    } else {
      const modes = params[1] || "";
      if (ircFold(target) === ircFold(S.myNick)) {
        if (modes.includes("+") && modes.includes("o")) S.isIrcOp = true;
        if (modes.includes("-") && modes.includes("o")) S.isIrcOp = false;
        updateTopicButton();
      }
      addLine("*status", {
        time,
        text: `Mode ${target} ${params.slice(1).join(" ")}`,
        kind: "sys",
      });
    }
    return true;
  }

  if (command === "INVITE") {
    const invitee = params[0] || "";
    if (invitee && ircFold(invitee) !== ircFold(S.myNick)) {
      // invite-notify: someone else in a shared channel was invited.
      const chan = params[1] || "";
      if (buffers.has(ircFold(chan))) {
        addLine(chan, {
          time,
          text: `${nick} invited ${invitee} to ${chan}`,
          kind: "sys",
        });
      }
      return true;
    }
    addLine("*status", {
      time,
      text: `${nick} invited you to ${params[1]}`,
      kind: "sys",
    });
    return true;
  }

  if (command === "KICK") {
    const chan = params[0];
    const victim = params[1];
    const buf = buffers.get(ircFold(chan));
    if (buf) buf.members.delete(victim);
    if (ircFold(victim) !== ircFold(S.myNick)) e2ee.onMemberLeft(chan);
    addLine(chan, {
      time,
      text: `${victim} was kicked by ${nick} (${params[2] || ""})`,
      kind: "err",
    });
    renderMembers();
    return true;
  }

  if (command === "322") {
    const chan = params[1] || "";
    const users = parseInt(params[2] || "0", 10) || 0;
    const topic = params[3] || "";
    if (S.discoverLoading || $("discover-modal").classList.contains("open")) {
      if (chan) {
        S.discoverChannels.push({ name: chan, users, topic });
        renderDiscoverList();
      }
      return true;
    }
    addLine("*status", {
      time,
      text: `${chan} (${users} users) ${topic}`,
      kind: "sys",
    });
    return true;
  }

  if (command === "323") {
    if (S.discoverLoading || $("discover-modal").classList.contains("open")) {
      S.discoverLoading = false;
      renderDiscoverList();
      return true;
    }
    return true;
  }
  return false;
}
