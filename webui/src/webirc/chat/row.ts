// One message row, composed from its parts. Three shapes:
//   system line   [time] [text]
//   continuation  [time] [reply? body reactions?]           (same author run)
//   full message  [avatar] [reply? meta body reactions?]
// plus the action bar for lines that have a msgid.
import type { ChatLine } from "../types.ts";
import { createActions } from "./actions.ts";
import { createAvatar } from "./avatar.ts";
import { createBody } from "./body.ts";
import { createMeta, createTime } from "./meta.ts";
import { isGrouped } from "./policy.ts";
import { createReactions } from "./reactions.ts";
import { createReplyRef } from "./reply_ref.ts";

/** The row for one line; `prev` decides grouping under the same author. */
export function buildLineRow(entry: ChatLine, prev?: ChatLine): HTMLElement {
  const grouped = isGrouped(entry, prev);
  const row = document.createElement("div");
  row.className = "msg" +
    (entry.kind ? ` ${entry.kind}` : "") +
    (grouped ? " grouped" : "") +
    (entry.mention ? " mention" : "") +
    (entry.redacted ? " redacted" : "");
  if (entry.msgid) row.dataset.msgid = entry.msgid;
  row.dataset.ts = String(entry.epochMs);

  if (entry.kind || !entry.nick) {
    row.append(createTime(entry), createBody(entry, "span"));
  } else {
    const col = document.createElement("div");
    col.className = "msg-col";
    const ref = createReplyRef(entry);
    if (ref) col.appendChild(ref);
    if (!grouped) col.appendChild(createMeta(entry));
    col.appendChild(createBody(entry));
    const reactions = createReactions(entry);
    if (reactions) col.appendChild(reactions);
    row.append(
      grouped ? createTime(entry, true) : createAvatar(entry.nick),
      col,
    );
  }

  const actions = createActions(entry);
  if (actions) row.appendChild(actions);
  return row;
}
