// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Capacity} from "../src/Capacity.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

// Permit-capable USDG stand-in for this test only (MockUSDG has no EIP-2612 support and is
// shared by tests that don't need it).
contract PermitUSDG is ERC20, ERC20Permit {
    constructor() ERC20("Permit USDG", "pUSDG") ERC20Permit("Permit USDG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// depositWithPermit's try/catch: a writer
/// deposits in one transaction off a signed permit, and a griefer front-running that same
/// permit (relaying it first) does not block the deposit, since the allowance it would have
/// granted is already in place.
contract CapacityPermitTest is Test {
    PermitUSDG usdg;
    Capacity capacity;

    uint256 writerPk = 0xA11CE;
    address writer;
    address treaty = makeAddr("treaty");

    function setUp() public {
        usdg = new PermitUSDG();
        capacity = new Capacity(usdg, treaty, "Test Capacity", "tCAP");
        writer = vm.addr(writerPk);
        usdg.mint(writer, 1_000_000e6);
    }

    function _sign(uint256 amount, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                writer,
                address(capacity),
                amount,
                usdg.nonces(writer),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdg.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(writerPk, digest);
    }

    function test_depositWithPermit() public {
        uint256 amount = 100_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(amount, deadline);

        vm.prank(writer);
        uint256 shares = capacity.depositWithPermit(amount, writer, deadline, v, r, s);

        assertGt(shares, 0);
        assertEq(usdg.balanceOf(writer), 900_000e6);
        assertEq(usdg.balanceOf(address(capacity)), amount);
        assertEq(capacity.balanceOf(writer), shares);
    }

    /// Front-run fallback: a griefer relays the writer's own permit signature first. The
    /// allowance it grants is already sufficient, so depositWithPermit falls through instead
    /// of reverting on the now-stale signature.
    function test_depositWithPermit_frontrunFallsThrough() public {
        uint256 amount = 50_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(amount, deadline);

        vm.prank(makeAddr("griefer"));
        usdg.permit(writer, address(capacity), amount, deadline, v, r, s);

        uint256 before = usdg.balanceOf(writer);
        vm.prank(writer);
        uint256 shares = capacity.depositWithPermit(amount, writer, deadline, v, r, s);

        assertEq(usdg.balanceOf(writer), before - amount, "deposit still pulled despite the front-run permit");
        assertEq(capacity.balanceOf(writer), shares);
    }

    /// A stale/garbage signature with no prior approve and no front-run reverts: there is no
    /// allowance for the deposit to fall back on.
    function test_depositWithPermit_badSignatureReverts() public {
        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(writer);
        vm.expectRevert(Capacity.InsufficientAllowance.selector);
        capacity.depositWithPermit(amount, writer, deadline, 27, bytes32(uint256(1)), bytes32(uint256(2)));
    }
}
