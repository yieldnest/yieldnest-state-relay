/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {BaseData} from "./BaseData.s.sol";

import {StateStore} from "../src/StateStore.sol";
import {StateSender} from "../src/StateSender.sol";
import {LayerZeroReceiverTransport} from "../src/layerzero/LayerZeroReceiverTransport.sol";
import {LayerZeroSenderTransport} from "../src/layerzero/LayerZeroSenderTransport.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Shared input, deployment JSON, and deploy steps for state relay scripts.
/// @dev Call `setUp()` once at the start of each script `run` (BaseData is not idempotent). Then `loadInput`, `loadDeployment`.
contract StateRelayBase is BaseData {
    struct SenderInput {
        uint256 chainId;
        address target;
        bytes callData;
        address refundAddress;
        uint256 protocolVersion;
    }

    string internal deploymentRelativePathOverride;
    string internal relayName;
    string internal relayVersion;
    address internal relayOwner;
    uint256 internal receiverChainId;

    uint256[] internal chainIdsWithInput;

    string[] internal senderLabels;
    mapping(string => SenderInput) internal senderByLabel;

    mapping(uint256 => address) internal stateStoreOf;
    mapping(uint256 => address) internal stateReceiverOf;
    mapping(bytes32 => address) internal stateSenderOf;

    function defaultSendOptions() internal pure returns (bytes memory) {
        return OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 300_000, 0);
    }

    function senderSlot(uint256 chainId, string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(chainId, bytes(label)));
    }

    function isContract(address a) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(a)
        }
        return size > 0;
    }

    /// @dev If `deploymentRelativePath` is empty, uses `deployments/<name>-<version>.json` from input.
    function deploymentFilePath() internal view returns (string memory) {
        if (bytes(deploymentRelativePathOverride).length > 0) {
            return string.concat(vm.projectRoot(), "/", deploymentRelativePathOverride);
        }
        return string.concat(vm.projectRoot(), "/deployments/", relayName, "-", relayVersion, ".json");
    }

    /// @dev `initialize` sets Ownable to `relayOwner`; txs must be signed by the same key or `onlyOwner` reverts (Forge default caller is not `.owner`).
    function _startBroadcast() internal {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        require(vm.addr(pk) == relayOwner, "StateRelay: PRIVATE_KEY must match input .owner");
        vm.startBroadcast(pk);
    }

    function _pushUniqueChainId(uint256 chainId) private {
        for (uint256 i; i < chainIdsWithInput.length; i++) {
            if (chainIdsWithInput[i] == chainId) return;
        }
        chainIdsWithInput.push(chainId);
    }

    /// @param deploymentRelativePath empty string = default file derived from input name/version; else path relative to project root (e.g. `deployments/custom.json`).
    function loadInput(string calldata inputRelativePath, string calldata deploymentRelativePath) internal {
        deploymentRelativePathOverride = deploymentRelativePath;

        string memory path = string.concat(vm.projectRoot(), "/", inputRelativePath);
        console.log("Loading input from %s", path);
        string memory json = vm.readFile(path);

        // Relay INPUT uses `.senders`; deployment artifacts use `.chains.<chainId>.*` (see `saveDeployment`). First arg must be input JSON.
        string[] memory sKeys;
        try vm.parseJsonKeys(json, ".senders") returns (string[] memory keys) {
            sKeys = keys;
        } catch {
            revert(
                "StateRelay: first path must be relay INPUT (script/inputs/*.json with .senders), not deployments/*.json"
            );
        }
        require(sKeys.length > 0, "StateRelay: input needs at least one entry under .senders");

        relayName = vm.parseJsonString(json, ".name");
        relayVersion = vm.parseJsonString(json, ".version");
        relayOwner = vm.parseJsonAddress(json, ".owner");
        receiverChainId = vm.parseJsonUint(json, ".receiverChainId");
        require(relayOwner != address(0), "StateRelay: owner required");
        require(bytes(relayName).length > 0, "StateRelay: name required");
        require(isSupportedChainId(receiverChainId), "StateRelay: receiverChainId not in BaseData");

        delete chainIdsWithInput;
        _pushUniqueChainId(receiverChainId);

        delete senderLabels;
        for (uint256 i; i < sKeys.length; i++) {
            string memory label = sKeys[i];
            string memory sp = string.concat(".senders.", label);
            uint256 sChain = vm.parseJsonUint(json, string.concat(sp, ".chainId"));
            address target = vm.parseJsonAddress(json, string.concat(sp, ".target"));
            bytes memory callData = vm.parseJsonBytes(json, string.concat(sp, ".callData"));
            address refund = vm.parseJsonAddress(json, string.concat(sp, ".refundAddress"));
            uint256 pVer = vm.parseJsonUint(json, string.concat(sp, ".protocolVersion"));
            require(target != address(0), "StateRelay: sender target");
            require(callData.length > 0, "StateRelay: sender callData");
            require(isSupportedChainId(sChain), "StateRelay: sender chainId not in BaseData");
            senderLabels.push(label);
            senderByLabel[label] = SenderInput({
                chainId: sChain,
                target: target,
                callData: callData,
                refundAddress: refund,
                protocolVersion: pVer
            });
            _pushUniqueChainId(sChain);
        }
    }

    function loadDeployment() internal {
        string memory filePath = deploymentFilePath();
        if (!vm.isFile(filePath)) {
            console.log("No deployment file at %s", filePath);
            return;
        }
        _readDeploymentFile(filePath);
    }

    /// @dev `receiverChainId` and sender `chainId` come from **input** only. Deployment JSON supplies addresses under
    ///      `.chains.<chainId>.stateStore`, `.stateReceiver`, `.senders.<label>.address`. Legacy top-level
    ///      `.senderContracts.<label>.address` is still read if the per-chain path is missing.
    function _readDeploymentFile(string memory filePath) private {
        console.log("Loading deployment from %s", filePath);
        string memory json = vm.readFile(filePath);

        for (uint256 i; i < chainIdsWithInput.length; i++) {
            uint256 depChainId = chainIdsWithInput[i];
            string memory cpre = string.concat(".chains.", vm.toString(depChainId));
            try vm.parseJsonAddress(json, string.concat(cpre, ".stateStore")) returns (address st) {
                if (st != address(0)) stateStoreOf[depChainId] = st;
            } catch {}
            try vm.parseJsonAddress(json, string.concat(cpre, ".stateReceiver")) returns (address rc) {
                if (rc != address(0)) stateReceiverOf[depChainId] = rc;
            } catch {}
        }

        for (uint256 i; i < senderLabels.length; i++) {
            string memory label = senderLabels[i];
            SenderInput memory s = senderByLabel[label];
            string memory byChain = string.concat(".chains.", vm.toString(s.chainId), ".senders.", label, ".address");
            try vm.parseJsonAddress(json, byChain) returns (address sAddr) {
                if (sAddr != address(0)) stateSenderOf[senderSlot(s.chainId, label)] = sAddr;
            } catch {
                string memory legacy = string.concat(".senderContracts.", label, ".address");
                try vm.parseJsonAddress(json, legacy) returns (address sAddr) {
                    if (sAddr != address(0)) stateSenderOf[senderSlot(s.chainId, label)] = sAddr;
                } catch {}
            }
        }
    }

    /// @notice Same as `loadDeployment` but reverts if the deployment JSON is missing (for configure / transfer steps).
    function loadDeploymentRequired() internal {
        string memory filePath = deploymentFilePath();
        require(vm.isFile(filePath), "StateRelay: deployment file missing");
        _readDeploymentFile(filePath);
    }

    /// @dev Step 1 — deploy **StateSender(s)** on each source chain RPC (relay / source side).
    function deploySenders() internal {
        uint256 currentChainId = block.chainid;
        require(isSupportedChainId(currentChainId), "StateRelay: rpc chain not in BaseData");

        bool hasSender;
        for (uint256 i; i < senderLabels.length; i++) {
            if (senderByLabel[senderLabels[i]].chainId == currentChainId) {
                hasSender = true;
                break;
            }
        }
        require(hasSender, "StateRelay: no StateSender for this chain in input; use source-chain RPC");

        address lzEndpoint = getData(currentChainId).LZ_ENDPOINT;
        for (uint256 i; i < senderLabels.length; i++) {
            string memory label = senderLabels[i];
            SenderInput memory s = senderByLabel[label];
            if (s.chainId == currentChainId) {
                _deploySender(label, s, lzEndpoint);
            }
        }
        saveDeployment();
    }

    /// @dev Step 2 — deploy **StateStore + StateReceiver** on `receiverChainId` RPC only.
    function deployDestination() internal {
        uint256 currentChainId = block.chainid;
        require(isSupportedChainId(currentChainId), "StateRelay: rpc chain not in BaseData");
        require(currentChainId == receiverChainId, "StateRelay: destination deploy only on receiver chain RPC");
        _deployDestination(getData(currentChainId).LZ_ENDPOINT);
        saveDeployment();
    }

    function _deployDestination(address lzEndpoint) internal {
        uint256 dstChainId = block.chainid;
        if (!isContract(stateStoreOf[dstChainId])) {
            _startBroadcast();
            StateStore impl = new StateStore();
            bytes memory initStore = abi.encodeCall(StateStore.initialize, (relayOwner, new address[](0)));
            ERC1967Proxy storeProxy = new ERC1967Proxy(address(impl), initStore);
            vm.stopBroadcast();
            stateStoreOf[dstChainId] = address(storeProxy);
            console.log("StateStore proxy:", stateStoreOf[dstChainId]);
        } else {
            console.log("StateStore already at:", stateStoreOf[dstChainId]);
        }

        if (!isContract(stateReceiverOf[dstChainId])) {
            _startBroadcast();
            LayerZeroReceiverTransport recvImpl = new LayerZeroReceiverTransport(lzEndpoint);
            bytes memory recvInit =
                abi.encodeCall(LayerZeroReceiverTransport.initialize, (relayOwner, stateStoreOf[dstChainId]));
            ERC1967Proxy recvProxy = new ERC1967Proxy(address(recvImpl), recvInit);
            vm.stopBroadcast();
            stateReceiverOf[dstChainId] = address(recvProxy);
            console.log("StateReceiver proxy:", stateReceiverOf[dstChainId]);
        } else {
            console.log("StateReceiver already at:", stateReceiverOf[dstChainId]);
        }

        StateStore store = StateStore(stateStoreOf[dstChainId]);
        if (!store.isWriter(stateReceiverOf[dstChainId])) {
            _startBroadcast();
            store.grantRole(store.WRITER_ROLE(), stateReceiverOf[dstChainId]);
            vm.stopBroadcast();
            console.log("Granted StateReceiver writer on StateStore");
        }
    }

    function _deploySender(string memory label, SenderInput memory s, address lzEndpoint) internal {
        bytes32 slot = senderSlot(block.chainid, label);
        address existing = stateSenderOf[slot];
        if (isContract(existing)) {
            console.log("StateSender [%s] already at:", label);
            console.logAddress(existing);
            return;
        }

        _startBroadcast();
        LayerZeroSenderTransport transportImpl = new LayerZeroSenderTransport(lzEndpoint);
        bytes memory transportInit = abi.encodeCall(LayerZeroSenderTransport.initialize, (relayOwner));
        ERC1967Proxy transportProxy = new ERC1967Proxy(address(transportImpl), transportInit);

        StateSender impl = new StateSender();
        bytes memory init = abi.encodeCall(
            StateSender.initialize, (relayOwner, address(transportProxy), s.target, s.callData, s.protocolVersion)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        LayerZeroSenderTransport(address(transportProxy)).setDestination(
            receiverChainId, getEID(receiverChainId), bytes32(0), defaultSendOptions(), true
        );
        vm.stopBroadcast();

        stateSenderOf[slot] = address(proxy);
        console.log("StateSender [%s] proxy:", label);
        console.logAddress(address(proxy));
        console.log("StateSender [%s] transport:", label);
        console.logAddress(address(transportProxy));
    }

    /// @dev Merges into the deployment file on disk: call `loadDeployment()` first so in-memory maps include prior
    ///      JSON, then this only overwrites paths for non-zero addresses we know about. Other keys stay untouched.
    function saveDeployment() internal {
        string memory path = deploymentFilePath();
        if (!vm.isFile(path)) {
            vm.writeJson("{\"chains\":{}}", path);
        }

        for (uint256 i; i < chainIdsWithInput.length; i++) {
            uint256 chainId = chainIdsWithInput[i];
            string memory chainIdStr = vm.toString(chainId);

            if (stateStoreOf[chainId] != address(0)) {
                vm.writeJson(
                    string.concat('"', vm.toString(stateStoreOf[chainId]), '"'),
                    path,
                    string.concat(".chains.", chainIdStr, ".stateStore")
                );
            }
            if (stateReceiverOf[chainId] != address(0)) {
                vm.writeJson(
                    string.concat('"', vm.toString(stateReceiverOf[chainId]), '"'),
                    path,
                    string.concat(".chains.", chainIdStr, ".stateReceiver")
                );
            }

            for (uint256 j; j < senderLabels.length; j++) {
                string memory label = senderLabels[j];
                SenderInput memory s = senderByLabel[label];
                if (s.chainId != chainId) continue;
                address deployed = stateSenderOf[senderSlot(chainId, label)];
                if (deployed == address(0)) continue;

                string memory objKey = string.concat("sndW_", chainIdStr, "_", label);
                string memory senderObj = vm.serializeAddress(objKey, "address", deployed);
                vm.writeJson(senderObj, path, string.concat(".chains.", chainIdStr, ".senders.", label));
            }
        }

        console.log("Wrote deployment to %s", path);
    }
}
