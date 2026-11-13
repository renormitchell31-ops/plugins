# On-chain dictionary registry

Bonded, challengeable dictionary for ASCII headwords. Inspired by in-page lookup (term → definition), not a clone of any proprietary dictionary.

Canonical text is written only after an optimistic challenge window or an arbiter ruling. Bonds are pulled, never pushed.

## Installation

```text
/add-plugin onchain-dictionary
```

## Skills

| Skill | Description |
| --- | --- |
| `deploy-dictionary` | Test and deploy `TimelockGovernor` then `DictionaryRegistry` |
| `propose-dictionary-entry` | Valid propose / challenge / finalize / resolve / timeout / withdraw flow |
| `review-dictionary-registry` | Pre-flight fund-safety and constraint review before mainnet |

## Layout

| Contract | Role |
| --- | --- |
| `DictionaryRegistry` | Propose / challenge / finalize entries; escrow bonds |
| `TimelockGovernor` | Delayed `governor` so parameter changes are not a hot key |

## Lifecycle

1. **Propose** a term (`a-z`, `-`, `'`) plus 1–4 senses. `msg.value >= minBond` is escrowed.
2. Anyone may **challenge** with an equal bond before `challengeDeadline`.
3. If unchallenged, anyone **finalize**s after the window; the submitter pulls the bond back.
4. If challenged, **arbiter** accepts (entry goes live, submitter takes both bonds) or rejects (challenger takes both).
5. If the arbiter misses `resolveDeadline`, **timeout** is a draw: both pull their own bond, no canonical write.

Pause (guardian/governor) blocks new propose/challenge only. Finalize, resolve, timeout, and withdraw stay live so funds cannot be frozen.

## Critical constraints

- Terms are lowercase ASCII only (homograph-resistant).
- Definitions capped (280 bytes) so storage cannot be used as a dump.
- No `receive`/`fallback` ETH; extra value cannot stick.
- Governor transfer is two-step. Point `governor` at `TimelockGovernor` before any real stake.
- Not upgradeable. Wrong params require a new deployment.
- Arbiter is trusted for disputed entries. Replace it with a real court (multisig, UMA, Kleros) via the timelock.

## Deploy

```bash
forge test -vv
forge create src/TimelockGovernor.sol:TimelockGovernor --constructor-args <owner> 86400 1209600
forge create src/DictionaryRegistry.sol:DictionaryRegistry --constructor-args <timelock> <arbiter> <guardian> 100000000000000000 86400 86400
```

Unaudited. Do not mainnet this without an independent review.
