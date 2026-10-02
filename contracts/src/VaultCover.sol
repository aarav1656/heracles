// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Treaty} from "./Treaty.sol";
import {OIGuard} from "./OIGuard.sol";

/// A perp venue's LP vault, wired to Heracles in one contract. The venue reports every change to
/// the vault's signed net exposure here: `open` asks the OIGuard first and records the change only
/// if the weekend cover premium of the resulting book stays within the owner's budget (or falls);
/// `close` moves a market toward zero and never consults the pricer, so closing is never blocked.
/// Once a week a keeper calls `renewCover`, which binds a Treaty layer on the vault's book as it
/// stands, paying the premium from this contract's balance up to a ceiling the owner set. Payouts
/// and refunds go to the owner, and anyone can trigger them.
/// The book is held in the OIGuard's market order; `coverIndex[i]` names the book market the
/// Treaty's market i covers, so a Treaty listing fewer markets covers those legs of the book.
contract VaultCover is Ownable {
    using SafeERC20 for IERC20;

    Treaty public immutable treaty;
    OIGuard public immutable guard;
    uint256 public immutable book;
    IERC20 public immutable asset;

    int256[] internal _net;
    uint256[] internal _coverIndex;
    mapping(address => bool) public isVenue;
    mapping(address => bool) public isKeeper;

    uint256 public retention;
    uint256 public limit;
    /// Most `renewCover` pays for one weekend's layer; passed to `Treaty.bind` as `maxPremium`.
    uint256 public maxPremium;
    /// `fridayCutoff` of the week the last layer was bound for: one layer per week.
    uint256 public lastCutoff;
    uint256[] internal _layers;

    error NotVenue();
    error NotKeeper();
    error NotReducing();
    error AlreadyCovered(uint256 fridayCutoff);
    error BadParams();

    event VenueSet(address venue, bool allowed);
    event KeeperSet(address keeper, bool allowed);
    event TermsSet(uint256 retention, uint256 limit, uint256 maxPremium);
    event Opened(uint256 indexed market, int256 delta, int256 net, uint256 premium);
    event Closed(uint256 indexed market, int256 delta, int256 net);
    event CoverBound(uint256 indexed id, uint256 fridayCutoff, int256[] exposure, uint256 premium);
    event CoverClaimed(uint256 indexed id, address to);

    modifier onlyVenue() {
        if (!isVenue[msg.sender]) revert NotVenue();
        _;
    }

    constructor(Treaty treaty_, OIGuard guard_, uint256 book_, uint256[] memory coverIndex_, address owner_) Ownable(owner_) {
        uint256 markets = guard_.feeds().length;
        if (book_ >= treaty_.booksCount() || coverIndex_.length != treaty_.marketsLength()) revert BadParams();
        for (uint256 i; i < coverIndex_.length; i++) {
            if (coverIndex_[i] >= markets) revert BadParams();
        }
        treaty = treaty_;
        guard = guard_;
        book = book_;
        asset = IERC20(treaty_.bookAsset(book_));
        _net = new int256[](markets);
        _coverIndex = coverIndex_;
    }

    function net() external view returns (int256[] memory) {
        return _net;
    }

    function coverIndex() external view returns (uint256[] memory) {
        return _coverIndex;
    }

    function layers() external view returns (uint256[] memory) {
        return _layers;
    }

    /// The exposure `renewCover` would bind right now, in the Treaty's market order.
    function coverExposure() public view returns (int256[] memory exposure) {
        exposure = new int256[](_coverIndex.length);
        for (uint256 i; i < exposure.length; i++) {
            exposure[i] = _net[_coverIndex[i]];
        }
    }

    function setVenue(address venue, bool allowed) external onlyOwner {
        isVenue[venue] = allowed;
        emit VenueSet(venue, allowed);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function setTerms(uint256 retention_, uint256 limit_, uint256 maxPremium_) external onlyOwner {
        if (limit_ == 0 || maxPremium_ == 0) revert BadParams();
        (retention, limit, maxPremium) = (retention_, limit_, maxPremium_);
        emit TermsSet(retention_, limit_, maxPremium_);
    }

    /// Records `delta` more net exposure on `market` if the OIGuard accepts it; reverts with the
    /// guard's `PremiumOverBudget(premium, budget, currentPremium)` otherwise.
    function open(uint256 market, int256 delta) external onlyVenue returns (uint256 premium) {
        premium = guard.check(_net, market, delta);
        int256 next = _net[market] + delta;
        _net[market] = next;
        emit Opened(market, delta, next, premium);
    }

    /// Moves `market` toward zero by `delta`, without crossing it.
    function close(uint256 market, int256 delta) external onlyVenue {
        int256 cur = _net[market];
        int256 next = cur + delta;
        if (cur >= 0 ? (next < 0 || next > cur) : (next > 0 || next < cur)) revert NotReducing();
        _net[market] = next;
        emit Closed(market, delta, next);
    }

    /// Binds this week's layer on the book as it stands. The Treaty enforces its own bind window,
    /// pricing and `maxPremium`; the approval covers exactly that ceiling and is cleared after.
    function renewCover() external returns (uint256 id) {
        if (!isKeeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        if (limit == 0) revert BadParams();
        (uint256 cutoff,) = treaty.weekWindow(block.timestamp);
        if (cutoff == lastCutoff) revert AlreadyCovered(cutoff);
        lastCutoff = cutoff;
        int256[] memory exposure = coverExposure();
        uint256 before = asset.balanceOf(address(this));
        asset.forceApprove(address(treaty), maxPremium);
        id = treaty.bind(book, exposure, retention, limit, maxPremium);
        asset.forceApprove(address(treaty), 0);
        _layers.push(id);
        emit CoverBound(id, cutoff, exposure, before - asset.balanceOf(address(this)));
    }

    /// Sends a settled layer's payout, or a cancelled layer's refund, to the owner.
    function claimCover(uint256 id) external {
        address to = owner();
        treaty.claimTo(id, to);
        emit CoverClaimed(id, to);
    }

    /// Returns premium funds held here to the owner.
    function withdraw(uint256 amount) external onlyOwner {
        asset.safeTransfer(owner(), amount);
    }
}
