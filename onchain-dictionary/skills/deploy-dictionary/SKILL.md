---
name: deploy-dictionary
description: >-
  Test and deploy DictionaryRegistry behind TimelockGovernor. Use when the user
  asks to deploy, configure, or launch the on-chain dictionary, or mentions
  forge create, minBond, challengePeriod, or governor delay.
---

# Deploy dictionary

Deploy `TimelockGovernor` first, then point `DictionaryRegistry.governor` at it. Do not leave `governor` as an EOA once real stake exists.

## Preconditions

- Foundry (`forge`) installed
- Work from `onchain-dictionary/`
- Contracts are **not upgradeable**. Wrong constructor args mean a new deployment.

## Test

```bash
forge test -vv
```

Do not skip tests. Pause, bond, challenge, timeout, and withdraw paths are load-bearing.

## Constructor args

`TimelockGovernor(owner, delay, grace)`

| Arg | Constraint | Suggested start |
| --- | --- | --- |
| `owner` | nonzero | your multisig |
| `delay` | 1 hour–30 days | `86400` (1 day) |
| `grace` | 1 hour–30 days | `1209600` (14 days) |

`DictionaryRegistry(governor, arbiter, guardian, minBond, challengePeriod, resolvePeriod)`

| Arg | Constraint | Suggested start |
| --- | --- | --- |
| `governor` | `TimelockGovernor` address | the address just created |
| `arbiter` | trusted resolver (replace later via timelock) | multisig or court |
| `guardian` | can pause propose/challenge only | hot pause key |
| `minBond` | `> 0` | `100000000000000000` (0.1 ETH) |
| `challengePeriod` | 1 hour–30 days | `86400` |
| `resolvePeriod` | 1 hour–30 days | `86400` |

## Deploy

```bash
forge create src/TimelockGovernor.sol:TimelockGovernor --constructor-args <owner> 86400 1209600
forge create src/DictionaryRegistry.sol:DictionaryRegistry --constructor-args <timelock> <arbiter> <guardian> 100000000000000000 86400 86400
```

Record both addresses. Verify source on the explorer.

## After deploy

1. Confirm `registry.governor()` is the timelock, not an EOA.
2. Confirm pause does **not** block `finalize`, `resolve`, `timeout`, or `withdraw`.
3. Do not mainnet this without an independent review. The contracts are unaudited.
