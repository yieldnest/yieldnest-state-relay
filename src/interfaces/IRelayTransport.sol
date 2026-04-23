// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IRelayTransport {
    struct TransportQuote {
        address token;
        uint256 feeAmount;
        bool nativeFee;
    }

    function quoteSend(uint256 destinationId, bytes calldata message)
        external
        view
        returns (TransportQuote memory quote);

    function send(uint256 destinationId, bytes calldata message, address refundTo) external payable;
}
