// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OAppUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {StateStore} from "../StateStore.sol";

/**
 * @title LayerZeroReceiverTransport
 * @notice Destination-chain upgradeable OApp: receives LZ message, decodes, forwards to StateStore (stub).
 */
contract LayerZeroReceiverTransport is OAppUpgradeable {
    StateStore public stateStore;

    event MessageReceived(uint256 version, bytes32 key, bytes value, uint64 srcTimestamp);
    event StaleMessageIgnored(uint256 version, bytes32 key, uint64 srcTimestamp);

    error LayerZeroReceiverTransport_InvalidOwner();
    error LayerZeroReceiverTransport_InvalidStateStore();
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {
        _disableInitializers();
    }

    function initialize(address _owner, address _stateStore) external initializer {
        if (_owner == address(0)) revert LayerZeroReceiverTransport_InvalidOwner();
        if (_stateStore == address(0)) revert LayerZeroReceiverTransport_InvalidStateStore();
        __Ownable_init(_owner);
        __OApp_init(_owner);
        stateStore = StateStore(_stateStore);
    }

    function _lzReceive(Origin calldata, bytes32, bytes calldata _message, address, bytes calldata)
        internal
        virtual
        override
    {
        StateStore.WriteResult memory result = stateStore.write(_message);
        if (result.written) {
            emit MessageReceived(result.version, result.key, result.value, result.srcTimestamp);
        } else {
            emit StaleMessageIgnored(result.version, result.key, result.srcTimestamp);
        }
    }
}
