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

    /// @dev Mirrors _lzReceive: forward raw payload to the store and emit based on the write result.
    function receivePayload(bytes calldata message) external {
        StateStore.WriteResult memory result = stateStore.write(message);
        if (result.written) {
            emit MessageReceived(result.version, result.key, result.value, result.srcTimestamp);
        } else {
            emit StaleMessageIgnored(result.version, result.key, result.srcTimestamp);
        }
    }
}
