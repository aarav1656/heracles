// Treaty-domain constants and plain-word error glosses. No invented numbers.
import { fmtClock } from './format';

export const LAYER_STATES = ['None', 'Bound', 'Settled', 'Cancelled'] as const;

/** Monday 13:30 UTC fixing, derived from the layer expiry the chain reports. */
export function fixingWords(expiry: bigint): string {
  return `Fixing opens after ${fmtClock(expiry)} UTC and waits for the first SPY round at or after that time.`;
}

export const ERROR_WORDS: Record<string, string> = {
  BadParams: 'A parameter fails the contract checks: exposure length must match the market count, every exposure and the limit must be above zero in the right places, or the recipient is the zero address.',
  BadTiming: 'Too early or too late for this call on the layer clock. Binding needs now strictly before the Friday 19:30 UTC cutoff; setReference needs Saturday 00:00 UTC or later; cancel needs expiry plus 7 days.',
  BadRound: 'That feed round is not acceptable: stale, non-positive, out of the 64-bit price range, outside the 24h reference window, or from a superseded Chainlink phase.',
  NotFirstRound: 'That round is not the first round at or after expiry. Step one round back and retry.',
  NotLastRound: 'That round is not the last round before Saturday 00:00 UTC. Step one round forward and retry.',
  EarlyFix: 'Fixing is not open yet. The layer can only be fixed after Monday 13:30 UTC expiry.',
  ReferenceNotSet: 'Every market needs its Friday reference set before any market can be fixed.',
  ReferenceSet: 'This market already has its Friday reference.',
  WrongState: 'The layer is not in the state this call needs.',
  AlreadyFixed: 'This market is already fixed for this layer.',
  NothingToClaim: 'Nothing is claimable here: wrong caller, already claimed, or a zero payout.',
  SequencerDown: 'The Arbitrum sequencer is down or still inside the one-hour restart grace period.',
  CapacityExceeded: 'The limit is larger than the free writer capacity. Lower the limit or wait for more deposits.',
  InsufficientLocked: 'The pool has less locked capital than this call needs.',
  InsufficientPremium: 'The pool holds less pending premium than this call needs.',
  NotTreaty: 'Only the treaty contract can call this function.',
  ERC20InsufficientAllowance: 'Allowance too low. Approve the amount first, then retry.',
  ERC20InsufficientBalance: 'USDG balance too low for this amount.',
  ERC4626ExceededMaxDeposit: 'This deposit exceeds the vault maximum.',
  ERC4626ExceededMaxMint: 'This mint exceeds the vault maximum.',
  ERC4626ExceededMaxRedeem: 'Only free capacity (assets minus locked) can be redeemed while layers are live.',
  ERC4626ExceededMaxWithdraw: 'Only free capacity (assets minus locked) can be withdrawn while layers are live.',
};
