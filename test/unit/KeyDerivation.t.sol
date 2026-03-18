// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {KeyDerivation} from "src/KeyDerivation.sol";

contract KeyDerivationTest is Test {
    function test_deriveKey_deterministic() public pure {
        uint256 chainId = 1;
        address target = address(0x123);
        bytes memory callData = hex"679aefce";
        bytes32 a = KeyDerivation.deriveKey(chainId, target, callData);
        bytes32 b = KeyDerivation.deriveKey(chainId, target, callData);
        assertEq(a, b);
    }

    function test_deriveKey_differentChainId_differentKey() public pure {
        address target = address(0x456);
        bytes memory callData = hex"dead";
        bytes32 k1 = KeyDerivation.deriveKey(1, target, callData);
        bytes32 k2 = KeyDerivation.deriveKey(2, target, callData);
        assertTrue(k1 != k2);
    }

    function test_deriveKey_differentTarget_differentKey() public pure {
        uint256 chainId = 1;
        bytes memory callData = hex"beef";
        bytes32 k1 = KeyDerivation.deriveKey(chainId, address(0x1), callData);
        bytes32 k2 = KeyDerivation.deriveKey(chainId, address(0x2), callData);
        assertTrue(k1 != k2);
    }

    function test_deriveKey_differentCallData_differentKey() public pure {
        uint256 chainId = 1;
        address target = address(0x789);
        bytes32 k1 = KeyDerivation.deriveKey(chainId, target, hex"aa");
        bytes32 k2 = KeyDerivation.deriveKey(chainId, target, hex"bb");
        assertTrue(k1 != k2);
    }

    function test_deriveKey_domainNonZero() public pure {
        assertTrue(KeyDerivation.KEY_DOMAIN != bytes32(0));
    }

    function test_deriveKey_matchesStateSenderUsage() public view {
        uint256 chainId = block.chainid;
        address target = address(0xBEEF);
        bytes memory callData = abi.encodeWithSelector(bytes4(0x679aefce));
        bytes32 key = KeyDerivation.deriveKey(chainId, target, callData);
        assertTrue(key != bytes32(0));
        assertEq(key, KeyDerivation.deriveKey(chainId, target, callData));
    }
}
