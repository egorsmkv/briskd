// The message box: keys, history, multi-line sending.
import { scrollToNewest } from "./chat/scroll.ts";
import { byId as $ } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import {
  CONCAT_TAG,
  MULTILINE_CAP,
  multilineBytes,
  splitMultiline,
  utf8Bytes,
} from "../common/multiline.ts";
import { addLine } from "./buffers.ts";
import { capOn } from "./caps.ts";
import { runSlashCommand } from "./commands.ts";
import { sendRaw } from "./connection.ts";
import { EDIT_TAG, REPLY_TAG } from "./constants.ts";
import { e2ee } from "./e2ee_ui.ts";
import { clearComposeMode } from "./message_actions.ts";
import { featureOn } from "./settings.ts";
import { switchBuf } from "./sidebar.ts";
import { buffers, S } from "./state.ts";
import { sendTypingState } from "./typing.ts";
import { isChan } from "./util.ts";

export const sentHistory: string[] = [];

export const msgInp = $<HTMLTextAreaElement>("inp-msg");

/** Grow the composer with its content, up to the CSS max-height. */
export function autosizeComposer(): void {
  msgInp.style.height = "auto";
  msgInp.style.height = `${msgInp.scrollHeight}px`;
}

// Room for the text of one PRIVMSG once the server adds our prefix (RFC 1459:
// 512 bytes per line): about 400 bytes minus the target.
export function lineBudget(target: string): number {
  return Math.max(100, 400 - utf8Bytes(target));
}

/** Lines sent one by one when the server has no draft/multiline. */
export const MAX_PLAIN_LINES = 10;

/** Why `text` cannot be sent to `target` as a multi-line message, or "". */
export function multilineProblem(target: string, text: string): string {
  const lines = splitMultiline(text, lineBudget(target));
  if (capOn(MULTILINE_CAP) && S.multilineLimits) {
    if (lines.length > S.multilineLimits.maxLines) {
      return t("ml.too_many_lines", { max: S.multilineLimits.maxLines });
    }
    if (multilineBytes(lines) > S.multilineLimits.maxBytes) {
      return t("ml.too_long", { max: S.multilineLimits.maxBytes });
    }
    return "";
  }
  const plain = lines.filter((l) => l.text.trim() !== "").length;
  return plain > MAX_PLAIN_LINES
    ? t("ml.unsupported", { max: MAX_PLAIN_LINES })
    : "";
}

/**
 * Send `text` as a PRIVMSG with optional message `tags` (`key=value;...`).
 * Text with line breaks goes as one draft/multiline batch, with the tags on
 * the opening BATCH line; without the capability each non-blank line becomes
 * its own PRIVMSG (the tags on the first).
 */
export function sendText(target: string, text: string, tags = ""): void {
  if (!text.includes("\n")) {
    sendRaw(`${tags ? `@${tags} ` : ""}PRIVMSG ${target} :${text}`);
    return;
  }
  const lines = splitMultiline(text, lineBudget(target));
  if (capOn(MULTILINE_CAP) && S.multilineLimits) {
    const ref = Math.random().toString(36).slice(2, 10) || "ml";
    sendRaw(
      `${tags ? `@${tags} ` : ""}BATCH +${ref} ${MULTILINE_CAP} ${target}`,
    );
    for (const l of lines) {
      const lineTags = l.concat ? `batch=${ref};${CONCAT_TAG}` : `batch=${ref}`;
      sendRaw(`@${lineTags} PRIVMSG ${target} :${l.text}`);
    }
    sendRaw(`BATCH -${ref}`);
    return;
  }
  let first = true;
  for (const l of lines) {
    if (!l.text.trim()) continue;
    sendRaw(`${first && tags ? `@${tags} ` : ""}PRIVMSG ${target} :${l.text}`);
    first = false;
  }
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  msgInp.addEventListener("input", autosizeComposer);

  msgInp.addEventListener("keydown", (ev) => {
    // Enter sends; Shift+Enter inserts a line break. Keys pressed while an
    // input method is composing (e.g. CJK) belong to the IME.
    if (ev.key === "Enter" && !ev.shiftKey && !ev.isComposing) {
      ev.preventDefault();
      $<HTMLFormElement>("send-form").requestSubmit();
      return;
    }
    // History only from the first or last line, so arrows still move the
    // caret inside a multi-line message.
    const caret = msgInp.selectionStart ?? 0;
    const onFirstLine = !msgInp.value.slice(0, caret).includes("\n");
    const onLastLine = !msgInp.value.slice(msgInp.selectionEnd ?? caret)
      .includes("\n");
    if (ev.key === "Tab") {
      const buf = buffers.get(S.activeBuf);
      if (!buf || !isChan(buf.name)) return;
      const val = msgInp.value;
      const lastSpace = val.lastIndexOf(" ");
      const prefix = val.slice(lastSpace + 1);
      if (!prefix) return;
      const match = Array.from(buf.members.keys()).find((n) =>
        n.toLowerCase().startsWith(prefix.toLowerCase())
      );
      if (match) {
        ev.preventDefault();
        const suffix = lastSpace === -1 ? ": " : " ";
        msgInp.value = val.slice(0, lastSpace + 1) + match + suffix;
      }
    } else if (ev.key === "ArrowUp" && !ev.altKey && onFirstLine) {
      if (sentHistory.length > 0) {
        ev.preventDefault();
        S.histPos = Math.min(S.histPos + 1, sentHistory.length - 1);
        msgInp.value = sentHistory[sentHistory.length - 1 - S.histPos];
        autosizeComposer();
      }
    } else if (ev.key === "ArrowDown" && !ev.altKey && onLastLine) {
      if (S.histPos > 0) {
        ev.preventDefault();
        S.histPos -= 1;
        msgInp.value = sentHistory[sentHistory.length - 1 - S.histPos];
      } else if (S.histPos === 0) {
        ev.preventDefault();
        S.histPos = -1;
        msgInp.value = "";
      }
      autosizeComposer();
    }
  });

  document.addEventListener("keydown", (ev) => {
    if (!ev.altKey || (ev.key !== "ArrowUp" && ev.key !== "ArrowDown")) return;
    const keys = Array.from(buffers.keys());
    if (keys.length < 2) return;
    ev.preventDefault();
    const idx = keys.indexOf(S.activeBuf);
    const delta = ev.key === "ArrowDown" ? 1 : -1;
    switchBuf(keys[(idx + delta + keys.length) % keys.length]);
  });

  $<HTMLFormElement>("send-form").addEventListener("submit", (ev) => {
    ev.preventDefault();
    // Line breaks at the end are not part of the message.
    const raw = msgInp.value.replace(/\r\n?/g, "\n").replace(/\s+$/, "");
    if (!raw.trim()) return;
    const buf = buffers.get(S.activeBuf);
    const multi = raw.includes("\n");
    if (raw.startsWith("/") && multi) {
      addLine(S.activeBuf, { text: t("ml.command"), kind: "err" });
      return;
    }
    // Refuse before clearing the composer, so nothing typed is lost.
    if (!raw.startsWith("/") && (!S.ws || S.ws.readyState !== WebSocket.OPEN)) {
      addLine(S.activeBuf, { text: t("rc.notsent"), kind: "err" });
      return;
    }
    if (
      multi && buf && buf.name !== "*status" && !raw.startsWith("/") &&
      !e2ee.isBufferEncrypted(buf.name)
    ) {
      const problem = multilineProblem(buf.name, raw);
      if (problem) {
        addLine(S.activeBuf, { text: problem, kind: "err" });
        return;
      }
    }
    msgInp.value = "";
    autosizeComposer();
    sentHistory.push(raw);
    if (sentHistory.length > 100) sentHistory.shift();
    S.histPos = -1;

    if (raw.startsWith("/")) {
      runSlashCommand(raw, buf);
      return;
    }
    if (!buf || buf.name === "*status") {
      addLine("*status", {
        text: "Join a channel first (e.g. /join #lobby) or type /help.",
        kind: "err",
      });
      return;
    }
    // Sending a message shows the newest lines, where its echo will appear.
    scrollToNewest(false);
    if (e2ee.isBufferEncrypted(buf.name)) {
      const dest = buf.name;
      clearComposeMode();
      sendTypingState(dest, "done");
      void e2ee.sendEncrypted(dest, raw).then((ok) => {
        if (ok) addLine(dest, { nick: S.myNick, text: raw, encrypted: true });
      });
      return;
    }
    sendTypingState(buf.name, "done");
    if (S.composeMode?.kind === "edit" && featureOn("editing")) {
      const targetId = S.composeMode.msgid;
      clearComposeMode();
      sendText(buf.name, raw, `${EDIT_TAG}=${targetId}`);
      return;
    }
    if (S.composeMode?.kind === "reply" && featureOn("replies")) {
      const targetId = S.composeMode.msgid;
      clearComposeMode();
      sendText(buf.name, raw, `${REPLY_TAG}=${targetId}`);
      return;
    }
    clearComposeMode();
    sendText(buf.name, raw);
  });
}
