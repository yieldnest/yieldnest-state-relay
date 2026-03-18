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

## 14. Other Considerations

- **Batch sending**: Send multiple keys in one LZ message to reduce per-message overhead
- **Multi-destination**: Push from L1 to multiple L2s in a single transaction (LayerZero's "Batch Send" pattern




