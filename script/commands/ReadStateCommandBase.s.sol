/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {StateRelayBase} from "../StateRelayBase.s.sol";
import {StateStore} from "../../src/StateStore.sol";
import {KeyDerivation} from "../../src/KeyDerivation.sol";

/// @notice Shared destination-side helpers for reading stored relay state by sender label.
abstract contract ReadStateCommandBase is StateRelayBase {
    function _setUpReadContext(string calldata inputPath, string calldata deploymentPath)
        internal
        returns (address stateStoreAddress, StateStore stateStore)
    {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeploymentRequired();

        require(block.chainid == receiverChainId, "StateRelay: read command must run on the receiver chain");

        stateStoreAddress = stateStoreOf[receiverChainId];
        require(isContract(stateStoreAddress), "StateRelay: destination state store not deployed");
        stateStore = StateStore(stateStoreAddress);
    }

    function _senderInputForLabel(string memory label) internal view returns (SenderInput memory senderInput) {
        bytes32 expectedLabelHash = keccak256(bytes(label));
        for (uint256 i; i < senderLabels.length; i++) {
            if (keccak256(bytes(senderLabels[i])) == expectedLabelHash) {
                return senderByLabel[senderLabels[i]];
            }
        }
        revert("StateRelay: unknown sender label");
    }

    function _keyForLabel(string memory label) internal view returns (bytes32 key) {
        SenderInput memory senderInput = _senderInputForLabel(label);
        return KeyDerivation.deriveKey(senderInput.chainId, senderInput.target, senderInput.callData);
    }

    function _printEntry(uint256 reverseIndex, StateStore.Entry memory entry) internal pure {
        uint256 decodedValue = abi.decode(entry.value, (uint256));

        console.log("Entry reverseIndex: %s", reverseIndex);
        console.log("Value (uint256): %s", decodedValue);
        console.log("Version: %s", entry.version);
        console.log("Source timestamp: %s", entry.srcTimestamp);
        console.log("Updated at: %s", entry.updatedAt);
        console.log("Updated at block: %s", entry.updatedAtBlock);
    }
}
