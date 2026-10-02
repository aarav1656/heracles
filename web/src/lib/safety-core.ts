// Pure pieces of the pre-signing checks. No chain access, so they test without a node.

/** Treaty.sol's MAX_ROUND_AGE: `bind` reverts BadRound when a market's latest round is older than this. */
export const MAX_ROUND_AGE_SECONDS = 26 * 3600;

export type Freshness = { fresh: boolean; ageSeconds: number; words: string };

export function ageWords(sec: number): string {
  const s = Math.max(0, Math.floor(sec));
  if (s < 90) return `${s} seconds`;
  if (s < 5400) return `${Math.round(s / 60)} minutes`;
  return `${(s / 3600).toFixed(1)} hours`;
}

/** Same comparison as the contract: stale when `updatedAt + maxAge < now`. */
export function checkFreshness(updatedAt: bigint, nowSec: number, maxAge: number = MAX_ROUND_AGE_SECONDS): Freshness {
  const ageSeconds = nowSec - Number(updatedAt);
  const fresh = Number(updatedAt) + maxAge >= nowSec;
  const age = ageWords(ageSeconds);
  const bound = ageWords(maxAge);
  return {
    fresh,
    ageSeconds,
    words: fresh
      ? `The price feed last printed ${age} ago, inside the ${bound} the treaty accepts.`
      : `The price feed last printed ${age} ago, older than the ${bound} the treaty accepts. A bind now would revert, so signing is held until the feed prints again.`,
  };
}
