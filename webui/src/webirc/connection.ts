// The WebSocket connection: sending, heartbeat, and automatic reconnection.
import { CALLS_CAP } from "../calls.ts";
import { byId as $, errorMessage } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { ircFold, METADATA_KEYS } from "../common/ircv3.ts";
import { backoffDelay } from "../common/reconnect.ts";
import { E2EE_CAP } from "../e2ee/manager.ts";
import { addLine, updateTitle } from "./buffers.ts";
import { calls, updateCallButton } from "./calls_ui.ts";
import { capOn, multiline, resetIrcv3State } from "./caps.ts";
import { FEATURES_CAP, FILES_CAP, REDACT_CAP, VOICE_CAP } from "./constants.ts";
import { e2ee } from "./e2ee_ui.ts";
import { handleMessage } from "./handler.ts";
import { renderMembers } from "./sidebar.ts";
import { buffers, S } from "./state.ts";
import { type BufferState } from "./types.ts";

export function sendRaw(line: string): void {
  if (S.ws && S.ws.readyState === WebSocket.OPEN) {
    const clean = line.replace(/[\r\n\0]/g, "");
    if (clean) S.ws.send(clean);
  }
}

// Heartbeat: once registered, send `ISON <own nick>` (RFC 2812 section 4.9)
// every HEARTBEAT_MS so idle WebSocket proxies keep the connection open and a
// dead connection is noticed. Replies to our own probes (303 RPL_ISON) are
// hidden; after HEARTBEAT_MAX_MISSED unanswered probes the socket is closed.
export const HEARTBEAT_MS = 30_000;

export const HEARTBEAT_MAX_MISSED = 2;

export function startHeartbeat(): void {
  stopHeartbeat();
  S.heartbeatTimer = setInterval(() => {
    if (!S.ws || S.ws.readyState !== WebSocket.OPEN || !S.isRegistered) return;
    if (S.heartbeatPending >= HEARTBEAT_MAX_MISSED) {
      addLine("*status", { text: "Server stopped responding.", kind: "err" });
      stopHeartbeat();
      abandonSocket();
      return;
    }
    S.heartbeatPending++;
    sendRaw(
      capOn("labeled-response")
        ? `@label=hb ISON ${S.myNick}`
        : `ISON ${S.myNick}`,
    );
    // Registered with a fallback nickname: retake the preferred one once the
    // old connection is gone.
    if (
      S.preferredNick && !S.regainPending &&
      ircFold(S.myNick) !== ircFold(S.preferredNick)
    ) {
      S.regainPending = true;
      sendRaw(`NICK ${S.preferredNick}`);
    }
  }, HEARTBEAT_MS);
}

export function stopHeartbeat(): void {
  if (S.heartbeatTimer !== null) clearInterval(S.heartbeatTimer);
  S.heartbeatTimer = null;
  S.heartbeatPending = 0;
}

/** Capabilities the client requests when the server offers them. */
export function wantedCaps(): string[] {
  const wanted = [
    "message-tags",
    "server-time",
    "echo-message",
    "batch",
    "draft/chathistory",
    "draft/multiline",
    REDACT_CAP,
    "away-notify",
    "account-notify",
    "account-tag",
    "extended-join",
    "multi-prefix",
    "userhost-in-names",
    "no-implicit-names",
    "chghost",
    "setname",
    "invite-notify",
    "cap-notify",
    "labeled-response",
    "standard-replies",
    "extended-monitor",
    "draft/read-marker",
    "draft/metadata-2",
    E2EE_CAP,
    FEATURES_CAP,
    FILES_CAP,
    VOICE_CAP,
    CALLS_CAP,
  ];
  if (S.saslPass && !S.isRegistered) wanted.push("sasl");
  return wanted;
}

export function metadataSubscribe(): void {
  sendRaw(`METADATA * SUB ${METADATA_KEYS.join(" ")}`);
}

export function setConnButtonState(offline: boolean): void {
  S.connOffline = offline;
  $("chat-view").classList.toggle("offline", offline);
  const btn = $("btn-conn");
  const label = $("btn-conn-label");
  // Offline, reconnecting is the one thing to do: the button turns primary.
  btn.classList.toggle("primary", offline);
  btn.classList.toggle("ghost", !offline);
  btn.classList.toggle("ghost-danger", !offline);
  $("icon-disconnect").classList.toggle("hidden", offline);
  $("icon-reconnect").classList.toggle("hidden", !offline);
  const text = offline ? t("btn.reconnect") : t("btn.disconnect");
  label.textContent = text;
  btn.title = text;
  btn.setAttribute("aria-label", text);
}

// --- Automatic reconnection ------------------------------------------------
//
// A connection that closes without the user asking (network loss, server
// restart, missed heartbeats, KILL) is retried with exponential backoff
// (common/reconnect.ts: 1 s doubling to 60 s, with jitter). The attempt count
// resets only after a connection has stayed registered for STABLE_MS, so a
// server that accepts and then drops us at once is not hammered. Going
// online, or the tab becoming visible, retries at once. The Disconnect
// button, /quit, and Cancel stop it.

export const CONNECT_TIMEOUT_MS = 15_000;

export const STABLE_MS = 30_000;

/** Channels being rejoined after a reconnect, by folded name. */
export const catchUp = new Set<string>();

/**
 * The CHATHISTORY selector for what was missed in `buf` while disconnected:
 * after the server time of its newest server-stamped message, or null when
 * there is none (then the latest messages are fetched).
 */
export function historyAfter(buf: BufferState | undefined): string | null {
  if (!buf) return null;
  for (let i = buf.lines.length - 1; i >= 0; i--) {
    const l = buf.lines[i];
    if (l.msgid && l.epochMs) {
      return `timestamp=${new Date(l.epochMs).toISOString()}`;
    }
  }
  return null;
}

export function clearTimer(id: number | null): null {
  if (id !== null) clearTimeout(id);
  return null;
}

export function showReconnectBar(text: string, canRetryNow: boolean): void {
  $("reconnect-text").textContent = text;
  $("btn-reconnect-now").classList.toggle("hidden", !canRetryNow);
  $("reconnect-bar").classList.remove("hidden");
}

export function hideReconnectBar(): void {
  $("reconnect-bar").classList.add("hidden");
}

/** Stop a pending retry (the bar stays if a reconnect is still under way). */
export function cancelReconnectTimer(): void {
  S.reconnectTimer = clearTimer(S.reconnectTimer);
  if (S.reconnectTicker !== null) clearInterval(S.reconnectTicker);
  S.reconnectTicker = null;
}

export function updateReconnectCountdown(): void {
  const s = Math.max(1, Math.ceil((S.reconnectAt - Date.now()) / 1000));
  showReconnectBar(t("rc.waiting", { s }), true);
}

export function scheduleReconnect(): void {
  cancelReconnectTimer();
  if (!S.lastWsUrl || S.userClosed) return;
  S.reconnecting = true;
  if (navigator.onLine === false) {
    // The "online" event retries; no timer while there is no network.
    showReconnectBar(t("rc.offline"), true);
    return;
  }
  const delay = backoffDelay(S.reconnectAttempt);
  S.reconnectAttempt++;
  S.reconnectAt = Date.now() + delay;
  updateReconnectCountdown();
  S.reconnectTicker = setInterval(updateReconnectCountdown, 1000);
  S.reconnectTimer = setTimeout(reconnectNow, delay);
}

export function reconnectNow(): void {
  cancelReconnectTimer();
  if (!S.lastWsUrl || S.userClosed) return;
  S.reconnecting = true;
  showReconnectBar(t("rc.connecting"), false);
  try {
    connectSocket(S.lastWsUrl);
  } catch (e) {
    addLine("*status", { text: errorMessage(e), kind: "err" });
    scheduleReconnect();
  }
}

/** Stop reconnecting; the user ended the session or cancelled. */
export function stopReconnecting(): void {
  cancelReconnectTimer();
  S.reconnecting = false;
  hideReconnectBar();
}

/**
 * Treat the current socket as closed now. On a dead network a browser may
 * take minutes to report the close; the handlers are detached and the close
 * handling (which schedules the reconnect) runs at once.
 */
export function abandonSocket(): void {
  const sock = S.ws;
  if (!sock) return;
  const onclose = sock.onclose;
  sock.onopen =
    sock.onmessage =
    sock.onerror =
    sock.onclose =
      null;
  try {
    sock.close();
  } catch {
    // ignore
  }
  onclose?.call(sock, new CloseEvent("close"));
}

export function connectSocket(url: string): void {
  const parsed = new URL(url);
  if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
    throw new Error("WebSocket URL must start with ws:// or wss://");
  }
  S.lastWsUrl = parsed.href;
  cancelReconnectTimer();
  if (S.ws) {
    // Detach first: a late close event from the old socket must not reset
    // the state of the new connection or schedule another reconnect.
    const old = S.ws;
    old.onopen =
      old.onmessage =
      old.onerror =
      old.onclose =
        null;
    try {
      old.close();
    } catch {
      // ignore
    }
  }
  const sock = new WebSocket(parsed.href, ["text.ircv3.net"]);
  S.ws = sock;
  $("status-dot").classList.remove("off");
  setConnButtonState(false);
  addLine("*status", { text: `Connecting to ${url}...`, kind: "sys" });
  // A connection that never opens (black-holed network) is abandoned.
  S.connectTimer = clearTimer(S.connectTimer);
  S.connectTimer = setTimeout(() => {
    if (S.ws === sock && sock.readyState === WebSocket.CONNECTING) {
      abandonSocket();
    }
  }, CONNECT_TIMEOUT_MS);

  sock.onopen = () => {
    if (S.ws !== sock) return;
    S.connectTimer = clearTimer(S.connectTimer);
    S.advertisedCaps = [];
    resetIrcv3State();
    e2ee.resetConnection();
    S.nickAttempt = 0;
    S.regainPending = false;
    S.myNick = S.preferredNick || S.myNick;
    sendRaw("CAP LS 302");
    sendRaw(`NICK ${S.myNick}`);
    sendRaw(`USER ${S.myNick} 0 * :${S.myNick}`);
  };
  sock.onmessage = (e) => {
    if (S.ws !== sock) return;
    if (typeof e.data === "string") handleMessage(e.data);
  };
  sock.onerror = () => {
    if (S.ws !== sock) return;
    addLine("*status", { text: "WebSocket connection error.", kind: "err" });
  };
  sock.onclose = () => {
    // The Disconnect button clears `ws` before this fires; a replaced socket
    // has no handlers left (see above).
    if (S.ws && S.ws !== sock) return;
    S.connectTimer = clearTimer(S.connectTimer);
    S.stableTimer = clearTimer(S.stableTimer);
    const wasRegistered = S.isRegistered;
    stopHeartbeat();
    calls.reset();
    calls.enabled = false;
    updateCallButton();
    S.isRegistered = false;
    S.hiddenUnread = 0;
    S.hiddenMentions = 0;
    e2ee.resetConnection();
    multiline.clear();
    // Member lists are refilled by NAMES after rejoining.
    buffers.forEach((b) => b.members.clear());
    renderMembers();
    updateTitle();
    $("status-dot").classList.add("off");
    setConnButtonState(true);
    if (wasRegistered || !S.reconnecting) {
      addLine("*status", { text: "Disconnected from server.", kind: "err" });
    }
    if (S.userClosed) {
      stopReconnecting();
    } else {
      scheduleReconnect();
    }
  };
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  $("btn-reconnect-now").onclick = () => {
    S.userClosed = false;
    reconnectNow();
  };

  $("btn-reconnect-cancel").onclick = () => {
    S.userClosed = true;
    stopReconnecting();
    if (S.ws && S.ws.readyState !== WebSocket.CLOSED) S.ws.close();
    addLine("*status", { text: t("rc.cancelled"), kind: "sys" });
  };

  globalThis.addEventListener("online", () => {
    if (S.reconnecting && (!S.ws || S.ws.readyState === WebSocket.CLOSED)) {
      reconnectNow();
    }
  });

  document.addEventListener("visibilitychange", () => {
    // Phones throttle background timers; retry as soon as the tab is back.
    if (document.visibilityState === "visible" && S.reconnectTimer !== null) {
      reconnectNow();
    }
  });

  globalThis.addEventListener("pageshow", (ev) => {
    // Restored from the back/forward cache with a closed socket.
    if (
      (ev as PageTransitionEvent).persisted && S.lastWsUrl && !S.userClosed &&
      (!S.ws || S.ws.readyState === WebSocket.CLOSED)
    ) {
      reconnectNow();
    }
  });
}
