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
        uint256 minLowerBound;
        uint256 maxUpperBound;
    }

    event BoundsSet(
        uint256 previousMinLowerBound, uint256 previousMaxUpperBound, uint256 newMinLowerBound, uint256 newMaxUpperBound
    );

    error RateAdapterUpgradeable_RateOutOfBounds(uint256 rate, uint256 minLowerBound, uint256 maxUpperBound);

    /**
     * @notice Initializes the adapter to read a specific relayed rate key with freshness bounds.
     * @param _admin Address granted the default admin and reader manager roles.
     * @param _stateStore State store contract providing relayed values.
     * @param _rateKey Relay key for the rate entry.
     * @param _maxSrcStaleness Maximum allowed age of the source timestamp.
     * @param _maxDstStaleness Maximum allowed age since delivery to the destination chain.
     * @param _maxSourceTimestampSkew Maximum allowed future skew for the source timestamp.
     * @param _scalingFactor Scalar used by `getRateScaled()`.
     * @param _minLowerBound Minimum allowed decoded rate value.
     * @param _maxUpperBound Maximum allowed decoded rate value.
     */
    function initialize(
        address _admin,
        address _stateStore,
        bytes32 _rateKey,
        uint256 _maxSrcStaleness,
        uint256 _maxDstStaleness,
        uint256 _maxSourceTimestampSkew,
        uint256 _scalingFactor,
        uint256 _minLowerBound,
        uint256 _maxUpperBound
    ) external initializer {
        __StateReaderBase_init(
            _admin, _stateStore, _rateKey, _maxSrcStaleness, _maxDstStaleness, _maxSourceTimestampSkew
        );
        RateAdapterStorage storage $ = _getRateAdapterStorage();
        $.scalingFactor = _scalingFactor;
        $.minLowerBound = _minLowerBound;
        $.maxUpperBound = _maxUpperBound;
    }

    /**
     * @notice Returns the decoded relayed rate value.
     * @return Current rate stored under the configured relay key.
     */
    function getRate() external view returns (uint256) {
        return _getBoundedRate();
    }

    /**
     * @notice Returns the decoded relayed rate value multiplied by the configured scaling factor.
     * @return Scaled rate stored under the configured relay key.
     */
    function getRateScaled() external view returns (uint256) {
        RateAdapterStorage storage $ = _getRateAdapterStorage();
        return _getBoundedRate() * $.scalingFactor;
    }

    /**
     * @notice Updates both rate bounds in a single call.
     * @param _minLowerBound Minimum allowed decoded rate value.
     * @param _maxUpperBound Maximum allowed decoded rate value.
     */
    function setBounds(uint256 _minLowerBound, uint256 _maxUpperBound) external onlyRole(CONFIG_MANAGER_ROLE) {
        RateAdapterStorage storage $ = _getRateAdapterStorage();
        emit BoundsSet($.minLowerBound, $.maxUpperBound, _minLowerBound, _maxUpperBound);
        $.minLowerBound = _minLowerBound;
        $.maxUpperBound = _maxUpperBound;
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

    /**
     * @notice Returns the configured minimum allowed decoded rate value.
     * @return Minimum allowed decoded rate value.
     */
    function minLowerBound() external view returns (uint256) {
        return _getRateAdapterStorage().minLowerBound;
    }

    /**
     * @notice Returns the configured maximum allowed decoded rate value.
     * @return Maximum allowed decoded rate value.
     */
    function maxUpperBound() external view returns (uint256) {
        return _getRateAdapterStorage().maxUpperBound;
    }

    function _getBoundedRate() internal view returns (uint256 rate) {
        RateAdapterStorage storage $ = _getRateAdapterStorage();
        rate = abi.decode(_getValue(), (uint256));
        if (rate < $.minLowerBound || rate > $.maxUpperBound) {
            revert RateAdapterUpgradeable_RateOutOfBounds(rate, $.minLowerBound, $.maxUpperBound);
        }
    }

    function _getRateAdapterStorage() internal pure returns (RateAdapterStorage storage $) {
        assembly {
            $.slot := 0xbc9d4070b70d4be3f4a4b56ec642fef61fb1ccf1a6575d3fc7ee8e1c9ef0abdb
        }
    }
}
