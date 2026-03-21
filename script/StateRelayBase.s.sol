/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {BaseData} from "./BaseData.s.sol";

import {StateStore} from "../src/StateStore.sol";
import {StateSender} from "../src/StateSender.sol";
import {StateReceiver} from "../src/StateReceiver.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Shared input, deployment JSON, and deploy steps for state relay scripts.
/// @dev Call `setUp()` once at the start of each script `run` (BaseData is not idempotent). Then `loadInput`, `loadDeployment`.
contract StateRelayBase is BaseData {
    struct SenderInput {
        uint256 chainId;
        address target;
        bytes callData;
        address refundAddress;
        address lzToken;
        uint8 protocolVersion;
    }

    string internal deploymentRelativePathOverride;
    string internal relayName;
    string internal relayVersion;
    address internal relayOwner;
    uint256 internal receiverChainId;
    uint256 internal maxValueSize;

    uint256[] internal chainIdsWithInput;

    string[] internal senderLabels;
    mapping(string => SenderInput) internal senderByLabel;

    mapping(uint256 => address) internal stateStoreOf;
    mapping(uint256 => address) internal stateReceiverOf;
    mapping(bytes32 => address) internal stateSenderOf;

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

        relayName = vm.parseJsonString(json, ".name");
        relayVersion = vm.parseJsonString(json, ".version");
        relayOwner = vm.parseJsonAddress(json, ".owner");
        receiverChainId = vm.parseJsonUint(json, ".receiverChainId");
        maxValueSize = vm.parseJsonUint(json, ".dst.maxValueSize");
        require(relayOwner != address(0), "StateRelay: owner required");
        require(bytes(relayName).length > 0, "StateRelay: name required");
        require(isSupportedChainId(receiverChainId), "StateRelay: receiverChainId not in BaseData");

        delete chainIdsWithInput;
        _pushUniqueChainId(receiverChainId);

        delete senderLabels;
        string[] memory sKeys = vm.parseJsonKeys(json, ".senders");
        for (uint256 i; i < sKeys.length; i++) {
            string memory label = sKeys[i];
            string memory sp = string.concat(".senders.", label);
            uint256 sChain = vm.parseJsonUint(json, string.concat(sp, ".chainId"));
            address target = vm.parseJsonAddress(json, string.concat(sp, ".target"));
            bytes memory callData = vm.parseJsonBytes(json, string.concat(sp, ".callData"));
            address refund = vm.parseJsonAddress(json, string.concat(sp, ".refundAddress"));
            address lzTok = vm.parseJsonAddress(json, string.concat(sp, ".lzToken"));
            uint8 pVer = uint8(vm.parseJsonUint(json, string.concat(sp, ".protocolVersion")));
            require(target != address(0), "StateRelay: sender target");
            require(callData.length > 0, "StateRelay: sender callData");
            require(isSupportedChainId(sChain), "StateRelay: sender chainId not in BaseData");
            senderLabels.push(label);
            senderByLabel[label] = SenderInput({
                chainId: sChain,
                target: target,
                callData: callData,
                refundAddress: refund,
                lzToken: lzTok,
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

    function _readDeploymentFile(string memory filePath) private {
        console.log("Loading deployment from %s", filePath);
        string memory json = vm.readFile(filePath);

        require(vm.parseJsonUint(json, ".receiverChainId") == receiverChainId, "StateRelay: receiverChainId mismatch");

        string[] memory chainKeys = vm.parseJsonKeys(json, ".chains");
        for (uint256 i; i < chainKeys.length; i++) {
            uint256 depChainId = vm.parseUint(chainKeys[i]);
            string memory cpre = string.concat(".chains.", chainKeys[i]);
            stateStoreOf[depChainId] = vm.parseJsonAddress(json, string.concat(cpre, ".stateStore"));
            stateReceiverOf[depChainId] = vm.parseJsonAddress(json, string.concat(cpre, ".stateReceiver"));
        }

        try vm.parseJsonKeys(json, ".senderContracts") returns (string[] memory sndKeys) {
            for (uint256 i; i < sndKeys.length; i++) {
                string memory label = sndKeys[i];
                string memory sp = string.concat(".senderContracts.", label);
                uint256 sChain = vm.parseJsonUint(json, string.concat(sp, ".chainId"));
                address sAddr = vm.parseJsonAddress(json, string.concat(sp, ".address"));
                stateSenderOf[senderSlot(sChain, label)] = sAddr;
            }
        } catch {}
    }

    /// @notice Same as `loadDeployment` but reverts if the deployment JSON is missing (for configure / transfer steps).
    function loadDeploymentRequired() internal {
        string memory filePath = deploymentFilePath();
        require(vm.isFile(filePath), "StateRelay: deployment file missing");
        _readDeploymentFile(filePath);
    }

    function runDeployForChain() internal {
        uint256 currentChainId = block.chainid;
        require(isSupportedChainId(currentChainId), "StateRelay: rpc chain not in BaseData");

        bool inScope;
        if (currentChainId == receiverChainId) inScope = true;
        for (uint256 i; i < senderLabels.length; i++) {
            if (senderByLabel[senderLabels[i]].chainId == currentChainId) {
                inScope = true;
                break;
            }
        }
        require(inScope, "StateRelay: this chain not used by this input");

        address lzEndpoint = getData(currentChainId).LZ_ENDPOINT;

        if (currentChainId == receiverChainId) {
            _deployDestination(lzEndpoint);
        }

        for (uint256 i; i < senderLabels.length; i++) {
            string memory label = senderLabels[i];
            SenderInput memory s = senderByLabel[label];
            if (s.chainId == currentChainId) {
                _deploySender(label, s, lzEndpoint);
            }
        }

        saveDeployment();
    }

    function _deployDestination(address lzEndpoint) internal {
        uint256 dstChainId = block.chainid;
        if (!isContract(stateStoreOf[dstChainId])) {
            vm.startBroadcast();
            StateStore impl = new StateStore();
            bytes memory initStore = abi.encodeCall(StateStore.initialize, (relayOwner, maxValueSize, new address[](0)));
            ERC1967Proxy storeProxy = new ERC1967Proxy(address(impl), initStore);
            vm.stopBroadcast();
            stateStoreOf[dstChainId] = address(storeProxy);
            console.log("StateStore proxy:", stateStoreOf[dstChainId]);
        } else {
            console.log("StateStore already at:", stateStoreOf[dstChainId]);
        }

        if (!isContract(stateReceiverOf[dstChainId])) {
            vm.startBroadcast();
            StateReceiver recvImpl = new StateReceiver(lzEndpoint);
            bytes memory recvInit = abi.encodeCall(StateReceiver.initialize, (relayOwner, stateStoreOf[dstChainId]));
            ERC1967Proxy recvProxy = new ERC1967Proxy(address(recvImpl), recvInit);
            vm.stopBroadcast();
            stateReceiverOf[dstChainId] = address(recvProxy);
            console.log("StateReceiver proxy:", stateReceiverOf[dstChainId]);
        } else {
            console.log("StateReceiver already at:", stateReceiverOf[dstChainId]);
        }

        StateStore store = StateStore(stateStoreOf[dstChainId]);
        if (!store.isWriter(stateReceiverOf[dstChainId])) {
            vm.startBroadcast();
            store.setWriter(stateReceiverOf[dstChainId], true);
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

        vm.startBroadcast();
        StateSender impl = new StateSender(lzEndpoint);
        bytes memory init = abi.encodeCall(
            StateSender.initialize,
            (relayOwner, s.target, s.refundAddress, s.lzToken, s.callData, s.protocolVersion)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        vm.stopBroadcast();

        stateSenderOf[slot] = address(proxy);
        console.log("StateSender [%s] proxy:", label);
        console.logAddress(address(proxy));
    }

    function saveDeployment() internal {
        string memory root = "stateRelayDeploy";
        root = vm.serializeUint(root, "receiverChainId", receiverChainId);

        string memory chainsAcc = "chainsAcc";
        for (uint256 i; i < chainIdsWithInput.length; i++) {
            uint256 chainId = chainIdsWithInput[i];
            string memory chainIdStr = vm.toString(chainId);
            string memory chainObj = string.concat("chain_", chainIdStr);
            chainObj = vm.serializeAddress(chainObj, "stateStore", stateStoreOf[chainId]);
            chainObj = vm.serializeAddress(chainObj, "stateReceiver", stateReceiverOf[chainId]);
            chainsAcc = vm.serializeString(chainsAcc, chainIdStr, chainObj);
        }
        root = vm.serializeString(root, "chains", chainsAcc);

        string memory sndAcc = "sndAcc";
        bool anySender;
        for (uint256 i; i < senderLabels.length; i++) {
            string memory label = senderLabels[i];
            SenderInput memory s = senderByLabel[label];
            address deployed = stateSenderOf[senderSlot(s.chainId, label)];
            if (deployed == address(0)) continue;

            string memory one = string.concat("snd1_", label);
            one = vm.serializeUint(one, "chainId", s.chainId);
            one = vm.serializeAddress(one, "address", deployed);
            sndAcc = vm.serializeString(sndAcc, label, one);
            anySender = true;
        }
        if (!anySender) {
            sndAcc = vm.serializeJson("sndAccEmpty", "{}");
        }
        root = vm.serializeString(root, "senderContracts", sndAcc);

        vm.writeJson(root, deploymentFilePath());
        console.log("Wrote deployment to %s", deploymentFilePath());
    }
}
