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

$<HTMLFormElement>("signup-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const account = $<HTMLInputElement>("account").value.trim();
  const email = $<HTMLInputElement>("email").value.trim();
  const password = $<HTMLInputElement>("password").value;
  const confirm = $<HTMLInputElement>("confirm").value;

  if (password !== confirm) {
    showNotice(false, "Passwords do not match.");
    return;
  }
  if (!$<HTMLInputElement>("accept-terms").checked) {
    showNotice(false, "You must accept the Terms of Use and Privacy Policy.");
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
    const payload: Record<string, unknown> = {
      account,
      password,
      accept_terms: true,
      altcha: altchaPayload,
    };
    if (email) payload.email = email;
    const res = await fetch("/api/signup", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Requested-With": "ircd-webui",
      },
      body: JSON.stringify(payload),
    });
    const data = (await res.json()) as {
      status?: string;
      account?: string;
      message?: string;
      error?: string;
    };
    if (res.ok) {
      if (data.status === "verification_required") {
        showNotice(
          true,
          `Account '${data.account}' created. Check your email for the verification link or code.`,
        );
      } else {
        showNotice(
          true,
          `Account '${data.account}' created. You can now log in via SASL in your IRC client.`,
        );
      }
      $<HTMLFormElement>("signup-form").reset();
    } else {
      showNotice(false, data.message || data.error || "Sign up failed.");
    }
  } catch (e) {
    showNotice(false, `Request failed: ${e instanceof Error ? e.message : String(e)}`);
  } finally {
    altcha.reset();
    btn.disabled = false;
  }
});
