// Per-connection IRCv3 state: negotiated capabilities, ISUPPORT, and multiline batches.
import { MultilineAssembler } from "../common/multiline.ts";
import { monitored, pendingWho, readMarkers, users } from "./users.ts";

export const enabledCaps = new Set<string>();

export const multiline = new MultilineAssembler();

export const isupport = new Map<string, string>();

export function capOn(cap: string): boolean {
  return enabledCaps.has(cap);
}

export function resetIrcv3State(): void {
  enabledCaps.clear();
  multiline.clear();
  isupport.clear();
  users.clear();
  monitored.clear();
  readMarkers.clear();
  pendingWho.clear();
}
