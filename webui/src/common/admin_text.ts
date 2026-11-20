// Human-readable text for admin panel actions: titles, success messages, and
// error descriptions built from `/api/action` JSON replies.

const TITLES: Record<string, string> = {
  "rehash": "Rehash",
  "check-config": "Config check",
  "reload-certs": "Certificate reload",
  "log-level": "Log level change",
  "kick-client": "Kick",
  "notice-all": "Broadcast",
  "notice-channel": "Channel notice",
  "set-topic": "Topic update",
  "connect": "Connect",
  "squit": "SQUIT",
  "create-account": "Account creation",
  "verify-account": "Account verification",
  "reset-password": "Password reset",
  "delete-account": "Account deletion",
  "dronebl-ban": "IP ban",
  "dronebl-unban": "Unban",
  "backup": "Backup",
  "drain": "Drain",
  "stop": "Stop",
  "toggle-feature": "Feature toggle",
  "delete-voice": "Voice message deletion",
  "delete-file": "File deletion",
  "clear-upload-limits": "Upload limit reset",
};

/** Short title for an action, used as the prefix of error messages. */
export function actionTitle(action: string): string {
  return TITLES[action] ?? action;
}

function words(code: string): string {
  const text = code.replace(/_/g, " ").trim();
  return text ? text[0].toUpperCase() + text.slice(1) : text;
}

function field(data: unknown, key: string): unknown {
  return data && typeof data === "object"
    ? (data as Record<string, unknown>)[key]
    : undefined;
}

/**
 * Describe a failed reply. Prefers a `message`, then the `error` code, which
 * may be a plain snake_case atom or an Erlang term such as
 * `{no_such_nick,<<"bob">>}`.
 */
export function humanizeError(data: unknown, status?: number): string {
  const message = field(data, "message");
  if (typeof message === "string" && message) return message;
  const error = field(data, "error");
  if (typeof error === "string" && error) {
    const term = /^\{([a-z_]+),\s*(?:<<"([^"]*)">>|([^{}]*))\}$/.exec(error);
    if (term) {
      const arg = (term[2] ?? term[3] ?? "").trim();
      return arg ? `${words(term[1])}: ${arg}` : words(term[1]);
    }
    return /^[a-z_]+$/.test(error) ? words(error) : error;
  }
  return status ? `HTTP ${status}` : "Unknown error";
}

/** Confirmation text for a successful action. */
export function successMessage(
  action: string,
  args: string[],
  data: unknown,
): string {
  const target = args[0] ?? "";
  switch (action) {
    case "rehash":
      return "Configuration reloaded";
    case "check-config": {
      const status = field(data, "status");
      const path = field(data, "path");
      return status === "valid"
        ? `Configuration is valid${
          typeof path === "string" ? ` (${path})` : ""
        }`
        : `Configuration check: ${String(status ?? "done")}`;
    }
    case "reload-certs":
      return "TLS certificates reloaded";
    case "log-level":
      return `Log level set to ${String(field(data, "log_level") ?? target)}`;
    case "kick-client":
      return `Kicked ${target}`;
    case "notice-all":
      return "Notice broadcast to all users";
    case "notice-channel":
      return `Notice sent to ${target}`;
    case "set-topic":
      return args[1]
        ? `Topic updated for ${target}`
        : `Topic cleared for ${target}`;
    case "connect":
      return `Connecting to ${target}…`;
    case "squit":
      return `Disconnected ${target}`;
    case "create-account":
      return `Account ${target} created`;
    case "verify-account":
      return `Account ${target} verified`;
    case "reset-password":
      return `Password updated for ${target}`;
    case "delete-account":
      return `Account ${target} deleted`;
    case "dronebl-ban":
      return `Banned ${target}`;
    case "dronebl-unban":
      return `Unbanned ${target}`;
    case "backup":
      return `Backup written to ${target}`;
    case "drain":
      return "Listeners drained";
    case "stop":
      return "Server is stopping";
    case "toggle-feature":
      return `${words(target)} ${args[1] === "true" ? "enabled" : "disabled"}`;
    case "delete-voice":
      return "Voice message deleted";
    case "delete-file":
      return "File deleted";
    case "clear-upload-limits":
      return "Upload limits reset";
    default:
      return `${actionTitle(action)}: done`;
  }
}

/** "just now", "12s ago", "3m ago" for the last successful refresh. */
export function formatAgo(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 3) return "just now";
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  return `${Math.floor(m / 60)}h ago`;
}
