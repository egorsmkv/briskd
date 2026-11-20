// Login form, starting a session, and restoring a saved one.
import { initAltcha } from "../common/altcha.ts";
import { byId as $, errorMessage, postJson } from "../common/dom.ts";
import { ircFold } from "../common/ircv3.ts";
import { ensureBuf } from "./buffers.ts";
import { restoreHistory } from "./history_cache.ts";
import { connectSocket, stopReconnecting } from "./connection.ts";
import { loadSession, pathToBuffer, saveSession } from "./session.ts";
import { showMyNick, switchBuf } from "./sidebar.ts";
import { buffers, S } from "./state.ts";
import { isChan } from "./util.ts";

export function startSession(opts: {
  nick: string;
  acct: string;
  pass: string;
  channels: string[];
  wsUrl: string;
  targetBuf?: string;
}): void {
  const err = $("connect-err");
  err.style.display = "none";
  S.myNick = opts.nick;
  S.preferredNick = opts.nick;
  S.userClosed = false;
  S.reconnectAttempt = 0;
  stopReconnecting();
  S.isIrcOp = false;
  S.saslUser = opts.acct;
  S.saslPass = opts.pass;
  S.autoChannels = opts.channels;
  S.desiredBuf = ircFold(opts.targetBuf || "");

  if (S.desiredBuf && S.desiredBuf !== "*status" && isChan(S.desiredBuf)) {
    if (!S.autoChannels.some((c) => ircFold(c) === S.desiredBuf)) {
      S.autoChannels = [...S.autoChannels, S.desiredBuf];
    }
  }
  try {
    buffers.clear();
    ensureBuf("*status");
    // This tab's conversations from before a reload: only newer messages
    // are fetched for them.
    restoreHistory();
    if (S.desiredBuf && S.desiredBuf !== "*status" && !isChan(S.desiredBuf)) {
      ensureBuf(opts.targetBuf || S.desiredBuf);
    }
    $("connect-view").style.display = "none";
    $("chat-view").classList.add("active");
    showMyNick();
    if (S.desiredBuf && buffers.has(S.desiredBuf)) {
      switchBuf(S.desiredBuf);
      S.desiredBuf = "";
    } else {
      switchBuf("*status", false);
    }
    connectSocket(opts.wsUrl);
    saveSession();
  } catch (e) {
    err.textContent = `Invalid WebSocket URL: ${errorMessage(e)}`;
    err.style.display = "block";
    $("chat-view").classList.remove("active");
    $("connect-view").style.display = "flex";
  }
}

export const connectErr = $("connect-err");

export const loginAltcha = initAltcha(
  $<HTMLInputElement>("altcha-check"),
  $("altcha-label"),
  (msg) => {
    connectErr.textContent = msg;
    connectErr.style.display = "block";
  },
);

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  $<HTMLFormElement>("connect-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    connectErr.style.display = "none";
    const altchaPayload = loginAltcha.getPayload();
    if (!altchaPayload) {
      connectErr.textContent = "Please complete the ALTCHA verification.";
      connectErr.style.display = "block";
      return;
    }
    const btn = $<HTMLButtonElement>("btn-connect");
    btn.disabled = true;
    try {
      const res = await postJson<{ error?: string; message?: string }>(
        "/api/webirc/verify",
        { altcha: altchaPayload },
      );
      if (!res.ok) {
        connectErr.textContent = res.data.message ||
          "ALTCHA verification failed. Please try again.";
        connectErr.style.display = "block";
        loginAltcha.reset();
        return;
      }
      loginAltcha.reset();
      const pathBuf = pathToBuffer(location.pathname);
      startSession({
        nick: $<HTMLInputElement>("inp-nick").value.trim(),
        acct: $<HTMLInputElement>("inp-acct").value.trim(),
        pass: $<HTMLInputElement>("inp-pass").value,
        channels: $<HTMLInputElement>("inp-channels").value
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean),
        wsUrl: $<HTMLInputElement>("inp-ws").value.trim(),
        targetBuf: pathBuf || undefined,
      });
    } catch (e) {
      connectErr.textContent = `Verification failed: ${errorMessage(e)}`;
      connectErr.style.display = "block";
      loginAltcha.reset();
    } finally {
      btn.disabled = false;
    }
  });

  globalThis.addEventListener("popstate", () => {
    const target = pathToBuffer(location.pathname);
    if (target && buffers.has(ircFold(target))) {
      switchBuf(ircFold(target), false);
    }
  });

  // The account and server fields sit in a disclosure: open it when one of
  // them is invalid, or the browser would block a submit on a field the
  // user cannot see.
  const advanced = $<HTMLDetailsElement>("connect-advanced");
  for (const id of ["inp-ws", "inp-acct", "inp-pass"]) {
    $(id).addEventListener("invalid", () => advanced.open = true);
  }

  // Auto-restore saved WebIRC session across page refreshes
  (function restoreSavedSession() {
    const saved = loadSession();
    if (!saved) return;
    $<HTMLInputElement>("inp-nick").value = saved.nick;
    $<HTMLInputElement>("inp-acct").value = saved.acct;
    $<HTMLInputElement>("inp-pass").value = saved.pass;
    $<HTMLInputElement>("inp-channels").value = saved.channels.join(",");
    $<HTMLInputElement>("inp-ws").value = saved.wsUrl;
    if (saved.acct) advanced.open = true;
    const pathBuf = pathToBuffer(location.pathname);
    startSession({
      nick: saved.nick,
      acct: saved.acct,
      pass: saved.pass,
      channels: saved.channels,
      wsUrl: saved.wsUrl,
      targetBuf: pathBuf || saved.activeBuf,
    });
  })();
}
