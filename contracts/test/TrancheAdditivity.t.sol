// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pricer} from "../src/Pricer.sol";
import {nTableIds} from "./utils/TableIdsFixture.sol";

/// Additivity of `Pricer.priceCore` across a first-loss/senior split (docs/pricing.md, cited by
/// `bind`'s own premium-split comment): splitting one evaluation `(R, L)` into a first-loss
/// sub-layer `(R, J)` and a senior sub-layer `(R + J, L - J)` must reproduce the same EL, TVaR95
/// and premium as evaluating the whole layer at once, up to the small independent-rounding slack
/// each of the three extra divisions (`el`, `tvar95`, and `premium`'s own two loads) can
/// introduce. This is the mathematical justification for why `bind` can price the first-loss
/// slice with its own `quote` call and derive the senior slice's premium by subtraction, instead
/// of quoting it directly.
contract TrancheAdditivityTest is Test {
    Pricer pricer;

    function setUp() public {
        pricer = new Pricer(nTableIds(4));
    }

    function testFuzz_additivity(
        uint256 exposureSeed,
        uint256 volSeed,
        uint8 nMarketsSeed,
        uint256 retention,
        uint256 limit,
        uint256 juniorShareBps
    ) public view {
        uint256 nMarkets = bound(nMarketsSeed, 1, 4);
        limit = bound(limit, 1, 500_000e6);
        retention = bound(retention, 0, 2_000_000e6);
        juniorShareBps = bound(juniorShareBps, 1, 9_999);

        uint256 J = limit * juniorShareBps / 1e4;
        vm.assume(J > 0 && limit - J > 0);

        int256[] memory exposure = new int256[](nMarkets);
        uint256[] memory volScalePpm = new uint256[](nMarkets);
        for (uint256 i; i < nMarkets; i++) {
            exposure[i] = int256(bound(uint256(keccak256(abi.encode(exposureSeed, i))), 0, 5_000_000e6));
            volScalePpm[i] = bound(uint256(keccak256(abi.encode(volSeed, i))), 1_000_000, 3_000_000);
        }

        (uint256 pTotal, uint256 elTotal, uint256 tvarTotal) = pricer.priceCore(exposure, volScalePpm, retention, limit);
        (uint256 pJunior, uint256 elJunior, uint256 tvarJunior) =
            pricer.priceCore(exposure, volScalePpm, retention, J);
        (uint256 pSenior, uint256 elSenior, uint256 tvarSenior) =
            pricer.priceCore(exposure, volScalePpm, retention + J, limit - J);

        assertApproxEqAbs(elJunior + elSenior, elTotal, 1, "el(R,J) + el(R+J,L-J) must be within 1 of el(R,L)");
        assertApproxEqAbs(
            tvarJunior + tvarSenior, tvarTotal, 1, "tvar(R,J) + tvar(R+J,L-J) must be within 1 of tvar(R,L)"
        );
        assertApproxEqAbs(
            pJunior + pSenior, pTotal, 3, "premium(R,J) + premium(R+J,L-J) must be within 3 of premium(R,L)"
        );
        assertLe(pJunior, pTotal, "the first-loss sub-layer alone can never price above the whole layer");
    }
}
