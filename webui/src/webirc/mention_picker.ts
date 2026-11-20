// The @-mention picker of the message box: typing "@" (and part of a name)
// lists matching people of the open conversation; Up/Down move, Enter or Tab
// insert "@nick ", Escape closes, and a click picks. The rules (what counts
// as a query, ranking, insertion) are in mention.ts.
import { byId as $ } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { ircFold } from "../common/ircv3.ts";
import { createAvatar } from "./chat/avatar.ts";
import { msgInp } from "./composer.ts";
import {
  applyMention,
  type MentionQuery,
  mentionQuery,
  rankMentions,
} from "./mention.ts";
import { buffers, S } from "./state.ts";
import { displayNameOf } from "./users.ts";
import { isChan } from "./util.ts";

/** Lines scanned for recent speakers, who rank first. */
const RECENT_LINES = 100;

let current: MentionQuery | null = null;
let items: string[] = [];
let active = 0;

function picker(): HTMLElement {
  return $("mention-picker");
}

export function isMentionPickerOpen(): boolean {
  return current !== null;
}

/** People who can be mentioned in the open conversation. */
function candidates(): { nicks: string[]; recent: string[] } {
  const buf = buffers.get(S.activeBuf);
  if (!buf || buf.name === "*status") return { nicks: [], recent: [] };
  const recent: string[] = [];
  for (
    let i = buf.lines.length - 1;
    i >= 0 && i >= buf.lines.length - RECENT_LINES;
    i--
  ) {
    const line = buf.lines[i];
    if (line.nick && !line.kind) recent.push(line.nick);
  }
  const nicks = isChan(buf.name) ? [...buf.members.keys()] : [buf.name];
  return { nicks, recent };
}

function close(): void {
  if (!current) return;
  current = null;
  items = [];
  picker().classList.add("hidden");
  picker().textContent = "";
  msgInp.setAttribute("aria-expanded", "false");
  msgInp.removeAttribute("aria-activedescendant");
}

function render(): void {
  const list = picker();
  list.textContent = "";
  items.forEach((nick, i) => {
    const opt = document.createElement("div");
    opt.id = `mention-opt-${i}`;
    opt.className = "mention-opt" + (i === active ? " active" : "");
    opt.setAttribute("role", "option");
    opt.setAttribute("aria-selected", String(i === active));
    const name = document.createElement("span");
    name.className = "mention-name";
    name.dir = "auto";
    name.textContent = displayNameOf(nick);
    opt.append(createAvatar(nick), name);
    if (displayNameOf(nick) !== nick) {
      const handle = document.createElement("span");
      handle.className = "mention-handle";
      handle.dir = "ltr";
      handle.textContent = nick;
      opt.appendChild(handle);
    }
    // Keep focus in the message box: pick on mousedown, not after blur.
    opt.addEventListener("mousedown", (ev) => {
      ev.preventDefault();
      choose(i);
    });
    list.appendChild(opt);
  });
  list.classList.remove("hidden");
  msgInp.setAttribute("aria-expanded", "true");
  msgInp.setAttribute("aria-activedescendant", `mention-opt-${active}`);
  list.querySelector(".mention-opt.active")?.scrollIntoView({
    block: "nearest",
  });
}

/** Re-read the text at the caret and show, update, or close the list. */
export function updateMentionPicker(): void {
  const caret = msgInp.selectionStart ?? 0;
  if (caret !== msgInp.selectionEnd) return close();
  const query = mentionQuery(msgInp.value, caret);
  if (!query) return close();
  const { nicks, recent } = candidates();
  const ranked = rankMentions(query.query, nicks, {
    fold: ircFold,
    display: displayNameOf,
    recent,
    exclude: S.myNick,
  });
  if (ranked.length === 0) return close();
  const sameQuery = current?.start === query.start;
  const keep = sameQuery ? items[active] : undefined;
  current = query;
  items = ranked;
  active = keep !== undefined ? Math.max(0, ranked.indexOf(keep)) : 0;
  render();
}

function choose(index: number): void {
  const nick = items[index];
  const query = current;
  if (!nick || !query) return;
  const caret = msgInp.selectionStart ?? msgInp.value.length;
  const next = applyMention(msgInp.value, query.start, caret, nick);
  close();
  msgInp.value = next.text;
  msgInp.setSelectionRange(next.caret, next.caret);
  // Let the composer resize and the typing indicator see the change.
  msgInp.dispatchEvent(new Event("input", { bubbles: true }));
}

/**
 * Keys for the open list; the message box calls this first and skips its
 * own handling (send, history, Tab completion) when it returns true.
 */
export function handleMentionKey(ev: KeyboardEvent): boolean {
  if (!current || ev.isComposing) return false;
  switch (ev.key) {
    case "ArrowDown":
    case "ArrowUp": {
      const step = ev.key === "ArrowDown" ? 1 : -1;
      active = (active + step + items.length) % items.length;
      render();
      break;
    }
    case "Enter":
    case "Tab":
      if (ev.shiftKey) return false;
      choose(active);
      break;
    case "Escape":
      close();
      // Do not also clear a reply or close dialogs (document handler).
      ev.stopPropagation();
      break;
    default:
      return false;
  }
  ev.preventDefault();
  return true;
}

/** Wire the list to the message box. */
export function init(): void {
  picker().setAttribute("aria-label", t("mention.label"));
  msgInp.setAttribute("aria-autocomplete", "list");
  msgInp.setAttribute("aria-controls", "mention-picker");
  msgInp.setAttribute("aria-expanded", "false");
  msgInp.addEventListener("input", updateMentionPicker);
  // Caret moves without typing (arrows, Home/End, clicks) change the query.
  msgInp.addEventListener("click", updateMentionPicker);
  msgInp.addEventListener("keyup", (ev) => {
    if (
      ev.key === "ArrowLeft" || ev.key === "ArrowRight" ||
      ev.key === "Home" || ev.key === "End"
    ) {
      updateMentionPicker();
    }
  });
  msgInp.addEventListener("blur", close);
}
