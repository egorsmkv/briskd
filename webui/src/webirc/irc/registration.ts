// Registration: welcome, nickname in use, ISUPPORT, heartbeat replies.
import { renderBuffers, showMyNick } from "../sidebar.ts";
import { t } from "../../common/i18n.ts";
import { ircFold } from "../../common/ircv3.ts";
import { altNick, rejoinList } from "../../common/reconnect.ts";
import { addLine, ensureBuf, updateTitle } from "../buffers.ts";
import { capOn, isupport } from "../caps.ts";
import {
  catchUp,
  clearTimer,
  hideReconnectBar,
  historyAfter,
  metadataSubscribe,
  sendRaw,
  STABLE_MS,
  startHeartbeat,
} from "../connection.ts";
import { e2ee } from "../e2ee_ui.ts";
import { buffers, S } from "../state.ts";
import type { IrcMessage } from "../types.ts";
import { dmNames, monitorAdd, requestMarker } from "../users.ts";
import { isChan } from "../util.ts";

/** Conversations with history asked for after registering. */
const DM_TARGETS = 50;

/**
 * Registration: welcome, nickname in use, ISUPPORT, heartbeat replies.
 * Returns true when the line was handled.
 */
export function handleRegistration(
  msg: IrcMessage,
  time: string | undefined,
): boolean {
  const { command, params } = msg;

  if (command === "001") {
    S.myNick = params[0] || S.myNick;
    S.isRegistered = true;
    showMyNick();
    e2ee.setMyNick(S.myNick);
    e2ee.onRegistered();
    updateTitle();
    addLine("*status", { time, text: params[1] || "Connected", kind: "sys" });
    catchUp.clear();
    if (S.reconnecting) {
      addLine("*status", { time, text: t("rc.reconnected"), kind: "sys" });
      // Rejoined channels fetch what was missed instead of the latest page,
      // and do not take over the conversation the user is looking at.
      buffers.forEach((b) => {
        if (isChan(b.name)) catchUp.add(ircFold(b.name));
      });
    }
    // Private conversations (kept across a reload, or still open after a
    // reconnect) fetch what they missed; a logged-in user's conversations
    // that are not open yet come back through TARGETS.
    if (capOn("draft/chathistory")) {
      for (const dm of dmNames()) {
        const after = historyAfter(buffers.get(ircFold(dm)));
        sendRaw(
          after
            ? `CHATHISTORY AFTER ${dm} ${after} 100`
            : `CHATHISTORY LATEST ${dm} * 50`,
        );
      }
      if (S.account) {
        sendRaw(
          `CHATHISTORY TARGETS timestamp=${new Date().toISOString()} ` +
            `timestamp=1970-01-01T00:00:00.000Z ${DM_TARGETS}`,
        );
      }
    }
    S.reconnecting = false;
    hideReconnectBar();
    // Only a connection that lasts counts as recovered for the backoff.
    S.stableTimer = clearTimer(S.stableTimer);
    S.stableTimer = setTimeout(() => {
      S.reconnectAttempt = 0;
    }, STABLE_MS);
    if (S.preferredNick && ircFold(S.myNick) !== ircFold(S.preferredNick)) {
      addLine("*status", {
        time,
        text: t("rc.altnick", { nick: S.preferredNick, alt: S.myNick }),
        kind: "sys",
      });
    }
    // Subscribe before joining so the joins carry members' metadata.
    if (capOn("draft/metadata-2")) metadataSubscribe();
    // After a reconnect, the channels still open here are rejoined too.
    const open: string[] = [];
    buffers.forEach((b) => {
      if (isChan(b.name)) open.push(b.name);
    });
    for (const ch of rejoinList(open, S.autoChannels, ircFold)) {
      sendRaw(`JOIN ${ch}`);
    }
    for (const dm of dmNames()) requestMarker(dm);
    startHeartbeat();
    return true;
  }

  // 433: the nickname is taken, typically by our own previous connection the
  // server has not dropped yet. 437: the server holds it for a while after
  // that connection went away (a page reload). Either way, register with a
  // fallback and retake the nickname later (see the heartbeat); without a
  // fallback, registration would stall with no nickname.
  // A conversation with history (CHATHISTORY TARGETS, IRCv3
  // draft/chathistory): reopen a private one we do not have yet.
  if (command === "CHATHISTORY" && params[0] === "TARGETS") {
    const target = params[1] || "";
    if (target && !isChan(target) && !buffers.has(ircFold(target))) {
      ensureBuf(target);
      renderBuffers();
      sendRaw(`CHATHISTORY LATEST ${target} * 50`);
    }
    return true;
  }

  const nickRefused = command === "433" ||
    (command === "437" && !isChan(params[1] || ""));
  if (nickRefused && !S.isRegistered) {
    S.nickAttempt++;
    if (S.nickAttempt > 20) return true;
    S.myNick = altNick(S.myNick, S.nickLen, S.nickAttempt);
    sendRaw(`NICK ${S.myNick}`);
    return true;
  }

  if (nickRefused && S.regainPending) {
    S.regainPending = false; // still held; try again on the next heartbeat
    return true;
  }

  if (command === "005") {
    const nl = params.slice(1, -1).find((tok) => tok.startsWith("NICKLEN="));
    const n = nl ? parseInt(nl.slice(8), 10) : NaN;
    if (Number.isFinite(n) && n > 0) S.nickLen = n;
    for (const tok of params.slice(1, -1)) {
      if (tok.startsWith("-")) {
        isupport.delete(tok.slice(1).toUpperCase());
        continue;
      }
      const eq = tok.indexOf("=");
      isupport.set(
        (eq === -1 ? tok : tok.slice(0, eq)).toUpperCase(),
        eq === -1 ? "" : tok.slice(eq + 1),
      );
    }
    monitorAdd(dmNames());
    return true;
  }

  if (command === "303") {
    // With labeled-response our probe's reply carries `label=hb`; otherwise
    // the oldest unanswered probe claims the next 303.
    if (msg.tags.label === "hb") {
      S.heartbeatPending = 0;
      return true;
    }
    if (!capOn("labeled-response") && S.heartbeatPending > 0) {
      S.heartbeatPending--;
      return true;
    }
  }

  if (command === "ACK") return true;
  return false;
}
