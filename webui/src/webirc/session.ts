// Saved session (sessionStorage), URL paths for conversations, and the WebSocket URL default.
import { config } from "../app/config.ts";
import { RECLAIM_SECRET, reclaimSecret } from "../common/reconnect.ts";
import { clearHistory } from "./history_cache.ts";
import { byId as $ } from "../common/dom.ts";
import { buffers, S } from "./state.ts";
import { type SavedSession } from "./types.ts";
import { isChan } from "./util.ts";

export const WS_PORT = config().wsPort;

export const WSS_PORT = config().wssPort;

export const BASE_TITLE = `${config().network} - WebIRC`;

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
    const p: unknown = JSON.parse(raw);
    if (!p || typeof p !== "object") return null;
    const o = p as Record<string, unknown>;
    const str = (v: unknown) => typeof v === "string" ? v : "";
    if (!str(o.nick) || !str(o.wsUrl)) return null;
    return {
      nick: str(o.nick),
      acct: str(o.acct),
      pass: str(o.pass),
      channels: Array.isArray(o.channels)
        ? o.channels.filter((c): c is string =>
          typeof c === "string" && c !== ""
        )
        : [],
      wsUrl: str(o.wsUrl),
      activeBuf: str(o.activeBuf) || "*status",
    };
  } catch {
    return null;
  }
}

export function clearSession(): void {
  try {
    sessionStorage.removeItem(SESSION_KEY);
    sessionStorage.removeItem(RECLAIM_KEY);
  } catch {
    // ignore
  }
  memorySecret = null;
  clearHistory();
}

const RECLAIM_KEY = "ircd-webirc-reclaim";
let memorySecret: string | null = null;

/**
 * This tab's `RECLAIM` secret, sent before `NICK` on every connection so a
 * page reload takes back the nickname the server holds for the dropped
 * connection. Kept in sessionStorage: it survives a reload but is not shared
 * with other tabs; signing out (clearSession) makes a new one.
 */
export function tabReclaimSecret(): string {
  try {
    const saved = sessionStorage.getItem(RECLAIM_KEY);
    if (saved && RECLAIM_SECRET.test(saved)) return saved;
  } catch {
    // Storage blocked: the secret lasts as long as the page.
  }
  const secret = memorySecret ??
    reclaimSecret(crypto.getRandomValues(new Uint8Array(24)));
  memorySecret = secret;
  try {
    sessionStorage.setItem(RECLAIM_KEY, secret);
  } catch {
    // ignore
  }
  return secret;
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
