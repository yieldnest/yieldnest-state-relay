/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateRelayBase} from "../../StateRelayBase.s.sol";

abstract contract AdapterScriptBase is StateRelayBase {
    struct AdapterDeployment {
        address adapter;
        address proxyAdmin;
        address proxyAdminTimelock;
        address stateStore;
        bytes32 rateKey;
        uint256 maxSrcStaleness;
        uint256 maxDstStaleness;
        uint256 maxSourceTimestampSkew;
    }

    function adapterDeploymentFilePath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/adapters/", relayName, "-", relayVersion, ".json");
    }

    function _ensureAdapterDeploymentDir() internal {
        vm.createDir(string.concat(vm.projectRoot(), "/deployments/adapters"), true);
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

    function _loadAdapterDeployment(string memory label) internal view returns (AdapterDeployment memory deployment) {
        string memory filePath = adapterDeploymentFilePath();
        if (!vm.isFile(filePath)) {
            return deployment;
        }

        string memory json = vm.readFile(filePath);
        string memory basePath =
            string.concat(".chains.", vm.toString(receiverChainId), ".rateAdapters.", label);

        try vm.parseJsonAddress(json, string.concat(basePath, ".address")) returns (address adapterAddress) {
            deployment.adapter = adapterAddress;
        } catch {}
        try vm.parseJsonAddress(json, string.concat(basePath, ".proxyAdmin")) returns (address proxyAdmin) {
            deployment.proxyAdmin = proxyAdmin;
        } catch {}
        try vm.parseJsonAddress(json, string.concat(basePath, ".proxyAdminTimelock")) returns (address proxyAdminTimelock)
        {
            deployment.proxyAdminTimelock = proxyAdminTimelock;
        } catch {}
        try vm.parseJsonAddress(json, string.concat(basePath, ".stateStore")) returns (address stateStoreAddress) {
            deployment.stateStore = stateStoreAddress;
        } catch {}
        try vm.parseJsonBytes32(json, string.concat(basePath, ".rateKey")) returns (bytes32 rateKey) {
            deployment.rateKey = rateKey;
        } catch {}
        try vm.parseJsonUint(json, string.concat(basePath, ".maxSrcStaleness")) returns (uint256 maxSrcStaleness) {
            deployment.maxSrcStaleness = maxSrcStaleness;
        } catch {}
        try vm.parseJsonUint(json, string.concat(basePath, ".maxDstStaleness")) returns (uint256 maxDstStaleness) {
            deployment.maxDstStaleness = maxDstStaleness;
        } catch {}
        try vm.parseJsonUint(json, string.concat(basePath, ".maxSourceTimestampSkew")) returns (uint256 maxSourceTimestampSkew) {
            deployment.maxSourceTimestampSkew = maxSourceTimestampSkew;
        } catch {}
    }
}
