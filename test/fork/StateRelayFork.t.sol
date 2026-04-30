// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StateSender} from "src/StateSender.sol";
import {LayerZeroSenderTransport} from "src/layerzero/LayerZeroSenderTransport.sol";
import {LayerZeroReceiverTransport} from "src/layerzero/LayerZeroReceiverTransport.sol";
import {KeyDerivation} from "src/KeyDerivation.sol";
import {StateReceiverHarness} from "test/mocks/StateReceiverHarness.sol";
import {StateStore} from "src/StateStore.sol";
import {RateAdapterUpgradeable} from "src/adapter/RateAdapterUpgradeable.sol";
import {StateReaderBaseUpgradeable} from "src/StateReaderBaseUpgradeable.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/TestHelperOz5.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

interface IVault {

    struct AssetParams {
        uint256 index;
        bool active;
        uint8 decimals;
    }

    function getAsset(address asset_) external view returns (AssetParams memory);
}

/// @dev Canonical ynETHx on Ethereum L1 + shared calldata for `convertToAssets(1e18)`.
abstract contract StateRelayForkConstants {
    address internal constant YNETHX_MAINNET = 0x657d9ABA1DBb59e53f9F3eCAA878447dCfC96dCb;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 internal constant ONE_SHARE = 1e18;
    bytes internal constant CONVERT_TO_ASSETS_CALLDATA = abi.encodeCall(IERC4626.convertToAssets, (ONE_SHARE));
    bytes internal constant GET_WETH_ASSET_CALLDATA = abi.encodeCall(IVault.getAsset, (WETH));
}

abstract contract StateRelayForkAdapterHelpers is StateRelayForkConstants {
    uint256 internal constant MAX_SOURCE_TIMESTAMP_SKEW = 1 hours;

    function _deployRateAdapter(
        address stateStore_,
        bytes32 key,
        uint256 maxSrcStaleness,
        uint256 maxDstStaleness,
        uint256 maxSourceTimestampSkew
    )
        internal
        returns (RateAdapterUpgradeable)
    {
        RateAdapterUpgradeable adapterImpl = new RateAdapterUpgradeable();
        bytes memory adapterInit = abi.encodeCall(
            RateAdapterUpgradeable.initialize,
            (address(this), stateStore_, key, maxSrcStaleness, maxDstStaleness, maxSourceTimestampSkew)
        );
        ERC1967Proxy adapterProxy = new ERC1967Proxy(address(adapterImpl), adapterInit);
        return RateAdapterUpgradeable(address(adapterProxy));
    }
}

/**
 * @notice Fork real chain state for staticcalls; delivery uses TestHelperOz5 (`verifyPackets`) in-process — not two live chains talking.
 * @dev Mainnet-only sender + LayerZero receiver transport. Run: `forge test --match-contract StateRelayFork --rpc-url <MAINNET_RPC>`.
 * @dev RPC: pass a reliable mainnet URL via `--rpc-url`; set `ARBITRUM_RPC` in `.env` for the multi-fork test.
 *      Public RPCs often cause `failed to get storage` / `upstream connect error` / invalid JSON during storage reads.
 */
abstract contract StateRelayForkTestBase is Test, TestHelperOz5, StateRelayForkAdapterHelpers {
    uint32 internal constant SRC_EID = 1;
    uint32 internal constant DST_EID = 2;
    uint256 internal constant DST_CHAIN_ID = 42161;

    StateSender internal stateSender;
    LayerZeroSenderTransport internal transport;
    LayerZeroReceiverTransport internal receiverTransport;
    StateStore internal destinationStateStore;

    /// @dev ynETHx vault on the forked chain (mainnet only in this base).
    address internal ynEthx;

    function _initAfterFork(address ynEthx_) internal {
        ynEthx = ynEthx_;

        TestHelperOz5.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        LayerZeroSenderTransport transportImpl = new LayerZeroSenderTransport(address(endpoints[SRC_EID]));
        bytes memory transportInitData = abi.encodeCall(LayerZeroSenderTransport.initialize, (address(this)));
        ERC1967Proxy transportProxy = new ERC1967Proxy(address(transportImpl), transportInitData);
        transport = LayerZeroSenderTransport(address(transportProxy));

        StateSender impl = new StateSender();
        bytes memory initData = abi.encodeCall(
            StateSender.initialize, (address(this), address(transport), ynEthx_, CONVERT_TO_ASSETS_CALLDATA, 1)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        stateSender = StateSender(address(proxy));
        transport.grantRole(transport.SENDER_ROLE(), address(stateSender));

        StateStore storeImpl = new StateStore();
        bytes memory storeInit = abi.encodeCall(StateStore.initialize, (address(this), new address[](0)));
        ERC1967Proxy storeProxy = new ERC1967Proxy(address(storeImpl), storeInit);
        destinationStateStore = StateStore(address(storeProxy));

        LayerZeroReceiverTransport receiverImpl = new LayerZeroReceiverTransport(address(endpoints[DST_EID]));
        bytes memory receiverInit =
            abi.encodeCall(LayerZeroReceiverTransport.initialize, (address(this), address(destinationStateStore)));
        ERC1967Proxy receiverProxy = new ERC1967Proxy(address(receiverImpl), receiverInit);
        receiverTransport = LayerZeroReceiverTransport(address(receiverProxy));
        destinationStateStore.grantRole(destinationStateStore.WRITER_ROLE(), address(receiverTransport));

        wireOApps(toAddressArray(address(transportProxy), address(receiverProxy)));
        LayerZeroSenderTransport.DestinationConfig[] memory destinationConfigs =
            new LayerZeroSenderTransport.DestinationConfig[](1);
        destinationConfigs[0] = LayerZeroSenderTransport.DestinationConfig({
            lzEid: DST_EID,
            peer: addressToBytes32(address(receiverTransport)),
            options: OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 300_000, 0),
            enabled: true
        });
        uint256[] memory destinationIds = new uint256[](1);
        destinationIds[0] = DST_CHAIN_ID;
        transport.setDestination(destinationConfigs, destinationIds);
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

        assertTrue(expectedAssets > 1e18, "expectedAssets should be above 1e18");
        assertTrue(expectedAssets < 2e18, "expectedAssets should be below 2e18");
   

        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(DST_CHAIN_ID);
        assertTrue(quoteData.transportQuote.feeAmount > 0, "expected non-zero native fee");

        stateSender.sendState{value: quoteData.transportQuote.feeAmount}(DST_CHAIN_ID);
        verifyPackets(DST_EID, addressToBytes32(address(receiverTransport)));

        bytes32 expectedKey = KeyDerivation.deriveKey(block.chainid, ynEthx, CONVERT_TO_ASSETS_CALLDATA);
        StateStore.Entry memory entry = destinationStateStore.get(expectedKey);

        assertEq(entry.version, 1, "relay version");
        assertEq(entry.srcTimestamp, block.timestamp);
        assertEq(entry.value.length, 32);
        assertEq(abi.decode(entry.value, (uint256)), expectedAssets);
        assertEq(quoteData.key, expectedKey);
        assertEq(entry.updatedAt, block.timestamp);
        assertEq(entry.updatedAtBlock, block.number);
    }

    function _assertYnEthxGetAssetRelayed() internal {
        (bool ok, bytes memory ret) = ynEthx.staticcall(GET_WETH_ASSET_CALLDATA);
        require(ok, "fork: convertToAssets staticcall failed");
        IVault.AssetParams memory expectedEntry = abi.decode(ret, (IVault.AssetParams));
   
        assertEq(expectedEntry.index, 0);
        assertTrue(expectedEntry.active);
        assertEq(expectedEntry.decimals, 18);

        stateSender.setCallData(GET_WETH_ASSET_CALLDATA);

        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(DST_CHAIN_ID);
        assertTrue(quoteData.transportQuote.feeAmount > 0, "expected non-zero native fee");

        stateSender.sendState{value: quoteData.transportQuote.feeAmount}(DST_CHAIN_ID);
        verifyPackets(DST_EID, addressToBytes32(address(receiverTransport)));

        bytes32 expectedKey = KeyDerivation.deriveKey(block.chainid, ynEthx, GET_WETH_ASSET_CALLDATA);
        StateStore.Entry memory entry = destinationStateStore.get(expectedKey);

        assertEq(entry.version, 1, "relay version");
        assertEq(entry.srcTimestamp, block.timestamp);
        assertEq(entry.value.length, 96);
        {
            IVault.AssetParams memory resultEntry = abi.decode(entry.value, (IVault.AssetParams));
            assertEq(resultEntry.index, expectedEntry.index);
            assertTrue(resultEntry.active);
            assertEq(resultEntry.decimals, expectedEntry.decimals);
        }
        assertEq(quoteData.key, expectedKey);
        assertEq(entry.updatedAt, block.timestamp);
        assertEq(entry.updatedAtBlock, block.number);
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

    function test_fork_mainnet_sendState_relayedViaLzHelper_ynEthxGetAsset() public {
        _assertYnEthxGetAssetRelayed();
    }

    function test_fork_mainnet_sendState_insufficientNativeFee_reverts() public {
        _assertInsufficientNativeFeeReverts();
    }
}

/**
 * @notice Reads `convertToAssets(1e18)` from **mainnet** ynETHx, then applies it on an **Arbitrum** fork via
 *         StateStore + StateReceiver (harness simulates LZ payload). Models production: L1 rate → L2 store.
 * @dev Wire format to the receiver is `abi.encode(uint256 version, bytes32 key, bytes value, uint64 srcTimestamp)`.
 */
contract StateRelayForkMainnetToArbitrumTest is Test, TestHelperOz5, StateRelayForkAdapterHelpers {
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
    function _readMainnetAndDeliverToArbitrumForCalldata(address target, bytes memory callData)
        internal
        returns (StateStore stateStore, bytes32 key, bytes memory data, uint256 deliveredAt)
    {
        vm.selectFork(forkMainnet);

        (bool ok, bytes memory stateData) = target.staticcall(callData);
        require(ok, "mainnet: calldata staticcall failed");

        uint64 srcTs = uint64(block.timestamp);
        key = KeyDerivation.deriveKey(1, target, callData);

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
            bytes memory recvInit =
                abi.encodeCall(LayerZeroReceiverTransport.initialize, (address(this), address(stateStore)));
            ERC1967Proxy recvProxy = new ERC1967Proxy(address(recvImpl), recvInit);
            receiver = StateReceiverHarness(address(recvProxy));
        }

        stateStore.grantRole(stateStore.WRITER_ROLE(), address(receiver));

        bytes memory message = abi.encode(uint256(1), key, stateData, srcTs);
        receiver.receivePayload(message);

        deliveredAt = block.timestamp;

        bytes memory stored = stateStore.get(key).value;
        assertEq(stored, stateData);
        return (stateStore, key, stored, deliveredAt);
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


        bytes memory stored;
        (stateStore, key, stored, deliveredAt) = _readMainnetAndDeliverToArbitrumForCalldata(YNETHX_MAINNET, CONVERT_TO_ASSETS_CALLDATA);
        assertEq(stored, stateData);
        assertEq(abi.decode(stored, (uint256)), expectedRate);
    }

    function test_fork_mainnet_convertToAssets_writtenOnArbitrumStateStore() public {
        (StateStore stateStore, bytes32 key, uint256 expectedRate,) = _readMainnetAndDeliverToArbitrum();

        RateAdapterUpgradeable adapter =
            _deployRateAdapter(address(stateStore), key, STALENESS, STALENESS, MAX_SOURCE_TIMESTAMP_SKEW);
        assertEq(adapter.getRate(), expectedRate);
    }

    /// @dev Proves `StateReaderBase` accepts fresh delivery under a short `maxSrc` / `maxDst` window.
    function test_fork_mainnetToArbitrum_rateAdapter_passesShortStaleness() public {
        (StateStore stateStore, bytes32 key, uint256 expectedRate,) = _readMainnetAndDeliverToArbitrum();

        RateAdapterUpgradeable adapter =
            _deployRateAdapter(address(stateStore), key, STALENESS, STALENESS, MAX_SOURCE_TIMESTAMP_SKEW);
        assertEq(adapter.maxSrcStaleness(), STALENESS);
        assertEq(adapter.maxDstStaleness(), STALENESS);
        assertEq(adapter.maxSourceTimestampSkew(), MAX_SOURCE_TIMESTAMP_SKEW);
        assertEq(adapter.getRate(), expectedRate);

        // Still within both windows after a modest warp (delivery age < STALENESS).
        vm.warp(block.timestamp + 30 minutes);
        assertEq(adapter.getRate(), expectedRate);
    }

    /// @dev Past `maxDstStaleness` from store `updatedAt`, read must revert.
    function test_fork_mainnetToArbitrum_rateAdapter_revertsWhenDeliveryStale() public {
        (StateStore stateStore, bytes32 key,, uint256 deliveredAt) = _readMainnetAndDeliverToArbitrum();

        // Keep source window wider so this test isolates delivery-stale behavior.
        RateAdapterUpgradeable adapter = _deployRateAdapter(
            address(stateStore), key, STALENESS + 1 hours, STALENESS, MAX_SOURCE_TIMESTAMP_SKEW
        );

        vm.warp(deliveredAt + STALENESS + 1);
        vm.expectRevert(StateReaderBaseUpgradeable.StateReaderBaseUpgradeable_DeliveryStale.selector);
        adapter.getRate();
    }
}
