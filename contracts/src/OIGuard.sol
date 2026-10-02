// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPricer} from "./IPricer.sol";

/// Open-interest guard for a perp venue's LP vault. Before the venue accepts a new position it
/// calls `check(book, market, size)` with the vault's current signed net exposure per market (the
/// vault is the counterparty, so it carries the opposite of trader OI) and the change the position
/// would make to it. The guard prices weekend-gap cover on the resulting book with the same
/// pricer the Treaty binds on, and refuses when that premium exceeds the budget the vault owner
/// set. A trade that lowers the premium is always accepted, so a vault already over budget (after a
/// volatility jump or a budget cut) can still be hedged back down.
/// Amounts are the pricer's 6-decimal units throughout.
contract OIGuard is Ownable {
    IPricer public immutable pricer;
    /// Retention and limit of the weekend layer the budget is measured against.
    uint256 public retention;
    uint256 public limit;
    /// Most the vault will pay for one weekend's cover on its whole book.
    uint256 public premiumBudget;
    address[] internal _feeds;

    error BadParams();
    /// `premium` for the book after the trade is above `budget` and above `currentPremium`, the
    /// premium for the book before it.
    error PremiumOverBudget(uint256 premium, uint256 budget, uint256 currentPremium);

    event TermsSet(uint256 retention, uint256 limit, uint256 premiumBudget);

    /// @param feeds_ feed per market in the pricer's market order; its length is the book length.
    constructor(IPricer pricer_, address[] memory feeds_, address owner_, uint256 retention_, uint256 limit_, uint256 budget_)
        Ownable(owner_)
    {
        if (address(pricer_) == address(0) || feeds_.length == 0) revert BadParams();
        pricer = pricer_;
        _feeds = feeds_;
        _setTerms(retention_, limit_, budget_);
    }

    function feeds() external view returns (address[] memory) {
        return _feeds;
    }

    function setTerms(uint256 retention_, uint256 limit_, uint256 budget_) external onlyOwner {
        _setTerms(retention_, limit_, budget_);
    }

    /// Premium for `book` with `size` added to `market`, and whether `check` would accept it.
    function preview(int256[] calldata book, uint256 market, int256 size) external view returns (uint256 premium, bool allowed) {
        (premium,, allowed) = _evaluate(book, market, size);
    }

    /// Reverts `PremiumOverBudget` when the trade would push the cover premium over budget.
    function check(int256[] calldata book, uint256 market, int256 size) external view returns (uint256 premium) {
        uint256 current;
        bool allowed;
        (premium, current, allowed) = _evaluate(book, market, size);
        if (!allowed) revert PremiumOverBudget(premium, premiumBudget, current);
    }

    /// `current` is only priced when `premium` is over budget; it is 0 otherwise.
    function _evaluate(int256[] calldata book, uint256 market, int256 size)
        internal
        view
        returns (uint256 premium, uint256 current, bool allowed)
    {
        if (book.length != _feeds.length || market >= book.length) revert BadParams();
        int256[] memory next = book;
        next[market] += size;
        (premium,,) = pricer.quote(next, _feeds, retention, limit);
        if (premium <= premiumBudget) return (premium, 0, true);
        (current,,) = pricer.quote(book, _feeds, retention, limit);
        allowed = premium <= current;
    }

    function _setTerms(uint256 retention_, uint256 limit_, uint256 budget_) internal {
        if (limit_ == 0) revert BadParams();
        (retention, limit, premiumBudget) = (retention_, limit_, budget_);
        emit TermsSet(retention_, limit_, budget_);
    }
}
