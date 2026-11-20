// Client-side navigation: the current location as signals, `navigate()`,
// and interception of same-origin links to app pages, so moving between
// pages keeps the chat connection and does not reload the app.
import { signal } from "@preact/signals";
import { pageFor } from "./routes.ts";

export const pathname = signal(location.pathname);
export const search = signal(location.search);

function sync(): void {
  pathname.value = location.pathname;
  search.value = location.search;
}

/** Go to `to` (same origin: in the app; elsewhere: a normal load). */
export function navigate(to: string, replace = false): void {
  const url = new URL(to, location.href);
  if (url.origin !== location.origin || pageFor(url.pathname) === null) {
    location.assign(url.href);
    return;
  }
  const target = url.pathname + url.search + url.hash;
  if (replace) history.replaceState(null, "", target);
  else history.pushState(null, "", target);
  sync();
  globalThis.scrollTo?.(0, 0);
}

/** Start following back/forward and intercepting in-app links. */
export function startRouter(): void {
  addEventListener("popstate", sync);
  document.addEventListener("click", (ev) => {
    if (
      ev.defaultPrevented || ev.button !== 0 || ev.metaKey || ev.ctrlKey ||
      ev.shiftKey || ev.altKey
    ) {
      return;
    }
    const link = (ev.target as Element | null)?.closest?.("a[href]");
    if (!(link instanceof HTMLAnchorElement)) return;
    if (link.target || link.hasAttribute("download")) return;
    if (link.dataset.native !== undefined) return;
    const url = new URL(link.href);
    if (url.origin !== location.origin || pageFor(url.pathname) === null) {
      return;
    }
    ev.preventDefault();
    navigate(url.pathname + url.search + url.hash);
  });
}
