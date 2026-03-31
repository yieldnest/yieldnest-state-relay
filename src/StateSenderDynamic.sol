// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {IStateSenderDynamic} from "./interfaces/IStateSenderDynamic.sol";
import {StateSenderBase} from "./StateSenderBase.sol";

/**
 * @title StateSenderDynamic
 * @notice Per-call `target` + `callData` for staticcall/read/state key (no stored read target or calldata).
 * @dev Each send/quote must pass a non-zero `target_`. Read-only staticcalls only.
 */
contract StateSenderDynamic is StateSenderBase, IStateSenderDynamic {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) StateSenderBase(_endpoint) {}

    function initialize(address _owner, address _refundAddress, address _lzToken, uint8 _version)
        external
        reinitializer(1)
    {
        __StateSenderBase_init(_owner, _refundAddress, _lzToken, _version);
    }

    function quoteSendState(uint32 dstEid_, bool payInLzToken_, address target_, bytes calldata callData_)
        external
        view
        returns (MessagingFee memory fee)
    {
        return _quoteSendState(dstEid_, payInLzToken_, target_, callData_);
    }

    function sendState(uint32 dstEid_, bool payInLzToken_, address target_, bytes calldata callData_) external payable {
        _sendState(dstEid_, payInLzToken_, target_, callData_);
    }
}
