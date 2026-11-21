// Capability negotiation (CAP) and SASL authentication.
import { CALLS_CAP } from "../../calls.ts";
import { saslAuthenticateChunks } from "../../common/ircv3.ts";
import { MULTILINE_CAP, parseMultilineCap } from "../../common/multiline.ts";
import { toB64 } from "../../e2ee/crypto.ts";
import { E2EE_CAP } from "../../e2ee/manager.ts";
import { addLine } from "../buffers.ts";
import { calls, updateCallButton } from "../calls_ui.ts";
import { enabledCaps } from "../caps.ts";
import { metadataSubscribe, sendRaw, wantedCaps } from "../connection.ts";
import {
  FEATURES_CAP,
  FILES_CAP,
  REDACT_CAP,
  VOICE_CAP,
} from "../constants.ts";
import { e2ee } from "../e2ee_ui.ts";
import { closeAttachMenu, updateFileButton } from "../files.ts";
import { parseFeatures } from "../feature_flags.ts";
import { announceServices, setServerFeatures } from "../server_features.ts";
import { updateSearchButton } from "../search_ui.ts";
import { S } from "../state.ts";
import type { IrcMessage } from "../types.ts";
import { updateVoiceButton } from "../voice.ts";

/**
 * Capability negotiation (CAP) and SASL authentication.
 * Returns true when the line was handled.
 */
export function handleCap(
  msg: IrcMessage,
  time: string | undefined,
): boolean {
  const { command, params } = msg;

  if (command === "CAP") {
    const sub = (params[1] || "").toUpperCase();
    if (sub === "LS" || sub === "NEW") {
      const more = params[2] === "*";
      const listStr = more ? params[3] || "" : params[2] || "";
      const offered: string[] = [];
      for (const tok of listStr.split(" ").filter(Boolean)) {
        const eq = tok.indexOf("=");
        const capName = eq === -1 ? tok : tok.slice(0, eq);
        offered.push(capName);
        if (!S.advertisedCaps.includes(capName)) S.advertisedCaps.push(capName);
        if (capName === CALLS_CAP) {
          calls.holdSupported = eq !== -1 &&
            tok.slice(eq + 1).split(",").includes("hold");
        }
        if (capName === MULTILINE_CAP) {
          S.multilineLimits = eq === -1
            ? null
            : parseMultilineCap(tok.slice(eq + 1));
        }
        if (capName === FILES_CAP && eq !== -1) {
          const m = /max-bytes=(\d+)/.exec(tok.slice(eq + 1));
          if (m) {
            const parsed = parseInt(m[1], 10);
            if (Number.isFinite(parsed) && parsed > 0) S.filesMaxBytes = parsed;
          }
        }
        if (capName === FEATURES_CAP && eq !== -1) {
          // The administrator's chat feature switches; a change arrives
          // as CAP NEW with the new list.
          setServerFeatures(parseFeatures(tok.slice(eq + 1)));
        }
      }
      if (sub === "NEW") {
        announceServices(offered, true);
        // cap-notify: request newly offered capabilities we want.
        const toReq = wantedCaps().filter((c) =>
          offered.includes(c) && !enabledCaps.has(c)
        );
        if (toReq.length > 0) sendRaw(`CAP REQ :${toReq.join(" ")}`);
        return true;
      }
      if (more) return true;
      if (!S.advertisedCaps.includes(REDACT_CAP)) {
        setServerFeatures({ redaction: false });
      }
      const toReq = wantedCaps().filter((c) => S.advertisedCaps.includes(c));
      if (toReq.length > 0) sendRaw(`CAP REQ :${toReq.join(" ")}`);
      else sendRaw("CAP END");
    } else if (sub === "DEL") {
      const removed = (params[2] || "").split(" ").filter(Boolean);
      S.advertisedCaps = S.advertisedCaps.filter((c) => !removed.includes(c));
      for (const c of removed) enabledCaps.delete(c);
      if (removed.includes(FILES_CAP)) {
        S.filesSupported = false;
        updateFileButton();
      }
      if (removed.includes(VOICE_CAP)) {
        S.voiceSupported = false;
        updateVoiceButton();
      }
      if (removed.includes(E2EE_CAP)) e2ee.setServerSupported(false);
      if (removed.includes(CALLS_CAP)) {
        calls.reset();
        calls.enabled = false;
        updateCallButton();
      }
      if (removed.includes(REDACT_CAP)) {
        setServerFeatures({ redaction: false });
      }
      if (removed.includes(FILES_CAP)) closeAttachMenu();
      updateSearchButton();
      announceServices(removed, false);
    } else if (sub === "ACK") {
      const acked = (params[2] || "").split(" ").filter(Boolean);
      for (const c of acked) {
        if (c.startsWith("-")) enabledCaps.delete(c.slice(1));
        else enabledCaps.add(c);
      }
      if (acked.includes(E2EE_CAP)) e2ee.setServerSupported(true);
      if (acked.includes(CALLS_CAP)) {
        calls.enabled = true;
        updateCallButton();
      }
      if (acked.includes(FILES_CAP)) {
        S.filesSupported = true;
        updateFileButton();
      }
      if (acked.includes(VOICE_CAP)) {
        S.voiceSupported = true;
        updateVoiceButton();
      }
      if (acked.includes("account-tag")) e2ee.setAccountTagEnabled(true);
      updateSearchButton();
      if (S.isRegistered) {
        // A later ACK (cap-notify): never re-run SASL or send CAP END again.
        if (acked.includes("draft/metadata-2")) metadataSubscribe();
      } else if (S.saslPass && acked.includes("sasl")) {
        sendRaw("AUTHENTICATE PLAIN");
      } else {
        sendRaw("CAP END");
      }
    } else if (sub === "NAK") {
      if (!S.isRegistered) sendRaw("CAP END");
    }
    return true;
  }

  if (command === "AUTHENTICATE" && params[0] === "+") {
    // RFC 4616: authzid NUL authcid NUL passwd, UTF-8 encoded, then base64
    // split into 400-byte AUTHENTICATE chunks (IRCv3 SASL 3.1).
    const auth = toB64(
      new TextEncoder().encode(`\0${S.saslUser || S.myNick}\0${S.saslPass}`),
    );
    for (const chunk of saslAuthenticateChunks(auth)) {
      sendRaw(`AUTHENTICATE ${chunk}`);
    }
    return true;
  }

  if (command === "900") {
    S.account = params[2] || "";
    if (params[2]) e2ee.setAccount(params[2]);
    return true;
  }

  if (command === "901") {
    S.account = "";
    return false;
  }

  if (command === "903") {
    if (S.saslUser || S.myNick) e2ee.setAccount(S.saslUser || S.myNick);
    addLine("*status", {
      time,
      text: params[1] || "SASL authentication successful",
      kind: "sys",
    });
    sendRaw("CAP END");
    return true;
  }

  if (command === "904" || command === "905") {
    addLine("*status", {
      time,
      text: `SASL failed: ${params[1] || ""}`,
      kind: "err",
    });
    sendRaw("CAP END");
    return true;
  }
  return false;
}
