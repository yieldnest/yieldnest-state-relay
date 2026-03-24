/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateRelayBase} from "../StateRelayBase.s.sol";

/// @notice **Step 1** — deploy **StateSender** (relay) on each **source** chain.
/// @dev Run with `--rpc-url` on every `senders.*.chainId` from input (e.g. mainnet). Then step 2 on the receiver chain.
///
/// forge script --sig "run(string,string)" --rpc-url "$RPC_MAINNET" --broadcast --with-gas-price 1gwei script/deploy/1_DeployStateRelaySenders.s.sol:DeployStateRelaySenders script/inputs/anvil-mainnet-arbitrum.json ""
contract DeployStateRelaySenders is StateRelayBase {
    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeployment();
        deploySenders();
    }
}
