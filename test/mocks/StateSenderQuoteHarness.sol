// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LayerZeroStateRelayTransport} from "src/layerzero/LayerZeroStateRelayTransport.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract StateSenderQuoteHarness is LayerZeroStateRelayTransport {
    MessagingFee internal _mockFee;

    constructor(address _endpoint) LayerZeroStateRelayTransport(_endpoint) {}

    function setMockFee(uint256 nativeFee, uint256 lzTokenFee) external {
        _mockFee = MessagingFee({nativeFee: nativeFee, lzTokenFee: lzTokenFee});
    }

    function _quote(uint32, bytes memory, bytes memory, bool)
        internal
        view
        virtual
        override
        returns (MessagingFee memory)
    {
        return _mockFee;
    }
}
