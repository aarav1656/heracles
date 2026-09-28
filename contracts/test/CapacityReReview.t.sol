// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";

contract PermitUSDG is ERC20, ERC20Permit {
    constructor() ERC20("Permit USDG", "pUSDG") ERC20Permit("Permit USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Re-review of b71cf94 (the security review "Re-review of b71cf94"). Ported from
/// the reviewer's scratch suite at the reviewer's own scratch copy. H1/H1b are red against
/// b71cf94 (the epoch gate keyed on aggregate `locked != 0`) and green once the gate keys on each
/// layer's own cutoff instead (Resolution 2). L1r's assertions are rewritten for the chosen fix
/// (always attempt the permit, never leave a signature unconsumed) rather than the reviewer's
/// literal assertions (which target the alternative fix of skipping unnecessary permits at the
/// call site, done here in the web app instead of on-chain).
contract CapacityReReviewTest is Test {
    uint256 constant MON0 = 1_789_948_800; // Monday 00:00 UTC
    uint256 constant WEEKS = 10;

    MockUSDG usdg;
    MockFeed feed;
    Treaty treaty;
    Capacity capacity;
    address writer = makeAddr("writer");
    address griefer = makeAddr("griefer");

    function setUp() public {
        usdg = new MockUSDG();
        feed = new MockFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = new Treaty(address(usdg), address(new Pricer(oneTableId())), feeds, 50, address(0));
        capacity = treaty.capacity();

        // Item 6: setReference now needs its own first-round-after-Friday's-close pair, so each
        // week gets three round ids instead of two: 3w+1 (pre-close predecessor, unchanged Fri
        // 19:00 seed), 3w+2 (the actual Friday reference round, at `fridayCloseOf`, queried live
        // since this WEEKS=10 run spans the Nov 2026 DST switch), 3w+3 (Monday fix round,
        // unchanged placeholder timing).
        // Round 3 (the Monday fix round) is timestamped from `expiry` itself, not a hardcoded
        // "13:30 UTC" offset: WEEKS=10 from a late-September MON0 runs past the first Sunday of
        // November, so mid-run `expiry`'s time-of-day shifts from 13:30 UTC (EDT) to 14:30 UTC
        // (EST) -- a fixed offset would seed a round that is `EarlyFix` (or `BadRound`, once the
        // round predates the real DST-shifted expiry) for every EST week.
        for (uint256 w; w < WEEKS; w++) {
            uint256 monday = MON0 + w * 7 days;
            (uint256 cutoff, uint256 expiry) = treaty.weekWindow(monday);
            uint256 refTime = treaty.fridayCloseOf(cutoff);
            feed.set(uint80(3 * w + 1), 100e8, cutoff - 30 minutes);
            feed.set(uint80(3 * w + 2), 100e8, refTime);
            feed.set(uint80(3 * w + 3), 100e8, expiry + 1);
        }
        vm.warp(MON0 + 1 hours);
        usdg.mint(writer, 100_000e6);
        vm.startPrank(writer);
        usdg.approve(address(capacity), type(uint256).max);
        capacity.deposit(100_000e6, writer);
        vm.stopPrank();
    }

    function _one(int256 e) internal pure returns (int256[] memory x) {
        x = new int256[](1);
        x[0] = e;
    }

    /// HIGH (closed). One dust layer per week, bound Monday morning before the previous weekend's
    /// 13:30 UTC expiry, used to keep `locked != 0` at every instant under the old aggregate gate,
    /// which kept `maxRedeem` at exactly 0 forever. The griefer always keeps one dust layer open
    /// (this week's, bound before last week's has settled), so `locked` itself never returns to 0
    /// either, under old code or new: a redeem of the writer's entire balance still cannot succeed
    /// on either version (some capital is always, correctly, reserved). What the old code broke was
    /// `maxRedeem` itself: it returned exactly 0 forever, not just "less than the full balance". The
    /// fix under test is that `maxRedeem` now tracks free capacity precisely (all but the ~200 wei
    /// reserved by whichever dust layer is currently open) and a redeem for that amount succeeds
    /// every single week, instead of every exit reverting outright.
    function test_H1_rollingDustBindFreezesWritersIndefinitely() public {
        usdg.mint(griefer, 1_000);
        vm.prank(griefer);
        usdg.approve(address(capacity), type(uint256).max);

        uint256 exits;
        uint256 prevId = type(uint256).max;
        uint256 bindGas;
        uint256 grieferStart = usdg.balanceOf(griefer);
        for (uint256 w = 1; w < 9; w++) {
            // Monday 00:05 of week w: previous layer (expiry Monday 13:30 of week w) still live.
            vm.warp(MON0 + w * 7 days + 5 minutes);
            uint256 g = gasleft();
            vm.prank(griefer);
            uint256 id = treaty.bind(_one(1e6), 1_000_000e6, 200);
            bindGas = g - gasleft();
            (,,,,,,,,, uint256 premium,) = treaty.layers(id);
            assertEq(premium, 1, "min nonzero premium is 1 base unit");

            if (prevId != type(uint256).max) {
                // prevId's expiry, DST-aware, not a hardcoded "13:30 UTC" (see setUp).
                (, uint256 prevExpiry) = treaty.weekWindow(MON0 + (w - 1) * 7 days + 5 minutes);
                vm.warp(prevExpiry + 1);
                treaty.fix(prevId, 0, uint80(3 * (w - 1) + 3)); // writer settles diligently
                // A modest, representative redemption (not the writer's whole balance): some
                // capital is always, correctly, reserved for whichever dust layer is currently
                // open, so a redeem of the full balance can never succeed on any version of this
                // code. What must succeed every week is a redeem within free capacity.
                uint256 want = capacity.maxRedeem(writer);
                if (want > 1_000e6) want = 1_000e6;
                if (want > 0) {
                    vm.prank(writer);
                    try capacity.redeem(want, writer, writer) {
                        exits++;
                    } catch {}
                }
            }
            // Saturday 00:00+1 of week w: writer sets this layer's reference at once (safely
            // after Friday's close, regardless of DST regime).
            vm.warp(MON0 + w * 7 days + 5 days + 1);
            treaty.setReference(id, 0, uint80(3 * w + 2));
            prevId = id;
        }
        console2.log("griefer USDG base units spent over 8 weeks", grieferStart - usdg.balanceOf(griefer));
        console2.log("gas per griefing bind (Solidity Pricer)", bindGas);
        console2.log("writer exits achieved", exits);
        assertGt(exits, 0, "H1: writer never able to exit across 8 weeks of 1-base-unit binds");
    }

    /// Same freeze from honest usage (closed): a buyer rolling weekly cover binds next weekend's
    /// layer on Monday morning, before this weekend's layer can be fixed at 13:30. No attacker
    /// needed; the new layer's own cutoff is a week away, so it does not hold the gate shut once
    /// the just-fixed layer drains.
    function test_H1b_honestMondayRollAlsoFreezes() public {
        address buyer = makeAddr("buyer");
        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(capacity), type(uint256).max);
        vm.prank(buyer);
        uint256 a = treaty.bind(_one(-500_000e6), 20_000e6, 10_000e6);
        // Round 1 (set in setUp, w=0) is the pre-close predecessor; round 2 is the actual
        // Friday-close reference round.
        vm.warp(MON0 + 5 days + 1);
        treaty.setReference(a, 0, 2);
        vm.warp(MON0 + 7 days + 9 hours); // Monday 09:00, next week's roll
        vm.prank(buyer);
        treaty.bind(_one(-500_000e6), 20_000e6, 10_000e6);
        (, uint256 expiryA) = treaty.weekWindow(MON0);
        vm.warp(expiryA + 1);
        treaty.fix(a, 0, 3);
        assertGt(capacity.maxRedeem(writer), 0, "H1b: exit closed after every past weekend has settled");
    }

    /// LOW re-review, closed by always attempting the permit (Resolution 2) instead of the
    /// contract-side skip Resolution 1 shipped: a valid signature is consumed inside the very
    /// depositWithPermit call it was signed for, so there is nothing left afterward for a third
    /// party to relay. The UX cost the skip was trying to avoid (overwriting a standing allowance)
    /// is instead avoided at the caller: the web app only requests a permit when the standing
    /// allowance does not already cover the deposit (see heracles web src/hooks).
    function test_L1r_permitAlwaysConsumedNoReplayWindow() public {
        PermitUSDG pu = new PermitUSDG();
        Capacity cap = new Capacity(pu, address(this));
        uint256 pk = 0xA11CE;
        address w = vm.addr(pk);
        pu.mint(w, 1_000_000e6);
        vm.prank(w);
        pu.approve(address(cap), type(uint256).max); // standing approval for premiums

        uint256 assets = 1_000e6;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                pu.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        w,
                        address(cap),
                        assets,
                        pu.nonces(w),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vm.prank(w);
        cap.depositWithPermit(assets, w, deadline, v, r, s);
        assertEq(pu.nonces(w), 1, "L1r: permit must be consumed inside depositWithPermit itself");

        // A griefer trying to replay the now-stale signature later gets nothing: the nonce it was
        // signed against is already spent, so the signature is no longer valid for anyone.
        vm.prank(griefer);
        vm.expectRevert();
        pu.permit(w, address(cap), assets, deadline, v, r, s);
    }
}
