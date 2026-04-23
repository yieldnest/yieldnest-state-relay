// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title StateStore
 * @notice Key -> value registry with timestamp and writer allowlist (stub).
 */
contract StateStore is Initializable, AccessControlUpgradeable {
    struct StateUpdate {
        bytes value;
        uint256 version;
        uint64 srcTimestamp;
    }

    struct Entry {
        bytes value;
        uint256 version;
        uint64 srcTimestamp;
        uint64 updatedAt;
    }

    struct WriteResult {
        bool written;
        bytes32 key;
        bytes value;
        uint256 version;
        uint64 srcTimestamp;
    }

    bytes32 public constant VERSION_MANAGER_ROLE = keccak256("VERSION_MANAGER_ROLE");
    bytes32 public constant WRITER_MANAGER_ROLE = keccak256("WRITER_MANAGER_ROLE");
    bytes32 public constant WRITER_ROLE = keccak256("WRITER_ROLE");
    mapping(bytes32 => Entry) private _entries;
    mapping(uint256 => bool) public supportedVersions;

    event SupportedVersionSet(uint256 version, bool previousSupported, bool newSupported);
    event StateUpdated(bytes32 indexed key, uint256 version, uint64 srcTimestamp, uint64 updatedAt);
    event StateIgnored(bytes32 indexed key, uint256 version, uint64 srcTimestamp, uint64 storedSrcTimestamp);

    error StateStore_OwnerCannotBeZero();
    error StateStore_NotWriter();
    error StateStore_UnsupportedVersion(uint256 version);
    /// @custom:oz-upgrades-unsafe-allow constructor

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the store and seeds its initial writer set.
     * @param owner_ Address granted the default admin, version-manager, and writer-manager roles.
     * @param writers_ Addresses granted the writer role at initialization.
     */
    function initialize(address owner_, address[] memory writers_) external initializer {
        __AccessControl_init();
        if (owner_ == address(0)) revert StateStore_OwnerCannotBeZero();
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(VERSION_MANAGER_ROLE, owner_);
        _grantRole(WRITER_MANAGER_ROLE, owner_);
        _setRoleAdmin(WRITER_ROLE, WRITER_MANAGER_ROLE);
        for (uint256 i = 0; i < writers_.length; i++) {
            _grantRole(WRITER_ROLE, writers_[i]);
        }

        supportedVersions[1] = true;
    }

    /**
     * @notice Returns whether an account is authorized to write relay updates.
     * @param account Address to query.
     * @return True if `account` holds `WRITER_ROLE`.
     */
    function isWriter(address account) public view returns (bool) {
        return hasRole(WRITER_ROLE, account);
    }

    /**
     * @notice Enables or disables a supported relay message version.
     * @param version Version value to update.
     * @param supported Whether the version should be accepted.
     */
    function setSupportedVersion(uint256 version, bool supported) external onlyRole(VERSION_MANAGER_ROLE) {
        emit SupportedVersionSet(version, supportedVersions[version], supported);
        supportedVersions[version] = supported;
    }

    /**
     * @notice Decodes a raw relay payload and applies it to the store.
     * @param message Encoded relay payload containing version, key, value, and source timestamp.
     * @return result Structured write result including whether storage changed.
     */
    function write(bytes calldata message) external onlyRole(WRITER_ROLE) returns (WriteResult memory result) {
        (uint256 version, bytes32 key, bytes memory value, uint64 srcTimestamp) =
            abi.decode(message, (uint256, bytes32, bytes, uint64));
        StateUpdate memory update = StateUpdate({value: value, version: version, srcTimestamp: srcTimestamp});
        return _write(key, update);
    }

    /**
     * @notice Applies a decoded state update for a specific key.
     * @param key Deterministic relay key for the value being written.
     * @param update Decoded state update payload.
     * @return result Structured write result including whether storage changed.
     */
    function write(bytes32 key, StateUpdate calldata update)
        external
        onlyRole(WRITER_ROLE)
        returns (WriteResult memory result)
    {
        return _write(key, update);
    }

    /**
     * @notice Applies a decoded state update after writer and version checks.
     * @param key Deterministic relay key for the value being updated.
     * @param update Decoded state update payload.
     * @return result Structured write result including whether storage changed.
     */
    function _write(bytes32 key, StateUpdate memory update) internal returns (WriteResult memory result) {
        if (!isWriter(msg.sender)) revert StateStore_NotWriter();
        if (!supportedVersions[update.version]) revert StateStore_UnsupportedVersion(update.version);
        Entry storage e = _entries[key];
        if (update.srcTimestamp <= e.srcTimestamp) {
            emit StateIgnored(key, update.version, update.srcTimestamp, e.srcTimestamp);
            return WriteResult({
                written: false,
                key: key,
                value: update.value,
                version: update.version,
                srcTimestamp: update.srcTimestamp
            });
        }
        e.value = update.value;
        e.version = update.version;
        e.srcTimestamp = update.srcTimestamp;
        e.updatedAt = uint64(block.timestamp);
        emit StateUpdated(key, update.version, update.srcTimestamp, e.updatedAt);
        return WriteResult({
            written: true,
            key: key,
            value: update.value,
            version: update.version,
            srcTimestamp: update.srcTimestamp
        });
    }

    /**
     * @notice Returns the stored entry for a relay key.
     * @param key Deterministic relay key to read.
     * @return Stored entry for `key`.
     */
    function get(bytes32 key) external view returns (Entry memory) {
        return _entries[key];
    }
}
