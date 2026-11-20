// ERROR, voice call signalling, and standard replies (FAIL/WARN/NOTE).
import { formatStandardReply } from "../../common/ircv3.ts";
import { addLine } from "../buffers.ts";
import { calls } from "../calls_ui.ts";
import type { IrcMessage } from "../types.ts";

/**
 * ERROR, voice call signalling, and standard replies (FAIL/WARN/NOTE).
 * Returns true when the line was handled.
 */
export function handleReplies(
  msg: IrcMessage,
  time: string | undefined,
): boolean {
  const { command, params, nick } = msg;

  if (command === "ERROR") {
    addLine("*status", {
      time,
      text: `${command}: ${params.join(" ")}`,
      kind: "err",
    });
    return true;
  }

  if (command === "CALL") {
    calls.handle(nick, params);
    return true;
  }

  if (command === "FAIL" && params[0] === "CALL") {
    // FAIL CALL <code> [<token>] :<text>
    const token = params.length >= 4 ? params[2] : "";
    calls.handleFail(params[1] || "", token, params[params.length - 1] || "");
    if (!calls.busy && !token) {
      addLine("*status", {
        time,
        text: formatStandardReply(command, params),
        kind: "err",
      });
    }
    return true;
  }

  if (command === "FAIL" || command === "WARN" || command === "NOTE") {
    addLine("*status", {
      time,
      text: formatStandardReply(command, params),
      kind: command === "FAIL" ? "err" : "sys",
    });
    return true;
  }
  return false;
}
