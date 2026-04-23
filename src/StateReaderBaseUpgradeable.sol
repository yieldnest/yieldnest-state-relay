// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {StateStore} from "./StateStore.sol";

/**
 * @title StateReaderBaseUpgradeable
 * @notice Abstract reader: fetches bytes from StateStore by key and asserts staleness. Subclasses decode/validate.
 */
abstract contract StateReaderBaseUpgradeable is Initializable {
    uint256 internal constant MAX_SOURCE_TIMESTAMP_SKEW = 1 hours;

    StateStore public stateStore;
    bytes32 public stateKey;
    uint256 public maxSrcStaleness;
    uint256 public maxDstStaleness;

    error StateReaderBaseUpgradeable_ZeroAddress();
    error StateReaderBaseUpgradeable_SourceTimestampInFuture();
    error StateReaderBaseUpgradeable_SourceStale();
    error StateReaderBaseUpgradeable_DeliveryTimestampInFuture();
    error StateReaderBaseUpgradeable_DeliveryStale();

    /**
     * @notice Configures the store, relay key, and staleness thresholds for a reader.
     * @param _stateStore State store contract providing relayed values.
     * @param _stateKey Relay key to read from the store.
     * @param _maxSrcStaleness Maximum allowed age of the source timestamp.
     * @param _maxDstStaleness Maximum allowed age since delivery to the destination chain.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the store, relay key, and staleness thresholds for a reader.
     * @param _stateStore State store contract providing relayed values.
     * @param _stateKey Relay key to read from the store.
     * @param _maxSrcStaleness Maximum allowed age of the source timestamp.
     * @param _maxDstStaleness Maximum allowed age since delivery to the destination chain.
     */
    function __StateReaderBase_init(
        address _stateStore,
        bytes32 _stateKey,
        uint256 _maxSrcStaleness,
        uint256 _maxDstStaleness
    ) internal onlyInitializing {
        if (_stateStore == address(0)) revert StateReaderBaseUpgradeable_ZeroAddress();

        stateStore = StateStore(_stateStore);
        stateKey = _stateKey;
        maxSrcStaleness = _maxSrcStaleness;
        maxDstStaleness = _maxDstStaleness;
    }

    /**
     * @notice Returns the raw stored value after staleness checks pass.
     * @return Raw bytes stored under the configured relay key.
     */
    function _getValue() internal view returns (bytes memory) {
        StateStore.Entry memory entry = stateStore.get(stateKey);
        _assertStaleness(entry.srcTimestamp, entry.updatedAt);

        return entry.value;
    }

    /**
     * @notice Validates the source and delivery timestamps against the configured freshness windows.
     * @param srcTimestamp Timestamp captured on the source chain.
     * @param updatedAt Timestamp when the value was written on the destination chain.
     */
    function _assertStaleness(uint64 srcTimestamp, uint64 updatedAt) internal view {
        if (srcTimestamp > block.timestamp + MAX_SOURCE_TIMESTAMP_SKEW) {
            revert StateReaderBaseUpgradeable_SourceTimestampInFuture();
        }
        uint256 srcAge = srcTimestamp > block.timestamp ? 0 : block.timestamp - srcTimestamp;
        if (srcAge > maxSrcStaleness) revert StateReaderBaseUpgradeable_SourceStale();
        if (block.timestamp < updatedAt) revert StateReaderBaseUpgradeable_DeliveryTimestampInFuture();
        if (block.timestamp - updatedAt > maxDstStaleness) revert StateReaderBaseUpgradeable_DeliveryStale();
    }
}
