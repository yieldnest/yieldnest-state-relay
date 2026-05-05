/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {StateStore} from "../../src/StateStore.sol";
import {ReadStateCommandBase} from "./ReadStateCommandBase.s.sol";

/// @notice Prints up to the latest 20 stored relay values for a sender label, decoded as uint256.
/// @dev Run on the destination-chain RPC for the current relay deployment.
contract ReadStateHistoryAsUint256Command is ReadStateCommandBase {
    uint256 internal constant MAX_ENTRIES_TO_PRINT = 20;

    function run(string calldata inputPath, string calldata deploymentPath, string calldata label) external {
        (address stateStoreAddress, StateStore stateStore) = _setUpReadContext(inputPath, deploymentPath);
        bytes32 key = _keyForLabel(label);
        uint256 totalEntries = stateStore.length(key);
        uint256 entriesToPrint = totalEntries > MAX_ENTRIES_TO_PRINT ? MAX_ENTRIES_TO_PRINT : totalEntries;

        console.log("Reading latest %s entrie(s) for label %s", entriesToPrint, label);
        console.log("StateStore: %s", vm.toString(stateStoreAddress));
        console.log("Key: %s", vm.toString(key));
        console.log("Total entries available: %s", totalEntries);

        for (uint256 reverseIndex; reverseIndex < entriesToPrint; reverseIndex++) {
            StateStore.Entry memory entry = stateStore.get(key, reverseIndex);
            _printEntry(reverseIndex, entry);
        }
    }
}
