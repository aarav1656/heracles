// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPricer} from "./IPricer.sol";
import {Capacity} from "./Capacity.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Weekend-gap excess-of-loss treaty. A vault (buyer) declares its Friday exposure per
/// market and binds a layer above `retention` up to `limit`; USDG writer capital in `Capacity`
/// backs the layer and is paid the premium the Stylus/Solidity `Pricer` quotes; Monday's fixing
/// pays the realized loss, capped at the layer's own locked limit, to the buyer.
///
/// Fixing rule, allowlist and several checks follow a proven pattern: constructor-fixed feed
/// allowlist with a `decimals() == 8` check ("writer picks the oracle"), the Chainlink
/// phase-boundary guard `_latestInPhase`, the `fix()` first-fresh-round rule
/// (`updatedAt >= expiry`, previous round `updatedAt < expiry`, both read via `getRoundData`),
/// and `setReference`'s "last round before Saturday 00:00 UTC, within 24h" rule (same
/// REF_WINDOW pattern). This treaty has no
/// corporate-action multiplier check because it binds raw Chainlink equity feeds directly, not
/// Robinhood-style Stock Tokens with a `uiMultiplier()`; there is no multiplier to read.
///
/// Timing (SECURITY-REVIEW.md C1+H1): the caller does not choose `fridayCutoff`/`expiry`. `bind`
/// only succeeds strictly before the current ISO week's Friday 19:30 UTC (computed on-chain from
/// `block.timestamp` with integer weekday math, `_weekWindow`); `expiry` is always exactly the
/// following Monday 13:30 UTC. The Friday reference price used for settlement is not the spot at
/// bind time either: it is fixed afterwards, per market, by `setReference` against the last round
/// before Saturday 00:00 UTC (within 24h). The premium
/// is still quoted at bind time (the Pricer's 504-scenario table has no price/date argument, so
/// "latest" and "reference" price the same premium either way); a floor (H2) guarantees it is
/// never zero.
///
/// Solvency: `Capacity.locked` reserves a layer's full `limit` at bind; on settle, `Capacity.settle`
/// moves the unused remainder back to free capacity and the realized `payout` into `Capacity.owed`
/// (kept reserved until claim), and `Capacity.payOut` reverts if a caller ever asks for more than
/// is owed. Together with the `payout <= limit` clamp below ("cap the payout at the
/// escrow"), one layer's settlement can never draw
/// capital reserved for another layer or for a writer's still-free capacity. `Capacity.totalAssets()`
/// counts active `locked` capital at face value and nets out only `owed` and `pendingPremium`
/// (the C1 fix); the gate (`Capacity.maxDeposit`/`maxMint`/`maxRedeem`) closes deposits and
/// withdrawals from a layer's own `fridayCutoff` until every layer sharing that cutoff has settled
/// or been cancelled (the re-review's H1 fix: keying the gate on aggregate `locked != 0` let a
/// rolling weekly bind, timed for a cutoff days away, hold it shut forever). `bind`/`cancel`/
/// `_settle` below pass each layer's own `L.fridayCutoff` into `capacity.lock`/`unlock`/`settle` so
/// Capacity can bucket locked capital by the cutoff that actually starts its risk window.
contract Treaty is ReentrancyGuard {
    enum State {
        None,
        Bound,
        Settled,
        Cancelled
    }

    struct Layer {
        address buyer;
        uint40 fridayCutoff;
        uint40 expiry;
        uint8 referencedCount;
        uint8 fixedCount;
        State state;
        bool buyerClaimed;
        uint256 retention;
        uint256 limit;
        uint256 premium;
        uint256 payout;
    }

    uint256 internal constant REF_WINDOW = 24 hours;
    // F1 (re-review of 96309c8, the security review): a layer's own cutoff to
    // the next weekly cutoff is 168h (7 days). A layer becomes cancellable at `expiry + GRACE`,
    // and `expiry` is cutoff + 66h (Friday 19:30 to Monday 13:30). For a stuck layer (dead feed,
    // never fixable) to be cancellable before the *next* week's cutoff closes the gate again,
    // 66h + GRACE must be < 168h, i.e. GRACE < 102h. At 7 days (168h) a stuck layer outlived the
    // next cutoff and froze writers indefinitely with one dust bind per week. 3 days (72h) is
    // comfortably under the 102h bound and leaves a 168h - 66h - 72h = 30h open window every week
    // even with a permanently dead feed; a cancel still refunds the buyer's premium in full
    // (`cancel` below calls `capacity.refundPremium`), so this only shortens the backstop, it does
    // not change who pays for an unfixable layer.
    uint256 internal constant GRACE = 3 days;
    uint256 internal constant SEQUENCER_GRACE = 1 hours;
    uint256 internal constant BPS = 1e4;
    // F2 (re-review of 96309c8): `_settle` multiplies `exposure[i] * gapBps` in checked int256.
    // The Pricer's own scenario table never produces |gapBps| above ~1474, so any exposure this
    // pricer would ever quote against is safe, but nothing stopped a caller from binding an
    // exposure so large that a real gap (not just the table's) panics the multiplication forever.
    // 1e30 is far above any real vault's exposure (USDG has 6 decimals; 1e30 base units is
    // 1e24 USDG) while leaving `1e30 * 1474` (~1.47e33) nowhere near int256's ~5.79e76 ceiling.
    uint256 internal constant MAX_EXPOSURE = 1e30;

    // Weekday math constants (SECURITY-REVIEW.md C1+H1). Epoch day 0 (1970-01-01) was a Thursday.
    // ISO weekday (Monday=0..Sunday=6) of epoch day `d` is `(d + 3) % 7` (day 0=Thu -> 3, day
    // 4=Mon -> 0; unit-tested in contracts/test/WeekWindow.t.sol across 3 weeks, a year boundary
    // and both weekend days).
    uint256 internal constant FRIDAY_CUTOFF_TOD = 19 hours + 30 minutes;
    uint256 internal constant SATURDAY_MIDNIGHT_OFFSET = 4 hours + 30 minutes; // Fri 19:30 -> Sat 00:00
    uint256 internal constant MONDAY_EXPIRY_TOD = 13 hours + 30 minutes;

    IERC20 public immutable usdg;
    IPricer public immutable pricer; // L3: fixed at deploy, no setter, no admin path to swap it
    Capacity public immutable capacity;
    uint256 public immutable minRateOnLineBps; // H2: premium floor, bps of limit
    address public immutable sequencerUptimeFeed; // M2: address(0) disables the check (testnet)
    AggregatorV3Interface[] public markets;

    mapping(uint256 => Layer) public layers;
    uint256 public layerCount;
    mapping(uint256 => int256[]) internal _exposure;
    mapping(uint256 => mapping(uint256 => uint64)) public fridayPrice;
    mapping(uint256 => mapping(uint256 => uint64)) public mondayPrice;
    mapping(uint256 => mapping(uint256 => bool)) public referenceSet;
    mapping(uint256 => mapping(uint256 => bool)) public marketFixed;

    event Bound(
        uint256 indexed id, address indexed buyer, uint256 retention, uint256 limit, uint256 premium, uint40 expiry
    );
    event ReferenceSet(uint256 indexed id, uint256 indexed marketIdx, uint80 roundId, uint64 price);
    event MarketFixed(uint256 indexed id, uint256 indexed marketIdx, uint80 roundId, int256 answer);
    event Settled(uint256 indexed id, uint256 payout);
    event Claimed(uint256 indexed id, address indexed buyer, address to, uint256 amount);
    event Cancelled(uint256 indexed id, uint256 premiumRefunded);

    error BadParams();
    error BadTiming();
    error BadRound();
    error NotFirstRound();
    error NotLastRound();
    error EarlyFix();
    error ReferenceNotSet();
    error WrongState();
    error AlreadyFixed();
    error NothingToClaim();
    error SequencerDown();

    constructor(
        address usdg_,
        address pricer_,
        address[] memory feeds,
        uint256 minRateOnLineBps_,
        address sequencerUptimeFeed_
    ) {
        if (usdg_ == address(0) || pricer_ == address(0) || feeds.length == 0) revert BadParams();
        usdg = IERC20(usdg_);
        pricer = IPricer(pricer_);
        minRateOnLineBps = minRateOnLineBps_;
        sequencerUptimeFeed = sequencerUptimeFeed_;
        for (uint256 i; i < feeds.length; i++) {
            if (feeds[i] == address(0)) revert BadParams();
            if (AggregatorV3Interface(feeds[i]).decimals() != 8) revert BadParams();
            markets.push(AggregatorV3Interface(feeds[i]));
        }
        capacity = new Capacity(IERC20(usdg_), address(this));
    }

    function marketsLength() external view returns (uint256) {
        return markets.length;
    }

    function exposureOf(uint256 id) external view returns (int256[] memory) {
        return _exposure[id];
    }

    /// The ISO week's Friday 19:30 UTC cutoff and the following Monday 13:30 UTC expiry
    /// containing `ts`, regardless of which day of that week `ts` falls on. `public pure` so
    /// contracts/test/WeekWindow.t.sol can unit-test the calendar math directly.
    function weekWindow(uint256 ts) public pure returns (uint256 fridayCutoff, uint256 expiry) {
        uint256 day = ts / 1 days;
        uint256 isoDow = (day + 3) % 7; // Monday=0 .. Sunday=6
        // Written as `day + 4 - isoDow`, not `day - isoDow + 4`: the latter underflows for small
        // `day` (e.g. day 0, the 1970-01-01 Thursday epoch anchor) before the `+4` can bring it
        // back positive, since Solidity evaluates left to right.
        uint256 fridayDay = day + 4 - isoDow;
        uint256 mondayDay = fridayDay + 3;
        fridayCutoff = fridayDay * 1 days + FRIDAY_CUTOFF_TOD;
        expiry = mondayDay * 1 days + MONDAY_EXPIRY_TOD;
    }

    /// Declares exposure per market and locks a layer for the current weekend. Only callable
    /// strictly before this week's Friday 19:30 UTC cutoff (SECURITY-REVIEW.md C1+H1); the caller
    /// cannot choose `fridayCutoff` or `expiry`. Quotes the premium from `pricer`, floors it at
    /// `minRateOnLineBps` of `limit` (H2, a zero quote can never bind), reserves `limit` out of
    /// `capacity`'s free capital, and pulls the premium straight into `capacity` (the buyer must
    /// approve `capacity`, not this contract). The Friday reference price is set later, per
    /// market, by `setReference`, not read here.
    function bind(int256[] calldata exposure, uint256 retention, uint256 limit)
        external
        nonReentrant
        returns (uint256 id)
    {
        uint256 n = markets.length;
        if (exposure.length != n) revert BadParams();
        if (limit == 0) revert BadParams();
        // F2: bound `retention` so `int256(L.retention)` in `_settle` can never wrap (a uint256
        // above int256.max reinterprets as negative under a plain cast), and bound each market's
        // exposure so `exposure[i] * gapBps` cannot overflow checked int256 there either.
        if (retention > uint256(type(int256).max)) revert BadParams();
        bool nonZero;
        for (uint256 i; i < n; i++) {
            int256 e = exposure[i];
            if (e > int256(MAX_EXPOSURE) || e < -int256(MAX_EXPOSURE)) revert BadParams();
            if (e != 0) {
                nonZero = true;
            }
        }
        if (!nonZero) revert BadParams();
        _requireSequencerUp();

        (uint256 cutoff, uint256 expiry) = weekWindow(block.timestamp);
        if (block.timestamp >= cutoff) revert BadTiming();

        (uint256 quoted,,) = pricer.quote(exposure, retention, limit);
        uint256 floor_ = limit * minRateOnLineBps / BPS;
        uint256 premium = quoted < floor_ ? floor_ : quoted;
        // L2 (the security review): the H2 floor itself rounds to zero for any
        // limit under 200 base units. Harmless alone, but the C1 epoch gate now closes every
        // writer's deposits and withdrawals while a layer is live, so a free bind becomes a
        // repeatable weekly griefing lock. A zero-premium layer can never bind.
        if (premium == 0) revert BadParams();

        id = layerCount++;
        Layer storage L = layers[id];
        L.buyer = msg.sender;
        L.fridayCutoff = uint40(cutoff);
        L.expiry = uint40(expiry);
        L.state = State.Bound;
        L.retention = retention;
        L.limit = limit;
        L.premium = premium;
        _exposure[id] = exposure;

        emit Bound(id, msg.sender, retention, limit, premium, uint40(expiry));

        capacity.lock(limit, uint40(cutoff));
        capacity.receivePremium(msg.sender, premium);
    }

    /// Sets one market's Friday reference: the last round before Saturday 00:00 UTC, updated no
    /// more than `REF_WINDOW` (24h) before it. Callable
    /// only after Saturday 00:00 UTC (so the whole Friday session has printed) and permissionless,
    /// same as `fix`.
    function setReference(uint256 id, uint256 marketIdx, uint80 roundId) external nonReentrant {
        Layer storage L = layers[id];
        if (L.state != State.Bound) revert WrongState();
        if (marketIdx >= markets.length) revert BadParams();
        if (referenceSet[id][marketIdx]) revert AlreadyFixed();

        uint256 refTime = uint256(L.fridayCutoff) + SATURDAY_MIDNIGHT_OFFSET;
        if (block.timestamp < refTime) revert BadTiming();
        _requireSequencerUp();

        AggregatorV3Interface feed = markets[marketIdx];
        uint80 latestId = _latestInPhase(feed, roundId);
        (, int256 answer,, uint256 updatedAt,) = feed.getRoundData(roundId);
        if (answer <= 0 || uint256(answer) > type(uint64).max) revert BadRound();
        if (updatedAt >= refTime || updatedAt + REF_WINDOW < refTime) revert BadRound();

        if (roundId != latestId) {
            (,,, uint256 nextUpdatedAt,) = feed.getRoundData(roundId + 1);
            if (nextUpdatedAt < refTime) revert NotLastRound();
        }

        uint64 price = uint64(uint256(answer));
        fridayPrice[id][marketIdx] = price;
        referenceSet[id][marketIdx] = true;
        L.referencedCount += 1;
        emit ReferenceSet(id, marketIdx, roundId, price);
    }

    /// Fixes one market's Monday price for a layer: the first round with `updatedAt >= expiry`
    /// (searched forward by whoever calls this), whose
    /// predecessor round is strictly before `expiry` (`NotFirstRound`).
    /// Requires every market's reference to already be set (`ReferenceNotSet`). Calling before
    /// `expiry` reverts `EarlyFix` regardless of what round is passed in: this is the treaty's
    /// deliberate-failure demo path.
    function fix(uint256 id, uint256 marketIdx, uint80 roundId) external nonReentrant {
        Layer storage L = layers[id];
        if (L.state != State.Bound) revert WrongState();
        if (marketIdx >= markets.length) revert BadParams();
        if (marketFixed[id][marketIdx]) revert AlreadyFixed();
        if (L.referencedCount != markets.length) revert ReferenceNotSet();
        if (block.timestamp < L.expiry) revert EarlyFix();
        _requireSequencerUp();

        AggregatorV3Interface feed = markets[marketIdx];
        _latestInPhase(feed, roundId);
        (, int256 answer,, uint256 updatedAt,) = feed.getRoundData(roundId);
        if (answer <= 0 || uint256(answer) > type(uint64).max) revert BadRound();
        if (updatedAt < L.expiry || updatedAt > block.timestamp) revert BadRound();
        (,,, uint256 prevUpdatedAt,) = feed.getRoundData(roundId - 1);
        if (prevUpdatedAt == 0 || prevUpdatedAt >= L.expiry) revert NotFirstRound();

        mondayPrice[id][marketIdx] = uint64(uint256(answer));
        marketFixed[id][marketIdx] = true;
        L.fixedCount += 1;
        emit MarketFixed(id, marketIdx, roundId, answer);

        if (L.fixedCount == markets.length) _settle(id);
    }

    /// If a market's feed never produces a fresh round within `GRACE` of expiry (including the
    /// M3 case: a Chainlink phase change makes every settling round unfixable), anyone can cancel
    /// the layer, freeing the writer capital it locked. Unlike the earlier build, the buyer's
    /// premium is refunded here rather than kept by writers for a layer that never resolved
    /// (SECURITY-REVIEW.md M3): writers only earn the premium for a layer that actually settles.
    function cancel(uint256 id) external nonReentrant {
        Layer storage L = layers[id];
        if (L.state != State.Bound) revert WrongState();
        if (block.timestamp < uint256(L.expiry) + GRACE) revert BadTiming();
        // Same sequencer gate as fix: cancel must not land in a window where fix is blocked.
        _requireSequencerUp();
        L.state = State.Cancelled;
        emit Cancelled(id, L.premium);
        capacity.unlock(L.limit, L.fridayCutoff);
        capacity.refundPremium(L.buyer, L.premium);
    }

    /// Pull claim for the buyer's realized payout, paid to the caller. `claimTo` lets the buyer
    /// redirect to another address (L4: a blocklisted buyer is not stuck forever); only the
    /// buyer who owns the claim can call either.
    function claim(uint256 id) external {
        claimTo(id, msg.sender);
    }

    function claimTo(uint256 id, address to) public nonReentrant {
        Layer storage L = layers[id];
        if (L.state != State.Settled) revert WrongState();
        if (L.buyerClaimed) revert NothingToClaim();
        if (msg.sender != L.buyer) revert NothingToClaim();
        if (L.payout == 0) revert NothingToClaim();
        if (to == address(0)) revert BadParams();

        L.buyerClaimed = true;
        emit Claimed(id, L.buyer, to, L.payout);
        capacity.payOut(to, L.payout);
    }

    function _settle(uint256 id) internal {
        Layer storage L = layers[id];
        uint256 n = markets.length;
        int256[] storage exposure = _exposure[id];

        int256 totalLoss;
        for (uint256 i; i < n; i++) {
            int256 friday = int256(uint256(fridayPrice[id][i]));
            int256 monday = int256(uint256(mondayPrice[id][i]));
            int256 gapBps = ((monday - friday) * 10000) / friday;
            int256 pnl = (exposure[i] * gapBps) / 10000;
            if (pnl < 0) totalLoss -= pnl;
        }

        int256 p = totalLoss - int256(L.retention);
        if (p < 0) p = 0;
        uint256 payout = uint256(p);
        // The attachment/limit clamp: a layer can never pay more than the capital locked for it.
        if (payout > L.limit) payout = L.limit;

        L.payout = payout;
        L.state = State.Settled;
        emit Settled(id, payout);

        // C1: moves this layer's reservation out of `locked` entirely. The unused remainder
        // becomes free capacity again; `payout` moves into `owed`, still excluded from
        // totalAssets() but earmarked for `payOut` (claim) instead of this layer's own hold.
        capacity.settle(L.limit - payout, payout, L.fridayCutoff);
        // M1: the premium was withheld from share pricing since bind (Capacity.pendingPremium);
        // now that this weekend's risk has actually played out, it vests to whoever holds shares.
        capacity.releasePremium(L.premium);
    }

    /// Chainlink proxy ids are phaseId << 64 | aggregatorRound; only the proxy's current phase is
    /// accepted, so roundId +/- 1 is always the neighbour on the same aggregator.
    function _latestInPhase(AggregatorV3Interface feed, uint80 roundId) private view returns (uint80 latestId) {
        (latestId,,,,) = feed.latestRoundData();
        if (roundId >> 64 != latestId >> 64 || uint64(roundId) == 0) revert BadRound();
    }

    /// SECURITY-REVIEW.md M2: reverts if the Arbitrum sequencer is down, or within the grace
    /// period after it came back, so a force-included call during downtime cannot use a price the
    /// market has left. `sequencerUptimeFeed == address(0)` disables the check (no such feed
    /// exists on Arbitrum Sepolia at chain id 421614 today; verified empty at that address there
    /// on 2026-09-26, and absent from Chainlink's own L2 feeds list, so testnet deploys pass
    /// address(0) and mainnet deploys must pass the real feed).
    function _requireSequencerUp() internal view {
        if (sequencerUptimeFeed == address(0)) return;
        (, int256 answer,, uint256 startedAt,) = AggregatorV3Interface(sequencerUptimeFeed).latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt < SEQUENCER_GRACE) revert SequencerDown();
    }
}
