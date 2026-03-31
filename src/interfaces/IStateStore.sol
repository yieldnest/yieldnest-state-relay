// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @notice Key → value registry with source timestamp; writer-gated updates (see `StateStore`).
 */
interface IStateStore {
    event WriterSet(address indexed writer, bool allowed);
    event StateUpdated(bytes32 indexed key, uint64 srcTimestamp, uint64 updatedAt);

    function initialize(address owner_, address[] memory writers_) external;
    function setWriter(address writer, bool allowed) external;
    function isWriter(address account) external view returns (bool);
    function write(bytes32 key, bytes calldata value, uint64 srcTimestamp) external;
    function get(bytes32 key) external view returns (bytes memory value, uint64 srcTimestamp, uint64 updatedAt);
}
