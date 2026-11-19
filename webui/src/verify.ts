import { initTheme } from "./common/theme.ts";
import { initAltcha } from "./common/altcha.ts";

const $ = <T extends HTMLElement = HTMLElement>(id: string): T =>
  document.getElementById(id) as T;

function showNotice(ok: boolean, text: string): void {
  const n = $("notice");
  n.className = ok ? "ok" : "err";
  n.textContent = text;
}

initTheme([$("btn-theme")]);

const altcha = initAltcha(
  $<HTMLInputElement>("altcha-check"),
  $("altcha-label"),
  (msg) => showNotice(false, msg),
);

const accountInp = $<HTMLInputElement>("account");
const emailInp = $<HTMLInputElement>("email");
if (accountInp.value && !emailInp.value) {
  emailInp.placeholder = `Using account: ${accountInp.value}`;
}

$<HTMLFormElement>("verify-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const email = emailInp.value.trim();
  const account = accountInp.value.trim();
  const code = $<HTMLInputElement>("code").value.trim();

  if (!email && !account) {
    showNotice(false, "Enter your email address.");
    return;
  }
  const altchaPayload = altcha.getPayload();
  if (!altchaPayload) {
    showNotice(false, "Please complete the ALTCHA verification.");
    return;
  }

  const btn = $<HTMLButtonElement>("btn-submit");
  btn.disabled = true;
  try {
    const payload: Record<string, string> = { code, altcha: altchaPayload };
    if (email) payload.email = email;
    else payload.account = account;
    const res = await fetch("/api/verify", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Requested-With": "ircd-webui",
      },
      body: JSON.stringify(payload),
    });
    const data = (await res.json()) as { account?: string; message?: string; error?: string };
    if (res.ok) {
      showNotice(
        true,
        `Account '${data.account}' has been verified. You can now log in via SASL.`,
      );
      $<HTMLFormElement>("verify-form").reset();
      accountInp.value = "";
    } else {
      showNotice(false, data.message || data.error || "Verification failed.");
    }
  } catch (e) {
    showNotice(false, `Request failed: ${e instanceof Error ? e.message : String(e)}`);
  } finally {
    altcha.reset();
    btn.disabled = false;
  }
});
