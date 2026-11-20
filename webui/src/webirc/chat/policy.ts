// Pure rules of the chat view (no DOM), shared by the row and list
// components and unit-tested: author grouping, the "at the bottom" test, and
// how many lines to render to reach a given line.
import { dayKey } from "../../common/format.ts";

/** Lines rendered for the open conversation by default. */
export const DOM_WINDOW = 200;
/** Lines kept in the DOM at most; also the lines a conversation keeps. */
export const DOM_HARD_MAX = 600;
/** Within this many pixels of the end, the list counts as at the bottom. */
export const BOTTOM_SLACK_PX = 60;
/** Within this many pixels of the top, earlier lines load. */
export const LOAD_EARLIER_PX = 300;
/** A run of one author's lines is grouped when gaps stay under this. */
export const GROUP_GAP_MS = 180_000;

/** The fields grouping looks at. */
export interface GroupLine {
  nick: string;
  kind: string;
  epochMs: number;
}

/**
 * Whether `entry` continues the run of `prev` (same author, same day, a
 * normal message, less than GROUP_GAP_MS later): it is shown without the
 * avatar and nick.
 */
export function isGrouped(entry: GroupLine, prev?: GroupLine): boolean {
  return !!prev && !entry.kind && !!entry.nick && !prev.kind &&
    prev.nick === entry.nick &&
    dayKey(entry.epochMs) === dayKey(prev.epochMs) &&
    entry.epochMs - prev.epochMs < GROUP_GAP_MS;
}

/** Whether a scroll position counts as at the newest message. */
export function isAtBottom(
  scrollHeight: number,
  scrollTop: number,
  clientHeight: number,
): boolean {
  return scrollHeight - scrollTop - clientHeight < BOTTOM_SLACK_PX;
}

/**
 * The render window that includes the line at `index` of `total` lines, with
 * `margin` lines of context above it, never below `current` nor above
 * DOM_HARD_MAX. A line that is already inside `current` keeps `current`.
 */
export function windowToInclude(
  index: number,
  total: number,
  current: number,
  margin = 20,
): number {
  const needed = total - index + margin;
  return Math.min(DOM_HARD_MAX, Math.max(current, needed));
}
