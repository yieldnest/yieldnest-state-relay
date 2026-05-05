/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {StateRelayBase} from "../../StateRelayBase.s.sol";
import {KeyDerivation} from "../../../src/KeyDerivation.sol";
import {RateAdapterUpgradeable} from "../../../src/adapter/RateAdapterUpgradeable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Deploys a RateAdapterUpgradeable for a sender label on the receiver chain.
/// @dev Persists the adapter under `.chains.<receiverChainId>.rateAdapters.<label>` in the deployment JSON.
contract DeployRateAdapter is StateRelayBase {
    function run(
        string calldata inputPath,
        string calldata deploymentPath,
        string calldata label,
        uint256 maxSrcStaleness,
        uint256 maxDstStaleness,
        uint256 maxSourceTimestampSkew
    ) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeploymentRequired();

        require(block.chainid == receiverChainId, "StateRelay: rate adapter deploy only on receiver chain RPC");

        SenderInput memory senderInput = _senderInputForLabel(label);
        address stateStoreAddress = stateStoreOf[receiverChainId];
        require(isContract(stateStoreAddress), "StateRelay: destination state store not deployed");

        address existingAdapter = _existingRateAdapter(label);
        if (isContract(existingAdapter)) {
            console.log("RateAdapter [%s] already at:", label);
            console.logAddress(existingAdapter);
            return;
        }

        bytes32 rateKey = KeyDerivation.deriveKey(senderInput.chainId, senderInput.target, senderInput.callData);
        address adapterOwner = getData(receiverChainId).OFT_OWNER;

        (address rateAdapterAddress, address rateAdapterProxyAdmin, address adapterTimelock) = _deployRateAdapter(
            adapterOwner,
            stateStoreAddress,
            rateKey,
            maxSrcStaleness,
            maxDstStaleness,
            maxSourceTimestampSkew
        );

        _logAndSaveRateAdapter(label, rateAdapterAddress, rateAdapterProxyAdmin, adapterTimelock, stateStoreAddress, rateKey);
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

    function _existingRateAdapter(string memory label) internal view returns (address rateAdapterAddress) {
        string memory filePath = deploymentFilePath();
        if (!vm.isFile(filePath)) {
            return address(0);
        }

        string memory json = vm.readFile(filePath);
        string memory path =
            string.concat(".chains.", vm.toString(receiverChainId), ".rateAdapters.", label, ".address");
        try vm.parseJsonAddress(json, path) returns (address parsedAddress) {
            return parsedAddress;
        } catch {
            return address(0);
        }
    }

    function _saveRateAdapterDeployment(
        string memory label,
        address rateAdapterAddress,
        address rateAdapterProxyAdmin,
        address rateAdapterProxyAdminTimelock,
        address stateStoreAddress,
        bytes32 rateKey
    ) internal {
        string memory filePath = deploymentFilePath();
        if (!vm.isFile(filePath)) {
            vm.writeJson("{\"chains\":{}}", filePath);
        }

        string memory objectKey = string.concat("rateAdapter_", vm.toString(receiverChainId), "_", label);
        string memory adapterObject = vm.serializeAddress(objectKey, "address", rateAdapterAddress);
        adapterObject = vm.serializeAddress(objectKey, "proxyAdmin", rateAdapterProxyAdmin);
        adapterObject = vm.serializeAddress(objectKey, "proxyAdminTimelock", rateAdapterProxyAdminTimelock);
        adapterObject = vm.serializeAddress(objectKey, "stateStore", stateStoreAddress);
        adapterObject = vm.serializeBytes32(objectKey, "rateKey", rateKey);
        vm.writeJson(
            adapterObject,
            filePath,
            string.concat(".chains.", vm.toString(receiverChainId), ".rateAdapters.", label)
        );

        console.log("Wrote deployment to %s", filePath);
    }

    function _deployRateAdapter(
        address adapterOwner,
        address stateStoreAddress,
        bytes32 rateKey,
        uint256 maxSrcStaleness,
        uint256 maxDstStaleness,
        uint256 maxSourceTimestampSkew
    ) internal returns (address rateAdapterAddress, address rateAdapterProxyAdmin, address adapterTimelock) {
        _startBroadcast();
        adapterTimelock = _deployTimelockController(adapterOwner, PROXY_ADMIN_TIMELOCK_DELAY);
        RateAdapterUpgradeable adapterImplementation = new RateAdapterUpgradeable();
        bytes memory adapterInit = abi.encodeCall(
            RateAdapterUpgradeable.initialize,
            (
                adapterOwner,
                stateStoreAddress,
                rateKey,
                maxSrcStaleness,
                maxDstStaleness,
                maxSourceTimestampSkew
            )
        );
        TransparentUpgradeableProxy adapterProxy =
            new TransparentUpgradeableProxy(address(adapterImplementation), adapterTimelock, adapterInit);
        vm.stopBroadcast();

        rateAdapterAddress = address(adapterProxy);
        rateAdapterProxyAdmin = _proxyAdminOf(rateAdapterAddress);
    }

    function _logAndSaveRateAdapter(
        string memory label,
        address rateAdapterAddress,
        address rateAdapterProxyAdmin,
        address rateAdapterProxyAdminTimelock,
        address stateStoreAddress,
        bytes32 rateKey
    ) internal {
        console.log("RateAdapter [%s] proxy:", label);
        console.logAddress(rateAdapterAddress);
        console.log("RateAdapter [%s] proxy admin:", label);
        console.logAddress(rateAdapterProxyAdmin);
        console.log("RateAdapter [%s] proxy admin timelock:", label);
        console.logAddress(rateAdapterProxyAdminTimelock);
        console.log("RateAdapter [%s] stateStore:", label);
        console.logAddress(stateStoreAddress);
        console.log("RateAdapter [%s] rateKey:", label);
        console.logBytes32(rateKey);

        _saveRateAdapterDeployment(
            label,
            rateAdapterAddress,
            rateAdapterProxyAdmin,
            rateAdapterProxyAdminTimelock,
            stateStoreAddress,
            rateKey
        );
    }
}
