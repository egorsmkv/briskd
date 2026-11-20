// Private conversations kept across a page reload. Channel history comes back
// from the server (CHATHISTORY on join), and so do a logged-in user's
// private conversations (CHATHISTORY TARGETS); but the server keeps no
// private history for a guest, so without this a reload loses every private
// conversation, including one with a bot. The newest lines of each are kept
// in this tab's sessionStorage: private to the tab, gone when it closes or
// the user signs out.
import { ensureBuf } from "./buffers.ts";
import { buffers } from "./state.ts";
import { MAX_LINES, snapshot, type Stored } from "./dm_snapshot.ts";
import { isChan } from "./util.ts";

const KEY = "ircd-webirc-dms";
const SAVE_DELAY_MS = 1000;

let timer: ReturnType<typeof setTimeout> | null = null;

function isDm(name: string): boolean {
  return name !== "*status" && !isChan(name);
}

/** Save the private conversations now. */
export function saveDms(): void {
  if (timer !== null) {
    clearTimeout(timer);
    timer = null;
  }
  try {
    sessionStorage.setItem(KEY, JSON.stringify(snapshot(buffers.entries())));
  } catch {
    // Storage full or blocked: the conversations last as long as the page.
  }
}

/** Save soon; changes within SAVE_DELAY_MS are written once. */
export function scheduleDmSave(): void {
  if (timer === null) timer = setTimeout(saveDms, SAVE_DELAY_MS);
}

/**
 * Recreate the saved private conversations (before connecting, so history
 * fetched later only adds what is new). Lines are read already.
 */
export function restoreDms(): void {
  let stored: Stored;
  try {
    stored = JSON.parse(sessionStorage.getItem(KEY) || "{}");
  } catch {
    return;
  }
  for (const { name, lines } of Object.values(stored)) {
    if (typeof name !== "string" || !isDm(name) || !Array.isArray(lines)) {
      continue;
    }
    const buf = ensureBuf(name);
    if (buf.lines.length > 0) continue;
    buf.lines = lines
      .filter((l) =>
        l && typeof l.text === "string" && Number.isFinite(l.epochMs)
      )
      .slice(-MAX_LINES);
  }
}

/** Forget the saved conversations (sign-out). */
export function clearDms(): void {
  if (timer !== null) {
    clearTimeout(timer);
    timer = null;
  }
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    // ignore
  }
}

/** Save when the page is hidden or unloaded, so the last lines are kept. */
export function init(): void {
  addEventListener("pagehide", saveDms);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) saveDms();
  });
}
