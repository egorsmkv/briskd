export type Theme =
  | "hacker"
  | "light"
  | "dark"
  | "nord"
  | "solarized-light"
  | "solarized-dark"
  | "dracula"
  | "high-contrast";

export interface ThemeMeta {
  id: Theme;
  name: string;
  swatchBg: string;
  swatchAccent: string;
}

export const THEMES: ThemeMeta[] = [
  {
    id: "hacker",
    name: "Hacker",
    swatchBg: "#050a07",
    swatchAccent: "#00e64d",
  },
  { id: "light", name: "Light", swatchBg: "#f4f6f9", swatchAccent: "#2563eb" },
  { id: "dark", name: "Dark", swatchBg: "#0c1118", swatchAccent: "#3b82f6" },
  { id: "nord", name: "Nord", swatchBg: "#2e3440", swatchAccent: "#88c0d0" },
  {
    id: "solarized-light",
    name: "Solarized Light",
    swatchBg: "#fdf6e3",
    swatchAccent: "#268bd2",
  },
  {
    id: "solarized-dark",
    name: "Solarized Dark",
    swatchBg: "#002b36",
    swatchAccent: "#2aa198",
  },
  {
    id: "dracula",
    name: "Dracula",
    swatchBg: "#282a36",
    swatchAccent: "#bd93f9",
  },
  {
    id: "high-contrast",
    name: "High Contrast",
    swatchBg: "#000000",
    swatchAccent: "#38bdf8",
  },
];

const VALID_THEMES = new Set<string>(THEMES.map((t) => t.id));
let activeStorageKey = "ircd-webui-theme";
let activeDarkFallback: Theme = "dark";

export interface ThemeInitOptions {
  defaultTheme?: Theme;
  storageKey?: string;
}

export function currentTheme(): Theme {
  const attr = document.documentElement.getAttribute("data-theme") || "light";
  return VALID_THEMES.has(attr) ? (attr as Theme) : "light";
}

export function applyTheme(
  theme: Theme,
  buttons: Array<HTMLElement | null> = [],
): void {
  document.documentElement.setAttribute("data-theme", theme);
  const isLight = theme === "light" || theme === "solarized-light";
  const label = isLight
    ? (activeDarkFallback === "hacker" ? "Hacker" : "Dark")
    : "Light";
  for (const btn of buttons) {
    if (btn) btn.textContent = label;
  }
}

export function setTheme(
  theme: Theme,
  buttons: Array<HTMLElement | null> = [],
): void {
  applyTheme(theme, buttons);
  try {
    localStorage.setItem(activeStorageKey, theme);
  } catch {
    // Ignore storage errors.
  }
}

export function initTheme(
  buttons: Array<HTMLElement | null> = [],
  opts: ThemeInitOptions = {},
): () => void {
  activeStorageKey = opts.storageKey || "ircd-webui-theme";
  activeDarkFallback = opts.defaultTheme === "hacker" ? "hacker" : "dark";

  let saved: string | null = null;
  try {
    saved = localStorage.getItem(activeStorageKey);
  } catch {
    // Ignore storage errors in restricted contexts.
  }
  const allowed = opts.storageKey === "ircd-webirc-theme"
    ? VALID_THEMES
    : new Set<string>(["light", "dark"]);
  const prefersDark = typeof globalThis.matchMedia === "function" &&
    globalThis.matchMedia("(prefers-color-scheme: dark)").matches;
  const fallback: Theme = opts.defaultTheme ?? (prefersDark ? "dark" : "light");
  const initial: Theme = saved && allowed.has(saved)
    ? (saved as Theme)
    : fallback;
  applyTheme(initial, buttons);

  const toggle = () => {
    const cur = currentTheme();
    const next: Theme = cur === "light" || cur === "solarized-light"
      ? activeDarkFallback
      : "light";
    setTheme(next, buttons);
  };

  for (const btn of buttons) {
    if (btn) btn.addEventListener("click", toggle);
  }
  return toggle;
}
