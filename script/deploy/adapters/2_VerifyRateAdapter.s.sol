/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {AdapterScriptBase} from "./AdapterScriptBase.s.sol";
import {RateAdapterUpgradeable} from "../../../src/adapter/RateAdapterUpgradeable.sol";
import {KeyDerivation} from "../../../src/KeyDerivation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract VerifyRateAdapter is AdapterScriptBase {
    string[] internal remainingActions;
    string[] internal warnings;

    function run(string calldata inputPath, string calldata relayDeploymentPath, string calldata label) external {
        setUp();
        loadInput(inputPath, relayDeploymentPath);
        loadDeploymentRequired();

        delete remainingActions;
        delete warnings;

        require(block.chainid == receiverChainId, "StateRelay: rate adapter verify only on receiver chain RPC");

        SenderInput memory senderInput = _senderInputForLabel(label);
        address expectedStateStore = stateStoreOf[receiverChainId];
        require(isContract(expectedStateStore), "StateRelay: destination state store not deployed");

        AdapterDeployment memory deployment = _loadAdapterDeployment(label);
        if (!isContract(deployment.adapter)) {
            _require(string.concat("RateAdapter not deployed for label ", label));
            _printSummary();
            return;
        }

        bytes32 expectedRateKey = KeyDerivation.deriveKey(senderInput.chainId, senderInput.target, senderInput.callData);
        address expectedOwner = getData(receiverChainId).OFT_OWNER;

        console.log("Verifying RateAdapter on chainId %s", block.chainid);
        console.log("Relay deployment file: %s", deploymentFilePath());
        console.log("Adapter deployment file: %s", adapterDeploymentFilePath());
        console.log("RateAdapter [%s] deployed at %s", label, vm.toString(deployment.adapter));

        _verifyTransparentProxy(
            string.concat("RateAdapter [", label, "]"),
            deployment.adapter,
            deployment.proxyAdmin,
            deployment.proxyAdminTimelock
        );

        RateAdapterUpgradeable rateAdapter = RateAdapterUpgradeable(deployment.adapter);

        if (!rateAdapter.hasRole(rateAdapter.DEFAULT_ADMIN_ROLE(), expectedOwner)) {
            _require("RateAdapter missing DEFAULT_ADMIN_ROLE for OFT_OWNER");
        }
        if (!rateAdapter.hasRole(rateAdapter.CONFIG_MANAGER_ROLE(), expectedOwner)) {
            _require("RateAdapter missing CONFIG_MANAGER_ROLE for OFT_OWNER");
        }
        if (!rateAdapter.hasRole(rateAdapter.STATE_STORE_MANAGER_ROLE(), expectedOwner)) {
            _require("RateAdapter missing STATE_STORE_MANAGER_ROLE for OFT_OWNER");
        }
        if (address(rateAdapter.stateStore()) != expectedStateStore) {
            _require("RateAdapter stateStore does not match deployed relay StateStore");
        }
        if (deployment.stateStore != address(0) && deployment.stateStore != expectedStateStore) {
            _warn("Adapter deployment JSON stateStore does not match deployed relay StateStore");
        }
        if (rateAdapter.rateKey() != expectedRateKey) {
            _require("RateAdapter rateKey does not match derived relay key");
        }
        if (deployment.rateKey != bytes32(0) && deployment.rateKey != expectedRateKey) {
            _warn("Adapter deployment JSON rateKey does not match derived relay key");
        }
        if (rateAdapter.scalingFactor() != deployment.scalingFactor) {
            _require("RateAdapter scalingFactor does not match adapter deployment JSON");
        }
        if (rateAdapter.maxSrcStaleness() != deployment.maxSrcStaleness) {
            _require("RateAdapter maxSrcStaleness does not match adapter deployment JSON");
        }
        if (rateAdapter.maxDstStaleness() != deployment.maxDstStaleness) {
            _require("RateAdapter maxDstStaleness does not match adapter deployment JSON");
        }
        if (rateAdapter.maxSourceTimestampSkew() != deployment.maxSourceTimestampSkew) {
            _require("RateAdapter maxSourceTimestampSkew does not match adapter deployment JSON");
        }

        _printSummary();
    }

    function _verifyTransparentProxy(
        string memory label,
        address proxy,
        address expectedProxyAdmin,
        address expectedTimelock
    ) internal {
        address actualProxyAdmin = _proxyAdminOf(proxy);
        if (expectedProxyAdmin == address(0)) {
            _warn(string.concat(label, " adapter deployment JSON missing proxyAdmin"));
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
            _warn(string.concat(label, " adapter deployment JSON missing proxyAdminTimelock"));
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
        address oftOwner = getData(block.chainid).OFT_OWNER;
        if (timelock.getMinDelay() != PROXY_ADMIN_TIMELOCK_DELAY) {
            _warn(string.concat(label, " timelock delay mismatch"));
        }
        if (!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), oftOwner)) {
            _warn(string.concat(label, " timelock missing DEFAULT_ADMIN_ROLE for OFT_OWNER"));
        }
        if (!timelock.hasRole(timelock.PROPOSER_ROLE(), oftOwner)) {
            _warn(string.concat(label, " timelock missing PROPOSER_ROLE for OFT_OWNER"));
        }
        if (!timelock.hasRole(timelock.EXECUTOR_ROLE(), oftOwner)) {
            _warn(string.concat(label, " timelock missing EXECUTOR_ROLE for OFT_OWNER"));
        }
    }

    function _require(string memory message) internal {
        remainingActions.push(message);
        console.log("REMAINING: %s", message);
    }

    function _warn(string memory message) internal {
        warnings.push(message);
        console.log("WARNING: %s", message);
    }

    function _printSummary() internal view {
        console.log("");
        console.log("=== RateAdapter Verification Summary ===");
        if (remainingActions.length == 0 && warnings.length == 0) {
            console.log("All checked deployment and configuration items look correct.");
            return;
        }

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
