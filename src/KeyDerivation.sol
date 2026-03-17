// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title KeyDerivation
 * @notice Deterministic key derivation for state relay: (chainId, target, callData) -> bytes32
 */
library KeyDerivation {
    bytes32 public constant KEY_DOMAIN = keccak256("LZ_STATE_RELAY_V1");

    function deriveKey(uint256 chainId, address target, bytes calldata callData) internal pure returns (bytes32) {
        return keccak256(abi.encode(KEY_DOMAIN, chainId, target, callData));
    }
}
