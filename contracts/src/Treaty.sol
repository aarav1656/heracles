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
/// phase-boundary guard `_latestInPhase`, and matching first-fresh-round rules for both ends of
/// the weekend: `fix()` takes the first round with `updatedAt >= expiry` (Monday's open, DST-aware,
/// previous round strictly before `expiry`), and `setReference` takes the first round with
/// `updatedAt >= fridayCloseOf(fridayCutoff)` (Friday's official close, also DST-aware, previous
/// round strictly before that close) -- see `_isUsDst`/`fridayCloseOf` (Item 6 / judging doc B.2).
/// This treaty has no corporate-action multiplier check because it binds raw Chainlink equity
/// feeds directly, not Robinhood-style Stock Tokens with a `uiMultiplier()`; there is no
/// multiplier to read.
///
/// Timing (SECURITY-REVIEW.md C1+H1): the caller does not choose `fridayCutoff`/`expiry`. `bind`
/// only succeeds strictly before the current ISO week's Friday 19:30 UTC (computed on-chain from
/// `block.timestamp` with integer weekday math, `weekWindow`); `expiry` is the following Monday
/// 9:30am ET, expressed in UTC via `_isUsDst` (13:30 UTC under DST, 14:30 UTC under standard
/// time). The bind cutoff itself stays fixed at 19:30 UTC year-round: that is strictly earlier
/// than Friday's close under either DST regime (20:00 UTC EDT, 21:00 UTC EST), so a bind can never
/// land after the reference has already printed. The Friday reference price used for settlement is
/// not the spot at bind time either: it is fixed afterwards, per market, by `setReference` against
/// the first round at or after Friday's official close. The premium
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
    //
    // Item 6 / judging doc B.2: NYSE's Friday close and Monday open are fixed in *US Eastern*
    // clock time (4:00pm / 9:30am ET), not fixed UTC offsets; UTC drifts by an hour twice a year
    // as the US switches DST. `FRIDAY_CUTOFF_TOD` (the bind deadline) is left DST-independent on
    // purpose: 19:30 UTC is strictly earlier than the close under either regime (20:00 UTC EDT,
    // 21:00 UTC EST), so a bind can never straddle the reference print regardless of which side of
    // the March/November switch the week falls on. `MONDAY_EXPIRY_TOD_*` and `fridayCloseOf` below
    // are the two instants that do move with DST.
    uint256 internal constant FRIDAY_CUTOFF_TOD = 19 hours + 30 minutes;
    uint256 internal constant MONDAY_EXPIRY_TOD_EDT = 13 hours + 30 minutes; // 9:30am ET, UTC-4
    uint256 internal constant MONDAY_EXPIRY_TOD_EST = 14 hours + 30 minutes; // 9:30am ET, UTC-5
    uint256 internal constant FRIDAY_CLOSE_TOD_EDT = 20 hours; // 4:00pm ET, UTC-4
    uint256 internal constant FRIDAY_CLOSE_TOD_EST = 21 hours; // 4:00pm ET, UTC-5

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
    error EarlyFix();
    error ReferenceNotSet();
    error WrongState();
    error AlreadyFixed();
    error NothingToClaim();
    error SequencerDown();
    // Item 6: cancel is a backstop for a genuinely stale/dead feed, not a way to skip a layer that
    // could still be fixed right now.
    error StillFixable();

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

    /// The ISO week's Friday 19:30 UTC cutoff and the following Monday 9:30am-ET expiry (13:30 UTC
    /// under DST, 14:30 UTC under standard time) containing `ts`, regardless of which day of that
    /// week `ts` falls on. `public pure` so contracts/test/WeekWindow.t.sol and
    /// contracts/test/ReferenceRule.t.sol can unit-test the calendar math directly.
    function weekWindow(uint256 ts) public pure returns (uint256 fridayCutoff, uint256 expiry) {
        uint256 day = ts / 1 days;
        uint256 isoDow = (day + 3) % 7; // Monday=0 .. Sunday=6
        // Written as `day + 4 - isoDow`, not `day - isoDow + 4`: the latter underflows for small
        // `day` (e.g. day 0, the 1970-01-01 Thursday epoch anchor) before the `+4` can bring it
        // back positive, since Solidity evaluates left to right.
        uint256 fridayDay = day + 4 - isoDow;
        uint256 mondayDay = fridayDay + 3;
        fridayCutoff = fridayDay * 1 days + FRIDAY_CUTOFF_TOD;
        // DST status is evaluated at the Monday itself, not the Friday: the US DST transition
        // always lands on a Sunday, which sits inside this weekend window between the two, so the
        // rare week that straddles the March/November switch has Friday in one regime and Monday
        // in the other. `fridayCloseOf` below makes the matching choice for Friday's own instant.
        uint256 mondayTs = mondayDay * 1 days;
        expiry = mondayTs + (_isUsDst(mondayTs) ? MONDAY_EXPIRY_TOD_EDT : MONDAY_EXPIRY_TOD_EST);
    }

    /// Friday's official US market-close instant (4:00pm ET) for the week containing
    /// `fridayCutoff` (any timestamp that same UTC day works; DST never changes mid-day). Item 6 /
    /// judging doc B.2: this, not "the last round before Saturday 00:00 UTC", is what
    /// `setReference` now waits for.
    function fridayCloseOf(uint256 fridayCutoff) public pure returns (uint256 closeTs) {
        uint256 fridayDay = fridayCutoff / 1 days;
        uint256 fridayMidnight = fridayDay * 1 days;
        closeTs = fridayMidnight + (_isUsDst(fridayMidnight) ? FRIDAY_CLOSE_TOD_EDT : FRIDAY_CLOSE_TOD_EST);
    }

    /// US DST is in effect from 07:00 UTC on the 2nd Sunday of March (clocks spring forward to
    /// 3am EDT) through 06:00 UTC on the 1st Sunday of November (clocks fall back to 1am EST),
    /// under the rule in effect continuously since the Energy Policy Act of 2005. Pure function of
    /// `ts`'s calendar date; unit-tested across both switch weeks in
    /// contracts/test/WeekWindow.t.sol, and against fixed EDT/EST dates directly (via
    /// `fridayCloseOf`) in contracts/test/ReferenceRule.t.sol.
    function _isUsDst(uint256 ts) internal pure returns (bool) {
        uint256 day = ts / 1 days;
        (uint256 year,,) = _civilFromDays(day);
        uint256 startTs = _nthSundayOfMonth(year, 3, 2) * 1 days + 7 hours;
        uint256 endTs = _nthSundayOfMonth(year, 11, 1) * 1 days + 6 hours;
        return ts >= startTs && ts < endTs;
    }

    /// Epoch day number of the `n`th Sunday of `month`/`year` (`n=1` is the first).
    function _nthSundayOfMonth(uint256 year, uint256 month, uint256 n) internal pure returns (uint256 day) {
        uint256 firstDay = _daysFromCivil(year, month, 1);
        uint256 firstDow = (firstDay + 3) % 7; // Monday=0 .. Sunday=6, same convention as weekWindow
        uint256 toFirstSunday = (6 + 7 - firstDow) % 7;
        day = firstDay + toFirstSunday + (n - 1) * 7;
    }

    /// Civil (year, month, day) from an epoch day count. Howard Hinnant's `civil_from_days`
    /// algorithm (public-domain, http://howardhinnant.github.io/date_algorithms.html), valid over
    /// the full proleptic Gregorian calendar; only `year` is used by `_isUsDst` above.
    function _civilFromDays(uint256 z_) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 z = int256(z_) + 719468;
        int256 era = (z >= 0 ? z : z - 146096) / 146097;
        uint256 doe = uint256(z - era * 146097); // [0, 146096]
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
        int256 y = int256(yoe) + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
        uint256 mp = (5 * doy + 2) / 153; // [0, 11]
        day = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
        month = mp < 10 ? mp + 3 : mp - 9; // [1, 12]
        year = uint256(month <= 2 ? y + 1 : y);
    }

    /// Inverse of `_civilFromDays`: epoch day count of a given civil (year, month, day), valid for
    /// `year >= 1970` (the only range this contract ever needs).
    function _daysFromCivil(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        int256 y = int256(year) - (month <= 2 ? int256(1) : int256(0));
        int256 era = (y >= 0 ? y : y - 399) / 400;
        uint256 yoe = uint256(y - era * 400); // [0, 399]
        uint256 doy = (153 * (month + (month > 2 ? 0 : 12) - 3) + 2) / 5 + day - 1; // [0, 365]
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
        return uint256(era * 146097 + int256(doe) - 719468);
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

        address[] memory feedAddrs = new address[](n);
        for (uint256 i; i < n; i++) {
            feedAddrs[i] = address(markets[i]);
        }
        (uint256 quoted,,) = pricer.quote(exposure, feedAddrs, retention, limit);
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

    /// Sets one market's Friday reference: the first round with `updatedAt >= fridayCloseOf`
    /// (Friday's official US market close, 4:00pm ET, DST-aware), whose predecessor round is
    /// strictly before that close (`NotFirstRound`) -- the same "first fresh round" shape as
    /// `fix`'s Monday rule below, just anchored to Friday's close instead of Monday's open. Item 6
    /// / judging doc B.2: replaces the earlier "last round before Saturday 00:00 UTC" rule, which
    /// both used a fixed UTC offset (wrong under DST) and picked the wrong instant (the research
    /// this repo cites, contracts/../evidence/auction-and-pricing.md, is about the *official
    /// close*, not an arbitrary midnight boundary). Callable only once that Friday's close has
    /// passed, and permissionless, same as `fix`.
    function setReference(uint256 id, uint256 marketIdx, uint80 roundId) external nonReentrant {
        Layer storage L = layers[id];
        if (L.state != State.Bound) revert WrongState();
        if (marketIdx >= markets.length) revert BadParams();
        if (referenceSet[id][marketIdx]) revert AlreadyFixed();

        uint256 refTime = fridayCloseOf(uint256(L.fridayCutoff));
        if (block.timestamp < refTime) revert BadTiming();
        _requireSequencerUp();

        AggregatorV3Interface feed = markets[marketIdx];
        _latestInPhase(feed, roundId);
        (, int256 answer,, uint256 updatedAt,) = feed.getRoundData(roundId);
        if (answer <= 0 || uint256(answer) > type(uint64).max) revert BadRound();
        if (updatedAt < refTime || updatedAt > block.timestamp) revert BadRound();
        (,,, uint256 prevUpdatedAt,) = feed.getRoundData(roundId - 1);
        if (prevUpdatedAt == 0 || prevUpdatedAt >= refTime) revert NotFirstRound();

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
    ///
    /// Item 6: cancel is a backstop for a genuinely dead layer, not a shortcut around a layer that
    /// could still be fixed. `_anyMarketFixable` below reverts `StillFixable` if any unfixed
    /// market already has a Monday round sitting there waiting to be consumed by `fix` -- at that
    /// point the correct call is `fix`, not `cancel`.
    function cancel(uint256 id) external nonReentrant {
        Layer storage L = layers[id];
        if (L.state != State.Bound) revert WrongState();
        if (block.timestamp < uint256(L.expiry) + GRACE) revert BadTiming();
        // Same sequencer gate as fix: cancel must not land in a window where fix is blocked.
        _requireSequencerUp();
        if (_anyMarketFixable(id)) revert StillFixable();
        L.state = State.Cancelled;
        emit Cancelled(id, L.premium);
        capacity.unlock(L.limit, L.fridayCutoff);
        capacity.refundPremium(L.buyer, L.premium);
    }

    /// True if some not-yet-fixed market on this layer already has a Monday round `fix` could
    /// consume right now. A market whose Friday reference was never set is treated as dead, not
    /// fixable: `setReference` is permissionless, so if that feed were alive any
    /// economically-interested party (the buyer, who wants a chance at a payout, or a writer, who
    /// wants the premium to vest) could have called it by `expiry + GRACE`; its absence is itself
    /// the evidence the feed is stale, not a reason to keep the layer open indefinitely.
    ///
    /// Mirrors `fix`'s full acceptance test, not just "a round with `updatedAt >= expiry`
    /// exists": the feed's current latest round can sit in a phase whose own predecessor round
    /// (phase, roundId - 1) was never published (a Chainlink phase change right after expiry, the
    /// M3 scenario), in which case `fix` itself would revert `NotFirstRound`/`BadRound` on that
    /// exact round forever. Without checking the predecessor here too, a layer stuck in that
    /// state could never be fixed AND never be cancelled -- capital locked with no exit. `try`
    /// because round 0 in a phase (or a roundId of 0) has no predecessor to read and must revert,
    /// not be treated as fixable.
    function _anyMarketFixable(uint256 id) internal view returns (bool) {
        Layer storage L = layers[id];
        uint256 n = markets.length;
        for (uint256 i; i < n; i++) {
            if (marketFixed[id][i]) continue;
            if (!referenceSet[id][i]) continue;
            (uint80 roundId, int256 answer,, uint256 updatedAt,) = markets[i].latestRoundData();
            if (answer <= 0 || uint256(answer) > type(uint64).max) continue;
            if (updatedAt < uint256(L.expiry)) continue;
            if (roundId == 0) continue;
            try markets[i].getRoundData(roundId - 1) returns (uint80, int256, uint256, uint256 prevUpdatedAt, uint80) {
                if (prevUpdatedAt != 0 && prevUpdatedAt < uint256(L.expiry)) return true;
            } catch {
                continue;
            }
        }
        return false;
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
            // Slither divide-before-multiply / judging doc B.4 (Treaty.sol:357-358 pre-fix): the
            // old two-step computation truncated the gap to whole bps (`* 10000 / friday`) before
            // multiplying by exposure, losing up to 0.005% of the true gap per market, always
            // rounded toward the writers (up to ~100 USDG of error on 1e12 exposure). One division
            // keeps full precision; `friday` can never be 0 (`setReference` requires a Chainlink
            // `answer > 0`), and Solidity's `int256` division truncates toward zero either way, so
            // this changes precision, not rounding direction. See
            // contracts/test/TreatyPrecision.t.sol for the measured before/after difference.
            int256 pnl = (exposure[i] * (monday - friday)) / friday;
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
