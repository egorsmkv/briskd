// Server-provided settings for the single-page app, read once from the
// `<script type="application/json" id="app-config">` block of the shell.

export interface AppConfig {
  /** IRC network name, for titles and headings. */
  network: string;
  /** IRC-over-WebSocket ports ("" when that listener is off). */
  wsPort: string;
  wssPort: string;
  /** Up to five configured channels, comma-separated. */
  defaultChannels: string;
  termsUrl: string;
  privacyUrl: string;
  /** Which pages this server offers. */
  features: {
    webirc: boolean;
    registration: boolean;
    verification: boolean;
    recovery: boolean;
  };
}

const DEFAULTS: AppConfig = {
  network: "IRC",
  wsPort: "",
  wssPort: "",
  defaultChannels: "#lobby",
  termsUrl: "",
  privacyUrl: "",
  features: {
    webirc: false,
    registration: false,
    verification: false,
    recovery: false,
  },
};

/** Parse a config document; missing or malformed fields get defaults. */
export function parseConfig(text: string | null | undefined): AppConfig {
  let raw: Partial<AppConfig> = {};
  try {
    const parsed: unknown = text ? JSON.parse(text) : {};
    // "null", a number, or an array is not a config: use the defaults.
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      raw = parsed as Partial<AppConfig>;
    }
  } catch {
    raw = {};
  }
  const str = (v: unknown, d: string) => typeof v === "string" ? v : d;
  const f =
    (raw.features && typeof raw.features === "object"
      ? raw.features
      : {}) as Partial<AppConfig["features"]>;
  return {
    network: str(raw.network, DEFAULTS.network),
    wsPort: str(raw.wsPort, ""),
    wssPort: str(raw.wssPort, ""),
    defaultChannels: str(raw.defaultChannels, DEFAULTS.defaultChannels),
    termsUrl: str(raw.termsUrl, ""),
    privacyUrl: str(raw.privacyUrl, ""),
    features: {
      webirc: f.webirc === true,
      registration: f.registration === true,
      verification: f.verification === true,
      recovery: f.recovery === true,
    },
  };
}

let cached: AppConfig | null = null;

/** The page's config (parsed on first use). */
export function config(): AppConfig {
  if (!cached) {
    cached = parseConfig(
      globalThis.document?.getElementById("app-config")?.textContent,
    );
  }
  return cached;
}
