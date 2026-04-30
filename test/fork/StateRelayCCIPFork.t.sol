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

    uint256 internal constant ONE_SHARE = 1e18;
    uint256 internal constant MAX_SOURCE_TIMESTAMP_SKEW = 1 hours;
    uint256 internal constant STALENESS = 1 hours;
    uint256 internal constant DST_CHAIN_ID = 421614;

    bytes internal constant CONVERT_TO_ASSETS_CALLDATA = abi.encodeCall(IERC4626.convertToAssets, (ONE_SHARE));
    bytes internal constant GET_ASSET_CALLDATA = abi.encodeCall(ITestCCIPStateSourceView.getAsset, (ASSET));
}

contract StateRelayCCIPFork is Test, StateRelayCCIPForkConstants {
    uint256 internal forkSepolia;
    uint256 internal forkArbitrumSepolia;

    CCIPLocalSimulatorFork internal ccipLocalSimulatorFork;

    StateSender internal stateSender;
    TestCCIPSenderTransport internal senderTransport;
    TestCCIPStateSource internal stateSource;

    StateStore internal destinationStateStore;
    TestCCIPReceiverTransport internal receiverTransport;

    Register.NetworkDetails internal sepoliaNetworkDetails;
    Register.NetworkDetails internal arbitrumSepoliaNetworkDetails;

    function setUp() public {
        forkSepolia = vm.createSelectFork(vm.envString("ETHEREUM_SEPOLIA_RPC_URL"));
        forkArbitrumSepolia = vm.createFork(vm.envString("ARBITRUM_SEPOLIA_RPC_URL"));

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        vm.selectFork(forkArbitrumSepolia);
        arbitrumSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        vm.selectFork(forkSepolia);

        _deploySource();
        _deployDestination();
    }

    function test_fork_sepolia_sendState_relayedViaCCIP_convertToAssets() public {
        vm.selectFork(forkSepolia);

        uint256 expectedAssets = stateSource.convertToAssets(ONE_SHARE);

        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(DST_CHAIN_ID);
        stateSender.sendState{value: quoteData.transportQuote.feeAmount}(DST_CHAIN_ID);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(forkArbitrumSepolia);

        vm.selectFork(forkArbitrumSepolia);

        bytes32 expectedKey = KeyDerivation.deriveKey(1, address(stateSource), CONVERT_TO_ASSETS_CALLDATA);
        StateStore.Entry memory entry = destinationStateStore.get(expectedKey);

        assertEq(entry.version, 1);
        assertEq(entry.value.length, 32);
        assertEq(abi.decode(entry.value, (uint256)), expectedAssets);

        RateAdapterUpgradeable adapter = _deployRateAdapter(address(destinationStateStore), expectedKey);
        assertEq(adapter.getRate(), expectedAssets);
    }

    function test_fork_sepolia_sendState_relayedViaCCIP_getAsset() public {
        vm.selectFork(forkSepolia);

        ITestCCIPStateSourceView.AssetParams memory expectedEntry =
            ITestCCIPStateSourceView(address(stateSource)).getAsset(ASSET);

        stateSender.setCallData(GET_ASSET_CALLDATA);
        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(DST_CHAIN_ID);
        stateSender.sendState{value: quoteData.transportQuote.feeAmount}(DST_CHAIN_ID);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(forkArbitrumSepolia);

        vm.selectFork(forkArbitrumSepolia);

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

    function test_fork_sepolia_sendState_insufficientNativeFee_reverts() public {
        vm.selectFork(forkSepolia);

        StateSender.SendStateQuote memory quoteData = stateSender.quoteSendState(DST_CHAIN_ID);
        vm.expectRevert(StateSender.StateSender_InsufficientNativeFee.selector);
        stateSender.sendState{value: quoteData.transportQuote.feeAmount - 1}(DST_CHAIN_ID);
    }

    function _deploySource() internal {
        vm.selectFork(forkSepolia);

        senderTransport = new TestCCIPSenderTransport(sepoliaNetworkDetails.routerAddress, address(this));
        stateSource = new TestCCIPStateSource();
        stateSource.setConvertToAssetsRate(2e18);
        stateSource.setAsset(ASSET, TestCCIPStateSource.AssetParams({index: 7, active: true, decimals: 18}));

        TestCCIPSenderTransport.DestinationConfig memory destinationConfig = TestCCIPSenderTransport.DestinationConfig({
            chainSelector: arbitrumSepoliaNetworkDetails.chainSelector,
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
        vm.selectFork(forkArbitrumSepolia);

        StateStore storeImpl = new StateStore();
        bytes memory storeInit = abi.encodeCall(StateStore.initialize, (address(this), new address[](0)));
        destinationStateStore = StateStore(address(new ERC1967Proxy(address(storeImpl), storeInit)));

        receiverTransport = new TestCCIPReceiverTransport(
            arbitrumSepoliaNetworkDetails.routerAddress, address(this), address(destinationStateStore)
        );
        destinationStateStore.grantRole(destinationStateStore.WRITER_ROLE(), address(receiverTransport));
        receiverTransport.setTrustedSource(sepoliaNetworkDetails.chainSelector, address(senderTransport));

        vm.selectFork(forkSepolia);
        TestCCIPSenderTransport.DestinationConfig memory destinationConfig = TestCCIPSenderTransport.DestinationConfig({
            chainSelector: arbitrumSepoliaNetworkDetails.chainSelector,
            receiver: address(receiverTransport),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            enabled: true
        });
        senderTransport.setDestination(DST_CHAIN_ID, destinationConfig);
    }

    function _deployRateAdapter(address stateStore_, bytes32 key) internal returns (RateAdapterUpgradeable) {
        vm.selectFork(forkArbitrumSepolia);

        RateAdapterUpgradeable adapterImpl = new RateAdapterUpgradeable();
        bytes memory adapterInit = abi.encodeCall(
            RateAdapterUpgradeable.initialize,
            (address(this), stateStore_, key, STALENESS, STALENESS, MAX_SOURCE_TIMESTAMP_SKEW)
        );
        return RateAdapterUpgradeable(address(new ERC1967Proxy(address(adapterImpl), adapterInit)));
    }
}
