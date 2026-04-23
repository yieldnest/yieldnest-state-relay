// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateReaderBaseUpgradeable} from "../StateReaderBaseUpgradeable.sol";

/**
 * @title RateAdapterUpgradeable
 * @notice Reads the relayed rate from StateStore; decodes the uint256 value encoded by StateSender (staticcall return).
 */
contract RateAdapterUpgradeable is StateReaderBaseUpgradeable {
    /**
     * @notice Initializes the adapter to read a specific relayed rate key with freshness bounds.
     * @param _stateStore State store contract providing relayed values.
     * @param _rateKey Relay key for the rate entry.
     * @param _maxSrcStaleness Maximum allowed age of the source timestamp.
     * @param _maxDstStaleness Maximum allowed age since delivery to the destination chain.
     */
    function initialize(address _stateStore, bytes32 _rateKey, uint256 _maxSrcStaleness, uint256 _maxDstStaleness)
        external
        initializer
    {
        __StateReaderBase_init(_stateStore, _rateKey, _maxSrcStaleness, _maxDstStaleness);
    }

    /**
     * @notice Returns the decoded relayed rate value.
     * @return Current rate stored under the configured relay key.
     */
    function getRate() external view returns (uint256) {
        return abi.decode(_getValue(), (uint256));
    }

    /**
     * @notice Returns the relay key used by this adapter.
     * @return Relay key read from the state store.
     */
    function rateKey() external view returns (bytes32) {
        return stateKey;
    }
}
