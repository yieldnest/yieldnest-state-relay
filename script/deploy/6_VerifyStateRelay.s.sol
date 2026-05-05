/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {StateRelayLzConfigure} from "../StateRelayLzConfigure.s.sol";
import {StateSender} from "../../src/StateSender.sol";
import {StateStore} from "../../src/StateStore.sol";
import {LayerZeroSenderTransport} from "../../src/layerzero/LayerZeroSenderTransport.sol";
import {LayerZeroReceiverTransport} from "../../src/layerzero/LayerZeroReceiverTransport.sol";

import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ExecutorConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

interface ILZEndpointDelegates {
    function delegates(address) external view returns (address);
}

/// @notice Verifies the current per-chain relay deployment and prints the remaining rollout steps.
/// @dev Run once per chain RPC after any deploy/config step.
contract VerifyStateRelay is StateRelayLzConfigure {
    error VerifyStateRelay_CriticalMisconfiguration(string message);

    string[] internal remainingActions;
    string[] internal warnings;

    bool internal needsStep1;
    bool internal needsStep2;
    bool internal needsStep3;
    bool internal needsStep4;
    bool internal needsStep5;

    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeployment();

        delete remainingActions;
        delete warnings;
        needsStep1 = false;
        needsStep2 = false;
        needsStep3 = false;
        needsStep4 = false;
        needsStep5 = false;

        uint256 cid = block.chainid;
        require(isSupportedChainId(cid), "StateRelay: rpc chain not in BaseData");

        console.log("Verifying state relay on chainId %s", cid);
        console.log("Deployment file: %s", deploymentFilePath());

        _verifySendersOnCurrentChain(cid);
        if (cid == receiverChainId) {
            _verifyReceiverChain(cid);
        }

        _printSummary();
    }

    function _verifySendersOnCurrentChain(uint256 cid) internal {
        for (uint256 i; i < senderLabels.length; i++) {
            string memory label = senderLabels[i];
            SenderInput memory senderInput = senderByLabel[label];
            if (senderInput.chainId != cid) continue;
            _verifySender(label, senderInput);
        }
    }

    function _verifySender(string memory label, SenderInput memory senderInput) internal {
        bytes32 slot = senderSlot(senderInput.chainId, label);
        address stateSenderAddress = stateSenderOf[slot];
        address expectedOwner = getData(senderInput.chainId).OFT_OWNER;

        if (!isContract(stateSenderAddress)) {
            _requireStep(1, string.concat("Sender missing for label ", label));
            return;
        }

        console.log("Sender [%s] deployed at %s", label, vm.toString(stateSenderAddress));
        _verifyTransparentProxy(
            string.concat("StateSender [", label, "]"),
            stateSenderAddress,
            stateSenderProxyAdminOf[slot],
            stateSenderProxyAdminTimelockOf[slot]
        );

        StateSender stateSender = StateSender(stateSenderAddress);
        _requireCriticalRole(
            stateSender.hasRole(stateSender.DEFAULT_ADMIN_ROLE(), expectedOwner),
            string.concat("StateSender [", label, "] missing DEFAULT_ADMIN_ROLE for OFT_OWNER")
        );
        _requireCriticalRole(
            stateSender.hasRole(stateSender.CONFIG_MANAGER_ROLE(), expectedOwner),
            string.concat("StateSender [", label, "] missing CONFIG_MANAGER_ROLE for OFT_OWNER")
        );
        _requireCriticalRole(
            stateSender.hasRole(stateSender.TRANSPORT_MANAGER_ROLE(), expectedOwner),
            string.concat("StateSender [", label, "] missing TRANSPORT_MANAGER_ROLE for OFT_OWNER")
        );
        _requireCriticalRole(
            stateSender.hasRole(stateSender.PAUSER_ROLE(), expectedOwner),
            string.concat("StateSender [", label, "] missing PAUSER_ROLE for OFT_OWNER")
        );

        address stateSenderTransportAddress = address(stateSender.transport());
        if (!isContract(stateSenderTransportAddress)) {
            _requireStep(1, string.concat("Sender transport missing for label ", label));
            return;
        }

        if (stateSenderTransportOf[slot] != address(0) && stateSenderTransportOf[slot] != stateSenderTransportAddress) {
            _warn(
                string.concat(
                    "Deployment JSON transport mismatch for sender ",
                    label,
                    ": stored=",
                    vm.toString(stateSenderTransportOf[slot]),
                    ", onchain=",
                    vm.toString(stateSenderTransportAddress)
                )
            );
        }

        LayerZeroSenderTransport senderTransport = LayerZeroSenderTransport(stateSenderTransportAddress);
        _verifyTransparentProxy(
            string.concat("StateSender transport [", label, "]"),
            stateSenderTransportAddress,
            stateSenderTransportProxyAdminOf[slot],
            stateSenderTransportProxyAdminTimelockOf[slot]
        );

        if (!senderTransport.hasRole(senderTransport.SENDER_ROLE(), stateSenderAddress)) {
            _requireStep(3, string.concat("Sender transport missing SENDER_ROLE for sender ", label));
        }

        _verifySenderTransportControl(label, senderTransport, expectedOwner);
        _verifySenderRouteAndLzConfig(label, senderTransport);
    }

    function _verifyReceiverChain(uint256 cid) internal {
        address stateReceiverAddress = stateReceiverOf[cid];
        address stateStoreAddress = stateStoreOf[cid];
        address expectedOwner = getData(cid).OFT_OWNER;

        if (!isContract(stateReceiverAddress) || !isContract(stateStoreAddress)) {
            _requireStep(2, "Destination contracts missing");
            return;
        }

        console.log("StateReceiver deployed at %s", vm.toString(stateReceiverAddress));
        console.log("StateStore deployed at %s", vm.toString(stateStoreAddress));

        _verifyTransparentProxy(
            "StateReceiver",
            stateReceiverAddress,
            stateReceiverProxyAdminOf[cid],
            stateReceiverProxyAdminTimelockOf[cid]
        );
        _verifyTransparentProxy(
            "StateStore", stateStoreAddress, stateStoreProxyAdminOf[cid], stateStoreProxyAdminTimelockOf[cid]
        );

        StateStore stateStore = StateStore(stateStoreAddress);
        LayerZeroReceiverTransport stateReceiver = LayerZeroReceiverTransport(stateReceiverAddress);

        _requireCriticalRole(
            stateStore.hasRole(stateStore.DEFAULT_ADMIN_ROLE(), expectedOwner),
            "StateStore missing DEFAULT_ADMIN_ROLE for OFT_OWNER"
        );
        _requireCriticalRole(
            stateStore.hasRole(stateStore.VERSION_MANAGER_ROLE(), expectedOwner),
            "StateStore missing VERSION_MANAGER_ROLE for OFT_OWNER"
        );
        _requireCriticalRole(
            stateStore.hasRole(stateStore.WRITER_MANAGER_ROLE(), expectedOwner),
            "StateStore missing WRITER_MANAGER_ROLE for OFT_OWNER"
        );
        _requireCriticalRole(
            stateStore.hasRole(stateStore.PAUSER_ROLE(), expectedOwner), "StateStore missing PAUSER_ROLE for OFT_OWNER"
        );

        if (!stateStore.isWriter(stateReceiverAddress)) {
            _requireStep(2, "StateReceiver is not a StateStore writer");
        }
        if (address(stateReceiver.stateStore()) != stateStoreAddress) {
            _requireStep(2, "StateReceiver stateStore pointer is not configured");
        }

        _verifyReceiverControl(stateReceiver, expectedOwner);
        _verifyReceiverLzConfig(stateReceiverAddress);
    }

    function _verifySenderTransportControl(
        string memory label,
        LayerZeroSenderTransport senderTransport,
        address expectedOwner
    ) internal {
        if (senderTransport.owner() != expectedOwner) {
            _requireStep(5, string.concat("Sender transport ownership not transferred for ", label));
        }
        if (!senderTransport.hasRole(senderTransport.DEFAULT_ADMIN_ROLE(), expectedOwner)) {
            _requireStep(5, string.concat("Sender transport missing DEFAULT_ADMIN_ROLE for OFT_OWNER on ", label));
        }
        if (!senderTransport.hasRole(senderTransport.CONFIG_MANAGER_ROLE(), expectedOwner)) {
            _requireStep(5, string.concat("Sender transport missing CONFIG_MANAGER_ROLE for OFT_OWNER on ", label));
        }
        if (relayDeployer != expectedOwner && senderTransport.owner() == relayDeployer) {
            _requireStep(5, string.concat("Sender transport ownership still held by deployer for ", label));
        }
        if (
            relayDeployer != expectedOwner
                && senderTransport.hasRole(senderTransport.DEFAULT_ADMIN_ROLE(), relayDeployer)
        ) {
            _requireStep(5, string.concat("Sender transport deployer still has DEFAULT_ADMIN_ROLE on ", label));
        }
        if (
            relayDeployer != expectedOwner
                && senderTransport.hasRole(senderTransport.CONFIG_MANAGER_ROLE(), relayDeployer)
        ) {
            _requireStep(5, string.concat("Sender transport deployer still has CONFIG_MANAGER_ROLE on ", label));
        }
    }

    function _verifyReceiverControl(LayerZeroReceiverTransport stateReceiver, address expectedOwner) internal {
        if (stateReceiver.owner() != expectedOwner) {
            _requireStep(5, "StateReceiver ownership not transferred");
        }
        if (!stateReceiver.hasRole(stateReceiver.DEFAULT_ADMIN_ROLE(), expectedOwner)) {
            _requireStep(5, "StateReceiver missing DEFAULT_ADMIN_ROLE for OFT_OWNER");
        }
        if (!stateReceiver.hasRole(stateReceiver.PAUSER_ROLE(), expectedOwner)) {
            _requireStep(5, "StateReceiver missing PAUSER_ROLE for OFT_OWNER");
        }
        if (!stateReceiver.hasRole(stateReceiver.STATE_STORE_MANAGER_ROLE(), expectedOwner)) {
            _requireStep(5, "StateReceiver missing STATE_STORE_MANAGER_ROLE for OFT_OWNER");
        }
        if (relayDeployer != expectedOwner && stateReceiver.owner() == relayDeployer) {
            _requireStep(5, "StateReceiver ownership still held by deployer");
        }
        if (relayDeployer != expectedOwner && stateReceiver.hasRole(stateReceiver.DEFAULT_ADMIN_ROLE(), relayDeployer))
        {
            _requireStep(5, "StateReceiver deployer still has DEFAULT_ADMIN_ROLE");
        }
        if (relayDeployer != expectedOwner && stateReceiver.hasRole(stateReceiver.PAUSER_ROLE(), relayDeployer)) {
            _requireStep(5, "StateReceiver deployer still has PAUSER_ROLE");
        }
        if (
            relayDeployer != expectedOwner
                && stateReceiver.hasRole(stateReceiver.STATE_STORE_MANAGER_ROLE(), relayDeployer)
        ) {
            _requireStep(5, "StateReceiver deployer still has STATE_STORE_MANAGER_ROLE");
        }
    }

    function _verifySenderRouteAndLzConfig(string memory label, LayerZeroSenderTransport senderTransport) internal {
        address stateReceiverAddress = stateReceiverOf[receiverChainId];
        if (!isContract(stateReceiverAddress)) {
            _warn(string.concat("Receiver not deployed yet; skipping sender peer verification for ", label));
            return;
        }

        uint32 expectedDestinationEid = getEID(receiverChainId);
        bytes32 expectedReceiverPeer = addressToBytes32(stateReceiverAddress);
        (uint32 configuredDestinationEid, bytes32 configuredPeer, bytes memory options, bool enabled) =
            senderTransport.destinations(receiverChainId);

        if (!enabled) {
            _requireStep(3, string.concat("Sender destination disabled for ", label));
        }
        if (configuredDestinationEid != expectedDestinationEid) {
            _requireStep(3, string.concat("Sender destination EID mismatch for ", label));
        }
        if (
            configuredPeer != expectedReceiverPeer
                || senderTransport.peers(expectedDestinationEid) != expectedReceiverPeer
        ) {
            _requireStep(3, string.concat("Sender peer not configured to receiver for ", label));
        }
        if (keccak256(options) != keccak256(defaultSendOptions())) {
            _requireStep(3, string.concat("Sender options do not match defaultSendOptions for ", label));
        }

        uint256[] memory destinationChainIds = _dstChainIdsForSender();
        _verifyLzConfig(
            string.concat("StateSender transport [", label, "]"), address(senderTransport), destinationChainIds, 3
        );
    }

    function _verifyReceiverLzConfig(address stateReceiverAddress) internal {
        (uint256[] memory remoteChainIds, bytes32[] memory remotePeers) = _receiverRemotePeers();

        IOAppCore receiverOApp = IOAppCore(stateReceiverAddress);
        for (uint256 i; i < remoteChainIds.length; i++) {
            uint32 remoteEid = getEID(remoteChainIds[i]);
            if (receiverOApp.peers(remoteEid) != remotePeers[i]) {
                _requireStep(
                    4, string.concat("Receiver peer mismatch for remote chain ", vm.toString(remoteChainIds[i]))
                );
            }
        }

        _verifyLzConfig("StateReceiver", stateReceiverAddress, remoteChainIds, 4);
    }

    function _verifyLzConfig(string memory componentName, address oapp, uint256[] memory otherChainIds, uint8 step)
        internal
    {
        Data storage data = getData(block.chainid);
        UlnConfig memory expectedUlnConfig = _getUlnConfig();
        bytes memory expectedUlnConfigEncoded = abi.encode(expectedUlnConfig);
        bytes memory expectedExecutorConfig =
            abi.encode(ExecutorConfig({maxMessageSize: DEFAULT_MAX_MESSAGE_SIZE, executor: data.LZ_EXECUTOR}));

        for (uint256 i; i < otherChainIds.length; i++) {
            _verifyLzConfigForRemote(
                componentName, oapp, otherChainIds[i], step, data, expectedUlnConfigEncoded, expectedExecutorConfig
            );
        }

        if (ILZEndpointDelegates(data.LZ_ENDPOINT).delegates(oapp) != data.OFT_OWNER) {
            _requireStep(step, string.concat(componentName, " delegate is not OFT_OWNER"));
        }
    }

    function _verifyLzConfigForRemote(
        string memory componentName,
        address oapp,
        uint256 otherChainId,
        uint8 step,
        Data storage data,
        bytes memory expectedUlnConfigEncoded,
        bytes memory expectedExecutorConfig
    ) internal {
        ILayerZeroEndpointV2 lzEndpoint = ILayerZeroEndpointV2(data.LZ_ENDPOINT);
        uint32 eid = getEID(otherChainId);
        bytes memory sendUlnConfigBytes = lzEndpoint.getConfig(oapp, data.LZ_SEND_LIB, eid, CONFIG_TYPE_ULN);
        bytes memory receiveUlnConfigBytes = lzEndpoint.getConfig(oapp, data.LZ_RECEIVE_LIB, eid, CONFIG_TYPE_ULN);

        if (lzEndpoint.getSendLibrary(oapp, eid) != data.LZ_SEND_LIB) {
            _requireStep(
                step, string.concat(componentName, " missing send library for chain ", vm.toString(otherChainId))
            );
        }

        (address receiveLibrary, bool isDefault) = lzEndpoint.getReceiveLibrary(oapp, eid);
        if (receiveLibrary != data.LZ_RECEIVE_LIB || isDefault) {
            _requireStep(
                step, string.concat(componentName, " missing receive library for chain ", vm.toString(otherChainId))
            );
        }

        if (
            keccak256(sendUlnConfigBytes) != keccak256(expectedUlnConfigEncoded)
                || keccak256(receiveUlnConfigBytes) != keccak256(expectedUlnConfigEncoded)
        ) {
            _requireStep(
                step, string.concat(componentName, " ULN config mismatch for chain ", vm.toString(otherChainId))
            );
        }

        if (!isTestnetChainId(block.chainid)) {
            _verifyExplicitMainnetUlnConfig(
                componentName, abi.decode(sendUlnConfigBytes, (UlnConfig)), otherChainId, step, "send"
            );
            _verifyExplicitMainnetUlnConfig(
                componentName, abi.decode(receiveUlnConfigBytes, (UlnConfig)), otherChainId, step, "receive"
            );
        }

        if (
            keccak256(lzEndpoint.getConfig(oapp, data.LZ_SEND_LIB, eid, CONFIG_TYPE_EXECUTOR))
                != keccak256(expectedExecutorConfig)
        ) {
            _requireStep(
                step, string.concat(componentName, " executor config mismatch for chain ", vm.toString(otherChainId))
            );
        }
    }

    function _verifyExplicitMainnetUlnConfig(
        string memory componentName,
        UlnConfig memory actualUlnConfig,
        uint256 otherChainId,
        uint8 step,
        string memory direction
    ) internal {
        if (actualUlnConfig.requiredDVNs.length != 3) {
            _requireStep(
                step,
                string.concat(
                    componentName,
                    " ",
                    direction,
                    " ULN requiredDVNs length must be 3 for chain ",
                    vm.toString(otherChainId)
                )
            );
        }
        if (actualUlnConfig.optionalDVNs.length != 0) {
            _requireStep(
                step,
                string.concat(
                    componentName,
                    " ",
                    direction,
                    " ULN optionalDVNs length must be 0 for chain ",
                    vm.toString(otherChainId)
                )
            );
        }
        if (actualUlnConfig.requiredDVNCount != 3) {
            _requireStep(
                step,
                string.concat(
                    componentName,
                    " ",
                    direction,
                    " ULN requiredDVNCount must be 3 for chain ",
                    vm.toString(otherChainId)
                )
            );
        }
        if (actualUlnConfig.optionalDVNCount != 0) {
            _requireStep(
                step,
                string.concat(
                    componentName,
                    " ",
                    direction,
                    " ULN optionalDVNCount must be 0 for chain ",
                    vm.toString(otherChainId)
                )
            );
        }
        if (actualUlnConfig.optionalDVNThreshold != 0) {
            _requireStep(
                step,
                string.concat(
                    componentName,
                    " ",
                    direction,
                    " ULN optionalDVNThreshold must be 0 for chain ",
                    vm.toString(otherChainId)
                )
            );
        }
        if (actualUlnConfig.confirmations != 32) {
            _requireStep(
                step,
                string.concat(
                    componentName, " ", direction, " ULN confirmations must be 32 for chain ", vm.toString(otherChainId)
                )
            );
        }
    }

    function _verifyTransparentProxy(
        string memory label,
        address proxy,
        address expectedProxyAdmin,
        address expectedTimelock
    ) internal {
        address actualProxyAdmin = _proxyAdminOf(proxy);
        if (expectedProxyAdmin == address(0)) {
            _warn(string.concat(label, " deployment JSON missing proxyAdmin"));
        } else if (actualProxyAdmin != expectedProxyAdmin) {
            _warn(
                string.concat(
                    label,
                    " proxy admin mismatch: stored=",
                    vm.toString(expectedProxyAdmin),
                    ", onchain=",
                    vm.toString(actualProxyAdmin)
                )
            );
        }

        if (!isContract(actualProxyAdmin)) {
            _warn(string.concat(label, " proxy admin is not deployed"));
            return;
        }

        address actualProxyAdminOwner = Ownable(actualProxyAdmin).owner();
        if (expectedTimelock == address(0)) {
            _warn(string.concat(label, " deployment JSON missing proxyAdminTimelock"));
        } else if (actualProxyAdminOwner != expectedTimelock) {
            _warn(
                string.concat(
                    label,
                    " proxy admin owner mismatch: stored timelock=",
                    vm.toString(expectedTimelock),
                    ", onchain owner=",
                    vm.toString(actualProxyAdminOwner)
                )
            );
        }

        if (!isContract(actualProxyAdminOwner)) {
            _warn(string.concat(label, " timelock is not deployed"));
            return;
        }

        TimelockController timelock = TimelockController(payable(actualProxyAdminOwner));
        Data storage data = getData(block.chainid);
        if (timelock.getMinDelay() != PROXY_ADMIN_TIMELOCK_DELAY) {
            _warn(string.concat(label, " timelock delay mismatch"));
        }
        if (!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), data.OFT_OWNER)) {
            _warn(string.concat(label, " timelock missing DEFAULT_ADMIN_ROLE for OFT_OWNER"));
        }
        if (!timelock.hasRole(timelock.PROPOSER_ROLE(), data.OFT_OWNER)) {
            _warn(string.concat(label, " timelock missing PROPOSER_ROLE for OFT_OWNER"));
        }
        if (!timelock.hasRole(timelock.EXECUTOR_ROLE(), data.OFT_OWNER)) {
            _warn(string.concat(label, " timelock missing EXECUTOR_ROLE for OFT_OWNER"));
        }
    }

    function _requireRole(bool ok, uint8 step, string memory message) internal {
        if (ok) return;
        if (step == 0) {
            _warn(message);
        } else {
            _requireStep(step, message);
        }
    }

    function _requireCriticalRole(bool ok, string memory message) internal pure {
        if (!ok) revert VerifyStateRelay_CriticalMisconfiguration(message);
    }

    function _requireStep(uint8 step, string memory message) internal {
        if (step == 1) needsStep1 = true;
        if (step == 2) needsStep2 = true;
        if (step == 3) needsStep3 = true;
        if (step == 4) needsStep4 = true;
        if (step == 5) needsStep5 = true;
        remainingActions.push(message);
        console.log("REMAINING: %s", message);
    }

    function _warn(string memory message) internal {
        warnings.push(message);
        console.log("WARNING: %s", message);
    }

    function _printSummary() internal view {
        console.log("");
        console.log("=== Verification Summary ===");
        if (remainingActions.length == 0 && warnings.length == 0) {
            console.log("All checked deployment and configuration items look correct.");
            return;
        }

        if (needsStep1) console.log("Step 1 remaining: DeployStateRelaySenders");
        if (needsStep2) console.log("Step 2 remaining: DeployStateRelayDestination");
        if (needsStep3) console.log("Step 3 remaining: ConfigureStateRelaySenders");
        if (needsStep4) console.log("Step 4 remaining: ConfigureStateRelayReceiver");
        if (needsStep5) console.log("Step 5 remaining: TransferStateRelayOwnership");

        if (remainingActions.length > 0) {
            console.log("");
            console.log("Remaining actions:");
            for (uint256 i; i < remainingActions.length; i++) {
                console.log("- %s", remainingActions[i]);
            }
        }

        if (warnings.length > 0) {
            console.log("");
            console.log("Warnings:");
            for (uint256 i; i < warnings.length; i++) {
                console.log("- %s", warnings[i]);
            }
        }
    }
}
