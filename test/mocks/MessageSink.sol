// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OApp} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";

/**
 * @title MessageSink
 * @notice Minimal OApp receiver that stores the last received message for testing.
 */
contract MessageSink is OApp {
    bytes public lastMessage;
    Origin public lastOrigin;

    constructor(address _endpoint, address _delegate) OApp(_endpoint, _delegate) Ownable(_delegate) {}

    function _lzReceive(Origin calldata _origin, bytes32, bytes calldata _message, address, bytes calldata)
        internal
        virtual
        override
    {
        lastOrigin = _origin;
        lastMessage = _message;
    }
}
