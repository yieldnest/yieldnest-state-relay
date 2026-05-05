/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {StateStore} from "../../src/StateStore.sol";
import {ReadStateCommandBase} from "./ReadStateCommandBase.s.sol";

/// @notice Reads the latest stored relay value for a sender label and decodes it as uint256.
/// @dev Run on the destination-chain RPC for the current relay deployment.
contract ReadStateAsUint256Command is ReadStateCommandBase {
    function run(string calldata inputPath, string calldata deploymentPath, string calldata label) external {
        (address stateStoreAddress, StateStore stateStore) = _setUpReadContext(inputPath, deploymentPath);
        bytes32 key = _keyForLabel(label);
        StateStore.Entry memory entry = stateStore.get(key);

        console.log("Reading latest state for label %s", label);
        console.log("StateStore: %s", vm.toString(stateStoreAddress));
        console.log("Key: %s", vm.toString(key));
        _printEntry(0, entry);
    }
}
