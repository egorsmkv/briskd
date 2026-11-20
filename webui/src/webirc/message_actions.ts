// Replies, edits, reactions, and redactions.
import { byId as $ } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { ircFold } from "../common/ircv3.ts";
import { autosizeComposer, msgInp } from "./composer.ts";
import { sendRaw } from "./connection.ts";
import {
  MAX_REACTIONS_PER_MSG,
  REACT_TAG,
  REPLY_TAG,
  SAFE_MSGID_RE,
} from "./constants.ts";
import { renderActiveMessages } from "./chat/list.ts";
import { featureOn } from "./settings.ts";
import { buffers, S } from "./state.ts";
import { type ChatLine } from "./types.ts";

export function clearComposeMode(): void {
  S.composeMode = null;
  $("compose-banner").classList.add("hidden");
  $("compose-banner-label").textContent = "";
  $("compose-banner-snippet").textContent = "";
}

export function startReply(entry: ChatLine): void {
  if (!entry.msgid || !featureOn("replies")) return;
  S.composeMode = {
    kind: "reply",
    msgid: entry.msgid,
    nick: entry.nick,
    snippet: entry.text.slice(0, 100),
  };
  $("compose-banner-label").textContent = t("msg.replyingTo", {
    nick: entry.nick,
  });
  $("compose-banner-snippet").textContent = S.composeMode.snippet;
  $("compose-banner").classList.remove("hidden");
  msgInp.focus();
}

export function startEdit(entry: ChatLine): void {
  if (!entry.msgid || !featureOn("editing")) return;
  S.composeMode = {
    kind: "edit",
    msgid: entry.msgid,
    origText: entry.text,
  };
  $("compose-banner-label").textContent = t("msg.editing");
  $("compose-banner-snippet").textContent = entry.text.slice(0, 100);
  $("compose-banner").classList.remove("hidden");
  msgInp.value = entry.text;
  autosizeComposer();
  msgInp.focus();
}

export function findMessageInActive(msgid: string): ChatLine | undefined {
  const buf = buffers.get(S.activeBuf);
  if (!buf) return undefined;
  return buf.lines.find((l) => l.msgid === msgid);
}

export function sendReaction(msgid: string, emoji: string): void {
  if (!featureOn("reactions") || !SAFE_MSGID_RE.test(msgid)) return;
  const clean = emoji.trim().slice(0, 8);
  if (!clean || /[\s;\r\n\0]/.test(clean)) return;
  const buf = buffers.get(S.activeBuf);
  if (!buf || buf.name === "*status") return;
  sendRaw(`@${REPLY_TAG}=${msgid};${REACT_TAG}=${clean} TAGMSG ${buf.name}`);
}

export function sendRedaction(msgid: string): void {
  if (!featureOn("redaction") || !SAFE_MSGID_RE.test(msgid)) return;
  const buf = buffers.get(S.activeBuf);
  if (!buf || buf.name === "*status") return;
  sendRaw(`REDACT ${buf.name} ${msgid}`);
}

export function applyReaction(
  bufName: string,
  msgid: string,
  emoji: string,
  sender: string,
): void {
  if (!SAFE_MSGID_RE.test(msgid) || !sender) return;
  let cleanEmoji = "";
  for (const ch of emoji.trim()) {
    const code = ch.codePointAt(0) || 0;
    if (
      code < 0x20 || code === 0x7f ||
      (code >= 0x202a && code <= 0x202e) ||
      (code >= 0x2066 && code <= 0x2069)
    ) {
      continue;
    }
    cleanEmoji += ch;
    if (cleanEmoji.length >= 8) break;
  }
  if (!cleanEmoji) return;
  const key = ircFold(bufName);
  const buf = buffers.get(key);
  if (!buf) return;
  const line = buf.lines.find((l) => l.msgid === msgid);
  if (!line || line.redacted) return;
  if (!line.reactions) line.reactions = new Map();
  let set = line.reactions.get(cleanEmoji);
  if (!set) {
    if (line.reactions.size >= MAX_REACTIONS_PER_MSG) return;
    set = new Set();
    line.reactions.set(cleanEmoji, set);
  }
  const existing = Array.from(set).find((n) => ircFold(n) === ircFold(sender));
  if (existing) {
    set.delete(existing);
    if (set.size === 0) line.reactions.delete(cleanEmoji);
  } else {
    set.add(sender);
  }
  if (S.activeBuf === key) renderActiveMessages();
}

export function applyEdit(
  bufName: string,
  msgid: string,
  sender: string,
  senderAccount: string | undefined,
  newText: string,
): boolean {
  const key = ircFold(bufName);
  const buf = buffers.get(key);
  if (!buf) return false;
  const line = buf.lines.find((l) => l.msgid === msgid);
  if (
    !line || line.redacted || line.encrypted || line.voiceId || line.fileId ||
    line.albumIds
  ) {
    return false;
  }
  // Prevent spoofing: require matching nick, and matching SASL account if known
  if (ircFold(line.nick) !== ircFold(sender)) return false;
  if (
    line.account && line.account !== "*" &&
    (!senderAccount ||
      ircFold(senderAccount) !== ircFold(line.account))
  ) {
    return false;
  }
  line.text = newText;
  line.edited = true;
  if (S.activeBuf === key) renderActiveMessages();
  return true;
}

export function applyRedaction(bufName: string, msgid: string): void {
  const key = ircFold(bufName);
  const buf = buffers.get(key);
  if (!buf) return;
  const line = buf.lines.find((l) => l.msgid === msgid);
  if (!line) return;
  line.redacted = true;
  line.text = "";
  line.voiceId = undefined;
  line.fileId = undefined;
  line.reactions?.clear();
  if (S.activeBuf === key) renderActiveMessages();
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  $("btn-compose-cancel").onclick = () => {
    if (S.composeMode?.kind === "edit") msgInp.value = "";
    autosizeComposer();
    clearComposeMode();
  };
}
