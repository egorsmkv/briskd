// Automatic reconnection for WebIRC: the backoff schedule, which channels to
// rejoin, and a fallback nickname while the old session still holds ours.

export interface BackoffOptions {
  /** Delay before the first retry. */
  baseMs: number;
  /** Ceiling for the delay. */
  maxMs: number;
  /** Growth per failed attempt. */
  factor: number;
  /** Fraction of the delay that is randomized (0..1), so clients spread out. */
  jitter: number;
}

export const DEFAULT_BACKOFF: BackoffOptions = {
  baseMs: 1000,
  maxMs: 60_000,
  factor: 2,
  jitter: 0.3,
};

/**
 * Delay before reconnect attempt `attempt` (0 for the first): exponential
 * growth capped at `maxMs`, minus up to `jitter` of it at random. The result
 * lies in `[d * (1 - jitter), d]` where `d = min(maxMs, baseMs * factor^n)`.
 */
export function backoffDelay(
  attempt: number,
  opts: BackoffOptions = DEFAULT_BACKOFF,
  random: () => number = Math.random,
): number {
  const n = Math.max(0, Math.floor(attempt));
  // Cap the exponent so large attempt counts cannot overflow to Infinity.
  const exp = Math.min(
    opts.maxMs,
    opts.baseMs * opts.factor ** Math.min(n, 30),
  );
  const spread = exp * Math.min(1, Math.max(0, opts.jitter));
  return Math.round(exp - spread * random());
}

/**
 * Channels to join after reconnecting: the channels open in the client, then
 * any configured auto-join channel not among them, without duplicates under
 * `fold` (the server's case mapping), in that order.
 */
export function rejoinList(
  open: string[],
  configured: string[],
  fold: (s: string) => string,
): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const ch of [...open, ...configured]) {
    const key = fold(ch);
    if (!ch || seen.has(key)) continue;
    seen.add(key);
    out.push(ch);
  }
  return out;
}

/**
 * The next nickname to try when `nick` is in use during registration (as
 * when the server has not yet noticed that the previous connection dropped):
 * append `_`, and once `maxLen` is reached replace the last character with a
 * digit that changes every attempt.
 */
export function altNick(nick: string, maxLen: number, attempt: number): string {
  const max = Math.max(2, maxLen);
  if (nick.length < max) return `${nick}_`;
  return `${nick.slice(0, max - 1)}${attempt % 10}`;
}
