// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

contract TestCCIPStateSource {
    struct AssetParams {
        uint256 index;
        bool active;
        uint8 decimals;
    }

    uint256 internal s_convertToAssetsRate;

    mapping(address asset => AssetParams params) internal s_assets;

    function setConvertToAssetsRate(uint256 rate) external {
        s_convertToAssetsRate = rate;
    }

    function setAsset(address asset, AssetParams calldata params) external {
        s_assets[asset] = params;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * s_convertToAssetsRate / 1e18;
    }

    function getAsset(address asset) external view returns (AssetParams memory) {
        return s_assets[asset];
    }
}
