// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OAppUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KeyDerivation} from "./KeyDerivation.sol";
import {IStateSenderBase} from "./interfaces/IStateSenderBase.sol";

/**
 * @title StateSenderBase
 * @notice Abstract upgradeable OApp: staticcall + LayerZero send. `StateSenderStatic` stores target/calldata; `StateSenderDynamic` passes them per call.
 */
abstract contract StateSenderBase is OAppUpgradeable, IStateSenderBase {
    address public refundAddress;
    IERC20 public lzToken;
    uint8 public version;
    /**
     * @dev Reserved storage space to allow for layout changes in future upgrades.
     */
    uint256[47] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {
        _disableInitializers();
    }

    function __StateSenderBase_init(
        address _owner,
        address _refundAddress,
        address _lzToken,
        uint8 _version
    ) internal onlyInitializing {
        __Ownable_init(_owner);
        __OApp_init(_owner);
        refundAddress = _refundAddress;
        lzToken = IERC20(_lzToken);
        version = _version;
    }

    function setRefundAddress(address _refundAddress) external onlyOwner {
        refundAddress = _refundAddress;
        emit RefundAddressSet(_refundAddress);
    }

    function setLzToken(address _lzToken) external onlyOwner {
        lzToken = IERC20(_lzToken);
        emit LzTokenSet(_lzToken);
    }

    function setVersion(uint8 _version) external onlyOwner {
        version = _version;
        emit VersionSet(_version);
    }

    function _getDefaultOptions() internal pure returns (bytes memory) {
        return OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 300_000, 0);
    }

    function _staticCallState(address target_, bytes memory callData_) internal view returns (bytes memory) {
        require(target_ != address(0), "StateSender: target required");
        (bool success, bytes memory data) = target_.staticcall(callData_);
        require(success, "StateSender: staticcall failed");
        return data;
    }

    function _createMessage(bytes32 key, bytes memory stateData) internal view returns (bytes memory) {
        return abi.encode(block.chainid, key, stateData, block.timestamp);
    }

    function _quoteSendState(uint32 dstEid_, bool payInLzToken_, address target_, bytes memory callData_)
        internal
        view
        virtual
        returns (MessagingFee memory fee)
    {
        bytes memory stateData = _staticCallState(target_, callData_);
        bytes32 key = KeyDerivation.deriveKey(block.chainid, target_, callData_);
        bytes memory message = _createMessage(key, stateData);
        return _quote(dstEid_, message, _getDefaultOptions(), payInLzToken_);
    }

    function _sendState(uint32 dstEid_, bool payInLzToken_, address target_, bytes memory callData_) internal virtual {
        bytes memory stateData = _staticCallState(target_, callData_);
        bytes32 key = KeyDerivation.deriveKey(block.chainid, target_, callData_);
        bytes memory message = _createMessage(key, stateData);
        bytes memory options = _getDefaultOptions();
        MessagingFee memory fee = _quote(dstEid_, message, options, payInLzToken_);

        if (payInLzToken_) {
            uint256 balance = lzToken.balanceOf(address(this));
            if (balance < fee.lzTokenFee) {
                uint256 balanceDifference = fee.lzTokenFee - balance;
                SafeERC20.safeTransferFrom(lzToken, msg.sender, address(this), balanceDifference);
            }
            SafeERC20.forceApprove(lzToken, address(endpoint), fee.lzTokenFee);
            _lzSend(dstEid_, message, options, fee, refundAddress);
        } else {
            require(msg.value >= fee.nativeFee, "StateSender: insufficient native fee");
            _lzSend(dstEid_, message, options, fee, refundAddress);
        }

        emit StateSent(key, dstEid_, payInLzToken_, message);
    }

    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) internal virtual override {
        // Send-only OApp: no receive logic.
    }
}
