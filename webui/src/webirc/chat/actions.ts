// The hover/tap action bar of a message (quick reactions, reply, edit,
// delete), and the one delegated listener that opens it on touch screens.
import { byId as $ } from "../../common/dom.ts";
import { t } from "../../common/i18n.ts";
import { ircFold } from "../../common/ircv3.ts";
import { QUICK_EMOJIS } from "../constants.ts";
import {
  sendReaction,
  sendRedaction,
  startEdit,
  startReply,
} from "../message_actions.ts";
import { featureOn } from "../settings.ts";
import { isOperatorInBuffer } from "../sidebar.ts";
import { buffers, S } from "../state.ts";
import type { ChatLine } from "../types.ts";

function actionButton(
  label: string,
  title: string,
  onClick: () => void,
  danger = false,
): HTMLButtonElement {
  const b = document.createElement("button");
  b.type = "button";
  b.className = danger ? "msg-act-btn danger" : "msg-act-btn";
  b.textContent = label;
  b.title = title;
  b.setAttribute("aria-label", title);
  b.onclick = onClick;
  return b;
}

export function createActions(entry: ChatLine): HTMLElement | null {
  const msgid = entry.msgid;
  if (!msgid || entry.redacted || entry.kind) return null;
  const isMine = ircFold(entry.nick) === ircFold(S.myNick);
  const canReact = featureOn("reactions");
  const canReply = featureOn("replies");
  const canEdit = featureOn("editing") && isMine && !entry.voiceId &&
    !entry.fileId && !entry.encrypted;
  const canDelete = featureOn("redaction") &&
    (isMine || isOperatorInBuffer(buffers.get(S.activeBuf)));
  if (!canReact && !canReply && !canEdit && !canDelete) return null;

  const actions = document.createElement("div");
  actions.className = "msg-actions";
  if (canReact) {
    for (const emoji of QUICK_EMOJIS) {
      actions.appendChild(
        actionButton(emoji, emoji, () => sendReaction(msgid, emoji)),
      );
    }
  }
  if (canReply) {
    actions.appendChild(
      actionButton("↩", t("msg.reply"), () => startReply(entry)),
    );
  }
  if (canEdit) {
    actions.appendChild(
      actionButton("✎", t("msg.edit"), () => startEdit(entry)),
    );
  }
  if (canDelete) {
    actions.appendChild(
      actionButton("🗑", t("msg.delete"), () => sendRedaction(msgid), true),
    );
  }
  return actions;
}

/**
 * Tapping a message (not one of its controls) opens its action bar and
 * closes any other. One listener on the list instead of one per row.
 */
export function initActionToggle(list: HTMLElement): void {
  list.addEventListener("click", (ev) => {
    const target = ev.target as HTMLElement | null;
    const row = target?.closest<HTMLElement>(".msg");
    if (!row || !row.querySelector(":scope > .msg-actions")) return;
    if (target?.closest("button, a, audio, .voice-wave")) return;
    const wasOpen = row.classList.contains("actions-open");
    list.querySelectorAll(".msg.actions-open").forEach((el) =>
      el.classList.remove("actions-open")
    );
    if (!wasOpen) row.classList.add("actions-open");
  });
}

/** Wire the delegated action-bar toggle on the message list. */
export function init(): void {
  initActionToggle($("messages"));
}
