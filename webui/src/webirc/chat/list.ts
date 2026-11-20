// The message list of the open conversation, rendered as a window: only the
// newest `S.renderWindow` lines are in the DOM (each line is ~20 nodes plus
// any image, voice, or link card). New lines trim the oldest rows; earlier
// lines load on demand. The lines themselves stay in `buf.lines`.
import { byId as $ } from "../../common/dom.ts";
import { dayKey, formatDayLabel } from "../../common/format.ts";
import { t } from "../../common/i18n.ts";
import { buffers, S } from "../state.ts";
import type { BufferState, ChatLine } from "../types.ts";
import { DOM_HARD_MAX, DOM_WINDOW, isAtBottom } from "./policy.ts";
import { buildLineRow } from "./row.ts";
import {
  forgetAllRows,
  forgetRow,
  observeRow,
  onLineAppended,
  setScrollTop,
} from "./scroll.ts";

function list(): HTMLElement {
  return $("messages");
}

export function dayDivider(epochMs: number): HTMLElement {
  const sep = document.createElement("div");
  sep.className = "day-divider";
  const span = document.createElement("span");
  span.textContent = formatDayLabel(epochMs);
  sep.appendChild(span);
  return sep;
}

function earlierButton(hidden: number): HTMLElement {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "load-earlier";
  btn.textContent = t("msg.earlier", { n: hidden });
  btn.onclick = () => loadEarlier();
  return btn;
}

/** Lines of the open conversation not in the DOM. */
export function hiddenLines(): number {
  return (buffers.get(S.activeBuf)?.lines.length ?? 0) - S.domLines;
}

/**
 * Render DOM_WINDOW more earlier lines, keeping the lines on screen where
 * they are. Returns false when there are none.
 */
export function loadEarlier(): boolean {
  if (hiddenLines() <= 0 || S.renderWindow >= DOM_HARD_MAX) return false;
  const el = list();
  const before = el.scrollHeight;
  const top = el.scrollTop;
  // Grow from what is rendered: while reading, live lines can make that
  // more than the window.
  S.renderWindow = Math.min(
    DOM_HARD_MAX,
    Math.max(S.renderWindow, S.domLines) + DOM_WINDOW,
  );
  renderMessages(buffers.get(S.activeBuf), "none");
  setScrollTop(el.scrollHeight - before + top);
  return true;
}

/**
 * Rebuild the list for `buf` from its newest `S.renderWindow` lines.
 * `scroll` is "bottom" (show the newest), "keep" (stay at the bottom if
 * there, else keep the offset), or "none" (the caller positions it).
 */
export function renderMessages(
  buf: BufferState | undefined,
  scroll: "bottom" | "keep" | "none",
): void {
  const el = list();
  const prevTop = el.scrollTop;
  const atBottom = isAtBottom(el.scrollHeight, el.scrollTop, el.clientHeight);
  forgetAllRows();
  el.textContent = "";
  S.domLines = 0;
  if (!buf) return;
  const start = Math.max(0, buf.lines.length - S.renderWindow);
  if (start > 0) el.appendChild(earlierButton(start));
  let prev: ChatLine | undefined;
  for (let i = start; i < buf.lines.length; i++) {
    appendLineDom(buf.lines[i], prev, true);
    prev = buf.lines[i];
  }
  if (scroll === "bottom" || (scroll === "keep" && atBottom)) {
    setScrollTop(el.scrollHeight);
  } else if (scroll === "keep") {
    setScrollTop(prevTop);
  }
}

/** Rebuild the open conversation (settings or metadata changed). */
export function renderActiveMessages(): void {
  renderMessages(buffers.get(S.activeBuf), "keep");
}

/**
 * Add the row for `entry` (`prev` is the line before it). A `bulk` render
 * positions the scroll itself; a live line goes through the scroll
 * controller, which keeps the list at the newest line or counts it as unseen.
 */
export function appendLineDom(
  entry: ChatLine,
  prev?: ChatLine,
  bulk = false,
): void {
  const el = list();
  if (!prev || dayKey(entry.epochMs) !== dayKey(prev.epochMs)) {
    el.appendChild(dayDivider(entry.epochMs));
  }
  const row = buildLineRow(entry, prev);
  el.appendChild(row);
  observeRow(row);
  S.domLines++;
  if (!bulk) onLineAppended();
}

/**
 * Drop the oldest rows beyond the window. At the bottom the window applies;
 * while the user reads older lines nothing they may be looking at goes, up to
 * DOM_HARD_MAX, and the remaining rows keep their place on screen.
 */
export function trimMessages(atBottom: boolean): void {
  const limit = atBottom
    ? Math.min(DOM_HARD_MAX, S.renderWindow)
    : DOM_HARD_MAX;
  if (S.domLines <= limit) return;
  const el = list();
  const before = el.scrollHeight;
  let btn = el.firstElementChild?.classList.contains("load-earlier")
    ? el.firstElementChild as HTMLElement
    : null;
  const head = () => btn ? btn.nextElementSibling : el.firstElementChild;
  for (let node = head(); node && S.domLines > limit; node = head()) {
    if (node.classList.contains("msg")) {
      S.domLines--;
      forgetRow(node);
    }
    node.remove();
  }
  // Leading dividers left without their rows go too.
  for (
    let node = head();
    node?.classList.contains("day-divider") &&
    !node.nextElementSibling?.classList.contains("msg");
    node = head()
  ) {
    node.remove();
  }
  // The rows are the newest `domLines` lines. A first row that continues an
  // author's run is rebuilt with its nick and avatar, and the list starts
  // with that row's day.
  const buf = buffers.get(S.activeBuf);
  let first = head() as HTMLElement | null;
  if (first?.classList.contains("msg") && buf) {
    const line = buf.lines[buf.lines.length - S.domLines];
    if (line && first.classList.contains("grouped")) {
      const fresh = buildLineRow(line, undefined);
      forgetRow(first);
      first.replaceWith(fresh);
      observeRow(fresh);
      first = fresh;
    }
    if (first.dataset.ts) {
      el.insertBefore(dayDivider(Number(first.dataset.ts)), first);
    }
  }
  const hidden = hiddenLines();
  if (hidden > 0) {
    if (btn) btn.textContent = t("msg.earlier", { n: hidden });
    else {
      btn = earlierButton(hidden);
      el.insertBefore(btn, el.firstChild);
    }
  }
  if (!atBottom) setScrollTop(el.scrollTop - (before - el.scrollHeight));
}
