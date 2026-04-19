// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OAppUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {KeyDerivation} from "./KeyDerivation.sol";

/**
 * @title StateSender
 * @notice Source-chain upgradeable OApp: reads state via staticcall, sends via _lzSend.
 * @dev Stub: key derivation and send logic to be implemented.
 */
contract StateSender is OAppUpgradeable {
    address public target;
    address public refundAddress;
    bytes public callData;
    uint8 public version;

    event StateSent(bytes32 key, uint32 dstEid, bytes message);
    event TargetSet(address target);
    event RefundAddressSet(address refundAddress);
    event CallDataSet(bytes callData);
    event VersionSet(uint8 version);
    error StateSender_LzTokenPaymentNotSupported();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {
        _disableInitializers();
    }

    /**
     * @notice Initialize the OApp and ownership.
     * @param _owner Delegate and owner (capable of configuring peers, etc.)
     * @param _target The target contract to send the state to
     * @param _callData The function signature and data to make the staticcall state retrieval from the target contract
     * @param _version The version of the state relay
     */
    function initialize(
        address _owner,
        address _target,
        address _refundAddress,
        bytes memory _callData,
        uint8 _version
    ) external reinitializer(1) {
        __Ownable_init(_owner);
        __OApp_init(_owner);
        target = _target;
        refundAddress = _refundAddress;
        callData = _callData;
        version = _version;
    }

    function setTarget(address _target) external onlyOwner {
        target = _target;
        emit TargetSet(_target);
    }

    function setRefundAddress(address _refundAddress) external onlyOwner {
        refundAddress = _refundAddress;
        emit RefundAddressSet(_refundAddress);
    }

    function setCallData(bytes memory _callData) external onlyOwner {
        callData = _callData;
        emit CallDataSet(_callData);
    }

    function setVersion(uint8 _version) external onlyOwner {
        version = _version;
        emit VersionSet(_version);
    }

    /// @notice Returns the messaging fee for sending state to _dstEid (for callers to pass as msg.value when paying).
    function quoteSendState(uint32 _dstEid) external view returns (MessagingFee memory fee) {
        bytes memory stateData = _getStaticCallData();
        bytes32 key = KeyDerivation.deriveKey(block.chainid, target, callData);
        bytes memory message = _createMessage(key, stateData);
        fee = _quote(_dstEid, message, _getDefaultOptions(), false);
        if (fee.lzTokenFee != 0) revert StateSender_LzTokenPaymentNotSupported();
    }

    function sendState(uint32 _dstEid) external payable {
        bytes memory stateData = _getStaticCallData();
        bytes32 key = KeyDerivation.deriveKey(block.chainid, target, callData);
        bytes memory message = _createMessage(key, stateData);
        bytes memory options = _getDefaultOptions();
        MessagingFee memory fee = _quote(_dstEid, message, options, false);
        if (fee.lzTokenFee != 0) revert StateSender_LzTokenPaymentNotSupported();

        require(msg.value >= fee.nativeFee, "StateSender: insufficient native fee");
        _lzSend(_dstEid, message, options, fee, refundAddress);

        emit StateSent(key, _dstEid, message);
    }

    /// @dev Options used for quote and send (executor lzReceive gas + value for destination).
    function _getDefaultOptions() internal pure returns (bytes memory) {
        return OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 300_000, 0);
    }

    function _getStaticCallData() internal view returns (bytes memory) {
        (bool success, bytes memory data) = target.staticcall(callData);

        require(success, "StateSender: staticcall failed");

        return data;
    }

    function _createMessage(bytes32 key, bytes memory stateData) internal view returns (bytes memory) {
        return abi.encode(version, key, stateData, uint64(block.timestamp));
    }

    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) internal virtual override {
        // Send-only OApp: no receive logic.
    }
}
