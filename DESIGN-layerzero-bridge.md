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

### 3.1 Message Format

All state updates are encoded as a single message:

```solidity
bytes memory message = abi.encode(key, value, srcTimestamp);
```

| Field | Type | Description |
|---|---|---|
| `key` | `bytes32` | Identifier for the state value (e.g. `keccak256("ynETHx/ETH")`) |
| `value` | `bytes` | The state value, abi-encoded (e.g. `abi.encode(uint256(rate))`) |
| `srcTimestamp` | `uint64` | Source chain timestamp at time of read |

This is intentionally flat. No message type enum, no versioning overhead. One message = one state update.

### 3.2 StateSender

Inherits from LayerZero V2's `OApp`. Lives on the source chain.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { OApp, MessagingFee, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

contract StateSender is OApp {
    using OptionsBuilder for bytes;

    uint128 public dstGasLimit = 100_000;

    event StateSent(bytes32 indexed key, bytes value, uint32 dstEid);

    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) {}

    /// @notice Push an state value to a destination chain.
    /// @param dstEid   LayerZero endpoint ID of destination chain.
    /// @param key      State Key identifier.
    /// @param value    ABI-encoded state value.
    function sendStateValue(
        uint32 dstEid,
        bytes32 key,
        bytes calldata value
    ) external payable {
        bytes memory message = abi.encode(key, value, uint64(block.timestamp));
        bytes memory options = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(dstGasLimit, 0);

        _lzSend(dstEid, message, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit StateSent(key, value, dstEid);
    }

    /// @notice Quote the fee for sending an state value.
    function quoteSend(
        uint32 dstEid,
        bytes32 key,
        bytes calldata value
    ) external view returns (uint256 nativeFee) {
        bytes memory message = abi.encode(key, value, uint64(block.timestamp));
        bytes memory options = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(dstGasLimit, 0);

        MessagingFee memory fee = _quote(dstEid, message, options, false);
        return fee.nativeFee;
    }

    /// @notice Owner can adjust destination gas limit.
    function setDstGasLimit(uint128 _gasLimit) external onlyOwner {
        dstGasLimit = _gasLimit;
    }

    /// @dev Required by OApp but this contract only sends.
    function _lzReceive(
        Origin calldata, bytes32, bytes calldata, address, bytes calldata
    ) internal override {
        revert("StateSender: receive not supported");
    }
}
```

**Key decisions:**
- `sendStateValue` is **permissionless** -- any EOA or keeper can call it and pay the gas. Access control on *what* gets sent is handled by the caller reading on-chain values.
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

An off-chain keeper (bot or multisig) calls `StateSender.sendStateValue()` daily:

```
1. Read ynETHx rate on L1: ynETHx.convertToAssets(1e18)
2. Encode: abi.encode(rate)
3. Quote: StateSender.quoteSend(dstEid, key, encodedRate)
4. Send:  StateSender.sendStateValue{value: fee}(dstEid, key, encodedRate)
```

**Pros**: Dead simple, easy to monitor.
**Cons**: Relies on an external keeper being up.

### Option B: Gelato / Chainlink Automation (Recommended)

Use [Chainlink Automation](https://automation.chain.link/) or [Gelato](https://www.gelato.network/) to trigger the push:

- **Trigger**: Time-based (every 24h) or deviation-based (>0.1% rate change)
- **Execution**: Calls `sendStateValue` on the StateSender
- **Gas funding**: Automation service pays L1 gas; LayerZero fee comes from a pre-funded contract or is forwarded

A thin `AutomatedStatePusher` contract can wrap the logic:

```solidity
contract AutomatedStatePusher {
    StateSender public immutable sender;
    address public immutable rateSource; // e.g. ynETHx vault
    bytes32 public immutable key;
    uint32 public immutable dstEid;

    function pushRate() external payable {
        uint256 rate = IERC4626(rateSource).convertToAssets(1e18);
        bytes memory value = abi.encode(rate);
        uint256 fee = sender.quoteSend(dstEid, key, value);
        sender.sendStateValue{value: fee}(dstEid, key, value);
    }

    receive() external payable {} // Accept ETH for gas funding
}
```

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
7. Deploy RateAdapter on Arbitrum (pass store + key + maxStaleness)
8. Configure Curve pool to use RateAdapter address
```

---

## 8. Use Case: ynETHx Rate on Arbitrum

### Source Value

ynETHx is an ERC-4626 vault. The exchange rate is:

```solidity
uint256 rate = ynETHx.convertToAssets(1e18); // returns 18-decimal rate
```

### State Key

```solidity
bytes32 constant YNETHX_ETH_RATE = keccak256("ynETHx/ETH");
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

| Concern | Mitigation |
|---|---|
| **Unauthorized sender** | OApp peer validation: only the registered peer on the source chain can send messages. `_getPeerOrRevert` in `lzReceive()` enforces this. |
| **Stale data** | RateAdapter reverts on stale data. StateStore silently skips out-of-order messages. |
| **Replay / re-entrancy** | LayerZero V2 handles nonce management. StateStore update is a simple SSTORE, no external calls. |
| **Malicious state value** | The sender is permissionless but reads from immutable on-chain sources (e.g. ERC-4626 vault). The value is trustworthy if the source contract is trustworthy. |
| **LayerZero liveness** | If LayerZero is down, rates go stale and the RateAdapter reverts, preventing trades at bad prices. This is the correct behavior. |
| **Message ordering** | We don't require ordered delivery. The `srcTimestamp` check in StateStore ensures only newer values are accepted regardless of arrival order. |
| **Store writer compromise** | Owner can revoke writers. In the worst case, the staleness check in RateAdapter limits the impact window. |

---

## 10. Gas Estimates

| Operation | Estimated Gas | Notes |
|---|---|---|
| `StateSender.sendStateValue` (L1) | ~80,000 + LZ fee | LZ fee varies by DVN config |
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
| StateSender | ~50 | Thin wrapper over OApp._lzSend |
| StateReceiver | ~30 | Thin wrapper over OApp._lzReceive |
| StateStore | ~60 | Simple SSTORE with timestamp check |
| RateAdapter | ~20 | Pure view, no state mutation |
| **Total** | **~160** | |

The OApp base contracts are already audited by LayerZero. Our custom code is ~160 lines of straightforward Solidity.

---

## 14. Future Considerations

- **Batch sending**: Send multiple keys in one LZ message to reduce per-message overhead
- **Multi-destination**: Push from L1 to multiple L2s in a single transaction (LayerZero's "Batch Send" pattern)
- **Additional bridges**: Deploy Axelar/Hyperlane receivers and add them as StateStore writers for redundancy
- **Quorum verification**: If multi-bridge consensus becomes necessary, add a lightweight quorum check in StateStore (inspired by Centrifuge's MultiAdapter threshold pattern)
- **Rate smoothing**: On-chain TWAP or bounded rate updates to mitigate state manipulation
