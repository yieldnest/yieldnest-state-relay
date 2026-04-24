/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {StateRelayBase} from "../StateRelayBase.s.sol";
import {StateStore} from "../../src/StateStore.sol";
import {StateSender} from "../../src/StateSender.sol";
import {LayerZeroSenderTransport} from "../../src/layerzero/LayerZeroSenderTransport.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice **Step 5** (optional) — transfer destination store roles, receiver ownership, sender roles, and sender transport ownership on **this** chain to `BaseData` `OFT_OWNER`.
///
/// Run once per chain; use `$RPC_MAINNET` or `$RPC_ARBITRUM` to match `block.chainid`.
/// forge script --sig "run(string,string)" --rpc-url "$RPC_MAINNET" --broadcast --with-gas-price 1gwei script/deploy/5_TransferStateRelayOwnership.s.sol:TransferStateRelayOwnership script/inputs/anvil-mainnet-arbitrum.json ""
contract TransferStateRelayOwnership is StateRelayBase {
    error NotOwner();

    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeploymentRequired();

        address nextOwner = getData(block.chainid).OFT_OWNER;
        uint256 cid = block.chainid;
        uint256 pk = vm.envUint("PRIVATE_KEY");
        require(vm.addr(pk) == relayOwner, "StateRelay: PRIVATE_KEY must match input .owner");

        address st = stateStoreOf[cid];
        if (st != address(0)) {
            _transferStateStoreRoles(StateStore(st), nextOwner, pk);
        }

        address rc = stateReceiverOf[cid];
        if (rc != address(0)) {
            Ownable o = Ownable(rc);
            if (o.owner() != nextOwner) {
                if (o.owner() != relayOwner) revert NotOwner();
                vm.broadcast(pk);
                o.transferOwnership(nextOwner);
                console.log("StateReceiver ownership -> OFT_OWNER");
            }
        }

        for (uint256 i; i < senderLabels.length; i++) {
            string memory label = senderLabels[i];
            if (senderByLabel[label].chainId != cid) continue;
            address snd = stateSenderOf[senderSlot(cid, label)];
            if (snd == address(0)) continue;

            _transferStateSenderRoles(StateSender(snd), label, nextOwner, pk);

            LayerZeroSenderTransport transport = LayerZeroSenderTransport(address(StateSender(snd).transport()));
            if (transport.owner() != nextOwner) {
                if (transport.owner() != relayOwner) revert NotOwner();
                vm.broadcast(pk);
                transport.transferOwnership(nextOwner);
                console.log("StateSender transport [%s] ownership -> OFT_OWNER", label);
            }
        }
    }

    function _transferStateStoreRoles(StateStore store, address nextOwner, uint256 pk) internal {
        bool relayAdmin = store.hasRole(store.DEFAULT_ADMIN_ROLE(), relayOwner);
        bool needsGrant = !store.hasRole(store.DEFAULT_ADMIN_ROLE(), nextOwner)
            || !store.hasRole(store.VERSION_MANAGER_ROLE(), nextOwner)
            || !store.hasRole(store.WRITER_MANAGER_ROLE(), nextOwner);
        bool needsRenounce = store.hasRole(store.DEFAULT_ADMIN_ROLE(), relayOwner)
            || store.hasRole(store.VERSION_MANAGER_ROLE(), relayOwner)
            || store.hasRole(store.WRITER_MANAGER_ROLE(), relayOwner);

        if (!needsGrant && !needsRenounce) return;
        if (needsGrant && !relayAdmin) revert NotOwner();

        vm.startBroadcast(pk);
        if (!store.hasRole(store.DEFAULT_ADMIN_ROLE(), nextOwner)) {
            store.grantRole(store.DEFAULT_ADMIN_ROLE(), nextOwner);
        }
        if (!store.hasRole(store.VERSION_MANAGER_ROLE(), nextOwner)) {
            store.grantRole(store.VERSION_MANAGER_ROLE(), nextOwner);
        }
        if (!store.hasRole(store.WRITER_MANAGER_ROLE(), nextOwner)) {
            store.grantRole(store.WRITER_MANAGER_ROLE(), nextOwner);
        }
        if (store.hasRole(store.WRITER_MANAGER_ROLE(), relayOwner)) {
            store.renounceRole(store.WRITER_MANAGER_ROLE(), relayOwner);
        }
        if (store.hasRole(store.VERSION_MANAGER_ROLE(), relayOwner)) {
            store.renounceRole(store.VERSION_MANAGER_ROLE(), relayOwner);
        }
        if (store.hasRole(store.DEFAULT_ADMIN_ROLE(), relayOwner)) {
            store.renounceRole(store.DEFAULT_ADMIN_ROLE(), relayOwner);
        }
        vm.stopBroadcast();

        console.log("StateStore roles -> OFT_OWNER");
    }

    function _transferStateSenderRoles(StateSender sender, string memory label, address nextOwner, uint256 pk) internal {
        bool relayAdmin = sender.hasRole(sender.DEFAULT_ADMIN_ROLE(), relayOwner);
        bool needsGrant = !sender.hasRole(sender.DEFAULT_ADMIN_ROLE(), nextOwner)
            || !sender.hasRole(sender.CONFIG_MANAGER_ROLE(), nextOwner)
            || !sender.hasRole(sender.TRANSPORT_MANAGER_ROLE(), nextOwner);
        bool needsRenounce = sender.hasRole(sender.DEFAULT_ADMIN_ROLE(), relayOwner)
            || sender.hasRole(sender.CONFIG_MANAGER_ROLE(), relayOwner)
            || sender.hasRole(sender.TRANSPORT_MANAGER_ROLE(), relayOwner);

        if (!needsGrant && !needsRenounce) return;
        if (needsGrant && !relayAdmin) revert NotOwner();

        vm.startBroadcast(pk);
        if (!sender.hasRole(sender.DEFAULT_ADMIN_ROLE(), nextOwner)) {
            sender.grantRole(sender.DEFAULT_ADMIN_ROLE(), nextOwner);
        }
        if (!sender.hasRole(sender.CONFIG_MANAGER_ROLE(), nextOwner)) {
            sender.grantRole(sender.CONFIG_MANAGER_ROLE(), nextOwner);
        }
        if (!sender.hasRole(sender.TRANSPORT_MANAGER_ROLE(), nextOwner)) {
            sender.grantRole(sender.TRANSPORT_MANAGER_ROLE(), nextOwner);
        }
        if (sender.hasRole(sender.CONFIG_MANAGER_ROLE(), relayOwner)) {
            sender.renounceRole(sender.CONFIG_MANAGER_ROLE(), relayOwner);
        }
        if (sender.hasRole(sender.TRANSPORT_MANAGER_ROLE(), relayOwner)) {
            sender.renounceRole(sender.TRANSPORT_MANAGER_ROLE(), relayOwner);
        }
        if (sender.hasRole(sender.DEFAULT_ADMIN_ROLE(), relayOwner)) {
            sender.renounceRole(sender.DEFAULT_ADMIN_ROLE(), relayOwner);
        }
        vm.stopBroadcast();

        console.log("StateSender [%s] roles -> OFT_OWNER", label);
    }
}
