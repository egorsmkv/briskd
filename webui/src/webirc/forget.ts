// Everything kept per conversation outside its BufferState, dropped when the
// conversation is closed, parted, or evicted, so a long session that visits
// many conversations does not keep state for each of them.
import { forgetPosition } from "./chat/scroll.ts";
import { typingTimers } from "./typing.ts";
import { readMarkers } from "./users.ts";

/** Forget the state of conversation `key` (folded name). */
export function forgetBuffer(key: string): void {
  forgetPosition(key);
  readMarkers.delete(key);
  const timers = typingTimers.get(key);
  if (timers) {
    for (const id of timers.values()) clearTimeout(id);
    typingTimers.delete(key);
  }
}
