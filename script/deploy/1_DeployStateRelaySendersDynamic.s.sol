/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateRelayBase} from "../StateRelayBase.s.sol";

/// @notice **Step 1 (dynamic)** — deploy **StateSenderDynamic** (calldata per `sendState` / `quoteSendState`) on each **source** chain.
/// @dev Input `callData` is not stored; callers supply it on each send. Same `setupChain`/JSON otherwise as static step 1.
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
