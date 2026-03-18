// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title MockRateTarget
 * @notice Mock contract that returns a fixed rate for staticcall (e.g. getRate()).
 */
contract MockRateTarget {
    uint256 public rate = 1e18;

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }
}
