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

    error StateReaderBase_ZeroAddress();
    error StateReaderBase_SourceTimestampInFuture();
    error StateReaderBase_SourceStale();
    error StateReaderBase_DeliveryTimestampInFuture();
    error StateReaderBase_DeliveryStale();

    constructor(address _stateStore, bytes32 _stateKey, uint256 _maxSrcStaleness, uint256 _maxDstStaleness) {
        if (_stateStore == address(0)) revert StateReaderBase_ZeroAddress();
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
        if (block.timestamp < srcTimestamp) revert StateReaderBase_SourceTimestampInFuture();
        if (block.timestamp - srcTimestamp > maxSrcStaleness) revert StateReaderBase_SourceStale();
        if (block.timestamp < updatedAt) revert StateReaderBase_DeliveryTimestampInFuture();
        if (block.timestamp - updatedAt > maxDstStaleness) revert StateReaderBase_DeliveryStale();
    }
}
