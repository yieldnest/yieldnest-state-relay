// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {IStateSenderBase} from "./IStateSenderBase.sol";

/**
 * @notice `target` + `callData` supplied per `quoteSendState` / `sendState`.
 */
interface IStateSenderDynamic is IStateSenderBase {
    function initialize(address _owner, address _refundAddress, address _lzToken, uint8 _version) external;

    function quoteSendState(uint32 dstEid_, bool payInLzToken_, address target_, bytes calldata callData_)
        external
        view
        returns (MessagingFee memory fee);

    function sendState(uint32 dstEid_, bool payInLzToken_, address target_, bytes calldata callData_) external payable;
}
