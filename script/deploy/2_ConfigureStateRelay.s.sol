/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateRelayLzConfigure} from "../StateRelayLzConfigure.s.sol";

/// @notice Step 2: wire LayerZero peers, libs, DVNs, executor, delegate (mirrors `2_ConfigureOFT`).
/// @dev Run once per chain: on each sender chain configures that chain's StateSender(s); on the receiver chain configures StateReceiver. At most one `senders` entry per source chain ID for a given relay (OApp receiver stores one peer per source EID).
///
/// forge script script/deploy/2_ConfigureStateRelay.s.sol:ConfigureStateRelay \
///   --sig "run(string,string)" script/inputs/your-relay.json "" \
///   --rpc-url $RPC_URL --broadcast
contract ConfigureStateRelay is StateRelayLzConfigure {
    function run(string calldata inputPath, string calldata deploymentPath) external {
        setUp();
        loadInput(inputPath, deploymentPath);
        loadDeploymentRequired();
        runConfigureForChain();
    }
}
