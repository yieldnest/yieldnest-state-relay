// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {StateSenderBase} from "./StateSenderBase.sol";

/**
 * @title StateSenderStatic
 * @notice Source-chain upgradeable OApp with calldata fixed at initialization (and optionally updated by owner).
 */
contract StateSenderStatic is StateSenderBase {
    bytes public callData;

    event CallDataSet(bytes callData);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) StateSenderBase(_endpoint) {}

    function initialize(
        address _owner,
        address _target,
        address _refundAddress,
        address _lzToken,
        bytes memory _callData,
        uint8 _version
    ) external reinitializer(1) {
        __StateSenderBase_init(_owner, _target, _refundAddress, _lzToken, _version);
        callData = _callData;
    }

    function setCallData(bytes memory _callData) external onlyOwner {
        callData = _callData;
        emit CallDataSet(_callData);
    }

    function quoteSendState(uint32 dstEid_, bool payInLzToken_) external view returns (MessagingFee memory fee) {
        return _quoteSendState(dstEid_, payInLzToken_, callData);
    }

    function sendState(uint32 dstEid_, bool payInLzToken_) external payable {
        _sendState(dstEid_, payInLzToken_, callData);
    }
}
