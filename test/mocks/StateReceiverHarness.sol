// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LayerZeroReceiverTransport} from "src/layerzero/LayerZeroReceiverTransport.sol";
import {StateStore} from "src/StateStore.sol";

/**
 * @title StateReceiverHarness
 * @notice Exposes payload delivery for unit tests without going through the LZ endpoint.
 */
contract StateReceiverHarness is LayerZeroReceiverTransport {
    constructor(address _endpoint) LayerZeroReceiverTransport(_endpoint) {}

    /// @dev Mirrors _lzReceive: decode, revert on unsupported version, write, emit events.
    function receivePayload(bytes calldata message) external {
        (uint8 version, bytes32 key, bytes memory value, uint64 srcTimestamp) =
            abi.decode(message, (uint8, bytes32, bytes, uint64));
        if (!supportedVersions[version]) revert LayerZeroReceiverTransport_UnsupportedVersion(version);
        StateStore.WriteResult memory result =
            stateStore.write(key, StateStore.StateUpdate({value: value, version: version, srcTimestamp: srcTimestamp}));
        if (result.written) {
            emit MessageReceived(version, key, value, srcTimestamp);
        } else {
            emit StaleMessageIgnored(version, key, srcTimestamp);
        }
    }
}
