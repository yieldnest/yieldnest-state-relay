// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {StateStore} from "src/StateStore.sol";

contract TestCCIPReceiverTransport is CCIPReceiver, Ownable {
    StateStore public immutable stateStore;

    uint64 public trustedSourceChainSelector;
    address public trustedSender;

    event TrustedSourceSet(uint64 indexed chainSelector, address indexed sender);
    event MessageReceived(uint256 version, bytes32 key, bytes value, uint64 srcTimestamp);
    event StaleMessageIgnored(uint256 version, bytes32 key, uint64 srcTimestamp);

    error TestCCIPReceiverTransport_InvalidStateStore();
    error TestCCIPReceiverTransport_InvalidSource(uint64 chainSelector, address sender);

    constructor(address router_, address owner_, address stateStore_) CCIPReceiver(router_) Ownable(owner_) {
        if (stateStore_ == address(0)) revert TestCCIPReceiverTransport_InvalidStateStore();
        stateStore = StateStore(stateStore_);
    }

    function setTrustedSource(uint64 sourceChainSelector, address sender) external onlyOwner {
        trustedSourceChainSelector = sourceChainSelector;
        trustedSender = sender;
        emit TrustedSourceSet(sourceChainSelector, sender);
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = _decodeSender(message.sender);
        if (message.sourceChainSelector != trustedSourceChainSelector || sender != trustedSender) {
            revert TestCCIPReceiverTransport_InvalidSource(message.sourceChainSelector, sender);
        }

        StateStore.WriteResult memory result = stateStore.write(message.data);
        if (result.written) {
            emit MessageReceived(result.version, result.key, result.value, result.srcTimestamp);
        } else {
            emit StaleMessageIgnored(result.version, result.key, result.srcTimestamp);
        }
    }

    function _decodeSender(bytes memory encodedSender) internal pure returns (address sender) {
        if (encodedSender.length == 20) {
            return address(bytes20(encodedSender));
        }

        if (encodedSender.length == 32) {
            return address(uint160(uint256(bytes32(encodedSender))));
        }

        assembly {
            sender := shr(96, mload(add(encodedSender, 32)))
        }
    }
}
