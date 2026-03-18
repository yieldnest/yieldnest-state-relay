// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OAppUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {StateStore} from "./StateStore.sol";

import {KeyDerivation} from "./KeyDerivation.sol";

/**
 * @title StateReceiver
 * @notice Destination-chain upgradeable OApp: receives LZ message, decodes, forwards to StateStore (stub).
 */
contract StateReceiver is OAppUpgradeable {
    StateStore public stateStore;
    mapping(uint8 => bool) public supportedVersions;

    event SupportedVersionSet(uint8 version, bool supported);
    event StateReceived(bytes32 key, bytes value, uint64 srcTimestamp);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    function initialize(address _owner, address _stateStore, uint8[] memory _supportedVersions)
        external
        reinitializer(1)
    {
        __Ownable_init(_owner);
        __OApp_init(_owner);
        stateStore = StateStore(_stateStore);
        for (uint256 i = 0; i < _supportedVersions.length; i++) {
            supportedVersions[_supportedVersions[i]] = true;
        }
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
        if(supportedVersions[version]) {
        // call stateStore.write()
        stateStore.write(key, value, srcTimestamp);
        // emit event
        emit StateReceived(key, value, srcTimestamp);
        }
        // if version is not supported ignore the message
    }
}
