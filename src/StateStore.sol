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
        uint8 version;
        uint64 srcTimestamp;
    }

    struct Entry {
        bytes value;
        uint8 version;
        uint64 srcTimestamp;
        uint64 updatedAt;
    }

    bytes32 public constant WRITER_MANAGER_ROLE = keccak256("WRITER_MANAGER_ROLE");
    bytes32 public constant WRITER_ROLE = keccak256("WRITER_ROLE");
    mapping(bytes32 => Entry) private _entries;

    event StateUpdated(bytes32 indexed key, uint8 version, uint64 srcTimestamp, uint64 updatedAt);
    event StateIgnored(bytes32 indexed key, uint8 version, uint64 srcTimestamp, uint64 storedSrcTimestamp);

    error StateStore_OwnerCannotBeZero();
    error StateStore_NotWriter();
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address[] memory writers_) external initializer {
        __AccessControl_init();
        if (owner_ == address(0)) revert StateStore_OwnerCannotBeZero();
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(WRITER_MANAGER_ROLE, owner_);
        _setRoleAdmin(WRITER_ROLE, WRITER_MANAGER_ROLE);
        for (uint256 i = 0; i < writers_.length; i++) {
            _grantRole(WRITER_ROLE, writers_[i]);
        }
    }

    function isWriter(address account) public view returns (bool) {
        return hasRole(WRITER_ROLE, account);
    }

    function write(bytes32 key, StateUpdate calldata update) external returns (bool written) {
        if (!isWriter(msg.sender)) revert StateStore_NotWriter();
        Entry storage e = _entries[key];
        if (update.srcTimestamp <= e.srcTimestamp) {
            emit StateIgnored(key, update.version, update.srcTimestamp, e.srcTimestamp);
            return false;
        }
        e.value = update.value;
        e.version = update.version;
        e.srcTimestamp = update.srcTimestamp;
        e.updatedAt = uint64(block.timestamp);
        emit StateUpdated(key, update.version, update.srcTimestamp, e.updatedAt);
        return true;
    }

    function get(bytes32 key) external view returns (Entry memory) {
        return _entries[key];
    }
}
