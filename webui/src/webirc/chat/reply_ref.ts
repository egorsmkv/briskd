// The "replying to" quote above a reply; clicking it jumps to the original.
import { t } from "../../common/i18n.ts";
import { findMessageInActive } from "../message_actions.ts";
import { featureOn } from "../settings.ts";
import type { ChatLine } from "../types.ts";
import { jumpToMessage } from "./scroll.ts";

export function createReplyRef(entry: ChatLine): HTMLElement | null {
  const target = entry.replyTo;
  if (!target || entry.redacted || !featureOn("replies")) return null;
  const orig = findMessageInActive(target);
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "msg-reply-ref";
  const who = document.createElement("span");
  who.className = "reply-nick";
  who.textContent = orig ? `↩ ${orig.nick}` : "↩";
  const snip = document.createElement("span");
  snip.className = "reply-snip";
  snip.dir = "auto";
  snip.textContent = orig
    ? (orig.redacted ? t("msg.deleted") : orig.text.slice(0, 80))
    : target.slice(0, 12);
  btn.append(who, snip);
  btn.onclick = () => jumpToMessage(target);
  return btn;
}
