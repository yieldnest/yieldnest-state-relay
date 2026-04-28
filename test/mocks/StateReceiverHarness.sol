// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LayerZeroReceiverTransport} from "src/layerzero/LayerZeroReceiverTransport.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";

/**
 * @title StateReceiverHarness
 * @notice Exposes payload delivery for unit tests without going through the LZ endpoint.
 */
contract StateReceiverHarness is LayerZeroReceiverTransport {
    constructor(address _endpoint) LayerZeroReceiverTransport(_endpoint) {}

    /// @dev Invokes the LayerZero receive hook directly to mirror production control flow in tests.
    function receivePayload(bytes calldata message) external {
        this.receiveFromHarness(Origin({srcEid: 0, sender: bytes32(0), nonce: 0}), bytes32(0), message, address(0), "");
    }

    /// @dev Forwards calldata-typed arguments into the inherited internal receive hook.
    function receiveFromHarness(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external {
        _lzReceive(origin, guid, message, executor, extraData);
    }
}
