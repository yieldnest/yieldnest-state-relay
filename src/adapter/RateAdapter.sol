// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateReaderBase} from "../StateReaderBase.sol";

/**
 * @title RateAdapter
 * @notice Reads the relayed rate from StateStore; decodes the uint256 value encoded by StateSender (staticcall return).
 */
contract RateAdapter is StateReaderBase {
    constructor(address _stateStore, bytes32 _rateKey, uint256 _maxSrcStaleness, uint256 _maxDstStaleness)
        StateReaderBase(_stateStore, _rateKey, _maxSrcStaleness, _maxDstStaleness)
    {}

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
