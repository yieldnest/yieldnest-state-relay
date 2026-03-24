/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateRelayLzConfigure} from "../StateRelayLzConfigure.s.sol";

/// @notice **Step 3** — LayerZero config for **StateSender(s)** on each **source** chain.
/// @dev Requires step 2 done and deployment JSON containing `StateReceiver` address. Run once per sender chain RPC.
///
/// forge script --sig "run(string,string)" --rpc-url "$RPC_MAINNET" --broadcast --with-gas-price 1gwei script/deploy/3_ConfigureStateRelaySenders.s.sol:ConfigureStateRelaySenders script/inputs/anvil-mainnet-arbitrum.json ""
contract ConfigureStateRelaySenders is StateRelayLzConfigure {
    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeploymentRequired();
        configureSenders();
    }
}
