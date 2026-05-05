// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StateReaderBaseUpgradeable} from "../StateReaderBaseUpgradeable.sol";

/**
 * @title RateAdapterUpgradeable
 * @notice Reads the relayed rate from StateStore; decodes the uint256 value encoded by StateSender (staticcall return).
 */
contract RateAdapterUpgradeable is StateReaderBaseUpgradeable {
    /// @custom:storage-location erc7201:yieldnest.storage.rate_adapter
    struct RateAdapterStorage {
        uint256 scalingFactor;
    }

    /**
     * @notice Initializes the adapter to read a specific relayed rate key with freshness bounds.
     * @param _admin Address granted the default admin and reader manager roles.
     * @param _stateStore State store contract providing relayed values.
     * @param _rateKey Relay key for the rate entry.
     * @param _maxSrcStaleness Maximum allowed age of the source timestamp.
     * @param _maxDstStaleness Maximum allowed age since delivery to the destination chain.
     * @param _maxSourceTimestampSkew Maximum allowed future skew for the source timestamp.
     * @param _scalingFactor Scalar used by `getRateScaled()`.
     */
    function initialize(
        address _admin,
        address _stateStore,
        bytes32 _rateKey,
        uint256 _maxSrcStaleness,
        uint256 _maxDstStaleness,
        uint256 _maxSourceTimestampSkew,
        uint256 _scalingFactor
    ) external initializer {
        __StateReaderBase_init(
            _admin, _stateStore, _rateKey, _maxSrcStaleness, _maxDstStaleness, _maxSourceTimestampSkew
        );
        _getRateAdapterStorage().scalingFactor = _scalingFactor;
    }

    /**
     * @notice Returns the decoded relayed rate value.
     * @return Current rate stored under the configured relay key.
     */
    function getRate() external view returns (uint256) {
        return abi.decode(_getValue(), (uint256));
    }

    /**
     * @notice Returns the decoded relayed rate value multiplied by the configured scaling factor.
     * @return Scaled rate stored under the configured relay key.
     */
    function getRateScaled() external view returns (uint256) {
        return abi.decode(_getValue(), (uint256)) * _getRateAdapterStorage().scalingFactor;
    }

    /**
     * @notice Returns the relay key used by this adapter.
     * @return Relay key read from the state store.
     */
    function rateKey() external view returns (bytes32) {
        return stateKey();
    }

    /**
     * @notice Returns the configured scaling factor used by `getRateScaled()`.
     * @return Scalar applied to the decoded rate value.
     */
    function scalingFactor() external view returns (uint256) {
        return _getRateAdapterStorage().scalingFactor;
    }

    function _getRateAdapterStorage() internal pure returns (RateAdapterStorage storage $) {
        assembly {
            $.slot := 0xbc9d4070b70d4be3f4a4b56ec642fef61fb1ccf1a6575d3fc7ee8e1c9ef0abdb
        }
    }
}
