// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {StateStore} from "../src/StateStore.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title Deploy
 * @notice Deploys StateStore implementation + proxy. Validates RPC and env (PRIVATE_KEY, RPC_URL).
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerPrivateKey);
        uint256 maxValueSize = 1024;

        vm.startBroadcast(deployerPrivateKey);

        StateStore impl = new StateStore();
        address[] memory writers = new address[](0);
        bytes memory initData = abi.encodeCall(StateStore.initialize, (owner, maxValueSize, writers));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), owner, initData);
        StateStore stateStore = StateStore(address(proxy));

        vm.stopBroadcast();

        console.log("StateStore implementation:", address(impl));
        console.log("StateStore proxy (use this):", address(proxy));
        console.log("Owner:", owner);
        console.log("maxValueSize:", stateStore.maxValueSize());
    }
}
