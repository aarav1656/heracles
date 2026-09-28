// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Pricer's constructor no longer accepts an empty `tableIds` array (P2 re-review,
/// docs/security/capacity-review.md "Re-review (2026-09-28)"): it reverts `BadTableId()` on
/// empty or any entry > 3, closing the positional/id-value fallback this used to lean on. Tests
/// that only need construction to succeed, not a specific table selection, use these helpers to
/// pass an explicit id 0 (NVDA) per market instead of `new uint8[](0)`.
function oneTableId() pure returns (uint8[] memory ids) {
    ids = new uint8[](1);
    ids[0] = 0;
}

function nTableIds(uint256 n) pure returns (uint8[] memory ids) {
    ids = new uint8[](n);
    for (uint256 i; i < n; i++) {
        ids[i] = 0;
    }
}
