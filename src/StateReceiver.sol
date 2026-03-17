// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OAppUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import { StateStore } from "./StateStore.sol";

/**
 * @title StateReceiver
 * @notice Destination-chain upgradeable OApp: receives LZ message, decodes, forwards to StateStore (stub).
 */
contract StateReceiver is OAppUpgradeable {
    StateStore public stateStore;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    function initialize(address _owner, address _stateStore) external reinitializer(1) {
        __Ownable_init(_owner);
        __OApp_init(_owner);
        stateStore = StateStore(_stateStore);
    }

    function _lzReceive(
        Origin calldata,
        bytes32,
        bytes calldata,
        address,
        bytes calldata
    ) internal virtual override {
        // Stub: decode payload and call stateStore.write() to be implemented.
    }
}
