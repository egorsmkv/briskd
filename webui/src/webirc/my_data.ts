// "Delete my data" rules (pure, unit-tested; delete_data.ts applies them).

/** Every key this app writes to browser storage starts with this. */
export const APP_KEY_PREFIX = "ircd-";

/**
 * The storage keys that belong to this app: settings, theme, language, the
 * saved session and reconnect secret, cached direct messages, and E2EE keys.
 */
export function appKeys(keys: Iterable<string>): string[] {
  return [...keys].filter((k) => k.startsWith(APP_KEY_PREFIX));
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
