// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared interface for the weekend-gap layer pricer, implemented once in Solidity
/// (`Pricer.sol`, reference + fallback) and once in Rust/Stylus (`pricer/src/lib.rs`), so
/// `Treaty` calls whichever is deployed through the same ABI. All amounts are USDG's native
/// 6-decimal fixed point: exposure/retention/limit/premium/el/tvar95 are all plain USDG units,
/// no WAD conversion. exposure[i] is signed: positive is long market i (loses when it falls),
/// negative is short (loses when it rises).
interface IPricer {
    /// @return premium mean(payout)*1.25 + 0.5*TVaR95(payout) over the 504 stored weekend
    /// scenarios, where payout(s) = min(limit, max(0, portfolioLoss(s) - retention)).
    /// @return el mean(payout) (expected loss of the layer).
    /// @return tvar95 mean of the worst 5% of payout(s) (25 of 504 scenarios).
    function quote(int256[] calldata exposure, uint256 retention, uint256 limit)
        external
        view
        returns (uint256 premium, uint256 el, uint256 tvar95);
}
