import { byId, errorMessage, postJson, showNotice } from "./common/dom.ts";
import { initTheme } from "./common/theme.ts";
import { initAltcha } from "./common/altcha.ts";

interface SignupResponse {
  status?: string;
  account?: string;
  message?: string;
  error?: string;
}

const notice = (ok: boolean, text: string) => showNotice("notice", ok, text);

initTheme([byId("btn-theme")]);

const altcha = initAltcha(
  byId<HTMLInputElement>("altcha-check"),
  byId("altcha-label"),
  (msg) => notice(false, msg),
);

byId<HTMLFormElement>("signup-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const account = byId<HTMLInputElement>("account").value.trim();
  const email = byId<HTMLInputElement>("email").value.trim();
  const password = byId<HTMLInputElement>("password").value;
  const confirm = byId<HTMLInputElement>("confirm").value;

  if (password !== confirm) {
    notice(false, "Passwords do not match.");
    return;
  }
  if (!byId<HTMLInputElement>("accept-terms").checked) {
    notice(false, "You must accept the Terms of Use and Privacy Policy.");
    return;
  }
  const altchaPayload = altcha.getPayload();
  if (!altchaPayload) {
    notice(false, "Please complete the ALTCHA verification.");
    return;
  }

  const btn = byId<HTMLButtonElement>("btn-submit");
  btn.disabled = true;
  try {
    const payload: Record<string, unknown> = {
      account,
      password,
      accept_terms: true,
      altcha: altchaPayload,
    };
    if (email) payload.email = email;
    const { ok, data } = await postJson<SignupResponse>("/api/signup", payload);
    if (ok) {
      const msg = data.status === "verification_required"
        ? `Account '${data.account}' created. Check your email for the verification link or code.`
        : `Account '${data.account}' created. You can now log in via SASL in your IRC client.`;
      notice(true, msg);
      byId<HTMLFormElement>("signup-form").reset();
    } else {
      notice(false, data.message || data.error || "Sign up failed.");
    }
  } catch (err) {
    notice(false, `Request failed: ${errorMessage(err)}`);
  } finally {
    altcha.reset();
    btn.disabled = false;
  }
});
