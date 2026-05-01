// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {KeyDerivation} from "./KeyDerivation.sol";
import {IRelayTransport} from "./interfaces/IRelayTransport.sol";

/**
 * @title StateSender
 * @notice Source-chain relay app: reads state, builds canonical payload, forwards through a transport adapter.
 */
contract StateSender is AccessControlUpgradeable, PausableUpgradeable {
    string public constant VERSION = "0.1.0";

    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant TRANSPORT_MANAGER_ROLE = keccak256("TRANSPORT_MANAGER_ROLE");

    struct SendStateQuote {
        IRelayTransport.TransportQuote transportQuote;
        bytes32 key;
        bytes message;
    }

    /// @custom:storage-location erc7201:yieldnest.storage.state_sender
    struct StateSenderStorage {
        IRelayTransport transport;
        address target;
        bytes callData;
        uint256 version;
    }

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

    /**
     * @notice Initializes the sender app with its transport and read target configuration.
     * @param _owner Address granted admin, config-manager, and transport-manager roles.
     * @param _transport Transport adapter used to quote and send relay messages.
     * @param _target Contract queried via `staticcall` for relay state.
     * @param _callData Calldata used for the state read on `_target`.
     * @param _version Version value encoded into outbound relay messages.
     */
    function initialize(address _owner, address _transport, address _target, bytes memory _callData, uint256 _version)
        external
        initializer
    {
        StateSenderStorage storage $ = _getStateSenderStorage();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(CONFIG_MANAGER_ROLE, _owner);
        _grantRole(TRANSPORT_MANAGER_ROLE, _owner);
        _setTransport(_transport);
        $.target = _target;
        $.callData = _callData;
        $.version = _version;
    }

    /**
     * @notice Pauses relay sends.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses relay sends.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Updates the transport adapter used for quoting and sending messages.
     * @param _transport Address of the new transport adapter.
     */
    function setTransport(address _transport) external onlyRole(TRANSPORT_MANAGER_ROLE) {
        _setTransport(_transport);
    }

    /**
     * @notice Updates the source contract queried for relay state.
     * @param _target Address of the new read target.
     */
    function setTarget(address _target) external onlyRole(CONFIG_MANAGER_ROLE) {
        StateSenderStorage storage $ = _getStateSenderStorage();
        emit TargetSet($.target, _target);
        $.target = _target;
    }

    /**
     * @notice Updates the calldata used to read state from the target contract.
     * @param _callData New calldata payload for the source-chain `staticcall`.
     */
    function setCallData(bytes memory _callData) external onlyRole(CONFIG_MANAGER_ROLE) {
        StateSenderStorage storage $ = _getStateSenderStorage();
        emit CallDataSet($.callData, _callData);
        $.callData = _callData;
    }

    /**
     * @notice Updates the version encoded into outbound relay messages.
     * @param _version New message version value.
     */
    function setVersion(uint256 _version) external onlyRole(CONFIG_MANAGER_ROLE) {
        StateSenderStorage storage $ = _getStateSenderStorage();
        emit VersionSet($.version, _version);
        $.version = _version;
    }

    /**
     * @notice Quotes a relay send for a destination and returns the built payload metadata.
     * @param destinationId Application-level destination identifier understood by the transport.
     * @dev NOTE: By convention, for EVM chains, destinationId is the chainId of the destination chain.  
     * @return quoteData Transport quote, derived key, and encoded message for the send.
     */
    function quoteSendState(uint256 destinationId) public view returns (SendStateQuote memory quoteData) {
        StateSenderStorage storage $ = _getStateSenderStorage();
        bytes memory stateData = _getStaticCallData();
        bytes32 key = KeyDerivation.deriveKey(block.chainid, $.target, $.callData);

        bytes memory message = _createMessage(key, stateData);

        IRelayTransport.TransportQuote memory quote = $.transport.quoteSend(destinationId, message);
        if (!quote.nativeFee) revert StateSender_NonNativeFeeUnsupported();

        return SendStateQuote({transportQuote: quote, key: key, message: message});
    }

    /**
     * @notice Reads the current state, quotes the fee, and sends the relay message.
     * @param destinationId Application-level destination identifier understood by the transport.
     */
    function sendState(uint256 destinationId) external payable whenNotPaused {
        SendStateQuote memory quoteData = quoteSendState(destinationId);
        if (msg.value < quoteData.transportQuote.feeAmount) revert StateSender_InsufficientNativeFee();
        _getStateSenderStorage().transport.send{value: msg.value}(destinationId, quoteData.message, msg.sender);
        emit StateSent(quoteData.key, destinationId, quoteData.message);
    }

    /**
     * @notice Returns the raw bytes read from the configured target contract.
     * @return Encoded return data from the configured `staticcall`.
     */
    function getStaticCallData() public view returns (bytes memory) {
        return _getStaticCallData();
    }

    /**
     * @notice Performs the configured `staticcall` against the source contract.
     * @return Encoded return data from the source contract.
     */
    function _getStaticCallData() internal view returns (bytes memory) {
        StateSenderStorage storage $ = _getStateSenderStorage();
        (bool success, bytes memory data) = $.target.staticcall($.callData);

        if (!success) revert StateSender_StaticcallFailed();

        return data;
    }

    /**
     * @notice Encodes the canonical relay payload.
     * @param key Deterministic relay key for the source read.
     * @param stateData Raw state bytes returned from the source contract.
     * @return Encoded relay payload including version, key, value, and source timestamp.
     */
    function _createMessage(bytes32 key, bytes memory stateData) internal view returns (bytes memory) {
        return abi.encode(_getStateSenderStorage().version, key, stateData, uint64(block.timestamp));
    }

    /**
     * @notice Updates the stored transport adapter reference.
     * @param _transport Address of the new transport adapter.
     */
    function _setTransport(address _transport) internal {
        StateSenderStorage storage $ = _getStateSenderStorage();
        if (_transport == address(0)) revert StateSender_InvalidTransport();
        emit TransportSet(address($.transport), _transport);
        $.transport = IRelayTransport(_transport);
    }

    // --- Getters ---

    /**
     * @notice Returns the configured transport adapter.
     * @return Configured transport adapter.
     */
    function transport() public view returns (IRelayTransport) {
        return _getStateSenderStorage().transport;
    }

    /**
     * @notice Returns the configured source read target.
     * @return Configured source read target.
     */
    function target() public view returns (address) {
        return _getStateSenderStorage().target;
    }

    /**
     * @notice Returns the configured source read calldata.
     * @return Configured source read calldata.
     */
    function callData() public view returns (bytes memory) {
        return _getStateSenderStorage().callData;
    }

    /**
     * @notice Returns the configured outbound relay version.
     * @return Configured outbound relay version.
     */
    function version() public view returns (uint256) {
        return _getStateSenderStorage().version;
    }

    /**
     * @notice Returns the namespaced storage blob for StateSender.
     * @dev Storage slot derivation:
     *      1. `namespace = keccak256("yieldnest.storage.state_sender")`
     *      2. `slot = 0xd2cf4d03df6a2cd4e2e16141189509923da0c783c15418b31ba778070d4b90e5`
     *      This repo intentionally uses one raw namespace hash per contract storage blob.
     * @return $ StateSender storage blob.
     */
    function _getStateSenderStorage() internal pure returns (StateSenderStorage storage $) {
        assembly {
            $.slot := 0xd2cf4d03df6a2cd4e2e16141189509923da0c783c15418b31ba778070d4b90e5
        }
    }
}
