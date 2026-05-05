/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {KeyDerivation} from "../../../src/KeyDerivation.sol";
import {RateAdapterUpgradeable} from "../../../src/adapter/RateAdapterUpgradeable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AdapterScriptBase} from "./AdapterScriptBase.s.sol";

/// @notice Deploys a RateAdapterUpgradeable for a sender label on the receiver chain.
/// @dev Persists the adapter under `.chains.<receiverChainId>.rateAdapters.<label>` in the deployment JSON.
contract DeployRateAdapter is AdapterScriptBase {
    struct DeploymentContext {
        address stateStoreAddress;
        bytes32 rateKey;
        address adapterOwner;
    }

    function run(
        string calldata inputPath,
        string calldata deploymentPath,
        string calldata label,
        uint256 scalingFactor,
        uint256 maxSrcStaleness,
        uint256 maxDstStaleness,
        uint256 maxSourceTimestampSkew
    ) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeploymentRequired();

        require(block.chainid == receiverChainId, "StateRelay: rate adapter deploy only on receiver chain RPC");

        AdapterDeployment memory existingDeployment = _loadAdapterDeployment(label);
        if (isContract(existingDeployment.adapter)) {
            console.log("RateAdapter [%s] already at:", label);
            console.logAddress(existingDeployment.adapter);
            return;
        }

        DeploymentContext memory deploymentContext = _prepareDeploymentContext(label);

        (address rateAdapterAddress, address rateAdapterProxyAdmin, address adapterTimelock) = _deployRateAdapter(
            deploymentContext.adapterOwner,
            deploymentContext.stateStoreAddress,
            deploymentContext.rateKey,
            scalingFactor,
            maxSrcStaleness,
            maxDstStaleness,
            maxSourceTimestampSkew
        );

        AdapterDeployment memory deployment;
        deployment.adapter = rateAdapterAddress;
        deployment.proxyAdmin = rateAdapterProxyAdmin;
        deployment.proxyAdminTimelock = adapterTimelock;
        deployment.stateStore = deploymentContext.stateStoreAddress;
        deployment.rateKey = deploymentContext.rateKey;
        deployment.scalingFactor = scalingFactor;
        deployment.maxSrcStaleness = maxSrcStaleness;
        deployment.maxDstStaleness = maxDstStaleness;
        deployment.maxSourceTimestampSkew = maxSourceTimestampSkew;

        _logAndSaveRateAdapter(label, deployment);
    }

    function _prepareDeploymentContext(string memory label) internal view returns (DeploymentContext memory deploymentContext) {
        SenderInput memory senderInput = _senderInputForLabel(label);
        deploymentContext.stateStoreAddress = stateStoreOf[receiverChainId];
        require(isContract(deploymentContext.stateStoreAddress), "StateRelay: destination state store not deployed");
        deploymentContext.rateKey =
            KeyDerivation.deriveKey(senderInput.chainId, senderInput.target, senderInput.callData);
        deploymentContext.adapterOwner = getData(receiverChainId).OFT_OWNER;
    }

    function _saveRateAdapterDeployment(string memory label, AdapterDeployment memory deployment) internal {
        _ensureAdapterDeploymentDir();
        string memory filePath = adapterDeploymentFilePath();
        if (!vm.isFile(filePath)) {
            vm.writeJson("{\"chains\":{}}", filePath);
        }

        string memory objectKey = string.concat("rateAdapter_", vm.toString(receiverChainId), "_", label);
        string memory adapterObject = vm.serializeAddress(objectKey, "address", deployment.adapter);
        adapterObject = vm.serializeAddress(objectKey, "proxyAdmin", deployment.proxyAdmin);
        adapterObject = vm.serializeAddress(objectKey, "proxyAdminTimelock", deployment.proxyAdminTimelock);
        adapterObject = vm.serializeAddress(objectKey, "stateStore", deployment.stateStore);
        adapterObject = vm.serializeBytes32(objectKey, "rateKey", deployment.rateKey);
        adapterObject = vm.serializeUint(objectKey, "scalingFactor", deployment.scalingFactor);
        adapterObject = vm.serializeUint(objectKey, "maxSrcStaleness", deployment.maxSrcStaleness);
        adapterObject = vm.serializeUint(objectKey, "maxDstStaleness", deployment.maxDstStaleness);
        adapterObject =
            vm.serializeUint(objectKey, "maxSourceTimestampSkew", deployment.maxSourceTimestampSkew);
        string memory basePath = string.concat(".chains.", vm.toString(receiverChainId), ".rateAdapters.", label);
        vm.writeJson(adapterObject, filePath, basePath);

        console.log("Wrote deployment to %s", filePath);
    }

    function _deployRateAdapter(
        address adapterOwner,
        address stateStoreAddress,
        bytes32 rateKey,
        uint256 scalingFactor,
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
                maxSourceTimestampSkew,
                scalingFactor
            )
        );
        TransparentUpgradeableProxy adapterProxy =
            new TransparentUpgradeableProxy(address(adapterImplementation), adapterTimelock, adapterInit);
        vm.stopBroadcast();

        rateAdapterAddress = address(adapterProxy);
        rateAdapterProxyAdmin = _proxyAdminOf(rateAdapterAddress);
    }

    function _logAndSaveRateAdapter(string memory label, AdapterDeployment memory deployment) internal {
        console.log("RateAdapter [%s] proxy:", label);
        console.logAddress(deployment.adapter);
        console.log("RateAdapter [%s] proxy admin:", label);
        console.logAddress(deployment.proxyAdmin);
        console.log("RateAdapter [%s] proxy admin timelock:", label);
        console.logAddress(deployment.proxyAdminTimelock);
        console.log("RateAdapter [%s] stateStore:", label);
        console.logAddress(deployment.stateStore);
        console.log("RateAdapter [%s] rateKey:", label);
        console.logBytes32(deployment.rateKey);
        console.log("RateAdapter [%s] scalingFactor:", label);
        console.logUint(deployment.scalingFactor);
        console.log("RateAdapter [%s] maxSrcStaleness:", label);
        console.logUint(deployment.maxSrcStaleness);
        console.log("RateAdapter [%s] maxDstStaleness:", label);
        console.logUint(deployment.maxDstStaleness);
        console.log("RateAdapter [%s] maxSourceTimestampSkew:", label);
        console.logUint(deployment.maxSourceTimestampSkew);

        _saveRateAdapterDeployment(label, deployment);
    }
}
