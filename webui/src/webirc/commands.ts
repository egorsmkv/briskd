// Slash commands and /help.
import { byId as $ } from "../common/dom.ts";
import { ircFold, METADATA_KEYS } from "../common/ircv3.ts";
import { addLine, ensureBuf } from "./buffers.ts";
import { calls, startCall } from "./calls_ui.ts";
import { sendRaw, stopReconnecting } from "./connection.ts";
import { e2ee } from "./e2ee_ui.ts";
import { clearSession, isSafeIrcTarget } from "./session.ts";
import { openSettings } from "./settings.ts";
import { switchBuf } from "./sidebar.ts";
import { S } from "./state.ts";
import { type BufferState } from "./types.ts";
import { isChan } from "./util.ts";

export function showHelp(target: string): void {
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
    "/meta set <key> <value> | /meta clear <key> | /meta list [nick]",
    "/call [nick] | /hangup  (voice calls)",
    "/e2ee [on|off|status|rotate|verify|reset]",
    "/oper <name> <pass> | /kill <nick> <reason> | /rehash",
    "/clear | /raw <line> | /quit [reason]",
  ];
  addLine(target, { text: `Commands:\n${cmds.join("\n")}`, kind: "sys" });
}

export function runSlashCommand(
  raw: string,
  buf: BufferState | undefined,
): void {
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
        switchBuf(ircFold(dest));
        sendRaw(`PRIVMSG ${dest} :${text}`);
      } else if (rest) {
        ensureBuf(rest);
        switchBuf(ircFold(rest));
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
    case "call": {
      const who = rest.trim() ||
        (buf && buf.name !== "*status" && !isChan(buf.name) ? buf.name : "");
      if (who && !isChan(who) && isSafeIrcTarget(who)) startCall(who);
      else addLine(target, { text: "Usage: /call <nick>", kind: "err" });
      return;
    }
    case "hangup":
      calls.hangup();
      return;
    case "monitor":
      if (rest) sendRaw(`MONITOR ${rest}`);
      return;
    case "meta": {
      // /meta set <key> <value> | /meta clear <key> | /meta list [nick]
      const parts = rest.split(/\s+/).filter(Boolean);
      const sub = (parts[0] || "list").toLowerCase();
      const key = parts[1] || "";
      const validKey = /^[a-z0-9_.\/-]{1,64}$/.test(key);
      if (sub === "set" && validKey && parts.length >= 3) {
        const value = rest.replace(/^\S+\s+\S+\s+/, "").trim();
        S.metaEchoUntil = Date.now() + 5000;
        sendRaw(`METADATA * SET ${key} :${value}`);
      } else if (sub === "clear" && validKey) {
        S.metaEchoUntil = Date.now() + 5000;
        sendRaw(`METADATA * SET ${key}`);
      } else if (sub === "list") {
        const who = parts[1] && isSafeIrcTarget(parts[1]) ? parts[1] : "*";
        S.metaEchoUntil = Date.now() + 5000;
        sendRaw(`METADATA ${who} LIST`);
      } else {
        addLine(target, {
          text:
            `Usage: /meta set <key> <value> | /meta clear <key> | /meta list [nick]. Keys: ${
              METADATA_KEYS.join(", ")
            }`,
          kind: "err",
        });
      }
      return;
    }
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
        S.domLines = 0;
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
        const who = ircFold(
          parts[1] || (!isChan(target) && target !== "*status" ? target : ""),
        );
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
      S.userClosed = true;
      stopReconnecting();
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
