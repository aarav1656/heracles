// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// T1 (`payoutJunior + payoutSenior == payout`, `payoutJunior <= J`, `payoutSenior <= L - J`,
/// `payoutSenior > 0` implies `payoutJunior == J`) and T2 (`premiumJunior + premiumSenior ==
/// premium`, `premiumJunior == pricer.quote(R, J).premium` at the bind block) across the
/// waterfall's four payout regimes, plus the floor top-up landing in senior and the dust-split
/// guards.
contract TrancheTest is Test, TreatyFixture {
    uint256 constant T0 = 1_790_000_000; // a Monday; that week's Fri 19:30/Mon 13:30 below
    uint256 constant CUTOFF = 1_790_364_600; // Fri 2026-09-25 19:30 UTC (T0's week)
    uint256 constant REF_TIME = CUTOFF + 30 minutes; // Fri 2026-09-25 20:00 UTC (EDT close)
    uint40 constant EXPIRY = uint40(1_790_602_200); // Mon 2026-09-28 13:30 UTC

    int256 constant FRIDAY_PRICE = 100e8;

    uint256 constant RETENTION = 20_000e6;
    uint256 constant LIMIT = 60_000e6;
    int256 constant EXPOSURE = 2_000_000e6;
    // juniorShareBps defaults to 3_000 (30%) via TreatyFixture.DEFAULT_JUNIOR_SHARE_BPS.
    uint256 constant JUNIOR_LIMIT = LIMIT * 3_000 / 1e4; // 18_000e6

    MockUSDG usdg;
    MockFeed feed;
    Pricer pricer;
    Treaty treaty;
    Capacity firstLoss;
    Capacity senior;
    address[] feeds;

    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer(oneTableId());
        feed = new MockFeed();
        feed.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);

        feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = deployTreaty(address(usdg), address(pricer), feeds, 50, address(0));
        firstLoss = Capacity(treaty.firstLossVault(0));
        senior = Capacity(treaty.seniorVault(0));

        usdg.mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        usdg.approve(address(firstLoss), type(uint256).max);
        usdg.approve(address(senior), type(uint256).max);
        firstLoss.deposit(500_000e6, writer);
        senior.deposit(500_000e6, writer);
        vm.stopPrank();

        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(treaty), type(uint256).max);

        vm.warp(T0);
    }

    function _exposure() internal pure returns (int256[] memory e) {
        e = new int256[](1);
        e[0] = EXPOSURE;
    }

    function _layer(uint256 id)
        internal
        view
        returns (
            Treaty.State state,
            uint256 limit,
            uint256 juniorLimit,
            uint256 premium,
            uint256 premiumJunior,
            uint256 premiumSenior,
            uint256 payout,
            uint256 payoutJunior,
            uint256 payoutSenior
        )
    {
        (,,,,,, state,,, limit, juniorLimit, premium, premiumJunior, premiumSenior, payout, payoutJunior, payoutSenior)
        = treaty.layers(id);
    }

    /// Binds at T0 with the shared exposure/retention/limit, asserts T2 against a same-block
    /// `pricer.quote(R, J)` call (before `setReference`/`fix` advance the feed's latest round),
    /// then carries the layer to settlement against `mondayPrice` and asserts T1.
    function _bindCheckT2AndSettle(int256 mondayPrice) internal returns (uint256 id) {
        vm.prank(buyer);
        id = treaty.bind(0, _exposure(), RETENTION, LIMIT);

        (,,,, uint256 premiumJunior, uint256 premiumSenior,,,) = _layer(id);
        (uint256 quotedJunior,,) = pricer.quote(_exposure(), feeds, RETENTION, JUNIOR_LIMIT);
        assertEq(premiumJunior, quotedJunior, "T2: premiumJunior must equal pricer.quote(R, J) at the bind block");
        (,,, uint256 premium,,,,,) = _layer(id);
        assertEq(premiumJunior + premiumSenior, premium, "T2: premiumJunior + premiumSenior == premium");

        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);

        feed.set(3, mondayPrice, uint256(EXPIRY) + 10);
        vm.warp(uint256(EXPIRY) + 20);
        treaty.fix(id, 0, 3);
    }

    function _assertT1(uint256 id) internal view {
        (Treaty.State state,,,,,, uint256 payout, uint256 payoutJunior, uint256 payoutSenior) = _layer(id);
        assertEq(uint8(state), uint8(Treaty.State.Settled));
        assertEq(payoutJunior + payoutSenior, payout, "T1: payoutJunior + payoutSenior == payout");
        assertLe(payoutJunior, JUNIOR_LIMIT, "T1: payoutJunior <= J");
        assertLe(payoutSenior, LIMIT - JUNIOR_LIMIT, "T1: payoutSenior <= L - J");
        if (payoutSenior > 0) {
            assertEq(payoutJunior, JUNIOR_LIMIT, "T1: payoutSenior > 0 implies payoutJunior == J");
        }
    }

    /// A 1% Friday-to-Monday move exactly consumes the retention (2,000,000e6 * 1% ==
    /// 20,000e6 == RETENTION), so the measured loss never exceeds it: zero payout on both slices.
    function test_T1T2_zeroPayout() public {
        uint256 id = _bindCheckT2AndSettle(99e8);
        (,,,,,, uint256 payout, uint256 payoutJunior, uint256 payoutSenior) = _layer(id);
        assertEq(payout, 0);
        assertEq(payoutJunior, 0);
        assertEq(payoutSenior, 0);
        _assertT1(id);
    }

    /// A 1.5% move measures a 30,000e6 loss, 10,000e6 over retention: the first-loss slice
    /// (J = 18,000e6) absorbs the whole payout and the senior slice pays nothing.
    function test_T1T2_partialJunior() public {
        uint256 id = _bindCheckT2AndSettle(9_850_000_000); // 98.5e8: a 1.5% move
        _assertT1(id);
    }

    /// A 2.5% move measures a 50,000e6 loss, 30,000e6 over retention: the first-loss slice
    /// exhausts its full 18,000e6 and the senior slice absorbs the remaining 12,000e6.
    function test_T1T2_fullJuniorPartialSenior() public {
        uint256 id = _bindCheckT2AndSettle(9_750_000_000); // 97.5e8: a 2.5% move
        _assertT1(id);
    }

    /// A 10% move measures a 180,000e6 loss, clamped at the layer's own 60,000e6 limit: the
    /// first-loss slice exhausts its full 18,000e6 and the senior slice absorbs the remaining
    /// 42,000e6.
    function test_T1T2_fullLimit() public {
        uint256 id = _bindCheckT2AndSettle(90e8);
        (,,,,,, uint256 payout, uint256 payoutJunior, uint256 payoutSenior) = _layer(id);
        assertEq(payout, LIMIT);
        assertEq(payoutJunior, JUNIOR_LIMIT);
        assertEq(payoutSenior, LIMIT - JUNIOR_LIMIT);
        _assertT1(id);
    }

    /// A limit under 4 base units floors `juniorLimit` to zero (`limit * 3_000 / 1e4`): no vault
    /// can lock capital for a zero-sized slice, so `bind` rejects it before ever pricing it.
    function test_bindRevertsWhenJuniorLimitIsZero() public {
        vm.prank(buyer);
        vm.expectRevert(Treaty.BadParams.selector);
        treaty.bind(0, _exposure(), RETENTION, 3);
    }

    /// A retention far above the table's worst possible weekend gap zeroes every scenario's
    /// payout, so `el`/`tvar95` are both zero and the sub-layer's premium is pure capital charge;
    /// at a 4,000-unit limit that charge itself floors to zero for the first-loss sub-layer
    /// (`juniorLimit == 1,200`, `1,200 * 280_000 / 365_000_000 == 0`), so `premiumJunior` quotes
    /// to zero even though `juniorLimit` itself is nonzero. No vault can lock capital for zero
    /// premium, so `bind` rejects the whole layer rather than silently pricing one slice at zero.
    function test_bindRevertsWhenJuniorPremiumIsZero() public {
        vm.prank(buyer);
        vm.expectRevert(Treaty.BadParams.selector);
        treaty.bind(0, _exposure(), 1e12, 4000);
    }

    /// H2's floor (`minRateOnLineBps` of the whole limit) is never re-applied to the first-loss
    /// sub-quote (bind's own comment: "the floor, if it bound above, is not re-applied to the
    /// sub-layer"). A small enough exposure makes the unfloored total premium fall under the
    /// floor while the sub-quote stays genuinely small but nonzero; the floor's whole top-up then
    /// lands in `premiumSenior`, not split proportionally across both slices.
    function test_floorTopUpLandsInSenior() public {
        int256[] memory tinyExposure = new int256[](1);
        tinyExposure[0] = 1_000e6;

        vm.prank(buyer);
        uint256 id = treaty.bind(0, tinyExposure, 0, LIMIT);

        (uint256 quotedTotal,,) = pricer.quote(tinyExposure, feeds, 0, LIMIT);
        (uint256 quotedJunior,,) = pricer.quote(tinyExposure, feeds, 0, JUNIOR_LIMIT);

        (,,, uint256 premium, uint256 premiumJunior, uint256 premiumSenior,,,) = _layer(id);

        assertGt(premium, quotedTotal, "the floor must have bound above the unfloored total quote");
        assertEq(premiumJunior, quotedJunior, "the floor must never touch the first-loss sub-quote");
        assertEq(premiumJunior + premiumSenior, premium, "T2: premiumJunior + premiumSenior == premium");
        assertGt(
            premiumSenior,
            quotedTotal - quotedJunior,
            "the whole floor top-up must land in the senior slice, not be split proportionally"
        );
    }
}
