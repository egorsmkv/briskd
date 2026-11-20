// A message's content: one of a deleted placeholder, an E2EE attachment, a
// code snippet, an image album, a voice message, a file card, or formatted
// text (with an "(edited)" mark and a link preview).
import { createRemoteCodeCard } from "../../common/code_card.ts";
import {
  createAlbumGrid,
  createEncryptedAttachmentView,
  createFileCard,
  parseE2eeAttachment,
} from "../../common/file_card.ts";
import { renderIrcMessage } from "../../common/format.ts";
import { t } from "../../common/i18n.ts";
import { ircFold } from "../../common/ircv3.ts";
import {
  createLinkPreviewSlot,
  extractFirstHttpUrl,
} from "../../common/link_preview.ts";
import { createVoicePlayer } from "../../common/voice_player.ts";
import { sendRaw } from "../connection.ts";
import { FILE_ID_RE, VOICE_ID_RE } from "../constants.ts";
import { featureOn } from "../settings.ts";
import { switchBuf } from "../sidebar.ts";
import { buffers, S } from "../state.ts";
import type { ChatLine } from "../types.ts";

/** The `.msg-text` element holding the content of `entry`. */
export function createBody(
  entry: ChatLine,
  tag: "div" | "span" = "div",
): HTMLElement {
  const body = document.createElement(tag);
  body.className = "msg-text";
  body.dir = "auto";
  body.appendChild(createContent(entry));
  return body;
}

function createContent(entry: ChatLine): Node {
  if (entry.redacted) {
    const span = document.createElement("span");
    span.className = "msg-redacted-text";
    span.textContent = t("msg.deleted");
    return span;
  }
  return createAttachment(entry) ?? createText(entry);
}

function createAttachment(entry: ChatLine): Node | null {
  if (entry.encrypted) {
    const att = parseE2eeAttachment(entry.text);
    if (att) {
      return createEncryptedAttachmentView(att, {
        voiceLabel: t("voice.label"),
        downloadLabel: t("file.download"),
      });
    }
  }
  if (entry.pasteId && FILE_ID_RE.test(entry.pasteId)) {
    return createRemoteCodeCard({
      fileId: entry.pasteId,
      lang: entry.pasteLang,
      title: entry.pasteTitle,
    });
  }
  if (entry.albumIds && entry.albumIds.length > 0) {
    return createAlbumGrid(
      entry.albumIds.map((id) => ({ url: `/api/files/${id}`, name: id })),
    );
  }
  if (entry.voiceId && VOICE_ID_RE.test(entry.voiceId)) {
    return createVoicePlayer({
      voiceId: entry.voiceId,
      durationSec: entry.voiceDur,
      label: t("voice.label"),
    });
  }
  if (entry.fileId && FILE_ID_RE.test(entry.fileId)) {
    return createFileCard({
      fileId: entry.fileId,
      fileName: entry.fileName || entry.fileId,
      fileSize: entry.fileSize,
      downloadLabel: t("file.download"),
    });
  }
  return null;
}

function createText(entry: ChatLine): Node {
  const frag = document.createDocumentFragment();
  frag.appendChild(renderIrcMessage(entry.text, {
    myNick: entry.kind ? undefined : S.myNick,
    onChannelClick: (chan: string) => {
      const key = ircFold(chan);
      if (buffers.has(key)) switchBuf(key);
      else sendRaw(`JOIN ${chan}`);
    },
  }));
  if (entry.edited) {
    const ed = document.createElement("span");
    ed.className = "msg-edited";
    ed.textContent = ` ${t("msg.edited")}`;
    frag.appendChild(ed);
  }
  if (!entry.encrypted && !entry.kind && featureOn("link_previews")) {
    const url = extractFirstHttpUrl(entry.text);
    if (url) frag.appendChild(createLinkPreviewSlot(url));
  }
  return frag;
}
