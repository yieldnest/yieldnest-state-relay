// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @dev Minimal stub so `OApp` init (`endpoint.setDelegate`) succeeds on vanilla Anvil. Not a real LayerZero endpoint.
contract MockLayerZeroEndpointV2 {
    function setDelegate(address) external {}
}
