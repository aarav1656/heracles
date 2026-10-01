// Treaty-domain constants and plain-word error glosses. No invented numbers.
import type { Address, PublicClient } from 'viem';
import { aggregatorAbi } from '../abi';
import { fmtClock } from './format';

export const LAYER_STATES = ['None', 'Bound', 'Settled', 'Cancelled'] as const;

// Mirrors Treaty.sol's internal constants (not exposed on-chain, so kept here in lockstep).
export const REFERENCE_MAX_DELAY_SECONDS = 36 * 3600;
export const GRACE_SECONDS = 3 * 86400;
/** Binding closes this long before the Friday 19:30 UTC anchor: Thursday 19:30 UTC. */
export const BIND_LEAD_SECONDS = 86400;

/** Monday's fixing time, derived from the layer expiry the chain reports (13:30/14:30 UTC, DST-aware). */
export function fixingWords(expiry: bigint): string {
  return `Fixing opens after ${fmtClock(expiry)} UTC and waits for the first SPY round at or after that time.`;
}

export type ReferenceRound =
  | { kind: 'none' }
  | { kind: 'unknown' }
  | { kind: 'found'; roundId: bigint; updatedAt: bigint; late: boolean };

/**
 * Walks a Chainlink feed backward from its latest round to find the first round with
 * `updatedAt >= boundary` whose predecessor is strictly before it, the same "first fresh
 * round" rule Treaty.sol's setReference/voidReference check on-chain (`NotFirstRound`). `late`
 * marks a found round more than `REFERENCE_MAX_DELAY_SECONDS` past `boundary`: setReference
 * would revert `BadRound` on it, so voidReference is the correct call instead.
 * ponytail: linear walk capped at 200 rounds back from latest; a feed printing far more often
 * than its heartbeat over many days without anyone calling in could exceed this, upgrade to a
 * binary search on `updatedAt` if that ever happens in practice.
 */
export async function findFirstRoundAtOrAfter(
  client: PublicClient,
  feed: Address,
  boundary: number,
  latestRoundId: bigint,
  latestUpdatedAt: bigint,
): Promise<ReferenceRound> {
  const boundaryBig = BigInt(boundary);
  if (latestUpdatedAt < boundaryBig) return { kind: 'none' };

  let cursor = latestRoundId;
  let cursorUpdatedAt = latestUpdatedAt;
  for (let i = 0; i < 200; i++) {
    if (BigInt.asUintN(64, cursor) <= 1n) return { kind: 'unknown' };
    const predId = cursor - 1n;
    let predUpdatedAt: bigint;
    try {
      const data = await client.readContract({
        address: feed, abi: aggregatorAbi, functionName: 'getRoundData', args: [predId],
      });
      predUpdatedAt = (data as readonly [bigint, bigint, bigint, bigint, bigint])[3];
    } catch {
      return { kind: 'unknown' };
    }
    if (predUpdatedAt !== 0n && predUpdatedAt < boundaryBig) {
      return {
        kind: 'found',
        roundId: cursor,
        updatedAt: cursorUpdatedAt,
        late: cursorUpdatedAt > boundaryBig + BigInt(REFERENCE_MAX_DELAY_SECONDS),
      };
    }
    cursor = predId;
    cursorUpdatedAt = predUpdatedAt;
  }
  return { kind: 'unknown' };
}

export const ERROR_WORDS: Record<string, string> = {
  BadParams: 'A parameter fails the contract checks: exposure length must match the market count, every exposure and the limit must be above zero in the right places, or the recipient is the zero address.',
  BadTiming: 'Too early or too late for this call on the layer clock. Binding needs now strictly before the Thursday 19:30 UTC bind deadline; setReference needs the Friday 4:00pm ET close to have passed; voidReference needs a first round more than 36h after that close; cancel needs expiry plus 3 days.',
  BadRound: "That feed round is not acceptable: stale or ahead of now, non-positive, out of the 64-bit price range, more than 36h past Friday's close (setReference only), or from a superseded Chainlink phase.",
  NotFirstRound: "That round is not the first one at or after the boundary this call checks (Friday's close for setReference/voidReference, Monday's expiry for fix): its predecessor already sits at or after that boundary too. Use the round the panel found, or step one round back and retry.",
  EarlyFix: 'Fixing is not open yet. The layer can only be fixed after Monday 13:30/14:30 UTC expiry (DST-aware).',
  ReferenceNotSet: 'Every market needs its Friday reference set before any market can be fixed.',
  PremiumTooHigh: 'The premium for these terms rose above the ceiling this bind carried (the premium you were shown). Review the new quote and bind again.',
  ReferenceKnownAtBind: 'That round was already in effect when this layer bound, so it cannot be the reference. Use voidReference on it.',
  ReferenceIsVoid: "This market's Friday reference was already proven void; it can no longer be set or voided again.",
  WrongState: 'The layer is not in the state this call needs.',
  FixIsVoid: "This market's Monday fix was proven impossible (its first round carries an unusable answer), so it can no longer be fixed. The layer can be cancelled for a full refund.",
  AlreadyFixed: 'This market is already fixed for this layer.',
  NothingToClaim: 'Nothing is claimable here: wrong caller, already claimed, or a zero payout.',
  SequencerDown: 'The Arbitrum sequencer is down or still inside the one-hour restart grace period.',
  StillFixable: 'This layer still has a market that could be referenced or fixed right now. Cancel is only for a layer with no path left to settle.',
  CapacityExceeded: 'The limit is larger than the free writer capacity. Lower the limit or wait for more deposits.',
  InsufficientLocked: 'The pool has less locked capital than this call needs.',
  InsufficientPremium: 'The pool holds less pending premium than this call needs.',
  InsufficientAllowance: 'Your allowance to the vault is too low for this permit deposit. Approve the amount first, then retry.',
  NotTreaty: 'Only the treaty contract can call this function.',
  EmptyExposure: 'The exposure array is empty. Provide an exposure figure for every market.',
  BadFeeds: "The pricer's feeds/scaling array doesn't match the exposure array's length.",
  BadTableId: 'A configured pricing table id is not 0-3. This is a deploy-time configuration error.',
  MissingTable: 'The pricer has no pricing table configured for one of the requested markets.',
  ERC20InsufficientAllowance: 'Allowance too low. Approve the amount first, then retry.',
  ERC20InsufficientBalance: 'Your balance of this asset is too low for this amount.',
  ERC4626ExceededMaxDeposit: 'This deposit exceeds the vault maximum.',
  ERC4626ExceededMaxMint: 'This mint exceeds the vault maximum.',
  ERC4626ExceededMaxRedeem: 'Only free capacity (assets minus locked) can be redeemed while layers are live.',
  ERC4626ExceededMaxWithdraw: 'Only free capacity (assets minus locked) can be withdrawn while layers are live.',
};
