// Known users, presence, MONITOR, read markers, and metadata.
import { byId as $ } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import {
  cleanMetaText,
  ircFold,
  MAX_META_VALUE,
  METADATA_KEYS,
  msToMarker,
  safeAvatarUrl,
  safeHomepageUrl,
} from "../common/ircv3.ts";
import { updateTitle } from "./buffers.ts";
import { updateCallButton } from "./calls_ui.ts";
import { capOn, isupport } from "./caps.ts";
import { sendRaw } from "./connection.ts";
import { renderActiveMessages } from "./chat/list.ts";
import { isSafeIrcTarget } from "./session.ts";
import { settings } from "./settings.ts";
import { renderBuffers, renderMembers, updateTopicButton } from "./sidebar.ts";
import { buffers, S } from "./state.ts";
import { type BufferState, type UserInfo } from "./types.ts";
import { isChan } from "./util.ts";

export const MAX_USERS = 5000;

export const MONITOR_CHUNK = 20;

export const users = new Map<string, UserInfo>();

/** Nicks we monitor automatically because a DM buffer is open. */
export const monitored = new Set<string>();

/** draft/read-marker positions (ms since epoch) by lowercased target. */
export const readMarkers = new Map<string, number>();

/** Channels with an outstanding WHOX request of ours. */
export const pendingWho = new Set<string>();

export function peekUser(nick: string): UserInfo | undefined {
  return users.get(ircFold(nick));
}

export function userInfo(nick: string): UserInfo {
  const key = ircFold(nick);
  let u = users.get(key);
  if (!u) {
    if (users.size >= MAX_USERS) {
      const oldest = users.keys().next().value;
      if (oldest !== undefined) users.delete(oldest);
    }
    u = { meta: new Map() };
    users.set(key, u);
  }
  return u;
}

export function userhostOf(prefix: string): string | undefined {
  const bang = prefix.indexOf("!");
  return bang > 0 ? prefix.slice(bang + 1) : undefined;
}

// appendLineDom shadows `t` with a DOM node, so the badge text comes from here.
export function botLabel(): string {
  return t("badge.bot");
}

export function displayNameOf(nick: string): string {
  const dn = peekUser(nick)?.meta.get("display-name");
  return (dn && cleanMetaText(dn)) || nick;
}

export function avatarOf(nick: string): string | null {
  const url = safeAvatarUrl(peekUser(nick)?.meta.get("avatar"));
  if (!url) return null;
  return url.startsWith("/") || settings.remoteAvatars ? url : null;
}

export function presenceText(nick: string): string {
  const u = peekUser(nick);
  if (!u) return "";
  if (u.online === false) return t("presence.offline");
  if (u.away !== undefined) {
    return u.away
      ? t("presence.awayMsg", { msg: cleanMetaText(u.away, 100) })
      : t("presence.away");
  }
  return u.online ? t("presence.online") : "";
}

export function presenceClass(nick: string): string {
  const u = peekUser(nick);
  if (!u || u.online === undefined) return "";
  if (!u.online) return "offline";
  return u.away !== undefined ? "away" : "online";
}

export function userTooltip(nick: string): string {
  const u = peekUser(nick);
  if (!u) return nick;
  const dn = u.meta.get("display-name");
  const lines = [dn ? `${cleanMetaText(dn)} (${nick})` : nick];
  const pronouns = u.meta.get("pronouns");
  if (pronouns) lines.push(cleanMetaText(pronouns, 32));
  if (u.realname) lines.push(cleanMetaText(u.realname, 100));
  if (u.account) lines.push(`${t("user.account")}: ${u.account}`);
  if (u.userhost) lines.push(u.userhost);
  const status = u.meta.get("status");
  if (status) lines.push(cleanMetaText(status, 100));
  const homepage = safeHomepageUrl(u.meta.get("homepage"));
  if (homepage) lines.push(homepage);
  const presence = presenceText(nick);
  if (presence) lines.push(presence);
  if (u.bot) lines.push(t("badge.bot"));
  return lines.join("\n");
}

/** Subtitle under the buffer name: topic, or a DM peer's profile/presence. */
export function bufSubtitle(buf: BufferState): string {
  if (buf.name === "*status") return "";
  if (isChan(buf.name)) return buf.topic || t("topic.none");
  const u = peekUser(buf.name);
  const parts: string[] = [];
  const dn = u?.meta.get("display-name");
  if (dn) parts.push(cleanMetaText(dn));
  const pronouns = u?.meta.get("pronouns");
  if (pronouns) parts.push(cleanMetaText(pronouns, 32));
  const presence = presenceText(buf.name);
  if (presence) parts.push(presence);
  const status = u?.meta.get("status");
  if (status) parts.push(cleanMetaText(status, 100));
  return parts.join(" · ");
}

/** Coalesce member list, buffer list, and header updates after user changes. */
export function scheduleUserRender(messages = false): void {
  if (messages) S.userRenderMessages = true;
  if (S.userRenderTimer !== null) return;
  S.userRenderTimer = setTimeout(() => {
    S.userRenderTimer = null;
    renderMembers();
    renderBuffers();
    updateTopicButton();
    updateCallButton();
    const buf = buffers.get(S.activeBuf);
    if (buf && !isChan(buf.name)) {
      $("active-topic").textContent = bufSubtitle(buf);
    }
    if (S.userRenderMessages) {
      S.userRenderMessages = false;
      renderActiveMessages();
    }
  }, 150);
}

export function dmNames(): string[] {
  const names: string[] = [];
  buffers.forEach((b) => {
    if (b.name !== "*status" && !isChan(b.name)) names.push(b.name);
  });
  return names;
}

export function monitorLimit(): number {
  const v = isupport.get("MONITOR");
  if (v === undefined) return 0;
  const n = parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : 100;
}

/** MONITOR the peers of open DM buffers for presence (730/731). */
export function monitorAdd(nicks: string[]): void {
  const limit = monitorLimit();
  if (!S.isRegistered || limit === 0) return;
  const fresh: string[] = [];
  for (const nick of nicks) {
    const key = ircFold(nick);
    if (
      isChan(nick) || nick === "*status" || !isSafeIrcTarget(nick) ||
      monitored.has(key) || monitored.size >= limit
    ) {
      continue;
    }
    monitored.add(key);
    fresh.push(nick);
  }
  for (let i = 0; i < fresh.length; i += MONITOR_CHUNK) {
    sendRaw(`MONITOR + ${fresh.slice(i, i + MONITOR_CHUNK).join(",")}`);
  }
}

export function monitorRemove(nick: string): void {
  const key = ircFold(nick);
  if (!monitored.delete(key)) return;
  sendRaw(`MONITOR - ${nick}`);
  const u = users.get(key);
  if (u) u.online = undefined;
}

export function markerOf(name: string): number {
  return readMarkers.get(ircFold(name)) ?? 0;
}

/** Ask for a DM's read marker; channels get theirs after JOIN. */
export function requestMarker(name: string): void {
  if (
    S.isRegistered && capOn("draft/read-marker") && name !== "*status" &&
    !isChan(name) && isSafeIrcTarget(name)
  ) {
    sendRaw(`MARKREAD ${name}`);
  }
}

export function scheduleMarkRead(): void {
  if (S.markReadTimer !== null) return;
  S.markReadTimer = setTimeout(() => {
    S.markReadTimer = null;
    markActiveRead();
  }, 1000);
}

/** Move the active buffer's read marker to its newest server message. */
export function markActiveRead(): void {
  if (!S.isRegistered || !capOn("draft/read-marker") || document.hidden) return;
  const buf = buffers.get(S.activeBuf);
  if (!buf || buf.name === "*status" || !isSafeIrcTarget(buf.name)) return;
  let last = 0;
  for (let i = buf.lines.length - 1; i >= 0; i--) {
    if (buf.lines[i].msgid) {
      last = buf.lines[i].epochMs;
      break;
    }
  }
  if (last <= markerOf(buf.name)) return;
  readMarkers.set(ircFold(buf.name), last);
  sendRaw(`MARKREAD ${buf.name} ${msToMarker(last)}`);
}

/** A MARKREAD from the server (ours, or another session of the account). */
export function applyMarker(target: string, ms: number | null): void {
  if (ms === null) return;
  const key = ircFold(target);
  readMarkers.set(key, Math.max(ms, markerOf(target)));
  const buf = buffers.get(key);
  if (!buf || key === S.activeBuf) return;
  const marker = markerOf(target);
  const me = ircFold(S.myNick);
  const isDm = !isChan(buf.name);
  let unread = 0;
  let mentions = 0;
  for (const line of buf.lines) {
    if (
      line.epochMs <= marker || !line.nick || ircFold(line.nick) === me
    ) {
      continue;
    }
    unread += 1;
    if (line.mention || (isDm && !line.kind)) mentions += 1;
  }
  if (unread !== buf.unread || mentions !== buf.mentions) {
    buf.unread = unread;
    buf.mentions = mentions;
    renderBuffers();
    updateTitle();
  }
}

export function applyMetadata(
  target: string | undefined,
  key: string | undefined,
  value: string | undefined,
): void {
  if (!target || !key || target === "*" || isChan(target)) return;
  if (!(METADATA_KEYS as readonly string[]).includes(key)) return;
  const u = userInfo(target);
  if (value === undefined || value === "") u.meta.delete(key);
  else u.meta.set(key, value.slice(0, MAX_META_VALUE));
  const folded = ircFold(target);
  const buf = buffers.get(S.activeBuf);
  const visible = (key === "avatar" || key === "display-name") && !!buf &&
    buf.lines.some((l) => ircFold(l.nick) === folded);
  scheduleUserRender(visible);
}
