// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OAppUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";

/**
 * @title StateSender
 * @notice Source-chain upgradeable OApp: reads state via staticcall, sends via _lzSend.
 * @dev Stub: key derivation and send logic to be implemented.
 */
contract StateSender is OAppUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    /**
     * @notice Initialize the OApp and ownership.
     * @param _owner Delegate and owner (capable of configuring peers, etc.)
     */
    function initialize(address _owner) external reinitializer(1) {
        __Ownable_init(_owner);
        __OApp_init(_owner);
    }

    function _lzReceive(
        Origin calldata,
        bytes32,
        bytes calldata,
        address,
        bytes calldata
    ) internal virtual override {
        // Send-only OApp: no receive logic.
    }
}
