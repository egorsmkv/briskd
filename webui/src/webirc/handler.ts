// Handling of incoming IRC lines: preprocessing, then one handler per
// protocol area (./irc/).
import { multiline } from "./caps.ts";
import { sendRaw } from "./connection.ts";
import { e2ee } from "./e2ee_ui.ts";
import { parseIrc } from "./parse.ts";
import { handleCap } from "./irc/cap.ts";
import { handleRegistration } from "./irc/registration.ts";
import { handleChannels } from "./irc/channels.ts";
import { handleChat } from "./irc/chat.ts";
import { handleReplies } from "./irc/replies.ts";
import { handlePresence } from "./irc/presence.ts";
import { handleNumerics } from "./irc/numerics.ts";
import { handleSearchReply } from "./search_ui.ts";

export function handleMessage(raw: string): void {
  let msg = parseIrc(raw);
  if (!msg) return;
  if (msg.command === "PING") {
    sendRaw(`PONG :${msg.params[0] || ""}`);
    return;
  }
  // E2EE first: encrypted envelopes travel in their own draft/multiline
  // batches (tagged with the E2EE type), which the manager reassembles.
  if (e2ee.handleIrc(msg)) {
    return;
  }
  // Other draft/multiline batches: lines are held until the batch ends, which
  // is then handled as one PRIVMSG/NOTICE whose text has line breaks.
  const assembled = multiline.feed(msg);
  if (assembled.kind === "consumed") return;
  if (assembled.kind === "complete") msg = assembled.message;
  // Message search replies (egorsmkv.github.io/search) go to the search
  // dialog, never into a conversation.
  if (handleSearchReply(msg)) return;
  const time = msg.tags.time;
  if (handleCap(msg, time)) return;
  if (handleRegistration(msg, time)) return;
  if (handleChannels(msg, time)) return;
  if (handleChat(msg, time)) return;
  if (handleReplies(msg, time)) return;
  if (handlePresence(msg, time)) return;
  if (handleNumerics(msg, time)) return;
}
