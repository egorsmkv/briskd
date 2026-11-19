import { sha256 } from "@noble/hashes/sha256";
import { errorMessage } from "./dom.ts";

interface AltchaChallenge {
  algorithm: string;
  challenge: string;
  maxnumber?: number;
  salt: string;
  signature: string;
}

const enc = new TextEncoder();

function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}

async function sha256Hex(str: string): Promise<string> {
  const subtle = globalThis.crypto?.subtle;
  if (subtle) {
    const buf = await subtle.digest("SHA-256", enc.encode(str));
    return bytesToHex(new Uint8Array(buf));
  }
  return bytesToHex(sha256(enc.encode(str)));
}

export interface AltchaController {
  getPayload(): string | null;
  reset(): void;
}

export function initAltcha(
  checkbox: HTMLInputElement,
  label: HTMLElement,
  onError: (msg: string) => void,
): AltchaController {
  let payload: string | null = null;

  const reset = () => {
    payload = null;
    checkbox.checked = false;
    checkbox.disabled = false;
    label.textContent = "I'm not a robot";
  };

  checkbox.addEventListener("change", async () => {
    if (!checkbox.checked) {
      reset();
      return;
    }
    checkbox.disabled = true;
    label.textContent = "Verifying...";
    try {
      const res = await fetch("/api/altcha", { cache: "no-store" });
      if (!res.ok) throw new Error("Challenge unavailable");
      const ch = (await res.json()) as AltchaChallenge;
      const max = ch.maxnumber ?? 50000;
      let found = -1;
      for (let n = 0; n <= max; n++) {
        if ((await sha256Hex(ch.salt + n)) === ch.challenge) {
          found = n;
          break;
        }
        if ((n & 255) === 255) {
          await new Promise((r) => setTimeout(r, 0));
        }
      }
      if (found < 0) throw new Error("Verification failed");
      payload = btoa(
        JSON.stringify({
          algorithm: ch.algorithm,
          challenge: ch.challenge,
          number: found,
          salt: ch.salt,
          signature: ch.signature,
        }),
      );
      label.textContent = "Verified";
    } catch (err) {
      reset();
      onError(`ALTCHA error: ${errorMessage(err)}`);
    }
  });

  return {
    getPayload: () => payload,
    reset,
  };
}
