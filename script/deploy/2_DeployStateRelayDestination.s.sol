/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateRelayBase} from "../StateRelayBase.s.sol";

/// @notice **Step 2** — deploy **StateStore** + **StateReceiver** on **`receiverChainId`** only.
/// @dev Run with `--rpc-url` equal to the destination chain (e.g. Arbitrum when `receiverChainId` is 42161).
///
/// forge script --sig "run(string,string)" --rpc-url "$RPC_ARBITRUM" --broadcast --with-gas-price 1gwei script/deploy/2_DeployStateRelayDestination.s.sol:DeployStateRelayDestination script/inputs/anvil-mainnet-arbitrum.json ""
contract DeployStateRelayDestination is StateRelayBase {
    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeployment();
        deployDestination();
    }
}
