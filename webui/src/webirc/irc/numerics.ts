// Any other numeric reply, shown in the server tab (must run last).
import { addLine } from "../buffers.ts";
import type { IrcMessage } from "../types.ts";

/**
 * Any other numeric reply, shown in the server tab (must run last).
 * Returns true when the line was handled.
 */
export function handleNumerics(
  msg: IrcMessage,
  time: string | undefined,
): boolean {
  const { command, params } = msg;

  if (/^\d{3}$/.test(command)) {
    if (["366", "002", "003", "004", "005", "375", "376"].includes(command)) {
      return true;
    }
    addLine("*status", {
      time,
      text: `[${command}] ${params.slice(1).join(" ")}`,
      kind: "sys",
    });
  }
  return false;
}
