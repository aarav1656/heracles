// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPricer} from "./IPricer.sol";

/// @notice Local, minimal Chainlink aggregator interface (mirrors Treaty.sol's own local
/// `AggregatorV3Interface`; not imported from Treaty so Pricer has zero dependency on it).
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

/// @notice Weekend-gap layer pricer, Solidity implementation of IPricer.
///
/// Per-market scenario tables (docs/judging/heracles.md item 5, evidence/auction-and-pricing.md
/// section 2): four independently sourced 504-scenario Friday-close-to-Monday-open weekend gap
/// tables (basis points), one each for NVDA, AAPL, SPY and TSLA, fetched from
/// api.nasdaq.com's free historical-bars endpoint and re-derivable with
/// `scripts/generate_gap_tables.py` (evidence/gap-tables/{TICKER}.json holds the full detail
/// including source URL and fetch method for every scenario). Table id 0 is NVDA, 1 AAPL, 2 SPY,
/// 3 TSLA. `marketTableIds[i]` (a constructor-supplied array, docs/security/capacity-review.md
/// "Re-review (2026-09-28)" P2) picks market i's table explicitly, so the market a table prices
/// no longer depends on `exposure[i]`/`feeds[i]`'s array position. There is no positional or
/// id-value fallback (P2 re-review, docs/security/capacity-review.md): the constructor reverts
/// `BadTableId()` if `tableIds` is empty or any entry is not 0-3, and `tableIdAt(i)` reverts
/// `MissingTable()` if `i` is past `marketTableIds`'s length, so a quote spanning more markets
/// than the deploy configured reverts instead of silently pricing the extra market on NVDA.
///
/// Volatility scale (item 5): before being applied, every scenario in a market's table is
/// scaled by that market's own realised volatility, read live from its Chainlink feed's last
/// `VOL_ROUNDS` rounds (`_volScalePpm`), relative to `NORMAL_ROUND_MOVE_BPS` (the ~0.5% round-
/// to-round deviation threshold measured live against the real Arbitrum One SPY/USD feed,
/// docs/judging/heracles.md section B.2), bounded to [`MIN_SCALE_PPM`, `MAX_SCALE_PPM`]. This
/// makes the quote react to current market conditions instead of always replaying the same
/// static historical distribution. It is a relative regime-scaling heuristic (scale the whole
/// historical distribution up or down by how much livelier or calmer the feed has been lately),
/// not a rigorous annualised-vol/Black-Scholes model; see docs/pricing.md Limitations. It is
/// implemented identically here and in the Stylus twin (`pricer/src/lib.rs`) because the added
/// cost is dominated by the `CALL` opcode to each feed, which costs the same in both languages;
/// unlike the historical-scenario loop, this part gives Stylus no advantage, so keeping the
/// Solidity reference twin exact stays cheap and honest.
///
/// Pricing formula (item 2, docs/security/capacity-review.md "Pricing (item 2)"): `premium = el
/// + RISK_LOAD_PPM * (tvar95 - el) + CAPITAL_CHARGE_ANNUAL_PPM * limit * LOCK_DAYS /
/// DAYS_PER_YEAR`, replacing the old `el + c*(tvar95-el)` cost-of-capital-only load, which
/// priced writers a Sharpe ratio near zero. The first term is a flat per-weekend tail-risk load
/// (not prorated by time, since a weekend gap prices as a discrete per-bind event, not a
/// continuous-time process); the second is the risk-free rate on the fully collateralised limit
/// for the real capital-lock duration (see docs/pricing.md for the sourcing and the before/after
/// numbers).
///
/// quote() computes, per scenario s and market i: scaledGap = table[i][s] * volScalePpm[i] /
/// 1e6, portfolioLoss(s) = sum_i max(0, -(exposure[i] * scaledGap) / 10000), payout(s) =
/// min(limit, max(0, portfolioLoss(s) - retention)), then el = mean(payout), tvar95 = mean of
/// the worst 5% (25 of 504) of payout(s), and premium = el + RISK_LOAD_PPM*(tvar95-el) +
/// CAPITAL_CHARGE_ANNUAL_PPM*limit*LOCK_DAYS/DAYS_PER_YEAR, all in USDG's native 6-decimal fixed
/// point (no WAD). This is the reference/fallback implementation; the product path calls the
/// identical algorithm on the Rust/Stylus PricerStylus contract through the same IPricer
/// interface (gas ratio: docs/pricing.md, remeasured at this build's scale).
contract Pricer is IPricer {
    uint256 internal constant SCENARIOS = 504;
    uint256 internal constant TAIL = 25; // ceil(504 * 0.05), the worst 5% of scenarios
    int256 internal constant BPS = 10000;
    uint256 internal constant PPM = 1_000_000;

    /// Per-weekend tail-risk load, docs/security/capacity-review.md "Pricing (item 2)": a flat
    /// 3% of (TVaR95 - EL), not prorated by time.
    uint256 internal constant RISK_LOAD_PPM = 30_000; // 3.00%
    /// Risk-free rate on the fully collateralised limit for the real capital-lock duration
    /// (LOCK_DAYS / DAYS_PER_YEAR), replacing the old cost-of-capital-only load. Capital is
    /// locked for the real bind-to-settlement window (up to about 7.5 days, Treaty.sol's own
    /// bind-to-Monday-expiry cutoff), so LOCK_DAYS = 7 prices the full real lock instead of the
    /// old WEEKEND_HOURS = 66, which undercounted it (docs/security/capacity-review.md Low/Info).
    uint256 internal constant CAPITAL_CHARGE_ANNUAL_PPM = 40_000; // 4.00%
    uint256 internal constant LOCK_DAYS = 7;
    uint256 internal constant DAYS_PER_YEAR = 365;

    /// Realised-volatility scale (item 5): sampled over the feed's last VOL_ROUNDS rounds,
    /// relative to NORMAL_ROUND_MOVE_BPS, bounded to [MIN_SCALE_PPM, MAX_SCALE_PPM].
    uint256 internal constant VOL_ROUNDS = 8;
    /// The live-measured Chainlink deviation threshold on the real Arbitrum One SPY/USD feed
    /// (docs/judging/heracles.md section B.2, "roughly 0.5%, inferred from consecutive Sep 16
    /// rounds 755.40 to 751.61"): a feed moving at exactly its own deviation threshold per round
    /// is defined as the 1.0x "normal" baseline.
    uint256 internal constant NORMAL_ROUND_MOVE_BPS = 50;
    /// Floors at 1.0x (docs/security/capacity-review.md P4): the vol scale may only raise a
    /// quote above the static historical table, never cut it below, closing the buyer's
    /// bind-timing option (a heartbeat-quiet weekday priced a materially cheaper premium than a
    /// livelier one on the same layer).
    uint256 internal constant MIN_SCALE_PPM = 1_000_000; // floor 1.0x
    uint256 internal constant MAX_SCALE_PPM = 3_000_000; // cap 3.0x

    int32[504] internal gapsNVDA;
    int32[504] internal gapsAAPL;
    int32[504] internal gapsSPY;
    int32[504] internal gapsTSLA;

    /// Explicit per-market table id (docs/security/capacity-review.md P2): `marketTableIds[i]`
    /// picks market i's table by id, not by its position in `exposure`/`feeds`. Any `i` past
    /// this array's length reverts (`tableIdAt`), there is no positional fallback.
    uint8[] internal marketTableIds;

    error EmptyExposure();
    error BadFeeds();
    /// A configured table id is not a real table (must be 0-3). Reverts the constructor.
    error BadTableId();
    /// A market index has no entry in `marketTableIds` (docs/security/capacity-review.md
    /// "Re-review (2026-09-28)" P2): the deploy did not configure a table for every market a
    /// quote spans, so pricing it would have to guess. Reverts `tableIdAt`, and transitively
    /// `_tableFor`/`priceCore`/`quote` for the same index.
    error MissingTable();

    constructor(uint8[] memory tableIds) {
        if (tableIds.length == 0) revert BadTableId();
        for (uint256 i; i < tableIds.length; i++) {
            if (tableIds[i] > 3) revert BadTableId();
        }
        marketTableIds = tableIds;
        gapsNVDA = [int32(0),int32(53),int32(-2),int32(68),int32(33),int32(294),int32(14),int32(78),int32(-31),int32(174),int32(-215),int32(-71),int32(208),int32(-219),int32(39),int32(-42),int32(-20),int32(-76),int32(-33),int32(-20),int32(93),int32(73),int32(-150),int32(42),int32(67),int32(-176),int32(2),int32(3),int32(126),int32(42),int32(46),int32(130),int32(130),int32(131),int32(-46),int32(-249),int32(118),int32(86),int32(34),int32(203),int32(84),int32(17),int32(33),int32(70),int32(238),int32(61),int32(47),int32(-122),int32(113),int32(279),int32(-70),int32(113),int32(82),int32(62),int32(45),int32(0),int32(-71),int32(0),int32(30),int32(16),int32(120),int32(30),int32(86),int32(-115),int32(118),int32(232),int32(48),int32(14),int32(-24),int32(-279),int32(141),int32(37),int32(76),int32(-86),int32(68),int32(-92),int32(216),int32(119),int32(12),int32(31),int32(29),int32(177),int32(60),int32(160),int32(-29),int32(54),int32(-20),int32(-67),int32(-171),int32(-119),int32(121),int32(-45),int32(-43),int32(23),int32(-20),int32(14),int32(-67),int32(44),int32(-19),int32(34),int32(-37),int32(-47),int32(112),int32(-125),int32(-22),int32(92),int32(287),int32(-25),int32(-180),int32(-161),int32(337),int32(561),int32(-123),int32(-82),int32(-238),int32(131),int32(170),int32(-142),int32(-78),int32(-1474),int32(44),int32(-120),int32(-27),int32(212),int32(99),int32(63),int32(75),int32(-92),int32(206),int32(-64),int32(-16),int32(18),int32(-410),int32(-315),int32(-254),int32(49),int32(33),int32(155),int32(-5),int32(57),int32(508),int32(-150),int32(51),int32(51),int32(-17),int32(-458),int32(-136),int32(286),int32(195),int32(-175),int32(70),int32(-166),int32(0),int32(61),int32(144),int32(-19),int32(130),int32(86),int32(161),int32(-1),int32(-15),int32(244),int32(-13),int32(-43),int32(85),int32(48),int32(-37),int32(-159),int32(137),int32(-59),int32(-489),int32(-31),int32(36),int32(-143),int32(-812),int32(253),int32(-983),int32(-1181),int32(-2),int32(104),int32(464),int32(-174),int32(187),int32(-67),int32(-6),int32(318),int32(145),int32(-48),int32(-48),int32(-131),int32(42),int32(16),int32(110),int32(71),int32(37),int32(111),int32(120),int32(248),int32(158),int32(27),int32(-704),int32(753),int32(-217),int32(129),int32(133),int32(165),int32(66),int32(-120),int32(99),int32(-7),int32(-94),int32(64),int32(3),int32(32),int32(57),int32(-149),int32(107),int32(122),int32(51),int32(49),int32(100),int32(69),int32(-102),int32(117),int32(-9),int32(7),int32(52),int32(-15),int32(-77),int32(-236),int32(-53),int32(77),int32(-17),int32(-60),int32(147),int32(16),int32(-4),int32(45),int32(-109),int32(174),int32(122),int32(95),int32(-135),int32(-126),int32(103),int32(39),int32(-26),int32(74),int32(86),int32(-4),int32(92),int32(-344),int32(-168),int32(-115),int32(-123),int32(-52),int32(109),int32(32),int32(133),int32(53),int32(161),int32(274),int32(-265),int32(17),int32(-178),int32(137),int32(-244),int32(-253),int32(-447),int32(150),int32(22),int32(-6),int32(-257),int32(-68),int32(-52),int32(-105),int32(20),int32(23),int32(6),int32(-391),int32(-160),int32(-4),int32(-343),int32(-111),int32(-252),int32(90),int32(224),int32(-574),int32(374),int32(109),int32(-240),int32(-197),int32(343),int32(-173),int32(10),int32(-783),int32(-4),int32(-201),int32(-148),int32(62),int32(-13),int32(-141),int32(-20),int32(171),int32(-32),int32(259),int32(34),int32(-40),int32(51),int32(-67),int32(-170),int32(-150),int32(-117),int32(21),int32(1),int32(-87),int32(162),int32(286),int32(0),int32(126),int32(-204),int32(-139),int32(128),int32(-181),int32(165),int32(0),int32(-93),int32(-43),int32(22),int32(-96),int32(-72),int32(-39),int32(33),int32(-55),int32(59),int32(-116),int32(423),int32(-106),int32(111),int32(72),int32(60),int32(51),int32(36),int32(180),int32(95),int32(1),int32(96),int32(-90),int32(276),int32(101),int32(-59),int32(126),int32(-262),int32(-5),int32(122),int32(-201),int32(-88),int32(-38),int32(145),int32(62),int32(-3),int32(3),int32(5),int32(-147),int32(-3),int32(104),int32(28),int32(-56),int32(85),int32(56),int32(94),int32(33),int32(312),int32(65),int32(-92),int32(112),int32(225),int32(-126),int32(290),int32(-37),int32(79),int32(103),int32(250),int32(-16),int32(68),int32(67),int32(137),int32(355),int32(364),int32(-43),int32(84),int32(-263),int32(-6),int32(132),int32(102),int32(205),int32(56),int32(-1418),int32(150),int32(-24),int32(15),int32(-281),int32(199),int32(-194),int32(47),int32(-255),int32(6),int32(124),int32(9),int32(103),int32(134),int32(71),int32(-175),int32(3),int32(42),int32(-244),int32(-5),int32(117),int32(-159),int32(285),int32(-436),int32(105),int32(-1249),int32(-443),int32(19),int32(174),int32(158),int32(-113),int32(-248),int32(88),int32(185),int32(-414),int32(-726),int32(287),int32(-119),int32(-139),int32(456),int32(-222),int32(218),int32(27),int32(104),int32(97),int32(-94),int32(41),int32(27),int32(20),int32(30),int32(83),int32(-36),int32(8),int32(20),int32(-240),int32(32),int32(-121),int32(-78),int32(125),int32(-113),int32(262),int32(-5),int32(200),int32(276),int32(370),int32(-221),int32(34),int32(-127),int32(13),int32(167),int32(162),int32(-148),int32(154),int32(-89),int32(-233),int32(-27),int32(-206),int32(-62),int32(-58),int32(83),int32(-123),int32(-56),int32(151),int32(264),int32(75),int32(-138),int32(-84),int32(66),int32(53),int32(-54),int32(202),int32(56),int32(217),int32(248),int32(182),int32(69),int32(-115),int32(151),int32(66),int32(-152),int32(-25),int32(36),int32(38),int32(61),int32(119),int32(-323),int32(30)];
        gapsAAPL = [int32(-30),int32(84),int32(-26),int32(43),int32(-6),int32(114),int32(-66),int32(5),int32(-32),int32(9),int32(-58),int32(-15),int32(0),int32(-2),int32(3),int32(-59),int32(0),int32(-84),int32(4),int32(73),int32(38),int32(35),int32(-30),int32(-21),int32(29),int32(-89),int32(3),int32(18),int32(86),int32(101),int32(5),int32(-6),int32(61),int32(-12),int32(-71),int32(-217),int32(98),int32(61),int32(60),int32(-5),int32(-15),int32(21),int32(27),int32(43),int32(117),int32(0),int32(18),int32(-18),int32(118),int32(14),int32(-125),int32(9),int32(33),int32(58),int32(41),int32(52),int32(-8),int32(-67),int32(8),int32(5),int32(84),int32(-10),int32(52),int32(-241),int32(55),int32(-37),int32(46),int32(-65),int32(-79),int32(-87),int32(134),int32(-22),int32(48),int32(-57),int32(17),int32(-39),int32(190),int32(89),int32(17),int32(67),int32(-12),int32(73),int32(22),int32(91),int32(-52),int32(73),int32(-18),int32(-51),int32(-82),int32(-70),int32(81),int32(10),int32(-40),int32(48),int32(0),int32(8),int32(24),int32(46),int32(34),int32(-16),int32(-76),int32(-39),int32(98),int32(-93),int32(-43),int32(22),int32(134),int32(-153),int32(-268),int32(-182),int32(113),int32(329),int32(-207),int32(-2),int32(-171),int32(147),int32(30),int32(-95),int32(-26),int32(-125),int32(53),int32(38),int32(-42),int32(69),int32(41),int32(149),int32(-17),int32(24),int32(89),int32(-29),int32(-15),int32(5),int32(-352),int32(-480),int32(-290),int32(-3),int32(30),int32(87),int32(8),int32(-12),int32(265),int32(-167),int32(39),int32(52),int32(35),int32(-296),int32(-68),int32(200),int32(159),int32(-111),int32(74),int32(-47),int32(56),int32(95),int32(-33),int32(-55),int32(47),int32(34),int32(59),int32(-71),int32(2),int32(36),int32(1),int32(-26),int32(67),int32(39),int32(-12),int32(-122),int32(42),int32(-48),int32(-259),int32(-168),int32(-183),int32(-295),int32(-504),int32(326),int32(-875),int32(-1296),int32(-51),int32(121),int32(393),int32(-171),int32(-41),int32(3),int32(-65),int32(177),int32(145),int32(-6),int32(-38),int32(-164),int32(46),int32(-11),int32(140),int32(9),int32(118),int32(183),int32(134),int32(101),int32(348),int32(222),int32(-580),int32(243),int32(-215),int32(243),int32(79),int32(264),int32(79),int32(-90),int32(23),int32(152),int32(-29),int32(-14),int32(33),int32(5),int32(16),int32(-129),int32(-217),int32(50),int32(288),int32(136),int32(-53),int32(9),int32(-143),int32(205),int32(-40),int32(31),int32(28),int32(36),int32(-36),int32(-48),int32(38),int32(44),int32(-61),int32(-49),int32(46),int32(38),int32(22),int32(37),int32(-12),int32(23),int32(8),int32(76),int32(-180),int32(-20),int32(34),int32(4),int32(-38),int32(8),int32(27),int32(43),int32(111),int32(-155),int32(-99),int32(-62),int32(-44),int32(-96),int32(-1),int32(-54),int32(9),int32(25),int32(70),int32(163),int32(151),int32(93),int32(-167),int32(15),int32(-179),int32(-90),int32(-147),int32(-10),int32(27),int32(-75),int32(-139),int32(-109),int32(12),int32(-212),int32(-29),int32(-146),int32(15),int32(-81),int32(-41),int32(-60),int32(-150),int32(-106),int32(15),int32(-38),int32(113),int32(-311),int32(141),int32(73),int32(-83),int32(-93),int32(38),int32(-5),int32(-92),int32(62),int32(-34),int32(-107),int32(-151),int32(42),int32(141),int32(-92),int32(-51),int32(1),int32(24),int32(194),int32(-6),int32(-166),int32(-92),int32(-49),int32(-75),int32(-201),int32(-3),int32(38),int32(45),int32(-36),int32(27),int32(65),int32(5),int32(18),int32(-67),int32(-125),int32(-4),int32(-154),int32(68),int32(182),int32(-47),int32(5),int32(-19),int32(-38),int32(-7),int32(-1),int32(-24),int32(-63),int32(34),int32(-67),int32(87),int32(93),int32(17),int32(-28),int32(8),int32(-10),int32(-74),int32(63),int32(77),int32(12),int32(8),int32(10),int32(33),int32(83),int32(-62),int32(106),int32(84),int32(-34),int32(1),int32(-38),int32(-117),int32(-114),int32(48),int32(-15),int32(-31),int32(11),int32(-3),int32(-66),int32(-133),int32(-75),int32(1),int32(-279),int32(50),int32(-202),int32(39),int32(-21),int32(124),int32(-23),int32(-29),int32(-15),int32(-195),int32(129),int32(171),int32(-100),int32(-32),int32(-67),int32(31),int32(240),int32(-56),int32(130),int32(-29),int32(81),int32(34),int32(1),int32(41),int32(11),int32(70),int32(33),int32(258),int32(120),int32(-46),int32(-945),int32(-8),int32(-15),int32(-4),int32(-20),int32(0),int32(-268),int32(-38),int32(99),int32(-101),int32(51),int32(-23),int32(83),int32(-86),int32(-86),int32(11),int32(69),int32(-3),int32(-42),int32(-6),int32(11),int32(-131),int32(39),int32(-140),int32(-260),int32(56),int32(-255),int32(85),int32(-18),int32(-25),int32(-2),int32(-148),int32(-8),int32(125),int32(-41),int32(-593),int32(671),int32(34),int32(-110),int32(627),int32(-159),int32(155),int32(-28),int32(23),int32(43),int32(31),int32(46),int32(-58),int32(44),int32(7),int32(105),int32(-62),int32(5),int32(-56),int32(-124),int32(-16),int32(125),int32(114),int32(-35),int32(-1),int32(168),int32(142),int32(78),int32(2),int32(18),int32(-132),int32(-22),int32(-30),int32(-23),int32(67),int32(-30),int32(-26),int32(-14),int32(-8),int32(-110),int32(139),int32(21),int32(-8),int32(89),int32(-41),int32(-67),int32(-69),int32(79),int32(241),int32(51),int32(-29),int32(4),int32(-183),int32(-17),int32(-46),int32(0),int32(24),int32(-78),int32(46),int32(103),int32(104),int32(54),int32(-7),int32(46),int32(22),int32(-207),int32(9),int32(69),int32(-3),int32(-90),int32(76),int32(-25)];
        gapsSPY = [int32(-22),int32(52),int32(-1),int32(48),int32(18),int32(139),int32(28),int32(31),int32(-16),int32(44),int32(-5),int32(9),int32(14),int32(68),int32(-13),int32(-33),int32(-17),int32(-35),int32(-20),int32(25),int32(18),int32(-4),int32(-39),int32(-3),int32(0),int32(-83),int32(3),int32(7),int32(110),int32(25),int32(2),int32(21),int32(25),int32(-15),int32(-8),int32(-12),int32(39),int32(32),int32(45),int32(-7),int32(-4),int32(-4),int32(19),int32(3),int32(60),int32(-3),int32(25),int32(-23),int32(59),int32(17),int32(-12),int32(10),int32(10),int32(10),int32(14),int32(-25),int32(-6),int32(-30),int32(11),int32(2),int32(70),int32(3),int32(60),int32(-17),int32(37),int32(-4),int32(51),int32(-9),int32(-23),int32(-73),int32(89),int32(-40),int32(44),int32(-50),int32(12),int32(-31),int32(158),int32(64),int32(70),int32(24),int32(26),int32(33),int32(18),int32(62),int32(-68),int32(34),int32(9),int32(-59),int32(-47),int32(-65),int32(41),int32(2),int32(-8),int32(3),int32(1),int32(11),int32(18),int32(47),int32(-16),int32(40),int32(-2),int32(-22),int32(48),int32(-27),int32(-14),int32(27),int32(131),int32(20),int32(-21),int32(-25),int32(96),int32(168),int32(-8),int32(-41),int32(-69),int32(73),int32(12),int32(-82),int32(-62),int32(-90),int32(2),int32(27),int32(-32),int32(57),int32(42),int32(29),int32(9),int32(-14),int32(79),int32(-16),int32(3),int32(3),int32(-163),int32(-197),int32(-62),int32(11),int32(1),int32(60),int32(9),int32(8),int32(126),int32(-49),int32(16),int32(15),int32(-4),int32(-155),int32(-57),int32(116),int32(85),int32(-64),int32(37),int32(-42),int32(-24),int32(19),int32(-30),int32(-12),int32(49),int32(44),int32(56),int32(-49),int32(-8),int32(33),int32(9),int32(-14),int32(60),int32(27),int32(3),int32(-60),int32(21),int32(-32),int32(-175),int32(50),int32(-29),int32(-32),int32(-310),int32(66),int32(-745),int32(-1045),int32(-27),int32(90),int32(389),int32(-141),int32(76),int32(-72),int32(-72),int32(236),int32(220),int32(-23),int32(28),int32(-203),int32(-21),int32(45),int32(80),int32(-9),int32(23),int32(55),int32(15),int32(33),int32(78),int32(-7),int32(-171),int32(103),int32(-150),int32(137),int32(66),int32(79),int32(39),int32(-106),int32(112),int32(394),int32(80),int32(55),int32(-23),int32(-22),int32(64),int32(-114),int32(-89),int32(70),int32(21),int32(99),int32(40),int32(34),int32(-76),int32(138),int32(27),int32(7),int32(14),int32(-40),int32(-16),int32(-24),int32(17),int32(51),int32(9),int32(-29),int32(58),int32(60),int32(0),int32(3),int32(45),int32(13),int32(1),int32(-2),int32(-119),int32(-14),int32(42),int32(-1),int32(-31),int32(41),int32(16),int32(-8),int32(72),int32(-148),int32(-25),int32(-29),int32(-16),int32(-43),int32(26),int32(23),int32(25),int32(29),int32(43),int32(111),int32(60),int32(-12),int32(-117),int32(28),int32(-73),int32(-107),int32(-136),int32(-16),int32(18),int32(-12),int32(-54),int32(-131),int32(-14),int32(20),int32(-4),int32(-14),int32(5),int32(-77),int32(-56),int32(2),int32(-152),int32(-43),int32(82),int32(-41),int32(103),int32(-255),int32(165),int32(25),int32(-141),int32(-73),int32(84),int32(17),int32(-69),int32(43),int32(-55),int32(-121),int32(-77),int32(23),int32(54),int32(-86),int32(-42),int32(109),int32(32),int32(178),int32(43),int32(-66),int32(36),int32(-46),int32(-35),int32(-81),int32(-73),int32(21),int32(5),int32(-3),int32(51),int32(59),int32(-1),int32(21),int32(-71),int32(-62),int32(17),int32(-103),int32(88),int32(21),int32(-106),int32(21),int32(60),int32(-13),int32(-2),int32(-5),int32(-11),int32(8),int32(15),int32(0),int32(48),int32(8),int32(24),int32(-46),int32(-14),int32(-8),int32(-8),int32(-3),int32(26),int32(11),int32(43),int32(-21),int32(24),int32(52),int32(-10),int32(61),int32(-7),int32(-29),int32(-20),int32(-46),int32(54),int32(-38),int32(70),int32(18),int32(-31),int32(-6),int32(-14),int32(-76),int32(-11),int32(35),int32(9),int32(-66),int32(11),int32(-30),int32(33),int32(7),int32(-13),int32(-1),int32(-36),int32(9),int32(-16),int32(-24),int32(82),int32(-27),int32(14),int32(84),int32(54),int32(36),int32(48),int32(33),int32(2),int32(16),int32(31),int32(-16),int32(-13),int32(-3),int32(26),int32(14),int32(36),int32(73),int32(29),int32(-399),int32(23),int32(8),int32(19),int32(-57),int32(79),int32(-5),int32(19),int32(-18),int32(-29),int32(28),int32(-13),int32(61),int32(2),int32(27),int32(8),int32(67),int32(7),int32(-2),int32(30),int32(-4),int32(-120),int32(73),int32(-81),int32(52),int32(-216),int32(-152),int32(54),int32(19),int32(35),int32(34),int32(-145),int32(0),int32(121),int32(-105),int32(-318),int32(189),int32(14),int32(-74),int32(304),int32(-103),int32(120),int32(-28),int32(10),int32(57),int32(13),int32(40),int32(-7),int32(19),int32(6),int32(64),int32(4),int32(-9),int32(-20),int32(-117),int32(21),int32(34),int32(-23),int32(38),int32(36),int32(117),int32(44),int32(81),int32(53),int32(93),int32(-33),int32(56),int32(-67),int32(13),int32(58),int32(49),int32(-40),int32(49),int32(-49),int32(-147),int32(18),int32(-35),int32(-17),int32(-24),int32(-23),int32(-106),int32(-89),int32(92),int32(146),int32(95),int32(-30),int32(0),int32(-11),int32(-8),int32(-16),int32(9),int32(59),int32(-15),int32(79),int32(136),int32(103),int32(-33),int32(51),int32(81),int32(32),int32(-9),int32(-2),int32(-12),int32(-26),int32(-15),int32(-69),int32(60)];
        gapsTSLA = [int32(405),int32(241),int32(27),int32(46),int32(126),int32(159),int32(-30),int32(1),int32(-59),int32(57),int32(32),int32(0),int32(72),int32(55),int32(-2),int32(-44),int32(46),int32(-17),int32(-13),int32(56),int32(118),int32(-344),int32(-145),int32(46),int32(-34),int32(-97),int32(309),int32(219),int32(118),int32(26),int32(83),int32(-198),int32(63),int32(26),int32(-40),int32(19),int32(97),int32(84),int32(239),int32(-10),int32(-68),int32(56),int32(13),int32(12),int32(189),int32(-47),int32(-22),int32(-45),int32(232),int32(12),int32(59),int32(42),int32(-203),int32(-51),int32(138),int32(-53),int32(30),int32(-94),int32(-40),int32(-73),int32(-1),int32(-16),int32(42),int32(-42),int32(21),int32(-18),int32(39),int32(-18),int32(-88),int32(-168),int32(184),int32(-30),int32(41),int32(-81),int32(44),int32(-151),int32(192),int32(36),int32(-45),int32(36),int32(-16),int32(116),int32(75),int32(163),int32(-12),int32(86),int32(153),int32(-77),int32(-105),int32(499),int32(100),int32(-225),int32(-374),int32(-43),int32(-78),int32(159),int32(-452),int32(-149),int32(-156),int32(381),int32(-175),int32(-21),int32(1549),int32(98),int32(11),int32(26),int32(199),int32(-171),int32(-61),int32(57),int32(-25),int32(272),int32(57),int32(-101),int32(-196),int32(117),int32(127),int32(-141),int32(85),int32(-139),int32(25),int32(190),int32(-43),int32(109),int32(113),int32(-22),int32(21),int32(-182),int32(99),int32(99),int32(35),int32(31),int32(-196),int32(-314),int32(-390),int32(30),int32(19),int32(281),int32(26),int32(62),int32(302),int32(-80),int32(119),int32(22),int32(-42),int32(-202),int32(-86),int32(194),int32(104),int32(-68),int32(112),int32(33),int32(-26),int32(36),int32(-70),int32(0),int32(54),int32(-18),int32(48),int32(202),int32(21),int32(339),int32(-16),int32(21),int32(116),int32(153),int32(-37),int32(-57),int32(321),int32(387),int32(-404),int32(355),int32(694),int32(520),int32(-688),int32(648),int32(-1394),int32(-1411),int32(142),int32(-80),int32(650),int32(-281),int32(172),int32(-5),int32(-353),int32(358),int32(216),int32(275),int32(376),int32(-187),int32(-9),int32(97),int32(740),int32(121),int32(127),int32(129),int32(-32),int32(159),int32(372),int32(44),int32(-1490),int32(221),int32(248),int32(424),int32(199),int32(184),int32(149),int32(-214),int32(154),int32(222),int32(11),int32(284),int32(281),int32(98),int32(148),int32(-414),int32(-348),int32(141),int32(99),int32(262),int32(205),int32(23),int32(-239),int32(216),int32(43),int32(5),int32(454),int32(-50),int32(128),int32(-273),int32(159),int32(-79),int32(-111),int32(-241),int32(12),int32(41),int32(-121),int32(38),int32(19),int32(-3),int32(41),int32(80),int32(-222),int32(118),int32(186),int32(158),int32(-169),int32(76),int32(39),int32(88),int32(54),int32(-328),int32(-16),int32(275),int32(27),int32(104),int32(449),int32(278),int32(-592),int32(-153),int32(222),int32(176),int32(-133),int32(-157),int32(-235),int32(861),int32(-263),int32(-219),int32(-415),int32(311),int32(5),int32(18),int32(-267),int32(63),int32(215),int32(-185),int32(106),int32(539),int32(44),int32(-440),int32(-259),int32(-115),int32(-337),int32(-32),int32(-134),int32(187),int32(419),int32(-390),int32(362),int32(149),int32(-188),int32(53),int32(203),int32(-1),int32(139),int32(237),int32(59),int32(-160),int32(-183),int32(91),int32(35),int32(-107),int32(-127),int32(-405),int32(39),int32(246),int32(-402),int32(-102),int32(57),int32(-163),int32(-241),int32(-159),int32(-278),int32(-165),int32(251),int32(-459),int32(-382),int32(522),int32(269),int32(184),int32(8),int32(159),int32(-126),int32(-159),int32(262),int32(38),int32(-345),int32(-114),int32(210),int32(-364),int32(71),int32(-26),int32(-69),int32(215),int32(-19),int32(31),int32(359),int32(179),int32(145),int32(37),int32(-255),int32(562),int32(74),int32(186),int32(-160),int32(39),int32(-95),int32(-286),int32(281),int32(167),int32(0),int32(635),int32(-118),int32(-61),int32(-216),int32(-200),int32(-43),int32(-94),int32(96),int32(183),int32(44),int32(-11),int32(61),int32(-129),int32(-45),int32(11),int32(77),int32(64),int32(-57),int32(-173),int32(3),int32(130),int32(-194),int32(-75),int32(-191),int32(17),int32(-193),int32(6),int32(394),int32(-121),int32(269),int32(-47),int32(-441),int32(1196),int32(144),int32(91),int32(6),int32(-158),int32(3),int32(-80),int32(-5),int32(107),int32(159),int32(-151),int32(312),int32(209),int32(232),int32(-1081),int32(-49),int32(44),int32(-71),int32(54),int32(260),int32(-43),int32(183),int32(-55),int32(-43),int32(107),int32(-82),int32(30),int32(-178),int32(781),int32(624),int32(215),int32(209),int32(216),int32(111),int32(236),int32(-284),int32(311),int32(-292),int32(144),int32(-290),int32(-443),int32(-150),int32(-23),int32(10),int32(251),int32(-386),int32(-197),int32(377),int32(-540),int32(-654),int32(240),int32(141),int32(-92),int32(796),int32(-391),int32(236),int32(-85),int32(-311),int32(184),int32(167),int32(-115),int32(135),int32(144),int32(76),int32(213),int32(162),int32(-28),int32(-33),int32(-169),int32(108),int32(687),int32(118),int32(90),int32(254),int32(243),int32(104),int32(144),int32(-12),int32(235),int32(-139),int32(283),int32(-113),int32(-166),int32(228),int32(180),int32(-130),int32(226),int32(-85),int32(-186),int32(-90),int32(-212),int32(-29),int32(-122),int32(-110),int32(-296),int32(-168),int32(128),int32(139),int32(111),int32(32),int32(49),int32(-112),int32(-15),int32(-145),int32(-70),int32(100),int32(-190),int32(136),int32(146),int32(55),int32(-77),int32(137),int32(7),int32(-8),int32(-60),int32(-46),int32(-40),int32(-44),int32(85),int32(-155),int32(202)];
    }

    /// Table id 0 NVDA, 1 AAPL, 2 SPY, 3 TSLA. `marketTableIds` picks market i's table
    /// explicitly (docs/security/capacity-review.md P2); reverts `MissingTable()` if it has no
    /// entry at `i` rather than defaulting by position, closing the single root path every
    /// caller (`_tableFor`, and external callers like Deploy.s.sol's sanity check) routes
    /// through.
    function tableIdAt(uint256 i) public view returns (uint8) {
        if (i >= marketTableIds.length) revert MissingTable();
        return marketTableIds[i];
    }

    function _tableFor(uint256 i) internal view returns (int32[504] storage) {
        uint8 id = tableIdAt(i);
        if (id == 1) return gapsAAPL;
        if (id == 2) return gapsSPY;
        if (id == 3) return gapsTSLA;
        return gapsNVDA;
    }

    /// Realised volatility over the feed's last VOL_ROUNDS rounds, as a scale in parts-per-
    /// million relative to NORMAL_ROUND_MOVE_BPS, bounded to [MIN_SCALE_PPM, MAX_SCALE_PPM].
    /// Returns PPM (1.0x, neutral) if the feed has too little history yet. Walks the raw round
    /// id backwards by 1 per step; this does not track Chainlink's phaseId the way Treaty's
    /// `_latestInPhase` does (docs/pricing.md Limitations), so a phase change in the last
    /// VOL_ROUNDS rounds truncates the sample early via the try/catch below rather than
    /// crossing into the wrong phase's round ids.
    function _volScalePpm(address feedAddr) internal view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(feedAddr);
        (uint80 latestId, int256 latestAnswer,,,) = feed.latestRoundData();
        if (latestAnswer <= 0 || latestId < VOL_ROUNDS) return PPM;

        int256 prevAnswer = latestAnswer;
        uint256 sumBps;
        uint256 n;
        for (uint256 k = 1; k <= VOL_ROUNDS; k++) {
            try feed.getRoundData(latestId - uint80(k)) returns (uint80, int256 answer, uint256, uint256, uint80) {
                if (answer <= 0) break;
                uint256 diff = prevAnswer > answer ? uint256(prevAnswer - answer) : uint256(answer - prevAnswer);
                sumBps += (diff * 10000) / uint256(prevAnswer);
                prevAnswer = answer;
                n++;
            } catch {
                break;
            }
        }
        if (n == 0) return PPM;

        uint256 scale = (sumBps / n) * PPM / NORMAL_ROUND_MOVE_BPS;
        if (scale < MIN_SCALE_PPM) scale = MIN_SCALE_PPM;
        if (scale > MAX_SCALE_PPM) scale = MAX_SCALE_PPM;
        return scale;
    }

    /// Deterministic pricing core: given exposure and an already-known per-market volatility
    /// scale (parts-per-million, 1_000_000 = 1.0x = the stored historical table unscaled), no
    /// feed reads happen here at all. `quote()` is a thin wrapper that reads live feeds to
    /// compute `volScalePpm` and then calls this. Exposed `public` (not `internal`) specifically
    /// so it is a fuzzable, feed-independent parity target: contracts/test/PricerParity.t.sol
    /// fuzzes this function directly against the Rust twin's `price_core` (same split, called
    /// via FFI), which is what makes an exact, feed-independent Solidity == Stylus parity check
    /// possible at all (live feed state can never be made identical across two toolchains).
    function priceCore(int256[] memory exposure, uint256[] memory volScalePpm, uint256 retention, uint256 limit)
        public
        view
        returns (uint256 premium, uint256 el, uint256 tvar95)
    {
        if (exposure.length == 0) revert EmptyExposure();
        if (volScalePpm.length != exposure.length) revert BadFeeds();

        uint256[] memory payout = new uint256[](SCENARIOS);
        uint256 sumPayout;
        for (uint256 s; s < SCENARIOS; s++) {
            int256 loss;
            for (uint256 i; i < exposure.length; i++) {
                int32[504] storage table = _tableFor(i);
                int256 gap = (int256(table[s]) * int256(volScalePpm[i])) / int256(PPM);
                int256 pnl = (exposure[i] * gap) / BPS;
                if (pnl < 0) loss -= pnl;
            }
            int256 p = loss - int256(retention);
            if (p < 0) p = 0;
            uint256 pu = uint256(p);
            if (pu > limit) pu = limit;
            payout[s] = pu;
            sumPayout += pu;
        }
        el = sumPayout / SCENARIOS;

        // Worst-5% tail via partial selection (pull the TAIL largest payouts, not a full sort):
        // matches the Stylus side and the "504 layer evaluations and a TVaR partial sort per
        // quote" workload this product's own research describes.
        bool[] memory used = new bool[](SCENARIOS);
        uint256 tailSum;
        for (uint256 k; k < TAIL; k++) {
            uint256 bestIdx = type(uint256).max;
            uint256 bestVal;
            for (uint256 s; s < SCENARIOS; s++) {
                if (used[s]) continue;
                if (bestIdx == type(uint256).max || payout[s] > bestVal) {
                    bestVal = payout[s];
                    bestIdx = s;
                }
            }
            used[bestIdx] = true;
            tailSum += bestVal;
        }
        tvar95 = tailSum / TAIL;

        // premium = el + RISK_LOAD_PPM * (tvar95 - el) + CAPITAL_CHARGE_ANNUAL_PPM * limit *
        // LOCK_DAYS / DAYS_PER_YEAR; each term fully multiplied before its single final division
        // so neither load is itself divide-before-multiply (docs/judging/heracles.md B.4 flags
        // exactly this anti-pattern elsewhere in the product).
        uint256 riskLoad = ((tvar95 - el) * RISK_LOAD_PPM) / PPM;
        uint256 capitalCharge = (limit * CAPITAL_CHARGE_ANNUAL_PPM * LOCK_DAYS) / (DAYS_PER_YEAR * PPM);
        premium = el + riskLoad + capitalCharge;
    }

    /// @inheritdoc IPricer
    function quote(int256[] calldata exposure, address[] calldata feeds, uint256 retention, uint256 limit)
        external
        view
        returns (uint256 premium, uint256 el, uint256 tvar95)
    {
        if (exposure.length == 0) revert EmptyExposure();
        if (feeds.length != exposure.length) revert BadFeeds();

        uint256[] memory volScalePpm = new uint256[](feeds.length);
        for (uint256 i; i < feeds.length; i++) {
            volScalePpm[i] = _volScalePpm(feeds[i]);
        }
        int256[] memory exposureMem = exposure;
        return priceCore(exposureMem, volScalePpm, retention, limit);
    }
}
