// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateStore} from "./StateStore.sol";

/**
 * @title StateReaderBase
 * @notice Abstract reader: fetches bytes from StateStore by key and asserts staleness. Subclasses decode/validate.
 */
abstract contract StateReaderBase {
    StateStore public stateStore;
    bytes32 public stateKey;
    uint256 public maxSrcStaleness;
    uint256 public maxDstStaleness;

    constructor(address _stateStore, bytes32 _stateKey, uint256 _maxSrcStaleness, uint256 _maxDstStaleness) {
        require(_stateStore != address(0), "StateReaderBase: zero address");
        stateStore = StateStore(_stateStore);
        stateKey = _stateKey;
        maxSrcStaleness = _maxSrcStaleness;
        maxDstStaleness = _maxDstStaleness;
    }

    /// @dev Returns raw value after staleness checks. Subclasses use this and decode to their type.
    function _getValue() internal view returns (bytes memory) {
        (bytes memory data, uint64 srcTimestamp, uint64 updatedAt) = stateStore.get(stateKey);
        _assertStaleness(srcTimestamp, updatedAt);
        return data;
    }
    function _assertStaleness(uint64 srcTimestamp, uint64 updatedAt) internal view {
        require(block.timestamp >= srcTimestamp, "StateReaderBase: source timestamp in future");
        require(block.timestamp - srcTimestamp <= maxSrcStaleness, "StateReaderBase: source stale");
        require(block.timestamp >= updatedAt, "StateReaderBase: delivery timestamp in future");
        require(block.timestamp - updatedAt <= maxDstStaleness, "StateReaderBase: delivery stale");
    }

}
