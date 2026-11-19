import { byId, errorMessage, postJson, showNotice } from "./common/dom.ts";
import { initTheme } from "./common/theme.ts";
import { initAltcha } from "./common/altcha.ts";

interface RecoverResponse {
  status?: string;
  account?: string;
  message?: string;
  error?: string;
}

const notice = (ok: boolean, text: string) => showNotice("notice", ok, text);

initTheme([byId("btn-theme")]);

function switchStep(step: "request" | "confirm"): void {
  const isConfirm = step === "confirm";
  byId("tab-request").classList.toggle("active", !isConfirm);
  byId("tab-request").setAttribute("aria-selected", String(!isConfirm));
  byId("tab-confirm").classList.toggle("active", isConfirm);
  byId("tab-confirm").setAttribute("aria-selected", String(isConfirm));
  byId("recover-request-form").classList.toggle("active", !isConfirm);
  byId("recover-confirm-form").classList.toggle("active", isConfirm);
}

byId("tab-request").onclick = () => switchStep("request");
byId("tab-confirm").onclick = () => switchStep("confirm");

const altchaReq = initAltcha(
  byId<HTMLInputElement>("altcha-req-check"),
  byId("altcha-req-label"),
  (msg) => notice(false, msg),
);

const altchaCfm = initAltcha(
  byId<HTMLInputElement>("altcha-cfm-check"),
  byId("altcha-cfm-label"),
  (msg) => notice(false, msg),
);

const reqEmailInp = byId<HTMLInputElement>("req-email");
const cfmEmailInp = byId<HTMLInputElement>("cfm-email");
const cfmCodeInp = byId<HTMLInputElement>("cfm-code");

// If opened from an email link with ?code=..., jump directly to Step 2
if (cfmCodeInp.value.trim()) {
  switchStep("confirm");
}

byId<HTMLFormElement>("recover-request-form").addEventListener(
  "submit",
  async (ev) => {
    ev.preventDefault();
    const email = reqEmailInp.value.trim();
    if (!email) {
      notice(false, "Enter your email address.");
      return;
    }
    const altchaPayload = altchaReq.getPayload();
    if (!altchaPayload) {
      notice(false, "Please complete the ALTCHA verification.");
      return;
    }
    const btn = byId<HTMLButtonElement>("btn-req-submit");
    btn.disabled = true;
    try {
      const { ok, data } = await postJson<RecoverResponse>(
        "/api/recover/request",
        { email, altcha: altchaPayload },
      );
      if (ok) {
        notice(
          true,
          data.message ||
            "If an account exists for that email, a recovery code has been sent.",
        );
        cfmEmailInp.value = email;
        switchStep("confirm");
      } else {
        notice(
          false,
          data.message || data.error || "Could not send recovery email.",
        );
      }
    } catch (err) {
      notice(false, `Request failed: ${errorMessage(err)}`);
    } finally {
      altchaReq.reset();
      btn.disabled = false;
    }
  },
);

byId<HTMLFormElement>("recover-confirm-form").addEventListener(
  "submit",
  async (ev) => {
    ev.preventDefault();
    const email = cfmEmailInp.value.trim();
    const code = cfmCodeInp.value.trim();
    const password = byId<HTMLInputElement>("cfm-password").value;
    const confirm = byId<HTMLInputElement>("cfm-confirm").value;

    if (password !== confirm) {
      notice(false, "Passwords do not match.");
      return;
    }
    const altchaPayload = altchaCfm.getPayload();
    if (!altchaPayload) {
      notice(false, "Please complete the ALTCHA verification.");
      return;
    }

    const btn = byId<HTMLButtonElement>("btn-cfm-submit");
    btn.disabled = true;
    try {
      const { ok, data } = await postJson<RecoverResponse>(
        "/api/recover/confirm",
        { email, code, password, altcha: altchaPayload },
      );
      if (ok) {
        notice(
          true,
          `Password updated for account '${data.account}'. You can now log in via SASL.`,
        );
        byId<HTMLFormElement>("recover-confirm-form").reset();
      } else {
        notice(
          false,
          data.message || data.error || "Password reset failed.",
        );
      }
    } catch (err) {
      notice(false, `Request failed: ${errorMessage(err)}`);
    } finally {
      altchaCfm.reset();
      btn.disabled = false;
    }
  },
);
