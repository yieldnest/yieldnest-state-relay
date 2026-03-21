/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateRelayBase} from "../StateRelayBase.s.sol";

/// @notice Step 1: deploy StateStore + StateReceiver on `receiverChainId`, and StateSender proxies on each sender chain.
/// @dev Run once per chain involved (same pattern as `1_DeployOFT`). Optional second arg overrides deployment JSON path.
///
/// forge script script/deploy/1_DeployStateRelay.s.sol:DeployStateRelay \
///   --sig "run(string,string)" script/inputs/your-relay.json "" \
///   --rpc-url $RPC_URL --broadcast
contract DeployStateRelay is StateRelayBase {
    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeployment();
        runDeployForChain();
    }
}
