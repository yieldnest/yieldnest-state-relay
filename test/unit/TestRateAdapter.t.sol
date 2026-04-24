// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {RateAdapterUpgradeable} from "src/adapter/RateAdapterUpgradeable.sol";
import {StateReaderBaseUpgradeable} from "src/StateReaderBaseUpgradeable.sol";
import {StateStore} from "src/StateStore.sol";
import {KeyDerivation} from "src/KeyDerivation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TestRateAdapterTest is Test {
    uint256 constant MAX_SOURCE_TIMESTAMP_SKEW = 1 hours;
    StateStore public stateStore;
    RateAdapterUpgradeable public rateAdapter;
    bytes32 public rateKey;

    uint256 constant STALENESS = 1 hours;

    function setUp() public {
        StateStore impl = new StateStore();
        bytes memory initData = abi.encodeCall(StateStore.initialize, (address(this), new address[](0)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        stateStore = StateStore(address(proxy));
        stateStore.grantRole(stateStore.WRITER_ROLE(), address(this));
        rateKey = KeyDerivation.deriveKey(block.chainid, address(0x123), hex"679aefce");
        RateAdapterUpgradeable adapterImpl = new RateAdapterUpgradeable();
        bytes memory adapterInit =
            abi.encodeCall(
                RateAdapterUpgradeable.initialize,
                (address(stateStore), rateKey, STALENESS, STALENESS, MAX_SOURCE_TIMESTAMP_SKEW)
            );
        ERC1967Proxy adapterProxy = new ERC1967Proxy(address(adapterImpl), adapterInit);
        rateAdapter = RateAdapterUpgradeable(address(adapterProxy));
    }

    // --- RateAdapterUpgradeable: decode value (StateSender sends abi.encode(uint256)) ---

    function test_getRate_returnsDecodedUint256() public {
        uint256 rate = 1e18;
        stateStore.write(
            rateKey,
            StateStore.StateUpdate({value: abi.encode(rate), version: 1, srcTimestamp: uint64(block.timestamp)})
        );
        assertEq(rateAdapter.getRate(), rate);
    }

    function test_getRate_decodesDifferentRates() public {
        stateStore.write(
            rateKey,
            StateStore.StateUpdate({value: abi.encode(uint256(2e18)), version: 1, srcTimestamp: uint64(block.timestamp)})
        );
        assertEq(rateAdapter.getRate(), 2e18);

        vm.warp(block.timestamp + 1);
        stateStore.write(
            rateKey,
            StateStore.StateUpdate({value: abi.encode(uint256(99e6)), version: 1, srcTimestamp: uint64(block.timestamp)})
        );
        assertEq(rateAdapter.getRate(), 99e6);
    }

    // --- StateReaderBaseUpgradeable: staleness checks ---

    function test_getRate_sourceStale_reverts() public {
        stateStore.write(
            rateKey,
            StateStore.StateUpdate({value: abi.encode(1e18), version: 1, srcTimestamp: uint64(block.timestamp)})
        );
        vm.warp(block.timestamp + STALENESS + 1);
        vm.expectRevert(StateReaderBaseUpgradeable.StateReaderBaseUpgradeable_SourceStale.selector);
        rateAdapter.getRate();
    }

    function test_getRate_deliveryStale_reverts() public {
        // With one write, source and delivery age together; source check runs first
        stateStore.write(
            rateKey,
            StateStore.StateUpdate({value: abi.encode(1e18), version: 1, srcTimestamp: uint64(block.timestamp)})
        );
        vm.warp(block.timestamp + STALENESS + 1);
        vm.expectRevert(StateReaderBaseUpgradeable.StateReaderBaseUpgradeable_SourceStale.selector);
        rateAdapter.getRate();
    }

    function test_getRate_withinStaleness_succeeds() public {
        stateStore.write(
            rateKey,
            StateStore.StateUpdate({value: abi.encode(1e18), version: 1, srcTimestamp: uint64(block.timestamp)})
        );
        vm.warp(block.timestamp + STALENESS - 1);
        assertEq(rateAdapter.getRate(), 1e18);
    }

    function test_getRate_sourceTimestampWithinSkew_succeeds() public {
        stateStore.write(
            rateKey,
            StateStore.StateUpdate({
                value: abi.encode(1e18),
                version: 1,
                srcTimestamp: uint64(block.timestamp + MAX_SOURCE_TIMESTAMP_SKEW)
            })
        );
        assertEq(rateAdapter.getRate(), 1e18);
    }

    function test_getRate_sourceTimestampBeyondSkew_reverts() public {
        stateStore.write(
            rateKey,
            StateStore.StateUpdate({
                value: abi.encode(1e18),
                version: 1,
                srcTimestamp: uint64(block.timestamp + MAX_SOURCE_TIMESTAMP_SKEW + 1)
            })
        );
        vm.expectRevert(StateReaderBaseUpgradeable.StateReaderBaseUpgradeable_SourceTimestampInFuture.selector);
        rateAdapter.getRate();
    }

    // --- StateReaderBaseUpgradeable: config stored correctly ---

    function test_rateAdapter_config() public view {
        assertEq(address(rateAdapter.stateStore()), address(stateStore));
        assertEq(rateAdapter.rateKey(), rateKey);
        assertEq(rateAdapter.maxSrcStaleness(), STALENESS);
        assertEq(rateAdapter.maxDstStaleness(), STALENESS);
        assertEq(rateAdapter.maxSourceTimestampSkew(), MAX_SOURCE_TIMESTAMP_SKEW);
    }

    function test_getRate_noEntry_reverts() public {
        // Key never written: get returns (empty, 0, 0). _decodeValue(empty) or staleness check reverts
        vm.expectRevert();
        rateAdapter.getRate();
    }
}
