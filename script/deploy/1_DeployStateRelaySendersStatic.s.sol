/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateRelayBase} from "../StateRelayBase.s.sol";

/// @notice **Step 1 (static)** — deploy **StateSenderStatic** (fixed calldata at init) on each **source** chain.
/// @dev Run with `--rpc-url` on every `senders.*.chainId` from input. For per-send calldata use `1_DeployStateRelaySendersDynamic.s.sol`.
///
/// forge script --sig "run(string,string)" --rpc-url "$RPC_MAINNET" --broadcast --with-gas-price 1gwei script/deploy/1_DeployStateRelaySendersStatic.s.sol:DeployStateRelaySendersStatic script/inputs/anvil-mainnet-arbitrum.json ""
contract DeployStateRelaySendersStatic is StateRelayBase {
    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeployment();
        deploySendersStatic();
    }
}
