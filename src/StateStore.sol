// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IStateStore} from "./interfaces/IStateStore.sol";

/**
 * @title StateStore
 * @notice Key -> value registry with timestamp and writer allowlist (stub).
 */
contract StateStore is Initializable, OwnableUpgradeable, IStateStore {
    struct Entry {
        bytes value;
        uint64 srcTimestamp;
        uint64 updatedAt;
    }

    mapping(bytes32 => Entry) private _entries;
    mapping(address => bool) private _writers;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address[] memory writers_) external initializer {
        __Ownable_init(owner_);
        for (uint256 i = 0; i < writers_.length; i++) {
            _writers[writers_[i]] = true;
        }
    }

    function setWriter(address writer, bool allowed) external onlyOwner {
        _writers[writer] = allowed;
        emit WriterSet(writer, allowed);
    }

    function isWriter(address account) public view returns (bool) {
        return _writers[account];
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
