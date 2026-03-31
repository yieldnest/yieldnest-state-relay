// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {IStateSenderBase} from "./IStateSenderBase.sol";

/**
 * @notice Fixed read `target` + stored `callData`; quote/send use storage.
 */
interface IStateSenderStatic is IStateSenderBase {
    event TargetSet(address target);
    event CallDataSet(bytes callData);

    function callData() external view returns (bytes memory);
    function target() external view returns (address);

    function initialize(
        address _owner,
        address _target,
        address _refundAddress,
        address _lzToken,
        bytes memory _callData,
        uint8 _version
    ) external;

    function setTarget(address _target) external;
    function setCallData(bytes memory _callData) external;

    function quoteSendState(uint32 dstEid_, bool payInLzToken_) external view returns (MessagingFee memory fee);
    function sendState(uint32 dstEid_, bool payInLzToken_) external payable;
}
