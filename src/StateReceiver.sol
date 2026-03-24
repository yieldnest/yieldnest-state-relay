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

    event SupportedVersionSet(uint8 version, bool supported);
    event StateReceived(bytes32 key, bytes value, uint64 srcTimestamp);
    event UnsupportedVersionReceived(uint8 version);
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    function initialize(address _owner, address _stateStore) external reinitializer(1) {
        require(_owner != address(0), "Invalid owner");
        require(_stateStore != address(0), "Invalid stateStore");
        __Ownable_init(_owner);
        __OApp_init(_owner);
        stateStore = StateStore(_stateStore);

        supportedVersions[1] = true;
    }

    function setSupportedVersion(uint8 version, bool supported) external onlyOwner {
        supportedVersions[version] = supported;
        emit SupportedVersionSet(version, supported);
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

        // check if version is supported
        if (supportedVersions[version]) {
            // call stateStore.write()
            stateStore.write(key, value, srcTimestamp);
            // emit event
            emit StateReceived(key, value, srcTimestamp);
        } else {
            emit UnsupportedVersionReceived(version);
        }
        // if version is not supported ignore the message
    }
}
