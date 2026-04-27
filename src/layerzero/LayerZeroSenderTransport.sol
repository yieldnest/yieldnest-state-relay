// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {OAppUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {IRelayTransport} from "../interfaces/IRelayTransport.sol";

/**
 * @title LayerZeroSenderTransport
 * @notice LayerZero-specific send adapter that maps application destination IDs onto LayerZero route configuration.
 */
contract LayerZeroSenderTransport is OAppUpgradeable, AccessControlUpgradeable, IRelayTransport {
    string public constant VERSION = "0.1.0";

    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");
    bytes32 public constant SENDER_ROLE = keccak256("SENDER_ROLE");

    struct DestinationConfig {
        uint32 lzEid;
        bytes32 peer;
        bytes options;
        bool enabled;
    }

    /// @custom:storage-location erc7201:yieldnest.storage.lz_sender_transport
    struct LayerZeroSenderTransportStorage {
        mapping(uint256 destinationId => DestinationConfig destination) destinations;
    }

    event DestinationSet(uint256 indexed destinationId, uint32 lzEid, bytes32 peer, bytes options, bool enabled);
    event MessageSent(uint256 indexed destinationId, uint32 lzEid, bytes message, address refundTo);

    error LayerZeroSenderTransport_InvalidOwner();
    error LayerZeroSenderTransport_DestinationNotEnabled(uint256 destinationId);
    error LayerZeroSenderTransport_InsufficientNativeFee();
    error LayerZeroSenderTransport_LzTokenPaymentNotSupported();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the LayerZero sender transport.
     * @param _owner Owner and LayerZero delegate for this transport.
     */
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert LayerZeroSenderTransport_InvalidOwner();
        __AccessControl_init();
        __Ownable_init(_owner);
        __OApp_init(_owner);
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(CONFIG_MANAGER_ROLE, _owner);
    }

    /**
     * @notice Configures destination routes for LayerZero sends.
     * @param configs Destination route configurations to apply.
     */
    function setDestination(DestinationConfig[] calldata configs, uint256[] calldata destinationIds)
        external
        onlyRole(CONFIG_MANAGER_ROLE)
    {
        require(configs.length == destinationIds.length, "LayerZeroSenderTransport: array length mismatch");

        LayerZeroSenderTransportStorage storage $ = _getLayerZeroSenderTransportStorage();
        for (uint256 i = 0; i < configs.length; i++) {
            DestinationConfig calldata config = configs[i];
            uint256 destinationId = destinationIds[i];
            $.destinations[destinationId] = DestinationConfig({
                lzEid: config.lzEid,
                peer: config.peer,
                options: config.options,
                enabled: config.enabled
            });
            setPeer(config.lzEid, config.peer);
            emit DestinationSet(destinationId, config.lzEid, config.peer, config.options, config.enabled);
        }
    }

    /**
     * @inheritdoc IRelayTransport
     */
    function quoteSend(uint256 destinationId, bytes calldata message)
        external
        view
        returns (TransportQuote memory quote)
    {
        DestinationConfig storage destination = _getDestinationOrRevert(destinationId);
        MessagingFee memory fee = _quote(destination.lzEid, message, destination.options, false);
        if (fee.lzTokenFee != 0) {
            return TransportQuote({token: endpoint.lzToken(), feeAmount: fee.lzTokenFee, nativeFee: false});
        }
        return TransportQuote({token: address(0), feeAmount: fee.nativeFee, nativeFee: true});
    }

    /**
     * @inheritdoc IRelayTransport
     */
    function send(uint256 destinationId, bytes calldata message, address refundTo)
        external
        payable
        onlyRole(SENDER_ROLE)
    {
        DestinationConfig storage destination = _getDestinationOrRevert(destinationId);
        MessagingFee memory fee = _quote(destination.lzEid, message, destination.options, false);

        // since we're requesting pay in native, the lzTokenFee value should be 0
        if (fee.lzTokenFee != 0) revert LayerZeroSenderTransport_LzTokenPaymentNotSupported();

        if (msg.value < fee.nativeFee) revert LayerZeroSenderTransport_InsufficientNativeFee();

        _lzSend(destination.lzEid, message, destination.options, fee, refundTo);
        emit MessageSent(destinationId, destination.lzEid, message, refundTo);
    }

    /**
     * @notice Resolves and validates the destination configuration for a send.
     * @param destinationId Application-level destination identifier.
     * @return destination Enabled destination configuration for the requested route.
     */
    function _getDestinationOrRevert(uint256 destinationId)
        internal
        view
        returns (DestinationConfig storage destination)
    {
        destination = _getLayerZeroSenderTransportStorage().destinations[destinationId];
        if (!destination.enabled) revert LayerZeroSenderTransport_DestinationNotEnabled(destinationId);
    }

    /**
     * @notice Rejects inbound LayerZero deliveries because this transport is send-only.
     */
    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) internal virtual override {
        // Send-only transport adapter.
    }

    // --- Getters ---

    /**
     * @notice Returns the configured LayerZero route for a destination identifier.
     * @param destinationId Application-level destination identifier.
     * @return lzEid LayerZero endpoint ID for the destination.
     * @return peer Trusted peer address encoded as bytes32.
     * @return options LayerZero executor options used for sends to the destination.
     * @return enabled Whether the destination is currently enabled.
     */
    function destinations(uint256 destinationId)
        public
        view
        returns (uint32 lzEid, bytes32 peer, bytes memory options, bool enabled)
    {
        DestinationConfig storage destination = _getLayerZeroSenderTransportStorage().destinations[destinationId];
        return (destination.lzEid, destination.peer, destination.options, destination.enabled);
    }

    /**
     * @notice Returns the namespaced storage blob for LayerZeroSenderTransport.
     * @dev Storage slot derivation:
     *      1. `namespace = keccak256("yieldnest.storage.lz_sender_transport")`
     *      2. `slot = 0x573c202118fe57f459cce9fdf607f84c000b40f5a7fb4b74da5c7052f8c73606`
     *      This repo intentionally uses one raw namespace hash per contract storage blob.
     * @return $ LayerZeroSenderTransport storage blob.
     */
    function _getLayerZeroSenderTransportStorage() internal pure returns (LayerZeroSenderTransportStorage storage $) {
        assembly {
            $.slot := 0x573c202118fe57f459cce9fdf607f84c000b40f5a7fb4b74da5c7052f8c73606
        }
    }
}
