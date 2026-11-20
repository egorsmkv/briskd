// Settings → My Data: clear what this app stores in the browser, or delete
// the user's account and what it wrote on the server (POST
// /api/account/delete, which checks the password again). Either ends the
// session here: the connection is closed and the app reloads, so nothing
// from before stays in memory.
import { byId as $, errorMessage, postJson } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { sendRaw, stopReconnecting } from "./connection.ts";
import { appKeys, canDeleteAccount } from "./my_data.ts";
import { S } from "./state.ts";

interface DeleteReply {
  ok?: boolean;
  account?: string;
  error?: string;
  message?: string;
  retry_after?: number;
}

/** How long the success message shows before the app reloads, in ms. */
const RELOAD_DELAY_MS = 2500;

function removeAppKeys(store: Storage): void {
  try {
    const keys: string[] = [];
    for (let i = 0; i < store.length; i++) {
      const k = store.key(i);
      if (k !== null) keys.push(k);
    }
    for (const k of appKeys(keys)) store.removeItem(k);
  } catch {
    // Storage may be unavailable (private mode); nothing to clear then.
  }
}

/** Disconnect, remove this app's browser storage, and start over. */
function wipeAndReload(delayMs = 0): void {
  S.userClosed = true;
  stopReconnecting();
  if (S.ws && S.ws.readyState === WebSocket.OPEN) {
    sendRaw("QUIT :Leaving");
    S.ws.close();
  }
  S.ws = null;
  removeAppKeys(localStorage);
  removeAppKeys(sessionStorage);
  setTimeout(() => location.replace("/"), delayMs);
}

function notice(text: string, ok: boolean): void {
  const el = $("del-notice");
  el.textContent = text;
  el.classList.remove("hidden");
  el.classList.toggle("ok", ok);
  el.classList.toggle("err", !ok);
}

function formReady(): boolean {
  return canDeleteAccount(
    $<HTMLInputElement>("del-account").value,
    $<HTMLInputElement>("del-password").value,
    $<HTMLInputElement>("del-understood").checked,
  );
}

function updateButton(): void {
  $<HTMLButtonElement>("btn-delete-account").disabled = !formReady();
}

function minutes(seconds: number): number {
  return Math.max(1, Math.ceil(seconds / 60));
}

async function deleteAccount(ev: Event): Promise<void> {
  ev.preventDefault();
  if (!formReady()) return;
  const btn = $<HTMLButtonElement>("btn-delete-account");
  const account = $<HTMLInputElement>("del-account").value.trim();
  const password = $<HTMLInputElement>("del-password");
  btn.disabled = true;
  btn.setAttribute("aria-busy", "true");
  try {
    const { ok, status, data } = await postJson<DeleteReply>(
      "/api/account/delete",
      { account, password: password.value },
    );
    if (ok) {
      notice(
        t("data.account.done", { account: data.account ?? account }),
        true,
      );
      password.value = "";
      wipeAndReload(RELOAD_DELAY_MS);
      return;
    }
    if (status === 429) {
      notice(
        t("data.account.limited", { minutes: minutes(data.retry_after ?? 60) }),
        false,
      );
    } else if (status === 401) {
      notice(t("data.account.wrong"), false);
      password.value = "";
      password.focus();
    } else {
      notice(data.message || t("data.account.failed"), false);
    }
  } catch (err) {
    notice(`${t("data.account.failed")} ${errorMessage(err)}`, false);
  } finally {
    btn.removeAttribute("aria-busy");
    updateButton();
  }
}

function showClearConfirm(on: boolean): void {
  $("btn-clear-browser").classList.toggle("hidden", on);
  $("clear-browser-confirm").classList.toggle("hidden", !on);
  if (on) $("btn-clear-browser-no").focus();
}

/** Prepare the tab when it opens: the logged-in account is filled in. */
export function renderMyData(): void {
  const acct = $<HTMLInputElement>("del-account");
  if (!acct.value && S.account) acct.value = S.account;
  showClearConfirm(false);
  updateButton();
}

/** Wire the My Data tab. */
export function init(): void {
  $("btn-clear-browser").onclick = () => showClearConfirm(true);
  $("btn-clear-browser-no").onclick = () => {
    showClearConfirm(false);
    $("btn-clear-browser").focus();
  };
  $("btn-clear-browser-yes").onclick = () => wipeAndReload();
  for (const id of ["del-account", "del-password", "del-understood"]) {
    $(id).addEventListener("input", updateButton);
    $(id).addEventListener("change", updateButton);
  }
  $<HTMLFormElement>("delete-account-form").addEventListener(
    "submit",
    (ev) => void deleteAccount(ev),
  );
}
