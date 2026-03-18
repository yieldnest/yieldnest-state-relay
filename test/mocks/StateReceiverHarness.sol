// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateReceiver} from "src/StateReceiver.sol";

/**
 * @title StateReceiverHarness
 * @notice Exposes payload delivery for unit tests without going through the LZ endpoint.
 */
contract StateReceiverHarness is StateReceiver {
    constructor(address _endpoint) StateReceiver(_endpoint) {}

    /// @dev Simulates _lzReceive payload handling: decode and write if version supported.
    function receivePayload(bytes calldata message) external {
        (uint8 version, bytes32 key, bytes memory value, uint64 srcTimestamp) =
            abi.decode(message, (uint8, bytes32, bytes, uint64));
        if (supportedVersions[version]) {
            stateStore.write(key, value, srcTimestamp);
            emit StateReceived(key, value, srcTimestamp);
        }
    }
}
