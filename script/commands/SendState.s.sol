/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {StateRelayBase} from "../StateRelayBase.s.sol";
import {StateSender} from "../../src/StateSender.sol";

/// @notice Sends a relay update through a deployed permissionless StateSender.
/// @dev Run on the source-chain RPC for the chosen sender label.
contract SendStateCommand is StateRelayBase {
    function run(string calldata inputPath, string calldata deploymentPath, string calldata label) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeploymentRequired();

        SenderInput memory senderInput = _senderInputForLabel(label);
        require(block.chainid == senderInput.chainId, "StateRelay: send command must run on the sender source chain");

        bytes32 slot = senderSlot(senderInput.chainId, label);
        address stateSenderAddress = stateSenderOf[slot];
        require(isContract(stateSenderAddress), "StateRelay: sender deployment missing for label");

        StateSender stateSender = StateSender(stateSenderAddress);
        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(receiverChainId);

        console.log("Sending state for label %s", label);
        console.log("StateSender: %s", vm.toString(stateSenderAddress));
        console.log("Destination chainId: %s", receiverChainId);
        console.log("Key: %s", vm.toString(quoteData.key));
        console.log("Required native fee: %s", quoteData.transportQuote.feeAmount);

        vm.broadcast();
        stateSender.sendState{value: quoteData.transportQuote.feeAmount}(receiverChainId);

        console.log("sendState() submitted");
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
