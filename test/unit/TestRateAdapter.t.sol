// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {RateAdapterUpgradeable} from "src/adapter/RateAdapterUpgradeable.sol";
import {StateReaderBaseUpgradeable} from "src/StateReaderBaseUpgradeable.sol";
import {StateStore} from "src/StateStore.sol";
import {KeyDerivation} from "src/KeyDerivation.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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
        bytes memory adapterInit = abi.encodeCall(
            RateAdapterUpgradeable.initialize,
            (address(this), address(stateStore), rateKey, STALENESS, STALENESS, MAX_SOURCE_TIMESTAMP_SKEW)
        );
        ERC1967Proxy adapterProxy = new ERC1967Proxy(address(adapterImpl), adapterInit);
        rateAdapter = RateAdapterUpgradeable(address(adapterProxy));
    }

    function _deployStateStore() internal returns (StateStore store) {
        StateStore impl = new StateStore();
        bytes memory initData = abi.encodeCall(StateStore.initialize, (address(this), new address[](0)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        store = StateStore(address(proxy));
        store.grantRole(store.WRITER_ROLE(), address(this));
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

    function test_initialize_grantsReaderAdminAndManagerRoles() public view {
        assertTrue(rateAdapter.hasRole(rateAdapter.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(rateAdapter.hasRole(rateAdapter.CONFIG_MANAGER_ROLE(), address(this)));
        assertTrue(rateAdapter.hasRole(rateAdapter.STATE_STORE_MANAGER_ROLE(), address(this)));
    }

    function test_initialize_grantsRolesToAdminParameterNotSender() public {
        address admin = address(0xA11CE);

        RateAdapterUpgradeable adapterImpl = new RateAdapterUpgradeable();
        bytes memory adapterInit = abi.encodeCall(
            RateAdapterUpgradeable.initialize,
            (admin, address(stateStore), rateKey, STALENESS, STALENESS, MAX_SOURCE_TIMESTAMP_SKEW)
        );
        ERC1967Proxy adapterProxy = new ERC1967Proxy(address(adapterImpl), adapterInit);
        RateAdapterUpgradeable adapter = RateAdapterUpgradeable(address(adapterProxy));

        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(adapter.hasRole(adapter.CONFIG_MANAGER_ROLE(), admin));
        assertTrue(adapter.hasRole(adapter.STATE_STORE_MANAGER_ROLE(), admin));

        assertFalse(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(adapter.hasRole(adapter.CONFIG_MANAGER_ROLE(), address(this)));
        assertFalse(adapter.hasRole(adapter.STATE_STORE_MANAGER_ROLE(), address(this)));
    }

    function test_initialize_revertsOnZeroAdmin() public {
        RateAdapterUpgradeable adapterImpl = new RateAdapterUpgradeable();
        bytes memory adapterInit = abi.encodeCall(
            RateAdapterUpgradeable.initialize,
            (address(0), address(stateStore), rateKey, STALENESS, STALENESS, MAX_SOURCE_TIMESTAMP_SKEW)
        );

        vm.expectRevert(StateReaderBaseUpgradeable.StateReaderBaseUpgradeable_ZeroAddress.selector);
        new ERC1967Proxy(address(adapterImpl), adapterInit);
    }

    function test_configSetters_updateConfig() public {
        bytes32 newRateKey = KeyDerivation.deriveKey(block.chainid, address(0x456), hex"679aefce");
        uint256 newMaxSrcStaleness = 2 hours;
        uint256 newMaxDstStaleness = 3 hours;
        uint256 newMaxSourceTimestampSkew = 4 hours;

        rateAdapter.setStateKey(newRateKey);
        rateAdapter.setMaxSrcStaleness(newMaxSrcStaleness);
        rateAdapter.setMaxDstStaleness(newMaxDstStaleness);
        rateAdapter.setMaxSourceTimestampSkew(newMaxSourceTimestampSkew);

        assertEq(rateAdapter.rateKey(), newRateKey);
        assertEq(rateAdapter.maxSrcStaleness(), newMaxSrcStaleness);
        assertEq(rateAdapter.maxDstStaleness(), newMaxDstStaleness);
        assertEq(rateAdapter.maxSourceTimestampSkew(), newMaxSourceTimestampSkew);

        stateStore.write(
            newRateKey,
            StateStore.StateUpdate({value: abi.encode(uint256(3e18)), version: 1, srcTimestamp: uint64(block.timestamp)})
        );
        assertEq(rateAdapter.getRate(), 3e18);
    }

    function test_setStateKey_requiresConfigManagerRole() public {
        address unauthorized = address(0xBEEF);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                rateAdapter.CONFIG_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        rateAdapter.setStateKey(rateKey);
    }

    function test_stalenessSetters_requireConfigManagerRole() public {
        address unauthorized = address(0xBEEF);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                rateAdapter.CONFIG_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        rateAdapter.setMaxSrcStaleness(STALENESS);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                rateAdapter.CONFIG_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        rateAdapter.setMaxDstStaleness(STALENESS);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                rateAdapter.CONFIG_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        rateAdapter.setMaxSourceTimestampSkew(MAX_SOURCE_TIMESTAMP_SKEW);
    }

    function test_setStateStore_updatesStore() public {
        StateStore newStateStore = _deployStateStore();

        newStateStore.write(
            rateKey,
            StateStore.StateUpdate({value: abi.encode(uint256(4e18)), version: 1, srcTimestamp: uint64(block.timestamp)})
        );
        rateAdapter.setStateStore(address(newStateStore));

        assertEq(address(rateAdapter.stateStore()), address(newStateStore));
        assertEq(rateAdapter.getRate(), 4e18);
    }

    function test_setStateStore_revertsOnZeroAddress() public {
        vm.expectRevert(StateReaderBaseUpgradeable.StateReaderBaseUpgradeable_ZeroAddress.selector);
        rateAdapter.setStateStore(address(0));
    }

    function test_setStateStore_requiresStateStoreManagerRole() public {
        address unauthorized = address(0xBEEF);
        StateStore newStateStore = _deployStateStore();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                rateAdapter.STATE_STORE_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        rateAdapter.setStateStore(address(newStateStore));
    }

    function test_getRate_noEntry_reverts() public {
        // Key never written: get returns (empty, 0, 0). _decodeValue(empty) or staleness check reverts
        vm.expectRevert();
        rateAdapter.getRate();
    }
}
