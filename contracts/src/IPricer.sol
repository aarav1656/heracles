// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared interface for the weekend-gap layer pricer, implemented once in Solidity
/// (`Pricer.sol`, reference + fallback) and once in Rust/Stylus (`pricer/src/lib.rs`), so
/// `Treaty` calls whichever is deployed through the same ABI. All amounts are USDG's native
/// 6-decimal fixed point: exposure/retention/limit/premium/el/tvar95 are all plain USDG units,
/// no WAD conversion. exposure[i] is signed: positive is long market i (loses when it falls),
/// negative is short (loses when it rises).
interface IPricer {
    /// @param feeds Chainlink AggregatorV3-shaped feed address per exposure index, same order as
    /// `exposure`, used only to read each market's own recent rounds for the realised-volatility
    /// scale applied to its scenario table (docs/pricing.md). Reverts if `feeds.length !=
    /// exposure.length`.
    /// @return premium el + RISK_LOAD_PPM*(tvar95 - el) + CAPITAL_CHARGE_ANNUAL_PPM*limit*
    /// LOCK_DAYS/DAYS_PER_YEAR: a per-weekend tail-risk load plus the risk-free rate on the
    /// fully collateralised limit for the real capital-lock duration (docs/pricing.md).
    /// @return el mean(payout) (expected loss of the layer) over the 504 stored, per-market,
    /// volatility-scaled weekend scenarios, where payout(s) = min(limit, max(0, portfolioLoss(s)
    /// - retention)).
    /// @return tvar95 mean of the worst 5% of payout(s) (25 of 504 scenarios).
    function quote(int256[] calldata exposure, address[] calldata feeds, uint256 retention, uint256 limit)
        external
        view
        returns (uint256 premium, uint256 el, uint256 tvar95);
}
