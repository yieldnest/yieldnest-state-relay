/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateRelayLzConfigure} from "../StateRelayLzConfigure.s.sol";

/// @notice **Step 4** — LayerZero config for **StateReceiver** on **`receiverChainId`** only.
/// @dev Requires senders deployed and present in deployment JSON. Run on destination chain RPC.
///
/// forge script --sig "run(string,string)" --rpc-url "$RPC_ARBITRUM" --broadcast --with-gas-price 1gwei script/deploy/4_ConfigureStateRelayReceiver.s.sol:ConfigureStateRelayReceiver script/inputs/anvil-mainnet-arbitrum.json ""
contract ConfigureStateRelayReceiver is StateRelayLzConfigure {
    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeploymentRequired();
        configureReceiver();
    }
}
