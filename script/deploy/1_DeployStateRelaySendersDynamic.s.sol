/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateRelayBase} from "../StateRelayBase.s.sol";

/// @notice **Step 1 (dynamic)** — deploy **StateSenderDynamic** (`target` + `callData` per `sendState` / `quoteSendState`) on each **source** chain.
/// @dev Input `target` / `callData` are not used for storage; callers supply both on each send (read-only staticcalls only).
///
/// forge script --sig "run(string,string)" --rpc-url "$RPC_MAINNET" --broadcast --with-gas-price 1gwei script/deploy/1_DeployStateRelaySendersDynamic.s.sol:DeployStateRelaySendersDynamic script/inputs/anvil-mainnet-arbitrum.json ""
contract DeployStateRelaySendersDynamic is StateRelayBase {
    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeployment();
        deploySendersDynamic();
    }
}
