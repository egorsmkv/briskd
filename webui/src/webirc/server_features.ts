// The server's chat features (egorsmkv.github.io/features, and
// draft/message-redaction) and what changes when an administrator turns one
// on or off while people are connected (cap-notify: CAP NEW with the new
// list, or CAP DEL). The open conversation is redrawn so its rows lose or
// gain reply, edit, delete, and reaction controls and link cards; a reply or
// edit in progress that is no longer allowed is cancelled; typing state is
// dropped when typing indicators go away; and the user is told.
import { t } from "../common/i18n.ts";
import { addLine } from "./buffers.ts";
import { renderActiveMessages } from "./chat/list.ts";
import { clearComposeMode } from "./message_actions.ts";
import { applySettings, featureOn, serverFeatures } from "./settings.ts";
import { S } from "./state.ts";
import { changedFeatures } from "./feature_flags.ts";
import type { FeatureKey } from "./types.ts";
import { renderTypingBar, typingTimers } from "./typing.ts";

/**
 * Take the server's features `next` (some or all keys). Before registration
 * (capability negotiation) only the settings are updated; afterwards a
 * change is applied to what is on screen and announced.
 */
export function setServerFeatures(
  next: Partial<Record<FeatureKey, boolean>>,
): void {
  const changed = changedFeatures(serverFeatures, next);
  Object.assign(serverFeatures, next);
  applySettings();
  if (changed.length === 0 || !S.isRegistered) return;

  const mode = S.composeMode?.kind;
  if (
    (mode === "reply" && !featureOn("replies")) ||
    (mode === "edit" && !featureOn("editing"))
  ) {
    clearComposeMode();
  }
  if (!featureOn("typing")) {
    for (const timers of typingTimers.values()) {
      for (const id of timers.values()) clearTimeout(id);
    }
    typingTimers.clear();
  }
  renderTypingBar();
  renderActiveMessages();

  const names = (on: boolean) =>
    changed.filter((k) => serverFeatures[k] === on)
      .map((k) => t(`settings.${k}`))
      .join(", ");
  const off = names(false);
  const on = names(true);
  if (off) notice(t("features.off", { list: off }));
  if (on) notice(t("features.on", { list: on }));
}

/** Tell the user in the conversation they are looking at. */
export function notice(text: string): void {
  addLine(S.activeBuf || "*status", { text, kind: "sys" });
}

/** Services the server can withdraw or offer again, by capability. */
const SERVICE_NAMES: Record<string, string> = {
  "egorsmkv.github.io/files": "features.files",
  "egorsmkv.github.io/voice": "features.voice",
  "egorsmkv.github.io/calls": "features.calls",
  "egorsmkv.github.io/e2ee": "features.e2ee",
  "draft/chathistory": "features.history",
};

/**
 * After registration, tell the user about services the server withdrew
 * (CAP DEL) or offers again (CAP NEW).
 */
export function announceServices(caps: string[], available: boolean): void {
  if (!S.isRegistered) return;
  for (const cap of caps) {
    const key = SERVICE_NAMES[cap];
    if (!key) continue;
    notice(
      t(available ? "features.service.on" : "features.service.off", {
        name: t(key),
      }),
    );
  }
}
