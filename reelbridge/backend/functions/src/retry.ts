/** Mirrors com.reelbridge.core.publish.RetryPolicy. */
const BASE_DELAY_MS = 60_000;
const MAX_DELAY_MS = 30 * 60_000;

export function retryDelayMs(attempt: number): number {
  const shift = Math.min(Math.max(attempt - 1, 0), 10);
  return Math.min(BASE_DELAY_MS * 2 ** shift, MAX_DELAY_MS);
}
