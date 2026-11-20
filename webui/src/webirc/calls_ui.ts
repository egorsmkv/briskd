// Voice call manager wiring, the call bar, and the incoming-call dialog.
import { callDuration, CallManager, type CallView } from "../calls.ts";
import { byId as $ } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { ircFold } from "../common/ircv3.ts";
import { addLine, ensureBuf } from "./buffers.ts";
import { stopCallSettingsMedia } from "./call_settings_ui.ts";
import { sendRaw } from "./connection.ts";
import { switchBuf } from "./sidebar.ts";
import { buffers, S } from "./state.ts";
import { avatarOf, displayNameOf, peekUser } from "./users.ts";
import { isChan, nickColor } from "./util.ts";

// --- Voice calls (egorsmkv.github.io/calls, relayed through rtpengine) ---

export const calls = new CallManager({
  send: (line) => sendRaw(line),
  onChange: (view) => renderCall(view),
  onEnded: (peer, summary) => {
    addLine(peer, { text: `📞 ${summary}`, kind: "sys" });
  },
  remoteAudio: () => $<HTMLAudioElement>("call-audio"),
  audio: () => S.callSettings,
});

export function callStatusText(view: CallView): string {
  switch (view.phase) {
    case "calling":
      return t("call.calling");
    case "ringing":
      return t("call.ringing");
    case "connecting":
      return t("call.connecting");
    case "active":
      // The duration keeps running on hold: the call is still connected.
      if (view.held || view.remoteHeld) {
        const d = callDuration(view);
        const label = view.held
          ? t("call.on_hold")
          : t("call.remote_hold", { nick: displayNameOf(view.peer) });
        return d ? `${label} · ${d}` : label;
      }
      return callDuration(view) || t("call.connecting");
    default:
      return "";
  }
}

export function fillCallAvatar(el: HTMLElement, nick: string): void {
  el.textContent = "";
  el.style.backgroundColor = nickColor(nick);
  const url = avatarOf(nick);
  if (url) {
    const img = document.createElement("img");
    img.src = url;
    img.alt = "";
    img.referrerPolicy = "no-referrer";
    img.onerror = () => {
      img.remove();
      el.textContent = nick.slice(0, 2).toUpperCase();
    };
    el.appendChild(img);
  } else {
    el.textContent = nick.slice(0, 2).toUpperCase();
  }
}

export function renderCall(view: CallView = calls.state): void {
  const dock = $("call-dock");
  const incoming = $("call-incoming");
  const inDock = view.phase !== "idle" && view.phase !== "incoming";
  dock.classList.toggle("hidden", !inDock);
  dock.classList.toggle("active", view.phase === "active");
  if (inDock) {
    fillCallAvatar($("call-dock-avatar"), view.peer);
    $("call-dock-peer").textContent = displayNameOf(view.peer);
    $("call-dock-status").textContent = callStatusText(view);
    const mute = $<HTMLButtonElement>("btn-call-mute");
    mute.setAttribute("aria-pressed", String(view.muted));
    mute.classList.toggle("on", view.muted);
    mute.title = view.muted ? t("call.unmute") : t("call.mute");
    mute.setAttribute("aria-label", mute.title);
    mute.querySelector(".icon-mic")?.classList.toggle("hidden", view.muted);
    mute.querySelector(".icon-mic-off")?.classList.toggle(
      "hidden",
      !view.muted,
    );
    const hold = $<HTMLButtonElement>("btn-call-hold");
    hold.disabled = view.phase !== "active";
    hold.setAttribute("aria-pressed", String(view.held));
    hold.classList.toggle("on", view.held);
    hold.title = view.held ? t("call.resume") : t("call.hold");
    hold.setAttribute("aria-label", hold.title);
    hold.querySelector(".icon-pause")?.classList.toggle("hidden", view.held);
    hold.querySelector(".icon-play")?.classList.toggle("hidden", !view.held);
    dock.classList.toggle("held", view.held || view.remoteHeld);
    $("btn-call-hangup").title = view.phase === "active" ||
        view.phase === "connecting"
      ? t("call.hangup")
      : t("call.cancel");
  }
  const wasIncoming = incoming.classList.contains("open");
  const isIncoming = view.phase === "incoming";
  incoming.classList.toggle("open", isIncoming);
  if (isIncoming && !wasIncoming) {
    fillCallAvatar($("call-incoming-avatar"), view.peer);
    $("call-incoming-name").textContent = displayNameOf(view.peer);
    $<HTMLButtonElement>("btn-call-accept").focus();
    if (
      document.hidden && typeof Notification !== "undefined" &&
      Notification.permission === "granted"
    ) {
      S.callNotification = new Notification(t("call.incoming"), {
        body: displayNameOf(view.peer),
        tag: "ircd-call",
        requireInteraction: true,
      });
      S.callNotification.onclick = () => {
        globalThis.focus();
        S.callNotification?.close();
      };
    }
  }
  if (!isIncoming && S.callNotification) {
    S.callNotification.close();
    S.callNotification = null;
  }
  if (view.phase === "active" && S.callTicker === null) {
    S.callTicker = setInterval(() => {
      $("call-dock-status").textContent = callStatusText(calls.state);
    }, 1000);
  } else if (view.phase !== "active" && S.callTicker !== null) {
    clearInterval(S.callTicker);
    S.callTicker = null;
  }
  updateCallButton();
}

/** The header call button: shown in a private conversation when calls work. */
export function updateCallButton(): void {
  const btn = $<HTMLButtonElement>("btn-call");
  const buf = buffers.get(S.activeBuf);
  const show = calls.enabled && S.isRegistered && !!buf &&
    buf.name !== "*status" && !isChan(buf.name);
  btn.classList.toggle("hidden", !show);
  if (!show || !buf) return;
  const offline = peekUser(buf.name)?.online === false;
  btn.disabled = calls.busy || offline;
  btn.title = offline
    ? t("call.offline", { nick: buf.name })
    : calls.busy
    ? t("call.busy")
    : t("call.start", { nick: buf.name });
  btn.setAttribute("aria-label", btn.title);
}

export function startCall(nick: string): void {
  if (!calls.enabled) {
    addLine(S.activeBuf, { text: t("call.unsupported"), kind: "err" });
    return;
  }
  ensureBuf(nick);
  calls.call(nick).catch(() => {
    // The manager already reported the failure in the conversation.
  });
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  $("btn-call").onclick = () => {
    const buf = buffers.get(S.activeBuf);
    if (buf && !isChan(buf.name) && buf.name !== "*status") startCall(buf.name);
  };

  $("btn-call-accept").onclick = () => {
    const peer = calls.state.peer;
    if (peer) {
      ensureBuf(peer);
      switchBuf(ircFold(peer));
    }
    void calls.accept();
  };

  $("btn-call-decline").onclick = () => calls.decline();

  $("btn-call-hangup").onclick = () => calls.hangup();

  $("btn-call-mute").onclick = () => calls.toggleMute();

  $("btn-call-hold").onclick = () => void calls.toggleHold();

  $("call-dock-peer").onclick = () => {
    const peer = calls.state.peer;
    if (peer) {
      ensureBuf(peer);
      switchBuf(ircFold(peer));
    }
  };

  $("call-incoming").addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") {
      ev.preventDefault();
      calls.decline();
    }
  });

  globalThis.addEventListener("pagehide", () => {
    if (calls.busy) calls.hangup();
    stopCallSettingsMedia();
  });
}
