// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IRelayTransport
 * @notice Bridge-agnostic transport interface for quoting and sending relay payloads to application destinations.
 */
interface IRelayTransport {
    /**
     * @notice Transport fee quote for a relay send.
     * @param token Fee token address, or `address(0)` for native gas token.
     * @param feeAmount Amount required in `token`.
     * @param nativeFee Whether the quote must be paid in the native gas token.
     */
    struct TransportQuote {
        address token;
        uint256 feeAmount;
        bool nativeFee;
    }

    /**
     * @notice Quotes the transport fee for sending a message to a destination.
     * @param destinationId Application-level destination identifier.
     * @param message Encoded relay payload to quote.
     * @return quote Structured fee quote for the transport.
     */
    function quoteSend(uint256 destinationId, bytes calldata message)
        external
        view
        returns (TransportQuote memory quote);

    /**
     * @notice Sends a relay payload through the transport to a destination.
     * @param destinationId Application-level destination identifier.
     * @param message Encoded relay payload to send.
     * @param refundTo Address that should receive any transport refunds.
     */
    function send(uint256 destinationId, bytes calldata message, address refundTo) external payable;
}
