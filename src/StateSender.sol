// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {KeyDerivation} from "./KeyDerivation.sol";
import {IRelayTransport} from "./IRelayTransport.sol";

/**
 * @title StateSender
 * @notice Source-chain relay app: reads state, builds canonical payload, forwards through a transport adapter.
 */
contract StateSender is AccessControlUpgradeable {
    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");

    IRelayTransport public transport;
    address public target;
    bytes public callData;
    uint8 public version;

    event StateSent(bytes32 key, uint256 destinationId, bytes message);
    event TransportSet(address previousTransport, address newTransport);
    event TargetSet(address previousTarget, address newTarget);
    event CallDataSet(bytes previousCallData, bytes newCallData);
    event VersionSet(uint8 previousVersion, uint8 newVersion);
    error StateSender_InsufficientNativeFee();
    error StateSender_StaticcallFailed();
    error StateSender_InvalidTransport();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _transport, address _target, bytes memory _callData, uint8 _version)
        external
        initializer
    {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(CONFIG_MANAGER_ROLE, _owner);
        _setTransport(_transport);
        target = _target;
        callData = _callData;
        version = _version;
    }

    function setTransport(address _transport) external onlyRole(CONFIG_MANAGER_ROLE) {
        _setTransport(_transport);
    }

    function setTarget(address _target) external onlyRole(CONFIG_MANAGER_ROLE) {
        emit TargetSet(target, _target);
        target = _target;
    }

    function setCallData(bytes memory _callData) external onlyRole(CONFIG_MANAGER_ROLE) {
        emit CallDataSet(callData, _callData);
        callData = _callData;
    }

    function setVersion(uint8 _version) external onlyRole(CONFIG_MANAGER_ROLE) {
        emit VersionSet(version, _version);
        version = _version;
    }

    function quoteSendState(uint256 destinationId) external view returns (uint256 nativeFee) {
        bytes memory stateData = _getStaticCallData();
        bytes32 key = KeyDerivation.deriveKey(block.chainid, target, callData);
        bytes memory message = _createMessage(key, stateData);
        return transport.quoteSend(destinationId, message);
    }

    function sendState(uint256 destinationId) external payable {
        bytes memory stateData = _getStaticCallData();
        bytes32 key = KeyDerivation.deriveKey(block.chainid, target, callData);
        bytes memory message = _createMessage(key, stateData);
        uint256 nativeFee = transport.quoteSend(destinationId, message);
        if (msg.value < nativeFee) revert StateSender_InsufficientNativeFee();
        transport.send{value: msg.value}(destinationId, message, msg.sender);
        emit StateSent(key, destinationId, message);
    }

    function getStaticCallData() public view returns (bytes memory) {
        return _getStaticCallData();
    }

    function _getStaticCallData() internal view returns (bytes memory) {
        (bool success, bytes memory data) = target.staticcall(callData);

        if (!success) revert StateSender_StaticcallFailed();

        return data;
    }

    function _createMessage(bytes32 key, bytes memory stateData) internal view returns (bytes memory) {
        return abi.encode(version, key, stateData, uint64(block.timestamp));
    }

    function _setTransport(address _transport) internal {
        if (_transport == address(0)) revert StateSender_InvalidTransport();
        emit TransportSet(address(transport), _transport);
        transport = IRelayTransport(_transport);
    }
}
