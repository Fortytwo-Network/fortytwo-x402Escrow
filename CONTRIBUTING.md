# Contributing

Thanks for contributing to `fortytwo-x402Escrow`.

## Development Setup

1. Install Foundry.
2. Install dependencies:

```bash
forge install --no-git foundry-rs/forge-std
forge install --no-git OpenZeppelin/openzeppelin-contracts
forge install --no-git OpenZeppelin/openzeppelin-contracts-upgradeable
```

3. Run local checks:

```bash
forge fmt --check
forge build
forge test --offline --match-path test/X402Escrow.t.sol -vv
forge snapshot --offline --match-path test/X402Escrow.t.sol --check
```

If your PR intentionally changes gas usage, regenerate `.gas-snapshot`:

```bash
forge snapshot --offline --match-path test/X402Escrow.t.sol
```

## Pull Request Guidelines

1. Keep changes scoped and explain intent clearly.
2. Add or update tests for behavioral changes.
3. Keep NatSpec and README in sync with code changes.
4. Avoid introducing breaking storage-layout changes without explicit migration notes.

## Commit Style

- Use concise, imperative commit messages.
- Prefer small commits that are easy to review.
