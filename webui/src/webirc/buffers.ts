// Conversations: creation, adding lines, mentions, page title and unread counters.
import { updateDynamicFavicon } from "../common/favicon.ts";
import { scheduleDmSave } from "./dm_cache.ts";
import { ircFold } from "../common/ircv3.ts";
import { SAFE_MSGID_RE } from "./constants.ts";
import { appendLineDom } from "./chat/list.ts";
import { BASE_TITLE, MAX_BUFFERS } from "./session.ts";
import { settings } from "./settings.ts";
import { renderBuffers } from "./sidebar.ts";
import { buffers, S } from "./state.ts";
import { type BufferState, type ChatLine } from "./types.ts";
import {
  markActiveRead,
  markerOf,
  monitorAdd,
  monitorRemove,
  requestMarker,
  scheduleMarkRead,
} from "./users.ts";
import { fmtTime, isChan } from "./util.ts";

export function updateTitle(): void {
  let totalUnread = S.hiddenUnread;
  let totalMentions = S.hiddenMentions;
  buffers.forEach((b) => {
    totalUnread += b.unread;
    totalMentions += b.mentions;
  });
  if (totalMentions > 0) document.title = `(@${totalMentions}) ${BASE_TITLE}`;
  else if (totalUnread > 0) document.title = `(${totalUnread}) ${BASE_TITLE}`;
  else document.title = BASE_TITLE;
  updateDynamicFavicon({
    connected: S.isRegistered,
    unread: totalUnread,
    mentions: totalMentions,
  });
}

export function clearHiddenCounters(): void {
  if (S.hiddenUnread > 0 || S.hiddenMentions > 0) {
    S.hiddenUnread = 0;
    S.hiddenMentions = 0;
    updateTitle();
  }
}

export function ensureBuf(name: string): BufferState {
  const key = ircFold(name);
  let buf = buffers.get(key);
  if (!buf) {
    if (buffers.size >= MAX_BUFFERS) {
      // Evict oldest inactive non-channel DM buffer to prevent DM flood memory exhaustion
      for (const [k, existing] of buffers.entries()) {
        if (k !== "*status" && k !== S.activeBuf && !isChan(existing.name)) {
          buffers.delete(k);
          monitorRemove(existing.name);
          break;
        }
      }
    }
    buf = {
      name,
      topic: "",
      lines: [],
      unread: 0,
      mentions: 0,
      members: new Map(),
      modes: new Set(),
      bans: [],
    };
    buffers.set(key, buf);
    renderBuffers();
    if (name !== "*status" && !isChan(name)) {
      monitorAdd([name]);
      requestMarker(name);
    }
  }
  return buf;
}

export function isMention(text: string, sender: string): boolean {
  if (!S.myNick || !sender || ircFold(sender) === ircFold(S.myNick)) {
    return false;
  }
  const escaped = S.myNick.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|\\W)${escaped}(\\W|$)`, "i").test(text);
}

export function addLine(
  bufName: string,
  opts: {
    time?: string;
    nick?: string;
    text: string;
    kind?: ChatLine["kind"];
    encrypted?: boolean;
    msgid?: string;
    account?: string;
    replyTo?: string;
    voiceId?: string;
    voiceDur?: number;
    fileId?: string;
    fileName?: string;
    fileSize?: number;
    albumIds?: string[];
    pasteId?: string;
    pasteLang?: string;
    pasteTitle?: string;
    bot?: boolean;
  },
): void {
  const buf = ensureBuf(bufName);
  const t = fmtTime(opts.time);
  const mention = opts.kind ? false : isMention(opts.text, opts.nick || "");
  const entry: ChatLine = {
    time: t.text,
    epochMs: t.ms,
    nick: opts.nick || "",
    text: opts.text,
    kind: opts.kind || "",
    mention,
    encrypted: opts.encrypted,
    msgid: opts.msgid && SAFE_MSGID_RE.test(opts.msgid)
      ? opts.msgid
      : undefined,
    account: opts.account,
    replyTo: opts.replyTo && SAFE_MSGID_RE.test(opts.replyTo)
      ? opts.replyTo
      : undefined,
    voiceId: opts.voiceId,
    voiceDur: opts.voiceDur,
    fileId: opts.fileId,
    fileName: opts.fileName,
    fileSize: opts.fileSize,
    albumIds: opts.albumIds,
    pasteId: opts.pasteId,
    pasteLang: opts.pasteLang,
    pasteTitle: opts.pasteTitle,
    bot: opts.bot,
  };
  // History fetched after a reconnect can overlap what is already shown.
  if (entry.msgid && buf.lines.some((l) => l.msgid === entry.msgid)) return;
  const prev = buf.lines[buf.lines.length - 1];
  buf.lines.push(entry);
  if (buf.lines.length > 600) buf.lines.shift();
  // Private conversations are kept across a page reload (dm_cache.ts).
  if (!isChan(bufName) && bufName !== "*status") scheduleDmSave();

  const isFromOther = !!entry.nick &&
    ircFold(entry.nick) !== ircFold(S.myNick);
  const isDm = !isChan(bufName) && bufName !== "*status";
  const isAlert = mention || (isDm && isFromOther && !opts.kind);

  // draft/read-marker: history older than the marker is already read.
  const isNew = t.ms > markerOf(bufName);
  if (ircFold(bufName) === S.activeBuf) {
    appendLineDom(entry, prev);
    if (document.hidden && isFromOther && !opts.kind && isNew) {
      S.hiddenUnread += 1;
      if (isAlert) S.hiddenMentions += 1;
      updateTitle();
    }
    if (entry.msgid) scheduleMarkRead();
  } else if (isNew) {
    buf.unread += 1;
    if (isAlert) buf.mentions += 1;
    renderBuffers();
    updateTitle();
  }
  if (
    isNew &&
    mention &&
    settings.notifyMentions &&
    typeof Notification !== "undefined" &&
    Notification.permission === "granted" &&
    document.hidden
  ) {
    new Notification(`${entry.nick} in ${bufName}`, { body: entry.text });
  }
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      clearHiddenCounters();
      markActiveRead();
    }
  });

  globalThis.addEventListener("focus", clearHiddenCounters);
}
