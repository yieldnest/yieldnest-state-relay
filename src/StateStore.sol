// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title StateStore
 * @notice Key -> value registry with timestamp and writer allowlist (stub).
 */
contract StateStore is Initializable, AccessControlUpgradeable {
    struct Entry {
        bytes value;
        uint64 srcTimestamp;
        uint64 updatedAt;
    }

    bytes32 public constant WRITER_MANAGER_ROLE = keccak256("WRITER_MANAGER_ROLE");
    bytes32 public constant WRITER_ROLE = keccak256("WRITER_ROLE");
    mapping(bytes32 => Entry) private _entries;

    event WriterSet(address indexed writer, bool allowed);
    event WriterManagerSet(address indexed writerManager, bool allowed);
    event StateUpdated(bytes32 indexed key, uint64 srcTimestamp, uint64 updatedAt);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address[] memory writers_) external initializer {
        __AccessControl_init();
        require(owner_ != address(0), "StateStore: owner cannot be 0");
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(WRITER_MANAGER_ROLE, owner_);
        _setRoleAdmin(WRITER_ROLE, WRITER_MANAGER_ROLE);
        for (uint256 i = 0; i < writers_.length; i++) {
            _grantRole(WRITER_ROLE, writers_[i]);
        }
    }

    function setWriterManager(address writerManager, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (allowed) {
            _grantRole(WRITER_MANAGER_ROLE, writerManager);
        } else {
            _revokeRole(WRITER_MANAGER_ROLE, writerManager);
        }
        emit WriterManagerSet(writerManager, allowed);
    }

    function setWriter(address writer, bool allowed) external onlyRole(WRITER_MANAGER_ROLE) {
        if (allowed) {
            _grantRole(WRITER_ROLE, writer);
        } else {
            _revokeRole(WRITER_ROLE, writer);
        }
        emit WriterSet(writer, allowed);
    }

    function isWriter(address account) public view returns (bool) {
        return hasRole(WRITER_ROLE, account);
    }

    function write(bytes32 key, bytes calldata value, uint64 srcTimestamp) external {
        require(isWriter(msg.sender), "StateStore: not writer");
        Entry storage e = _entries[key];
        require(srcTimestamp > e.srcTimestamp, "StateStore: stale");
        e.value = value;
        e.srcTimestamp = srcTimestamp;
        e.updatedAt = uint64(block.timestamp);
        emit StateUpdated(key, srcTimestamp, e.updatedAt);
    }

    function get(bytes32 key) external view returns (bytes memory value, uint64 srcTimestamp, uint64 updatedAt) {
        Entry storage e = _entries[key];
        return (e.value, e.srcTimestamp, e.updatedAt);
    }
}
