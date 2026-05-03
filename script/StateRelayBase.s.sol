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
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Shared input, deployment JSON, and deploy steps for state relay scripts.
/// @dev Call `setUp()` once at the start of each script `run` (BaseData is not idempotent). Then `loadInput`, `loadDeployment`.
contract StateRelayBase is BaseData {
    struct SenderInput {
        uint256 chainId;
        address target;
        bytes callData;
        uint256 protocolVersion;
    }

    string internal deploymentRelativePathOverride;
    string internal relayName;
    string internal relayVersion;
    address internal relayDeployer;
    uint256 internal receiverChainId;
    uint256 internal constant PROXY_ADMIN_TIMELOCK_DELAY = 1 days;
    // Default LayerZero executor gas forwarded to the destination chain `lzReceive` call.
    uint128 internal constant DEFAULT_LZ_RECEIVE_GAS_LIMIT = 500_000;

    uint256[] internal chainIdsWithInput;

    string[] internal senderLabels;
    mapping(string => SenderInput) internal senderByLabel;

    mapping(uint256 => address) internal stateStoreOf;
    mapping(uint256 => address) internal stateStoreProxyAdminOf;
    mapping(uint256 => address) internal stateStoreProxyAdminTimelockOf;
    mapping(uint256 => address) internal stateReceiverOf;
    mapping(uint256 => address) internal stateReceiverProxyAdminOf;
    mapping(uint256 => address) internal stateReceiverProxyAdminTimelockOf;
    mapping(bytes32 => address) internal stateSenderOf;
    mapping(bytes32 => address) internal stateSenderProxyAdminOf;
    mapping(bytes32 => address) internal stateSenderProxyAdminTimelockOf;
    mapping(bytes32 => address) internal stateSenderTransportOf;
    mapping(bytes32 => address) internal stateSenderTransportProxyAdminOf;
    mapping(bytes32 => address) internal stateSenderTransportProxyAdminTimelockOf;

    bytes32 internal constant ERC1967_ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function defaultSendOptions() internal pure returns (bytes memory) {
        return OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), DEFAULT_LZ_RECEIVE_GAS_LIMIT, 0);
    }

    function senderSlot(uint256 chainId, string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(chainId, bytes(label)));
    }

    function isContract(address candidateAddress) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(candidateAddress)
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

    /// @dev Uses Foundry's active broadcaster configuration (`--private-key`, `--account`, ledger, etc.).
    ///      The configured signer must equal the input `deployer`.
    function _startBroadcast() internal {
        vm.startBroadcast();
        (, address msgSender,) = vm.readCallers();
        require(msgSender == relayDeployer, "StateRelay: broadcaster must match input .deployer");
    }

    function _broadcastOnce() internal {
        vm.broadcast();
        (, address msgSender,) = vm.readCallers();
        require(msgSender == relayDeployer, "StateRelay: broadcaster must match input .deployer");
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
        relayDeployer = vm.parseJsonAddress(json, ".deployer");
        receiverChainId = vm.parseJsonUint(json, ".receiverChainId");
        require(relayDeployer != address(0), "StateRelay: deployer required");
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
            uint256 pVer = vm.parseJsonUint(json, string.concat(sp, ".protocolVersion"));
            require(target != address(0), "StateRelay: sender target");
            require(callData.length > 0, "StateRelay: sender callData");
            require(isSupportedChainId(sChain), "StateRelay: sender chainId not in BaseData");
            senderLabels.push(label);
            senderByLabel[label] = SenderInput({
                chainId: sChain, target: target, callData: callData, protocolVersion: pVer
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
            try vm.parseJsonAddress(json, string.concat(cpre, ".stateStore")) returns (address stateStore) {
                if (stateStore != address(0)) stateStoreOf[depChainId] = stateStore;
            } catch {}
            try vm.parseJsonAddress(json, string.concat(cpre, ".stateStoreProxyAdmin")) returns (address stateStoreProxyAdmin) {
                if (stateStoreProxyAdmin != address(0)) stateStoreProxyAdminOf[depChainId] = stateStoreProxyAdmin;
            } catch {}
            try vm.parseJsonAddress(json, string.concat(cpre, ".stateStoreProxyAdminTimelock")) returns (address stateStoreProxyAdminTimelock) {
                if (stateStoreProxyAdminTimelock != address(0)) {
                    stateStoreProxyAdminTimelockOf[depChainId] = stateStoreProxyAdminTimelock;
                }
            } catch {}
            try vm.parseJsonAddress(json, string.concat(cpre, ".stateReceiver")) returns (address stateReceiver) {
                if (stateReceiver != address(0)) stateReceiverOf[depChainId] = stateReceiver;
            } catch {}
            try vm.parseJsonAddress(json, string.concat(cpre, ".stateReceiverProxyAdmin")) returns (address stateReceiverProxyAdmin) {
                if (stateReceiverProxyAdmin != address(0)) stateReceiverProxyAdminOf[depChainId] = stateReceiverProxyAdmin;
            } catch {}
            try vm.parseJsonAddress(json, string.concat(cpre, ".stateReceiverProxyAdminTimelock")) returns (address stateReceiverProxyAdminTimelock) {
                if (stateReceiverProxyAdminTimelock != address(0)) {
                    stateReceiverProxyAdminTimelockOf[depChainId] = stateReceiverProxyAdminTimelock;
                }
            } catch {}
        }

        for (uint256 i; i < senderLabels.length; i++) {
            string memory label = senderLabels[i];
            SenderInput memory s = senderByLabel[label];
            string memory byChain = string.concat(".chains.", vm.toString(s.chainId), ".senders.", label, ".address");
            try vm.parseJsonAddress(json, byChain) returns (address stateSender) {
                if (stateSender != address(0)) {
                    bytes32 slot = senderSlot(s.chainId, label);
                    stateSenderOf[slot] = stateSender;
                    try vm.parseJsonAddress(json, string.concat(".chains.", vm.toString(s.chainId), ".senders.", label, ".proxyAdmin"))
                    returns (address stateSenderProxyAdmin) {
                        if (stateSenderProxyAdmin != address(0)) stateSenderProxyAdminOf[slot] = stateSenderProxyAdmin;
                    } catch {}
                    try vm.parseJsonAddress(
                        json, string.concat(".chains.", vm.toString(s.chainId), ".senders.", label, ".proxyAdminTimelock")
                    ) returns (address stateSenderProxyAdminTimelock) {
                        if (stateSenderProxyAdminTimelock != address(0)) {
                            stateSenderProxyAdminTimelockOf[slot] = stateSenderProxyAdminTimelock;
                        }
                    } catch {}
                    try vm.parseJsonAddress(
                        json, string.concat(".chains.", vm.toString(s.chainId), ".senders.", label, ".transport")
                    ) returns (address stateSenderTransport) {
                        if (stateSenderTransport != address(0)) stateSenderTransportOf[slot] = stateSenderTransport;
                    } catch {}
                    try vm.parseJsonAddress(
                        json,
                        string.concat(".chains.", vm.toString(s.chainId), ".senders.", label, ".transportProxyAdmin")
                    ) returns (address stateSenderTransportProxyAdmin) {
                        if (stateSenderTransportProxyAdmin != address(0)) {
                            stateSenderTransportProxyAdminOf[slot] = stateSenderTransportProxyAdmin;
                        }
                    } catch {}
                    try vm.parseJsonAddress(
                        json,
                        string.concat(
                            ".chains.", vm.toString(s.chainId), ".senders.", label, ".transportProxyAdminTimelock"
                        )
                    ) returns (address stateSenderTransportProxyAdminTimelock) {
                        if (stateSenderTransportProxyAdminTimelock != address(0)) {
                            stateSenderTransportProxyAdminTimelockOf[slot] = stateSenderTransportProxyAdminTimelock;
                        }
                    } catch {}
                }
            } catch {
                string memory legacy = string.concat(".senderContracts.", label, ".address");
                try vm.parseJsonAddress(json, legacy) returns (address stateSender) {
                    if (stateSender != address(0)) stateSenderOf[senderSlot(s.chainId, label)] = stateSender;
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
        address destinationOwner = getData(dstChainId).OFT_OWNER;
        if (!isContract(stateReceiverOf[dstChainId])) {
            _startBroadcast();
            address stateReceiverTimelock =
                _deployTimelockController(getData(dstChainId).OFT_OWNER, PROXY_ADMIN_TIMELOCK_DELAY);
            LayerZeroReceiverTransport recvImpl = new LayerZeroReceiverTransport(lzEndpoint);
            bytes memory recvInit = abi.encodeCall(LayerZeroReceiverTransport.initialize, (relayDeployer));
            TransparentUpgradeableProxy recvProxy =
                new TransparentUpgradeableProxy(address(recvImpl), stateReceiverTimelock, recvInit);
            vm.stopBroadcast();
            stateReceiverOf[dstChainId] = address(recvProxy);
            stateReceiverProxyAdminOf[dstChainId] = _proxyAdminOf(address(recvProxy));
            stateReceiverProxyAdminTimelockOf[dstChainId] = stateReceiverTimelock;
            console.log("StateReceiver proxy:", stateReceiverOf[dstChainId]);
            console.log("StateReceiver proxy admin:", stateReceiverProxyAdminOf[dstChainId]);
            console.log("StateReceiver proxy admin timelock:", stateReceiverProxyAdminTimelockOf[dstChainId]);
        } else {
            console.log("StateReceiver already at:", stateReceiverOf[dstChainId]);
            if (stateReceiverProxyAdminOf[dstChainId] == address(0)) {
                stateReceiverProxyAdminOf[dstChainId] = _proxyAdminOf(stateReceiverOf[dstChainId]);
            }
        }

        if (!isContract(stateStoreOf[dstChainId])) {
            _startBroadcast();
            address stateStoreTimelock = _deployTimelockController(destinationOwner, PROXY_ADMIN_TIMELOCK_DELAY);
            StateStore impl = new StateStore();
            address[] memory writers = new address[](1);
            writers[0] = stateReceiverOf[dstChainId];
            bytes memory initStore = abi.encodeCall(StateStore.initialize, (destinationOwner, writers));
            TransparentUpgradeableProxy storeProxy =
                new TransparentUpgradeableProxy(address(impl), stateStoreTimelock, initStore);
            vm.stopBroadcast();
            stateStoreOf[dstChainId] = address(storeProxy);
            stateStoreProxyAdminOf[dstChainId] = _proxyAdminOf(address(storeProxy));
            stateStoreProxyAdminTimelockOf[dstChainId] = stateStoreTimelock;
            console.log("StateStore proxy:", stateStoreOf[dstChainId]);
            console.log("StateStore proxy admin:", stateStoreProxyAdminOf[dstChainId]);
            console.log("StateStore proxy admin timelock:", stateStoreProxyAdminTimelockOf[dstChainId]);
        } else {
            console.log("StateStore already at:", stateStoreOf[dstChainId]);
            if (stateStoreProxyAdminOf[dstChainId] == address(0)) {
                stateStoreProxyAdminOf[dstChainId] = _proxyAdminOf(stateStoreOf[dstChainId]);
            }
        }

        LayerZeroReceiverTransport receiver = LayerZeroReceiverTransport(stateReceiverOf[dstChainId]);
        if (address(receiver.stateStore()) != stateStoreOf[dstChainId]) {
            _startBroadcast();
            receiver.setStateStore(stateStoreOf[dstChainId]);
            vm.stopBroadcast();
            console.log("Configured StateReceiver state store");
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

        _deployNewSender(slot, label, s, lzEndpoint);
    }

    function _deployNewSender(bytes32 slot, string memory label, SenderInput memory s, address lzEndpoint) internal {
        _startBroadcast();
        address destinationOwner = getData(block.chainid).OFT_OWNER;
        address transportTimelock = _deployTimelockController(destinationOwner, PROXY_ADMIN_TIMELOCK_DELAY);
        address senderTimelock = _deployTimelockController(destinationOwner, PROXY_ADMIN_TIMELOCK_DELAY);
        LayerZeroSenderTransport transportImpl = new LayerZeroSenderTransport(lzEndpoint);
        bytes memory transportInit = abi.encodeCall(LayerZeroSenderTransport.initialize, (relayDeployer));
        TransparentUpgradeableProxy transportProxy =
            new TransparentUpgradeableProxy(address(transportImpl), transportTimelock, transportInit);

        StateSender impl = new StateSender();
        bytes memory init = abi.encodeCall(
            StateSender.initialize, (destinationOwner, address(transportProxy), s.target, s.callData, s.protocolVersion)
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), senderTimelock, init);
        _seedSenderTransport(LayerZeroSenderTransport(address(transportProxy)), address(proxy));
        vm.stopBroadcast();

        _recordSenderDeployment(slot, label, address(proxy), address(transportProxy), senderTimelock, transportTimelock);
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
            if (stateStoreProxyAdminOf[chainId] != address(0)) {
                vm.writeJson(
                    string.concat('"', vm.toString(stateStoreProxyAdminOf[chainId]), '"'),
                    path,
                    string.concat(".chains.", chainIdStr, ".stateStoreProxyAdmin")
                );
            }
            if (stateStoreProxyAdminTimelockOf[chainId] != address(0)) {
                vm.writeJson(
                    string.concat('"', vm.toString(stateStoreProxyAdminTimelockOf[chainId]), '"'),
                    path,
                    string.concat(".chains.", chainIdStr, ".stateStoreProxyAdminTimelock")
                );
            }
            if (stateReceiverOf[chainId] != address(0)) {
                vm.writeJson(
                    string.concat('"', vm.toString(stateReceiverOf[chainId]), '"'),
                    path,
                    string.concat(".chains.", chainIdStr, ".stateReceiver")
                );
            }
            if (stateReceiverProxyAdminOf[chainId] != address(0)) {
                vm.writeJson(
                    string.concat('"', vm.toString(stateReceiverProxyAdminOf[chainId]), '"'),
                    path,
                    string.concat(".chains.", chainIdStr, ".stateReceiverProxyAdmin")
                );
            }
            if (stateReceiverProxyAdminTimelockOf[chainId] != address(0)) {
                vm.writeJson(
                    string.concat('"', vm.toString(stateReceiverProxyAdminTimelockOf[chainId]), '"'),
                    path,
                    string.concat(".chains.", chainIdStr, ".stateReceiverProxyAdminTimelock")
                );
            }

            for (uint256 j; j < senderLabels.length; j++) {
                string memory label = senderLabels[j];
                SenderInput memory s = senderByLabel[label];
                if (s.chainId != chainId) continue;
                address deployed = stateSenderOf[senderSlot(chainId, label)];
                if (deployed == address(0)) continue;
                bytes32 slot = senderSlot(chainId, label);

                string memory objKey = string.concat("sndW_", chainIdStr, "_", label);
                string memory senderObj = vm.serializeAddress(objKey, "address", deployed);
                if (stateSenderProxyAdminOf[slot] != address(0)) {
                    senderObj = vm.serializeAddress(objKey, "proxyAdmin", stateSenderProxyAdminOf[slot]);
                }
                if (stateSenderProxyAdminTimelockOf[slot] != address(0)) {
                    senderObj = vm.serializeAddress(objKey, "proxyAdminTimelock", stateSenderProxyAdminTimelockOf[slot]);
                }
                if (stateSenderTransportOf[slot] != address(0)) {
                    senderObj = vm.serializeAddress(objKey, "transport", stateSenderTransportOf[slot]);
                }
                if (stateSenderTransportProxyAdminOf[slot] != address(0)) {
                    senderObj =
                        vm.serializeAddress(objKey, "transportProxyAdmin", stateSenderTransportProxyAdminOf[slot]);
                }
                if (stateSenderTransportProxyAdminTimelockOf[slot] != address(0)) {
                    senderObj = vm.serializeAddress(
                        objKey, "transportProxyAdminTimelock", stateSenderTransportProxyAdminTimelockOf[slot]
                    );
                }
                vm.writeJson(senderObj, path, string.concat(".chains.", chainIdStr, ".senders.", label));
            }
        }

        console.log("Wrote deployment to %s", path);
    }

    function _proxyAdminOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_ADMIN_SLOT))));
    }

    function _seedSenderTransport(LayerZeroSenderTransport senderTransport, address stateSender) internal {
        senderTransport.grantRole(senderTransport.SENDER_ROLE(), stateSender);

        LayerZeroSenderTransport.DestinationConfig[] memory destinationConfigs =
            new LayerZeroSenderTransport.DestinationConfig[](1);
        destinationConfigs[0] = LayerZeroSenderTransport.DestinationConfig({
            lzEid: getEID(receiverChainId), peer: bytes32(0), options: defaultSendOptions(), enabled: true
        });
        uint256[] memory destinationIds = new uint256[](1);
        destinationIds[0] = receiverChainId;
        senderTransport.setDestination(destinationConfigs, destinationIds);
    }

    function _deployTimelockController(address owner, uint256 minDelay) internal returns (address timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = owner;

        address[] memory executors = new address[](1);
        executors[0] = owner;

        timelock = address(new TimelockController(minDelay, proposers, executors, owner));
    }

    function _recordSenderDeployment(
        bytes32 slot,
        string memory label,
        address senderProxy,
        address transportProxy,
        address senderTimelock,
        address transportTimelock
    ) internal {
        stateSenderOf[slot] = senderProxy;
        stateSenderProxyAdminOf[slot] = _proxyAdminOf(senderProxy);
        stateSenderProxyAdminTimelockOf[slot] = senderTimelock;
        stateSenderTransportOf[slot] = transportProxy;
        stateSenderTransportProxyAdminOf[slot] = _proxyAdminOf(transportProxy);
        stateSenderTransportProxyAdminTimelockOf[slot] = transportTimelock;

        console.log("StateSender [%s] proxy:", label);
        console.logAddress(senderProxy);
        console.log("StateSender [%s] proxy admin:", label);
        console.logAddress(stateSenderProxyAdminOf[slot]);
        console.log("StateSender [%s] proxy admin timelock:", label);
        console.logAddress(stateSenderProxyAdminTimelockOf[slot]);
        console.log("StateSender [%s] transport:", label);
        console.logAddress(transportProxy);
        console.log("StateSender [%s] transport proxy admin:", label);
        console.logAddress(stateSenderTransportProxyAdminOf[slot]);
        console.log("StateSender [%s] transport proxy admin timelock:", label);
        console.logAddress(stateSenderTransportProxyAdminTimelockOf[slot]);
    }
}
