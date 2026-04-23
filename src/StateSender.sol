// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {KeyDerivation} from "./KeyDerivation.sol";
import {IRelayTransport} from "./interfaces/IRelayTransport.sol";

/**
 * @title StateSender
 * @notice Source-chain relay app: reads state, builds canonical payload, forwards through a transport adapter.
 */
contract StateSender is AccessControlUpgradeable {
    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");

    struct SendStateQuote {
        IRelayTransport.TransportQuote transportQuote;
        bytes32 key;
        bytes message;
    }

    IRelayTransport public transport;
    address public target;
    bytes public callData;
    uint256 public version;

    event StateSent(bytes32 key, uint256 destinationId, bytes message);
    event TransportSet(address previousTransport, address newTransport);
    event TargetSet(address previousTarget, address newTarget);
    event CallDataSet(bytes previousCallData, bytes newCallData);
    event VersionSet(uint256 previousVersion, uint256 newVersion);
    error StateSender_InsufficientNativeFee();
    error StateSender_NonNativeFeeUnsupported();
    error StateSender_StaticcallFailed();
    error StateSender_InvalidTransport();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _transport, address _target, bytes memory _callData, uint256 _version)
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

    function setVersion(uint256 _version) external onlyRole(CONFIG_MANAGER_ROLE) {
        emit VersionSet(version, _version);
        version = _version;
    }

    function quoteSendState(uint256 destinationId) public view returns (SendStateQuote memory quoteData) {
        bytes memory stateData = _getStaticCallData();
        bytes32 key = KeyDerivation.deriveKey(block.chainid, target, callData);
        bytes memory message = _createMessage(key, stateData);
        IRelayTransport.TransportQuote memory quote = transport.quoteSend(destinationId, message);
        if (!quote.nativeFee) revert StateSender_NonNativeFeeUnsupported();
        return SendStateQuote({transportQuote: quote, key: key, message: message});
    }

    function sendState(uint256 destinationId) external payable {
        SendStateQuote memory quoteData = quoteSendState(destinationId);
        if (msg.value < quoteData.transportQuote.feeAmount) revert StateSender_InsufficientNativeFee();
        transport.send{value: msg.value}(destinationId, quoteData.message, msg.sender);
        emit StateSent(quoteData.key, destinationId, quoteData.message);
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
