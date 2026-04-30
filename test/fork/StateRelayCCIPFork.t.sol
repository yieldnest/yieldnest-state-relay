// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {StateSender} from "src/StateSender.sol";
import {StateStore} from "src/StateStore.sol";
import {RateAdapterUpgradeable} from "src/adapter/RateAdapterUpgradeable.sol";
import {KeyDerivation} from "src/KeyDerivation.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {TestCCIPSenderTransport} from "test/mocks/ccip/TestCCIPSenderTransport.sol";
import {TestCCIPReceiverTransport} from "test/mocks/ccip/TestCCIPReceiverTransport.sol";
import {TestCCIPStateSource} from "test/mocks/ccip/TestCCIPStateSource.sol";

interface ITestCCIPStateSourceView {
    struct AssetParams {
        uint256 index;
        bool active;
        uint8 decimals;
    }

    function getAsset(address asset_) external view returns (AssetParams memory);
}

abstract contract StateRelayCCIPForkConstants {
    address internal constant ASSET = 0x1111111111111111111111111111111111111111;
    address internal constant ETHEREUM_MAINNET_CCIP_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address internal constant ARBITRUM_ONE_CCIP_ROUTER = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;
    address internal constant MAINNET_WRAPPED_NATIVE = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ARBITRUM_WRAPPED_NATIVE = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    uint64 internal constant ETHEREUM_MAINNET_CHAIN_SELECTOR = 5009297550715157269;
    uint64 internal constant ARBITRUM_ONE_CHAIN_SELECTOR = 4949039107694359620;

    uint256 internal constant ONE_SHARE = 1e18;
    uint256 internal constant MAX_SOURCE_TIMESTAMP_SKEW = 30 days;
    uint256 internal constant STALENESS = 30 days;
    uint256 internal constant DST_CHAIN_ID = 42161;

    bytes internal constant CONVERT_TO_ASSETS_CALLDATA = abi.encodeCall(IERC4626.convertToAssets, (ONE_SHARE));
    bytes internal constant GET_ASSET_CALLDATA = abi.encodeCall(ITestCCIPStateSourceView.getAsset, (ASSET));
}

contract StateRelayCCIPFork is Test, StateRelayCCIPForkConstants {
    uint256 internal forkMainnet;
    uint256 internal forkArbitrum;

    CCIPLocalSimulatorFork internal ccipLocalSimulatorFork;

    StateSender internal stateSender;
    TestCCIPSenderTransport internal senderTransport;
    TestCCIPStateSource internal stateSource;

    StateStore internal destinationStateStore;
    TestCCIPReceiverTransport internal receiverTransport;

    Register.NetworkDetails internal mainnetNetworkDetails;
    Register.NetworkDetails internal arbitrumNetworkDetails;

    function setUp() public {
        forkMainnet = vm.createSelectFork(vm.envString("ETH_MAINNET_RPC_URL"));
        forkArbitrum = vm.createFork(vm.envString("ARBITRUM_RPC"));

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        _configureMainnetNetworkDetails();

        _deploySource();
        _deployDestination();
    }

    function test_fork_mainnet_sendState_relayedViaCCIP_convertToAssets() public {
        vm.selectFork(forkMainnet);

        uint256 expectedAssets = stateSource.convertToAssets(ONE_SHARE);

        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(DST_CHAIN_ID);
        stateSender.sendState{value: quoteData.transportQuote.feeAmount}(DST_CHAIN_ID);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(forkArbitrum);

        vm.selectFork(forkArbitrum);

        bytes32 expectedKey = KeyDerivation.deriveKey(1, address(stateSource), CONVERT_TO_ASSETS_CALLDATA);
        StateStore.Entry memory entry = destinationStateStore.get(expectedKey);

        assertEq(entry.version, 1);
        assertEq(entry.value.length, 32);
        assertEq(abi.decode(entry.value, (uint256)), expectedAssets);

        RateAdapterUpgradeable adapter = _deployRateAdapter(address(destinationStateStore), expectedKey);
        assertEq(adapter.getRate(), expectedAssets);
    }

    function test_fork_mainnet_sendState_relayedViaCCIP_getAsset() public {
        vm.selectFork(forkMainnet);

        ITestCCIPStateSourceView.AssetParams memory expectedEntry =
            ITestCCIPStateSourceView(address(stateSource)).getAsset(ASSET);

        stateSender.setCallData(GET_ASSET_CALLDATA);
        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(DST_CHAIN_ID);
        stateSender.sendState{value: quoteData.transportQuote.feeAmount}(DST_CHAIN_ID);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(forkArbitrum);

        vm.selectFork(forkArbitrum);

        bytes32 expectedKey = KeyDerivation.deriveKey(1, address(stateSource), GET_ASSET_CALLDATA);
        StateStore.Entry memory entry = destinationStateStore.get(expectedKey);

        assertEq(entry.version, 1);
        assertEq(entry.value.length, 96);

        ITestCCIPStateSourceView.AssetParams memory resultEntry =
            abi.decode(entry.value, (ITestCCIPStateSourceView.AssetParams));
        assertEq(resultEntry.index, expectedEntry.index);
        assertEq(resultEntry.active, expectedEntry.active);
        assertEq(resultEntry.decimals, expectedEntry.decimals);
    }

    function test_fork_mainnet_sendState_insufficientNativeFee_reverts() public {
        vm.selectFork(forkMainnet);

        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(DST_CHAIN_ID);
        vm.expectRevert(StateSender.StateSender_InsufficientNativeFee.selector);
        stateSender.sendState{value: quoteData.transportQuote.feeAmount - 1}(DST_CHAIN_ID);
    }

    function _configureMainnetNetworkDetails() internal {
        vm.selectFork(forkMainnet);
        ccipLocalSimulatorFork.setNetworkDetails(
            1,
            Register.NetworkDetails({
                chainSelector: ETHEREUM_MAINNET_CHAIN_SELECTOR,
                routerAddress: ETHEREUM_MAINNET_CCIP_ROUTER,
                linkAddress: address(0),
                wrappedNativeAddress: MAINNET_WRAPPED_NATIVE,
                ccipBnMAddress: address(0),
                ccipLnMAddress: address(0),
                rmnProxyAddress: address(0),
                registryModuleOwnerCustomAddress: address(0),
                tokenAdminRegistryAddress: address(0)
            })
        );
        mainnetNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        vm.selectFork(forkArbitrum);
        ccipLocalSimulatorFork.setNetworkDetails(
            42161,
            Register.NetworkDetails({
                chainSelector: ARBITRUM_ONE_CHAIN_SELECTOR,
                routerAddress: ARBITRUM_ONE_CCIP_ROUTER,
                linkAddress: address(0),
                wrappedNativeAddress: ARBITRUM_WRAPPED_NATIVE,
                ccipBnMAddress: address(0),
                ccipLnMAddress: address(0),
                rmnProxyAddress: address(0),
                registryModuleOwnerCustomAddress: address(0),
                tokenAdminRegistryAddress: address(0)
            })
        );
        arbitrumNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
    }

    function _deploySource() internal {
        vm.selectFork(forkMainnet);

        senderTransport = new TestCCIPSenderTransport(mainnetNetworkDetails.routerAddress, address(this));
        stateSource = new TestCCIPStateSource();
        stateSource.setConvertToAssetsRate(2e18);
        stateSource.setAsset(ASSET, TestCCIPStateSource.AssetParams({index: 7, active: true, decimals: 18}));

        TestCCIPSenderTransport.DestinationConfig memory destinationConfig = TestCCIPSenderTransport.DestinationConfig({
            chainSelector: arbitrumNetworkDetails.chainSelector,
            receiver: address(0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            enabled: true
        });

        StateSender impl = new StateSender();
        bytes memory initData = abi.encodeCall(
            StateSender.initialize,
            (address(this), address(senderTransport), address(stateSource), CONVERT_TO_ASSETS_CALLDATA, 1)
        );
        stateSender = StateSender(address(new ERC1967Proxy(address(impl), initData)));

        senderTransport.setDestination(DST_CHAIN_ID, destinationConfig);
    }

    function _deployDestination() internal {
        vm.selectFork(forkArbitrum);

        StateStore storeImpl = new StateStore();
        bytes memory storeInit = abi.encodeCall(StateStore.initialize, (address(this), new address[](0)));
        destinationStateStore = StateStore(address(new ERC1967Proxy(address(storeImpl), storeInit)));

        receiverTransport = new TestCCIPReceiverTransport(
            arbitrumNetworkDetails.routerAddress, address(this), address(destinationStateStore)
        );
        destinationStateStore.grantRole(destinationStateStore.WRITER_ROLE(), address(receiverTransport));
        receiverTransport.setTrustedSource(mainnetNetworkDetails.chainSelector, address(senderTransport));

        vm.selectFork(forkMainnet);
        TestCCIPSenderTransport.DestinationConfig memory destinationConfig = TestCCIPSenderTransport.DestinationConfig({
            chainSelector: arbitrumNetworkDetails.chainSelector,
            receiver: address(receiverTransport),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            enabled: true
        });
        senderTransport.setDestination(DST_CHAIN_ID, destinationConfig);
    }

    function _deployRateAdapter(address stateStore_, bytes32 key) internal returns (RateAdapterUpgradeable) {
        vm.selectFork(forkArbitrum);

        RateAdapterUpgradeable adapterImpl = new RateAdapterUpgradeable();
        bytes memory adapterInit = abi.encodeCall(
            RateAdapterUpgradeable.initialize,
            (address(this), stateStore_, key, STALENESS, STALENESS, MAX_SOURCE_TIMESTAMP_SKEW)
        );
        return RateAdapterUpgradeable(address(new ERC1967Proxy(address(adapterImpl), adapterInit)));
    }
}
