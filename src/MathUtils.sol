// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// Import PRBMath libraries with specific functions to avoid conflicts
import {UD60x18, ud60x18} from "@prb/math/src/UD60x18.sol";
import {SD59x18, sd59x18} from "@prb/math/src/SD59x18.sol";

/**
 * @title MathUtils
 * @dev A library providing mathematical utilities using PRBMath for high-precision calculations
 * Updated to use PRBMath for ln() and exp() functions with much better accuracy
 */
library MathUtils {
    // Fixed point scale factor - matches PRBMath scale
    uint256 public constant SCALE = 1e18;

    /**
    * @dev Calculates the absolute difference between two signed integers
    * @param a First value (int256)
    * @param b Second value (int256)  
    * @return The absolute difference |a - b| as uint256
    */
    function abs(int256 a, int256 b) internal pure returns (uint256) {
        if (a >= b) {
            return uint256(a - b);
        } else {
            return uint256(b - a);
        }
    }

    /**
     * @dev Calculates the natural logarithm of a fixed-point number using PRBMath
     * @param x The value to calculate the logarithm for (scaled by SCALE)
     * @return Natural logarithm of x (scaled by SCALE)
     * @notice For x < SCALE (i.e., x < 1.0), this will revert since UD60x18.ln() doesn't handle values < 1
     */
    function ln(uint256 x) internal pure returns (uint256) {
        require(x > 0, "MathUtils: logarithm of zero or negative");
        require(x >= SCALE, "MathUtils: ln() requires x >= 1.0 for unsigned result");
        
        // Convert to PRBMath UD60x18 and calculate ln
        UD60x18 xUD = ud60x18(x);
        UD60x18 result = xUD.ln();
        
        // Convert back to uint256
        return result.unwrap();
    }
    
    /**
     * @dev Calculates |ln(x)| - the absolute value of natural logarithm
     * This is useful for lognormal error calculations where we need |ln(ratio)|
     * @param x The value to calculate the logarithm for (scaled by SCALE)
     * @return Absolute value of natural logarithm of x (scaled by SCALE)
     */
    function lnAbs(uint256 x) internal pure returns (uint256) {
        require(x > 0, "MathUtils: logarithm of zero or negative");
        
        if (x >= SCALE) {
            // For x >= 1.0, ln(x) >= 0, so |ln(x)| = ln(x)
            UD60x18 xUD = ud60x18(x);
            UD60x18 result = xUD.ln();
            return result.unwrap();
        } else {
            // For x < 1.0, ln(x) < 0, so |ln(x)| = -ln(x) = ln(1/x)
            UD60x18 oneUD = ud60x18(SCALE);
            UD60x18 xUD = ud60x18(x);
            UD60x18 inverseX = oneUD.div(xUD);
            UD60x18 result = inverseX.ln();
            return result.unwrap();
        }
    }
    
    /**
     * @dev Calculates e^x for a fixed-point number x using PRBMath
     * @param x The exponent (scaled by SCALE)
     * @return e^x (scaled by SCALE)
     */
    function exp(uint256 x) internal pure returns (uint256) {
        // Convert to PRBMath UD60x18 and calculate exp
        UD60x18 xUD = ud60x18(x);
        UD60x18 result = xUD.exp();
        
        // Convert back to uint256
        return result.unwrap();
    }
    
    /**
     * @dev Calculates e^x for a signed exponent using PRBMath
     * @param x The exponent (scaled by SCALE, can be negative)
     * @return e^x (scaled by SCALE)
     */
    function expSigned(int256 x) internal pure returns (uint256) {
        // Convert to PRBMath SD59x18 and calculate exp
        SD59x18 xSD = sd59x18(x);
        SD59x18 resultSD = xSD.exp();
        
        // Convert back to uint256 (exp is always positive)
        // Note: SD59x18 unwrap gives int256, but exp result is always positive
        int256 resultInt = resultSD.unwrap();
        require(resultInt >= 0, "MathUtils: exp result should be positive");
        return uint256(resultInt);
    }

    /**
     * @dev Safely converts int256 to uint256, reverts on negative
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "MathUtils: negative value");
        return uint256(value);
    }

    /**
     * @dev Safely converts uint256 to int256, reverts on overflow
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        require(value <= uint256(type(int256).max), "MathUtils: overflow");
        return int256(value);
    }
    
    /**
     * @dev Multiplies two fixed-point numbers using PRBMath
     * @param x First number (scaled by SCALE)
     * @param y Second number (scaled by SCALE)
     * @return Product (scaled by SCALE)
     */
    function mul(uint256 x, uint256 y) internal pure returns (uint256) {
        UD60x18 xUD = ud60x18(x);
        UD60x18 yUD = ud60x18(y);
        UD60x18 result = xUD.mul(yUD);
        return result.unwrap();
    }
    
    /**
     * @dev Divides two fixed-point numbers using PRBMath
     * @param x Dividend (scaled by SCALE)
     * @param y Divisor (scaled by SCALE)
     * @return Quotient (scaled by SCALE)
     */
    function div(uint256 x, uint256 y) internal pure returns (uint256) {
        UD60x18 xUD = ud60x18(x);
        UD60x18 yUD = ud60x18(y);
        UD60x18 result = xUD.div(yUD);
        return result.unwrap();
    }
    
    /**
     * @dev Squares a fixed-point number using PRBMath
     * @param x Number to square (scaled by SCALE)
     * @return x^2 (scaled by SCALE)
     */
    function square(uint256 x) internal pure returns (uint256) {
        return mul(x, x);
    }
    
    /**
     * @dev Calculates the square root of a fixed-point number using PRBMath
     * @param x Number to calculate square root for (scaled by SCALE)
     * @return sqrt(x) (scaled by SCALE)
     */
    function sqrt(uint256 x) internal pure returns (uint256) {
        UD60x18 xUD = ud60x18(x);
        UD60x18 result = xUD.sqrt();
        return result.unwrap();
    }
    
    /**
     * @dev Raises a number to a power using PRBMath
     * @param base Base number (scaled by SCALE)
     * @param exponent Exponent (scaled by SCALE)
     * @return base^exponent (scaled by SCALE)
     */
    function pow(uint256 base, uint256 exponent) internal pure returns (uint256) {
        UD60x18 baseUD = ud60x18(base);
        UD60x18 exponentUD = ud60x18(exponent);
        UD60x18 result = baseUD.pow(exponentUD);
        return result.unwrap();
    }

    /**
     * @dev Helper function to convert a regular number to fixed-point
     * @param x Regular number
     * @return Fixed-point representation (scaled by SCALE)
     */
    function fromUint(uint256 x) internal pure returns (uint256) {
        return x * SCALE;
    }
    
    /**
     * @dev Helper function to convert fixed-point to regular number
     * @param x Fixed-point number (scaled by SCALE)
     * @return Regular number representation
     */
    function toUint(uint256 x) internal pure returns (uint256) {
        return x / SCALE;
    }
    
    /**
     * @dev Helper function for percentage calculations
     * @param value The value to calculate percentage of
     * @param percentage The percentage (e.g., 5 for 5%)
     * @return The percentage of the value
     */
    function percentage(uint256 value, uint256 percentage) internal pure returns (uint256) {
        return (value * percentage) / 100;
    }
    
    /**
     * @dev Helper function to check if a number is close to another within tolerance
     * @param a First number
     * @param b Second number  
     * @param tolerance Tolerance level (scaled by SCALE)
     * @return Whether the numbers are close within tolerance
     */
    function isClose(uint256 a, uint256 b, uint256 tolerance) internal pure returns (bool) {
        if (a > b) {
            return (a - b) <= tolerance;
        } else {
            return (b - a) <= tolerance;
        }
    }
}