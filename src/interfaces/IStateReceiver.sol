// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IStateStore} from "./IStateStore.sol";

/**
 * @notice Destination OApp: decodes LZ payload and forwards to `IStateStore` when version is supported.
 */
interface IStateReceiver {
    event SupportedVersionSet(uint8 version, bool supported);
    event StateReceived(bytes32 key, bytes value, uint64 srcTimestamp);
    event UnsupportedVersionReceived(uint8 version);

    function stateStore() external view returns (IStateStore);
    function supportedVersions(uint8 version) external view returns (bool);

    function initialize(address _owner, address _stateStore) external;
    function setSupportedVersion(uint8 version, bool supported) external;
}
