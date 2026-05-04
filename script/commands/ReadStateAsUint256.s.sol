/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {StateRelayBase} from "../StateRelayBase.s.sol";
import {StateStore} from "../../src/StateStore.sol";
import {KeyDerivation} from "../../src/KeyDerivation.sol";

/// @notice Reads the latest stored relay value for a sender label and decodes it as uint256.
/// @dev Run on the destination-chain RPC for the current relay deployment.
contract ReadStateAsUint256Command is StateRelayBase {
    function run(string calldata inputPath, string calldata deploymentPath, string calldata label) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeploymentRequired();

        require(block.chainid == receiverChainId, "StateRelay: read command must run on the receiver chain");

        SenderInput memory senderInput = _senderInputForLabel(label);
        address stateStoreAddress = stateStoreOf[receiverChainId];
        require(isContract(stateStoreAddress), "StateRelay: destination state store not deployed");

        bytes32 key = KeyDerivation.deriveKey(senderInput.chainId, senderInput.target, senderInput.callData);
        StateStore.Entry memory entry = StateStore(stateStoreAddress).get(key);
        uint256 decodedValue = abi.decode(entry.value, (uint256));

        console.log("Reading latest state for label %s", label);
        console.log("StateStore: %s", vm.toString(stateStoreAddress));
        console.log("Key: %s", vm.toString(key));
        console.log("Value (uint256): %s", decodedValue);
        console.log("Version: %s", entry.version);
        console.log("Source timestamp: %s", entry.srcTimestamp);
        console.log("Updated at: %s", entry.updatedAt);
        console.log("Updated at block: %s", entry.updatedAtBlock);
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
}
