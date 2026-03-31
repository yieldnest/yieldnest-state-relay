// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Shared configurable surface for `StateSenderStatic` and `StateSenderDynamic` (refund, LZ token fee path, protocol version).
 */
interface IStateSenderBase {
    event StateSent(bytes32 key, uint32 dstEid, bool payInLzToken, bytes message);
    event RefundAddressSet(address refundAddress);
    event LzTokenSet(address lzToken);
    event VersionSet(uint8 version);

    function refundAddress() external view returns (address);
    function lzToken() external view returns (IERC20);
    function version() external view returns (uint8);

    function setRefundAddress(address _refundAddress) external;
    function setLzToken(address _lzToken) external;
    function setVersion(uint8 _version) external;
}
