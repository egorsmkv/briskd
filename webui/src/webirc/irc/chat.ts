// Messages: PRIVMSG, NOTICE, TAGMSG (reactions, typing), and REDACT.
import { isPreviewImageId } from "../../common/file_card.ts";
import { ircFold } from "../../common/ircv3.ts";
import { addLine } from "../buffers.ts";
import {
  ALBUM_TAG,
  EDIT_TAG,
  FILE_ID_RE,
  FILE_NAME_TAG,
  FILE_SIZE_TAG,
  FILE_TAG,
  PASTE_LANG_TAG,
  PASTE_TAG,
  PASTE_TITLE_TAG,
  REACT_TAG,
  REPLY_TAG,
  SAFE_MSGID_RE,
  TYPING_TAG,
  VOICE_DUR_TAG,
  VOICE_ID_RE,
  VOICE_TAG,
} from "../constants.ts";
import {
  applyEdit,
  applyReaction,
  applyRedaction,
} from "../message_actions.ts";
import { featureOn } from "../settings.ts";
import { S } from "../state.ts";
import type { IrcMessage } from "../types.ts";
import { updateRemoteTyping } from "../typing.ts";
import { isChan } from "../util.ts";

/**
 * Messages: PRIVMSG, NOTICE, TAGMSG (reactions, typing), and REDACT.
 * Returns true when the line was handled.
 */
export function handleChat(
  msg: IrcMessage,
  time: string | undefined,
): boolean {
  const { command, params, nick } = msg;

  if (command === "TAGMSG") {
    const target = params[0] || "";
    const dest = isChan(target)
      ? target
      : ircFold(nick) === ircFold(S.myNick)
      ? target
      : nick;
    if (!dest) return true;
    const reactEmoji = msg.tags[REACT_TAG];
    const replyTarget = msg.tags[REPLY_TAG];
    if (reactEmoji && replyTarget && featureOn("reactions")) {
      applyReaction(dest, replyTarget, reactEmoji, nick || msg.prefix);
      return true;
    }
    const typingState = msg.tags[TYPING_TAG];
    if (
      typingState && featureOn("typing") &&
      ircFold(nick) !== ircFold(S.myNick)
    ) {
      updateRemoteTyping(dest, nick, typingState);
    }
    return true;
  }

  if (command === "REDACT") {
    const target = params[0] || "";
    const targetMsgId = params[1] || "";
    const dest = isChan(target)
      ? target
      : ircFold(nick) === ircFold(S.myNick)
      ? target
      : nick;
    if (dest && targetMsgId) {
      applyRedaction(dest, targetMsgId);
    }
    return true;
  }

  if (command === "PRIVMSG" || command === "NOTICE") {
    const target = params[0] || "*status";
    const text = params[1] || "";
    const dest = isChan(target)
      ? target
      : ircFold(nick) === ircFold(S.myNick)
      ? target
      : nick || "*status";
    if (nick && ircFold(nick) !== ircFold(S.myNick)) {
      updateRemoteTyping(dest, nick, "done");
    }
    const editTargetId = msg.tags[EDIT_TAG];
    if (
      command === "PRIVMSG" && editTargetId &&
      SAFE_MSGID_RE.test(editTargetId) &&
      featureOn("editing") &&
      applyEdit(
        dest,
        editTargetId,
        nick || msg.prefix,
        msg.tags.account,
        text,
      )
    ) {
      return true;
    }
    if (text.startsWith("\x01ACTION ") && text.endsWith("\x01")) {
      addLine(dest, {
        time,
        text: `* ${nick} ${text.slice(8, -1)}`,
        kind: "action",
        msgid: msg.tags.msgid,
      });
    } else {
      const rawVoiceId = msg.tags[VOICE_TAG] || "";
      const voiceId = VOICE_ID_RE.test(rawVoiceId) ? rawVoiceId : undefined;
      const rawDur = parseInt(msg.tags[VOICE_DUR_TAG] || "", 10);
      const voiceDur = Number.isFinite(rawDur) && rawDur > 0 && rawDur <= 600
        ? rawDur
        : undefined;
      const rawFileId = msg.tags[FILE_TAG] || "";
      const fileId = FILE_ID_RE.test(rawFileId) ? rawFileId : undefined;
      let fileName: string | undefined;
      if (fileId && msg.tags[FILE_NAME_TAG]) {
        try {
          fileName = decodeURIComponent(msg.tags[FILE_NAME_TAG]);
        } catch {
          fileName = msg.tags[FILE_NAME_TAG];
        }
      }
      const rawFileSize = parseInt(msg.tags[FILE_SIZE_TAG] || "", 10);
      const fileSize = Number.isFinite(rawFileSize) && rawFileSize > 0
        ? rawFileSize
        : undefined;
      const rawAlbum = msg.tags[ALBUM_TAG] || "";
      const albumIds = rawAlbum
        ? rawAlbum.split(",").filter((id) =>
          FILE_ID_RE.test(id) && isPreviewImageId(id)
        ).slice(0, 10)
        : undefined;
      const rawPasteId = msg.tags[PASTE_TAG] || "";
      const pasteId = FILE_ID_RE.test(rawPasteId) ? rawPasteId : undefined;
      const pasteLang = pasteId
        ? (msg.tags[PASTE_LANG_TAG] || "text")
        : undefined;
      let pasteTitle: string | undefined;
      if (pasteId && msg.tags[PASTE_TITLE_TAG]) {
        try {
          pasteTitle = decodeURIComponent(msg.tags[PASTE_TITLE_TAG]);
        } catch {
          pasteTitle = msg.tags[PASTE_TITLE_TAG];
        }
      }
      const replyTo = msg.tags[REPLY_TAG] || undefined;
      addLine(dest, {
        time,
        nick: nick || msg.prefix,
        text,
        kind: command === "NOTICE" ? "notice" : "",
        msgid: msg.tags.msgid,
        account: msg.tags.account,
        replyTo,
        voiceId,
        voiceDur,
        fileId,
        fileName,
        fileSize,
        albumIds: albumIds && albumIds.length > 0 ? albumIds : undefined,
        pasteId,
        pasteLang,
        pasteTitle,
        bot: "bot" in msg.tags,
      });
    }
    return true;
  }
  return false;
}
