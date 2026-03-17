// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateStore} from "./StateStore.sol";

/**
 * @title TestRateAdapter
 * @notice Example consumer: reads from StateStore, getRate() with staleness checks (stub).
 */
contract TestRateAdapter {
    StateStore public stateStore;
    bytes32 public rateKey;
    uint256 public maxSrcStaleness;
    uint256 public maxDstStaleness;

    constructor(address _stateStore, bytes32 _rateKey, uint256 _maxSrcStaleness, uint256 _maxDstStaleness) {
        stateStore = StateStore(_stateStore);
        rateKey = _rateKey;
        maxSrcStaleness = _maxSrcStaleness;
        maxDstStaleness = _maxDstStaleness;
    }

    function getRate() external view returns (uint256) {
        (, uint64 srcTimestamp, uint64 updatedAt) = stateStore.get(rateKey);
        require(block.timestamp - srcTimestamp <= maxSrcStaleness, "TestRateAdapter: source stale");
        require(block.timestamp - updatedAt <= maxDstStaleness, "TestRateAdapter: delivery stale");
        revert("TestRateAdapter: stub");
    }
}
