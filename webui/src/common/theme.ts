export type Theme = "light" | "dark";

const STORAGE_KEY = "ircd-webui-theme";

export function currentTheme(): Theme {
  return document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "light";
}

export function applyTheme(theme: Theme, buttons: Array<HTMLElement | null> = []): void {
  document.documentElement.setAttribute("data-theme", theme);
  const label = theme === "dark" ? "Light" : "Dark";
  for (const btn of buttons) {
    if (btn) btn.textContent = label;
  }
}

export function initTheme(buttons: Array<HTMLElement | null> = []): () => void {
  let saved: string | null = null;
  try {
    saved = localStorage.getItem(STORAGE_KEY);
  } catch {
    // Ignore storage errors in restricted contexts.
  }
  const prefersDark =
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-color-scheme: dark)").matches;
  const initial: Theme =
    saved === "dark" || saved === "light" ? saved : prefersDark ? "dark" : "light";
  applyTheme(initial, buttons);

  const toggle = () => {
    const next: Theme = currentTheme() === "dark" ? "light" : "dark";
    applyTheme(next, buttons);
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      // Ignore storage errors.
    }
  };

  for (const btn of buttons) {
    if (btn) btn.addEventListener("click", toggle);
  }
  return toggle;
}
