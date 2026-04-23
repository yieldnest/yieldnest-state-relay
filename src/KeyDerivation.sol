// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title KeyDerivation
 * @notice Deterministic key derivation for state relay: (chainId, target, callData) -> bytes32
 */
library KeyDerivation {
    bytes32 public constant KEY_DOMAIN = keccak256("LZ_STATE_RELAY_V1");

    /**
     * @notice Derives the deterministic relay key for a source-chain read target.
     * @param chainId Source chain ID used as part of the key domain.
     * @param target Source contract being queried.
     * @param callData Calldata used for the source-chain state read.
     * @return Deterministic relay key for the `(chainId, target, callData)` tuple.
     */
    function deriveKey(uint256 chainId, address target, bytes memory callData) internal pure returns (bytes32) {
        return keccak256(abi.encode(KEY_DOMAIN, chainId, target, callData));
    }
}
