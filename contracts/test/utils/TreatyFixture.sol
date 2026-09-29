// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Treaty} from "../../src/Treaty.sol";

/// Centralizes every test's `new Treaty(...)` call behind one helper, so a constructor signature
/// change touches this file instead of every test that deploys a `Treaty`. `deployTreaty` mirrors
/// the constructor's current argument list; plain contract deployment needs no `vm` cheatcode, so
/// this has no dependency on `forge-std/Test.sol` and test contracts inherit it alongside `Test`.
///
/// Books: the constructor now takes `address[] assets` plus a name/symbol per book's two vaults,
/// and an immutable `juniorShareBps`. The single-`address asset` overloads below build a one-book
/// array with fixed default vault names, so every existing single-book test keeps calling
/// `deployTreaty(asset, pricer, feeds, minRateOnLineBps, sequencerUptimeFeed[, livenessFeed])`
/// unchanged; only a test that reads `treaty.capacity()` or `treaty.usdg()` needs its own call
/// site touched, to route to book 0's vaults/asset instead. `juniorShareBps` defaults to 3_000
/// (30%), the same split the spec fixes at deploy.
abstract contract TreatyFixture {
    uint256 internal constant DEFAULT_JUNIOR_SHARE_BPS = 3_000;

    /// Compatibility view for tests written against the pre-tranche 11-field `Layer` (buyer,
    /// fridayCutoff, expiry, referencedCount, fixedCount, state, buyerClaimed, retention, limit,
    /// premium, payout). Reads the current 17-field struct and drops the book/juniorLimit/
    /// premiumJunior/premiumSenior/payoutJunior/payoutSenior fields a single-tranche test does not
    /// need, so its own positional destructure stays unchanged at the call site.
    function layerBasics(Treaty t, uint256 id)
        internal
        view
        returns (
            address buyer,
            uint40 fridayCutoff,
            uint40 expiry,
            uint8 referencedCount,
            uint8 fixedCount,
            Treaty.State state,
            bool buyerClaimed,
            uint256 retention,
            uint256 limit,
            uint256 premium,
            uint256 payout
        )
    {
        (
            buyer,
            fridayCutoff,
            expiry,
            ,
            referencedCount,
            fixedCount,
            state,
            buyerClaimed,
            retention,
            limit,
            ,
            premium,
            ,
            ,
            payout,
            ,
        ) = t.layers(id);
    }

    function deployTreaty(
        address asset,
        address pricer,
        address[] memory feeds,
        uint256 minRateOnLineBps,
        address sequencerUptimeFeed
    ) internal returns (Treaty) {
        return deployTreaty(asset, pricer, feeds, minRateOnLineBps, sequencerUptimeFeed, address(0));
    }

    function deployTreaty(
        address asset,
        address pricer,
        address[] memory feeds,
        uint256 minRateOnLineBps,
        address sequencerUptimeFeed,
        address livenessFeed
    ) internal returns (Treaty) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        return deployTreaty(assets, pricer, feeds, minRateOnLineBps, sequencerUptimeFeed, livenessFeed);
    }

    function deployTreaty(
        address[] memory assets,
        address pricer,
        address[] memory feeds,
        uint256 minRateOnLineBps,
        address sequencerUptimeFeed,
        address livenessFeed
    ) internal returns (Treaty) {
        return deployTreaty(
            assets, pricer, feeds, minRateOnLineBps, sequencerUptimeFeed, livenessFeed, DEFAULT_JUNIOR_SHARE_BPS
        );
    }

    function deployTreaty(
        address[] memory assets,
        address pricer,
        address[] memory feeds,
        uint256 minRateOnLineBps,
        address sequencerUptimeFeed,
        address livenessFeed,
        uint256 juniorShareBps
    ) internal returns (Treaty) {
        uint256 n = assets.length;
        string[] memory firstLossNames = new string[](n);
        string[] memory firstLossSymbols = new string[](n);
        string[] memory seniorNames = new string[](n);
        string[] memory seniorSymbols = new string[](n);
        for (uint256 i; i < n; i++) {
            firstLossNames[i] = "Heracles First Loss";
            firstLossSymbols[i] = "hFL";
            seniorNames[i] = "Heracles Senior";
            seniorSymbols[i] = "hSR";
        }
        return new Treaty(
            assets,
            firstLossNames,
            firstLossSymbols,
            seniorNames,
            seniorSymbols,
            pricer,
            feeds,
            minRateOnLineBps,
            sequencerUptimeFeed,
            livenessFeed,
            juniorShareBps
        );
    }
}
