// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Writer capital pool for the treaty, USDG-denominated ERC-4626. Writers deposit USDG
/// and hold shares; `Treaty` (the sole `treaty` address, set once at construction, no owner, no
/// setter) locks `limit` out of free capacity on every bind and unlocks the unused remainder on
/// settle, and pays a layer's payout out of pooled assets on claim.
///
/// H3 (SECURITY-REVIEW.md), C1 (the security review): `totalAssets()` nets out
/// only `owed` (a settled-but-unclaimed payout, capital that is no longer the writers' to price)
/// and `pendingPremium`. Active `locked` capital is counted at face value: most of it comes back
/// on settle (`Treaty._settle` unlocks `limit - payout`), so marking it to zero let a deposit made
/// while a layer is live buy the pool at a near-zero share price and redeem the writers' capital
/// once the layer settled (C1: 2,000 USDG in, ~202,000 USDG out). Counting `locked` at face value
/// alone would let the same deposit dilute an existing writer's exposure to a not-yet-realized
/// loss (a still-live layer's payout is unknown), so deposits and withdrawals close while that
/// exposure is live. `maxDeposit`/`maxMint`/`maxRedeem` below implement the gate (`maxWithdraw`
/// is not overridden: OZ's ERC4626 already composes it as `previewRedeem(maxRedeem(owner))`).
///
/// H1 (re-review of b71cf94, the security review "Re-review of b71cf94"): gating
/// on `locked != 0` (any layer live, bind to settle) let a rolling weekly bind keep `locked`
/// nonzero forever, since `Treaty.bind` always locks against the current week's own cutoff, days
/// before that cutoff's risk actually starts. The gate now keys on the cutoff itself: `locked`
/// capital is bucketed by the cutoff of the layer(s) that reserved it (`lockedByCutoff`), and
/// deposits/withdrawals close only from a bucket's own cutoff (Friday 19:30 UTC) until it drains
/// (every layer with that cutoff settled or cancelled). A layer bound for a future weekend keeps
/// reserving capital in `locked`/`totalAssets()` the same as before, but does not close the gate
/// until its own cutoff arrives, so a rolling dust bind can freeze writers for at most one
/// unavoidable settlement window (cutoff to Monday's permissionless `fix`, ~66h) per week instead
/// of indefinitely. `cutoffs`/`cutoffCursor` find the earliest bucket that might still be nonzero
/// without walking every layer; correctness relies on `Treaty.bind` only ever locking against a
/// non-decreasing cutoff over time (`weekWindow(block.timestamp)`, `block.timestamp` non-decreasing
/// across calls, and bind reverts once `block.timestamp >= cutoff`), so `cutoffs` is append-only
/// and sorted for free.
///
/// Fairness for a Monday-Thursday depositor joining while next weekend's layer is already bound:
/// `totalAssets()` already counts that layer's `locked` capital at face value, the same
/// conservative mark every existing holder is priced against, so the new depositor buys in at the
/// same worst-case mark and shares pro rata in the eventual unused-capacity release. They cannot
/// JIT around settle: withdrawals stay capped at `totalAssets() - locked` at all times regardless
/// of gate state (so reserved capital is never reachable early), and once that layer's own cutoff
/// arrives the gate closes outright until it settles, closing the exit path a JIT depositor would
/// need.
///
/// M1 / F3 (re-review of 96309c8, the security review): a bind's premium is
/// pulled in immediately but held in `pendingPremium`, excluded from both entry and exit pricing
/// until the layer's risk actually plays out. The comment above used to also claim "no dilution
/// either way" for a deposit arriving between bind and cutoff; that was wrong; excluding
/// `pendingPremium` from *entry* pricing let a deposit that contributed no capacity to the
/// already-bound layer buy in at a price that ignored premium the incumbent writers alone had
/// underwritten all week, then take a pro-rata cut of it at settle. `previewDeposit`/`previewMint`
/// below price entry against `totalAssets() + pendingPremium` instead (the entrant pays for the
/// premium already earned by the capital they are about to share risk with); `previewWithdraw`/
/// `previewRedeem` keep excluding it, so an exiting writer is never priced above what the pool can
/// actually pay before the premium vests, and a cancelled layer's refunded premium falls to
/// whoever is still a writer (the entrant paid for premium the layer never actually earned).
contract Capacity is ERC4626 {
    using SafeERC20 for IERC20;

    address public immutable treaty;
    uint256 public locked; // active layers only, counted at face value (C1)
    uint256 public owed; // settled, unclaimed payouts; excluded from totalAssets()
    uint256 public pendingPremium;

    // H1: locked capital bucketed by the cutoff of the layer(s) that reserved it. `cutoffs` is
    // append-only and non-decreasing (see contract docstring), so the earliest bucket that might
    // still be nonzero is found by walking `cutoffCursor` forward past drained buckets; each index
    // is visited at most once across the contract's lifetime.
    mapping(uint40 => uint256) public lockedByCutoff;
    uint40[] public cutoffs;
    uint256 public cutoffCursor;

    error NotTreaty();
    error CapacityExceeded();
    error InsufficientLocked();
    error InsufficientPremium();
    error InsufficientAllowance();

    modifier onlyTreaty() {
        if (msg.sender != treaty) revert NotTreaty();
        _;
    }

    constructor(IERC20 usdg_, address treaty_)
        ERC20("Heracles Capacity", "gtUSDG")
        ERC4626(usdg_)
    {
        treaty = treaty_;
    }

    /// Assets backing shares: raw balance minus a settled-but-unclaimed payout (`owed`, no longer
    /// the writers' to price) and minus premium not yet vested to writers (M1). Active `locked`
    /// capital is counted at face value (C1); the epoch gate below is what keeps that safe.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - owed - pendingPremium;
    }

    /// F3 (re-review of 96309c8, the security review): entry basis for
    /// `previewDeposit`/`previewMint`/`convertToShares` below. Includes `pendingPremium` (unlike
    /// `totalAssets()`) so a deposit landing between a bind and its own cutoff buys in at a price
    /// that already reflects the premium the currently locked layer(s) earned from incumbent
    /// writers, instead of buying at a discount and taking a pro-rata cut of premium at settle
    /// that only existing writers underwrote. Exit pricing (`previewWithdraw`/`previewRedeem`, and
    /// the base `_convertToShares`/`_convertToAssets` they still share) is untouched: it keeps
    /// pricing against `totalAssets()` alone, the more conservative mark for a writer leaving the
    /// pool (M1 unchanged: premium never reaches an exiting holder before it vests at settle).
    function _entryAssets() internal view returns (uint256) {
        return totalAssets() + pendingPremium;
    }

    /// Mirrors `previewDeposit`'s entry basis: a caller pricing a hypothetical deposit should see
    /// the price a real deposit would actually pay, not the exit-side rate `convertToAssets`
    /// (unchanged, exit basis) reports for the reverse direction.
    function convertToShares(uint256 assets) public view override returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 1, _entryAssets() + 1, Math.Rounding.Floor);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 1, _entryAssets() + 1, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return Math.mulDiv(shares, _entryAssets() + 1, totalSupply() + 1, Math.Rounding.Ceil);
    }

    /// H1: true once the earliest still-reserved cutoff bucket has actually arrived. False for a
    /// layer bound for a future weekend whose own cutoff has not happened yet, even though it
    /// already holds `locked` capital.
    function gateActive() public view returns (bool) {
        return cutoffCursor < cutoffs.length && block.timestamp >= cutoffs[cutoffCursor];
    }

    function maxDeposit(address) public view override returns (uint256) {
        return gateActive() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return gateActive() ? 0 : type(uint256).max;
    }

    /// Outside the gate window a withdrawal is capped at free capacity (`totalAssets() - locked`)
    /// regardless of gate state, so it can never touch capital reserved for a layer whether or not
    /// that layer's own cutoff has arrived yet (closes the H1/M1 JIT-around-settle path). Only
    /// `maxRedeem` needs overriding: OZ's ERC4626 already defines `maxWithdraw(owner)` as
    /// `previewRedeem(maxRedeem(owner))`.
    function maxRedeem(address owner) public view override returns (uint256) {
        if (gateActive()) return 0;
        uint256 free = totalAssets() - locked;
        uint256 freeShares = _convertToShares(free, Math.Rounding.Floor);
        uint256 ownerShares = balanceOf(owner);
        return ownerShares < freeShares ? ownerShares : freeShares;
    }

    /// Deposits funded by an EIP-2612 permit signature, one transaction, no prior approve. Always
    /// attempts the permit first: if it was already consumed (front-run by an observer relaying
    /// it first), this falls through instead of reverting as long as the allowance it would have
    /// granted is already sufficient.
    ///
    /// L1 (the security review): the same spender is also approved for bind
    /// premiums (`Treaty.sol:220`, `receivePremium` below), so a writer who also buys keeps a
    /// standing allowance to Capacity; a redundant permit call resets that allowance down to
    /// exactly `assets`. L1r (re-review of b71cf94): the contract-side "fix" for L1 (skip the
    /// permit call outright when the standing allowance already covers `assets`) left the signed
    /// permit unconsumed, so a third party could still relay it later and cut the writer's
    /// standing allowance down to `assets` at a time of the third party's choosing. Reverted to
    /// always trying the permit: a valid signature is now consumed inside this same call, leaving
    /// nothing live to replay. The UX cost (overwriting a standing allowance) is avoided instead at
    /// the caller: the web app only asks for a permit signature when the standing allowance does
    /// not already cover `assets`, calling plain `deposit` otherwise.
    function depositWithPermit(uint256 assets, address receiver, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 shares)
    {
        try IERC20Permit(asset()).permit(msg.sender, address(this), assets, deadline, v, r, s) {}
        catch {
            if (IERC20(asset()).allowance(msg.sender, address(this)) < assets) revert InsufficientAllowance();
        }
        shares = deposit(assets, receiver);
    }

    /// Reserves `amount` of free capacity for a new layer, bucketed under its `cutoff` (H1).
    /// Called once per bind. `totalAssets()` counts already-`locked` capital at face value (C1),
    /// so the free amount available to lock is `totalAssets() - locked`, not `totalAssets()` alone.
    ///
    /// F4 (re-review of 96309c8, latent/info): pushes a new `cutoffs` entry not only when this
    /// `cutoff` differs from the last one, but also when the cursor has already walked past every
    /// existing entry (`cutoffCursor == cutoffs.length`, every bucket fully drained). Without the
    /// second condition, refilling a cutoff whose bucket had already drained back to zero would
    /// re-add capital under an index the cursor had already passed, and `gateActive()` would never
    /// see it. Unreachable through `Treaty` today (a bucket can only drain after its own cutoff has
    /// passed, and `bind` never locks against a cutoff that has already passed), so this is a guard
    /// for any future caller of `lock` that can release a layer before its own cutoff.
    function lock(uint256 amount, uint40 cutoff) external onlyTreaty {
        if (amount > totalAssets() - locked) revert CapacityExceeded();
        locked += amount;
        if (cutoffs.length == 0 || cutoffCursor == cutoffs.length || cutoffs[cutoffs.length - 1] != cutoff) {
            cutoffs.push(cutoff);
        }
        lockedByCutoff[cutoff] += amount;
    }

    /// Releases `amount` back to free capacity (a cancelled layer's full limit) from its `cutoff`
    /// bucket. Never lets `locked` underflow past what was actually reserved.
    function unlock(uint256 amount, uint40 cutoff) external onlyTreaty {
        if (amount > locked) revert InsufficientLocked();
        locked -= amount;
        lockedByCutoff[cutoff] -= amount;
        _advanceCursor();
    }

    /// Moves a layer out of `locked` (and its `cutoff` bucket) on settle: `unused` becomes free
    /// capacity again, `payout` moves into `owed` (still excluded from `totalAssets()`, now
    /// earmarked for `payOut` instead of the layer's own reservation). Called once per settle,
    /// from `Treaty._settle`.
    function settle(uint256 unused, uint256 payout, uint40 cutoff) external onlyTreaty {
        uint256 amount = unused + payout;
        if (amount > locked) revert InsufficientLocked();
        locked -= amount;
        owed += payout;
        lockedByCutoff[cutoff] -= amount;
        _advanceCursor();
    }

    /// Walks `cutoffCursor` past every bucket that has fully drained. Out-of-order resolution
    /// (a later layer settling before an earlier one) is safe: the loop stops at the first bucket
    /// still holding capital, whichever cutoff that is, so the gate stays keyed on the true
    /// earliest outstanding cutoff.
    function _advanceCursor() internal {
        uint256 n = cutoffs.length;
        uint256 i = cutoffCursor;
        while (i < n && lockedByCutoff[cutoffs[i]] == 0) {
            i++;
        }
        cutoffCursor = i;
    }

    /// Pulls the bind premium into the pool but keeps it out of share pricing until the layer's
    /// risk actually plays out (M1).
    function receivePremium(address from, uint256 amount) external onlyTreaty {
        if (amount == 0) return;
        IERC20(asset()).safeTransferFrom(from, address(this), amount);
        pendingPremium += amount;
    }

    /// Vests a settled layer's premium to writers: it stops being excluded from `totalAssets()`.
    function releasePremium(uint256 amount) external onlyTreaty {
        if (amount > pendingPremium) revert InsufficientPremium();
        pendingPremium -= amount;
    }

    /// Returns a cancelled layer's premium to the buyer; it leaves the pool, so writers never see
    /// it (M3: cancel refunds the buyer, it does not pay writers for a layer that never settled).
    function refundPremium(address to, uint256 amount) external onlyTreaty {
        if (amount == 0) return;
        if (amount > pendingPremium) revert InsufficientPremium();
        pendingPremium -= amount;
        IERC20(asset()).safeTransfer(to, amount);
    }

    /// Pays a layer's realized loss out of pooled assets, pull-based from `Treaty.claimTo`.
    /// `Treaty._settle` moves `payout` from `locked` into `owed` (`settle` above), so the amount
    /// paid here is still reserved right up to this call; the `amount > owed` check is a second,
    /// pool-level guard (independent of Treaty's own bookkeeping) against ever paying out capital
    /// another layer or a writer's free capacity is relying on, the same escrow-cap discipline
    /// applied per series.
    function payOut(address to, uint256 amount) external onlyTreaty {
        if (amount == 0) return;
        if (amount > owed) revert InsufficientLocked();
        owed -= amount;
        IERC20(asset()).safeTransfer(to, amount);
    }
}
