// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OApp} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";

/**
 * @title MessageSink
 * @notice Minimal OApp receiver that stores the last received messages for testing as an append-only array,
 *         while still tracking the last received message separately. Allows querying messages and origins by index.
 */
contract MessageSink is OApp {
    bytes public lastMessage;
    Origin public lastOrigin;

    // Append-only array of received messages and their origins
    bytes[] public messages;
    Origin[] public origins;

    constructor(address _endpoint, address _delegate) OApp(_endpoint, _delegate) Ownable(_delegate) {}

    function _lzReceive(
        Origin calldata _origin,
        bytes32, 
        bytes calldata _message,
        address,
        bytes calldata
    )
        internal
        virtual
        override
    {
        lastOrigin = _origin;
        lastMessage = _message;

        messages.push(_message);
        origins.push(_origin);
    }

    /**
     * @notice Returns the number of messages received (and stored).
     */
    function messageCount() external view returns (uint256) {
        return messages.length;
    }

    /**
     * @notice Returns the message and origin at a specific index.
     * @param index The index of the message.
     * @return origin The origin at the given index.
     * @return message The message at the given index.
     */
    function messageAt(uint256 index) external view returns (Origin memory origin, bytes memory message) {
        require(index < messages.length, "index out of bounds");
        origin = origins[index];
        message = messages[index];
    }
}
