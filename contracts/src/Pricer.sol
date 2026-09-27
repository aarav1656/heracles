// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPricer} from "./IPricer.sol";

/// @notice Weekend-gap layer pricer, Solidity implementation of IPricer.
/// Scenario table: the same 504 historical NVDA Friday-close-to-Monday-open weekend gaps
/// (basis points) measured and deployed in spikes/stylus-pricer/sol/src/Pricer.sol and
/// spikes/stylus-pricer/rs/src/lib.rs (spikes/stylus-pricer/FINDINGS.md, 2026-09-26), copied
/// verbatim, not regenerated. Known simplification, disclosed in this product's
/// own blind-spot list: per-market histories exist only for NVDA/AAPL/SPY/TSLA
/// (`evidence/auction-and-pricing.md`) and even those are not wired in here, so this build
/// applies the one measured NVDA distribution as the shared weekend shock to every bound
/// market. Each of the 504 scenarios is real historical NVDA data, not fabricated; treating it
/// as a shared macro shock across markets is the stated limitation, not invented numbers.
///
/// quote() computes, per scenario s: portfolioLoss(s) = sum_i max(0, -(exposure[i] * gaps[s]) /
/// 10000), payout(s) = min(limit, max(0, portfolioLoss(s) - retention)), then
/// el = mean(payout), tvar95 = mean of the worst 5% (25 of 504) of payout(s), and
/// premium = el * 1.25 + tvar95 * 0.5, all in USDG's native 6-decimal fixed point (no WAD).
/// This is the reference/fallback implementation; the product path calls the identical
/// algorithm on the Rust/Stylus PricerStylus contract (measured ~4.06x cheaper total gas per
/// call, spikes/stylus-pricer/FINDINGS.md), through the same IPricer interface.
contract Pricer is IPricer {
    uint256 internal constant SCENARIOS = 504;
    uint256 internal constant TAIL = 25; // ceil(504 * 0.05), the worst 5% of scenarios
    int256 internal constant BPS = 10000;

    int32[504] internal gaps;

    error EmptyExposure();

    constructor() {
        gaps = [int32(0),int32(53),int32(-2),int32(68),int32(33),int32(294),int32(14),int32(78),int32(-31),int32(174),int32(-215),int32(-71),int32(208),int32(-219),int32(39),int32(-42),int32(-20),int32(-76),int32(-33),int32(-20),int32(93),int32(73),int32(-150),int32(42),int32(67),int32(-176),int32(2),int32(3),int32(126),int32(42),int32(46),int32(130),int32(130),int32(131),int32(-46),int32(-249),int32(118),int32(86),int32(34),int32(203),int32(84),int32(17),int32(33),int32(70),int32(238),int32(61),int32(47),int32(-122),int32(113),int32(279),int32(-70),int32(113),int32(82),int32(62),int32(45),int32(0),int32(-71),int32(0),int32(30),int32(16),int32(120),int32(30),int32(86),int32(-115),int32(118),int32(232),int32(48),int32(14),int32(-24),int32(-279),int32(141),int32(37),int32(76),int32(-86),int32(68),int32(-92),int32(216),int32(119),int32(12),int32(31),int32(29),int32(177),int32(60),int32(160),int32(-29),int32(54),int32(-20),int32(-67),int32(-171),int32(-119),int32(121),int32(-45),int32(-43),int32(23),int32(-20),int32(14),int32(-67),int32(44),int32(-19),int32(34),int32(-37),int32(-47),int32(112),int32(-125),int32(-22),int32(92),int32(287),int32(-25),int32(-180),int32(-161),int32(337),int32(561),int32(-123),int32(-82),int32(-238),int32(131),int32(170),int32(-142),int32(-78),int32(-1474),int32(44),int32(-120),int32(-27),int32(212),int32(99),int32(63),int32(75),int32(-92),int32(206),int32(-64),int32(-16),int32(18),int32(-410),int32(-315),int32(-254),int32(49),int32(33),int32(155),int32(-5),int32(57),int32(508),int32(-150),int32(51),int32(51),int32(-17),int32(-458),int32(-136),int32(286),int32(195),int32(-175),int32(70),int32(-166),int32(0),int32(61),int32(144),int32(-19),int32(130),int32(86),int32(161),int32(-1),int32(-15),int32(244),int32(-13),int32(-43),int32(85),int32(48),int32(-37),int32(-159),int32(137),int32(-59),int32(-489),int32(-31),int32(36),int32(-143),int32(-812),int32(253),int32(-983),int32(-1181),int32(-2),int32(104),int32(464),int32(-174),int32(187),int32(-67),int32(-6),int32(318),int32(145),int32(-48),int32(-48),int32(-131),int32(42),int32(16),int32(110),int32(71),int32(37),int32(111),int32(120),int32(248),int32(158),int32(27),int32(-704),int32(753),int32(-217),int32(129),int32(133),int32(165),int32(66),int32(-120),int32(99),int32(-7),int32(-94),int32(64),int32(3),int32(32),int32(57),int32(-149),int32(107),int32(122),int32(51),int32(49),int32(100),int32(69),int32(-102),int32(117),int32(-9),int32(7),int32(52),int32(-15),int32(-77),int32(-236),int32(-53),int32(77),int32(-17),int32(-60),int32(147),int32(16),int32(-4),int32(45),int32(-109),int32(174),int32(122),int32(95),int32(-135),int32(-126),int32(103),int32(39),int32(-26),int32(74),int32(86),int32(-4),int32(92),int32(-344),int32(-168),int32(-115),int32(-123),int32(-52),int32(109),int32(32),int32(133),int32(53),int32(161),int32(274),int32(-265),int32(17),int32(-178),int32(137),int32(-244),int32(-253),int32(-447),int32(150),int32(22),int32(-6),int32(-257),int32(-68),int32(-52),int32(-105),int32(20),int32(23),int32(6),int32(-391),int32(-160),int32(-4),int32(-343),int32(-111),int32(-252),int32(90),int32(224),int32(-574),int32(374),int32(109),int32(-240),int32(-197),int32(343),int32(-173),int32(10),int32(-783),int32(-4),int32(-201),int32(-148),int32(62),int32(-13),int32(-141),int32(-20),int32(171),int32(-32),int32(259),int32(34),int32(-40),int32(51),int32(-67),int32(-170),int32(-150),int32(-117),int32(21),int32(1),int32(-87),int32(162),int32(286),int32(0),int32(126),int32(-204),int32(-139),int32(128),int32(-181),int32(165),int32(0),int32(-93),int32(-43),int32(22),int32(-96),int32(-72),int32(-39),int32(33),int32(-55),int32(59),int32(-116),int32(423),int32(-106),int32(111),int32(72),int32(60),int32(51),int32(36),int32(180),int32(95),int32(1),int32(96),int32(-90),int32(276),int32(101),int32(-59),int32(126),int32(-262),int32(-5),int32(122),int32(-201),int32(-88),int32(-38),int32(145),int32(62),int32(-3),int32(3),int32(5),int32(-147),int32(-3),int32(104),int32(28),int32(-56),int32(85),int32(56),int32(94),int32(33),int32(312),int32(65),int32(-92),int32(112),int32(225),int32(-126),int32(290),int32(-37),int32(79),int32(103),int32(250),int32(-16),int32(68),int32(67),int32(137),int32(355),int32(364),int32(-43),int32(84),int32(-263),int32(-6),int32(132),int32(102),int32(205),int32(56),int32(-1418),int32(150),int32(-24),int32(15),int32(-281),int32(199),int32(-194),int32(47),int32(-255),int32(6),int32(124),int32(9),int32(103),int32(134),int32(71),int32(-175),int32(3),int32(42),int32(-244),int32(-5),int32(117),int32(-159),int32(285),int32(-436),int32(105),int32(-1249),int32(-443),int32(19),int32(174),int32(158),int32(-113),int32(-248),int32(88),int32(185),int32(-414),int32(-726),int32(287),int32(-119),int32(-139),int32(456),int32(-222),int32(218),int32(27),int32(104),int32(97),int32(-94),int32(41),int32(27),int32(20),int32(30),int32(83),int32(-36),int32(8),int32(20),int32(-240),int32(32),int32(-121),int32(-78),int32(125),int32(-113),int32(262),int32(-5),int32(200),int32(276),int32(370),int32(-221),int32(34),int32(-127),int32(13),int32(167),int32(162),int32(-148),int32(154),int32(-89),int32(-233),int32(-27),int32(-206),int32(-62),int32(-58),int32(83),int32(-123),int32(-56),int32(151),int32(264),int32(75),int32(-138),int32(-84),int32(66),int32(53),int32(-54),int32(202),int32(56),int32(217),int32(248),int32(182),int32(69),int32(-115),int32(151),int32(66),int32(-152),int32(-25),int32(36),int32(38),int32(61),int32(119),int32(-323),int32(30)];
    }



    /// @inheritdoc IPricer
    function quote(int256[] calldata exposure, uint256 retention, uint256 limit)
        external
        view
        returns (uint256 premium, uint256 el, uint256 tvar95)
    {
        if (exposure.length == 0) revert EmptyExposure();

        uint256[] memory payout = new uint256[](SCENARIOS);
        uint256 sumPayout;
        for (uint256 s; s < SCENARIOS; s++) {
            int256 gap = int256(gaps[s]);
            int256 loss;
            for (uint256 i; i < exposure.length; i++) {
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

        premium = (el * 125 + tvar95 * 50) / 100;
    }
}
