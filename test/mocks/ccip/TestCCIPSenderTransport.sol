// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRelayTransport} from "src/interfaces/IRelayTransport.sol";

contract TestCCIPSenderTransport is IRelayTransport, Ownable {
    struct DestinationConfig {
        uint64 chainSelector;
        address receiver;
        bytes extraArgs;
        bool enabled;
    }

    IRouterClient public immutable router;

    mapping(uint256 destinationId => DestinationConfig destination) internal s_destinations;

    event DestinationSet(uint256 indexed destinationId, uint64 chainSelector, address receiver, bytes extraArgs, bool enabled);
    event MessageSent(uint256 indexed destinationId, uint64 chainSelector, bytes message, address refundTo);

    error TestCCIPSenderTransport_InvalidRouter();
    error TestCCIPSenderTransport_DestinationNotEnabled(uint256 destinationId);
    error TestCCIPSenderTransport_InsufficientNativeFee();

    constructor(address router_, address owner_) Ownable(owner_) {
        if (router_ == address(0)) revert TestCCIPSenderTransport_InvalidRouter();
        router = IRouterClient(router_);
    }

    function setDestination(uint256 destinationId, DestinationConfig calldata config) external onlyOwner {
        s_destinations[destinationId] = config;
        emit DestinationSet(destinationId, config.chainSelector, config.receiver, config.extraArgs, config.enabled);
    }

    function quoteSend(uint256 destinationId, bytes calldata message)
        external
        view
        override
        returns (TransportQuote memory quote)
    {
        DestinationConfig storage destination = _getDestinationOrRevert(destinationId);
        Client.EVM2AnyMessage memory ccipMessage = _buildMessage(destination, message);
        uint256 fee = router.getFee(destination.chainSelector, ccipMessage);

        return TransportQuote({token: address(0), feeAmount: fee, nativeFee: true});
    }

    function send(uint256 destinationId, bytes calldata message, address refundTo) external payable override {
        DestinationConfig storage destination = _getDestinationOrRevert(destinationId);
        Client.EVM2AnyMessage memory ccipMessage = _buildMessage(destination, message);
        uint256 fee = router.getFee(destination.chainSelector, ccipMessage);
        if (msg.value < fee) revert TestCCIPSenderTransport_InsufficientNativeFee();

        router.ccipSend{value: msg.value}(destination.chainSelector, ccipMessage);
        emit MessageSent(destinationId, destination.chainSelector, message, refundTo);
    }

    function _buildMessage(DestinationConfig storage destination, bytes calldata message)
        internal
        view
        returns (Client.EVM2AnyMessage memory ccipMessage)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);

        return Client.EVM2AnyMessage({
            receiver: abi.encode(destination.receiver),
            data: message,
            tokenAmounts: tokenAmounts,
            feeToken: address(0),
            extraArgs: destination.extraArgs
        });
    }

    function _getDestinationOrRevert(uint256 destinationId)
        internal
        view
        returns (DestinationConfig storage destination)
    {
        destination = s_destinations[destinationId];
        if (!destination.enabled) revert TestCCIPSenderTransport_DestinationNotEnabled(destinationId);
    }
}
