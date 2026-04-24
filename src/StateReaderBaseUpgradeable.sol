// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {StateStore} from "./StateStore.sol";

/**
 * @title StateReaderBaseUpgradeable
 * @notice Abstract reader: fetches bytes from StateStore by key and asserts staleness. Subclasses decode/validate.
 */
abstract contract StateReaderBaseUpgradeable is Initializable {
    /// @custom:storage-location erc7201:yieldnest.storage.state_reader_base
    struct StateReaderBaseStorage {
        StateStore stateStore;
        bytes32 stateKey;
        uint256 maxSrcStaleness;
        uint256 maxDstStaleness;
        uint256 maxSourceTimestampSkew;
    }

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
     * @param _maxSourceTimestampSkew Maximum allowed future skew for the source timestamp.
     */
    function __StateReaderBase_init(
        address _stateStore,
        bytes32 _stateKey,
        uint256 _maxSrcStaleness,
        uint256 _maxDstStaleness,
        uint256 _maxSourceTimestampSkew
    ) internal onlyInitializing {
        StateReaderBaseStorage storage $ = _getStateReaderBaseStorage();
        if (_stateStore == address(0)) revert StateReaderBaseUpgradeable_ZeroAddress();

        $.stateStore = StateStore(_stateStore);
        $.stateKey = _stateKey;
        $.maxSrcStaleness = _maxSrcStaleness;
        $.maxDstStaleness = _maxDstStaleness;
        $.maxSourceTimestampSkew = _maxSourceTimestampSkew;
    }

    /**
     * @notice Returns the raw stored value after staleness checks pass.
     * @return Raw bytes stored under the configured relay key.
     */
    function _getValue() internal view returns (bytes memory) {
        StateReaderBaseStorage storage $ = _getStateReaderBaseStorage();
        StateStore.Entry memory entry = $.stateStore.get($.stateKey);
        _assertStaleness(entry.srcTimestamp, entry.updatedAt);

        return entry.value;
    }

    /**
     * @notice Validates the source and delivery timestamps against the configured freshness windows.
     * @param srcTimestamp Timestamp captured on the source chain.
     * @param updatedAt Timestamp when the value was written on the destination chain.
     */
    function _assertStaleness(uint64 srcTimestamp, uint64 updatedAt) internal view {
        StateReaderBaseStorage storage $ = _getStateReaderBaseStorage();
        if (srcTimestamp > block.timestamp + $.maxSourceTimestampSkew) {
            revert StateReaderBaseUpgradeable_SourceTimestampInFuture();
        }
        uint256 srcAge = srcTimestamp > block.timestamp ? 0 : block.timestamp - srcTimestamp;
        if (srcAge > $.maxSrcStaleness) revert StateReaderBaseUpgradeable_SourceStale();
        if (block.timestamp < updatedAt) revert StateReaderBaseUpgradeable_DeliveryTimestampInFuture();
        if (block.timestamp - updatedAt > $.maxDstStaleness) revert StateReaderBaseUpgradeable_DeliveryStale();
    }

    // --- Getters ---

    /**
     * @notice Returns the backing state store for this reader.
     * @return Backing state store for this reader.
     */
    function stateStore() public view returns (StateStore) {
        return _getStateReaderBaseStorage().stateStore;
    }

    /**
     * @notice Returns the relay key read by this reader.
     * @return Relay key read by this reader.
     */
    function stateKey() public view returns (bytes32) {
        return _getStateReaderBaseStorage().stateKey;
    }

    /**
     * @notice Returns the maximum allowed source timestamp staleness.
     * @return Maximum allowed source timestamp staleness.
     */
    function maxSrcStaleness() public view returns (uint256) {
        return _getStateReaderBaseStorage().maxSrcStaleness;
    }

    /**
     * @notice Returns the maximum allowed destination delivery staleness.
     * @return Maximum allowed destination delivery staleness.
     */
    function maxDstStaleness() public view returns (uint256) {
        return _getStateReaderBaseStorage().maxDstStaleness;
    }

    /**
     * @notice Returns the maximum allowed future skew for the source timestamp.
     * @return Maximum allowed future skew for the source timestamp.
     */
    function maxSourceTimestampSkew() public view returns (uint256) {
        return _getStateReaderBaseStorage().maxSourceTimestampSkew;
    }

    /**
     * @notice Returns the namespaced storage blob for StateReaderBaseUpgradeable.
     * @dev Storage slot derivation:
     *      1. `namespace = keccak256("yieldnest.storage.state_reader_base")`
     *      2. `slot = 0x2b15c139dd60eac5612cc56eb7ffca03998fef00f8172107057408ad48a11a56`
     *      This repo intentionally uses one raw namespace hash per contract storage blob.
     * @return $ StateReaderBaseUpgradeable storage blob.
     */
    function _getStateReaderBaseStorage() internal pure returns (StateReaderBaseStorage storage $) {
        assembly {
            $.slot := 0x2b15c139dd60eac5612cc56eb7ffca03998fef00f8172107057408ad48a11a56
        }
    }
}
