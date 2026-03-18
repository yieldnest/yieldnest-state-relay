// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OAppUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/libs/OptionsBuilder.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KeyDerivation} from "./KeyDerivation.sol";

/**
 * @title StateSender
 * @notice Source-chain upgradeable OApp: reads state via staticcall, sends via _lzSend.
 * @dev Stub: key derivation and send logic to be implemented.
 */
contract StateSender is OAppUpgradeable {
    address public target;
    address public immutable refundAddress;
    bytes public immutable callData;
    uint8 public immutable version;
    address public immutable lzToken;

    event StateSent(bytes32 key, uint32 dstEid, bool payInLzToken, bytes message);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {
        _disableInitializers();
    }

    /**
     * @notice Initialize the OApp and ownership.
     * @param _owner Delegate and owner (capable of configuring peers, etc.)
     * @param _target The target contract to send the state to
     * @param _callData The function signature and data to make the staticcall state retrieval from the target contract
     * @param _version The version of the state relay
     */
    function initialize(
        address _owner,
        address _target,
        address _refundAddress,
        address _lzToken,
        bytes memory _callData,
        uint8 _version
    ) external reinitializer(1) {
        __Ownable_init(_owner);
        __OApp_init(_owner);
        target = _target;
        refundAddress = _refundAddress;
        lzToken = _lzToken;
        callData = _callData;
        version = _version;
    }

    function sendState(uint32 _dstEid, bool _payInLzToken) external payable {
        // get state data
        bytes memory stateData = _getStaticCallData();
        // derive key
        bytes32 key = KeyDerivation.deriveKey(block.chainid, target, callData);
        // encode data
        bytes memory message = _createMessage(key, stateData);
        // set options (80000 gas limit for simple storage on destination chain)
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(80000, 0);
        // get quote
        MessagingFee memory fee = _quote(_dstEid, message, "", _payInLzToken);

        if (_payInLzToken) {
            uint256 balance = lzToken.balanceOf(address(this));

            if (balance < fee.lzTokenFee) {
                // transfer balance difference from sender to this contract
                uint256 balanceDifference = fee.lzTokenFee - balance;
                SafeERC20.transferFrom(lzToken, msg.sender, address(this), balanceDifference);
            }

            SafeERC20.approve(lzToken, address(endpoint), fee.lzTokenFee);
            _lzSend(_dstEid, message, options, fee, refundAddress);
            
        } else {
            require(msg.value >= fee.nativeFee, "StateSender: insufficient native fee");
            _lzSend{value: fee.nativeFee}(_dstEid, message, options, fee, refundAddress);
        }

        emit StateSent(key, _dstEid, _payInLzToken, message);
    }

    function _getStaticCallData() internal view returns (bytes memory) {
        (bool success, bytes memory data) = target.staticcall(_callData);

        require(success, "StateSender: staticcall failed");

        return data;
    }

    function _createMessage(bytes32 key, bytes memory stateData) internal view returns (bytes memory) {
        return abi.encode(block.chainid, key, stateData, block.timestamp);
    }

    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) internal virtual override {
        // Send-only OApp: no receive logic.
    }
}
