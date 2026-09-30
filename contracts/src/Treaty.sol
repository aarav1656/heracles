// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

/// @notice Weekend-gap excess-of-loss treaty. A buyer declares its Friday exposure per market and
/// binds a layer, in one book's asset, above `retention` up to `limit`; writer capital in that
/// book's two `Capacity` vaults backs the layer and is paid the premium the Stylus/Solidity
/// `Pricer` quotes; Monday's fixing pays the realized loss, capped at the layer's own locked
/// limit, to the buyer.
///
/// Books: the constructor takes one `address[] assets` array. Every asset must read
/// `decimals() == 6`, the unit the pricer and every stored amount already use. Each asset gets its
/// own pair of plain single-asset ERC-4626 vaults, a first-loss vault and a senior vault, so a
/// layer's collateral, premium and payout are always in that one book's asset; assets never mix.
/// `bind` takes a `book` index selecting which pair a layer draws on.
///
/// Tranches: at bind, a layer's limit `L` splits into a first-loss sub-layer `(retention, J)` and
/// a senior sub-layer `(retention + J, L - J)`, with `J = L * juniorShareBps / 1e4` and
/// `juniorShareBps` fixed at deploy. Two `pricer.quote` calls in the same transaction price the
/// whole layer and the first-loss sub-layer; the senior premium is the remainder, so the split
/// always comes from the same 504-scenario table the buyer's own price does. At settle, the
/// first-loss vault absorbs the first `J` of any payout and the senior vault the rest; both are
/// refunded on cancel and paid on claim from their own vault.
///
/// Fixing rule, allowlist and several checks follow a proven pattern: constructor-fixed feed
/// allowlist with a `decimals() == 8` check ("writer picks the oracle"), the Chainlink
/// phase-boundary guard `_latestInPhase`, and matching rules for both ends of the weekend:
/// `fix()` still takes the first round with `updatedAt >= expiry` (Monday's open, DST-aware,
/// previous round strictly before `expiry`); `setReference` instead takes the round in effect at
/// `fridayCloseOf(fridayCutoff)` (Friday's official close, also DST-aware), see
/// `_isUsDst`/`fridayCloseOf` and `setReference`'s own comment for the rule. This treaty has no
/// corporate-action multiplier check because it binds raw Chainlink equity feeds directly, not
/// Robinhood-style Stock Tokens with a `uiMultiplier()`; there is no multiplier to read.
///
/// Timing (SECURITY-REVIEW.md C1+H1; cutoff moved a day earlier by the independent v3 review's
/// H-1): the caller does not choose `fridayCutoff`/`expiry`. `weekWindow` still computes the
/// week's Friday 19:30 UTC anchor (`fridayCutoff`, unchanged: still what `L.fridayCutoff`,
/// `fridayCloseOf`, every vault's cutoff bucket and every event key on) and the following Monday
/// 9:30am ET `expiry`, in UTC via `_isUsDst` (13:30 UTC under DST, 14:30 UTC under standard time).
/// `bind` itself only succeeds strictly before `fridayCutoff - BIND_LEAD`, Thursday 19:30 UTC of
/// the same ISO week: one full equity-feed heartbeat before the old Friday 19:30 UTC deadline.
/// Reason: `setReference` reads the round already in effect at Friday's close (rules 1-5 below),
/// and a deviation-triggered feed (every RHC equity feed, 0.5% band, 24h heartbeat + ~36s
/// worst-case delay) can go a full heartbeat without printing. At the old Friday 19:30 UTC cutoff
/// a buyer could see that in-effect round live, 30-90 minutes before the close, and choose
/// exposure's sign to start in the money on an otherwise flat weekend. Thursday 19:30 UTC to
/// Friday's official close is at least 24.5h (20:00 UTC EDT / 21:00 UTC EST), longer than the
/// heartbeat, so the round that will turn out to be in effect at close cannot exist yet at bind
/// time under normal operation. Because a heartbeat is configuration, not a guarantee (a stall, a
/// holiday week), `setReference`/`voidReference` below also check this directly by round data
/// rather than by assumption (`ReferenceKnownAtBind`). The Friday reference price used for
/// settlement is not the spot at bind time either: it is fixed afterwards, per market, by
/// `setReference` against the round in effect at Friday's official close. The premium is still
/// quoted at bind time (the Pricer's 504-scenario table has no price/date argument, so "latest"
/// and "reference" price the same premium either way); a floor (H2) guarantees the total premium
/// is never zero, and each tranche's own split is checked separately so no slice can bind for a
/// zero premium either; `bind`'s own `maxPremium` argument reverts instead of silently charging a
/// buyer more than they quoted, if a round lands between the buyer's quote and the bind tx.
///
/// Solvency: `Capacity.locked` reserves a slice's full amount at bind; on settle, `Capacity.settle`
/// moves the unused remainder back to free capacity and the realized slice payout into
/// `Capacity.owed` (kept reserved until claim), and `Capacity.payOut` reverts if a caller ever asks
/// for more than is owed. Together with the `payout <= limit` clamp below (cap the payout at the
/// escrow), one layer's settlement can never draw capital reserved for another layer, another
/// tranche, another book, or a writer's still-free capacity. `Capacity.totalAssets()` counts active
/// `locked` capital at face value and nets out only `owed` and `pendingPremium` (the C1 fix); the
/// gate (`Capacity.maxDeposit`/`maxMint`/`maxRedeem`) closes deposits and withdrawals from a
/// vault's own `fridayCutoff` until every layer sharing that cutoff has settled or been cancelled
/// (the re-review's H1 fix: keying the gate on aggregate `locked != 0` let a rolling weekly bind,
/// timed for a cutoff days away, hold it shut forever). `bind`/`cancel`/`_settle` below pass each
/// layer's own `L.fridayCutoff` into each vault's `lock`/`unlock`/`settle` so Capacity can bucket
/// locked capital by the cutoff that actually starts its risk window. Both vaults of a book hold a
/// nonzero slice of every layer bound against that book (bind reverts if either slice's premium is
/// zero), so their gates always open and close together.
///
/// Premium flow: the buyer approves this contract, not a vault. `bind` pulls the whole premium
/// into the treaty, then each vault pulls its own share back out through the existing
/// `receivePremium(address(this), amount)`, using a max allowance this contract grants every vault
/// once, at construction. This contract's balance of every book asset is zero after every external
/// call (T5). It also means a writer's permit can never reset a buyer's standing premium
/// allowance (L1/F5 in docs/security/capacity-review.md), since buyers now approve this contract and
/// writers approve their vault, so no spender carries both allowances.
contract Treaty is ReentrancyGuard {
    using SafeERC20 for IERC20;

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
        uint16 book;
        uint8 referencedCount;
        uint8 fixedCount;
        State state;
        bool buyerClaimed;
        uint256 retention;
        uint256 limit;
        uint256 juniorLimit; // J: the first-loss sub-layer's own limit
        uint256 premium;
        uint256 premiumJunior;
        uint256 premiumSenior;
        uint256 payout;
        uint256 payoutJunior;
        uint256 payoutSenior;
    }

    /// One book: a single asset and the pair of plain single-asset ERC-4626 vaults that back every
    /// layer bound against it, a first-loss vault absorbing the first `juniorShareBps` of each
    /// layer's limit and a senior vault absorbing the rest.
    struct Book {
        IERC20 asset;
        Capacity firstLoss;
        Capacity senior;
    }

    // F1 (re-review of 96309c8, the security review): a layer's own cutoff to
    // the next weekly cutoff is 168h (7 days). A layer becomes cancellable at `expiry + GRACE`,
    // and `expiry` is cutoff + 66h (Friday 19:30 to Monday 13:30). For a stuck layer (dead feed,
    // never fixable) to be cancellable before the *next* week's cutoff closes the gate again,
    // 66h + GRACE must be < 168h, i.e. GRACE < 102h. At 7 days (168h) a stuck layer outlived the
    // next cutoff and froze writers indefinitely with one dust bind per week. 3 days (72h) is
    // comfortably under the 102h bound and leaves a 168h - 66h - 72h = 30h open window every week
    // even with a permanently dead feed; a cancel still moves the buyer's premium out of
    // `pendingPremium` in full (`cancel` below calls `cancelPremium` on both vaults, pull-claimable
    // through `claimTo`), so this only shortens the backstop, it does not change who pays for an
    // unfixable layer.
    uint256 internal constant GRACE = 3 days;
    uint256 internal constant SEQUENCER_GRACE = 1 hours;
    // L6-2: `cancel`'s livenessFeed check and its `_anyMarketFixable` StillFixable check both
    // depend on a signal that can stop forever, an immutable liveness feed or a market feed whose
    // reads start reverting, so without a time-bounded override an unfixable layer whose signal
    // died could stay `Bound` forever with both vaults' gates shut and no admin path out. Once
    // `block.timestamp >= expiry + CANCEL_BACKSTOP`, both checks are skipped and cancel proceeds
    // regardless of what either signal reports. The trade-off is explicit: a live 24h-heartbeat
    // feed prints dozens of post-expiry rounds in 30 days, so a buyer whose layer actually did pay
    // out has that long to call `fix` before anyone can cancel out from under them; a buyer who
    // lets a fixable layer sit unfixed for 30 days loses it to cancel instead of collecting the
    // payout. The sequencer-down check and the `GRACE` wait before `expiry` still apply
    // unconditionally: this backstop only lifts the two checks that can otherwise never resolve.
    uint256 internal constant CANCEL_BACKSTOP = 30 days;
    uint256 internal constant BPS = 1e4;
    // F2 (re-review of 96309c8): `_settle` multiplies `exposure[i] * gapBps` in checked int256.
    // The Pricer's own scenario table never produces |gapBps| above ~1474, so any exposure this
    // pricer would ever quote against is safe, but nothing stopped a caller from binding an
    // exposure so large that a real gap (not just the table's) panics the multiplication forever.
    // 1e30 is far above any real vault's exposure (every book asset has 6 decimals; 1e30 base
    // units is 1e24 of that asset) while leaving `1e30 * 1474` (~1.47e33) nowhere near int256's
    // ~5.79e76 ceiling.
    uint256 internal constant MAX_EXPOSURE = 1e30;

    // `setReference` used to accept the first fresh round at or after `fridayCloseOf`, bounded by
    // a max delay off that boundary. On Robinhood Chain's real equity feeds that rule never even
    // reaches a round to check: the weekend heartbeat gap is 52-56h with zero prints in between, so
    // "first round after close" is always the Sunday/Monday reopen, already carrying the weekend's
    // news, silently absorbing the very gap this treaty exists to cover. Reading the round already
    // in effect the instant trading stopped (`setReference` below) needs no round after close at
    // all, so an ordinary silent weekend never triggers absorption or void. `MAX_ROUND_AGE` now
    // only bounds how old *that* round may be (rule 5) and gates `bind`'s own freshness check
    // below; a round silent for a full weekend before close is still too stale to stand in for it.
    uint256 internal constant MAX_ROUND_AGE = 26 hours;

    // Weekday math constants (SECURITY-REVIEW.md C1+H1). Epoch day 0 (1970-01-01) was a Thursday.
    // ISO weekday (Monday=0..Sunday=6) of epoch day `d` is `(d + 3) % 7` (day 0=Thu -> 3, day
    // 4=Mon -> 0; unit-tested in contracts/test/WeekWindow.t.sol across 3 weeks, a year boundary
    // and both weekend days).
    //
    // NYSE's Friday close and Monday open are fixed in *US Eastern*
    // clock time (4:00pm / 9:30am ET), not fixed UTC offsets; UTC drifts by an hour twice a year
    // as the US switches DST. `FRIDAY_CUTOFF_TOD` is left DST-independent on purpose: 19:30 UTC is
    // strictly earlier than the close under either regime (20:00 UTC EDT, 21:00 UTC EST), so
    // `fridayCloseOf` (keyed off this anchor) can never straddle the March/November switch within
    // one week. `MONDAY_EXPIRY_TOD_*` and `fridayCloseOf` below are the two instants that do move
    // with DST. `FRIDAY_CUTOFF_TOD` itself is no longer the bind deadline (see `BIND_LEAD` below,
    // independent v3 review H-1): it still anchors `fridayCutoff`, which `L.fridayCutoff`,
    // `fridayCloseOf`, the Capacity gate buckets and every event still key on unchanged.
    uint256 internal constant FRIDAY_CUTOFF_TOD = 19 hours + 30 minutes;
    // H-1 (independent v3 review): a live 24h-heartbeat equity feed can go a full heartbeat plus
    // its own worst-case delay (~36s on RHC) without printing while inside the 0.5% deviation
    // band. At the old Friday 19:30 UTC bind deadline, 30-90 minutes before the close, a buyer
    // could already see the exact round `setReference` would later read as "in effect at close"
    // and choose exposure's sign to start in the money on an otherwise flat weekend. `bind` now
    // closes one full heartbeat earlier, at `fridayCutoff - BIND_LEAD` (Thursday 19:30 UTC):
    // Thursday 19:30 UTC to Friday's official close is at least 24.5h (20:00 UTC EDT / 21:00 UTC
    // EST), longer than the heartbeat, so under normal operation the round in effect at close has
    // not printed yet when bind closes. A stalled or holiday-silent feed could still defeat that
    // margin, so this is a defense in depth, not the only guard: `setReference`/`voidReference`
    // independently refuse/void any round whose own `updatedAt` is at or before the layer's bind
    // deadline (`ReferenceKnownAtBind`), which holds regardless of how long any given feed goes
    // silent.
    uint256 internal constant BIND_LEAD = 1 days;
    uint256 internal constant MONDAY_EXPIRY_TOD_EDT = 13 hours + 30 minutes; // 9:30am ET, UTC-4
    uint256 internal constant MONDAY_EXPIRY_TOD_EST = 14 hours + 30 minutes; // 9:30am ET, UTC-5
    uint256 internal constant FRIDAY_CLOSE_TOD_EDT = 20 hours; // 4:00pm ET, UTC-4
    uint256 internal constant FRIDAY_CLOSE_TOD_EST = 21 hours; // 4:00pm ET, UTC-5

    IPricer public immutable pricer; // L3: fixed at deploy, no setter, no admin path to swap it
    uint256 public immutable minRateOnLineBps; // H2: premium floor, bps of limit
    address public immutable sequencerUptimeFeed; // M2: address(0) disables the check (testnet)
    // `cancel`'s liveness guard: a feed with a heartbeat that survives weekends (USDC/USD on both
    // Arbitrum Sepolia and Robinhood Chain), read only there. Proves the chain itself kept
    // receiving Chainlink writes long enough past a layer's expiry that a live 24h-heartbeat
    // equity feed must have printed its own post-expiry round, so "no fresh equity round" really
    // means a dead/paused market, not a halted chain silently starving every feed at once
    // (Robinhood Chain has no sequencer-uptime feed at all, so this is its only guard against that
    // race). `address(0)` disables the check and must only ever be passed by unit tests; every real
    // deploy passes a real feed.
    address public immutable livenessFeed;
    // Every layer's first-loss sub-limit is `limit * juniorShareBps / BPS`. Fixed at deploy, not
    // governable: a writer knows their slice of every future layer before depositing.
    uint256 public immutable juniorShareBps;
    AggregatorV3Interface[] public markets;
    Book[] public books;

    mapping(uint256 => Layer) public layers;
    uint256 public layerCount;
    mapping(uint256 => int256[]) internal _exposure;
    mapping(uint256 => mapping(uint256 => uint64)) public fridayPrice;
    mapping(uint256 => mapping(uint256 => uint64)) public mondayPrice;
    mapping(uint256 => mapping(uint256 => bool)) public referenceSet;
    mapping(uint256 => mapping(uint256 => bool)) public marketFixed;
    // H1, rewritten for the round-in-effect-at-close rule: a market permissionlessly proven, by
    // round data, to have no reachable round in effect at close (see `voidReference` below for the
    // stale/phase proofs). A void market can never have its reference set and must not block
    // `cancel` the way a merely-unreferenced-but-still-fixable market does.
    mapping(uint256 => mapping(uint256 => bool)) public referenceVoid;

    event Bound(
        uint256 indexed id,
        address indexed buyer,
        uint256 indexed book,
        uint256 retention,
        uint256 limit,
        uint256 premium,
        uint40 expiry
    );
    event ReferenceSet(uint256 indexed id, uint256 indexed marketIdx, uint80 roundId, uint64 price);
    event ReferenceVoided(uint256 indexed id, uint256 indexed marketIdx, uint80 roundId, uint256 updatedAt);
    event MarketFixed(uint256 indexed id, uint256 indexed marketIdx, uint80 roundId, int256 answer);
    event Settled(uint256 indexed id, uint256 payout, uint256 payoutJunior, uint256 payoutSenior);
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
    // Cancel is a backstop for a genuinely stale/dead feed, not a way to skip a layer that
    // could still be fixed right now.
    error StillFixable();
    // H1: `setReference`/`voidReference` are mutually exclusive terminal proofs for one market;
    // once either has recorded an outcome the other must not run again for the same market.
    error ReferenceIsVoid();
    // Independent v3 review H-1: the round `setReference` would otherwise accept was already
    // in effect at or before this layer's own bind deadline, so the buyer could have seen it
    // before choosing exposure's sign. `voidReference`'s "known at bind" proof is the only path
    // forward for this market.
    error ReferenceKnownAtBind();
    // Independent v3 review L-2: `bind`'s caller-set ceiling on the premium actually charged.
    error PremiumTooHigh();

    constructor(
        address[] memory assets,
        string[] memory firstLossNames,
        string[] memory firstLossSymbols,
        string[] memory seniorNames,
        string[] memory seniorSymbols,
        address pricer_,
        address[] memory feeds,
        uint256 minRateOnLineBps_,
        address sequencerUptimeFeed_,
        address livenessFeed_,
        uint256 juniorShareBps_
    ) {
        uint256 nAssets = assets.length;
        if (
            nAssets == 0 || pricer_ == address(0) || feeds.length == 0
                || firstLossNames.length != nAssets || firstLossSymbols.length != nAssets
                || seniorNames.length != nAssets || seniorSymbols.length != nAssets
                || juniorShareBps_ == 0 || juniorShareBps_ >= BPS
        ) revert BadParams();
        pricer = IPricer(pricer_);
        minRateOnLineBps = minRateOnLineBps_;
        sequencerUptimeFeed = sequencerUptimeFeed_;
        livenessFeed = livenessFeed_;
        juniorShareBps = juniorShareBps_;
        for (uint256 i; i < feeds.length; i++) {
            if (feeds[i] == address(0)) revert BadParams();
            if (AggregatorV3Interface(feeds[i]).decimals() != 8) revert BadParams();
            markets.push(AggregatorV3Interface(feeds[i]));
        }
        for (uint256 i; i < nAssets; i++) {
            address a = assets[i];
            if (a == address(0)) revert BadParams();
            // Every book asset must read the same 6 decimals the pricer and every
            // stored amount already assume; a book on a differently-scaled asset would silently
            // misprice every layer bound against it.
            if (IERC20Metadata(a).decimals() != 6) revert BadParams();
            Capacity firstLoss = new Capacity(IERC20(a), address(this), firstLossNames[i], firstLossSymbols[i]);
            Capacity senior = new Capacity(IERC20(a), address(this), seniorNames[i], seniorSymbols[i]);
            // A max allowance so each vault's own `receivePremium` pull (called from `bind` below)
            // never needs a fresh approval from this contract.
            IERC20(a).forceApprove(address(firstLoss), type(uint256).max);
            IERC20(a).forceApprove(address(senior), type(uint256).max);
            books.push(Book({asset: IERC20(a), firstLoss: firstLoss, senior: senior}));
        }
    }

    function marketsLength() external view returns (uint256) {
        return markets.length;
    }

    function exposureOf(uint256 id) external view returns (int256[] memory) {
        return _exposure[id];
    }

    /// Number of books (one per asset the constructor was given).
    function booksCount() external view returns (uint256) {
        return books.length;
    }

    function bookAsset(uint256 book) external view returns (address) {
        return address(books[book].asset);
    }

    function firstLossVault(uint256 book) external view returns (address) {
        return address(books[book].firstLoss);
    }

    function seniorVault(uint256 book) external view returns (address) {
        return address(books[book].senior);
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
    /// `fridayCutoff` (any timestamp that same UTC day works; DST never changes mid-day). This,
    /// not "the last round before Saturday 00:00 UTC", is what `setReference` now waits for.
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

    /// Declares exposure per market and locks a layer for the current weekend, in one book's asset.
    /// Only callable strictly before this week's Thursday 19:30 UTC bind deadline, one heartbeat
    /// ahead of `fridayCutoff` (`BIND_LEAD`, independent v3 review H-1; SECURITY-REVIEW.md C1+H1);
    /// the caller cannot choose `fridayCutoff` or `expiry`. Quotes the whole layer's premium from
    /// `pricer` and floors it at `minRateOnLineBps` of `limit` (H2, a zero quote can never bind),
    /// then reverts `PremiumTooHigh` if that floored premium exceeds the caller's own `maxPremium`
    /// (independent v3 review L-2: bind prices from live rounds inside the transaction, so a round
    /// landing between a quote and the bind call can otherwise charge more than was shown). A
    /// second `pricer.quote` on the first-loss sub-layer `(retention, J)` in the same transaction
    /// sets `premiumJunior`, and `premiumSenior` is the remainder, so the split always comes from
    /// the same table the total premium does. Reserves `J` out of the book's first-loss vault and
    /// `limit - J` out of its senior vault, and pulls the whole premium from the buyer into this
    /// contract before each vault pulls its own share back out. The Friday reference price is set
    /// later, per market, by `setReference`, not read here.
    function bind(uint256 book, int256[] calldata exposure, uint256 retention, uint256 limit, uint256 maxPremium)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (book >= books.length) revert BadParams();
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
        // H-1: the actual bind deadline is one heartbeat before `fridayCutoff` (see `BIND_LEAD`'s
        // comment); `cutoff`/`expiry` themselves, and everything derived from `cutoff` below
        // (`L.fridayCutoff`, the vault cutoff buckets, the `Bound` event), are unchanged.
        if (block.timestamp >= cutoff - BIND_LEAD) revert BadTiming();

        // Liveness guard rule 1: every market's feed must have a round within MAX_ROUND_AGE of
        // now, or a layer could bind against a feed that is already dead (an F1-style weekly
        // griefing entry point) or price its volatility off a stale round during a long outage.
        // Written as an addition, `updatedAt + MAX_ROUND_AGE >= block.timestamp`, not
        // `block.timestamp - updatedAt`, so a fork test that warps block.timestamp backward never
        // underflows.
        address[] memory feedAddrs = new address[](n);
        for (uint256 i; i < n; i++) {
            feedAddrs[i] = address(markets[i]);
            (,,, uint256 updatedAt,) = markets[i].latestRoundData();
            if (updatedAt + MAX_ROUND_AGE < block.timestamp) revert BadRound();
        }

        // The first-loss sub-layer's own limit, J = L * juniorShareBps / 1e4. `BadParams` if
        // either slice would be empty: no vault can lock capital for a zero-sized slice.
        uint256 juniorLimit = limit * juniorShareBps / BPS;
        if (juniorLimit == 0 || limit - juniorLimit == 0) revert BadParams();

        (uint256 quotedTotal,,) = pricer.quote(exposure, feedAddrs, retention, limit);
        uint256 floor_ = limit * minRateOnLineBps / BPS;
        uint256 premium = quotedTotal < floor_ ? floor_ : quotedTotal;
        // L2 (the security review): the H2 floor itself rounds to zero for any limit under 200
        // base units. Harmless alone, but the C1 epoch gate now closes every writer's deposits and
        // withdrawals while a layer is live, so a free bind becomes a repeatable weekly griefing
        // lock. A zero-premium layer can never bind.
        if (premium == 0) revert BadParams();
        // L-2 (independent v3 review): the floored premium actually charged must not exceed what
        // the caller was willing to pay. A live round landing inside this same transaction, before
        // the two `pricer.quote` calls, can otherwise reprice the layer above whatever a UI or
        // integrator last quoted.
        if (premium > maxPremium) revert PremiumTooHigh();

        // The first-loss sub-layer's own quote sets its share of the premium; the floor, if it
        // bound above, is not re-applied to the sub-layer, so a floor top-up always lands in the
        // senior slice (docs/pricing.md: additivity holds on the unfloored quote, and the senior
        // slice absorbs whatever the floor added on top of it).
        (uint256 quotedJunior,,) = pricer.quote(exposure, feedAddrs, retention, juniorLimit);
        uint256 premiumJunior = quotedJunior;
        // Additivity (docs/pricing.md, checked in TrancheAdditivity.t.sol) guarantees
        // quotedJunior <= quotedTotal <= premium, so this never underflows in practice; if the
        // pricer ever violated that, this reverts instead of silently mispricing the split.
        uint256 premiumSenior = premium - premiumJunior;
        // No vault can lock capital for zero premium (generalizes L2 above to each slice): a
        // dust layer that would price one tranche at zero can never bind at all.
        if (premiumJunior == 0 || premiumSenior == 0) revert BadParams();

        id = layerCount++;
        Layer storage L = layers[id];
        L.buyer = msg.sender;
        L.fridayCutoff = uint40(cutoff);
        L.expiry = uint40(expiry);
        L.book = uint16(book);
        L.state = State.Bound;
        L.retention = retention;
        L.limit = limit;
        L.juniorLimit = juniorLimit;
        L.premium = premium;
        L.premiumJunior = premiumJunior;
        L.premiumSenior = premiumSenior;
        _exposure[id] = exposure;

        emit Bound(id, msg.sender, book, retention, limit, premium, uint40(expiry));

        Book storage b = books[book];
        b.firstLoss.lock(juniorLimit, uint40(cutoff));
        b.senior.lock(limit - juniorLimit, uint40(cutoff));
        // The buyer approves this contract, not a vault; this pulls the whole premium in, then
        // each vault pulls its own share back out through its existing `receivePremium`. This
        // contract's balance of the book asset returns to zero (T5): `premiumJunior +
        // premiumSenior == premium` exactly, by construction above.
        b.asset.safeTransferFrom(msg.sender, address(this), premium);
        b.firstLoss.receivePremium(address(this), premiumJunior);
        b.senior.receivePremium(address(this), premiumSenior);
    }

    /// Sets one market's Friday reference to the round in effect at Friday's official close, not
    /// the first round after it: the round whose `updatedAt` is at or before `closeTs` and that
    /// nothing has superseded before `closeTs` either (rule 4 below), so it is exactly the price
    /// the market was quoting the instant the week's trading stopped. Callable only after that
    /// close has passed, permissionlessly, same as `fix`.
    ///
    /// The five rules:
    /// 1. `block.timestamp > closeTs`, strict, so no round can still land at `closeTs` in this block.
    /// 2. `roundId` is in the feed's current phase (`_latestInPhase`) with a positive, in-range
    ///    answer.
    /// 3. `updatedAt(roundId) <= closeTs`: the round must already have existed at close.
    /// 4. `roundId` is the feed's latest round, or the very next round only printed after close:
    ///    within a phase this picks exactly one round, the one in effect at the close instant.
    /// 5. `updatedAt(roundId) + MAX_ROUND_AGE >= closeTs`: the in-effect round must itself be
    ///    recent, or a feed silent for a full weekend before close could let a days-old heartbeat
    ///    stand in for the close (the same absorption concern the old rule guarded against, from
    ///    the other side).
    ///
    /// This never needs a round *after* close, so a market with no weekend heartbeat (Robinhood
    /// Chain's real SPY/AAPL feeds, 52-56h silent every weekend) settles normally instead of
    /// voiding every ordinary weekend.
    ///
    /// One more check, after all five rules pass (independent v3 review H-1): if the round they
    /// picked was already `updatedAt` at or before this layer's own bind deadline
    /// (`fridayCutoff - BIND_LEAD`), the buyer could have seen this exact round, already in effect
    /// at close, before choosing exposure's sign, so it must not be usable to settle. Moving the
    /// bind deadline a heartbeat earlier makes this unreachable in the ordinary case, but a
    /// heartbeat is configuration, not a guarantee; this check holds regardless. Reverts
    /// `ReferenceKnownAtBind`; `voidReference`'s matching third proof is the only way forward left
    /// for this market.
    function setReference(uint256 id, uint256 marketIdx, uint80 roundId) external nonReentrant {
        Layer storage L = layers[id];
        if (L.state != State.Bound) revert WrongState();
        if (marketIdx >= markets.length) revert BadParams();
        if (referenceSet[id][marketIdx]) revert AlreadyFixed();
        // H1: once `voidReference` has recorded a proof that this market's round in effect at
        // close can never be reached, no round can ever satisfy this function again for this
        // market (see `voidReference`'s own comment); kept as an explicit, cheap revert.
        if (referenceVoid[id][marketIdx]) revert ReferenceIsVoid();

        uint256 closeTs = fridayCloseOf(uint256(L.fridayCutoff));
        if (block.timestamp <= closeTs) revert BadTiming(); // rule 1
        _requireSequencerUp();

        AggregatorV3Interface feed = markets[marketIdx];
        uint80 latestId = _latestInPhase(feed, roundId); // rule 2 (phase)
        (, int256 answer,, uint256 updatedAt,) = feed.getRoundData(roundId);
        if (answer <= 0 || uint256(answer) > type(uint64).max) revert BadRound(); // rule 2 (answer)
        if (updatedAt > closeTs) revert BadRound(); // rule 3
        if (roundId != latestId) {
            // rule 4: the next round must not have existed yet at close either, or `roundId` was
            // already stale before the week even finished trading.
            (,,, uint256 nextUpdatedAt,) = feed.getRoundData(roundId + 1);
            if (nextUpdatedAt != 0 && nextUpdatedAt <= closeTs) revert BadRound();
        }
        if (updatedAt + MAX_ROUND_AGE < closeTs) revert BadRound(); // rule 5
        // H-1: the round in effect at close must not already have existed at this layer's own
        // bind deadline, or the buyer could have seen it before choosing exposure's sign.
        if (updatedAt <= uint256(L.fridayCutoff) - BIND_LEAD) revert ReferenceKnownAtBind();

        uint64 price = uint64(uint256(answer));
        fridayPrice[id][marketIdx] = price;
        referenceSet[id][marketIdx] = true;
        L.referencedCount += 1;
        emit ReferenceSet(id, marketIdx, roundId, price);
    }

    /// Permissionless proof that a market's Friday reference can never be set, either proof
    /// callable only after `closeTs`:
    ///
    /// - **stale**: `roundId` is the genuine round in effect at close (rules 2-4 above, minus the
    ///   answer-value half of rule 2, see below) but fails rule 5, silent for more than
    ///   `MAX_ROUND_AGE` before close. The answer's *value* is deliberately not checked here
    ///   (unlike `setReference`): a stale round with a bad answer must still be voidable on timing
    ///   alone, or a feed that went both silent and briefly corrupt could leave the layer with
    ///   neither a reference nor an escape (the same reasoning the earlier void carried; see
    ///   `test_V4` in TreatyVoid.t.sol).
    /// - **phase**: `roundId` is the feed's current phase's own first round (`phaseId << 64 | 1`)
    ///   and its `updatedAt` is already after close, so the round that was actually in effect at
    ///   close sits in an older, now-unreachable phase (`_latestInPhase` only accepts the current
    ///   one). A round matching the phase pattern whose own `updatedAt` is at or before close is
    ///   not stranded at all and falls through to the stale/known-at-bind check instead.
    /// - **known at bind** (independent v3 review H-1): `roundId` is the genuine round in effect at
    ///   close (same rules 2-4 as the stale proof) and its `updatedAt` is at or before this layer's
    ///   own bind deadline (`fridayCutoff - BIND_LEAD`), the same condition `setReference` itself
    ///   now refuses with `ReferenceKnownAtBind`. Disjoint from stale (a round can be fresh, i.e.
    ///   not stale, and still known at bind, or the reverse), so either condition alone voids.
    ///
    /// All three proofs and `setReference` exclude each other (`AlreadyFixed`/`ReferenceIsVoid`).
    /// `_anyMarketFixable` below treats a void market the same as a dead one: it stops blocking
    /// `cancel`, so a layer stuck on an unreachable reference reaches `Cancelled` instead of
    /// staying `Bound` forever with the vaults' gates shut and no admin path out.
    function voidReference(uint256 id, uint256 marketIdx, uint80 roundId) external nonReentrant {
        Layer storage L = layers[id];
        if (L.state != State.Bound) revert WrongState();
        if (marketIdx >= markets.length) revert BadParams();
        if (referenceSet[id][marketIdx]) revert AlreadyFixed();
        if (referenceVoid[id][marketIdx]) revert ReferenceIsVoid();

        uint256 closeTs = fridayCloseOf(uint256(L.fridayCutoff));
        if (block.timestamp <= closeTs) revert BadTiming();

        AggregatorV3Interface feed = markets[marketIdx];
        (uint80 latestId,,,,) = feed.latestRoundData();
        if (uint64(latestId) == 0) revert BadRound();

        // Phase proof.
        if (roundId == ((latestId >> 64) << 64 | 1)) {
            (,,, uint256 phaseFirstUpdatedAt,) = feed.getRoundData(roundId);
            if (phaseFirstUpdatedAt > closeTs) {
                referenceVoid[id][marketIdx] = true;
                emit ReferenceVoided(id, marketIdx, roundId, phaseFirstUpdatedAt);
                return;
            }
        }

        // Stale / known-at-bind proof: same rules 2 (phase only, no answer-value check), 3 and 4 as
        // setReference, i.e. `roundId` is genuinely the round in effect at close. From there, two
        // disjoint ways this market can be void: stale (opposite of rule 5) or known at bind
        // (H-1, `updatedAt` at or before this layer's own bind deadline).
        uint80 checkedLatest = _latestInPhase(feed, roundId);
        (,,, uint256 updatedAt,) = feed.getRoundData(roundId);
        if (updatedAt == 0) revert BadRound(); // no round ever printed at this id: nothing to void
        if (updatedAt > closeTs) revert BadRound();
        if (roundId != checkedLatest) {
            (,,, uint256 nextUpdatedAt,) = feed.getRoundData(roundId + 1);
            if (nextUpdatedAt != 0 && nextUpdatedAt <= closeTs) revert BadRound();
        }
        bool stale = updatedAt + MAX_ROUND_AGE < closeTs;
        bool knownAtBind = updatedAt <= uint256(L.fridayCutoff) - BIND_LEAD;
        if (!stale && !knownAtBind) revert BadTiming(); // must actually be voidable one way or the other

        referenceVoid[id][marketIdx] = true;
        emit ReferenceVoided(id, marketIdx, roundId, updatedAt);
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
    /// the layer, freeing the writer capital both its slices locked. The buyer's premium moves
    /// from `pendingPremium` into `owed` in both vaults here rather than staying earned by writers
    /// for a layer that never resolved (SECURITY-REVIEW.md M3): writers only earn the premium for
    /// a layer that actually settles. L6-1: this used to push the refund straight to the buyer
    /// inside this same call; an issuer freeze of the buyer (a blacklist, an asset-protection
    /// hold) made that transfer revert forever and left the layer `Bound`, both vaults' gates shut
    /// for every writer. `cancelPremium` only moves the accounting; the buyer pulls it out
    /// afterwards through `claimTo`, the same pull `claim`/`claimTo` already use for a settled
    /// payout, so a frozen buyer can redirect the pull to another address instead of bricking the
    /// book.
    ///
    /// Cancel is a backstop for a genuinely dead layer, not a shortcut around a layer that
    /// could still be fixed. `_anyMarketFixable` below reverts `StillFixable` if any unfixed
    /// market already has a Monday round sitting there waiting to be consumed by `fix`, at that
    /// point the correct call is `fix`, not `cancel`; this check is unconditional; there is no
    /// point after which a layer that could still settle is allowed to cancel instead (independent
    /// v3 review L-1: `CANCEL_BACKSTOP` used to skip it too, so an out-of-the-money buyer could let
    /// 30 days pass and cancel for a full premium refund instead of calling `fix` for the payout
    /// they were actually owed, zero). L6-2: the liveness check alone depends on a signal (an
    /// immutable feed) that can stop responding forever; `CANCEL_BACKSTOP` (its own comment above)
    /// lifts only that check once 30 days have passed since expiry, so a dead liveness signal
    /// cannot brick the book indefinitely, while a market that is actually still fixable never
    /// becomes cancellable no matter how long it sits.
    function cancel(uint256 id) external nonReentrant {
        Layer storage L = layers[id];
        if (L.state != State.Bound) revert WrongState();
        if (block.timestamp < uint256(L.expiry) + GRACE) revert BadTiming();
        // Same sequencer gate as fix: cancel must not land in a window where fix is blocked.
        _requireSequencerUp();
        if (block.timestamp < uint256(L.expiry) + CANCEL_BACKSTOP) {
            // Liveness guard rule 3: proves the chain itself kept receiving Chainlink writes long
            // enough after expiry that a live 24h-heartbeat equity feed must have printed its own
            // post-expiry round, so "no fresh equity round" really means a dead market, not a
            // halted chain silently starving every feed at once, the same race the Arbitrum
            // sequencer-uptime check above guards on Arbitrum, but Robinhood Chain has no
            // sequencer-uptime feed at all, so this is its only protection. Reverts the same
            // `StillFixable` as the check below: both mean "cannot yet prove this layer is really
            // dead". `livenessFeed == address(0)` disables the check (unit tests only).
            if (livenessFeed != address(0)) {
                (,,, uint256 liveUpdatedAt,) = AggregatorV3Interface(livenessFeed).latestRoundData();
                if (liveUpdatedAt < uint256(L.expiry) + MAX_ROUND_AGE) revert StillFixable();
            }
        }
        // L-1: unconditional, backstop or not. A layer that could still be fixed right now must
        // never be cancellable; `_isMarketDead` below reads every feed through `try/catch`, so a
        // dead or reverting market feed cannot itself block this from resolving past the backstop.
        if (_anyMarketFixable(id)) revert StillFixable();
        L.state = State.Cancelled;
        emit Cancelled(id, L.premium);
        Book storage b = books[L.book];
        b.firstLoss.unlock(L.juniorLimit, L.fridayCutoff);
        b.senior.unlock(L.limit - L.juniorLimit, L.fridayCutoff);
        b.firstLoss.cancelPremium(L.premiumJunior);
        b.senior.cancelPremium(L.premiumSenior);
    }

    /// True if some not-yet-fixed market on this layer is still fixable: either its Monday round
    /// (against `L.expiry`) could still be produced, or, if the reference was never set, it has
    /// not been proven void.
    ///
    /// `setReference` reads the round already in effect the instant Friday's close happened, which
    /// always exists once close has passed (barring a feed with no history at all): it never waits
    /// for a round *after* the boundary the way `fix`'s Monday-open rule still does. An
    /// unreferenced market is therefore always resolvable unless `voidReference` has proven it
    /// stranded (the stale/phase proofs there); the old `_isMarketDead(markets[i], refBoundary)`
    /// check on the Friday side no longer applies to this branch (that function's question, "has a
    /// round printed past this boundary yet", is not the one this reference rule asks).
    ///
    /// H1/H2 (re-review of 23e632f): `fix` requires every market's reference to be set
    /// (`ReferenceNotSet`) before any one of them can settle. So the instant one market can never
    /// get a reference, proven void, `fix` can never succeed for this layer again, no matter
    /// what any other market looks like. Returning `false` immediately in that case (rather than
    /// only `continue`, the old per-market-only view) is what lets `cancel` actually terminate a
    /// layer stuck behind one unreferenceable market instead of deadlocking on another market's
    /// own "still fixable".
    function _anyMarketFixable(uint256 id) internal view returns (bool) {
        Layer storage L = layers[id];
        uint256 n = markets.length;
        bool anyFixable;
        for (uint256 i; i < n; i++) {
            if (marketFixed[id][i]) continue;
            if (!referenceSet[id][i]) {
                if (referenceVoid[id][i]) return false;
                anyFixable = true;
                continue;
            }
            if (!_isMarketDead(markets[i], uint256(L.expiry))) anyFixable = true;
        }
        return anyFixable;
    }

    /// A market counts as dead against `boundary` only if its latest round predates `boundary`
    /// (nothing has printed past it yet), or the current Chainlink phase's own first round
    /// (`phaseId << 64 | 1`, one extra read) is already at or past `boundary` (the crossing round
    /// lives in an older, now-unreachable phase, the M3 scenario `fix`'s own `_latestInPhase`
    /// guard cannot cross). Any other case means a genuine first-round-after-`boundary` exists
    /// somewhere in the current phase. `try` because a phase's own first round (or a roundId of 0)
    /// can be unset/unreadable on some feed implementations and must count as dead, not fixable.
    /// L-1 (independent v3 review): the initial `latestRoundData()` read is also `try`/`catch` now,
    /// not a bare call; a feed that reverts outright (not merely stale) must count as dead too, or
    /// it could block `cancel`'s backstop forever, the same failure mode the phase read already
    /// guarded against.
    function _isMarketDead(AggregatorV3Interface feed, uint256 boundary) internal view returns (bool) {
        uint80 latestId;
        int256 answer;
        uint256 updatedAt;
        try feed.latestRoundData() returns (uint80 latestId_, int256 answer_, uint256, uint256 updatedAt_, uint80) {
            (latestId, answer, updatedAt) = (latestId_, answer_, updatedAt_);
        } catch {
            return true;
        }
        if (answer <= 0 || uint256(answer) > type(uint64).max) return true;
        if (updatedAt < boundary) return true;
        if (uint64(latestId) == 0) return true;
        uint80 phase = latestId >> 64;
        uint80 phaseFirstRound = (phase << 64) | 1;
        try feed.getRoundData(phaseFirstRound) returns (uint80, int256, uint256, uint256 firstUpdatedAt, uint80) {
            return firstUpdatedAt >= boundary;
        } catch {
            return true;
        }
    }

    /// Pull claim for the buyer's realized payout, paid to the caller. `claimTo` lets the buyer
    /// redirect to another address (L4: a blocklisted buyer is not stuck forever); only the
    /// buyer who owns the claim can call either. Pays from both of the layer's book vaults, each
    /// its own slice, in the book's asset. L6-1: a `Cancelled` layer is claimable the same way,
    /// paying out the premium `cancel` moved into `owed` instead of pushing it, so a buyer frozen
    /// by their own issuer can still redirect the pull to another address instead of leaving the
    /// book bricked.
    function claim(uint256 id) external {
        claimTo(id, msg.sender);
    }

    function claimTo(uint256 id, address to) public nonReentrant {
        Layer storage L = layers[id];
        bool settled = L.state == State.Settled;
        if (!settled && L.state != State.Cancelled) revert WrongState();
        if (L.buyerClaimed) revert NothingToClaim();
        if (msg.sender != L.buyer) revert NothingToClaim();
        if (settled && L.payout == 0) revert NothingToClaim();
        if (to == address(0)) revert BadParams();

        L.buyerClaimed = true;
        emit Claimed(id, L.buyer, to, settled ? L.payout : L.premium);
        Book storage b = books[L.book];
        b.firstLoss.payOut(to, settled ? L.payoutJunior : L.premiumJunior);
        b.senior.payOut(to, settled ? L.payoutSenior : L.premiumSenior);
    }

    function _settle(uint256 id) internal {
        Layer storage L = layers[id];
        uint256 n = markets.length;
        int256[] storage exposure = _exposure[id];

        int256 totalLoss;
        for (uint256 i; i < n; i++) {
            int256 friday = int256(uint256(fridayPrice[id][i]));
            int256 monday = int256(uint256(mondayPrice[id][i]));
            // Slither divide-before-multiply (Treaty.sol:357-358 pre-fix): the
            // old two-step computation truncated the gap to whole bps (`* 10000 / friday`) before
            // multiplying by exposure, losing up to 0.005% of the true gap per market, always
            // rounded toward the writers (up to ~100 base units of error on 1e12 exposure). One
            // division keeps full precision; `friday` can never be 0 (`setReference` requires a
            // Chainlink `answer > 0`), and Solidity's `int256` division truncates toward zero
            // either way, so this changes precision, not rounding direction. See
            // contracts/test/TreatyPrecision.t.sol for the measured before/after difference.
            int256 pnl = (exposure[i] * (monday - friday)) / friday;
            if (pnl < 0) totalLoss -= pnl;
        }

        int256 p = totalLoss - int256(L.retention);
        if (p < 0) p = 0;
        uint256 payout = uint256(p);
        // The attachment/limit clamp: a layer can never pay more than the capital locked for it.
        if (payout > L.limit) payout = L.limit;

        // The waterfall: the first-loss vault absorbs the first `juniorLimit` of the payout, the
        // senior vault the rest. `payoutJunior + payoutSenior == payout` always, and
        // `payoutSenior > 0` only once the first-loss slice has paid its full `juniorLimit`.
        uint256 payoutJunior = payout < L.juniorLimit ? payout : L.juniorLimit;
        uint256 payoutSenior = payout - payoutJunior;

        L.payout = payout;
        L.payoutJunior = payoutJunior;
        L.payoutSenior = payoutSenior;
        L.state = State.Settled;
        emit Settled(id, payout, payoutJunior, payoutSenior);

        // C1: moves this layer's reservation out of each vault's `locked` entirely. The unused
        // remainder becomes free capacity again in that vault; the slice's own payout moves into
        // its `owed` (still excluded from totalAssets(), now earmarked for `payOut`/claim).
        Book storage b = books[L.book];
        b.firstLoss.settle(L.juniorLimit - payoutJunior, payoutJunior, L.fridayCutoff);
        b.senior.settle((L.limit - L.juniorLimit) - payoutSenior, payoutSenior, L.fridayCutoff);
        // M1: each slice's premium was withheld from its own vault's share pricing since bind
        // (Capacity.pendingPremium); now that this weekend's risk has actually played out, it
        // vests to whoever holds shares in that vault.
        b.firstLoss.releasePremium(L.premiumJunior);
        b.senior.releasePremium(L.premiumSenior);
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
