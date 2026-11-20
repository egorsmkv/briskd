// Saved session (sessionStorage), URL paths for conversations, and the WebSocket URL default.
import { byId as $ } from "../common/dom.ts";
import { buffers, S } from "./state.ts";
import { type SavedSession } from "./types.ts";
import { isChan } from "./util.ts";

export const bodyData = document.body.dataset;

export const WS_PORT = bodyData.wsPort || "";

export const WSS_PORT = bodyData.wssPort || "";

export const BASE_TITLE = document.title;

export const SESSION_KEY = "ircd-webirc-session";

export function bufferToPath(name: string): string {
  if (name === "*status") return "/status";
  if (isChan(name)) {
    const clean = name.startsWith("#") ? name.slice(1) : name;
    return `/channel/${encodeURIComponent(clean)}`;
  }
  return `/dm/${encodeURIComponent(name)}`;
}

export const MAX_BUFFERS = 100;

// 1-50 UTF-16 code units, none of them a control, space, comma, or DEL.
// deno-lint-ignore no-control-regex
export const SAFE_IRC_TARGET_RE = /^[^\x00-\x20,\x7f]{1,50}$/;

export function isSafeIrcTarget(s: string): boolean {
  return SAFE_IRC_TARGET_RE.test(s);
}

export function pathToBuffer(pathname: string): string | null {
  if (pathname === "/status") return "*status";
  const cm = pathname.match(/^\/channel\/([^/]+)\/?$/);
  if (cm) {
    try {
      const dec = decodeURIComponent(cm[1]).trim();
      if (dec && isSafeIrcTarget(dec)) {
        return isChan(dec) ? dec : `#${dec}`;
      }
    } catch {
      return null;
    }
  }
  const dm = pathname.match(/^\/dm\/([^/]+)\/?$/);
  if (dm) {
    try {
      const dec = decodeURIComponent(dm[1]).trim();
      if (dec && !isChan(dec) && isSafeIrcTarget(dec)) return dec;
    } catch {
      return null;
    }
  }
  return null;
}

export function saveSession(): void {
  if (!S.myNick || !S.lastWsUrl) return;
  const chans: string[] = [];
  buffers.forEach((b) => {
    if (isChan(b.name)) chans.push(b.name);
  });
  const payload: SavedSession = {
    nick: S.preferredNick || S.myNick,
    acct: S.saslUser,
    pass: S.saslPass,
    channels: chans.length > 0 ? chans : S.autoChannels,
    wsUrl: S.lastWsUrl,
    activeBuf: S.activeBuf,
  };
  try {
    sessionStorage.setItem(SESSION_KEY, JSON.stringify(payload));
  } catch {
    // ignore storage errors
  }
}

export function loadSession(): SavedSession | null {
  try {
    const raw = sessionStorage.getItem(SESSION_KEY);
    if (!raw) return null;
    const p = JSON.parse(raw) as Partial<SavedSession>;
    if (!p.nick || !p.wsUrl) return null;
    return {
      nick: p.nick,
      acct: p.acct || "",
      pass: p.pass || "",
      channels: Array.isArray(p.channels) ? p.channels.filter(Boolean) : [],
      wsUrl: p.wsUrl,
      activeBuf: p.activeBuf || "*status",
    };
  } catch {
    return null;
  }
}

export function clearSession(): void {
  try {
    sessionStorage.removeItem(SESSION_KEY);
  } catch {
    // ignore
  }
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  (function initWsUrl() {
    const isHttps = location.protocol === "https:";
    const host = location.hostname || "127.0.0.1";
    const inp = $<HTMLInputElement>("inp-ws");
    if (isHttps && WSS_PORT) {
      inp.value = `wss://${host}:${WSS_PORT}/`;
    } else if (WS_PORT) {
      inp.value = `ws://${host}:${WS_PORT}/`;
    } else if (WSS_PORT) {
      inp.value = `wss://${host}:${WSS_PORT}/`;
    } else {
      inp.value = `${isHttps ? "wss" : "ws"}://${location.host}/`;
    }
    const pathBuf = pathToBuffer(location.pathname);
    const qChan = new URLSearchParams(location.search).get("channel")?.trim();
    if (pathBuf && isChan(pathBuf)) {
      $<HTMLInputElement>("inp-channels").value = pathBuf;
    } else if (qChan && /^[#&+!]/.test(qChan)) {
      $<HTMLInputElement>("inp-channels").value = qChan;
    }
  })();
}
