// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IRelayTransport {
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
