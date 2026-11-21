// "Delete my data" rules (pure, unit-tested; delete_data.ts applies them).

/** Settings, theme, language, and session keys start with this. */
export const APP_KEY_PREFIX = "briskd-";

/**
 * E2EE device keys stay under this prefix so a browser that already enrolled
 * a device keeps it. `appKeys` still treats them as this app's data.
 */
export const LEGACY_E2EE_PREFIX = "ircd-e2ee-v1:";

/**
 * The storage keys that belong to this app: settings, theme, language, the
 * saved session and reconnect secret, cached direct messages, and E2EE keys.
 */
export function appKeys(keys: Iterable<string>): string[] {
  return [...keys].filter(
    (k) => k.startsWith(APP_KEY_PREFIX) || k.startsWith(LEGACY_E2EE_PREFIX),
  );
}

/** Whether the delete-account form may be sent. */
export function canDeleteAccount(
  account: string,
  password: string,
  understood: boolean,
): boolean {
  return account.trim() !== "" && account.trim().length <= 64 &&
    password !== "" && understood;
}
