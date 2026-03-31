// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {IStateSenderStatic} from "./interfaces/IStateSenderStatic.sol";
import {StateSenderBase} from "./StateSenderBase.sol";

/**
 * @title StateSenderStatic
 * @notice Source-chain upgradeable OApp with fixed read `target` and `callData` (set at init; owner may update).
 */
contract StateSenderStatic is StateSenderBase, IStateSenderStatic {
    /// @dev `callData` remains the first contract-local slot for layout compatibility with prior `StateSenderStatic` impls.
    bytes public callData;
    address public target;

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
        __StateSenderBase_init(_owner, _refundAddress, _lzToken, _version);
        target = _target;
        callData = _callData;
    }

    function setTarget(address _target) external onlyOwner {
        target = _target;
        emit TargetSet(_target);
    }

    function setCallData(bytes memory _callData) external onlyOwner {
        callData = _callData;
        emit CallDataSet(_callData);
    }

    function quoteSendState(uint32 dstEid_, bool payInLzToken_) external view returns (MessagingFee memory fee) {
        return _quoteSendState(dstEid_, payInLzToken_, target, callData);
    }

    function sendState(uint32 dstEid_, bool payInLzToken_) external payable {
        _sendState(dstEid_, payInLzToken_, target, callData);
    }
}
