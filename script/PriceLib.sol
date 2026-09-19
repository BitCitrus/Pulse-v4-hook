// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Exact integer price conversion for currencies with 0..18 decimals.
/// @dev Script-only arithmetic. Wider decimal formats can use a validated INITIAL_SQRT_PRICE.
library PriceLib {
    function sqrtPriceX96(uint256 priceE18, uint8 decimals0, uint8 decimals1)
        internal
        pure
        returns (uint160)
    {
        return sqrtPriceX96(priceE18, decimals0, decimals1, false);
    }

    /// @param inverted Whether the supplied quote is currency0 per currency1 instead.
    function sqrtPriceX96(uint256 priceE18, uint8 decimals0, uint8 decimals1, bool inverted)
        internal
        pure
        returns (uint160)
    {
        require(priceE18 > 0, "PriceLib: zero price");
        _checkDecimals(decimals0, decimals1);
        // Retain the exact rational quote, including when sorting reverses it. Do not first
        // round the raw-unit ratio or its reciprocal to 18 decimals.
        uint256 numerator = inverted ? 10 ** (18 + uint256(decimals1) - decimals0) : priceE18;
        uint256 denominator = inverted ? priceE18 : 10 ** (18 + uint256(decimals0) - decimals1);
        require(numerator / denominator < 1 << 128, "PriceLib: price overflows uint160");
        uint256 low;
        uint256 high = type(uint160).max;
        while (low < high) {
            uint256 mid = low + (high - low + 1) / 2;
            // mid^2 * denominator <= numerator * 2^192, using full-width products.
            (uint256 top, uint256 hi, uint256 lo) = _squareTimes(mid, denominator);
            uint256 rhsHi = numerator >> 64;
            bool fits = top == 0 && (hi < rhsHi || (hi == rhsHi && lo <= numerator << 192));
            if (fits) low = mid;
            else high = mid - 1;
        }
        require(low > 0, "PriceLib: price underflows uint160");
        return uint160(low);
    }

    /// @notice Sorted whole currency1 per whole currency0, rounded down to 1e18 precision.
    function priceE18From(uint160 sqrtPrice, uint8 decimals0, uint8 decimals1)
        internal
        pure
        returns (uint256)
    {
        _checkDecimals(decimals0, decimals1);
        (uint256 top, uint256 hi, uint256 lo) =
            _squareTimes(sqrtPrice, 10 ** (18 + uint256(decimals0) - decimals1));
        require(top == 0 && hi >> 192 == 0, "PriceLib: quote overflows uint256");
        return (hi << 64) | (lo >> 192);
    }

    function _checkDecimals(uint8 d0, uint8 d1) private pure {
        require(d0 <= 18 && d1 <= 18, "PriceLib: decimals > 18; use INITIAL_SQRT_PRICE");
    }

    /// @dev Three 256-bit limbs hold x*x*scale without truncation.
    function _squareTimes(uint256 x, uint256 scale)
        private
        pure
        returns (uint256 top, uint256 hi, uint256 lo)
    {
        (uint256 squareHi, uint256 squareLo) = _mul512(x, x);
        (uint256 carry, uint256 low) = _mul512(squareLo, scale);
        (uint256 upper, uint256 middle) = _mul512(squareHi, scale);
        unchecked {
            hi = middle + carry;
            top = upper + (hi < middle ? 1 : 0);
        }
        lo = low;
    }

    function _mul512(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }
}
