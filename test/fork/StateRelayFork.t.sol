// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StateSender} from "src/StateSender.sol";
import {LayerZeroStateRelayTransport} from "src/layerzero/LayerZeroStateRelayTransport.sol";
import {StateReceiver} from "src/StateReceiver.sol";
import {KeyDerivation} from "src/KeyDerivation.sol";
import {MessageSink} from "test/mocks/MessageSink.sol";
import {StateReceiverHarness} from "test/mocks/StateReceiverHarness.sol";
import {StateStore} from "src/StateStore.sol";
import {RateAdapter} from "src/adapter/RateAdapter.sol";
import {StateReaderBase} from "src/StateReaderBase.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/TestHelperOz5.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

/// @dev Canonical ynETHx on Ethereum L1 + shared calldata for `convertToAssets(1e18)`.
abstract contract StateRelayForkConstants {
    address internal constant YNETHX_MAINNET = 0x657d9ABA1DBb59e53f9F3eCAA878447dCfC96dCb;

    uint256 internal constant ONE_SHARE = 1e18;
    bytes internal constant CONVERT_TO_ASSETS_CALLDATA = abi.encodeCall(IERC4626.convertToAssets, (ONE_SHARE));
}

/**
 * @notice Fork real chain state for staticcalls; delivery uses TestHelperOz5 (`verifyPackets`) in-process — not two live chains talking.
 * @dev Mainnet-only sender + MessageSink. Run: `forge test --match-contract StateRelayFork --rpc-url <MAINNET_RPC>`.
 * @dev RPC: pass a reliable mainnet URL via `--rpc-url`; set `ARBITRUM_RPC` in `.env` for the multi-fork test.
 *      Public RPCs often cause `failed to get storage` / `upstream connect error` / invalid JSON during storage reads.
 */
abstract contract StateRelayForkTestBase is Test, TestHelperOz5, StateRelayForkConstants {
    uint32 internal constant SRC_EID = 1;
    uint32 internal constant DST_EID = 2;
    uint256 internal constant DST_CHAIN_ID = 42161;

    StateSender internal stateSender;
    LayerZeroStateRelayTransport internal transport;
    MessageSink internal messageSink;

    /// @dev ynETHx vault on the forked chain (mainnet only in this base).
    address internal ynEthx;

    function _initAfterFork(address ynEthx_) internal {
        ynEthx = ynEthx_;

        TestHelperOz5.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        LayerZeroStateRelayTransport transportImpl = new LayerZeroStateRelayTransport(address(endpoints[SRC_EID]));
        bytes memory transportInitData = abi.encodeCall(LayerZeroStateRelayTransport.initialize, (address(this)));
        ERC1967Proxy transportProxy = new ERC1967Proxy(address(transportImpl), transportInitData);
        transport = LayerZeroStateRelayTransport(address(transportProxy));

        StateSender impl = new StateSender();
        bytes memory initData = abi.encodeCall(
            StateSender.initialize, (address(this), address(transport), ynEthx_, CONVERT_TO_ASSETS_CALLDATA, 1)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        stateSender = StateSender(address(proxy));

        address sinkAddr =
            _deployOApp(type(MessageSink).creationCode, abi.encode(address(endpoints[DST_EID]), address(this)));
        messageSink = MessageSink(sinkAddr);

        wireOApps(toAddressArray(address(transportProxy), sinkAddr));
        transport.setDestination(
            DST_CHAIN_ID,
            DST_EID,
            addressToBytes32(address(messageSink)),
            OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 300_000, 0),
            true
        );
    }

    function toAddressArray(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _assertYnEthxConvertToAssetsRelayed() internal {
        (bool ok, bytes memory ret) = ynEthx.staticcall(CONVERT_TO_ASSETS_CALLDATA);
        require(ok, "fork: convertToAssets staticcall failed");
        uint256 expectedAssets = abi.decode(ret, (uint256));

        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(DST_CHAIN_ID);
        assertTrue(quoteData.transportQuote.feeAmount > 0, "expected non-zero native fee");

        stateSender.sendState{value: quoteData.transportQuote.feeAmount}(DST_CHAIN_ID);
        verifyPackets(DST_EID, addressToBytes32(address(messageSink)));

        assertEq(messageSink.lastMessage().length, 192, "message size");
        (uint8 msgVersion, bytes32 key, bytes memory stateData, uint64 ts) =
            abi.decode(messageSink.lastMessage(), (uint8, bytes32, bytes, uint64));

        assertEq(msgVersion, 1, "relay version");
        assertEq(ts, block.timestamp);
        assertEq(stateData.length, 32);
        assertEq(abi.decode(stateData, (uint256)), expectedAssets);

        bytes32 expectedKey = KeyDerivation.deriveKey(block.chainid, ynEthx, CONVERT_TO_ASSETS_CALLDATA);
        assertEq(quoteData.key, expectedKey);
        assertEq(quoteData.message, messageSink.lastMessage());
        assertEq(key, expectedKey);
    }

    function _assertInsufficientNativeFeeReverts() internal {
        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(DST_CHAIN_ID);
        vm.expectRevert(StateSender.StateSender_InsufficientNativeFee.selector);
        stateSender.sendState{value: quoteData.transportQuote.feeAmount - 1}(DST_CHAIN_ID);
    }
}

/// @dev ynETHx on Ethereum mainnet (YieldNest app / docs).
contract StateRelayForkMainnetTest is StateRelayForkTestBase {
    function setUp() public override {
        _initAfterFork(YNETHX_MAINNET);
    }

    function test_fork_mainnet_sendState_relayedViaLzHelper_ynEthxConvertToAssets() public {
        _assertYnEthxConvertToAssetsRelayed();
    }

    function test_fork_mainnet_sendState_insufficientNativeFee_reverts() public {
        _assertInsufficientNativeFeeReverts();
    }
}

/**
 * @notice Reads `convertToAssets(1e18)` from **mainnet** ynETHx, then applies it on an **Arbitrum** fork via
 *         StateStore + StateReceiver (harness simulates LZ payload). Models production: L1 rate → L2 store.
 * @dev Wire format to the receiver is `abi.encode(uint8 version, bytes32 key, bytes value, uint64 srcTimestamp)`.
 */
contract StateRelayForkMainnetToArbitrumTest is Test, TestHelperOz5, StateRelayForkConstants {
    uint32 internal constant ARB_EID = 1;

    uint256 internal forkMainnet;
    uint256 internal forkArb;

    /// @dev Much shorter than `365 days` but wide enough for typical mainnet vs Arbitrum fork `block.timestamp` skew.
    uint256 internal constant STALENESS = 1 hours;

    function setUp() public override {
        forkMainnet = vm.activeFork();
        forkArb = vm.createFork(vm.envString("ARBITRUM_RPC"));
    }

    /// @return stateStore Receiver-side store after delivery; `key`; decoded uint256 rate; Arb `block.timestamp` right after write.
    function _readMainnetAndDeliverToArbitrum()
        internal
        returns (StateStore stateStore, bytes32 key, uint256 expectedRate, uint256 deliveredAt)
    {
        vm.selectFork(forkMainnet);

        (bool ok, bytes memory stateData) = YNETHX_MAINNET.staticcall(CONVERT_TO_ASSETS_CALLDATA);
        require(ok, "mainnet: convertToAssets failed");

        expectedRate = abi.decode(stateData, (uint256));
        uint64 srcTs = uint64(block.timestamp);
        key = KeyDerivation.deriveKey(1, YNETHX_MAINNET, CONVERT_TO_ASSETS_CALLDATA);

        vm.selectFork(forkArb);

        TestHelperOz5.setUp();
        setUpEndpoints(1, LibraryType.UltraLightNode);

        StateReceiverHarness receiver;
        {
            StateStore storeImpl = new StateStore();
            bytes memory storeInit = abi.encodeCall(StateStore.initialize, (address(this), new address[](0)));
            ERC1967Proxy storeProxy = new ERC1967Proxy(address(storeImpl), storeInit);
            stateStore = StateStore(address(storeProxy));

            StateReceiverHarness recvImpl = new StateReceiverHarness(address(endpoints[ARB_EID]));
            bytes memory recvInit = abi.encodeCall(StateReceiver.initialize, (address(this), address(stateStore)));
            ERC1967Proxy recvProxy = new ERC1967Proxy(address(recvImpl), recvInit);
            receiver = StateReceiverHarness(address(recvProxy));
        }

        stateStore.grantRole(stateStore.WRITER_ROLE(), address(receiver));

        bytes memory message = abi.encode(uint8(1), key, stateData, srcTs);
        receiver.receivePayload(message);

        deliveredAt = block.timestamp;

        bytes memory stored = stateStore.get(key).value;
        assertEq(stored, stateData);
        assertEq(abi.decode(stored, (uint256)), expectedRate);
    }

    function test_fork_mainnet_convertToAssets_writtenOnArbitrumStateStore() public {
        (StateStore stateStore, bytes32 key, uint256 expectedRate,) = _readMainnetAndDeliverToArbitrum();

        RateAdapter adapter = new RateAdapter(address(stateStore), key, STALENESS, STALENESS);
        assertEq(adapter.getRate(), expectedRate);
    }

    /// @dev Proves `StateReaderBase` accepts fresh delivery under a short `maxSrc` / `maxDst` window.
    function test_fork_mainnetToArbitrum_rateAdapter_passesShortStaleness() public {
        (StateStore stateStore, bytes32 key, uint256 expectedRate,) = _readMainnetAndDeliverToArbitrum();

        RateAdapter adapter = new RateAdapter(address(stateStore), key, STALENESS, STALENESS);
        assertEq(adapter.maxSrcStaleness(), STALENESS);
        assertEq(adapter.maxDstStaleness(), STALENESS);
        assertEq(adapter.getRate(), expectedRate);

        // Still within both windows after a modest warp (delivery age < STALENESS).
        vm.warp(block.timestamp + 30 minutes);
        assertEq(adapter.getRate(), expectedRate);
    }

    /// @dev Past `maxDstStaleness` from store `updatedAt`, read must revert.
    function test_fork_mainnetToArbitrum_rateAdapter_revertsWhenDeliveryStale() public {
        (StateStore stateStore, bytes32 key,, uint256 deliveredAt) = _readMainnetAndDeliverToArbitrum();

        // Keep source window wider so this test isolates delivery-stale behavior.
        RateAdapter adapter = new RateAdapter(address(stateStore), key, STALENESS + 1 hours, STALENESS);

        vm.warp(deliveredAt + STALENESS + 1);
        vm.expectRevert(StateReaderBase.StateReaderBase_DeliveryStale.selector);
        adapter.getRate();
    }
}
