// Typing indicators (sent and received).
import { byId as $ } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { ircFold } from "../common/ircv3.ts";
import { msgInp } from "./composer.ts";
import { sendRaw } from "./connection.ts";
import { MAX_TYPERS_PER_BUF, TYPING_TAG } from "./constants.ts";
import { featureOn } from "./settings.ts";
import { buffers, S } from "./state.ts";

// Typing indicators (per-buffer remote typers with 6s expiry + throttled local send)
export const typingTimers = new Map<string, Map<string, number>>();

export function renderTypingBar(): void {
  const bar = $("typing-bar");
  if (!featureOn("typing")) {
    bar.classList.add("hidden");
    return;
  }
  const map = typingTimers.get(S.activeBuf);
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

export function updateRemoteTyping(
  bufName: string,
  sender: string,
  state: string,
): void {
  const key = ircFold(bufName);
  let map = typingTimers.get(key);
  if (!map) {
    // Every message reports "done" for its sender; only a conversation with
    // someone typing gets an entry, and it goes when the last one stops.
    if (state !== "active") return;
    map = new Map();
    typingTimers.set(key, map);
  }
  const prev = map.get(sender);
  if (prev !== undefined) globalThis.clearTimeout(prev);
  if (state === "active") {
    if (!map.has(sender) && map.size >= MAX_TYPERS_PER_BUF) return;
    const tid = globalThis.setTimeout(() => {
      map?.delete(sender);
      if (map?.size === 0) typingTimers.delete(key);
      if (S.activeBuf === key) renderTypingBar();
    }, 6000);
    map.set(sender, tid);
  } else {
    map.delete(sender);
    if (map.size === 0) typingTimers.delete(key);
  }
  if (S.activeBuf === key) renderTypingBar();
}

export function sendTypingState(
  target: string,
  state: "active" | "done",
): void {
  if (
    !featureOn("typing") || !S.isRegistered || !target || target === "*status"
  ) {
    return;
  }
  if (state === "active") {
    const now = Date.now();
    if (S.lastTypingTarget === target && now - S.lastTypingSentAt < 3000) {
      return;
    }
    S.lastTypingSentAt = now;
    S.lastTypingTarget = target;
    sendRaw(`@${TYPING_TAG}=active TAGMSG ${target}`);
    if (S.localTypingStopTimer !== null) {
      globalThis.clearTimeout(S.localTypingStopTimer);
    }
    S.localTypingStopTimer = globalThis.setTimeout(() => {
      sendTypingState(target, "done");
    }, 5000);
  } else {
    if (S.localTypingStopTimer !== null) {
      globalThis.clearTimeout(S.localTypingStopTimer);
      S.localTypingStopTimer = null;
    }
    if (S.lastTypingTarget === target) {
      S.lastTypingTarget = "";
      S.lastTypingSentAt = 0;
      sendRaw(`@${TYPING_TAG}=done TAGMSG ${target}`);
    }
  }
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  msgInp.addEventListener("input", () => {
    if (!featureOn("typing")) return;
    const buf = buffers.get(S.activeBuf);
    if (!buf || buf.name === "*status") return;
    const v = msgInp.value;
    if (v.trim() && !v.startsWith("/")) {
      sendTypingState(buf.name, "active");
    } else {
      sendTypingState(buf.name, "done");
    }
  });
}
