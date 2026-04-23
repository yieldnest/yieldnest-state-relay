// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IRelayTransport {
    function quoteSend(uint256 destinationId, bytes calldata message) external view returns (uint256 nativeFee);

    function send(uint256 destinationId, bytes calldata message, address refundTo) external payable;
}
