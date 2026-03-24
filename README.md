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
forge test
# Without `ETH_MAINNET_RPC` / `ARBITRUM_RPC` in `.env`, exclude fork suites:
# forge test --no-match-contract StateRelayFork
```

**Fork + LZ test helper** (`TestHelperOz5` mocks delivery; fork is for real on-chain staticcalls):

```bash
forge test --match-contract StateRelayFork
```

Fork tests **require** **`ETH_MAINNET_RPC`** and **`ARBITRUM_RPC`** in `.env` (no baked-in public fallback). Use **stable URLs** (provider + API key). Errors like `failed to get storage`, `upstream connect error`, or `cannot parse json-rpc response` mean the RPC dropped or returned garbage—not a contract bug. To skip forks: `forge test --no-match-contract StateRelayFork`. See `.env.example`.

- **`StateRelayForkMainnetTest`**: `StateSender` reads mainnet ynETHx `convertToAssets`; LZ helper delivers to `MessageSink`.
- **`StateRelayForkMainnetToArbitrumTest`**: same mainnet `convertToAssets` read, then **Arbitrum fork** `StateStore` + `StateReceiver` (harness) + `RateAdapter` — L1 rate → L2 store (no L2 vault read; Arbitrum ynETHx `convertToAssets` reverts in practice).

## Deployment sequence

1. Deploy **StateStore** (implementation + TransparentUpgradeableProxy) on each destination chain.
2. Deploy **StateReceiver** (implementation + proxy) on each destination; set StateStore and add receiver as writer on StateStore.
3. Deploy **StateSender** (implementation + proxy) on the source chain.
4. Configure LayerZero peers (StateSender <-> StateReceiver per path) and optional multi-destination helper.

(Details and chain-specific RPC/keys to be filled when deploying to mainnet/testnet.)

## Peer configuration

- Source chain: set peer `(dstEid, StateReceiver proxy address)` on StateSender for each destination.
- Destination chain: set peer `(srcEid, StateSender proxy address)` on StateReceiver.
- StateStore: `setWriter(StateReceiver proxy, true)` so only LZ-delivered messages can write.

## Forked Anvil (optional)

Use a **forked** Anvil only to **dry-run or broadcast deploy scripts** against a real `chainid` / `BaseData` LZ addresses. **This does not relay LayerZero messages between two Anvil instances** — use `forge test` + **TestHelperOz5** for that.

RPC URLs: `.env.example` → `.env` (`ETH_MAINNET_RPC`, `ARBITRUM_RPC`). See [docs/ANVIL_FORK.md](docs/ANVIL_FORK.md).

## Deploy script

Deploys StateStore implementation + proxy (validates `PRIVATE_KEY` and RPC):

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url <RPC_URL> --broadcast
```

Set `PRIVATE_KEY` in env or pass `--private-key`.

## Message schema

See proposal: versioned payload `(version, key, value, srcTimestamp)`. Receivers ignore unsupported versions.

## Multi-chain expansion

To add a new destination: deploy StateReceiver + StateStore on that chain, configure LZ peers, authorize receiver as writer on StateStore.
