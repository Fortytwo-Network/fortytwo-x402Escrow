# fortytwo-x402Escrow

## Overview

`x402Escrow` is a UUPS-upgradeable escrow contract developed by [Fortytwo](https://fortytwo.network/) that extends the [x402](https://www.x402.org/) payment protocol flow with on-chain escrow to enable usage-based, pay-per-token billing for AI services where costs are unknown at request time.

This repository focuses solely on `X402Escrow`: settlement, release, timeout refund, tests, and deployment.

## Contract Overview

`X402Escrow` is designed for facilitator-driven MCP billing:

1. Facilitator chooses `refundTimeoutSecs`, generates random `salt`, and computes nonce-binding.
2. Client signs EIP-3009 authorization off-chain (`ReceiveWithAuthorization`) with that nonce.
3. Facilitator calls `settle(...)` to pull USDC into escrow.
4. The same facilitator calls `release(escrowId, facilitatorAmount, refundTimeoutSecs, salt)` after the request is completed.
5. If release never happens, anyone can call `refundAfterTimeout(escrowId)` and funds return to the client.

## Why Escrow Extension for x402

Standard x402 is excellent for fixed-price endpoints, but inference workloads are variable:

- Token usage is unknown before execution and can vary widely by request.
- An upfront transfer to a service wallet creates trust asymmetry before delivery is complete.
- Per-token billing requires post-execution settlement, not only prepayment.

`X402Escrow` solves this with a deterministic settlement model:

1. Lock the maximum authorized amount in escrow.
2. Measure the actual usage after inference.
3. Release the actual amount to the facilitator and refund the remainder to the client in one call.

## Key Design Decisions

- `receiveWithAuthorization` (EIP-3009): the authorization targets the escrow contract, reducing mempool signature misuse risk.
- Permissionless settle/release with cryptographic binding: facilitator identity is proven via nonce reconstruction, not roles.
- Nonce-binding formula: `nonce = keccak256(TAG, chainId, escrowAddress, facilitatorAddress, refundTimeoutSecs, salt)`.
- Packed escrow storage: each escrow uses a compact, single-slot layout for gas efficiency.
- Per-escrow timeout: each escrow stores its own `refundAt`; no mutable global timeout state for active escrows.
- Permissionless timeout refund: anyone can call `refundAfterTimeout`, funds always return to the original client.
- Owner-only upgrade authority (UUPS), no `AccessControl` role management in V2.

## Security Properties

- Client protection: funds remain in escrow until settlement logic executes.
- Facilitator/service protection: release is restricted to the facilitator bound at settle time.
- Anti-front-run binding: a different caller cannot reuse the same signed authorization for settle/release.
- Liveness: timeout refunds remain available even if off-chain actors are unavailable.
- Reentrancy hardening: state-changing transfer flows are protected by `nonReentrant`.

## x402 Compatibility

This contract is an x402-compatible extension:

- Server still responds with HTTP `402 Payment Required`.
- Client still signs standard EIP-3009 authorization payload.
- The protocol adds nonce derivation conventions for facilitator binding while preserving x402 flow shape.

## Complementary to ERC-8183

`X402Escrow` and ERC-8183 target different layers of the same agentic commerce stack:

- `X402Escrow` is optimized for objective, consumption-based settlement (metered inference).
- ERC-8183 is optimized for task lifecycle and evaluator-driven job completion.

They are complementary: a task-level commerce flow can use ERC-8183 while metered inference inside that task can settle through `X402Escrow`.

## Roles

- `owner`:
  can upgrade proxy implementation (`UUPSUpgradeable`), uses 2-step ownership transfer.
- `facilitator`:
  no on-chain role in V2; any address can call settle/release only if cryptographically bound by nonce.

## Repository Layout

- `src/X402Escrow.sol` – escrow contract.
- `test/X402Escrow.t.sol` – unit tests (including proxy upgrade tests).
- `.gas-snapshot` – committed gas baseline for regression checks.
- `script/DeployX402Escrow.s.sol` – implementation + proxy deploy/upgrade script.
- `.env.example` – deployment environment template.

## Quick Start

```bash
forge --version

# Install dependencies (if lib/ is empty)
forge install --no-git foundry-rs/forge-std
forge install --no-git OpenZeppelin/openzeppelin-contracts
forge install --no-git OpenZeppelin/openzeppelin-contracts-upgradeable

forge build
forge test --offline --match-path test/X402Escrow.t.sol -vv
forge snapshot --offline --match-path test/X402Escrow.t.sol --check
```

If gas numbers have changed intentionally, refresh snapshot:

```bash
forge snapshot --offline --match-path test/X402Escrow.t.sol
```

## Deploy

```bash
cp .env.example .env
# fill PRIVATE_KEY, USDC_ADDRESS, OWNER_ADDRESS
source .env

# Base Sepolia (fresh deploy)
forge script script/DeployX402Escrow.s.sol --rpc-url base_sepolia --broadcast
```

Upgrade existing proxy in place:

```bash
ESCROW_PROXY_ADDRESS=0xYourProxy \
forge script script/DeployX402Escrow.s.sol --rpc-url base_sepolia --broadcast
```

You can also use `--rpc-url base`, `--rpc-url monad`, or `--rpc-url monad_testnet`.

## Main Functions

- `settle(...)` – lock client USDC via EIP-3009 `receiveWithAuthorization` and bind facilitator via nonce.
- `release(escrowId, facilitatorAmount, refundTimeoutSecs, salt)` – split escrow amount between facilitator and client.
- `refundAfterTimeout(escrowId)` – timeout safety refund to the client.
- `getEscrow(escrowId)` – returns enriched escrow view (`EscrowView`).

## Security Notes

- Contract uses `nonReentrant` on state-changing financial paths.
- Escrow storage is deleted before token transfers in release/refund.
- `settle` validates exact token delta to block fee-on-transfer behavior.
- `release` verifies caller binding via nonce reconstruction.
- Upgrade authorization is owner-only (`_authorizeUpgrade`).

## Open Source Docs

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [SECURITY.md](SECURITY.md)
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- [LICENSE](LICENSE)
