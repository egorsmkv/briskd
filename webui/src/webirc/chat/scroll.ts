// Scrolling of the message list:
// - pinned: while the user is at the newest line, new lines and content that
//   grows later (images, link cards, waveforms, a smaller viewport when the
//   phone keyboard opens) keep it there, once per animation frame;
// - reading: while scrolled up, rows above the viewport that change height
//   do not move the text being read, and new lines are counted on the
//   "jump to latest" button instead of being scrolled to;
// - earlier lines load when the top is near;
// - each conversation remembers where its reader was;
// - jumping to a replied-to line renders it first if it is outside the window.
// The browser's own scroll anchoring is off for the list (CSS
// `overflow-anchor: none`) so this behaves the same in every browser.
import { byId as $ } from "../../common/dom.ts";
import { t } from "../../common/i18n.ts";
import { buffers, S } from "../state.ts";
import {
  hiddenLines,
  loadEarlier,
  renderMessages,
  trimMessages,
} from "./list.ts";
import {
  DOM_WINDOW,
  isAtBottom,
  LOAD_EARLIER_PX,
  windowToInclude,
} from "./policy.ts";

/** Whether the list follows the newest line, and lines missed meanwhile. */
export const scroll = { pinned: true, unseen: 0 };

let frame = 0;
let pendingTrim = false;
/**
 * scrollTop as last set by this module or seen in a scroll event. Scroll
 * events arrive after the fact: by then a flood may have appended rows, so
 * "not at the bottom" alone does not mean the user left it. A pinned list is
 * unpinned only when the position moved up from here.
 */
let lastTop = 0;
let loadingEarlier = false;
let resizeObserver: ResizeObserver | null = null;
/** Last seen height of each observed row (content box). */
const heights = new WeakMap<Element, number>();

/** Where a conversation's reader was, by conversation key. */
interface Position {
  msgid?: string;
  ts: string;
  /** Pixels from the list's top edge to the row's top edge. */
  offset: number;
  window: number;
}
const positions = new Map<string, Position>();

function list(): HTMLElement {
  return $("messages");
}

/** Set the list's scrollTop (every programmatic scroll goes through here). */
export function setScrollTop(top: number): void {
  const el = list();
  el.scrollTop = top;
  lastTop = el.scrollTop;
}

function reducedMotion(): boolean {
  return globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ??
    false;
}

function behavior(): ScrollBehavior {
  return reducedMotion() ? "auto" : "smooth";
}

// --- Row observation (rows report their own height changes) ---------------

export function observeRow(row: Element): void {
  resizeObserver?.observe(row);
}

export function forgetRow(row: Element): void {
  resizeObserver?.unobserve(row);
  heights.delete(row);
}

/** Before the list is rebuilt: stop observing every row (keeps the list). */
export function forgetAllRows(): void {
  if (!resizeObserver) return;
  resizeObserver.disconnect();
  resizeObserver.observe(list());
}

function onResize(entries: ResizeObserverEntry[]): void {
  const el = list();
  const top = el.getBoundingClientRect().top;
  let delta = 0;
  for (const entry of entries) {
    if (entry.target === el) continue; // the viewport itself changed size
    const height = entry.contentRect.height;
    const old = heights.get(entry.target);
    heights.set(entry.target, height);
    if (old === undefined || scroll.pinned) continue;
    // A row starting above the viewport grew or shrank: shift by as much, so
    // the rows on screen stay put.
    if (entry.target.getBoundingClientRect().top < top) delta += height - old;
  }
  if (scroll.pinned) stickSoon();
  else if (delta !== 0) setScrollTop(el.scrollTop + delta);
}

// --- Following the newest line --------------------------------------------

/** Scroll to the newest line in the next frame (batched per frame). */
function stickSoon(): void {
  if (frame) return;
  frame = requestAnimationFrame(() => {
    frame = 0;
    if (pendingTrim) {
      pendingTrim = false;
      trimMessages(true);
    }
    if (scroll.pinned) setScrollTop(list().scrollHeight);
  });
}

/** A live line was added to the list. */
export function onLineAppended(): void {
  if (scroll.pinned) {
    pendingTrim = true;
    stickSoon();
  } else {
    scroll.unseen++;
    trimMessages(false); // only beyond the hard cap
    updateFab();
  }
}

/** Show the newest line (after sending, or from the button). */
export function scrollToNewest(smooth = true): void {
  const el = list();
  scroll.pinned = true;
  scroll.unseen = 0;
  if (S.renderWindow > DOM_WINDOW) {
    S.renderWindow = DOM_WINDOW;
    pendingTrim = true;
  }
  if (smooth && behavior() === "smooth") {
    el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
  } else {
    setScrollTop(el.scrollHeight);
  }
  stickSoon();
  updateFab();
}

function onScroll(): void {
  const el = list();
  const top = el.scrollTop;
  const atBottom = isAtBottom(el.scrollHeight, top, el.clientHeight);
  if (scroll.pinned) {
    // Only the user moving up unpins; growth below does not.
    if (!atBottom && top < lastTop - 2) scroll.pinned = false;
  } else if (atBottom) {
    scroll.pinned = true;
  }
  lastTop = top;
  if (scroll.pinned) {
    scroll.unseen = 0;
    // Back at the newest lines after reading older ones: shrink to the
    // default window again.
    if (S.renderWindow > DOM_WINDOW || S.domLines > DOM_WINDOW) {
      S.renderWindow = DOM_WINDOW;
      pendingTrim = true;
      stickSoon();
    }
  } else if (
    !loadingEarlier && el.scrollTop < LOAD_EARLIER_PX && hiddenLines() > 0
  ) {
    // Near the top: load earlier lines in the next frame, once.
    loadingEarlier = true;
    requestAnimationFrame(() => {
      loadEarlier();
      loadingEarlier = false;
    });
  }
  updateFab();
}

// --- The "jump to latest" button --------------------------------------------

export function updateFab(): void {
  const el = list();
  const fab = $("btn-scroll-bottom");
  const far = el.scrollHeight - el.scrollTop - el.clientHeight > 180;
  fab.classList.toggle("hidden", scroll.pinned || (!far && !scroll.unseen));
  const count = $("scroll-fab-count");
  count.classList.toggle("hidden", scroll.unseen === 0);
  count.textContent = scroll.unseen > 99 ? "99+" : String(scroll.unseen);
  const label = scroll.unseen
    ? t("msg.new_below", { n: scroll.unseen })
    : t("msg.jump_latest");
  fab.title = label;
  fab.setAttribute("aria-label", label);
}

// --- Per-conversation position ----------------------------------------------

/** Remember where the reader of the open conversation `key` is. */
export function savePosition(key: string): void {
  if (scroll.pinned) {
    positions.delete(key);
    return;
  }
  const el = list();
  const top = el.getBoundingClientRect().top;
  for (const row of el.querySelectorAll<HTMLElement>(".msg")) {
    const rect = row.getBoundingClientRect();
    if (rect.bottom > top) {
      positions.set(key, {
        msgid: row.dataset.msgid,
        ts: row.dataset.ts ?? "",
        offset: rect.top - top,
        window: S.renderWindow,
      });
      return;
    }
  }
  positions.delete(key);
}

/** The render window to open conversation `key` with. */
export function savedWindow(key: string): number {
  return positions.get(key)?.window ?? DOM_WINDOW;
}

/**
 * After `key` was rendered at the bottom: return to the saved position, if
 * any. Returns whether a position was restored.
 */
export function restorePosition(key: string): boolean {
  const saved = positions.get(key);
  const el = list();
  const row = saved &&
    ((saved.msgid &&
      el.querySelector<HTMLElement>(
        `.msg[data-msgid="${CSS.escape(saved.msgid)}"]`,
      )) ||
      el.querySelector<HTMLElement>(`.msg[data-ts="${CSS.escape(saved.ts)}"]`));
  if (!saved || !row) {
    positions.delete(key);
    scroll.pinned = true;
    scroll.unseen = 0;
    updateFab();
    return false;
  }
  setScrollTop(
    el.scrollTop + row.getBoundingClientRect().top -
      el.getBoundingClientRect().top - saved.offset,
  );
  scroll.pinned = isAtBottom(el.scrollHeight, el.scrollTop, el.clientHeight);
  scroll.unseen = 0;
  updateFab();
  return true;
}

/** A conversation was closed: forget its position. */
export function forgetPosition(key: string): void {
  positions.delete(key);
}

// --- Jumping to a line --------------------------------------------------------

function rowOf(msgid: string): HTMLElement | null {
  return list().querySelector<HTMLElement>(
    `.msg[data-msgid="${CSS.escape(msgid)}"]`,
  );
}

/**
 * Scroll to the line with `msgid` and highlight it. A line kept in the
 * conversation but outside the rendered window is rendered first.
 */
export function jumpToMessage(msgid: string): void {
  let row = rowOf(msgid);
  if (!row) {
    const buf = buffers.get(S.activeBuf);
    const index = buf?.lines.findIndex((l) => l.msgid === msgid) ?? -1;
    if (!buf || index < 0) return;
    S.renderWindow = windowToInclude(index, buf.lines.length, S.renderWindow);
    renderMessages(buf, "none");
    row = rowOf(msgid);
    if (!row) return;
  }
  scroll.pinned = false;
  row.scrollIntoView({ behavior: behavior(), block: "center" });
  row.classList.remove("flash-highlight");
  void row.offsetWidth; // restart the highlight animation
  row.classList.add("flash-highlight");
}

/** Wire the list's scroll, resize, button, and keyboard handling. */
export function init(): void {
  const el = list();
  if (typeof ResizeObserver !== "undefined") {
    resizeObserver = new ResizeObserver(onResize);
    resizeObserver.observe(el);
  }
  el.addEventListener("scroll", onScroll, { passive: true });
  $("btn-scroll-bottom").addEventListener("click", () => scrollToNewest());
  // PageUp/PageDown in the message box scroll the conversation.
  document.addEventListener("keydown", (ev) => {
    if (ev.key !== "PageUp" && ev.key !== "PageDown") return;
    if (ev.altKey || ev.ctrlKey || ev.metaKey || ev.shiftKey) return;
    const target = ev.target as HTMLElement | null;
    if (target && target.id !== "inp-msg" && target !== document.body) return;
    ev.preventDefault();
    const page = el.clientHeight * 0.9;
    el.scrollBy({
      top: ev.key === "PageUp" ? -page : page,
      behavior: behavior(),
    });
  });
}
