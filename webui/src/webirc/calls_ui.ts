// Call manager wiring, the call bar, the video call stage, and the
// incoming-call dialog.
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
import { isChan, NICK_COLORS, nickClass } from "./util.ts";

// --- Voice calls (egorsmkv.github.io/calls, relayed through rtpengine) ---

export const calls = new CallManager({
  send: (line) => sendRaw(line),
  onChange: (view) => renderCall(view),
  onEnded: (peer, summary) => {
    addLine(peer, { text: `📞 ${summary}`, kind: "sys" });
  },
  remoteAudio: () => $<HTMLAudioElement>("call-audio"),
  remoteVideo: () => $<HTMLVideoElement>("call-remote-video"),
  localVideo: () => $<HTMLVideoElement>("call-local-video"),
  notice: (text) => {
    const peer = calls.state.peer;
    addLine(peer || S.activeBuf, { text: `📞 ${text}`, kind: "err" });
  },
  audio: () => S.callSettings,
});

/** The video stage is shrunk to a corner so the conversation shows. */
let stageMini = false;

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
  for (let i = 0; i < NICK_COLORS; i++) el.classList.remove(`av-${i}`);
  el.classList.add(nickClass(nick, "av"));
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
    const camera = $<HTMLButtonElement>("btn-call-camera");
    camera.classList.toggle("hidden", !view.video);
    camera.disabled = view.held;
    camera.setAttribute("aria-pressed", String(view.cameraOn));
    camera.classList.toggle("on", view.video && !view.cameraOn);
    camera.title = view.cameraOn ? t("call.camera_off") : t("call.camera_on");
    camera.setAttribute("aria-label", camera.title);
    camera.querySelector(".icon-cam")?.classList.toggle(
      "hidden",
      !view.cameraOn,
    );
    camera.querySelector(".icon-cam-off")?.classList.toggle(
      "hidden",
      view.cameraOn,
    );
  }
  renderStage(view, inDock);
  const wasIncoming = incoming.classList.contains("open");
  const isIncoming = view.phase === "incoming";
  incoming.classList.toggle("open", isIncoming);
  if (isIncoming && !wasIncoming) {
    fillCallAvatar($("call-incoming-avatar"), view.peer);
    $("call-incoming-name").textContent = displayNameOf(view.peer);
    $("call-incoming-label").textContent = view.video
      ? t("call.incoming_video")
      : t("call.incoming");
    $("btn-call-accept-video").classList.toggle("hidden", !view.video);
    const accept = $<HTMLButtonElement>("btn-call-accept");
    // In a video call, plain Accept answers with the camera off.
    accept.title = view.video ? t("call.accept_audio") : t("call.accept");
    accept.setAttribute("aria-label", accept.title);
    (view.video ? $<HTMLButtonElement>("btn-call-accept-video") : accept)
      .focus();
    if (
      document.hidden && typeof Notification !== "undefined" &&
      Notification.permission === "granted"
    ) {
      S.callNotification = new Notification(
        view.video ? t("call.incoming_video") : t("call.incoming"),
        {
          body: displayNameOf(view.peer),
          tag: "ircd-call",
          requireInteraction: true,
        },
      );
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

/**
 * The video stage over the conversation: the other side's video (or their
 * avatar while there is no picture), this side's camera preview, and the
 * minimize and full-screen buttons. Shown for a video call from the first
 * ring to the hang-up.
 */
function renderStage(view: CallView, inCall: boolean): void {
  const stage = $("call-stage");
  const show = inCall && view.video;
  stage.classList.toggle("hidden", !show);
  if (!show) {
    stageMini = false;
    stage.classList.remove("mini");
    if (document.fullscreenElement === stage) {
      void document.exitFullscreen().catch(() => {});
    }
    return;
  }
  stage.classList.toggle("mini", stageMini);
  const picture = view.phase === "active" && view.remoteVideo &&
    !view.remoteHeld && !view.held;
  stage.classList.toggle("has-video", picture);
  $("call-stage-placeholder").classList.toggle("hidden", picture);
  if (!picture) {
    const avatar = $("call-stage-avatar");
    if (avatar.dataset.nick !== view.peer) {
      fillCallAvatar(avatar, view.peer);
      avatar.dataset.nick = view.peer;
    }
    $("call-stage-name").textContent = displayNameOf(view.peer);
    $("call-stage-note").textContent = view.phase !== "active"
      ? callStatusText(view)
      : view.held
      ? t("call.on_hold")
      : view.remoteHeld
      ? t("call.remote_hold", { nick: displayNameOf(view.peer) })
      : t("call.remote_camera_off");
  }
  $("call-local-video").classList.toggle(
    "hidden",
    !view.cameraOn || view.held,
  );
  const mini = $<HTMLButtonElement>("btn-call-stage-mini");
  mini.title = stageMini ? t("call.stage_restore") : t("call.stage_minimize");
  mini.setAttribute("aria-label", mini.title);
  mini.querySelector(".icon-stage-mini")?.classList.toggle("hidden", stageMini);
  mini.querySelector(".icon-stage-restore")?.classList.toggle(
    "hidden",
    !stageMini,
  );
  const full = $<HTMLButtonElement>("btn-call-stage-full");
  const isFull = document.fullscreenElement === stage;
  full.classList.toggle("hidden", !document.fullscreenEnabled || stageMini);
  full.title = isFull ? t("call.stage_exit_full") : t("call.stage_full");
  full.setAttribute("aria-label", full.title);
}

/**
 * The header call buttons (voice, and video when the server allows it):
 * shown in a private conversation when calls work.
 */
export function updateCallButton(): void {
  const buttons = [
    $<HTMLButtonElement>("btn-call"),
    $<HTMLButtonElement>("btn-video-call"),
  ];
  const buf = buffers.get(S.activeBuf);
  const show = calls.enabled && S.isRegistered && !!buf &&
    buf.name !== "*status" && !isChan(buf.name);
  buttons[0].classList.toggle("hidden", !show);
  buttons[1].classList.toggle("hidden", !show || !calls.videoSupported);
  if (!show || !buf) return;
  const offline = peekUser(buf.name)?.online === false;
  buttons.forEach((btn, i) => {
    btn.disabled = calls.busy || offline;
    btn.title = offline
      ? t("call.offline", { nick: buf.name })
      : calls.busy
      ? t("call.busy")
      : i === 0
      ? t("call.start", { nick: buf.name })
      : t("call.video_start", { nick: buf.name });
    btn.setAttribute("aria-label", btn.title);
  });
}

/** Call `nick`; with `video`, a video call when the server allows it. */
export function startCall(nick: string, video = false): void {
  if (!calls.enabled) {
    addLine(S.activeBuf, { text: t("call.unsupported"), kind: "err" });
    return;
  }
  if (video && !calls.videoSupported) {
    addLine(S.activeBuf, { text: t("call.video_unsupported"), kind: "err" });
    return;
  }
  ensureBuf(nick);
  calls.call(nick, video).catch(() => {
    // The manager already reported the failure in the conversation.
  });
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  const callActive = (video: boolean) => () => {
    const buf = buffers.get(S.activeBuf);
    if (buf && !isChan(buf.name) && buf.name !== "*status") {
      startCall(buf.name, video);
    }
  };
  $("btn-call").onclick = callActive(false);
  $("btn-video-call").onclick = callActive(true);

  const accept = (video: boolean) => () => {
    const peer = calls.state.peer;
    if (peer) {
      ensureBuf(peer);
      switchBuf(ircFold(peer));
    }
    void calls.accept(video);
  };
  // In a video call, Accept answers with the camera off.
  $("btn-call-accept").onclick = accept(false);
  $("btn-call-accept-video").onclick = accept(true);

  $("btn-call-camera").onclick = () => {
    calls.toggleCamera().catch(() => {
      // The manager reported an unavailable camera.
    });
  };

  const stage = $("call-stage");
  $("btn-call-stage-mini").onclick = (ev) => {
    ev.stopPropagation();
    stageMini = !stageMini;
    renderCall();
  };
  // A click on the minimized stage brings it back.
  stage.addEventListener("click", () => {
    if (stageMini) {
      stageMini = false;
      renderCall();
    }
  });
  $("btn-call-stage-full").onclick = (ev) => {
    ev.stopPropagation();
    if (document.fullscreenElement === stage) {
      void document.exitFullscreen().catch(() => {});
    } else {
      void stage.requestFullscreen().catch(() => {});
    }
  };
  document.addEventListener("fullscreenchange", () => renderCall());

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
