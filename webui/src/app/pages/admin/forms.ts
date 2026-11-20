// Inline forms that submit through an action: the submit button spins while
// the request runs, and the fields are cleared only when it succeeds.
import { busyKey, runAction } from "./store.ts";

/** Busy key of the submit button of the form for `action`. */
export function formKey(action: string): string {
  return busyKey(`form:${action}`);
}

/** Submit `args` (null: incomplete, nothing sent); `clear` on success. */
export async function submitForm(
  action: string,
  args: string[] | null,
  clear: () => void,
): Promise<void> {
  if (!args) return;
  if (await runAction(action, args, { key: formKey(action) })) clear();
}
