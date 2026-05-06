# Third-Party Bytecode Verification Guide

This guide explains how an independent third party can verify the deployed contracts committed on the current branch.

It covers:
- verifying the deployment topology
- verifying proxy/admin/timelock wiring
- verifying on-chain runtime bytecode against locally built artifacts
- verifying the LayerZero transport implementations and proxies with exact constructor arguments

This guide is for the committed relay deployment artifacts:
- [deployments/mainnet-xdc-ynrwax-v0.1.0.json](/home/claudeuser/source/yieldnest-state-relay/deployments/mainnet-xdc-ynrwax-v0.1.0.json)
- [deployments/adapters/mainnet-xdc-ynrwax-v0.1.0.json](/home/claudeuser/source/yieldnest-state-relay/deployments/adapters/mainnet-xdc-ynrwax-v0.1.0.json)

## Scope

The committed deployment is:
- source chain: Ethereum mainnet (`chainId = 1`)
- destination chain: XDC (`chainId = 50`)
- relay label: `mainnet-ynrwax-convertToAssets`

Deployed proxies:
- Ethereum mainnet
  - `StateSender` proxy: `0xD2854219263BF681a8E11c41b05ae3f1a08f5D94`
  - `LayerZeroSenderTransport` proxy: `0xDABE0aae5Dc98068963a49C63fF56144DB6FBBE8`
- XDC
  - `StateStore` proxy: `0xe4A68709601F0d67d2333F6fEA0b9518eA25C897`
  - `LayerZeroReceiverTransport` proxy: `0xa031Dfe64aD016E3475007BEb6dbE632B83CDc01`
  - `RateAdapterUpgradeable` proxy: `0xc25e5331C8523eAb0F09166B506B865Ad3E3Bb43`

Proxy admin contracts:
- Ethereum mainnet
  - sender proxy admin: `0xb4e7A08A791f7A7bcd135c628211931D57C73C2E`
  - transport proxy admin: `0xfc57516e6d2F3924DfF6f5D0c042f0c9df0d383A`
- XDC
  - state store proxy admin: `0x63eFe570352523f8a0F2E6658Dc1907598248953`
  - receiver proxy admin: `0x6fc2023829C8C8e6b9C9e8Cb3c13bAd1545dbDc3`
  - rate adapter proxy admin: `0xC7Ffca6D884c4b447E321496af1a0bc550d315e2`

Proxy-admin timelocks:
- Ethereum mainnet
  - sender proxy admin timelock: `0xA7aDbC2101F3503841Ab6FE5bDB8e480e2902D21`
  - transport proxy admin timelock: `0x9CB00E129d1BBf6baB6d3bE661602Ab3f1C38707`
- XDC
  - state store proxy admin timelock: `0x200940DC5cE303Af2a53e13181CBCBAc96237a74`
  - receiver proxy admin timelock: `0x3656ce5F84B98fa3E0D5EdD4E47fd4771Cd80C6c`
  - rate adapter proxy admin timelock: `0x5bA76aD2dbf0D7B53396F80328cEc5EAd3183Cfc`

Implementation contracts created during deployment:
- Ethereum mainnet
  - `LayerZeroSenderTransport` implementation: `0x7971F0dDC51F59496FaD4e012e35DF5ee1Acd203`
  - `StateSender` implementation: `0x7FC4e96e0D2D5918924B92bC6f960F951354B00c`
- XDC
  - `LayerZeroReceiverTransport` implementation: `0x3649638CC74F2e417563B5840dFD8A010BfE33a8`
  - `StateStore` implementation: `0x4e077cA5dEe2d965595b73beE36856486aC18a75`
  - `RateAdapterUpgradeable` implementation: `0x0f4398aDFa8Fc8451F262E6180Ee697bc4Ba7a90`

## Prerequisites

Use the same repo revision as the deployment artifacts:

```bash
cd /path/to/yieldnest-state-relay
git checkout <the-branch-or-commit-you-want-to-verify>
git submodule update --init --recursive
forge build
```

Build settings used by this repo:
- Solidity `0.8.22`
- optimizer enabled
- optimizer runs `200`

Environment:

```bash
export ETH_MAINNET_RPC_URL=...
export XDC_RPC_URL=...
export ETHERSCAN_API_KEY=...
export ETHERSCAN_VERIFIER_URL_XDC="https://api.etherscan.io/v2/api?chainid=50"
```

## Helper Variables

```bash
export IMPLEMENTATION_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
export ADMIN_SLOT=0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103

export MAINNET_SENDER_PROXY=0xD2854219263BF681a8E11c41b05ae3f1a08f5D94
export MAINNET_TRANSPORT_PROXY=0xDABE0aae5Dc98068963a49C63fF56144DB6FBBE8

export XDC_STATESTORE_PROXY=0xe4A68709601F0d67d2333F6fEA0b9518eA25C897
export XDC_RECEIVER_PROXY=0xa031Dfe64aD016E3475007BEb6dbE632B83CDc01
export XDC_RATE_ADAPTER_PROXY=0xc25e5331C8523eAb0F09166B506B865Ad3E3Bb43
```

Useful shell helpers:

```bash
slot_to_address() {
  cast storage "$1" "$2" --rpc-url "$3" | sed 's/^0x000000000000000000000000/0x/'
}

compare_runtime() {
  local rpc="$1"
  local address="$2"
  local contract="$3"
  local onchain local
  onchain=$(cast code "$address" --rpc-url "$rpc" | tr '[:upper:]' '[:lower:]')
  local=$(forge inspect "$contract" deployedBytecode | tr -d '\n' | tr '[:upper:]' '[:lower:]')
  if [ "$onchain" = "$local" ]; then
    echo "OK  $contract  $address"
  else
    echo "BAD $contract  $address"
  fi
}
```

## 1. Verify the ERC-1967 Proxy Topology

For each proxy, confirm:
- proxy runtime bytecode matches OpenZeppelin `TransparentUpgradeableProxy`
- ERC-1967 admin slot matches the committed proxy admin
- ERC-1967 implementation slot matches the deployed implementation

Check the proxy runtime bytecode:

```bash
compare_runtime "$ETH_MAINNET_RPC_URL" "$MAINNET_SENDER_PROXY" "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"
compare_runtime "$ETH_MAINNET_RPC_URL" "$MAINNET_TRANSPORT_PROXY" "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"
compare_runtime "$XDC_RPC_URL" "$XDC_STATESTORE_PROXY" "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"
compare_runtime "$XDC_RPC_URL" "$XDC_RECEIVER_PROXY" "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"
compare_runtime "$XDC_RPC_URL" "$XDC_RATE_ADAPTER_PROXY" "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"
```

Check the admin and implementation slots:

```bash
echo "Mainnet sender proxy admin:        $(slot_to_address "$MAINNET_SENDER_PROXY" "$ADMIN_SLOT" "$ETH_MAINNET_RPC_URL")"
echo "Mainnet sender proxy impl:         $(slot_to_address "$MAINNET_SENDER_PROXY" "$IMPLEMENTATION_SLOT" "$ETH_MAINNET_RPC_URL")"

echo "Mainnet transport proxy admin:     $(slot_to_address "$MAINNET_TRANSPORT_PROXY" "$ADMIN_SLOT" "$ETH_MAINNET_RPC_URL")"
echo "Mainnet transport proxy impl:      $(slot_to_address "$MAINNET_TRANSPORT_PROXY" "$IMPLEMENTATION_SLOT" "$ETH_MAINNET_RPC_URL")"

echo "XDC state store proxy admin:       $(slot_to_address "$XDC_STATESTORE_PROXY" "$ADMIN_SLOT" "$XDC_RPC_URL")"
echo "XDC state store proxy impl:        $(slot_to_address "$XDC_STATESTORE_PROXY" "$IMPLEMENTATION_SLOT" "$XDC_RPC_URL")"

echo "XDC receiver proxy admin:          $(slot_to_address "$XDC_RECEIVER_PROXY" "$ADMIN_SLOT" "$XDC_RPC_URL")"
echo "XDC receiver proxy impl:           $(slot_to_address "$XDC_RECEIVER_PROXY" "$IMPLEMENTATION_SLOT" "$XDC_RPC_URL")"

echo "XDC rate adapter proxy admin:      $(slot_to_address "$XDC_RATE_ADAPTER_PROXY" "$ADMIN_SLOT" "$XDC_RPC_URL")"
echo "XDC rate adapter proxy impl:       $(slot_to_address "$XDC_RATE_ADAPTER_PROXY" "$IMPLEMENTATION_SLOT" "$XDC_RPC_URL")"
```

Expected values:

```text
Mainnet sender proxy admin        0xb4e7A08A791f7A7bcd135c628211931D57C73C2E
Mainnet sender proxy impl         0x7FC4e96e0D2D5918924B92bC6f960F951354B00c

Mainnet transport proxy admin     0xfc57516e6d2F3924DfF6f5D0c042f0c9df0d383A
Mainnet transport proxy impl      0x7971F0dDC51F59496FaD4e012e35DF5ee1Acd203

XDC state store proxy admin       0x63eFe570352523f8a0F2E6658Dc1907598248953
XDC state store proxy impl        0x4e077cA5dEe2d965595b73beE36856486aC18a75

XDC receiver proxy admin          0x6fc2023829C8C8e6b9C9e8Cb3c13bAd1545dbDc3
XDC receiver proxy impl           0x3649638CC74F2e417563B5840dFD8A010BfE33a8

XDC rate adapter proxy admin      0xC7Ffca6D884c4b447E321496af1a0bc550d315e2
XDC rate adapter proxy impl       0x0f4398aDFa8Fc8451F262E6180Ee697bc4Ba7a90
```

## 2. Verify ProxyAdmin Contracts

Each TransparentUpgradeableProxy deploys a dedicated `ProxyAdmin`. Verify:
- runtime bytecode matches OpenZeppelin `ProxyAdmin`
- `owner()` is the expected timelock

```bash
compare_runtime "$ETH_MAINNET_RPC_URL" 0xb4e7A08A791f7A7bcd135c628211931D57C73C2E "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin"
compare_runtime "$ETH_MAINNET_RPC_URL" 0xfc57516e6d2F3924DfF6f5D0c042f0c9df0d383A "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin"
compare_runtime "$XDC_RPC_URL" 0x63eFe570352523f8a0F2E6658Dc1907598248953 "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin"
compare_runtime "$XDC_RPC_URL" 0x6fc2023829C8C8e6b9C9e8Cb3c13bAd1545dbDc3 "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin"
compare_runtime "$XDC_RPC_URL" 0xC7Ffca6D884c4b447E321496af1a0bc550d315e2 "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin"
```

Check owners:

```bash
cast call 0xb4e7A08A791f7A7bcd135c628211931D57C73C2E "owner()(address)" --rpc-url "$ETH_MAINNET_RPC_URL"
cast call 0xfc57516e6d2F3924DfF6f5D0c042f0c9df0d383A "owner()(address)" --rpc-url "$ETH_MAINNET_RPC_URL"
cast call 0x63eFe570352523f8a0F2E6658Dc1907598248953 "owner()(address)" --rpc-url "$XDC_RPC_URL"
cast call 0x6fc2023829C8C8e6b9C9e8Cb3c13bAd1545dbDc3 "owner()(address)" --rpc-url "$XDC_RPC_URL"
cast call 0xC7Ffca6D884c4b447E321496af1a0bc550d315e2 "owner()(address)" --rpc-url "$XDC_RPC_URL"
```

Expected owners:

```text
0xb4e7... -> 0xA7aDbC2101F3503841Ab6FE5bDB8e480e2902D21
0xfc57... -> 0x9CB00E129d1BBf6baB6d3bE661602Ab3f1C38707
0x63eF... -> 0x200940DC5cE303Af2a53e13181CBCBAc96237a74
0x6fc2... -> 0x3656ce5F84B98fa3E0D5EdD4E47fd4771Cd80C6c
0xC7Ff... -> 0x5bA76aD2dbf0D7B53396F80328cEc5EAd3183Cfc
```

## 3. Verify TimelockController Contracts

Verify:
- runtime bytecode matches OpenZeppelin `TimelockController`
- `minDelay == 86400`
- `DEFAULT_ADMIN_ROLE`, `PROPOSER_ROLE`, and `EXECUTOR_ROLE` are held by the chain’s `OFT_OWNER`

Known `OFT_OWNER` values from [script/BaseData.s.sol](/home/claudeuser/source/yieldnest-state-relay/script/BaseData.s.sol):
- Ethereum mainnet: `0xfcad670592a3b24869C0b51a6c6FDED4F95D6975`
- XDC: `0x24D2486F5b2C2c225B6be8B4f72D46349cBf4458`

Compare runtime:

```bash
compare_runtime "$ETH_MAINNET_RPC_URL" 0xA7aDbC2101F3503841Ab6FE5bDB8e480e2902D21 "@openzeppelin/contracts/governance/TimelockController.sol:TimelockController"
compare_runtime "$ETH_MAINNET_RPC_URL" 0x9CB00E129d1BBf6baB6d3bE661602Ab3f1C38707 "@openzeppelin/contracts/governance/TimelockController.sol:TimelockController"
compare_runtime "$XDC_RPC_URL" 0x200940DC5cE303Af2a53e13181CBCBAc96237a74 "@openzeppelin/contracts/governance/TimelockController.sol:TimelockController"
compare_runtime "$XDC_RPC_URL" 0x3656ce5F84B98fa3E0D5EdD4E47fd4771Cd80C6c "@openzeppelin/contracts/governance/TimelockController.sol:TimelockController"
compare_runtime "$XDC_RPC_URL" 0x5bA76aD2dbf0D7B53396F80328cEc5EAd3183Cfc "@openzeppelin/contracts/governance/TimelockController.sol:TimelockController"
```

Check delay:

```bash
cast call 0xA7aDbC2101F3503841Ab6FE5bDB8e480e2902D21 "getMinDelay()(uint256)" --rpc-url "$ETH_MAINNET_RPC_URL"
cast call 0x9CB00E129d1BBf6baB6d3bE661602Ab3f1C38707 "getMinDelay()(uint256)" --rpc-url "$ETH_MAINNET_RPC_URL"
cast call 0x200940DC5cE303Af2a53e13181CBCBAc96237a74 "getMinDelay()(uint256)" --rpc-url "$XDC_RPC_URL"
cast call 0x3656ce5F84B98fa3E0D5EdD4E47fd4771Cd80C6c "getMinDelay()(uint256)" --rpc-url "$XDC_RPC_URL"
cast call 0x5bA76aD2dbf0D7B53396F80328cEc5EAd3183Cfc "getMinDelay()(uint256)" --rpc-url "$XDC_RPC_URL"
```

Check roles:

```bash
export DEFAULT_ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
export PROPOSER_ROLE=$(cast keccak "PROPOSER_ROLE")
export EXECUTOR_ROLE=$(cast keccak "EXECUTOR_ROLE")

cast call 0xA7aDbC2101F3503841Ab6FE5bDB8e480e2902D21 "hasRole(bytes32,address)(bool)" "$DEFAULT_ADMIN_ROLE" 0xfcad670592a3b24869C0b51a6c6FDED4F95D6975 --rpc-url "$ETH_MAINNET_RPC_URL"
cast call 0xA7aDbC2101F3503841Ab6FE5bDB8e480e2902D21 "hasRole(bytes32,address)(bool)" "$PROPOSER_ROLE" 0xfcad670592a3b24869C0b51a6c6FDED4F95D6975 --rpc-url "$ETH_MAINNET_RPC_URL"
cast call 0xA7aDbC2101F3503841Ab6FE5bDB8e480e2902D21 "hasRole(bytes32,address)(bool)" "$EXECUTOR_ROLE" 0xfcad670592a3b24869C0b51a6c6FDED4F95D6975 --rpc-url "$ETH_MAINNET_RPC_URL"
```

Repeat the same pattern for the other timelocks.

## 4. Verify Implementation Runtime Bytecode

### 4.1 Contracts without constructor immutables

These can be verified by direct runtime bytecode comparison:
- `StateSender`
- `StateStore`
- `RateAdapterUpgradeable`

```bash
compare_runtime "$ETH_MAINNET_RPC_URL" 0x7FC4e96e0D2D5918924B92bC6f960F951354B00c "src/StateSender.sol:StateSender"
compare_runtime "$XDC_RPC_URL" 0x4e077cA5dEe2d965595b73beE36856486aC18a75 "src/StateStore.sol:StateStore"
compare_runtime "$XDC_RPC_URL" 0x0f4398aDFa8Fc8451F262E6180Ee697bc4Ba7a90 "src/adapter/RateAdapterUpgradeable.sol:RateAdapterUpgradeable"
```

### 4.2 Contracts with constructor immutables

These embed the LayerZero endpoint in deployed runtime, so direct `forge inspect ... deployedBytecode` comparison is not sufficient:
- `LayerZeroSenderTransport`
- `LayerZeroReceiverTransport`

Use source verification with the exact constructor arguments instead.

Known constructor args:
- Ethereum mainnet sender transport implementation constructor:
  - endpoint: `0x1a44076050125825900e736c501f859c50fE728c`
- XDC receiver transport implementation constructor:
  - endpoint: `0xcb566e3B6934Fa77258d68ea18E931fa75e1aaAa`

Verify on explorer:

```bash
forge verify-contract \
  --chain 1 \
  --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  0x7971F0dDC51F59496FaD4e012e35DF5ee1Acd203 \
  src/layerzero/LayerZeroSenderTransport.sol:LayerZeroSenderTransport \
  --constructor-args $(cast abi-encode "constructor(address)" 0x1a44076050125825900e736c501f859c50fE728c)
```

```bash
forge verify-contract \
  --chain 50 \
  --verifier etherscan \
  --verifier-url "$ETHERSCAN_VERIFIER_URL_XDC" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  0x3649638CC74F2e417563B5840dFD8A010BfE33a8 \
  src/layerzero/LayerZeroReceiverTransport.sol:LayerZeroReceiverTransport \
  --constructor-args $(cast abi-encode "constructor(address)" 0xcb566e3B6934Fa77258d68ea18E931fa75e1aaAa)
```

## 5. Verify Proxy Constructor Arguments

The committed broadcast artifacts contain the exact constructor args used for each proxy:
- [broadcast/1_DeployStateRelaySenders.s.sol/1/run-latest.json](/home/claudeuser/source/yieldnest-state-relay/broadcast/1_DeployStateRelaySenders.s.sol/1/run-latest.json)
- [broadcast/2_DeployStateRelayDestination.s.sol/50/run-latest.json](/home/claudeuser/source/yieldnest-state-relay/broadcast/2_DeployStateRelayDestination.s.sol/50/run-latest.json)
- [broadcast/1_DeployRateAdapter.s.sol/50/run-latest.json](/home/claudeuser/source/yieldnest-state-relay/broadcast/1_DeployRateAdapter.s.sol/50/run-latest.json)

The proxy constructor signature is:

```solidity
constructor(address _logic, address initialOwner, bytes memory _data)
```

### Mainnet `LayerZeroSenderTransport` proxy

```bash
forge verify-contract \
  --chain 1 \
  --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  0xDABE0aae5Dc98068963a49C63fF56144DB6FBBE8 \
  @openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy \
  --constructor-args $(cast abi-encode "constructor(address,address,bytes)" \
    0x7971F0dDC51F59496FaD4e012e35DF5ee1Acd203 \
    0x9CB00E129d1BBf6baB6d3bE661602Ab3f1C38707 \
    0xc4d66de80000000000000000000000004c51ce7b2546e18449fbe16738a8d55bc195a4dd)
```

### Mainnet `StateSender` proxy

```bash
forge verify-contract \
  --chain 1 \
  --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  0xD2854219263BF681a8E11c41b05ae3f1a08f5D94 \
  @openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy \
  --constructor-args $(cast abi-encode "constructor(address,address,bytes)" \
    0x7FC4e96e0D2D5918924B92bC6f960F951354B00c \
    0xA7aDbC2101F3503841Ab6FE5bDB8e480e2902D21 \
    0xfe2357ba000000000000000000000000fcad670592a3b24869c0b51a6c6fded4f95d6975000000000000000000000000dabe0aae5dc98068963a49c63ff56144db6fbbe800000000000000000000000001ba69727e2860b37bc1a2bd56999c1afb4c15d800000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002407a2d13a0000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000")
```

### XDC `LayerZeroReceiverTransport` proxy

```bash
forge verify-contract \
  --chain 50 \
  --verifier etherscan \
  --verifier-url "$ETHERSCAN_VERIFIER_URL_XDC" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  0xa031Dfe64aD016E3475007BEb6dbE632B83CDc01 \
  @openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy \
  --constructor-args $(cast abi-encode "constructor(address,address,bytes)" \
    0x3649638CC74F2e417563B5840dFD8A010BfE33a8 \
    0x3656ce5F84B98fa3E0D5EdD4E47fd4771Cd80C6c \
    0xc4d66de80000000000000000000000004c51ce7b2546e18449fbe16738a8d55bc195a4dd)
```

### XDC `StateStore` proxy

```bash
forge verify-contract \
  --chain 50 \
  --verifier etherscan \
  --verifier-url "$ETHERSCAN_VERIFIER_URL_XDC" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  0xe4A68709601F0d67d2333F6fEA0b9518eA25C897 \
  @openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy \
  --constructor-args $(cast abi-encode "constructor(address,address,bytes)" \
    0x4e077cA5dEe2d965595b73beE36856486aC18a75 \
    0x200940DC5cE303Af2a53e13181CBCBAc96237a74 \
    0x946d920400000000000000000000000024d2486f5b2c2c225b6be8b4f72d46349cbf445800000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000001000000000000000000000000a031dfe64ad016e3475007beb6dbe632b83cdc01)
```

### XDC `RateAdapterUpgradeable` proxy

```bash
forge verify-contract \
  --chain 50 \
  --verifier etherscan \
  --verifier-url "$ETHERSCAN_VERIFIER_URL_XDC" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  0xc25e5331C8523eAb0F09166B506B865Ad3E3Bb43 \
  @openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy \
  --constructor-args $(cast abi-encode "constructor(address,address,bytes)" \
    0x0f4398aDFa8Fc8451F262E6180Ee697bc4Ba7a90 \
    0x5bA76aD2dbf0D7B53396F80328cEc5EAd3183Cfc \
    0xfc87348400000000000000000000000024d2486f5b2c2c225b6be8b4f72d46349cbf4458000000000000000000000000e4a68709601f0d67d2333f6fea0b9518ea25c897e4ebad80baaf4b323a39ec6d02d64b5e0bfa5a02d892aa432ce2dae72f654ef20000000000000000000000000000000000000000000000000000000000093a800000000000000000000000000000000000000000000000000000000000093a80000000000000000000000000000000000000000000000000000000000003f480000000000000000000000000000000000000000000000000000000e8d4a5100000000000000000000000000000000000000000000000000000000000000dbba000000000000000000000000000000000000000000000000000000000001e8480)
```

## 6. Verify Timelock Constructor Arguments

The timelock constructor signature is:

```solidity
constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
```

The committed deployment used:
- `minDelay = 86400`
- `proposers = [OFT_OWNER]`
- `executors = [OFT_OWNER]`
- `admin = OFT_OWNER`

Example, Ethereum mainnet sender proxy-admin timelock:

```bash
forge verify-contract \
  --chain 1 \
  --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  0xA7aDbC2101F3503841Ab6FE5bDB8e480e2902D21 \
  @openzeppelin/contracts/governance/TimelockController.sol:TimelockController \
  --constructor-args $(cast abi-encode "constructor(uint256,address[],address[],address)" \
    86400 \
    "[0xfcad670592a3b24869C0b51a6c6FDED4F95D6975]" \
    "[0xfcad670592a3b24869C0b51a6c6FDED4F95D6975]" \
    0xfcad670592a3b24869C0b51a6c6FDED4F95D6975)
```

Repeat with the exact addresses listed in the broadcast artifacts for the remaining timelocks.

## 7. Verify the Functional Wiring

The verify scripts in this repo check the deployment wiring beyond raw bytecode:

```bash
forge script --sig "run(string,string)" \
  --rpc-url "$ETH_MAINNET_RPC_URL" \
  script/deploy/6_VerifyStateRelay.s.sol:VerifyStateRelay \
  script/inputs/mainnet-xdc-ynrwax.json ""
```

```bash
forge script --sig "run(string,string)" \
  --rpc-url "$XDC_RPC_URL" \
  script/deploy/6_VerifyStateRelay.s.sol:VerifyStateRelay \
  script/inputs/mainnet-xdc-ynrwax.json ""
```

```bash
forge script --sig "run(string,string,string)" \
  --rpc-url "$XDC_RPC_URL" \
  script/deploy/adapters/2_VerifyRateAdapter.s.sol:VerifyRateAdapter \
  script/inputs/mainnet-xdc-ynrwax.json "" "mainnet-ynrwax-convertToAssets"
```

These scripts verify:
- proxy admin and timelock ownership
- LayerZero peer config
- DVN / executor / delegate config
- `StateStore` writer binding
- adapter state store / key / bounds / staleness config

They are not a substitute for bytecode verification, but they are useful as a second pass.

## 8. Recommended Verification Order

For an independent third-party verifier, the most practical order is:

1. Check out this repo revision and run `forge build`.
2. Verify proxy runtime bytecode for all 5 proxies.
3. Read the ERC-1967 admin and implementation slots and confirm they match the committed deployment JSON.
4. Verify all 5 `ProxyAdmin` runtimes and confirm each `owner()` matches the committed timelock address.
5. Verify all 5 timelock runtimes, `minDelay`, and `OFT_OWNER` roles.
6. Verify `StateSender`, `StateStore`, and `RateAdapterUpgradeable` implementation runtimes by direct comparison.
7. Verify `LayerZeroSenderTransport` and `LayerZeroReceiverTransport` implementations with exact constructor arguments.
8. Verify each proxy constructor with the exact init calldata from the committed broadcast artifacts.
9. Run the repo’s verify scripts on both chains.

If all of those checks pass, a third party has strong evidence that:
- the deployed bytecode matches this repo
- the proxy topology matches the committed artifacts
- the timelock/admin ownership is correct
- the LayerZero route configuration is wired as intended
