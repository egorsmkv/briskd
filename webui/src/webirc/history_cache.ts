// Conversations kept across a page reload: channels and private
// conversations. After a reload the chat shows what it showed before and
// asks the server only for what came after (CHATHISTORY AFTER the newest
// message), as after a reconnect, instead of fetching and showing older
// messages again. It also keeps a guest's private conversations, which the
// server does not record. The newest lines of each are kept in this tab's
// sessionStorage: private to the tab, gone when it closes or the user signs
// out.
import { ensureBuf } from "./buffers.ts";
import { buffers } from "./state.ts";
import { restoredConversations, snapshot } from "./history_snapshot.ts";

const KEY = "briskd-webirc-history";
/** Earlier releases kept private conversations only, under this key. */
const OLD_KEY = "briskd-webirc-dms";
const SAVE_DELAY_MS = 1000;

let timer: ReturnType<typeof setTimeout> | null = null;

/** Save the conversations now. */
export function saveHistory(): void {
  if (timer !== null) {
    clearTimeout(timer);
    timer = null;
  }
  try {
    sessionStorage.setItem(KEY, JSON.stringify(snapshot(buffers.entries())));
    sessionStorage.removeItem(OLD_KEY);
  } catch {
    // Storage full or blocked: the conversations last as long as the page.
  }
}

/** Save soon; changes within SAVE_DELAY_MS are written once. */
export function scheduleHistorySave(): void {
  if (timer === null) timer = setTimeout(saveHistory, SAVE_DELAY_MS);
}

/**
 * Recreate the saved conversations (before connecting, so history fetched
 * later only adds what is new). Lines are read already.
 */
export function restoreHistory(): void {
  let raw: string | null;
  try {
    raw = sessionStorage.getItem(KEY) || sessionStorage.getItem(OLD_KEY);
  } catch {
    return;
  }
  if (!raw) return;
  for (const { name, lines } of restoredConversations(raw)) {
    const buf = ensureBuf(name);
    if (buf.lines.length === 0) buf.lines = lines;
  }
}

/** Forget the saved conversations (sign-out). */
export function clearHistory(): void {
  if (timer !== null) {
    clearTimeout(timer);
    timer = null;
  }
  try {
    sessionStorage.removeItem(KEY);
    sessionStorage.removeItem(OLD_KEY);
  } catch {
    // ignore
  }
}

/** Save when the page is hidden or unloaded, so the last lines are kept. */
export function init(): void {
  addEventListener("pagehide", saveHistory);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) saveHistory();
  });
}
