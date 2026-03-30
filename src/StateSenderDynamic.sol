// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {StateSenderBase} from "./StateSenderBase.sol";

/**
 * @title StateSenderDynamic
 * @notice Same as {StateSenderStatic} but calldata is passed per `quoteSendState` / `sendState` call (no stored callData).
 */
contract StateSenderDynamic is StateSenderBase {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) StateSenderBase(_endpoint) {}

    function initialize(
        address _owner,
        address _target,
        address _refundAddress,
        address _lzToken,
        uint8 _version
    ) external reinitializer(1) {
        __StateSenderBase_init(_owner, _target, _refundAddress, _lzToken, _version);
    }

    function quoteSendState(uint32 dstEid_, bool payInLzToken_, bytes calldata callData_)
        external
        view
        returns (MessagingFee memory fee)
    {
        return _quoteSendState(dstEid_, payInLzToken_, callData_);
    }

    function sendState(uint32 dstEid_, bool payInLzToken_, bytes calldata callData_) external payable {
        _sendState(dstEid_, payInLzToken_, callData_);
    }
}
