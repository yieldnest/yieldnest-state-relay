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
    /// @custom:storage-location erc7201:yieldnest.storage.lz_receiver_transport
    struct LayerZeroReceiverTransportStorage {
        StateStore stateStore;
    }

    event MessageReceived(uint256 version, bytes32 key, bytes value, uint64 srcTimestamp);
    event StaleMessageIgnored(uint256 version, bytes32 key, uint64 srcTimestamp);

    error LayerZeroReceiverTransport_InvalidOwner();
    error LayerZeroReceiverTransport_InvalidStateStore();

    /// @custom:oz-upgrades-unsafe-allow constructor

    constructor(address _endpoint) OAppUpgradeable(_endpoint) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the LayerZero receiver transport with its backing state store.
     * @param _owner Owner and LayerZero delegate for this transport.
     * @param _stateStore Store that will validate and persist inbound relay messages.
     */
    function initialize(address _owner, address _stateStore) external initializer {
        if (_owner == address(0)) revert LayerZeroReceiverTransport_InvalidOwner();
        if (_stateStore == address(0)) revert LayerZeroReceiverTransport_InvalidStateStore();
        __Ownable_init(_owner);
        __OApp_init(_owner);
        _getLayerZeroReceiverTransportStorage().stateStore = StateStore(_stateStore);
    }

    /**
     * @notice Handles an inbound LayerZero payload by forwarding it to the state store.
     * @param _message Raw relay payload delivered by LayerZero.
     */
    function _lzReceive(Origin calldata, bytes32, bytes calldata _message, address, bytes calldata)
        internal
        virtual
        override
    {
        StateStore.WriteResult memory result = _getLayerZeroReceiverTransportStorage().stateStore.write(_message);
        if (result.written) {
            emit MessageReceived(result.version, result.key, result.value, result.srcTimestamp);
        } else {
            emit StaleMessageIgnored(result.version, result.key, result.srcTimestamp);
        }
    }

    // --- Getters ---

    /**
     * @notice Returns the backing state store used by this receiver transport.
     * @return Backing state store used by this receiver transport.
     */
    function stateStore() public view returns (StateStore) {
        return _getLayerZeroReceiverTransportStorage().stateStore;
    }

    /**
     * @notice Returns the namespaced storage blob for LayerZeroReceiverTransport.
     * @dev Storage slot derivation:
     *      1. `namespace = keccak256("yieldnest.storage.lz_receiver_transport")`
     *      2. `slot = 0xf15fd915d2a9a1528c951b0b7e3d2c820da02b93c5079cfc782c4509bf106392`
     *      This repo intentionally uses one raw namespace hash per contract storage blob.
     * @return $ LayerZeroReceiverTransport storage blob.
     */
    function _getLayerZeroReceiverTransportStorage()
        internal
        pure
        returns (LayerZeroReceiverTransportStorage storage $)
    {
        assembly {
            $.slot := 0xf15fd915d2a9a1528c951b0b7e3d2c820da02b93c5079cfc782c4509bf106392
        }
    }
}
