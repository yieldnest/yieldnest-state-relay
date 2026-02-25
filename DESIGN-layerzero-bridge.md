# DESIGN: LayerZero State Relay Bridge

## 1. Overview

A minimal cross-chain state relay system that uses **LayerZero V2** to push arbitrary state values (encoded as `bytes`) from a source EVM chain to one or more destination EVM chains. The primary use case is bridging the **ynETHx exchange rate** from Ethereum L1 to Arbitrum, but the design is generalized for any `bytes`-encodable value (numbers, arrays, structs).

The system is designed around three principles:
1. **Simplicity** -- minimal contracts, minimal moving parts
2. **Forkability** -- lean heavily on existing audited code (LayerZero OApp, Centrifuge adapter pattern)
3. **Extensibility** -- other bridge adapters can be plugged in later without touching core logic

---

## 2. Architecture

```
 SOURCE CHAIN (e.g. Ethereum L1)              DESTINATION CHAIN (e.g. Arbitrum)
 ┌──────────────────────────────┐              ┌──────────────────────────────────┐
 │                              │              │                                  │
 │  Keeper / EOA / Automation   │              │                                  │
 │         │                    │              │                                  │
 │         ▼                    │              │                                  │
 │  ┌─────────────────┐        │   LayerZero  │  ┌──────────────────────┐        │
 │  │  StateSender   │────────┼──────────────┼─▶│   StateReceiver     │        │
 │  │  (OApp)         │        │   V2 Message │  │   (OApp)             │        │
 │  └─────────────────┘        │              │  └──────────┬───────────┘        │
 │                              │              │             │                    │
 │                              │              │             ▼                    │
 │                              │              │  ┌──────────────────────┐        │
 │                              │              │  │  StateStore         │        │
 │                              │              │  │  (key => value)      │        │
 │                              │              │  └──────────┬───────────┘        │
 │                              │              │             │                    │
 │                              │              │             ▼                    │
 │                              │              │  ┌──────────────────────┐        │
 │                              │              │  │  RateAdapter         │        │
 │                              │              │  │  (e.g. for Curve)    │        │
 │                              │              │  └──────────────────────┘        │
 └──────────────────────────────┘              └──────────────────────────────────┘
```

### Component Summary

| Contract | Chain | Responsibility |
|---|---|---|
| **StateSender** | Source | Encodes state values and sends them via LayerZero V2 |
| **StateReceiver** | Destination | Receives LayerZero messages and writes to StateStore |
| **StateStore** | Destination | Key-value store for bridged state values with timestamps |
| **RateAdapter** | Destination | Thin adapter presenting stored values to consumers (e.g. Curve pools) |

---

## 3. Contract Design

### 3.1 Key Derivation

State keys are **deterministic hashes** derived from the source contract and calldata:

```solidity
key = keccak256(abi.encode(target, callData))
```

The key is not assigned or registered — it is a fingerprint of exactly what on-chain value is being read. Anyone can trigger a push for any key. Since the value is always read via `staticcall(target, callData)`, the caller controls *when* but not *what*. There is no spoofing risk because the value is read on-chain at push time.

Trust is established at the **destination**, not the source. The RateAdapter (or any consumer) is deployed with a specific `stateKey`, which pins it to a specific `(target, callData)` pair. A malicious caller pointing at a different target contract produces a different key that no adapter reads.

**Example:**
```solidity
// ynETHx rate: target = ynETHx, callData = convertToAssets(1e18)
bytes memory callData = abi.encodeCall(IERC4626.convertToAssets, (1e18));
bytes32 key = keccak256(abi.encode(ynETHx, callData));
// key deterministically represents "ynETHx.convertToAssets(1e18)"
```

| Property | Benefit |
|---|---|
| **Deterministic** | Key is derived, not assigned. No admin call to bind key → source. |
| **Self-describing** | The key encodes exactly what on-chain value it represents. |
| **Collision-free** | Different targets or different calldata always produce different keys. |
| **Trust via target** | The target contract address is the trust boundary. Only a specific contract's return value is relayed for a given key. No access control needed — the source contract itself is the permission. |

### 3.2 Message Format

All state updates are encoded as a single message:

```solidity
bytes memory message = abi.encode(key, value, srcTimestamp);
```

| Field | Type | Description |
|---|---|---|
| `key` | `bytes32` | Derived key (see 3.1) |
| `value` | `bytes` | The state value, read via `staticcall` and abi-encoded |
| `srcTimestamp` | `uint64` | Source chain timestamp at time of read |

This is intentionally flat. No message type enum, no versioning overhead. One message = one state update.

### 3.3 StateSender

Inherits from LayerZero V2's `OApp`. Lives on the source chain.

The sender is **fully permissionless and value-constrained**. Anyone can trigger a push for any source, but the value is always read via `staticcall` — callers never supply it. The key is derived from `(target, callData)`, so trust is established by the target contract itself, not by access control on the sender.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { OApp, MessagingFee, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

contract StateSender is OApp {
    using OptionsBuilder for bytes;

    uint128 public dstGasLimit = 100_000;

    event StateSent(bytes32 indexed key, bytes value, uint32 dstEid);

    error SourceCallFailed();
    error ReceiveNotSupported();

    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) {}

    /// @notice Derive the key for a given source definition.
    function deriveKey(
        address target,
        bytes calldata callData
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, callData));
    }

    /// @notice Push a state value to a destination chain.
    ///         Anyone can call this. The value is read on-chain via staticcall, not caller-supplied.
    /// @param dstEid    LayerZero endpoint ID of destination chain.
    /// @param target    Source contract to read from.
    /// @param callData  Full calldata for the staticcall (selector + args).
    function sendState(
        uint32 dstEid,
        address target,
        bytes calldata callData
    ) external payable {
        bytes32 key = deriveKey(target, callData);
        bytes memory value = _readSource(target, callData);
        _send(dstEid, key, value);
    }

    /// @notice Quote the fee for sending a state value.
    function quoteSend(
        uint32 dstEid,
        address target,
        bytes calldata callData
    ) external view returns (uint256 nativeFee) {
        bytes32 key = deriveKey(target, callData);
        bytes memory value = _readSource(target, callData);
        return _quoteFee(dstEid, key, value);
    }

    /// @notice Owner can adjust destination gas limit.
    function setDstGasLimit(uint128 _gasLimit) external onlyOwner {
        dstGasLimit = _gasLimit;
    }

    function _readSource(address target, bytes calldata callData) internal view returns (bytes memory) {
        (bool ok, bytes memory result) = target.staticcall(callData);
        if (!ok) revert SourceCallFailed();
        return result;
    }

    function _send(uint32 dstEid, bytes32 key, bytes memory value) internal {
        bytes memory message = abi.encode(key, value, uint64(block.timestamp));
        bytes memory options = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(dstGasLimit, 0);

        _lzSend(dstEid, message, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit StateSent(key, value, dstEid);
    }

    function _quoteFee(uint32 dstEid, bytes32 key, bytes memory value) internal view returns (uint256) {
        bytes memory message = abi.encode(key, value, uint64(block.timestamp));
        bytes memory options = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(dstGasLimit, 0);

        MessagingFee memory fee = _quote(dstEid, message, options, false);
        return fee.nativeFee;
    }

    /// @dev Required by OApp but this contract only sends.
    function _lzReceive(
        Origin calldata, bytes32, bytes calldata, address, bytes calldata
    ) internal override {
        revert ReceiveNotSupported();
    }
}
```

**Key decisions:**
- **Value is always read via `staticcall`**, never caller-supplied. The target contract is the trust boundary — no access control needed on the sender.
- **Fully permissionless** -- anyone can trigger a push for any source. They control *when*, the target contract controls *what*.
- **No admin registration, no roles, no config** -- keys are derived at call time from `(target, callData)`. Zero admin surface beyond OApp peer configuration.
- Gas limit is configurable per-contract (not per-key) to keep it simple. 100k gas is ample for a SSTORE on the receiver side.
- No batching for now. Sending one key at a time keeps the code trivial. Batching can be added later if needed.

### 3.3 StateReceiver

Inherits from LayerZero V2's `OApp`. Lives on the destination chain. Writes received values to the `StateStore`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

interface IStateStore {
    function updateValue(bytes32 key, bytes calldata value, uint64 srcTimestamp) external;
}

contract StateReceiver is OApp {

    IStateStore public stateStore;

    event StateReceived(bytes32 indexed key, uint32 srcEid);

    constructor(
        address _endpoint,
        address _owner,
        address _stateStore
    ) OApp(_endpoint, _owner) {
        stateStore = IStateStore(_stateStore);
    }

    function setStateStore(address _stateStore) external onlyOwner {
        stateStore = IStateStore(_stateStore);
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override {
        (bytes32 key, bytes memory value, uint64 srcTimestamp) =
            abi.decode(_message, (bytes32, bytes, uint64));

        stateStore.updateValue(key, value, srcTimestamp);

        emit StateReceived(key, _origin.srcEid);
    }
}
```

**Key decisions:**
- The receiver does not interpret the value. It just passes through `bytes` to the store.
- The peer validation (ensuring the message comes from the trusted `StateSender`) is handled by OApp's built-in `_getPeerOrRevert` check in `lzReceive()`.
- StateStore is a separate contract so it can be shared by multiple receivers (future: when other bridge adapters are added).

### 3.4 StateStore

The central registry on the destination chain. Stores state values and enforces access control on who can write.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract StateStore is Ownable {

    struct StateValue {
        bytes value;          // Raw encoded value
        uint64 srcTimestamp;  // When the value was read on source chain
        uint64 updatedAt;     // When the value was written on this chain
    }

    mapping(bytes32 => StateValue) public values;
    mapping(address => bool) public writers;

    event ValueUpdated(bytes32 indexed key, uint64 srcTimestamp, uint64 updatedAt);
    event WriterSet(address indexed writer, bool allowed);

    error NotWriter();
    error StaleValue();

    constructor(address _owner) Ownable(_owner) {}

    modifier onlyWriter() {
        if (!writers[msg.sender]) revert NotWriter();
        _;
    }

    /// @notice Update an state value. Only callable by authorized writers.
    /// @dev Silently rejects values older than what's already stored (no revert to avoid
    ///      blocking LayerZero message queue if messages arrive out of order).
    function updateValue(
        bytes32 key,
        bytes calldata value,
        uint64 srcTimestamp
    ) external onlyWriter {
        if (srcTimestamp <= values[key].srcTimestamp) return; // stale, skip

        values[key] = StateValue({
            value: value,
            srcTimestamp: srcTimestamp,
            updatedAt: uint64(block.timestamp)
        });

        emit ValueUpdated(key, srcTimestamp, uint64(block.timestamp));
    }

    /// @notice Read a stored state value.
    function getValue(bytes32 key) external view returns (bytes memory value, uint64 srcTimestamp, uint64 updatedAt) {
        StateValue storage v = values[key];
        return (v.value, v.srcTimestamp, v.updatedAt);
    }

    function setWriter(address writer, bool allowed) external onlyOwner {
        writers[writer] = allowed;
        emit WriterSet(writer, allowed);
    }
}
```

**Key decisions:**
- **Staleness protection**: If a message arrives out of order, it's silently ignored (no revert). This is critical because reverting in `_lzReceive` would block the LayerZero message channel.
- **Writer pattern**: Only authorized addresses (the StateReceiver, or future bridge receivers) can write. This is the extensibility point for adding other bridges later.

### 3.5 RateAdapter (Example: Curve Pool Consumer)

A thin adapter that presents a stored state value in the interface expected by the consumer protocol.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStateStore {
    function getValue(bytes32 key) external view returns (bytes memory, uint64, uint64);
}

/// @notice Adapter that exposes a bridged state value as a rate for Curve pools
///         or other DeFi consumers. Implements a simple getRate() interface.
contract RateAdapter {

    IStateStore public immutable stateStore;
    bytes32 public immutable stateKey;
    uint64 public immutable maxStaleness; // seconds

    error StaleRate();

    constructor(address _stateStore, bytes32 _stateKey, uint64 _maxStaleness) {
        stateStore = IStateStore(_stateStore);
        stateKey = _stateKey;
        maxStaleness = _maxStaleness;
    }

    /// @notice Returns the bridged rate as uint256 (18 decimals).
    /// @dev Curve StableSwap-NG pools call this via raw_call with selector 0x679aefce.
    ///      Also compatible with Balancer IRateProvider.
    function getRate() external view returns (uint256) {
        (bytes memory value, uint64 srcTimestamp, ) = stateStore.getValue(stateKey);
        if (block.timestamp - srcTimestamp > maxStaleness) revert StaleRate();
        return abi.decode(value, (uint256));
    }
}
```

**Key decisions:**
- `getRate()` (selector `0x679aefce`) is the de-facto standard used by Curve StableSwap-NG (`_stored_rates` calls external oracles via `raw_call` with packed method_id + address) and Balancer (`IRateProvider`).
- **Staleness check**: The adapter reverts if the rate is older than `maxStaleness`. For a daily-pushed rate, set this to ~26 hours (93600 seconds) to allow for keeper timing variance.
- Immutable fields -- each adapter is deployed for a specific state key. No admin surface.

---

## 4. Keeper / Automation Strategy

### Option A: Simple Keeper (MVP)

An off-chain keeper (bot or multisig) calls `StateSender.sendState()` daily. The source definition is passed at call time — the StateSender reads the value on-chain and derives the key. The keeper decides *when* to push, not *what*.

```
1. Quote: StateSender.quoteSend(dstEid, ynETHx, callData)
2. Send:  StateSender.sendState{value: fee}(dstEid, ynETHx, callData)
```

**Pros**: Dead simple, easy to monitor.
**Cons**: Relies on an external keeper being up.

### Option B: Gelato / Chainlink Automation (Recommended)

Use [Chainlink Automation](https://automation.chain.link/) or [Gelato](https://www.gelato.network/) to trigger the push:

- **Trigger**: Time-based (every 24h) or deviation-based (>0.1% rate change)
- **Execution**: Calls `sendState` on the StateSender
- **Gas funding**: Automation service pays L1 gas; LayerZero fee comes from a pre-funded contract or is forwarded

A thin `AutomatedStatePusher` wraps a specific source definition for automation:

```solidity
contract AutomatedStatePusher {
    StateSender public immutable sender;
    address public immutable target;
    bytes public callData;
    uint32 public immutable dstEid;

    function push() external payable {
        uint256 fee = sender.quoteSend(dstEid, target, callData);
        sender.sendState{value: fee}(dstEid, target, callData);
    }

    receive() external payable {} // Accept ETH for gas funding
}
```

The pusher stores the source definition (target + callData) so automation services don't need to know it.

**Recommendation**: Start with Option A for launch, migrate to Option B once proven.

---

## 5. Extensibility: Plugging in Other Bridges

The `StateStore` writer pattern enables adding bridges beyond LayerZero without modifying any existing contract:

```
                                    ┌─────────────────┐
 LayerZero  ──▶  StateReceiver ──▶│                  │
                                    │   StateStore    │◀── RateAdapter (consumers)
 Axelar     ──▶  AxelarReceiver ──▶│   (writers[])    │
                                    │                  │
 Hyperlane  ──▶  HyperReceiver  ──▶│                  │
                                    └─────────────────┘
```

To add a new bridge:
1. Deploy a new receiver contract that implements the bridge's receive interface
2. Have it call `stateStore.updateValue(key, value, srcTimestamp)`
3. Call `stateStore.setWriter(newReceiver, true)`

No changes to StateStore, RateAdapter, or the LayerZero receiver.

Inspired by [Centrifuge's MultiAdapter pattern](https://github.com/centrifuge/protocol/blob/main/src/core/messaging/MultiAdapter.sol) but drastically simplified: we skip the quorum/threshold/voting mechanism since we don't need multi-bridge consensus for state values (a single trusted bridge path is sufficient for rate data).

---

## 6. Reference: Centrifuge Adapter Pattern (Code Attribution)

The adapter abstraction is inspired by Centrifuge's `IAdapter` interface:

```solidity
// From: https://github.com/centrifuge/protocol/blob/main/src/core/messaging/interfaces/IAdapter.sol
interface IAdapter {
    function send(uint16 chainId, bytes calldata payload, uint256 gasLimit, address refund)
        external payable returns (bytes32 adapterData);
    function estimate(uint16 chainId, bytes calldata payload, uint256 gasLimit)
        external view returns (uint256);
}
```

And Centrifuge's `LayerZeroAdapter`:
- [Source](https://github.com/centrifuge/protocol/blob/a59809faaca27909b4982aad6ad4548a2e1c4a04/src/adapters/LayerZeroAdapter.sol#L154)
- Wraps LayerZero V2 endpoint calls behind the `IAdapter` interface
- Handles EID ↔ chain ID mapping, peer (source/destination) configuration

Our design is intentionally simpler because we don't need Centrifuge's full multi-adapter voting system. We use LayerZero's native OApp pattern directly which gives us peer management, fee quoting, and message delivery out of the box.

---

## 7. LayerZero V2 Integration Details

### Dependencies

```
@layerzerolabs/oapp-evm           # OApp, OAppSender, OAppReceiver, OAppCore
@layerzerolabs/lz-evm-protocol-v2 # ILayerZeroEndpointV2, MessagingParams, MessagingFee
@openzeppelin/contracts            # Ownable
```

### Key LayerZero V2 Concepts Used

| Concept | Usage |
|---|---|
| **OApp** | Both StateSender and StateReceiver inherit from `OApp` which combines `OAppSender` + `OAppReceiver` + `OAppCore` |
| **Peer Configuration** | `setPeer(eid, bytes32(uint256(uint160(addr))))` -- must be set on both sender and receiver |
| **`_lzSend`** | Internal function on OAppSender: packs `MessagingParams`, pays fee, calls `endpoint.send()` |
| **`_lzReceive`** | Internal override on OAppReceiver: called by endpoint after DVN verification |
| **`_quote`** | View function to estimate the native fee before sending |
| **OptionsBuilder** | `OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0)` -- specifies destination gas |
| **EndpointV2** | Immutable protocol contract on each chain. Deployed by LayerZero. |

### Endpoint IDs (Mainnet)

| Chain | Endpoint ID | Endpoint Address |
|---|---|---|
| Ethereum | 30101 | `0x1a44076050125825900e736c501f859c50fE728c` |
| Arbitrum | 30110 | `0x1a44076050125825900e736c501f859c50fE728c` |

### Deployment Sequence

```
1. Deploy StateStore on Arbitrum
2. Deploy StateReceiver on Arbitrum (pass endpoint + store address)
3. Deploy StateSender on Ethereum (pass endpoint)
4. Call stateStore.setWriter(stateReceiver, true) on Arbitrum
5. Call stateSender.setPeer(30110, bytes32(uint256(uint160(stateReceiver)))) on Ethereum
6. Call stateReceiver.setPeer(30101, bytes32(uint256(uint160(stateSender)))) on Arbitrum
7. Derive key: stateSender.deriveKey(ynETHx, abi.encodeCall(IERC4626.convertToAssets, (1e18)))
8. Deploy RateAdapter on Arbitrum (pass store + derived key + maxStaleness)
9. Configure Curve pool to use RateAdapter address
```

---

## 8. Use Case: ynETHx Rate on Arbitrum

### Source Value

ynETHx is an ERC-4626 vault. The exchange rate is:

```solidity
uint256 rate = ynETHx.convertToAssets(1e18); // returns 18-decimal rate
```

### State Key (Derived)

The key is deterministically derived from the source contract and calldata. No arbitrary label needed:

```solidity
bytes memory callData = abi.encodeCall(IERC4626.convertToAssets, (1e18));
bytes32 YNETHX_ETH_RATE = keccak256(abi.encode(ynETHx, callData));
// This is a permissionless key — anyone can push it, value is always read on-chain.
```

### Push Frequency

- **Daily** for normal operations (rate changes slowly for staking vaults)
- **On-demand** if a significant rate change is detected

### Staleness Tolerance

- RateAdapter `maxStaleness`: **93600** seconds (26 hours)
- This allows a 2-hour buffer around a 24-hour push cycle

### Curve Integration

Curve StableSwap-NG pools call external rate oracles via `raw_call`:

```vyper
# In Curve's _stored_rates():
oracle_response: Bytes[32] = raw_call(
    convert(rate_oracles[i] % 2**160, address),   # RateAdapter address
    rate_oracles[i] & ORACLE_BIT_MASK,             # getRate() selector: 0x679aefce
    max_outsize=32,
    is_static_call=True,
)
```

The `RateAdapter.getRate()` function returns the bridged ynETHx rate as a `uint256`, which Curve reads as a 32-byte response. No additional adapter code is needed.

---

## 9. Security Considerations

### Transport Layer

| Concern | Mitigation |
|---|---|
| **Unauthorized cross-chain sender** | OApp peer validation: only the registered peer on the source chain can deliver messages. `_getPeerOrRevert` in `lzReceive()` enforces this. |
| **Replay / re-entrancy** | LayerZero V2 handles nonce management. StateStore update is a simple SSTORE with no external calls. |
| **Message ordering** | Not required. The `srcTimestamp` check in StateStore ensures only newer values are accepted regardless of arrival order. |
| **LayerZero liveness** | If LayerZero is down, rates go stale and the RateAdapter reverts, preventing trades at bad prices. This is the correct fail-safe behavior. |

### Key Derivation & Value Integrity

| Concern | Mitigation |
|---|---|
| **Fabricated value injection** | StateSender reads values via `staticcall` -- callers never supply the value. Both permissionless and permissioned modes enforce this. A caller cannot push an arbitrary `bytes` payload. |
| **Malicious target contract** | In permissionless mode, anyone can pass any `target` address. A malicious contract returning a fake value produces a **different derived key** than the legitimate source. Destination adapters are deployed with the legitimate key and will never read the attacker's key. The StateStore may accumulate garbage keys, but they are never consumed. |
| **Key collision / spoofing** | Keys are deterministic hashes of `(target, callData)`. Different targets or different calldata always produce different keys. No two sources can collide. |
| **Source contract manipulation** | The `staticcall` faithfully reads whatever the source returns. If the source contract's return value is manipulable (e.g. via flash loans, oracle manipulation, or reentrancy on the source), the relayed value will reflect that manipulation. **Mitigation**: Use sources that are resistant to atomic manipulation (e.g. ERC-4626 vaults with proper accounting, not AMM spot prices). For composed values, use a reader contract that incorporates TWAP or other smoothing. The bounded rate check in Amendment E provides an additional safety net on the destination. |

### Destination Side

| Concern | Mitigation |
|---|---|
| **Stale data** | RateAdapter reverts if `srcTimestamp` exceeds `maxStaleness`. See also Amendment B for adding a secondary `updatedAt` check to catch LayerZero delivery delays. |
| **Store writer compromise** | Owner can revoke writers via `setWriter(addr, false)`. The staleness check in RateAdapter limits the impact window of any bad writes. |
| **L2 timestamp reliability** | For L2 → L1 relay (reverse direction), `srcTimestamp` is set by `block.timestamp` on the L2, which the sequencer controls on optimistic rollups. Sequencers are constrained to within a few minutes of real time by protocol rules, but for high-value position data, the `updatedAt` secondary check (Amendment B) provides a chain-of-custody timestamp set by the L1 itself. |

---

## 10. Gas Estimates

| Operation | Estimated Gas | Notes |
|---|---|---|
| `StateSender.sendState` (L1) | ~85,000 + LZ fee | Includes staticcall to source + LZ fee varies by DVN config |
| `StateReceiver._lzReceive` (L2) | ~60,000 | abi.decode + SSTORE |
| `RateAdapter.getRate` (L2 view) | ~5,000 | Two SLOADs |

Destination gas limit of 100,000 provides comfortable headroom.

---

## 11. File Structure

```
src/
├── StateSender.sol          # Source chain: sends state values via LayerZero
├── StateReceiver.sol        # Dest chain: receives LZ messages, writes to store
├── StateStore.sol           # Dest chain: key-value store for state values
├── adapters/
│   └── RateAdapter.sol       # Dest chain: presents value to Curve/Balancer
├── automation/
│   └── AutomatedStatePusher.sol  # Optional: Gelato/Chainlink Automation wrapper
└── interfaces/
    └── IStateStore.sol      # Interface for StateStore
```

---

## 12. Testing Strategy

1. **Unit tests** (Foundry): Test each contract in isolation with mock LayerZero endpoints
2. **Integration tests**: Use LayerZero's [TestHelper](https://docs.layerzero.network/v2/developers/evm/tooling/test-helper) to simulate cross-chain message delivery in a single test
3. **Fork tests**: Fork Ethereum mainnet, read real ynETHx rate, send through mock LZ, verify Curve pool can read it
4. **Testnet deployment**: Deploy on Sepolia + Arbitrum Sepolia using LayerZero testnet endpoints (`0x6EDCE65403992e310A62460808c4b910D972f10f`)

---

## 13. Audit Scope

The minimal audit surface is:

| Contract | Lines (est.) | Notes |
|---|---|---|
| StateSender | ~70 | OApp, key derivation, staticcall reads |
| StateReceiver | ~30 | Thin wrapper over OApp._lzReceive |
| StateStore | ~60 | Simple SSTORE with timestamp check |
| RateAdapter | ~20 | Pure view, no state mutation |
| **Total** | **~180** | |

The OApp base contracts are already audited by LayerZero. Our custom code is ~180 lines of straightforward Solidity.

---

## 14. Future Considerations

- **Batch sending**: Send multiple keys in one LZ message to reduce per-message overhead
- **Multi-destination**: Push from L1 to multiple L2s in a single transaction (LayerZero's "Batch Send" pattern)
- **Additional bridges**: Deploy Axelar/Hyperlane receivers and add them as StateStore writers for redundancy
- **Quorum verification**: If multi-bridge consensus becomes necessary, add a lightweight quorum check in StateStore (inspired by Centrifuge's MultiAdapter threshold pattern)
- **Rate smoothing**: On-chain TWAP or bounded rate updates to mitigate state manipulation

---

## 15. Amendments

### Amendment A: Cross-Chain Yield Accounting via Reverse Relay

#### Problem

The doc's primary use case is L1 → L2 (pushing ynETHx rate to Arbitrum for Curve). However, the FlexStrategy use case introduces a reverse flow:

1. The FlexStrategy Safe moves assets **from the settlement chain to a sidechain**
2. Those assets are deployed into yield strategies on the sidechain (e.g. Arbitrum, Optimism)
3. Yield is earned on the sidechain
4. The **reward amount or position value must be relayed back** to the settlement chain so `AccountingModule.processRewards(amount)` can mint AccountingTokens and update the vault's NAV

#### Solution: Deploy the Same Contracts in Reverse

The existing `StateSender`, `StateReceiver`, and `StateStore` contracts are chain-agnostic. The relay infrastructure for L2 → L1 is simply a mirror deployment:

- Deploy `StateSender` on the **sidechain** (e.g. Arbitrum)
- Deploy `StateReceiver` + `StateStore` on the **settlement chain** (e.g. Ethereum L1)
- Configure peers bidirectionally
- Use an `AutomatedStatePusher` on the sidechain that reads the position value from the yield strategy (e.g. `IERC4626(vault).convertToAssets(shares)`) and relays it to L1

No new transport contracts are needed. The only net-new component is a **settlement-chain adapter** that consumes the relayed value and feeds it into the FlexStrategy's reward accounting.

```
 SIDECHAIN (e.g. Arbitrum)                    SETTLEMENT CHAIN (e.g. Ethereum L1)
 ┌──────────────────────────────┐              ┌────────────────────────────────────┐
 │                              │              │                                    │
 │  Yield Strategy (earning)    │              │                                    │
 │         │                    │              │                                    │
 │         ▼                    │              │                                    │
 │  ┌─────────────────────┐    │   LayerZero  │  ┌──────────────────────┐          │
 │  │  AutomatedState-    │    │              │  │   StateReceiver     │          │
 │  │  Pusher (reads vault)│    │   V2 Message │  │   (same OApp)       │          │
 │  └────────┬────────────┘    │              │  └──────────┬───────────┘          │
 │           │                  │              │             │                      │
 │           ▼                  │              │             ▼                      │
 │  ┌─────────────────────┐    │              │  ┌──────────────────────┐          │
 │  │  StateSender        │────┼──────────────┼─▶│  StateStore         │          │
 │  │  (same OApp)         │    │              │  │  (key => value)      │          │
 │  └─────────────────────┘    │              │  └──────────┬───────────┘          │
 │                              │              │             │                      │
 │                              │              │             ▼                      │
 │                              │              │  ┌──────────────────────┐          │
 │                              │              │  │  RewardRelayAdapter │ NEW      │
 │                              │              │  │  (delta → processR.) │          │
 │                              │              │  └──────────┬───────────┘          │
 │                              │              │             │                      │
 │                              │              │             ▼                      │
 │                              │              │  ┌──────────────────────┐          │
 │                              │              │  │  AccountingModule   │          │
 │                              │              │  │  (FlexStrategy)      │          │
 │                              │              │  └──────────────────────┘          │
 └──────────────────────────────┘              └────────────────────────────────────┘
```

#### Net-New Component: RewardRelayAdapter

The only new contract is a settlement-chain adapter that reads the relayed absolute position value from StateStore, computes the reward delta since the last checkpoint, and exposes it to the rewards processor for calling `accountingModule.processRewards(delta)`.

```solidity
contract RewardRelayAdapter {
    IStateStore public immutable stateStore;
    bytes32 public immutable stateKey;
    uint256 public lastRelayedValue;

    /// @notice Computes the reward delta since the last relay.
    function pendingRewards() external view returns (uint256) {
        (bytes memory value, , ) = stateStore.getValue(stateKey);
        uint256 currentValue = abi.decode(value, (uint256));
        if (currentValue <= lastRelayedValue) return 0;
        return currentValue - lastRelayedValue;
    }

    /// @notice Called by the rewards processor after processRewards succeeds.
    function checkpoint() external onlyRewardsProcessor {
        (bytes memory value, , ) = stateStore.getValue(stateKey);
        lastRelayedValue = abi.decode(value, (uint256));
    }
}
```

#### Value Semantics: Absolute Totals, Not Deltas

The relay should always send **absolute total position value**, not deltas. Rationale:
- Deltas require tracking "last sent" state on the source chain, creating a consistency hazard if a message is lost or replayed
- Absolute values are idempotent -- receiving the same value twice is harmless (StateStore's staleness check handles it)
- The delta computation happens on the settlement chain where it can be validated against the AccountingModule's APR caps before being applied

State key derivation for the reverse relay:
```solidity
// Relay the rate from the sidechain vault (fixed calldata, stable key)
bytes memory callData = abi.encodeCall(IERC4626.convertToAssets, (1e18));
bytes32 ARB_RATE_KEY = keccak256(abi.encode(arbVault, callData));

// Relay the Safe's share balance (fixed calldata, stable key)
bytes memory balCallData = abi.encodeCall(IERC20.balanceOf, (safe));
bytes32 ARB_BALANCE_KEY = keccak256(abi.encode(arbVault, balCallData));
```

The settlement chain computes `positionValue = rate * balance / 1e18` from two stable-key relays. No dynamic calldata, no reader contracts needed for this case.

The relayed value represents: "The total base-asset-equivalent value of all assets deployed on this sidechain, including accrued yield."

---

### Amendment B: Staleness Check Should Also Consider Delivery Delay

#### Problem

The RateAdapter staleness check only uses `srcTimestamp`:
```solidity
if (block.timestamp - srcTimestamp > maxStaleness) revert StaleRate();
```

This has two issues for the L2 → L1 direction:
1. **L2 timestamps can be sequencer-manipulated** on optimistic rollups (the sequencer sets `block.timestamp`)
2. **LayerZero delivery delay is invisible** -- a message could be sent with a recent `srcTimestamp` but sit in the DVN verification queue for hours. The staleness check passes, but the data is actually delayed.

#### Recommendation

Add a secondary freshness check using `updatedAt` (when the StateStore actually received the value):

```solidity
function getRate() external view returns (uint256) {
    (bytes memory value, uint64 srcTimestamp, uint64 updatedAt) = stateStore.getValue(stateKey);
    if (block.timestamp - srcTimestamp > maxStaleness) revert StaleRate();
    if (block.timestamp - updatedAt > maxDeliveryDelay) revert DeliveryDelayed();
    return abi.decode(value, (uint256));
}
```

Where `maxDeliveryDelay` is a shorter window (e.g. 2 hours) representing "how long ago did we actually receive this on-chain." This catches cases where LayerZero is degraded but technically still delivering old messages.

---

### Amendment C: Coordinating Relay Timing with AccountingModule Constraints

#### Problem

The FlexStrategy's AccountingModule enforces:
- A **cooldown** between `processRewards` calls
- An **APR cap** validated against historical snapshots

The relay design has its own timing: daily pushes with a 26-hour staleness window. These are not coordinated. If the relay pushes faster than the cooldown allows, reward data accumulates in the StateStore but can't be applied. If it pushes slower, the APR cap calculation window expands, potentially allowing larger single updates.

#### Recommendation

The keeper/automation that calls `processRewards` on the settlement chain should:
1. Read the latest relayed value from StateStore
2. Compute the delta via RewardRelayAdapter
3. Check if the AccountingModule cooldown has elapsed
4. Simulate the APR check before submitting the transaction
5. If the delta would exceed the APR cap, only apply up to the maximum (similar to how `RewardsSweeper.sweepRewardsUpToAPRMax()` works in the FlexStrategy)

This should be codified in a `CrossChainRewardsSweeper` contract:

```solidity
contract CrossChainRewardsSweeper {
    RewardRelayAdapter public immutable relayAdapter;
    IAccountingModule public immutable accountingModule;

    function sweepCrossChainRewards() external {
        uint256 pending = relayAdapter.pendingRewards();
        if (pending == 0) return;

        uint256 maxRewards = accountingModule.calculateMaxRewards();
        uint256 toProcess = pending < maxRewards ? pending : maxRewards;

        accountingModule.processRewards(toProcess);
        relayAdapter.checkpoint();
    }
}
```

---

### Amendment D: Multi-Chain Position Aggregation

#### Problem

If the FlexStrategy deploys to multiple sidechains simultaneously (e.g. Arbitrum + Optimism + Base), the settlement chain needs to aggregate reward data from all of them to compute total NAV. The current single-key-single-value design works per-chain but has no aggregation pattern.

#### Recommendation

Each chain's position value produces a naturally distinct derived key (different target contract address on each chain), so keys are already per-chain by construction. Add an aggregation layer on the settlement side:

```solidity
// Each chain has its own vault contract, so deriveKey produces unique keys automatically:
bytes32 arbKey  = keccak256(abi.encode(arbVault,  callData));  // Arbitrum
bytes32 opKey   = keccak256(abi.encode(opVault,   callData));  // Optimism
bytes32 baseKey = keccak256(abi.encode(baseVault, callData));  // Base
```

An `AggregatedRewardAdapter` on the settlement chain reads all position keys and sums the deltas:

```solidity
contract AggregatedRewardAdapter {
    IStateStore public immutable stateStore;
    bytes32[] public positionKeys;
    mapping(bytes32 => uint256) public lastRelayedValues;

    function totalPendingRewards() external view returns (uint256 total) {
        for (uint i = 0; i < positionKeys.length; i++) {
            (bytes memory value, , ) = stateStore.getValue(positionKeys[i]);
            uint256 current = abi.decode(value, (uint256));
            if (current > lastRelayedValues[positionKeys[i]]) {
                total += current - lastRelayedValues[positionKeys[i]];
            }
        }
    }
}
```

This keeps each relay path simple (one chain, one key, one value) while allowing flexible aggregation on the settlement side.

---

### Amendment E: Bounded Rate Update Sanity Check on StateStore

#### Problem

The StateStore currently accepts any `bytes` value from authorized writers with no sanity checking. A compromised writer (or bug in the relay) could write a wildly incorrect value. The RateAdapter's staleness check doesn't catch a fresh-but-wrong value.

#### Recommendation

Add an optional per-key bounds check in StateStore:

```solidity
struct KeyConfig {
    uint256 maxDelta;   // max allowed change per update (in basis points)
    uint256 lastUint;   // last decoded uint256 value (for comparison)
    bool bounded;       // whether bounds checking is enabled for this key
}

mapping(bytes32 => KeyConfig) public keyConfigs;

function updateValue(bytes32 key, bytes calldata value, uint64 srcTimestamp) external onlyWriter {
    if (srcTimestamp <= values[key].srcTimestamp) return;

    if (keyConfigs[key].bounded) {
        uint256 newVal = abi.decode(value, (uint256));
        uint256 oldVal = keyConfigs[key].lastUint;
        if (oldVal > 0) {
            uint256 delta = newVal > oldVal
                ? ((newVal - oldVal) * 10_000) / oldVal
                : ((oldVal - newVal) * 10_000) / oldVal;
            if (delta > keyConfigs[key].maxDelta) revert DeltaExceedsBound();
        }
        keyConfigs[key].lastUint = newVal;
    }

    values[key] = StateValue({ value: value, srcTimestamp: srcTimestamp, updatedAt: uint64(block.timestamp) });
    emit ValueUpdated(key, srcTimestamp, uint64(block.timestamp));
}
```

For the ynETHx rate, a `maxDelta` of 100 bps (1%) per update is reasonable. For position values, a wider bound may be needed to accommodate deposit/withdrawal flows.

**Trade-off**: This adds complexity to StateStore, which the original design intentionally kept minimal. An alternative is to put bounds checking only in the consumer adapters (RateAdapter, RewardRelayAdapter), keeping StateStore as a dumb pipe. The adapter-side approach is cleaner but means bad values still land in the store and could confuse off-chain monitoring.

---

### Amendment F: Minor Issues

1. **`dstGasLimit` is per-contract, not per-destination**: If sending to multiple L2s with different gas costs, a single gas limit is either wasteful (overpaying cheap chains) or insufficient (underpaying expensive chains). Consider `mapping(uint32 => uint128) public dstGasLimits`.

2. **Refund address in AutomatedStatePusher**: The `_lzSend` refunds overpaid gas to `msg.sender`. When called by Gelato/Chainlink Automation, `msg.sender` is the automation executor, not the contract owner. Excess ETH is irrecoverable. Refunds should go to the contract itself or a configurable address.

3. **No liveness monitoring**: There's no way for downstream systems to proactively detect relay failure. Consider adding a `lastUpdateTimestamp(bytes32 key)` view on StateStore and a monitoring integration that alerts if no update arrives within 2x the expected push interval.

4. **`StateSender._lzReceive` reverts with a string**: `revert("StateSender: receive not supported")` uses a string revert instead of a custom error. This wastes gas in the unlikely case it's triggered. Use `error ReceiveNotSupported()` instead.
