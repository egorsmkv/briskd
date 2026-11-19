import { byId, errorMessage, postJson, showNotice } from "./common/dom.ts";
import { initTheme } from "./common/theme.ts";
import { initAltcha } from "./common/altcha.ts";

interface VerifyResponse {
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

const accountInp = byId<HTMLInputElement>("account");
const emailInp = byId<HTMLInputElement>("email");
if (accountInp.value && !emailInp.value) {
  emailInp.placeholder = `Using account: ${accountInp.value}`;
}

byId<HTMLFormElement>("verify-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const email = emailInp.value.trim();
  const account = accountInp.value.trim();
  const code = byId<HTMLInputElement>("code").value.trim();

  if (!email && !account) {
    notice(false, "Enter your email address.");
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
    const payload: Record<string, string> = { code, altcha: altchaPayload };
    if (email) payload.email = email;
    else payload.account = account;
    const { ok, data } = await postJson<VerifyResponse>("/api/verify", payload);
    if (ok) {
      notice(
        true,
        `Account '${data.account}' has been verified. You can now log in via SASL.`,
      );
      byId<HTMLFormElement>("verify-form").reset();
      accountInp.value = "";
    } else {
      notice(false, data.message || data.error || "Verification failed.");
    }
  } catch (err) {
    notice(false, `Request failed: ${errorMessage(err)}`);
  } finally {
    altcha.reset();
    btn.disabled = false;
  }
});
