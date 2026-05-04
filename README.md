# YieldNest State Relay

Minimal cross-chain state relay using LayerZero V2 (OApp): relay bytes-encoded state from a source chain to one or more destination chains. Initial use case: ynETHx exchange rate from Ethereum to Arbitrum.

## Setup

### Dependencies

```bash
forge install LayerZero-Labs/devtools
forge install LayerZero-Labs/LayerZero-v2
forge install OpenZeppelin/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
git submodule add https://github.com/GNSPS/solidity-bytes-utils.git lib/solidity-bytes-utils
git submodule update --init --recursive
```

Remappings are in `foundry.toml`. If your `lib/` folder names differ (e.g. `layerzero-v2` vs `LayerZero-v2`), adjust the `@layerzerolabs/lz-evm-*` paths accordingly.

### Build & test

```bash
forge build
forge test --rpc-url <MAINNET_RPC>
# Without a mainnet `--rpc-url` and `ARBITRUM_RPC` in `.env`, exclude fork suites:
# forge test --no-match-contract StateRelayFork
```

**Fork + LZ test helper** (`TestHelperOz5` mocks delivery; fork is for real on-chain staticcalls):

```bash
forge test --match-contract StateRelayFork --rpc-url <MAINNET_RPC>
```

Fork tests **require** a mainnet RPC passed via **`--rpc-url`** and **`ARBITRUM_RPC`** in `.env` for the multi-fork test (no baked-in public fallback). Use **stable URLs** (provider + API key). Errors like `failed to get storage`, `upstream connect error`, or `cannot parse json-rpc response` mean the RPC dropped or returned garbage—not a contract bug. To skip forks: `forge test --no-match-contract StateRelayFork`. See `.env.example`.

- **`StateRelayForkMainnetTest`**: `StateSender` reads mainnet ynETHx `convertToAssets`; LZ helper delivers to `MessageSink`.
- **`StateRelayForkMainnetToArbitrumTest`**: same mainnet `convertToAssets` read, then **Arbitrum fork** `StateStore` + `StateReceiver` (harness) + `RateAdapter` — L1 rate → L2 store (no L2 vault read; Arbitrum ynETHx `convertToAssets` reverts in practice).

## Deployment sequence (`script/deploy/`)

Run with the same `script/inputs/<relay>.json` as first argument; deployment addresses merge into `deployments/<name>-<version>.json` under `chains.<chainId>`.

Current input schema uses:
- `deployer`: the broadcaster/operator address
- `receiverChainId`: the destination chain
- `senders.<label>`: source-chain read definitions

The scripts use Foundry's active broadcaster (`--account`, `--sender`, ledger, keystore, etc.) and require that the active broadcaster address matches `.deployer` in the input JSON.

Deployment flow:
1. **`1_DeployStateRelaySenders`** — deploy `StateSender` + sender transport on each source chain.
2. **`2_DeployStateRelayDestination`** — deploy destination receiver + `StateStore` on `receiverChainId`.
3. **`3_ConfigureStateRelaySenders`** — configure sender transport peers and LayerZero send-side settings.
4. **`4_ConfigureStateRelayReceiver`** — configure receiver peers and LayerZero receive-side settings.
5. **`5_TransferStateRelayOwnership`** (optional) — hand receiver/transport control from the deployer to `BaseData` `OFT_OWNER`.
6. **`6_VerifyStateRelay`** — verify the current per-chain deployment and print any missing remaining steps.

## Example: `mainnet-xdc-ynrwax`

Input file:
- [script/inputs/mainnet-xdc-ynrwax.json](script/inputs/mainnet-xdc-ynrwax.json)

Before running:
- update `.deployer` in that file so it matches the broadcaster address you will actually use
- make sure your `.env` contains:

```bash
ETH_MAINNET_RPC_URL=...
XDC_RPC_URL=...
DEPLOYER=0xYourBroadcasterAddress
ACCOUNT=your-foundry-account-alias
```

Load the `.env` first:

```bash
cd /home/claudeuser/source/yieldnest-state-relay
set -a
source .env
set +a
```

Then run the deployment:

```bash
forge script --sig "run(string,string)" \
  --rpc-url "$ETH_MAINNET_RPC_URL" \
  --account "$ACCOUNT" \
  --sender "$DEPLOYER" \
  --broadcast \
  script/deploy/1_DeployStateRelaySenders.s.sol:DeployStateRelaySenders \
  script/inputs/mainnet-xdc-ynrwax.json ""
```

```bash
forge script --sig "run(string,string)" \
  --rpc-url "$XDC_RPC_URL" \
  --account "$ACCOUNT" \
  --sender "$DEPLOYER" \
  --broadcast \
  script/deploy/2_DeployStateRelayDestination.s.sol:DeployStateRelayDestination \
  script/inputs/mainnet-xdc-ynrwax.json ""
```

```bash
forge script --sig "run(string,string)" \
  --rpc-url "$ETH_MAINNET_RPC_URL" \
  --account "$ACCOUNT" \
  --sender "$DEPLOYER" \
  --broadcast \
  script/deploy/3_ConfigureStateRelaySenders.s.sol:ConfigureStateRelaySenders \
  script/inputs/mainnet-xdc-ynrwax.json ""
```

```bash
forge script --sig "run(string,string)" \
  --rpc-url "$XDC_RPC_URL" \
  --account "$ACCOUNT" \
  --sender "$DEPLOYER" \
  --broadcast \
  script/deploy/4_ConfigureStateRelayReceiver.s.sol:ConfigureStateRelayReceiver \
  script/inputs/mainnet-xdc-ynrwax.json ""
```

Optional final handoff:

```bash
forge script --sig "run(string,string)" \
  --rpc-url "$ETH_MAINNET_RPC_URL" \
  --account "$ACCOUNT" \
  --sender "$DEPLOYER" \
  --broadcast \
  script/deploy/5_TransferStateRelayOwnership.s.sol:TransferStateRelayOwnership \
  script/inputs/mainnet-xdc-ynrwax.json ""
```

```bash
forge script --sig "run(string,string)" \
  --rpc-url "$XDC_RPC_URL" \
  --account "$ACCOUNT" \
  --sender "$DEPLOYER" \
  --broadcast \
  script/deploy/5_TransferStateRelayOwnership.s.sol:TransferStateRelayOwnership \
  script/inputs/mainnet-xdc-ynrwax.json ""
```

Verification:

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

Default deployment artifact path for this input:
- `deployments/mainnet-xdc-ynrwax-v0.1.0.json`

### Commands

Send the latest source-chain value through the deployed permissionless sender:

```bash
forge script --sig "run(string,string,string)" \
  --rpc-url "$ETH_MAINNET_RPC_URL" \
  --account "$ACCOUNT" \
  --sender "$DEPLOYER" \
  --broadcast \
  script/commands/SendState.s.sol:SendStateCommand \
  script/inputs/mainnet-xdc-ynrwax.json "" "mainnet-ynrwax-convertToAssets"
```

Read the latest destination-side stored value for that sender label, decoded as `uint256`:

```bash
forge script --sig "run(string,string,string)" \
  --rpc-url "$XDC_RPC_URL" \
  script/commands/ReadStateAsUint256.s.sol:ReadStateAsUint256Command \
  script/inputs/mainnet-xdc-ynrwax.json "" "mainnet-ynrwax-convertToAssets"
```

## Peer configuration

- Source chain: set peer `(dstEid, receiver transport proxy address)` on the sender transport for each destination.
- Destination chain: set peer `(srcEid, sender transport proxy address)` on the receiver transport.
- StateStore: grant `WRITER_ROLE` to the receiver transport so only delivered messages can write.

## Forked Anvil (optional)

Use a **forked** Anvil only to **dry-run or broadcast deploy scripts** against a real `chainid` / `BaseData` LZ addresses. **This does not relay LayerZero messages between two Anvil instances** — use `forge test` + **TestHelperOz5** for that.

RPC URLs: `.env.example` → `.env` (`ARBITRUM_RPC`); mainnet fork tests take their RPC from `forge test --rpc-url <MAINNET_RPC>`. Forked Anvil: set **`RPC_MAINNET`** / **`RPC_ARBITRUM`** to the HTTP URLs that report chain ids **1** and **42161** (e.g. local Anvil ports), and use **`--with-gas-price 1gwei`** with `--broadcast` if needed (see [docs/ANVIL_FORK.md](docs/ANVIL_FORK.md)).

## Message schema

See proposal: versioned payload `(version, key, value, srcTimestamp)`. Receivers ignore unsupported versions.

## Multi-chain expansion

To add a new destination: deploy StateReceiver + StateStore on that chain, configure LZ peers, authorize receiver as writer on StateStore.
