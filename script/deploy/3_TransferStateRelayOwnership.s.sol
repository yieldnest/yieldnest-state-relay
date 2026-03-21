/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {StateRelayBase} from "../StateRelayBase.s.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Step 3: transfer Ownable on StateStore, StateReceiver, and StateSender(s) on this chain to `BaseData` `OFT_OWNER` (mirrors `3_TransferOFTOwnership`).
///
/// forge script script/deploy/3_TransferStateRelayOwnership.s.sol:TransferStateRelayOwnership \
///   --sig "run(string,string)" script/inputs/your-relay.json "" \
///   --rpc-url $RPC_URL --broadcast
contract TransferStateRelayOwnership is StateRelayBase {
    error NotOwner();

    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeploymentRequired();

        address nextOwner = getData(block.chainid).OFT_OWNER;
        uint256 cid = block.chainid;

        address st = stateStoreOf[cid];
        if (st != address(0)) {
            Ownable o = Ownable(st);
            if (o.owner() != nextOwner) {
                if (o.owner() != msg.sender) revert NotOwner();
                vm.broadcast();
                o.transferOwnership(nextOwner);
                console.log("StateStore ownership -> OFT_OWNER");
            }
        }

        address rc = stateReceiverOf[cid];
        if (rc != address(0)) {
            Ownable o = Ownable(rc);
            if (o.owner() != nextOwner) {
                if (o.owner() != msg.sender) revert NotOwner();
                vm.broadcast();
                o.transferOwnership(nextOwner);
                console.log("StateReceiver ownership -> OFT_OWNER");
            }
        }

        for (uint256 i; i < senderLabels.length; i++) {
            string memory label = senderLabels[i];
            if (senderByLabel[label].chainId != cid) continue;
            address snd = stateSenderOf[senderSlot(cid, label)];
            if (snd == address(0)) continue;
            Ownable o = Ownable(snd);
            if (o.owner() != nextOwner) {
                if (o.owner() != msg.sender) revert NotOwner();
                vm.broadcast();
                o.transferOwnership(nextOwner);
                console.log("StateSender [%s] ownership -> OFT_OWNER", label);
            }
        }
    }
}
