// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {StateStore} from "./StateStore.sol";

/**
 * @title StateReaderBaseUpgradeable
 * @notice Abstract reader: fetches bytes from StateStore by key and asserts staleness. Subclasses decode/validate.
 */
abstract contract StateReaderBaseUpgradeable is Initializable, AccessControlUpgradeable {
    string public constant VERSION = "0.1.0";

    /// @custom:storage-location erc7201:yieldnest.storage.state_reader_base
    struct StateReaderBaseStorage {
        StateStore stateStore;
        bytes32 stateKey;
        uint256 maxSrcStaleness;
        uint256 maxDstStaleness;
        uint256 maxSourceTimestampSkew;
    }

    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");
    bytes32 public constant STATE_STORE_MANAGER_ROLE = keccak256("STATE_STORE_MANAGER_ROLE");

    event StateKeySet(bytes32 previousStateKey, bytes32 newStateKey);
    event MaxSrcStalenessSet(uint256 previousMaxSrcStaleness, uint256 newMaxSrcStaleness);
    event MaxDstStalenessSet(uint256 previousMaxDstStaleness, uint256 newMaxDstStaleness);
    event MaxSourceTimestampSkewSet(uint256 previousMaxSourceTimestampSkew, uint256 newMaxSourceTimestampSkew);
    event StateStoreSet(address indexed previousStateStore, address indexed newStateStore);

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
     * @param _admin Address granted the default admin, config-manager, and state-store-manager roles.
     * @param _stateStore State store contract providing relayed values.
     * @param _stateKey Relay key to read from the store.
     * @param _maxSrcStaleness Maximum allowed age of the source timestamp.
     * @param _maxDstStaleness Maximum allowed age since delivery to the destination chain.
     * @param _maxSourceTimestampSkew Maximum allowed future skew for the source timestamp.
     */
    function __StateReaderBase_init(
        address _admin,
        address _stateStore,
        bytes32 _stateKey,
        uint256 _maxSrcStaleness,
        uint256 _maxDstStaleness,
        uint256 _maxSourceTimestampSkew
    ) internal onlyInitializing {
        StateReaderBaseStorage storage $ = _getStateReaderBaseStorage();
        if (_admin == address(0)) revert StateReaderBaseUpgradeable_ZeroAddress();
        if (_stateStore == address(0)) revert StateReaderBaseUpgradeable_ZeroAddress();

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(CONFIG_MANAGER_ROLE, _admin);
        _grantRole(STATE_STORE_MANAGER_ROLE, _admin);

        $.stateStore = StateStore(_stateStore);
        $.stateKey = _stateKey;
        $.maxSrcStaleness = _maxSrcStaleness;
        $.maxDstStaleness = _maxDstStaleness;
        $.maxSourceTimestampSkew = _maxSourceTimestampSkew;
    }

    /**
     * @notice Updates the relay key.
     * @param _stateKey Relay key to read from the store.
     */
    function setStateKey(bytes32 _stateKey) external onlyRole(CONFIG_MANAGER_ROLE) {
        StateReaderBaseStorage storage $ = _getStateReaderBaseStorage();
        emit StateKeySet($.stateKey, _stateKey);
        $.stateKey = _stateKey;
    }

    /**
     * @notice Updates the maximum allowed source timestamp staleness.
     * @param _maxSrcStaleness Maximum allowed age of the source timestamp.
     */
    function setMaxSrcStaleness(uint256 _maxSrcStaleness) external onlyRole(CONFIG_MANAGER_ROLE) {
        StateReaderBaseStorage storage $ = _getStateReaderBaseStorage();
        emit MaxSrcStalenessSet($.maxSrcStaleness, _maxSrcStaleness);
        $.maxSrcStaleness = _maxSrcStaleness;
    }

    /**
     * @notice Updates the maximum allowed destination delivery staleness.
     * @param _maxDstStaleness Maximum allowed age since delivery to the destination chain.
     */
    function setMaxDstStaleness(uint256 _maxDstStaleness) external onlyRole(CONFIG_MANAGER_ROLE) {
        StateReaderBaseStorage storage $ = _getStateReaderBaseStorage();
        emit MaxDstStalenessSet($.maxDstStaleness, _maxDstStaleness);
        $.maxDstStaleness = _maxDstStaleness;
    }

    /**
     * @notice Updates the maximum allowed future skew for the source timestamp.
     * @param _maxSourceTimestampSkew Maximum allowed future skew for the source timestamp.
     */
    function setMaxSourceTimestampSkew(uint256 _maxSourceTimestampSkew) external onlyRole(CONFIG_MANAGER_ROLE) {
        StateReaderBaseStorage storage $ = _getStateReaderBaseStorage();
        emit MaxSourceTimestampSkewSet($.maxSourceTimestampSkew, _maxSourceTimestampSkew);
        $.maxSourceTimestampSkew = _maxSourceTimestampSkew;
    }

    /**
     * @notice Updates the backing state store.
     * @param _stateStore New state store contract providing relayed values.
     */
    function setStateStore(address _stateStore) external onlyRole(STATE_STORE_MANAGER_ROLE) {
        if (_stateStore == address(0)) revert StateReaderBaseUpgradeable_ZeroAddress();

        StateReaderBaseStorage storage $ = _getStateReaderBaseStorage();
        emit StateStoreSet(address($.stateStore), _stateStore);
        $.stateStore = StateStore(_stateStore);
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
