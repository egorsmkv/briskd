// Reaction pills under a message; clicking one toggles your reaction.
import { ircFold } from "../../common/ircv3.ts";
import { sendReaction } from "../message_actions.ts";
import { featureOn } from "../settings.ts";
import { S } from "../state.ts";
import type { ChatLine } from "../types.ts";

export function createReactions(entry: ChatLine): HTMLElement | null {
  if (
    !entry.reactions || entry.reactions.size === 0 || entry.redacted ||
    !featureOn("reactions")
  ) {
    return null;
  }
  const me = ircFold(S.myNick);
  const bar = document.createElement("div");
  bar.className = "msg-reactions";
  entry.reactions.forEach((nicks, emoji) => {
    if (nicks.size === 0) return;
    const pill = document.createElement("button");
    pill.type = "button";
    const mine = Array.from(nicks).some((n) => ircFold(n) === me);
    pill.className = "react-pill" + (mine ? " mine" : "");
    pill.title = Array.from(nicks).join(", ");
    const em = document.createElement("span");
    em.textContent = emoji;
    const count = document.createElement("span");
    count.className = "react-count";
    count.textContent = String(nicks.size);
    pill.append(em, count);
    pill.onclick = () => {
      if (entry.msgid) sendReaction(entry.msgid, emoji);
    };
    bar.appendChild(pill);
  });
  return bar.childElementCount > 0 ? bar : null;
}
