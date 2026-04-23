// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OAppUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {StateStore} from "./StateStore.sol";

/**
 * @title StateReceiver
 * @notice Destination-chain upgradeable OApp: receives LZ message, decodes, forwards to StateStore (stub).
 */
contract StateReceiver is OAppUpgradeable {
    StateStore public stateStore;
    mapping(uint8 => bool) public supportedVersions;

    event SupportedVersionSet(uint8 version, bool previousSupported, bool newSupported);
    event MessageReceived(uint8 version, bytes32 key, bytes value, uint64 srcTimestamp);
    event StaleMessageIgnored(uint8 version, bytes32 key, uint64 srcTimestamp);

    error StateReceiver_InvalidOwner();
    error StateReceiver_InvalidStateStore();
    error StateReceiver_UnsupportedVersion(uint8 version);
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    function initialize(address _owner, address _stateStore) external initializer {
        if (_owner == address(0)) revert StateReceiver_InvalidOwner();
        if (_stateStore == address(0)) revert StateReceiver_InvalidStateStore();
        __Ownable_init(_owner);
        __OApp_init(_owner);
        stateStore = StateStore(_stateStore);

        supportedVersions[1] = true;
    }

    function setSupportedVersion(uint8 version, bool supported) external onlyOwner {
        emit SupportedVersionSet(version, supportedVersions[version], supported);
        supportedVersions[version] = supported;
    }

    function _decodePayload(bytes calldata message)
        internal
        pure
        returns (uint8 version, bytes32 key, bytes memory value, uint64 srcTimestamp)
    {
        (version, key, value, srcTimestamp) = abi.decode(message, (uint8, bytes32, bytes, uint64));
    }

    function _lzReceive(Origin calldata, bytes32, bytes calldata _message, address, bytes calldata)
        internal
        virtual
        override
    {
        (uint8 version, bytes32 key, bytes memory value, uint64 srcTimestamp) = _decodePayload(_message);

        // Revert on unsupported versions so LayerZero retains the message for retry after upgrade.
        if (!supportedVersions[version]) revert StateReceiver_UnsupportedVersion(version);

        StateStore.WriteResult memory result =
            stateStore.write(key, StateStore.StateUpdate({value: value, version: version, srcTimestamp: srcTimestamp}));
        if (result.written) {
            emit MessageReceived(version, key, value, srcTimestamp);
        } else {
            emit StaleMessageIgnored(version, key, srcTimestamp);
        }
    }
}
