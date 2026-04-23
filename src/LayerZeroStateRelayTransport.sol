// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OAppUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {IRelayTransport} from "./IRelayTransport.sol";

contract LayerZeroStateRelayTransport is OAppUpgradeable, IRelayTransport {
    struct DestinationConfig {
        uint32 lzEid;
        bytes32 peer;
        bytes options;
        bool enabled;
    }

    mapping(uint256 => DestinationConfig) public destinations;

    event DestinationSet(uint256 indexed destinationId, uint32 lzEid, bytes32 peer, bytes options, bool enabled);
    event MessageSent(uint256 indexed destinationId, uint32 lzEid, bytes message, address refundTo);

    error LayerZeroStateRelayTransport_InvalidOwner();
    error LayerZeroStateRelayTransport_DestinationNotEnabled(uint256 destinationId);
    error LayerZeroStateRelayTransport_InsufficientNativeFee();
    error LayerZeroStateRelayTransport_LzTokenPaymentNotSupported();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {
        _disableInitializers();
    }

    function initialize(address _owner) external reinitializer(1) {
        if (_owner == address(0)) revert LayerZeroStateRelayTransport_InvalidOwner();
        __Ownable_init(_owner);
        __OApp_init(_owner);
    }

    function setDestination(
        uint256 destinationId,
        uint32 lzEid,
        bytes32 peer,
        bytes calldata options,
        bool enabled
    ) external onlyOwner {
        destinations[destinationId] = DestinationConfig({lzEid: lzEid, peer: peer, options: options, enabled: enabled});
        setPeer(lzEid, peer);
        emit DestinationSet(destinationId, lzEid, peer, options, enabled);
    }

    function quoteSend(uint256 destinationId, bytes calldata message) external view returns (uint256 nativeFee) {
        DestinationConfig storage destination = _getDestinationOrRevert(destinationId);
        MessagingFee memory fee = _quote(destination.lzEid, message, destination.options, false);
        if (fee.lzTokenFee != 0) revert LayerZeroStateRelayTransport_LzTokenPaymentNotSupported();
        return fee.nativeFee;
    }

    function send(uint256 destinationId, bytes calldata message, address refundTo) external payable {
        DestinationConfig storage destination = _getDestinationOrRevert(destinationId);
        MessagingFee memory fee = _quote(destination.lzEid, message, destination.options, false);
        if (fee.lzTokenFee != 0) revert LayerZeroStateRelayTransport_LzTokenPaymentNotSupported();
        if (msg.value < fee.nativeFee) revert LayerZeroStateRelayTransport_InsufficientNativeFee();

        _lzSend(destination.lzEid, message, destination.options, fee, refundTo);
        emit MessageSent(destinationId, destination.lzEid, message, refundTo);
    }

    function _getDestinationOrRevert(uint256 destinationId) internal view returns (DestinationConfig storage destination) {
        destination = destinations[destinationId];
        if (!destination.enabled) revert LayerZeroStateRelayTransport_DestinationNotEnabled(destinationId);
    }

    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) internal virtual override {
        // Send-only transport adapter.
    }
}
