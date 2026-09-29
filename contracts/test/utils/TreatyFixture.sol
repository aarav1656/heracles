// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Treaty} from "../../src/Treaty.sol";

/// Centralizes every test's `new Treaty(...)` call behind one helper, so a constructor signature
/// change (the `livenessFeed` argument lane L1 adds, books in lane L2) touches this file instead
/// of every test that deploys a `Treaty`. `deployTreaty` mirrors the constructor's current
/// argument list exactly; plain contract deployment needs no `vm` cheatcode, so this has no
/// dependency on `forge-std/Test.sol` and test contracts inherit it alongside `Test`.
abstract contract TreatyFixture {
    /// L1 (docs/design/v3.md, decision 3): the constructor's new `livenessFeed` immutable
    /// defaults to `address(0)` here (disabled), which is only ever correct for a unit test;
    /// callers that need `cancel`'s liveness guard exercised for real use the 6-arg overload below.
    function deployTreaty(
        address usdg,
        address pricer,
        address[] memory feeds,
        uint256 minRateOnLineBps,
        address sequencerUptimeFeed
    ) internal returns (Treaty) {
        return deployTreaty(usdg, pricer, feeds, minRateOnLineBps, sequencerUptimeFeed, address(0));
    }

    function deployTreaty(
        address usdg,
        address pricer,
        address[] memory feeds,
        uint256 minRateOnLineBps,
        address sequencerUptimeFeed,
        address livenessFeed
    ) internal returns (Treaty) {
        return new Treaty(usdg, pricer, feeds, minRateOnLineBps, sequencerUptimeFeed, livenessFeed);
    }
}
