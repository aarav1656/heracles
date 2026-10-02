// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OIGuard} from "../src/OIGuard.sol";
import {IPricer} from "../src/IPricer.sol";
import {Pricer} from "../src/Pricer.sol";

/// Test double: premium is 1% of gross exposure plus 0.1% of limit, so every number in a revert
/// can be written down by hand.
contract LinearPricer is IPricer {
    error BadFeeds();

    function quote(int256[] calldata exposure, address[] calldata feeds, uint256, uint256 limit)
        external
        pure
        returns (uint256 premium, uint256 el, uint256 tvar95)
    {
        if (feeds.length != exposure.length) revert BadFeeds();
        uint256 gross;
        for (uint256 i; i < exposure.length; i++) {
            gross += exposure[i] < 0 ? uint256(-exposure[i]) : uint256(exposure[i]);
        }
        premium = gross / 100 + limit / 1000;
        el = gross / 200;
        tvar95 = gross / 50;
    }
}

contract OIGuardTest is Test {
    OIGuard guard;
    address owner = makeAddr("owner");
    uint256 constant LIMIT = 200_000e6; // fixed part of the premium: 200e6

    function setUp() public {
        address[] memory feeds = new address[](3);
        (feeds[0], feeds[1], feeds[2]) = (address(1), address(2), address(3));
        guard = new OIGuard(new LinearPricer(), feeds, owner, 20_000e6, LIMIT, 1_200e6);
    }

    function _book(int256 a, int256 b, int256 c) internal pure returns (int256[] memory book) {
        book = new int256[](3);
        (book[0], book[1], book[2]) = (a, b, c);
    }

    function test_acceptsWithinBudget() public view {
        // gross 100k after the trade: 1_000e6 + 200e6 = 1_200e6, exactly the budget
        assertEq(guard.check(_book(60_000e6, 0, 0), 1, -40_000e6), 1_200e6);
    }

    function test_refusesOverBudgetWithTheNumbers() public {
        // gross 100k -> 100_001: premium 1_200.01e6 > 1_200e6, current 1_200e6
        vm.expectRevert(abi.encodeWithSelector(OIGuard.PremiumOverBudget.selector, 1_200_010_000, 1_200e6, 1_200e6));
        guard.check(_book(60_000e6, -40_000e6, 0), 2, 1e6);
    }

    function test_acceptsRiskReducingTradeWhenAlreadyOverBudget() public view {
        // gross 300k -> 250k: premium 2_700e6 is over budget but below the current 3_200e6
        assertEq(guard.check(_book(300_000e6, 0, 0), 0, -50_000e6), 2_700e6);
        (uint256 premium, bool allowed) = guard.preview(_book(300_000e6, 0, 0), 0, -50_000e6);
        assertEq(premium, 2_700e6);
        assertTrue(allowed);
    }

    function test_refusesFlipThatEndsWithMoreRisk() public {
        // long 300k flipped to short 350k: 3_700e6 vs current 3_200e6
        vm.expectRevert(abi.encodeWithSelector(OIGuard.PremiumOverBudget.selector, 3_700e6, 1_200e6, 3_200e6));
        guard.check(_book(300_000e6, 0, 0), 0, -650_000e6);
    }

    function test_previewMatchesCheck() public view {
        (uint256 premium, bool allowed) = guard.preview(_book(60_000e6, -40_000e6, 0), 2, 1e6);
        assertEq(premium, 1_200_010_000);
        assertFalse(allowed);
    }

    function test_rejectsWrongBookLengthAndMarket() public {
        vm.expectRevert(OIGuard.BadParams.selector);
        guard.check(new int256[](2), 0, 1);
        vm.expectRevert(OIGuard.BadParams.selector);
        guard.check(_book(0, 0, 0), 3, 1);
    }

    function test_onlyOwnerSetsTerms() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        guard.setTerms(0, LIMIT, type(uint256).max);

        vm.prank(owner);
        guard.setTerms(0, LIMIT, 5_000e6);
        assertEq(guard.premiumBudget(), 5_000e6);
        assertEq(guard.check(_book(300_000e6, 0, 0), 0, 100_000e6), 4_200e6);

        vm.prank(owner);
        vm.expectRevert(OIGuard.BadParams.selector);
        guard.setTerms(0, 0, 5_000e6);
    }

    function test_constructorRejectsEmptyFeedsAndZeroPricer() public {
        IPricer pricer = new LinearPricer();
        vm.expectRevert(OIGuard.BadParams.selector);
        new OIGuard(pricer, new address[](0), owner, 0, LIMIT, 1);
        address[] memory feeds = new address[](1);
        vm.expectRevert(OIGuard.BadParams.selector);
        new OIGuard(IPricer(address(0)), feeds, owner, 0, LIMIT, 1);
    }
}

/// Against Arbitrum Sepolia at a pinned block. Forge's EVM cannot execute Stylus WASM (a local
/// call to the pricer returns OpcodeNotFound on its 0xEFF002 prefix), so the live Stylus pricer is
/// reached through `vm.rpc("eth_call")`, which the Arbitrum node executes, and the guard runs
/// locally on the Solidity twin of the same six tables over the live SPY/USD feed. Gated on
/// FORK_TESTS like the other fork suites; with it set, an unreachable RPC fails setUp.
contract OIGuardForkTest is Test {
    string constant RPC = "https://sepolia-rollup.arbitrum.io/rpc";
    uint256 constant FORK_BLOCK = 314_938_000;
    address constant STYLUS_PRICER = 0x1674ECf8D236A91C484C11Fd11a21601837F7e37;
    address constant SPY_FEED = 0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06;
    uint256 constant RETENTION = 20_000e6;
    uint256 constant LIMIT = 200_000e6;

    Pricer twin;
    address[] feeds;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(RPC, FORK_BLOCK);
        uint8[] memory ids = new uint8[](6);
        for (uint8 i; i < 6; i++) {
            ids[i] = i;
            feeds.push(SPY_FEED);
        }
        twin = new Pricer(ids);
    }

    /// Long 1M NVDA, short 400k EUR/USD, long 250k gold: the vault book the guard is asked about.
    function _book() internal pure returns (int256[] memory book) {
        book = new int256[](6);
        (book[0], book[4], book[5]) = (1_000_000e6, -400_000e6, 250_000e6);
    }

    function _stylusQuote(int256[] memory book) internal returns (uint256 premium, uint256 el, uint256 tvar95) {
        bytes memory data = abi.encodeCall(IPricer.quote, (book, feeds, RETENTION, LIMIT));
        string memory params = string.concat(
            '[{"to":"', vm.toString(STYLUS_PRICER), '","data":"', vm.toString(data), '"},"0x', _hex(FORK_BLOCK), '"]'
        );
        (premium, el, tvar95) = abi.decode(vm.rpc(RPC, "eth_call", params), (uint256, uint256, uint256));
    }

    function _hex(uint256 v) internal pure returns (string memory s) {
        bytes memory digits = "0123456789abcdef";
        while (v > 0) {
            s = string.concat(string(abi.encodePacked(digits[v % 16])), s);
            v /= 16;
        }
    }

    function test_fork_stylusAndTwinAgreeOnTheLiveBook() public {
        (uint256 p, uint256 el, uint256 tv) = _stylusQuote(_book());
        (uint256 tp, uint256 tel, uint256 ttv) = twin.quote(_book(), feeds, RETENTION, LIMIT);
        assertGt(el, 0);
        assertGe(p, el);
        assertEq(tp, p, "premium");
        assertEq(tel, el, "el");
        assertEq(ttv, tv, "tvar95");
    }

    /// Budget one unit under the live Stylus premium for the book after a 50k NVDA add: refused,
    /// with the Stylus numbers in the error. One unit over: accepted.
    function test_fork_guardRefusesAtTheLiveStylusPremium() public {
        int256[] memory before = _book();
        int256[] memory afterTrade = _book();
        afterTrade[0] += 50_000e6;
        (uint256 premium,,) = _stylusQuote(afterTrade);
        (uint256 current,,) = _stylusQuote(before);
        assertGt(premium, current);

        OIGuard guard = new OIGuard(twin, feeds, address(this), RETENTION, LIMIT, premium - 1);
        vm.expectRevert(abi.encodeWithSelector(OIGuard.PremiumOverBudget.selector, premium, premium - 1, current));
        guard.check(before, 0, 50_000e6);

        guard.setTerms(RETENTION, LIMIT, premium);
        assertEq(guard.check(before, 0, 50_000e6), premium);
    }

    /// Cutting the gold leg lowers the premium, so it passes even with a budget below both quotes.
    function test_fork_guardAcceptsHedgeWhenOverBudget() public {
        int256[] memory afterTrade = _book();
        afterTrade[5] -= 200_000e6;
        (uint256 premium,,) = _stylusQuote(afterTrade);
        (uint256 current,,) = _stylusQuote(_book());
        assertLt(premium, current);

        OIGuard guard = new OIGuard(twin, feeds, address(this), RETENTION, LIMIT, 1);
        assertEq(guard.check(_book(), 5, -200_000e6), premium);
    }
}
