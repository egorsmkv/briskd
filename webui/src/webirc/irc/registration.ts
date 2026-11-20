// Registration: welcome, nickname in use, ISUPPORT, heartbeat replies.
import { byId as $ } from "../../common/dom.ts";
import { t } from "../../common/i18n.ts";
import { ircFold } from "../../common/ircv3.ts";
import { altNick, rejoinList } from "../../common/reconnect.ts";
import { addLine, updateTitle } from "../buffers.ts";
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
    $("my-nick").textContent = S.myNick;
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
      if (capOn("draft/chathistory")) {
        for (const dm of dmNames()) {
          const after = historyAfter(buffers.get(ircFold(dm)));
          if (after) sendRaw(`CHATHISTORY AFTER ${dm} ${after} 100`);
        }
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

  if (command === "433" && !S.isRegistered) {
    // The nickname is taken, typically by our own previous connection that
    // the server has not dropped yet: register with a fallback and retake it
    // later (see the heartbeat).
    S.nickAttempt++;
    if (S.nickAttempt > 20) return true;
    S.myNick = altNick(S.myNick, S.nickLen, S.nickAttempt);
    sendRaw(`NICK ${S.myNick}`);
    return true;
  }

  if (command === "433" && S.regainPending) {
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
