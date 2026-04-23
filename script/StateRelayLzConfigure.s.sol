/* solhint-disable no-console, gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";

import {StateRelayBase} from "./StateRelayBase.s.sol";
import {StateSender} from "../src/StateSender.sol";
import {LayerZeroSenderTransport} from "../src/layerzero/LayerZeroSenderTransport.sol";

import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {ExecutorConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";

interface ILZEndpointDelegates {
    function delegates(address) external view returns (address);
}

/// @notice LayerZero endpoint wiring for relay transports / StateReceiver (peers, libs, DVN, executor, delegate).
/// @dev Each sender has a transport contract that is the actual LayerZero OApp peer for the receiver.
abstract contract StateRelayLzConfigure is StateRelayBase {
    uint32 internal constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 internal constant CONFIG_TYPE_ULN = 2;
    uint32 internal constant DEFAULT_MAX_MESSAGE_SIZE = 10000;

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function _senderTransport(address senderAddr) internal view returns (address) {
        return address(StateSender(senderAddr).transport());
    }

    function _requireAtMostOneSenderPerSourceChain() internal view {
        for (uint256 i; i < senderLabels.length; i++) {
            uint256 a = senderByLabel[senderLabels[i]].chainId;
            if (a == receiverChainId) continue;
            for (uint256 j = i + 1; j < senderLabels.length; j++) {
                uint256 b = senderByLabel[senderLabels[j]].chainId;
                if (b == receiverChainId) continue;
                require(a != b, "StateRelay: multiple senders same src chain (one LZ peer per EID on receiver)");
            }
        }
    }

    /// @return remoteChainIds source chains that have a StateSender (excluding co-located receiver+sender same chain).
    /// @return peerForRemote OApp address on each source chain, bytes32-encoded.
    function _receiverRemotePeers()
        internal
        view
        returns (uint256[] memory remoteChainIds, bytes32[] memory peerForRemote)
    {
        _requireAtMostOneSenderPerSourceChain();
        uint256 n;
        for (uint256 i; i < senderLabels.length; i++) {
            if (senderByLabel[senderLabels[i]].chainId != receiverChainId) {
                n++;
            }
        }
        remoteChainIds = new uint256[](n);
        peerForRemote = new bytes32[](n);
        uint256 k;
        for (uint256 i; i < senderLabels.length; i++) {
            string memory label = senderLabels[i];
            uint256 srcChain = senderByLabel[label].chainId;
            if (srcChain == receiverChainId) continue;
            address snd = stateSenderOf[senderSlot(srcChain, label)];
            require(snd != address(0), "StateRelay: configure receiver: sender not deployed");
            remoteChainIds[k] = srcChain;
            peerForRemote[k] = addressToBytes32(_senderTransport(snd));
            k++;
        }
    }

    function _dstChainIdsForSender() internal view returns (uint256[] memory) {
        uint256[] memory dst = new uint256[](1);
        dst[0] = receiverChainId;
        return dst;
    }

    /// @dev Step 3 — LayerZero wiring for **StateSender(s)** on this chain (needs `StateReceiver` in deployment JSON).
    function configureSenders() internal {
        uint256 cid = block.chainid;
        require(isSupportedChainId(cid), "StateRelay: rpc chain not in BaseData");

        address recv = stateReceiverOf[receiverChainId];
        require(
            recv != address(0),
            "StateRelay: StateReceiver missing in deployment JSON; run step 2 on receiver RPC with --broadcast, then retry"
        );

        uint256[] memory dstOnlyReceiver = _dstChainIdsForSender();
        bytes32 recvB32 = addressToBytes32(recv);

        for (uint256 i; i < senderLabels.length; i++) {
            string memory label = senderLabels[i];
            if (senderByLabel[label].chainId != cid) continue;

            address senderAddr = stateSenderOf[senderSlot(cid, label)];
            if (senderAddr == address(0)) continue;

            address transportAddr = _senderTransport(senderAddr);
            LayerZeroSenderTransport transport = LayerZeroSenderTransport(transportAddr);
            _configurePeersSenderToReceiver(transport, dstOnlyReceiver, recvB32);
            _configureSendLibs(transportAddr, dstOnlyReceiver);
            _configureReceiveLibs(transportAddr, dstOnlyReceiver);
            _configureDVNs(transportAddr, dstOnlyReceiver);
            _configureExecutor(transportAddr, dstOnlyReceiver);
            _configureDelegate(transportAddr);
        }
    }

    /// @dev Step 4 — LayerZero wiring for **StateReceiver** on `receiverChainId` RPC only (needs senders in deployment JSON).
    function configureReceiver() internal {
        uint256 cid = block.chainid;
        require(isSupportedChainId(cid), "StateRelay: rpc chain not in BaseData");
        require(cid == receiverChainId, "StateRelay: receiver configure only on receiver chain RPC");

        address recv = stateReceiverOf[receiverChainId];
        if (recv == address(0)) {
            console.log("Step 4 needs StateReceiver address under .chains.<receiverChainId>.stateReceiver");
            console.log("receiverChainId from input:", receiverChainId);
            console.log("deployment file:", deploymentFilePath());
            revert(
                "StateRelay: run 2_DeployStateRelayDestination on THIS chain's RPC (receiverChainId) with --broadcast; then retry"
            );
        }

        (uint256[] memory remoteChains, bytes32[] memory remotePeers) = _receiverRemotePeers();
        _configurePeersReceiver(IOAppCore(recv), remoteChains, remotePeers);
        _configureSendLibs(recv, remoteChains);
        _configureReceiveLibs(recv, remoteChains);
        _configureDVNs(recv, remoteChains);
        _configureExecutor(recv, remoteChains);
        _configureDelegate(recv);
    }

    function _configurePeersReceiver(IOAppCore oapp, uint256[] memory remoteChainIds, bytes32[] memory peers)
        internal
    {
        require(remoteChainIds.length == peers.length, "StateRelay: peer array length");
        console.log("Configuring StateReceiver peers...");
        for (uint256 i; i < remoteChainIds.length; i++) {
            uint256 remoteCid = remoteChainIds[i];
            uint32 srcEid = getEID(remoteCid);
            if (oapp.peers(srcEid) == peers[i]) {
                console.log("Receiver peer already set chainId", remoteCid);
                continue;
            }
            _startBroadcast();
            oapp.setPeer(srcEid, peers[i]);
            vm.stopBroadcast();
            console.log("Receiver set peer chainId", remoteCid);
        }
    }

    function _configurePeersSenderToReceiver(
        LayerZeroSenderTransport transport,
        uint256[] memory dstChainIds,
        bytes32 receiverPeer
    ) internal {
        console.log("Configuring StateSender peer -> receiver...");
        for (uint256 i; i < dstChainIds.length; i++) {
            uint256 destinationId = dstChainIds[i];
            uint32 dstEid = getEID(destinationId);
            (uint32 configuredEid, bytes32 configuredPeer, bytes memory options, bool enabled) =
                transport.destinations(destinationId);
            if (transport.peers(dstEid) == receiverPeer && configuredPeer == receiverPeer) {
                console.log("Sender peer already set dst chainId", dstChainIds[i]);
                continue;
            }
            _startBroadcast();
            transport.setDestination(destinationId, configuredEid, receiverPeer, options, enabled);
            vm.stopBroadcast();
            console.log("Sender set peer dst chainId", dstChainIds[i]);
        }
    }

    function _configureSendLibs(address oapp, uint256[] memory otherChainIds) internal {
        console.log("Configuring send libraries...");
        ILayerZeroEndpointV2 lzEndpoint = ILayerZeroEndpointV2(getData(block.chainid).LZ_ENDPOINT);
        for (uint256 i; i < otherChainIds.length; i++) {
            uint256 chainId = otherChainIds[i];
            uint32 eid = getEID(chainId);
            if (lzEndpoint.getSendLibrary(oapp, eid) == getData(block.chainid).LZ_SEND_LIB) {
                console.log("Send lib already set chainId", chainId);
                continue;
            }
            _startBroadcast();
            lzEndpoint.setSendLibrary(oapp, eid, getData(block.chainid).LZ_SEND_LIB);
            vm.stopBroadcast();
            console.log("Set send library chainId", chainId);
        }
    }

    function _configureReceiveLibs(address oapp, uint256[] memory otherChainIds) internal {
        console.log("Configuring receive libraries...");
        ILayerZeroEndpointV2 lzEndpoint = ILayerZeroEndpointV2(getData(block.chainid).LZ_ENDPOINT);
        for (uint256 i; i < otherChainIds.length; i++) {
            uint256 chainId = otherChainIds[i];
            uint32 eid = getEID(chainId);
            (address lib, bool isDefault) = lzEndpoint.getReceiveLibrary(oapp, eid);
            if (lib == getData(block.chainid).LZ_RECEIVE_LIB && isDefault == false) {
                console.log("Receive lib already set chainId", chainId);
                continue;
            }
            _startBroadcast();
            lzEndpoint.setReceiveLibrary(oapp, eid, getData(block.chainid).LZ_RECEIVE_LIB, 0);
            vm.stopBroadcast();
            console.log("Set receive library chainId", chainId);
        }
    }

    function _getUlnConfig() internal view returns (UlnConfig memory _ulnConfig) {
        Data storage data = getData(block.chainid);
        bool isTestnet = isTestnetChainId(block.chainid);

        address[] memory requiredDVNs = new address[](isTestnet ? 1 : 2);
        uint64 confirmations = isTestnet ? 8 : 32;
        uint8 requiredDVNCount = isTestnet ? 1 : 2;

        if (isTestnet) {
            requiredDVNs[0] = data.LZ_DVN;
        } else {
            if (data.LZ_DVN > data.NETHERMIND_DVN) {
                requiredDVNs[0] = data.NETHERMIND_DVN;
                requiredDVNs[1] = data.LZ_DVN;
            } else {
                requiredDVNs[0] = data.LZ_DVN;
                requiredDVNs[1] = data.NETHERMIND_DVN;
            }
        }

        _ulnConfig = UlnConfig({
            confirmations: confirmations,
            requiredDVNCount: requiredDVNCount,
            optionalDVNCount: 0,
            optionalDVNThreshold: 0,
            requiredDVNs: requiredDVNs,
            optionalDVNs: new address[](0)
        });
    }

    function _configureDVNs(address oapp, uint256[] memory otherChainIds) internal {
        console.log("Configuring DVNs...");
        Data storage data = getData(block.chainid);
        ILayerZeroEndpointV2 lzEndpoint = ILayerZeroEndpointV2(data.LZ_ENDPOINT);

        for (uint256 i; i < otherChainIds.length; i++) {
            uint256 chainId = otherChainIds[i];
            uint32 dstEid = getEID(chainId);
            UlnConfig memory ulnConfig = _getUlnConfig();

            if (
                keccak256(lzEndpoint.getConfig(oapp, data.LZ_RECEIVE_LIB, dstEid, CONFIG_TYPE_ULN))
                    == keccak256(abi.encode(ulnConfig))
                    && keccak256(lzEndpoint.getConfig(oapp, data.LZ_SEND_LIB, dstEid, CONFIG_TYPE_ULN))
                        == keccak256(abi.encode(ulnConfig))
            ) {
                console.log("DVNs already set chainId", chainId);
                continue;
            }

            SetConfigParam[] memory params = new SetConfigParam[](1);
            params[0] = SetConfigParam(dstEid, CONFIG_TYPE_ULN, abi.encode(ulnConfig));

            _startBroadcast();
            lzEndpoint.setConfig(oapp, data.LZ_SEND_LIB, params);
            lzEndpoint.setConfig(oapp, data.LZ_RECEIVE_LIB, params);
            vm.stopBroadcast();
            console.log("Set DVNs chainId", chainId);
        }
    }

    function _configureExecutor(address oapp, uint256[] memory otherChainIds) internal {
        console.log("Configuring executor...");
        Data storage data = getData(block.chainid);
        ILayerZeroEndpointV2 lzEndpoint = ILayerZeroEndpointV2(data.LZ_ENDPOINT);

        for (uint256 i; i < otherChainIds.length; i++) {
            uint256 chainId = otherChainIds[i];
            uint32 dstEid = getEID(chainId);
            ExecutorConfig memory executorConfig =
                ExecutorConfig({maxMessageSize: DEFAULT_MAX_MESSAGE_SIZE, executor: data.LZ_EXECUTOR});

            if (
                keccak256(lzEndpoint.getConfig(oapp, data.LZ_SEND_LIB, dstEid, CONFIG_TYPE_EXECUTOR))
                    == keccak256(abi.encode(executorConfig))
            ) {
                console.log("Executor already set chainId", chainId);
                continue;
            }

            SetConfigParam[] memory params = new SetConfigParam[](1);
            params[0] = SetConfigParam(dstEid, CONFIG_TYPE_EXECUTOR, abi.encode(executorConfig));

            _startBroadcast();
            lzEndpoint.setConfig(oapp, data.LZ_SEND_LIB, params);
            vm.stopBroadcast();
            console.log("Set executor chainId", chainId);
        }
    }

    function _configureDelegate(address oapp) internal {
        Data storage data = getData(block.chainid);
        ILZEndpointDelegates ep = ILZEndpointDelegates(data.LZ_ENDPOINT);
        address targetDelegate = data.OFT_OWNER;
        if (ep.delegates(oapp) != targetDelegate) {
            _startBroadcast();
            IOAppCore(oapp).setDelegate(targetDelegate);
            vm.stopBroadcast();
            console.log("Set OApp delegate to OFT_OWNER");
        }
    }
}
