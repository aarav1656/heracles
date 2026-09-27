// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal WAD (1e18) fixed-point ln/exp/sqrt/normalCDF for the gap-treaty pricer spike.
/// Not a general-purpose library: exp() only handles exp(-y) for y >= 0, which is all the
/// Black-Scholes normal CDF needs. Ported line-for-line to Rust so Solidity and Stylus produce
/// the same premium.
library FixedMath {
    int256 internal constant WAD = 1e18;
    int256 internal constant LN2_WAD = 693147180559945309; // ln(2) * 1e18

    // Abramowitz & Stegun 26.2.17 normal CDF approximation constants (WAD-scaled).
    int256 internal constant P = 231641900000000000;
    int256 internal constant A1 = 319381530000000000;
    int256 internal constant A2 = -356563782000000000;
    int256 internal constant A3 = 1781477937000000000;
    int256 internal constant A4 = -1821255978000000000;
    int256 internal constant A5 = 1330274429000000000;
    int256 internal constant INV_SQRT_2PI = 398942280401432678;

    function mulWad(int256 a, int256 b) internal pure returns (int256) {
        return (a * b) / WAD;
    }

    function divWad(int256 a, int256 b) internal pure returns (int256) {
        return (a * WAD) / b;
    }

    /// @dev floor integer sqrt of a nonnegative uint256, Newton's method.
    function isqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @dev sqrt of a nonnegative WAD value, returned as WAD.
    function sqrtWad(int256 x) internal pure returns (int256) {
        require(x >= 0, "sqrtWad: negative");
        return int256(isqrt(uint256(x) * uint256(WAD)));
    }

    /// @dev ln(x) for x > 0 WAD, via range reduction to m in [1,2) WAD and the atanh series
    /// ln(m) = 2*atanh((m-1)/(m+1)) = 2*(t + t^3/3 + t^5/5 + t^7/7 + t^9/9 + t^11/11).
    function lnWad(int256 x) internal pure returns (int256) {
        require(x > 0, "lnWad: non-positive");
        int256 m = x;
        int256 e = 0;
        while (m >= 2 * WAD) {
            m = m / 2;
            e += 1;
        }
        while (m < WAD) {
            m = m * 2;
            e -= 1;
        }
        int256 t = divWad(m - WAD, m + WAD);
        int256 t2 = mulWad(t, t);
        int256 term = t;
        int256 sum = t;
        term = mulWad(term, t2); sum += term / 3;
        term = mulWad(term, t2); sum += term / 5;
        term = mulWad(term, t2); sum += term / 7;
        term = mulWad(term, t2); sum += term / 9;
        term = mulWad(term, t2); sum += term / 11;
        int256 lnm = 2 * sum;
        return e * LN2_WAD + lnm;
    }

    /// @dev exp(-y) for y >= 0 WAD, via range reduction y = n*ln2 + r, r in [0, ln2),
    /// Taylor series for exp(-r), then divide by 2^n.
    function expNegWad(int256 y) internal pure returns (int256) {
        require(y >= 0, "expNegWad: negative");
        if (y > 135 * WAD) return 0; // underflows to 0 well before this
        int256 n = y / LN2_WAD;
        int256 r = y - n * LN2_WAD; // 0 <= r < LN2_WAD
        // exp(-r) = 1 - r + r^2/2! - r^3/3! + r^4/4! - r^5/5! + r^6/6! - r^7/7!
        int256 term = WAD;
        int256 sum = WAD;
        term = mulWad(term, -r); sum += term;
        term = mulWad(term, -r) / 2; sum += term;
        term = mulWad(term, -r) / 3; sum += term;
        term = mulWad(term, -r) / 4; sum += term;
        term = mulWad(term, -r) / 5; sum += term;
        term = mulWad(term, -r) / 6; sum += term;
        term = mulWad(term, -r) / 7; sum += term;
        // sum now holds exp(-r) in WAD; divide by 2^n
        if (n >= 0) {
            if (n >= 255) return 0;
            return sum >> uint256(n);
        } else {
            uint256 shift = uint256(-n);
            require(shift < 200, "expNegWad: overflow");
            return sum << shift;
        }
    }

    /// @dev standard normal CDF N(x), x is WAD (can be negative).
    function normalCDF(int256 x) internal pure returns (int256) {
        int256 xAbs = x >= 0 ? x : -x;
        int256 k = divWad(WAD, WAD + mulWad(P, xAbs));
        int256 poly = mulWad(
            k,
            A1 + mulWad(k, A2 + mulWad(k, A3 + mulWad(k, A4 + mulWad(k, A5))))
        );
        int256 y = mulWad(xAbs, xAbs) / 2;
        int256 phi = mulWad(INV_SQRT_2PI, expNegWad(y));
        int256 tail = mulWad(phi, poly);
        if (x >= 0) {
            return WAD - tail;
        } else {
            return tail;
        }
    }
}
